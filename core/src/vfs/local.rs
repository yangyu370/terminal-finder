//! 本地文件系统 provider。
//!
//! 从 `workspace/fs.rs` 整体搬入，函数逻辑一字不动；新增 `LocalFsProvider` 实现 `VfsProvider`。
//! `spawn_blocking` 的职责从 `workspace/service.rs` 下沉到这里——因为 local 需要它，
//! 而 S3Provider 等原生 async provider 不需要；调用者只看到 async 接口。

use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::{
    error::ApiError,
    workspace::{DirectoryEntry, EntryKind, ListDirectoryResponse},
};

pub(crate) fn open_directory_blocking(
    path: PathBuf,
) -> Result<(PathBuf, ListDirectoryResponse), ApiError> {
    let directory = canonical_directory_path(path)?;
    let listing = list_directory_blocking(directory.clone())?;

    Ok((directory, listing))
}

pub(crate) fn workspace_root_for_directory(workspace_root: PathBuf, directory: &Path) -> PathBuf {
    workspace_root
        .canonicalize()
        .ok()
        .filter(|root| directory.starts_with(root))
        .unwrap_or_else(|| directory.to_path_buf())
}

/// Stat 单一路径，复用与 list_directory_blocking 同样的 symlink/dir/file/other 判定逻辑。
pub(crate) fn stat_blocking(path: PathBuf) -> Result<DirectoryEntry, ApiError> {
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

    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned());

    Ok(DirectoryEntry {
        name,
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

pub(crate) fn list_directory_blocking(path: PathBuf) -> Result<ListDirectoryResponse, ApiError> {
    let metadata = fs::metadata(&path).map_err(|source| ApiError::FileSystemRead {
        path: path.clone(),
        source,
    })?;

    if !metadata.is_dir() {
        return Err(ApiError::NotDirectory(path));
    }

    let mut entries = fs::read_dir(&path)
        .map_err(|source| ApiError::FileSystemRead {
            path: path.clone(),
            source,
        })?
        .map(|entry| directory_entry(entry, &path))
        .collect::<Result<Vec<_>, _>>()?;

    entries.sort_by(|left, right| {
        right
            .is_directory
            .cmp(&left.is_directory)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then_with(|| left.name.cmp(&right.name))
    });

    Ok(ListDirectoryResponse {
        path: path.to_string_lossy().into_owned(),
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

pub(crate) fn system_time_to_utc_iso(time: SystemTime) -> Option<String> {
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

/// 本地文件系统 provider。在 `spawn_blocking` 中执行阻塞 FS 调用，对外暴露 async 接口。
pub struct LocalFsProvider;

#[async_trait::async_trait]
impl crate::vfs::VfsProvider for LocalFsProvider {
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError> {
        let path = PathBuf::from(path);
        tokio::task::spawn_blocking(move || list_directory_blocking(path))
            .await
            .map_err(|e| ApiError::BackgroundTask {
                operation: "vfs.local.list",
                message: e.to_string(),
            })?
    }

    async fn open_directory(
        &self,
        path: &str,
    ) -> Result<(String, ListDirectoryResponse), ApiError> {
        let path_buf = PathBuf::from(path);
        tokio::task::spawn_blocking(move || {
            let (canonical, listing) = open_directory_blocking(path_buf)?;
            Ok::<_, ApiError>((canonical.to_string_lossy().into_owned(), listing))
        })
        .await
        .map_err(|e| ApiError::BackgroundTask {
            operation: "vfs.local.open_directory",
            message: e.to_string(),
        })?
    }

    async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError> {
        let path_buf = PathBuf::from(path);
        tokio::task::spawn_blocking(move || stat_blocking(path_buf))
            .await
            .map_err(|e| ApiError::BackgroundTask {
                operation: "vfs.local.stat",
                message: e.to_string(),
            })?
    }

    async fn read(&self, path: &str) -> Result<Vec<u8>, ApiError> {
        let path_buf = PathBuf::from(path);
        let path_for_meta = path_buf.clone();
        // 先在 spawn_blocking 内拿 metadata：避免主线程拒绝 51MB 这种轻判定也阻塞，
        // 且让 metadata 失败与 read 失败共享同一条 spawn_blocking 错误链。
        let metadata = tokio::task::spawn_blocking(move || fs::metadata(&path_for_meta))
            .await
            .map_err(|e| ApiError::BackgroundTask {
                operation: "vfs.local.read",
                message: e.to_string(),
            })?
            .map_err(|source| ApiError::FileSystemRead {
                path: path_buf.clone(),
                source,
            })?;

        if metadata.len() > crate::vfs::MAX_INLINE_READ_BYTES {
            return Err(ApiError::ProviderError {
                operation: "vfs.local.read",
                message: format!(
                    "file too large for inline read: {} bytes (limit {} bytes)",
                    metadata.len(),
                    crate::vfs::MAX_INLINE_READ_BYTES
                ),
            });
        }

        let path_for_read = path_buf.clone();
        tokio::task::spawn_blocking(move || fs::read(&path_for_read))
            .await
            .map_err(|e| ApiError::BackgroundTask {
                operation: "vfs.local.read",
                message: e.to_string(),
            })?
            .map_err(|source| ApiError::FileSystemRead {
                path: path_buf,
                source,
            })
    }

    fn capabilities(&self) -> crate::vfs::ProviderCaps {
        crate::vfs::ProviderCaps {
            can_rename: true,
            can_symlink: true,
            can_write: true,
            has_native_directories: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vfs::VfsProvider;

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

        let listing = list_directory_blocking(test_path.clone()).expect("list test directory");

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

        let listing = list_directory_blocking(test_path.clone()).expect("list test directory");

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

    #[tokio::test]
    async fn local_stat_returns_entry_for_file() {
        use std::io::Write;
        let test_path = std::env::temp_dir().join(format!(
            "terminal-finder-local-stat-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut f = std::fs::File::create(&test_path).expect("create test file");
        f.write_all(b"hello").expect("write content");

        let provider = LocalFsProvider;
        let entry = provider
            .stat(&test_path.to_string_lossy())
            .await
            .expect("stat");

        std::fs::remove_file(&test_path).expect("cleanup");

        assert!(!entry.is_directory);
        assert_eq!(entry.size, Some(5));
        assert_eq!(entry.kind, EntryKind::File);
    }

    #[tokio::test]
    async fn provider_dispatch_list_matches_direct_call() {
        // 验证：通过 LocalFsProvider trait 方法 list 的结果，与直接调 list_directory_blocking 一致。
        let test_path = std::env::temp_dir().join(format!(
            "terminal-finder-provider-dispatch-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time is after unix epoch")
                .as_nanos()
        ));

        fs::create_dir(&test_path).expect("create test directory");
        fs::create_dir(test_path.join("alpha")).expect("create child directory");
        fs::write(test_path.join("beta.txt"), b"data").expect("create child file");

        let provider = LocalFsProvider;
        let via_provider = provider
            .list(&test_path.to_string_lossy())
            .await
            .expect("provider lists directory");
        let via_direct = list_directory_blocking(test_path.clone()).expect("direct list works");

        fs::remove_dir_all(&test_path).expect("remove test directory");

        assert_eq!(via_provider.path, via_direct.path);
        assert_eq!(via_provider.entries.len(), via_direct.entries.len());
        for (p, d) in via_provider.entries.iter().zip(via_direct.entries.iter()) {
            assert_eq!(p.name, d.name);
            assert_eq!(p.path, d.path);
            assert_eq!(p.is_directory, d.is_directory);
            assert_eq!(p.size, d.size);
        }
    }

    #[tokio::test]
    async fn local_read_returns_file_bytes() {
        let path = unique_test_path("local-read-roundtrip");
        fs::write(&path, b"hello-world").expect("write file");

        let provider = LocalFsProvider;
        let data = provider
            .read(&path.to_string_lossy())
            .await
            .expect("read returns bytes");

        fs::remove_file(&path).expect("cleanup");
        assert_eq!(data, b"hello-world");
    }

    #[tokio::test]
    async fn local_read_rejects_files_above_limit() {
        let path = unique_test_path("local-read-oversize");
        // Just over the 50 MiB cap so we exercise the size guard without
        // actually round-tripping through fs::read.
        let oversize = (crate::vfs::MAX_INLINE_READ_BYTES as usize) + 1;
        fs::write(&path, vec![0u8; oversize]).expect("write oversize file");

        let provider = LocalFsProvider;
        let err = provider
            .read(&path.to_string_lossy())
            .await
            .expect_err("oversize must error");

        fs::remove_file(&path).expect("cleanup");
        assert_eq!(err.code(), "provider_error");
    }
}
