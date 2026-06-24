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

// macOS GUI 进程（LaunchServices 启动）默认 PATH 仅 /usr/bin:/bin:/usr/sbin:/sbin，
// 不包含 Docker Desktop 安装位置，导致 `docker` 二进制找不到。给每个 docker 子进程
// 注入候选目录到 PATH 前面，让 PATH lookup 能命中；同时保留宿主原 PATH 兜底。
const DOCKER_PATH_CANDIDATES: &[&str] = &[
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/Applications/Docker.app/Contents/Resources/bin",
];

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

    async fn mount(&self, mut spec: MountSpec) -> Result<MountHandle, ApiError> {
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

        // 用户填的 endpoint 直觉是从宿主角度看的（典型如 http://localhost:9000）；
        // 但 rclone 跑在容器里，对它而言 localhost 是容器自己。这里把 loopback host
        // 改写成 host.docker.internal，让容器能访问到宿主上的服务。原 connection
        // 配置保持不动。
        spec.config.endpoint = rewrite_endpoint_for_container(&spec.config.endpoint);

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
        let output = run_argv(&mountpoint_check_argv(&self.container, mountpoint))
            .await
            .map_err(|error| ApiError::WorkspaceStartFailed {
                runtime: RUNTIME_NAME.into(),
                message: format!("failed to inspect workspace path: {error}"),
            })?;
        Ok(output.status.success())
    }

    async fn unmount(&self, mountpoint: &str) -> Result<(), ApiError> {
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
    let mut caller_set_path = false;
    for (name, value) in env {
        if name == "PATH" {
            caller_set_path = true;
        }
        command.env(name, value);
    }
    if !caller_set_path {
        command.env("PATH", augmented_docker_path());
    }
    command.output().await
}

pub(crate) fn augmented_docker_path() -> String {
    let parent = std::env::var("PATH").ok();
    let home = std::env::var("HOME").ok();
    build_augmented_docker_path(parent.as_deref(), home.as_deref())
}

fn build_augmented_docker_path(parent_path: Option<&str>, home: Option<&str>) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(home) = home
        && !home.is_empty()
    {
        parts.push(format!("{home}/.docker/bin"));
    }
    for candidate in DOCKER_PATH_CANDIDATES {
        parts.push((*candidate).to_string());
    }
    if let Some(parent) = parent_path
        && !parent.is_empty()
    {
        parts.push(parent.to_string());
    }
    parts.join(":")
}

// Docker Desktop (macOS/Windows) 给容器回宿主的特殊 DNS 名。Linux 默认没有，
// 但 Linux 用户少有"宿主 loopback 跑 MinIO + 容器要访问"这种场景。
const HOST_GATEWAY_DNS: &str = "host.docker.internal";

/// 把 endpoint 里的 loopback host 改写成容器可见的宿主 gateway。
///
/// 命中条件（仅 host 部分）：`localhost` / `127.0.0.0/8` 全段 / `0.0.0.0` / IPv6 `::1`、`::`。
/// 其余原样透传（公网 IP、私网 IP、域名、无 scheme、解析失败均不改）。保留 scheme、端口、
/// path、query。
fn rewrite_endpoint_for_container(endpoint: &str) -> String {
    let Some(scheme_end) = endpoint.find("://") else {
        return endpoint.to_string();
    };
    let after_scheme = scheme_end + 3;
    let rest = &endpoint[after_scheme..];

    let (host, tail) = if let Some(stripped) = rest.strip_prefix('[') {
        // IPv6 字面量：[host]:port/path
        let Some(close) = stripped.find(']') else {
            return endpoint.to_string();
        };
        (&stripped[..close], &stripped[close + 1..])
    } else {
        let end = rest.find([':', '/']).unwrap_or(rest.len());
        (&rest[..end], &rest[end..])
    };

    if is_loopback_host(host) {
        let scheme = &endpoint[..scheme_end];
        format!("{scheme}://{HOST_GATEWAY_DNS}{tail}")
    } else {
        endpoint.to_string()
    }
}

fn is_loopback_host(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost") || host == "0.0.0.0" {
        return true;
    }
    // IPv6 loopback（含未指定地址 `::`，挂载语义上等价 loopback）
    if host == "::1" || host == "::" {
        return true;
    }
    // IPv4 127.0.0.0/8 整段
    if let Some(rest) = host.strip_prefix("127.") {
        let parts: Vec<&str> = rest.split('.').collect();
        if parts.len() == 3
            && parts
                .iter()
                .all(|p| !p.is_empty() && p.parse::<u8>().is_ok())
        {
            return true;
        }
    }
    false
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

    #[test]
    fn rewrite_endpoint_translates_localhost_with_port() {
        assert_eq!(
            rewrite_endpoint_for_container("http://localhost:9000"),
            "http://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_translates_localhost_case_insensitive() {
        assert_eq!(
            rewrite_endpoint_for_container("http://LocalHost:9000"),
            "http://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_translates_127_0_0_1() {
        assert_eq!(
            rewrite_endpoint_for_container("http://127.0.0.1:9000"),
            "http://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_translates_full_loopback_range() {
        // 127.0.0.0/8 整段都是 loopback
        assert_eq!(
            rewrite_endpoint_for_container("http://127.0.0.5:9000"),
            "http://host.docker.internal:9000"
        );
        assert_eq!(
            rewrite_endpoint_for_container("http://127.123.45.67:9000"),
            "http://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_translates_zero_zero_zero_zero() {
        assert_eq!(
            rewrite_endpoint_for_container("http://0.0.0.0:9000"),
            "http://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_translates_ipv6_loopback() {
        assert_eq!(
            rewrite_endpoint_for_container("http://[::1]:9000"),
            "http://host.docker.internal:9000"
        );
        assert_eq!(
            rewrite_endpoint_for_container("http://[::]:9000"),
            "http://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_preserves_path_and_query() {
        assert_eq!(
            rewrite_endpoint_for_container("https://localhost:9000/probe?ok=1"),
            "https://host.docker.internal:9000/probe?ok=1"
        );
        // 无端口、有 path
        assert_eq!(
            rewrite_endpoint_for_container("https://localhost/probe"),
            "https://host.docker.internal/probe"
        );
    }

    #[test]
    fn rewrite_endpoint_preserves_https_scheme() {
        assert_eq!(
            rewrite_endpoint_for_container("https://localhost:9000"),
            "https://host.docker.internal:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_passes_through_public_ip() {
        assert_eq!(
            rewrite_endpoint_for_container("http://43.136.30.29:9000"),
            "http://43.136.30.29:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_passes_through_private_lan_ip() {
        // 192.168/172.16-31/10 等私网 IP 不是 loopback，不应转译
        assert_eq!(
            rewrite_endpoint_for_container("http://192.168.1.10:9000"),
            "http://192.168.1.10:9000"
        );
        assert_eq!(
            rewrite_endpoint_for_container("http://10.0.0.5:9000"),
            "http://10.0.0.5:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_passes_through_domain_name() {
        assert_eq!(
            rewrite_endpoint_for_container("https://minio.example.com:9000/path"),
            "https://minio.example.com:9000/path"
        );
    }

    #[test]
    fn rewrite_endpoint_does_not_match_localhost_substring_in_domain() {
        // "localhost.evil.com" 不能被当成 loopback
        assert_eq!(
            rewrite_endpoint_for_container("http://localhost.evil.com:9000"),
            "http://localhost.evil.com:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_passes_through_when_scheme_missing() {
        // 没有 :// 就不知道哪儿是 host，原样透传让 rclone 自己报错
        assert_eq!(
            rewrite_endpoint_for_container("localhost:9000"),
            "localhost:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_passes_through_unclosed_ipv6_bracket() {
        // 畸形输入，原样透传
        assert_eq!(
            rewrite_endpoint_for_container("http://[::1:9000"),
            "http://[::1:9000"
        );
    }

    #[test]
    fn rewrite_endpoint_does_not_match_partial_127_octets() {
        // "1270.0.0.1" 不是 127.0.0.0/8，不应被改
        assert_eq!(
            rewrite_endpoint_for_container("http://1270.0.0.1:9000"),
            "http://1270.0.0.1:9000"
        );
        // "127.0.0" 段不全
        assert_eq!(
            rewrite_endpoint_for_container("http://127.0.0:9000"),
            "http://127.0.0:9000"
        );
    }

    #[test]
    fn build_augmented_docker_path_prepends_candidates_and_appends_parent_path() {
        let path =
            build_augmented_docker_path(Some("/usr/bin:/bin:/usr/sbin:/sbin"), Some("/Users/test"));

        assert_eq!(
            path,
            "/Users/test/.docker/bin:/usr/local/bin:/opt/homebrew/bin:\
/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        );
    }

    #[test]
    fn build_augmented_docker_path_omits_home_docker_bin_when_home_missing() {
        let path = build_augmented_docker_path(Some("/usr/bin:/bin"), None);

        assert!(!path.contains(".docker/bin"));
        assert!(path.starts_with("/usr/local/bin:"));
        assert!(path.ends_with(":/usr/bin:/bin"));
    }

    #[test]
    fn build_augmented_docker_path_omits_home_docker_bin_when_home_empty() {
        let path = build_augmented_docker_path(Some("/usr/bin"), Some(""));

        assert!(!path.contains(".docker/bin"));
    }

    #[test]
    fn build_augmented_docker_path_omits_parent_path_when_empty_or_missing() {
        let none_parent = build_augmented_docker_path(None, Some("/home/u"));
        let empty_parent = build_augmented_docker_path(Some(""), Some("/home/u"));

        let expected = "/home/u/.docker/bin:/usr/local/bin:/opt/homebrew/bin:\
/Applications/Docker.app/Contents/Resources/bin";
        assert_eq!(none_parent, expected);
        assert_eq!(empty_parent, expected);
    }

    #[tokio::test]
    async fn run_argv_with_env_injects_path_when_caller_does_not_provide_one() {
        // 直接用 /bin/sh 绝对路径作为 argv[0]，绕过 PATH 查找，
        // 只测"子进程实际收到的 $PATH 是不是 augmented 的"。
        let output = run_argv_with_env(
            &["/bin/sh".into(), "-c".into(), "printf %s \"$PATH\"".into()],
            &[],
        )
        .await
        .expect("sh runs");
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        let path = String::from_utf8(output.stdout).expect("path is utf8");
        assert!(
            path.contains("/usr/local/bin"),
            "expected augmented PATH, got: {path}"
        );
        assert!(
            path.contains("/opt/homebrew/bin"),
            "expected augmented PATH, got: {path}"
        );
    }

    #[tokio::test]
    async fn run_argv_with_env_preserves_caller_supplied_path() {
        let output = run_argv_with_env(
            &["/bin/sh".into(), "-c".into(), "printf %s \"$PATH\"".into()],
            &[("PATH".into(), "/tmp/caller-path".into())],
        )
        .await
        .expect("sh runs");
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        let path = String::from_utf8(output.stdout).expect("path is utf8");
        assert_eq!(path, "/tmp/caller-path");
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
