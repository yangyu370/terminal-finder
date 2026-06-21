use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::{
    connection::ConnectionId,
    error::ApiError,
    state::AppState,
    vfs::{Location, Scheme, VfsProvider, local::workspace_root_for_directory},
    workspace::{
        GetStateResponse, ListDirectoryParams, ListDirectoryResponse, OpenDirectoryParams,
        OpenDirectoryResponse, WorkspaceStateResponse, state::WorkspaceState,
    },
};

const LOG_TARGET: &str = "workspace";

pub fn get_state(state: &AppState) -> GetStateResponse {
    GetStateResponse {
        state: workspace_state_response(state.workspace().state()),
    }
}

pub async fn open_directory(
    state: &AppState,
    params: OpenDirectoryParams,
) -> Result<OpenDirectoryResponse, ApiError> {
    let requested_path = params.path.clone();
    tracing::info!(
        target: LOG_TARGET,
        path = %requested_path.to_string_lossy(),
        connection_id = params.connection_id.as_deref().unwrap_or(""),
        "opening directory"
    );

    let (location, provider) =
        resolve_provider(state, params.connection_id.as_deref(), &requested_path)?;

    let (canonical_path, listing) = provider.open_directory(&location.path).await?;

    let state_response = match location.scheme {
        Scheme::Local => {
            let existing = state.workspace().state();
            let directory = PathBuf::from(&canonical_path);
            // 切回 local 时，旧 workspace_root 可能是 S3 前缀（被 PathBuf 包装的字符串）。
            // `workspace_root_for_directory` 内部 `canonicalize` 会把这类字符串按 CWD
            // 解释为相对路径——如果碰巧命中一个真实本地目录，旧 S3 prefix 就会"继承"
            // 进 local workspace_root，违反 scheme 边界。
            // 因此只有上一次也是 local 时才沿用 Phase 0 的 root 保持逻辑；否则重置。
            let workspace_root = if existing.scheme == "local" {
                workspace_root_for_directory(existing.workspace_root, &directory)
            } else {
                directory.clone()
            };

            let workspace_state = state.workspace().set_directory_state(
                workspace_root,
                directory,
                "local".to_string(),
                None,
            );
            workspace_state_response(workspace_state)
        }
        Scheme::S3 => {
            // S3 has no OS-level canonical-path / workspace-root semantics;
            // both root and current report the resolved prefix (which the
            // S3 provider already normalized with trailing '/' for non-empty
            // prefixes). The store still owns the latest location so a
            // follow-up workspace.getState reflects the S3 dispatch.
            let prefix = PathBuf::from(&canonical_path);
            let workspace_state = state.workspace().set_directory_state(
                prefix.clone(),
                prefix,
                "s3".to_string(),
                location.connection_id.clone(),
            );
            workspace_state_response(workspace_state)
        }
    };

    tracing::info!(
        target: LOG_TARGET,
        current_directory = %state_response.current_directory,
        scheme = %state_response.scheme,
        entries = listing.entries.len(),
        "opened directory"
    );

    Ok(OpenDirectoryResponse {
        state: state_response,
        listing,
    })
}

pub async fn list_directory(
    state: &AppState,
    params: ListDirectoryParams,
) -> Result<ListDirectoryResponse, ApiError> {
    let path = params.path.clone();
    tracing::info!(
        target: LOG_TARGET,
        path = %path.to_string_lossy(),
        connection_id = params.connection_id.as_deref().unwrap_or(""),
        "listing directory"
    );

    let (location, provider) = resolve_provider(state, params.connection_id.as_deref(), &path)?;

    let result = provider.list(&location.path).await?;

    tracing::info!(
        target: LOG_TARGET,
        path = %result.path,
        scheme = ?location.scheme,
        entries = result.entries.len(),
        "listed directory"
    );

    Ok(result)
}

/// 解析请求落到哪个 provider。
///
/// - `connection_id == None` → Phase 0 LocalFsProvider，不触碰 `ConnectionRegistry`。
/// - `connection_id == Some(id)` → 在 `ConnectionRegistry` 找到对应配置后，按需懒构造 `S3Provider`
///   并缓存在 `ProviderRegistry::by_connection`；未注册的 id 直接 `ConnectionNotFound`。
///
/// `pub(crate)` so FFI helpers (`download_file`) can reuse the same
/// dispatch rules without duplicating the cache-priming logic.
pub(crate) fn resolve_provider(
    state: &AppState,
    connection_id: Option<&str>,
    path: &Path,
) -> Result<(Location, Arc<dyn VfsProvider>), ApiError> {
    let path_string = path.to_string_lossy().into_owned();
    match connection_id {
        None => {
            let location = Location::local(path_string);
            let provider = state
                .providers()
                .get(&Scheme::Local)
                .expect("local provider is always registered");
            Ok((location, provider))
        }
        Some(id) => {
            let conn_id = ConnectionId(id.to_string());
            ensure_provider_for_connection(state, &conn_id)?;
            let provider = state
                .providers()
                .get_by_connection(&conn_id)
                .ok_or_else(|| ApiError::ConnectionNotFound {
                    connection_id: id.to_string(),
                })?;
            let location = Location {
                scheme: Scheme::S3,
                connection_id: Some(id.to_string()),
                path: path_string,
            };
            Ok((location, provider))
        }
    }
}

/// 懒构造 `S3Provider` 并缓存到 `ProviderRegistry::by_connection`。
///
/// 重要：必须先到 `ConnectionRegistry` 验证条目仍存在，再看 provider 缓存。
/// 否则 `connection.remove` 之后 cache 还没被清的瞬间，旧 `S3Provider`（含旧凭据
/// 的 OpenDAL `Operator`）会被复用，违反 "remove 后该 connection_id 失效" 契约。
/// FFI 层的 `connection_remove` 也会同步清缓存，这里是 defense-in-depth。
fn ensure_provider_for_connection(
    state: &AppState,
    conn_id: &ConnectionId,
) -> Result<(), ApiError> {
    use crate::connection::{ConnectionConfig, Credential};
    use crate::vfs::s3::S3Provider;

    let entry = state
        .connections()
        .get(conn_id)
        .ok_or_else(|| ApiError::ConnectionNotFound {
            connection_id: conn_id.0.clone(),
        })?;
    if state.providers().get_by_connection(conn_id).is_some() {
        return Ok(());
    }
    let ConnectionConfig::S3(cfg) = &entry.config;
    let Credential::S3(cred) = &entry.credential;
    let provider = S3Provider::new(conn_id.clone(), cfg, cred)?;
    state.providers().register_connection(conn_id, provider);
    Ok(())
}

fn workspace_state_response(state: WorkspaceState) -> WorkspaceStateResponse {
    WorkspaceStateResponse {
        workspace_root: state.workspace_root.to_string_lossy().into_owned(),
        current_directory: state.current_directory.to_string_lossy().into_owned(),
        scheme: state.scheme,
        connection_id: state.connection_id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::{ConnectionConfig, Credential, S3ConnectionConfig, S3Credential};

    #[tokio::test]
    async fn open_directory_nil_connection_behaves_as_local() {
        let app_state = AppState::new("test");
        let temp = std::env::temp_dir();
        let response = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: temp.clone(),
                connection_id: None,
            },
        )
        .await
        .expect("opening a real temp directory must succeed");

        assert_eq!(response.state.scheme, "local");
        assert!(response.state.connection_id.is_none());
    }

    #[tokio::test]
    async fn open_directory_with_invalid_connection_id_returns_error() {
        let app_state = AppState::new("test");
        let err = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: std::path::PathBuf::from("/"),
                connection_id: Some("nonexistent".into()),
            },
        )
        .await
        .expect_err("unknown connection id must fail dispatch");

        assert_eq!(err.code(), "connection_not_found");
    }

    #[tokio::test]
    async fn open_directory_with_connection_id_dispatches_to_s3() {
        // Does NOT require network access — the test asserts dispatch
        // reaches S3Provider. The S3 call may then succeed or fail on
        // an offline endpoint, but the failure code must not be
        // `connection_not_found` (that would mean we never reached S3).
        let app_state = AppState::new("test");
        let id = app_state.connections().create(
            ConnectionConfig::S3(S3ConnectionConfig {
                display_name: "test".into(),
                endpoint: "http://127.0.0.1:1".into(),
                region: "us-east-1".into(),
                bucket: "x".into(),
                base_prefix: String::new(),
                path_style: true,
            }),
            Credential::S3(S3Credential {
                access_key_id: "x".into(),
                secret_access_key: "x".into(),
            }),
        );

        let result = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: std::path::PathBuf::from(""),
                connection_id: Some(id.0.clone()),
            },
        )
        .await;

        if let Err(err) = result {
            assert_ne!(
                err.code(),
                "connection_not_found",
                "S3 dispatch must reach the provider, not bail at lookup"
            );
        }
    }

    #[tokio::test]
    async fn get_state_reflects_local_open_directory() {
        // After opening a local directory, get_state must report scheme:"local"
        // and connection_id:None — the local branch is the Phase 0 baseline.
        let app_state = AppState::new("test");
        let temp = std::env::temp_dir();
        let _ = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: temp.clone(),
                connection_id: None,
            },
        )
        .await
        .expect("open temp dir");

        let snapshot = get_state(&app_state).state;
        assert_eq!(snapshot.scheme, "local");
        assert!(snapshot.connection_id.is_none());
    }

    #[tokio::test]
    async fn get_state_reflects_s3_open_directory_when_dispatch_succeeds() {
        // C2 regression guard: opening an S3 connection must update the
        // WorkspaceStore so that workspace.getState reflects the S3 location.
        // We can't rely on a network listing, so we drive WorkspaceStore
        // directly via the same code path open_directory uses on the S3 branch
        // (set_directory_state with scheme:"s3"). The assertion is that
        // workspace_state_response no longer hard-codes scheme/connection_id.
        let app_state = AppState::new("test");

        let _ = app_state.workspace().set_directory_state(
            std::path::PathBuf::from("conn-prefix/"),
            std::path::PathBuf::from("conn-prefix/"),
            "s3".to_string(),
            Some("conn-id".to_string()),
        );

        let snapshot = get_state(&app_state).state;
        assert_eq!(snapshot.scheme, "s3");
        assert_eq!(snapshot.connection_id.as_deref(), Some("conn-id"));
        assert_eq!(snapshot.current_directory, "conn-prefix/");
    }

    #[tokio::test]
    async fn local_open_after_s3_resets_workspace_root_to_opened_directory() {
        // Regression guard for the post-fix-2 review finding: when the previous
        // navigation was S3, the stored workspace_root is an S3-prefix string
        // wrapped in PathBuf. Feeding it into workspace_root_for_directory lets
        // canonicalize() interpret it as a relative local path. If the CWD
        // contains a directory of the same name, the S3 prefix would silently
        // become the new local workspace_root.
        //
        // We deterministically trigger that confusion by reusing the system temp
        // dir as the fake S3 prefix and opening a real subdirectory of it.
        let app_state = AppState::new("test");
        let outer = std::env::temp_dir();
        let inner = outer.join(format!(
            "tf_local_after_s3_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&inner).expect("create inner test dir");

        // Pretend the previous open was S3 with a prefix that happens to be a
        // valid local absolute path (the outer temp dir).
        let _ = app_state.workspace().set_directory_state(
            outer.clone(),
            outer.clone(),
            "s3".to_string(),
            Some("conn-id".to_string()),
        );

        let response = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: inner.clone(),
                connection_id: None,
            },
        )
        .await
        .expect("opening a real local directory must succeed");

        let canonical_inner = inner.canonicalize().expect("canonicalize inner dir");
        let _ = std::fs::remove_dir(&inner);

        assert_eq!(response.state.scheme, "local");
        assert!(response.state.connection_id.is_none());
        assert_eq!(
            std::path::PathBuf::from(&response.state.workspace_root),
            canonical_inner,
            "switching from S3 back to local must reset workspace_root to the opened directory, not inherit the prior S3 prefix as a local path"
        );
    }

    #[tokio::test]
    async fn dispatch_refuses_stale_provider_after_connection_removed() {
        // Regression guard for the C1 (PR5 self-review) fix: even when a
        // caller only removes the entry from ConnectionRegistry but forgets
        // to clear ProviderRegistry::by_connection (FFI's defense-in-depth),
        // the service layer must NOT route through the cached S3Provider.
        let app_state = AppState::new("test");
        let id = app_state.connections().create(
            ConnectionConfig::S3(S3ConnectionConfig {
                display_name: "test".into(),
                endpoint: "http://127.0.0.1:1".into(),
                region: "us-east-1".into(),
                bucket: "x".into(),
                base_prefix: String::new(),
                path_style: true,
            }),
            Credential::S3(S3Credential {
                access_key_id: "x".into(),
                secret_access_key: "x".into(),
            }),
        );

        // Prime the cache via a first dispatch attempt (network failure is fine).
        let _ = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: std::path::PathBuf::from(""),
                connection_id: Some(id.0.clone()),
            },
        )
        .await;
        assert!(
            app_state.providers().get_by_connection(&id).is_some(),
            "first dispatch must cache an S3Provider"
        );

        // Remove ONLY from ConnectionRegistry — leave the stale provider entry
        // in place to simulate a caller that bypassed the FFI cleanup.
        assert!(app_state.connections().remove(&id));

        let err = open_directory(
            &app_state,
            OpenDirectoryParams {
                path: std::path::PathBuf::from(""),
                connection_id: Some(id.0.clone()),
            },
        )
        .await
        .expect_err("removed connection id must not route via stale cache");
        assert_eq!(err.code(), "connection_not_found");
    }
}
