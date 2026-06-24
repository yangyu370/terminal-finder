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
pub const INTERACTIVE_USER: &str = "terminal";
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

    async fn is_exposed(&self, mountpoint: &str) -> Result<bool, ApiError> {
        Ok(matches!(
            run_argv(&mountpoint_check_argv(&self.container, mountpoint)).await,
            Ok(output) if output.status.success()
        ))
    }

    async fn unmount(&self, mountpoint: &str) -> Result<(), ApiError> {
        if !self.is_exposed(mountpoint).await? {
            return Ok(());
        }

        let output = run_argv(&unmount_argv(&self.container, mountpoint))
            .await
            .map_err(|error| ApiError::MountFailed {
                message: format!("failed to unmount workspace path: {error}"),
            })?;

        if output.status.success() || !self.is_exposed(mountpoint).await? {
            Ok(())
        } else {
            Err(ApiError::MountFailed {
                message: "failed to unmount workspace path".into(),
            })
        }
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
                user: INTERACTIVE_USER.into(),
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
    #[cfg(feature = "docker-integration-test")]
    use crate::{
        connection::{ConnectionId, S3ConnectionConfig, S3Credential},
        terminal::session::TerminalEvent,
        workspace::{MountSpec, TerminalOpenContext},
    };
    #[cfg(feature = "docker-integration-test")]
    use tokio::sync::mpsc;
    #[cfg(feature = "docker-integration-test")]
    use uuid::Uuid;

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

    #[cfg(feature = "docker-integration-test")]
    #[tokio::test]
    async fn mounted_bucket_is_usable_from_non_root_terminal_without_secret_leak() {
        let unique = Uuid::new_v4().to_string();
        let container = format!("terminal-finder-test-{unique}");
        let mountpoint = format!("/mnt/test-{}", &unique[..8]);
        let runtime = LocalDockerRuntime::new(container, DEFAULT_IMAGE);

        runtime.ensure_ready().await.expect("runtime is ready");
        let mount_result = runtime
            .mount(MountSpec {
                connection_id: ConnectionId(unique.clone()),
                config: S3ConnectionConfig {
                    display_name: "MinIO Local".into(),
                    endpoint: std::env::var("TERMINAL_FINDER_DOCKER_S3_ENDPOINT")
                        .unwrap_or_else(|_| "http://host.docker.internal:9000".into()),
                    region: "us-east-1".into(),
                    bucket: std::env::var("TERMINAL_FINDER_DOCKER_S3_BUCKET")
                        .unwrap_or_else(|_| "test-bucket".into()),
                    base_prefix: String::new(),
                    path_style: true,
                },
                credential: crate::connection::Credential::S3(S3Credential {
                    access_key_id: std::env::var("TERMINAL_FINDER_DOCKER_S3_ACCESS_KEY")
                        .unwrap_or_else(|_| "minioadmin".into()),
                    secret_access_key: std::env::var("TERMINAL_FINDER_DOCKER_S3_SECRET_KEY")
                        .unwrap_or_else(|_| "minioadmin".into()),
                }),
                mountpoint: mountpoint.clone(),
            })
            .await;

        let mount = match mount_result {
            Ok(mount) => mount,
            Err(error) => {
                let _ = runtime.teardown().await;
                panic!("mount succeeds against local MinIO: {error}");
            }
        };

        let (events, mut rx) = mpsc::channel(TERMINAL_EVENT_BUFFER);
        let session = runtime
            .open_terminal(
                TerminalOpenContext {
                    workdir: mount.mountpoint.clone(),
                },
                100,
                30,
                events,
            )
            .await
            .expect("terminal opens in mounted bucket");

        assert!(session.input(b"stty -echo\n".to_vec()));
        tokio::time::sleep(Duration::from_millis(300)).await;
        drain_available(&mut rx);

        let script = concat!(
            "whoami\n",
            "pwd\n",
            "printf 'docker-integration\\n' > codex-docker-integration.txt\n",
            "cat codex-docker-integration.txt\n",
            "for f in /proc/[0-9]*/environ; do ",
            "cat \"$f\" 2>/dev/null | tr '\\0' '\\n' | grep -E 'RCLONE_CONFIG_.*(SECRET|ACCESS)' && printf 'PROC_%s\\n' SECRET; ",
            "done\n",
            "echo DOCKER_INTEGRATION_DONE\n",
            "exit\n",
        );
        assert!(session.input(script.as_bytes().to_vec()));

        let output = collect_output_until(&mut rx, "DOCKER_INTEGRATION_DONE").await;
        assert!(output.contains(INTERACTIVE_USER), "output:\n{output}");
        assert!(output.contains(&mount.mountpoint), "output:\n{output}");
        assert!(output.contains("docker-integration"), "output:\n{output}");
        assert!(
            !output.contains("PROC_SECRET") && !output.contains("minioadmin"),
            "non-root terminal exposed mount credentials:\n{output}"
        );

        let _ = session.close();
        let _ = runtime.unmount(&mount.mountpoint).await;
        runtime.teardown().await.expect("teardown is best-effort");
    }

    #[cfg(feature = "docker-integration-test")]
    const TERMINAL_EVENT_BUFFER: usize = 128;

    #[cfg(feature = "docker-integration-test")]
    async fn collect_output_until(rx: &mut mpsc::Receiver<TerminalEvent>, needle: &str) -> String {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        let mut output = Vec::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(
                !remaining.is_zero(),
                "timed out waiting for {needle}; output:\n{}",
                String::from_utf8_lossy(&output)
            );
            match tokio::time::timeout(remaining, rx.recv()).await {
                Ok(Some(TerminalEvent::Output { bytes, .. })) => {
                    output.extend(bytes);
                    if String::from_utf8_lossy(&output).contains(needle) {
                        return String::from_utf8_lossy(&output).into_owned();
                    }
                }
                Ok(Some(TerminalEvent::Error { code, message, .. })) => {
                    panic!("terminal error {code}: {message}");
                }
                Ok(Some(TerminalEvent::Exit { .. })) => {
                    panic!(
                        "terminal exited before {needle}; output:\n{}",
                        String::from_utf8_lossy(&output)
                    );
                }
                Ok(None) => panic!("terminal event channel closed"),
                Err(_) => panic!(
                    "timed out waiting for {needle}; output:\n{}",
                    String::from_utf8_lossy(&output)
                ),
            }
        }
    }

    #[cfg(feature = "docker-integration-test")]
    fn drain_available(rx: &mut mpsc::Receiver<TerminalEvent>) {
        while rx.try_recv().is_ok() {}
    }
}
