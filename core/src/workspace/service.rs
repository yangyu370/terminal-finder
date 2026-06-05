use crate::{
    error::ApiError,
    state::AppState,
    workspace::{
        GetStateResponse, ListDirectoryParams, ListDirectoryResponse, OpenDirectoryParams,
        OpenDirectoryResponse, WorkspaceStateResponse,
        fs::{list_directory_blocking, open_directory_blocking, workspace_root_for_directory},
        state::WorkspaceState,
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

    let workspace_root = state.workspace().state().workspace_root;
    let (workspace_root, directory, listing) = tokio::task::spawn_blocking(move || {
        let (directory, listing) = open_directory_blocking(requested_path)?;
        let workspace_root = workspace_root_for_directory(workspace_root, &directory);
        Ok::<_, ApiError>((workspace_root, directory, listing))
    })
    .await
    .map_err(|error| ApiError::BackgroundTask {
        operation: "workspace.openDirectory",
        message: error.to_string(),
    })??;

    let workspace_state = state
        .workspace()
        .set_directory_state(workspace_root, directory);
    let state = workspace_state_response(workspace_state);

    tracing::info!(
        target: LOG_TARGET,
        current_directory = %state.current_directory,
        entries = listing.entries.len(),
        "opened directory"
    );

    Ok(OpenDirectoryResponse { state, listing })
}

pub async fn list_directory(
    params: ListDirectoryParams,
) -> Result<ListDirectoryResponse, ApiError> {
    let path = params.path.clone();
    tracing::info!(
        target: LOG_TARGET,
        path = %path.to_string_lossy(),
        "listing directory"
    );

    let result = tokio::task::spawn_blocking(move || list_directory_blocking(params))
        .await
        .map_err(|error| ApiError::BackgroundTask {
            operation: "workspace.listDirectory",
            message: error.to_string(),
        })??;

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
    }
}
