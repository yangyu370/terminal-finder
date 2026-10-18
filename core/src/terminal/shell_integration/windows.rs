use crate::terminal::windows_control::{self, Completion};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

#[derive(Debug, Clone)]
pub struct ShellIntegration {
    inner: Arc<Inner>,
}
#[derive(Debug)]
struct Inner {
    dir: PathBuf,
    sequence: AtomicU64,
    reported_error: AtomicU64,
}
pub type ShellIntegrationError = std::io::Error;

impl ShellIntegration {
    pub fn create() -> Result<Self, ShellIntegrationError> {
        // The per-user temp directory supplies inherited Windows access controls.
        let dir =
            std::env::temp_dir().join(format!("terminal-finder-shell-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir)?;
        let result = (|| {
            fs::create_dir(dir.join("requests"))?;
            fs::write(dir.join("bootstrap.ps1"), include_str!("powershell.ps1"))
        })();
        if let Err(error) = result {
            let _ = fs::remove_dir_all(&dir);
            return Err(error);
        }
        Ok(Self {
            inner: Arc::new(Inner {
                dir,
                sequence: AtomicU64::new(0),
                reported_error: AtomicU64::new(0),
            }),
        })
    }
    pub fn dir(&self) -> &Path {
        &self.inner.dir
    }
    pub fn request_file(&self) -> PathBuf {
        self.inner.dir.join("requests")
    }
    pub fn startup_script(&self) -> PathBuf {
        self.inner.dir.join("bootstrap.ps1")
    }
    pub fn write_cd_request(&self, target: &str) -> Result<(), ShellIntegrationError> {
        if let Ok(data) = fs::read(self.inner.dir.join("completion.json")) {
            if let Ok(done) = serde_json::from_slice::<Completion>(&data) {
                if done.target == target
                    && !done.success
                    && done.sequence
                        > self
                            .inner
                            .reported_error
                            .fetch_max(done.sequence, Ordering::SeqCst)
                {
                    return Err(std::io::Error::other(
                        "PowerShell could not change to the requested directory",
                    ));
                }
            }
        }
        let sequence = self.inner.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        windows_control::publish(&self.request_file(), target, sequence)
    }
}
impl Drop for Inner {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub fn percent_encode_path(path: &str) -> String {
    let mut out = String::new();
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_shell_bootstrap_and_failed_completion_allow_explicit_retry() {
        let integration = ShellIntegration::create().unwrap();
        let dir = integration.dir().to_owned();
        assert!(integration.startup_script().is_file());
        assert!(integration.request_file().is_dir());
        integration.write_cd_request("C:\\first").unwrap();
        fs::write(
            dir.join("completion.json"),
            r#"{"sequence":1,"target":"C:\\first","success":false}"#,
        )
        .unwrap();
        assert!(integration.write_cd_request("C:\\first").is_err());
        integration.write_cd_request("C:\\first").unwrap();
        drop(integration);
        assert!(!dir.exists());
    }
}
