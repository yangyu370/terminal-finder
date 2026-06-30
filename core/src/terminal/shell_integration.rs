use std::{
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct ShellIntegration {
    inner: Arc<ShellIntegrationInner>,
}

#[derive(Debug)]
struct ShellIntegrationInner {
    dir: PathBuf,
    request_file: PathBuf,
    wake_fifo: PathBuf,
}

#[derive(Debug, Error)]
pub enum ShellIntegrationError {
    #[error("terminal shell integration filesystem error: {0}")]
    Io(#[from] std::io::Error),
    #[error("target path contains unsafe control characters")]
    UnsafeTargetPath,
    #[error("terminal cd request file is a symlink")]
    SymlinkRequestFile,
}

impl ShellIntegration {
    pub fn create() -> Result<Self, ShellIntegrationError> {
        let dir = create_private_session_dir()?;
        let request_file = dir.join("cd-request");
        let wake_fifo = dir.join("cd-wake");
        create_private_file(&request_file, "")?;
        create_private_fifo(&wake_fifo)?;
        write_startup_wrappers(&dir)?;

        Ok(Self {
            inner: Arc::new(ShellIntegrationInner {
                dir,
                request_file,
                wake_fifo,
            }),
        })
    }

    pub fn dir(&self) -> &Path {
        &self.inner.dir
    }

    pub fn request_file(&self) -> &Path {
        &self.inner.request_file
    }

    pub fn wake_fifo(&self) -> &Path {
        &self.inner.wake_fifo
    }

    pub fn write_cd_request(&self, target: &str) -> Result<(), ShellIntegrationError> {
        reject_unsafe_target(target)?;
        reject_request_symlink(&self.inner.request_file)?;

        let tmp = self
            .inner
            .dir
            .join(format!("cd-request.{}.tmp", Uuid::new_v4()));
        {
            let mut file = open_private_new_file(&tmp)?;
            file.write_all(target.as_bytes())?;
            file.sync_all()?;
        }
        fs::rename(&tmp, &self.inner.request_file)?;
        #[cfg(unix)]
        fs::set_permissions(&self.inner.request_file, fs::Permissions::from_mode(0o600))?;

        if let Ok(parent) = File::open(&self.inner.dir) {
            let _ = parent.sync_all();
        }

        self.wake_cd_request();

        Ok(())
    }

    fn wake_cd_request(&self) {
        let Ok(mut fifo) = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&self.inner.wake_fifo)
        else {
            return;
        };
        let _ = fifo.write_all(b"1");
        let _ = fifo.flush();
    }
}

impl Drop for ShellIntegrationInner {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub fn percent_encode_path(path: &str) -> String {
    let mut encoded = String::with_capacity(path.len());
    for byte in path.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(char::from(*byte))
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

fn create_private_session_dir() -> Result<PathBuf, ShellIntegrationError> {
    let base = std::env::temp_dir();
    for _ in 0..16 {
        let dir = base.join(format!("terminal-finder-shell-{}", Uuid::new_v4()));
        match fs::create_dir(&dir) {
            Ok(()) => {
                #[cfg(unix)]
                fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
                return Ok(dir);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }

    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate unique terminal shell integration directory",
    )
    .into())
}

fn create_private_fifo(path: &Path) -> Result<(), ShellIntegrationError> {
    let path_c = CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "fifo path contains an interior NUL byte",
        )
    })?;
    // SAFETY: `path_c` is a valid NUL-terminated path pointer for this call.
    let result = unsafe { libc::mkfifo(path_c.as_ptr(), 0o600) };
    if result == -1 {
        return Err(std::io::Error::last_os_error().into());
    }
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn write_startup_wrappers(dir: &Path) -> Result<(), ShellIntegrationError> {
    create_private_file(
        &dir.join(".zshenv"),
        &format!(
            r#"[ -f "${{TF_USER_ZDOTDIR:-$HOME}}/.zshenv" ] && . "${{TF_USER_ZDOTDIR:-$HOME}}/.zshenv"
{}
"#,
            zsh_hook_block()
        ),
    )?;
    create_private_file(
        &dir.join(".zprofile"),
        r#"[ -f "${TF_USER_ZDOTDIR:-$HOME}/.zprofile" ] && . "${TF_USER_ZDOTDIR:-$HOME}/.zprofile"
"#,
    )?;
    create_private_file(&dir.join(".zshrc"), zshrc_wrapper())?;
    create_private_file(&dir.join(".zsh_history"), "")?;
    create_private_file(
        &dir.join(".zlogin"),
        r#"[ -f "${TF_USER_ZDOTDIR:-$HOME}/.zlogin" ] && . "${TF_USER_ZDOTDIR:-$HOME}/.zlogin"
_tf_install_hooks
"#,
    )?;
    Ok(())
}

fn zshrc_wrapper() -> &'static str {
    r#"[ -f "${TF_USER_ZDOTDIR:-$HOME}/.zshrc" ] && . "${TF_USER_ZDOTDIR:-$HOME}/.zshrc"
_tf_install_hooks
"#
}

fn zsh_hook_block() -> &'static str {
    r#"
_tf_percent_encode_byte() {
  case "$1" in
    [-A-Za-z0-9._~/]) printf '%s' "$1" ;;
    *) printf '%%%02X' "'$1" ;;
  esac
}

_tf_urlencode_pwd() {
  local LC_ALL=C
  local encoded="" char input="$PWD"
  for (( i = 1; i <= ${#input}; i++ )); do
    char="${input[i]}"
    encoded="${encoded}$(_tf_percent_encode_byte "$char")"
  done
  printf '%s' "$encoded"
}

_tf_apply_pending_cd() {
  [ -n "$TF_CD_REQUEST" ] || return
  [ -f "$TF_CD_REQUEST" ] || return
  local t
  t="$(cat "$TF_CD_REQUEST")" && : > "$TF_CD_REQUEST"
  [ -n "$t" ] && [ -d "$t" ] && cd -- "$t"
}

_tf_report() {
  printf '\e]7;file://%s%s\e\\' "$HOST" "$(_tf_urlencode_pwd)"
  printf '\e]133;A\e\\'
}

_tf_precmd() {
  _tf_apply_pending_cd
  _tf_report
}

_tf_install_wake_fd() {
  [ -n "${TF_CD_WAKE_FIFO:-}" ] || return
  [ -z "${TF_CD_WAKE_FD:-}" ] || return
  exec {TF_CD_WAKE_FD}<>"$TF_CD_WAKE_FIFO" 2>/dev/null || return
  zle -F $TF_CD_WAKE_FD _tf_wake_cd 2>/dev/null || true
}

_tf_wake_cd() {
  local _tf_byte
  while read -r -k 1 -t 0 -u $TF_CD_WAKE_FD _tf_byte 2>/dev/null; do :; done
  _tf_apply_pending_cd
  _tf_report
  printf '\r\e[K'
  zle reset-prompt 2>/dev/null || true
}

_tf_line_init() {
  _tf_install_wake_fd
}

_tf_install_hooks() {
  autoload -Uz add-zsh-hook add-zle-hook-widget
  add-zsh-hook -d precmd _tf_precmd 2>/dev/null || true
  add-zsh-hook precmd _tf_precmd 2>/dev/null || {
    precmd_functions=(${precmd_functions:#_tf_precmd})
    precmd_functions=(_tf_precmd $precmd_functions)
  }
  add-zle-hook-widget -d line-init _tf_line_init 2>/dev/null || true
  add-zle-hook-widget line-init _tf_line_init 2>/dev/null || true
}

_tf_install_hooks
"#
}

fn create_private_file(path: &Path, contents: &str) -> Result<(), ShellIntegrationError> {
    let mut file = open_private_new_file(path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

fn open_private_new_file(path: &Path) -> Result<File, ShellIntegrationError> {
    let file = OpenOptions::new().write(true).create_new(true).open(path)?;
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

fn reject_unsafe_target(target: &str) -> Result<(), ShellIntegrationError> {
    if target.chars().any(|ch| ch.is_control()) {
        Err(ShellIntegrationError::UnsafeTargetPath)
    } else {
        Ok(())
    }
}

fn reject_request_symlink(path: &Path) -> Result<(), ShellIntegrationError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        Err(ShellIntegrationError::SymlinkRequestFile)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[cfg(unix)]
    fn assert_private_dir(path: &Path) {
        let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
    }

    #[cfg(unix)]
    fn assert_private_file(path: &Path) {
        let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn percent_encoder_produces_valid_osc7_path_segments() {
        assert_eq!(
            percent_encode_path("/tmp/a b#c?d%/你好"),
            "/tmp/a%20b%23c%3Fd%25/%E4%BD%A0%E5%A5%BD"
        );
    }

    #[test]
    fn integration_directory_is_private_and_contains_zsh_wrappers() {
        let integration = ShellIntegration::create().expect("integration dir");

        assert_private_dir(integration.dir());
        assert_private_file(integration.request_file());
        assert_private_file(integration.wake_fifo());
        assert!(integration.dir().join(".zshenv").is_file());
        assert!(integration.dir().join(".zprofile").is_file());
        assert!(integration.dir().join(".zshrc").is_file());
        assert!(integration.dir().join(".zlogin").is_file());
    }

    #[test]
    fn zsh_wrappers_source_user_files_and_install_hooks_after_login_files() {
        let integration = ShellIntegration::create().expect("integration dir");
        let zlogin = std::fs::read_to_string(integration.dir().join(".zlogin")).unwrap();

        assert!(zlogin.contains("${TF_USER_ZDOTDIR:-$HOME}/.zlogin"));
        assert!(zlogin.contains("_tf_install_hooks"));
        assert!(zlogin.find(".zlogin").unwrap() < zlogin.find("_tf_install_hooks").unwrap());
    }

    #[test]
    fn wake_cd_redraw_clears_stale_prompt_tail() {
        let hook = zsh_hook_block();
        let wake_start = hook.find("_tf_wake_cd()").expect("wake handler exists");
        let reset_prompt = hook[wake_start..]
            .find("zle reset-prompt")
            .expect("wake handler resets prompt")
            + wake_start;

        assert!(
            hook[wake_start..reset_prompt].contains("\\e[K"),
            "wake redraw must clear the old prompt tail before drawing a shorter prompt"
        );
    }

    #[test]
    fn request_file_rejects_newline_and_control_characters() {
        let integration = ShellIntegration::create().expect("integration dir");

        assert!(matches!(
            integration.write_cd_request("/tmp/bad\npath"),
            Err(ShellIntegrationError::UnsafeTargetPath)
        ));
        assert!(matches!(
            integration.write_cd_request("/tmp/bad\u{7f}path"),
            Err(ShellIntegrationError::UnsafeTargetPath)
        ));
    }

    #[test]
    fn request_file_write_is_atomic_and_private() {
        let integration = ShellIntegration::create().expect("integration dir");

        integration
            .write_cd_request("/tmp/next")
            .expect("write request");

        assert_eq!(
            std::fs::read_to_string(integration.request_file()).unwrap(),
            "/tmp/next"
        );
        assert_private_file(integration.request_file());
    }
}
