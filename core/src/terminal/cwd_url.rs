//! Platform path part of local OSC 7 URLs. Authority validation stays at callers.
#[cfg(any(windows, test))]
pub(crate) fn windows_path(path: &str) -> Result<String, String> {
    if path.chars().any(char::is_control) || path.contains('\\') {
        return Err("invalid Windows directory URL path".into());
    }
    let bytes = path.as_bytes();
    if bytes.len() >= 4
        && bytes[0] == b'/'
        && bytes[1].is_ascii_alphabetic()
        && bytes[2] == b':'
        && bytes[3] == b'/'
    {
        return Ok(path[1..].replace('/', "\\"));
    }
    if let Some(unc) = path.strip_prefix("//") {
        let mut parts = unc.split('/');
        let server = parts.next().unwrap_or_default();
        let share = parts.next().unwrap_or_default();
        if !server.is_empty()
            && !share.is_empty()
            && ![".", "..", "?"].contains(&server)
            && ![".", ".."].contains(&share)
            && !server.contains(':')
            && !share.contains(':')
        {
            return Ok(path.replace('/', "\\"));
        }
    }
    Err("Windows directory URL must contain an absolute drive or UNC path".into())
}

pub(crate) fn native_path(path: String) -> Result<String, String> {
    #[cfg(windows)]
    {
        windows_path(&path)
    }
    #[cfg(not(windows))]
    {
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_drive_and_unc_url_paths_are_native_absolute_paths() {
        assert_eq!(
            windows_path("/C:/work/中文 space ' quote").unwrap(),
            "C:\\work\\中文 space ' quote"
        );
        assert_eq!(
            windows_path("//server/share/folder").unwrap(),
            "\\\\server\\share\\folder"
        );
        for bad in [
            "relative",
            "/tmp/unix",
            "/C:relative",
            "//server",
            "/C:/bad\npath",
            "//?/C:/device",
        ] {
            assert!(windows_path(bad).is_err(), "accepted {bad:?}");
        }
    }
}
