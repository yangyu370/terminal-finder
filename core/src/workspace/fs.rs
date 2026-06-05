use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::{
    error::ApiError,
    workspace::{DirectoryEntry, EntryKind, ListDirectoryParams, ListDirectoryResponse},
};

pub fn open_directory_blocking(
    path: PathBuf,
) -> Result<(PathBuf, ListDirectoryResponse), ApiError> {
    let directory = canonical_directory_path(path)?;
    let listing = list_directory_blocking(ListDirectoryParams {
        path: directory.clone(),
    })?;

    Ok((directory, listing))
}

pub fn workspace_root_for_directory(workspace_root: PathBuf, directory: &Path) -> PathBuf {
    workspace_root
        .canonicalize()
        .ok()
        .filter(|root| directory.starts_with(root))
        .unwrap_or_else(|| directory.to_path_buf())
}

pub fn list_directory_blocking(
    params: ListDirectoryParams,
) -> Result<ListDirectoryResponse, ApiError> {
    let metadata = fs::metadata(&params.path).map_err(|source| ApiError::FileSystemRead {
        path: params.path.clone(),
        source,
    })?;

    if !metadata.is_dir() {
        return Err(ApiError::NotDirectory(params.path));
    }

    let mut entries = fs::read_dir(&params.path)
        .map_err(|source| ApiError::FileSystemRead {
            path: params.path.clone(),
            source,
        })?
        .map(|entry| directory_entry(entry, &params.path))
        .collect::<Result<Vec<_>, _>>()?;

    entries.sort_by(|left, right| {
        right
            .is_directory
            .cmp(&left.is_directory)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then_with(|| left.name.cmp(&right.name))
    });

    Ok(ListDirectoryResponse {
        path: params.path.to_string_lossy().into_owned(),
        entries,
    })
}

fn canonical_directory_path(path: PathBuf) -> Result<PathBuf, ApiError> {
    let metadata = fs::metadata(&path).map_err(|source| ApiError::FileSystemRead {
        path: path.clone(),
        source,
    })?;

    if !metadata.is_dir() {
        return Err(ApiError::NotDirectory(path));
    }

    path.canonicalize()
        .map_err(|source| ApiError::FileSystemRead { path, source })
}

fn directory_entry(
    entry: Result<fs::DirEntry, std::io::Error>,
    parent_path: &Path,
) -> Result<DirectoryEntry, ApiError> {
    let entry = entry.map_err(|source| ApiError::FileSystemRead {
        path: parent_path.to_path_buf(),
        source,
    })?;
    let path = entry.path();
    let link_metadata = fs::symlink_metadata(&path).map_err(|source| ApiError::FileSystemRead {
        path: path.clone(),
        source,
    })?;
    let file_type = link_metadata.file_type();
    let target_metadata = fs::metadata(&path).ok();
    let is_directory = target_metadata
        .as_ref()
        .map(|metadata| metadata.is_dir())
        .unwrap_or(false);
    let kind = if file_type.is_symlink() {
        EntryKind::Symlink
    } else if link_metadata.is_dir() {
        EntryKind::Directory
    } else if link_metadata.is_file() {
        EntryKind::File
    } else {
        EntryKind::Other
    };

    Ok(DirectoryEntry {
        name: entry.file_name().to_string_lossy().into_owned(),
        path: path.to_string_lossy().into_owned(),
        kind,
        is_directory,
        size: link_metadata.is_file().then_some(link_metadata.len()),
        modified_at: link_metadata
            .modified()
            .ok()
            .and_then(system_time_to_utc_iso),
    })
}

fn system_time_to_utc_iso(time: SystemTime) -> Option<String> {
    let duration = time.duration_since(UNIX_EPOCH).ok()?;
    let (year, month, day, hour, minute, second) = unix_duration_to_utc_parts(duration);
    Some(format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z"
    ))
}

fn unix_duration_to_utc_parts(duration: Duration) -> (i64, u32, u32, u32, u32, u32) {
    let total_seconds = duration.as_secs() as i64;
    let days = total_seconds / 86_400;
    let seconds_of_day = total_seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    let hour = (seconds_of_day / 3_600) as u32;
    let minute = ((seconds_of_day % 3_600) / 60) as u32;
    let second = (seconds_of_day % 60) as u32;

    (year, month, day, hour, minute, second)
}

fn civil_from_days(days_since_unix_epoch: i64) -> (i64, u32, u32) {
    let z = days_since_unix_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    let year = year + if month <= 2 { 1 } else { 0 };

    (year, month as u32, day as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_directory_canonicalizes_path_and_returns_listing() {
        let test_path = std::env::temp_dir().join(format!(
            "terminal-finder-open-directory-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time is after unix epoch")
                .as_nanos()
        ));

        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(test_path.join("child")).expect("create child directory");
        let expected_directory = test_path
            .canonicalize()
            .expect("canonicalize test directory");

        let (directory, listing) =
            open_directory_blocking(test_path.clone()).expect("open test directory");

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(directory, expected_directory);
        assert_eq!(listing.path, directory.to_string_lossy());
        assert_eq!(listing.entries.len(), 1);
        assert_eq!(listing.entries[0].name, "child");
    }

    #[test]
    fn keeps_canonical_workspace_root_for_directory_inside_it() {
        let test_path = unique_test_path("workspace-root-inside");
        let child_path = test_path.join("child");
        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(&child_path).expect("create child directory");

        let expected_root = test_path.canonicalize().expect("canonicalize root");
        let directory = child_path.canonicalize().expect("canonicalize child");
        let workspace_root = workspace_root_for_directory(test_path.clone(), &directory);

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(workspace_root, expected_root);
    }

    #[test]
    fn switches_workspace_root_for_directory_outside_it() {
        let test_path = unique_test_path("workspace-root-outside");
        let first_root = test_path.join("first");
        let second_root = test_path.join("second");
        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(&first_root).expect("create first root");
        fs::create_dir(&second_root).expect("create second root");

        let directory = second_root
            .canonicalize()
            .expect("canonicalize second root");
        let workspace_root = workspace_root_for_directory(first_root, &directory);

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(workspace_root, directory);
    }

    #[test]
    fn switches_workspace_root_when_opening_its_ancestor() {
        let test_path = unique_test_path("workspace-root-ancestor");
        let child_path = test_path.join("child");
        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(&child_path).expect("create child directory");

        let directory = test_path.canonicalize().expect("canonicalize ancestor");
        let workspace_root = workspace_root_for_directory(child_path, &directory);

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(workspace_root, directory);
    }

    #[test]
    fn switches_workspace_root_when_current_root_is_missing() {
        let test_path = unique_test_path("workspace-root-missing");
        fs::create_dir(&test_path).expect("create test directory");

        let directory = test_path.canonicalize().expect("canonicalize directory");
        let workspace_root = workspace_root_for_directory(test_path.join("missing"), &directory);

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(workspace_root, directory);
    }

    #[test]
    fn lists_directory_entries_with_directories_first() {
        let test_path = std::env::temp_dir().join(format!(
            "terminal-finder-list-directory-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time is after unix epoch")
                .as_nanos()
        ));

        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(test_path.join("Folder")).expect("create child directory");
        fs::write(test_path.join("file.txt"), b"hello").expect("create child file");

        let listing = list_directory_blocking(ListDirectoryParams {
            path: test_path.clone(),
        })
        .expect("list test directory");

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(listing.path, test_path.to_string_lossy());
        assert_eq!(listing.entries.len(), 2);
        assert_eq!(listing.entries[0].name, "Folder");
        assert!(listing.entries[0].is_directory);
        assert_eq!(listing.entries[1].name, "file.txt");
        assert_eq!(listing.entries[1].size, Some(5));
    }

    #[cfg(unix)]
    #[test]
    fn marks_symlinked_directories_as_openable_symlinks() {
        let test_path = std::env::temp_dir().join(format!(
            "terminal-finder-symlink-directory-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time is after unix epoch")
                .as_nanos()
        ));

        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(test_path.join("Target")).expect("create symlink target directory");
        std::os::unix::fs::symlink(test_path.join("Target"), test_path.join("LinkedTarget"))
            .expect("create directory symlink");

        let listing = list_directory_blocking(ListDirectoryParams {
            path: test_path.clone(),
        })
        .expect("list test directory");

        fs::remove_dir_all(&test_path).expect("remove test directory");

        let entry = listing
            .entries
            .iter()
            .find(|entry| entry.name == "LinkedTarget")
            .expect("listing contains symlinked directory");

        assert_eq!(entry.kind, EntryKind::Symlink);
        assert!(entry.is_directory);
    }

    #[test]
    fn formats_unix_epoch_as_utc_iso() {
        assert_eq!(
            system_time_to_utc_iso(UNIX_EPOCH).as_deref(),
            Some("1970-01-01T00:00:00Z")
        );
    }

    #[test]
    fn formats_recent_utc_date() {
        let time = UNIX_EPOCH + Duration::from_secs(1_780_300_800);

        assert_eq!(
            system_time_to_utc_iso(time).as_deref(),
            Some("2026-06-01T08:00:00Z")
        );
    }

    fn unique_test_path(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "terminal-finder-{label}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time is after unix epoch")
                .as_nanos()
        ))
    }
}
