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
            let workspace_root = state.workspace().state().workspace_root;
            let directory = PathBuf::from(&canonical_path);
            let workspace_root = workspace_root_for_directory(workspace_root, &directory);

            let workspace_state = state
                .workspace()
                .set_directory_state(workspace_root, directory);
            workspace_state_response(workspace_state)
        }
        Scheme::S3 => {
            // S3 has no canonical-path / workspace-root semantics: the
            // workspace store is for local navigation only. Report the
            // resolved prefix (which the S3 provider already normalized
            // with trailing '/') for both root + current.
            WorkspaceStateResponse {
                workspace_root: canonical_path.clone(),
                current_directory: canonical_path,
                scheme: "s3".to_string(),
                connection_id: location.connection_id.clone(),
            }
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
fn resolve_provider(
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

/// 懒构造 `S3Provider` 并缓存到 `ProviderRegistry::by_connection`。已缓存则直接返回 `Ok`。
fn ensure_provider_for_connection(
    state: &AppState,
    conn_id: &ConnectionId,
) -> Result<(), ApiError> {
    use crate::connection::{ConnectionConfig, Credential};
    use crate::vfs::s3::S3Provider;

    if state.providers().get_by_connection(conn_id).is_some() {
        return Ok(());
    }
    let entry = state
        .connections()
        .get(conn_id)
        .ok_or_else(|| ApiError::ConnectionNotFound {
            connection_id: conn_id.0.clone(),
        })?;
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
        scheme: "local".to_string(),
        connection_id: None,
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
}
