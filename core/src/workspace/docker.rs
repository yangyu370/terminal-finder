use std::{process::Output, time::Duration};

use async_trait::async_trait;
use tokio::{process::Command, sync::mpsc, time};

use crate::{
    connection::Credential,
    error::ApiError,
    terminal::session::{SessionHandle, TerminalEvent, TerminalLaunch, TerminalSession},
    workspace::{
        MountHandle, MountSpec, RuntimeStatus, TerminalOpenContext, WorkspaceRuntime, naming,
        rclone,
    },
};

pub const RUNTIME_NAME: &str = "docker_local";
pub const MOUNT_ROOT: &str = "/mnt";
pub const DEFAULT_CONTAINER: &str = "terminal-finder-workspace";
pub const DEFAULT_IMAGE: &str = "terminal-finder-workspace:dev";
const RCLONE_REMOTE: &str = "tf";
const MOUNT_READY_TIMEOUT: Duration = Duration::from_secs(5);
const MOUNT_READY_POLL: Duration = Duration::from_millis(100);

pub struct LocalDockerRuntime {
    container: String,
    image: String,
}

impl LocalDockerRuntime {
    pub fn new(container: impl Into<String>, image: impl Into<String>) -> Self {
        Self {
            container: container.into(),
            image: image.into(),
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(DEFAULT_CONTAINER, DEFAULT_IMAGE)
    }

    pub fn container_name(&self) -> &str {
        &self.container
    }
}

pub fn run_container_argv(container: &str, image: &str) -> Vec<String> {
    strings([
        "docker",
        "run",
        "-d",
        "--name",
        container,
        "--cap-add",
        "SYS_ADMIN",
        "--device",
        "/dev/fuse",
        image,
        "sleep",
        "infinity",
    ])
}

pub fn unmount_argv(container: &str, mountpoint: &str) -> Vec<String> {
    strings(["docker", "exec", container, "fusermount", "-uz", mountpoint])
}

pub fn mountpoint_check_argv(container: &str, mountpoint: &str) -> Vec<String> {
    strings(["docker", "exec", container, "mountpoint", "-q", mountpoint])
}

pub fn terminate_mount_attempt_argv(container: &str, mountpoint: &str) -> Vec<String> {
    strings([
        "docker",
        "exec",
        container,
        "sh",
        "-c",
        "pkill -f -- \"rclone mount .* $1\" || true",
        "sh",
        mountpoint,
    ])
}

fn strings<const N: usize>(items: [&str; N]) -> Vec<String> {
    items.into_iter().map(String::from).collect()
}

#[async_trait]
impl WorkspaceRuntime for LocalDockerRuntime {
    async fn status(&self) -> RuntimeStatus {
        match run_argv(&strings(["docker", "info"])).await {
            Ok(output) if output.status.success() => RuntimeStatus::Ready,
            _ => RuntimeStatus::Unavailable,
        }
    }

    async fn ensure_ready(&self) -> Result<(), ApiError> {
        if self.status().await != RuntimeStatus::Ready {
            return Err(ApiError::WorkspaceRuntimeUnavailable {
                runtime: RUNTIME_NAME.into(),
                message: "runtime CLI is not available".into(),
            });
        }

        let image = run_argv(&strings(["docker", "image", "inspect", &self.image]))
            .await
            .map_err(|error| {
                provision_error(format!("failed to inspect runtime image: {error}"))
            })?;
        if !image.status.success() {
            return Err(provision_error("runtime image is not available".into()));
        }

        let inspect = run_argv(&strings([
            "docker",
            "inspect",
            "-f",
            "{{.State.Running}}",
            &self.container,
        ]))
        .await
        .map_err(|error| provision_error(format!("failed to inspect runtime instance: {error}")))?;

        if inspect.status.success() {
            let running = String::from_utf8_lossy(&inspect.stdout).trim() == "true";
            if running {
                return Ok(());
            }

            let start = run_argv(&strings(["docker", "start", &self.container]))
                .await
                .map_err(|error| {
                    start_error(format!("failed to start runtime instance: {error}"))
                })?;
            if start.status.success() {
                return Ok(());
            }
            return Err(start_error("failed to start runtime instance".into()));
        }

        let run = run_argv(&run_container_argv(&self.container, &self.image))
            .await
            .map_err(|error| {
                provision_error(format!("failed to create runtime instance: {error}"))
            })?;
        if run.status.success() {
            Ok(())
        } else {
            Err(provision_error("failed to create runtime instance".into()))
        }
    }

    fn propose_mountpoint(&self, display_name: &str, taken: &[String]) -> String {
        naming::mountpoint_for(MOUNT_ROOT, display_name, taken)
    }

    async fn mount(&self, spec: MountSpec) -> Result<MountHandle, ApiError> {
        let Credential::S3(credential) = spec.credential;
        let mkdir = run_argv(&strings([
            "docker",
            "exec",
            &self.container,
            "mkdir",
            "-p",
            &spec.mountpoint,
        ]))
        .await
        .map_err(|error| ApiError::MountFailed {
            message: format!("failed to prepare mountpoint: {error}"),
        })?;
        if !mkdir.status.success() {
            return Err(ApiError::MountFailed {
                message: "failed to prepare mountpoint".into(),
            });
        }

        let plan = rclone::mount_exec_plan(
            &self.container,
            RCLONE_REMOTE,
            &spec.config,
            &credential,
            &spec.mountpoint,
        );
        let mount = run_argv_with_env(&plan.argv, &plan.env)
            .await
            .map_err(|error| ApiError::MountFailed {
                message: format!("failed to start mount: {error}"),
            })?;
        if !mount.status.success() {
            return Err(ApiError::MountFailed {
                message: "failed to start mount".into(),
            });
        }

        if self.wait_for_mountpoint(&spec.mountpoint).await {
            Ok(MountHandle {
                mountpoint: spec.mountpoint,
            })
        } else {
            let _ = self.terminate_mount_attempt(&spec.mountpoint).await;
            let _ = self.unmount(&spec.mountpoint).await;
            Err(ApiError::MountTimeout {
                mountpoint: spec.mountpoint,
            })
        }
    }

    async fn unmount(&self, mountpoint: &str) -> Result<(), ApiError> {
        let _ = run_argv(&unmount_argv(&self.container, mountpoint)).await;
        Ok(())
    }

    async fn open_terminal(
        &self,
        ctx: TerminalOpenContext,
        cols: u16,
        rows: u16,
        events: mpsc::Sender<TerminalEvent>,
    ) -> Result<SessionHandle, ApiError> {
        TerminalSession::spawn(
            TerminalLaunch::DockerExec {
                container: self.container.clone(),
                workdir: ctx.workdir,
            },
            cols,
            rows,
            events,
        )
        .map_err(|error| ApiError::WorkspaceStartFailed {
            runtime: RUNTIME_NAME.into(),
            message: error.to_string(),
        })
    }

    async fn teardown(&self) -> Result<(), ApiError> {
        let _ = run_argv(&strings(["docker", "rm", "-f", &self.container])).await;
        Ok(())
    }
}

impl LocalDockerRuntime {
    async fn wait_for_mountpoint(&self, mountpoint: &str) -> bool {
        let deadline = time::Instant::now() + MOUNT_READY_TIMEOUT;
        loop {
            match run_argv(&mountpoint_check_argv(&self.container, mountpoint)).await {
                Ok(output) if output.status.success() => return true,
                _ if time::Instant::now() >= deadline => return false,
                _ => time::sleep(MOUNT_READY_POLL).await,
            }
        }
    }

    async fn terminate_mount_attempt(&self, mountpoint: &str) -> Result<(), std::io::Error> {
        run_argv(&terminate_mount_attempt_argv(&self.container, mountpoint))
            .await
            .map(|_| ())
    }
}

fn provision_error(message: String) -> ApiError {
    ApiError::WorkspaceProvisionFailed {
        runtime: RUNTIME_NAME.into(),
        message,
    }
}

fn start_error(message: String) -> ApiError {
    ApiError::WorkspaceStartFailed {
        runtime: RUNTIME_NAME.into(),
        message,
    }
}

async fn run_argv(argv: &[String]) -> Result<Output, std::io::Error> {
    run_argv_with_env(argv, &[]).await
}

async fn run_argv_with_env(
    argv: &[String],
    env: &[(String, String)],
) -> Result<Output, std::io::Error> {
    let mut command = Command::new(&argv[0]);
    command.args(&argv[1..]);
    for (name, value) in env {
        command.env(name, value);
    }
    command.output().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::WorkspaceRuntime;

    #[test]
    fn run_container_argv_requests_fuse_capabilities() {
        assert_eq!(
            run_container_argv("workspace", "image:dev"),
            vec![
                "docker",
                "run",
                "-d",
                "--name",
                "workspace",
                "--cap-add",
                "SYS_ADMIN",
                "--device",
                "/dev/fuse",
                "image:dev",
                "sleep",
                "infinity",
            ]
        );
    }

    #[test]
    fn unmount_argv_uses_fusermount_inside_container() {
        assert_eq!(
            unmount_argv("workspace", "/mnt/minio"),
            vec![
                "docker",
                "exec",
                "workspace",
                "fusermount",
                "-uz",
                "/mnt/minio"
            ]
        );
    }

    #[test]
    fn terminate_mount_attempt_targets_mountpoint_without_shell_interpolation() {
        assert_eq!(
            terminate_mount_attempt_argv("workspace", "/mnt/minio"),
            vec![
                "docker",
                "exec",
                "workspace",
                "sh",
                "-c",
                "pkill -f -- \"rclone mount .* $1\" || true",
                "sh",
                "/mnt/minio",
            ]
        );
    }

    #[test]
    fn start_error_uses_workspace_start_code() {
        let err = start_error("boom".into());
        assert_eq!(err.code(), "workspace_start_failed");
    }

    #[test]
    fn propose_mountpoint_uses_local_mnt_root() {
        let runtime = LocalDockerRuntime::with_defaults();

        assert_eq!(runtime.propose_mountpoint("Minio", &[]), "/mnt/minio");
    }

    #[cfg(feature = "docker-integration-test")]
    #[tokio::test]
    async fn ensure_ready_is_idempotent_against_real_docker() {
        let container = format!("terminal-finder-test-{}", uuid::Uuid::new_v4());
        let runtime = LocalDockerRuntime::new(container, DEFAULT_IMAGE);

        runtime.ensure_ready().await.expect("runtime is ready");
        runtime
            .ensure_ready()
            .await
            .expect("second ensure reuses ready runtime");
        runtime.teardown().await.expect("teardown is best-effort");
    }
}
