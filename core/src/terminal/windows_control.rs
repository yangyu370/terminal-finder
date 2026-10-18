//! Immutable control requests avoid Windows replace/open-file races. No stdin use.
use serde::{Deserialize, Serialize};
use std::{fs, io::Write, path::Path};
use uuid::Uuid;

#[derive(Serialize, Deserialize, Debug)]
pub(crate) struct Request {
    pub sequence: u64,
    pub target: String,
}
#[derive(Deserialize)]
pub(crate) struct Completion {
    pub sequence: u64,
    pub target: String,
    pub success: bool,
}

pub(crate) fn publish(directory: &Path, target: &str, sequence: u64) -> std::io::Result<()> {
    if target.chars().any(char::is_control) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "unsafe directory control characters",
        ));
    }
    let stem = format!("{sequence:020}-{}", Uuid::new_v4());
    let temporary = directory.join(format!("{stem}.tmp"));
    let published = directory.join(format!("{stem}.json"));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        let data = serde_json::to_vec(&Request {
            sequence,
            target: target.into(),
        })?;
        file.write_all(&data)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, &published)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result?;
    // Retain the newest request; failed removal is harmless while the shell holds
    // a file open. Never remove a request published concurrently after this one.
    for entry in fs::read_dir(directory)?.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.ends_with(".json")
            && name
                .split('-')
                .next()
                .and_then(|s| s.parse::<u64>().ok())
                .is_some_and(|old| old < sequence)
        {
            let _ = fs::remove_file(entry.path());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_control_requests_are_data_only_atomic_and_latest_wins() {
        let dir = std::env::temp_dir().join(format!("tf-win-control-{}", Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let target = "C:\\中文 space ' $() \\folder";
        publish(&dir, "C:\\old", 1).unwrap();
        publish(&dir, target, 2).unwrap();
        let files: Vec<_> = fs::read_dir(&dir).unwrap().flatten().collect();
        assert_eq!(files.len(), 1);
        let request: Request = serde_json::from_slice(&fs::read(files[0].path()).unwrap()).unwrap();
        assert_eq!((request.sequence, request.target.as_str()), (2, target));
        assert!(publish(&dir, "C:\\bad\npath", 3).is_err());
        let completion: Completion =
            serde_json::from_str(r#"{"sequence":2,"target":"x","success":false}"#).unwrap();
        assert_eq!(completion.sequence, 2);
        assert_eq!(completion.target, "x");
        assert!(!completion.success);
        fs::remove_dir_all(dir).unwrap();
    }
}
