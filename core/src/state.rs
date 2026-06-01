#[derive(Clone)]
pub struct AppState {
    pub version: &'static str,
}

impl AppState {
    pub fn new(version: &'static str) -> Self {
        Self { version }
    }
}
