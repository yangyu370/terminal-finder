use std::path::PathBuf;

use crate::{
    error::ApiError,
    state::AppState,
    vfs::{Location, local::workspace_root_for_directory},
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
        "opening directory"
    );

    let location = Location::local(requested_path.to_string_lossy().into_owned());
    let provider = state
        .providers()
        .get(&location.scheme)
        .expect("local provider is always registered");

    let (canonical_path, listing) = provider.open_directory(&location.path).await?;

    let workspace_root = state.workspace().state().workspace_root;
    let directory = PathBuf::from(&canonical_path);
    let workspace_root = workspace_root_for_directory(workspace_root, &directory);

    let workspace_state = state
        .workspace()
        .set_directory_state(workspace_root, directory);
    let state_response = workspace_state_response(workspace_state);

    tracing::info!(
        target: LOG_TARGET,
        current_directory = %state_response.current_directory,
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
        "listing directory"
    );

    let location = Location::local(path.to_string_lossy().into_owned());
    let provider = state
        .providers()
        .get(&location.scheme)
        .expect("local provider is always registered");

    let result = provider.list(&location.path).await?;

    tracing::info!(
        target: LOG_TARGET,
        path = %result.path,
        entries = result.entries.len(),
        "listed directory"
    );

    Ok(result)
}

fn workspace_state_response(state: WorkspaceState) -> WorkspaceStateResponse {
    WorkspaceStateResponse {
        workspace_root: state.workspace_root.to_string_lossy().into_owned(),
        current_directory: state.current_directory.to_string_lossy().into_owned(),
        scheme: "local".to_string(),
        connection_id: None,
    }
}
