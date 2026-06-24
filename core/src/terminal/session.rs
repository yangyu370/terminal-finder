use std::{
    env,
    io::{Read, Write},
    path::PathBuf,
    sync::mpsc::{self, RecvTimeoutError},
    thread,
    time::Duration,
};

use portable_pty::{CommandBuilder, ExitStatus, PtySize, native_pty_system};
use tokio::sync::mpsc as tokio_mpsc;
use uuid::Uuid;

const LOG_TARGET: &str = "terminal";
const DEFAULT_SHELL: &str = "/bin/zsh";
const DEFAULT_TERM: &str = "xterm-256color";
#[cfg(target_os = "macos")]
const DEFAULT_UTF8_LOCALE: &str = "en_US.UTF-8";
#[cfg(not(target_os = "macos"))]
const DEFAULT_UTF8_LOCALE: &str = "C.UTF-8";
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(25);

pub enum TerminalLaunch {
    LocalShell {
        cwd: PathBuf,
    },
    DockerExec {
        container: String,
        user: String,
        workdir: String,
    },
}

#[derive(Debug)]
pub enum TerminalEvent {
    Output {
        session_id: Uuid,
        bytes: Vec<u8>,
    },
    Exit {
        session_id: Uuid,
        code: Option<i32>,
        signal: Option<i32>,
    },
    Error {
        session_id: Uuid,
        code: &'static str,
        message: String,
    },
}

enum SessionCommand {
    Input(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Close,
}

#[derive(Clone)]
pub struct SessionHandle {
    session_id: Uuid,
    commands: mpsc::Sender<SessionCommand>,
}

impl SessionHandle {
    pub fn id(&self) -> Uuid {
        self.session_id
    }

    #[cfg(test)]
    pub fn for_test(session_id: Uuid) -> Self {
        let (commands, receiver) = mpsc::channel();
        drop(receiver);

        Self {
            session_id,
            commands,
        }
    }

    pub fn input(&self, bytes: Vec<u8>) -> bool {
        self.commands.send(SessionCommand::Input(bytes)).is_ok()
    }

    pub fn resize(&self, cols: u16, rows: u16) -> bool {
        self.commands
            .send(SessionCommand::Resize { cols, rows })
            .is_ok()
    }

    pub fn close(&self) -> bool {
        self.commands.send(SessionCommand::Close).is_ok()
    }
}
pub struct TerminalSession;

impl TerminalSession {
    pub fn spawn(
        launch: TerminalLaunch,
        cols: u16,
        rows: u16,
        events: tokio_mpsc::Sender<TerminalEvent>,
    ) -> anyhow::Result<SessionHandle> {
        let session_id = Uuid::new_v4();
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let command = build_command(&launch);

        let child = pair.slave.spawn_command(command)?;
        drop(pair.slave);

        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let master = pair.master;
        let (command_tx, command_rx) = mpsc::channel();

        spawn_reader_thread(session_id, reader, events.clone());
        spawn_control_thread(session_id, master, writer, child, command_rx, events);

        Ok(SessionHandle {
            session_id,
            commands: command_tx,
        })
    }
}

fn build_command(launch: &TerminalLaunch) -> CommandBuilder {
    let mut command = match launch {
        TerminalLaunch::LocalShell { cwd } => {
            let mut command = CommandBuilder::new(DEFAULT_SHELL);
            command.arg("-l");
            command.cwd(cwd);
            command
        }
        TerminalLaunch::DockerExec {
            container,
            user,
            workdir,
        } => {
            let mut command = CommandBuilder::new("docker");
            command.args([
                "exec",
                "-it",
                "--user",
                user.as_str(),
                "-w",
                workdir.as_str(),
                container.as_str(),
                DEFAULT_SHELL,
                "-l",
            ]);
            command
        }
    };
    configure_terminal_environment(&mut command);
    command
}

fn configure_terminal_environment(command: &mut CommandBuilder) {
    let term = env::var("TERM")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_TERM.to_string());
    command.env("TERM", term);

    let locale = preferred_utf8_locale();
    command.env(
        "LANG",
        utf8_env_value("LANG").unwrap_or_else(|| locale.clone()),
    );
    command.env(
        "LC_CTYPE",
        utf8_env_value("LC_CTYPE").unwrap_or_else(|| locale.clone()),
    );

    if env::var_os("LC_ALL").is_some() {
        match utf8_env_value("LC_ALL") {
            Some(value) => command.env("LC_ALL", value),
            None => command.env("LC_ALL", locale),
        }
    }
}

fn preferred_utf8_locale() -> String {
    utf8_env_value("LC_CTYPE")
        .or_else(|| utf8_env_value("LANG"))
        .or_else(|| utf8_env_value("LC_ALL"))
        .unwrap_or_else(|| DEFAULT_UTF8_LOCALE.to_string())
}

fn utf8_env_value(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| is_utf8_locale(value))
}

fn is_utf8_locale(value: &str) -> bool {
    let normalized = value.to_ascii_uppercase().replace('_', "-");
    normalized.contains("UTF-8") || normalized.contains("UTF8")
}

fn spawn_reader_thread(
    session_id: Uuid,
    mut reader: Box<dyn Read + Send>,
    events: tokio_mpsc::Sender<TerminalEvent>,
) {
    thread::Builder::new()
        .name(format!("terminal-reader-{session_id}"))
        .spawn(move || {
            let mut buffer = [0_u8; 8192];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => return,
                    Ok(count) => {
                        if events
                            .blocking_send(TerminalEvent::Output {
                                session_id,
                                bytes: buffer[..count].to_vec(),
                            })
                            .is_err()
                        {
                            return;
                        }
                    }
                    Err(error) => {
                        let _ = events.blocking_send(TerminalEvent::Error {
                            session_id,
                            code: "read_failed",
                            message: error.to_string(),
                        });
                        return;
                    }
                }
            }
        })
        .expect("terminal reader thread starts");
}

fn spawn_control_thread(
    session_id: Uuid,
    master: Box<dyn portable_pty::MasterPty + Send>,
    mut writer: Box<dyn Write + Send>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    commands: mpsc::Receiver<SessionCommand>,
    events: tokio_mpsc::Sender<TerminalEvent>,
) {
    thread::Builder::new()
        .name(format!("terminal-control-{session_id}"))
        .spawn(move || {
            loop {
                match commands.recv_timeout(EXIT_POLL_INTERVAL) {
                    Ok(SessionCommand::Input(bytes)) => {
                        if let Err(error) = writer.write_all(&bytes).and_then(|_| writer.flush()) {
                            let _ = events.blocking_send(TerminalEvent::Error {
                                session_id,
                                code: "write_failed",
                                message: error.to_string(),
                            });
                        }
                    }
                    Ok(SessionCommand::Resize { cols, rows }) => {
                        if let Err(error) = master.resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        }) {
                            let _ = events.blocking_send(TerminalEvent::Error {
                                session_id,
                                code: "resize_failed",
                                message: error.to_string(),
                            });
                        }
                    }
                    Ok(SessionCommand::Close) => {
                        if let Err(error) = child.kill() {
                            tracing::debug!(
                                target: LOG_TARGET,
                                %session_id,
                                message = %error,
                                "terminal child kill failed"
                            );
                        }
                        wait_for_child_exit(child, &events, session_id);
                        return;
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => {
                        if let Err(error) = child.kill() {
                            tracing::debug!(
                                target: LOG_TARGET,
                                %session_id,
                                message = %error,
                                "terminal child kill after disconnect failed"
                            );
                        }
                        wait_for_child_exit(child, &events, session_id);
                        return;
                    }
                }

                match child.try_wait() {
                    Ok(Some(exit_status)) => {
                        send_exit(&events, session_id, exit_status);
                        return;
                    }
                    Ok(None) => {}
                    Err(error) => {
                        let _ = events.blocking_send(TerminalEvent::Error {
                            session_id,
                            code: "wait_failed",
                            message: error.to_string(),
                        });
                        return;
                    }
                }
            }
        })
        .expect("terminal control thread starts");
}

fn wait_for_child_exit(
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    events: &tokio_mpsc::Sender<TerminalEvent>,
    session_id: Uuid,
) {
    match child.wait() {
        Ok(exit_status) => send_exit(events, session_id, exit_status),
        Err(error) => {
            let _ = events.blocking_send(TerminalEvent::Error {
                session_id,
                code: "wait_failed",
                message: error.to_string(),
            });
        }
    }
}

fn send_exit(events: &tokio_mpsc::Sender<TerminalEvent>, session_id: Uuid, status: ExitStatus) {
    let _ = events.blocking_send(TerminalEvent::Exit {
        session_id,
        code: i32::try_from(status.exit_code()).ok(),
        signal: None,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_locale_detection_accepts_common_spellings() {
        assert!(is_utf8_locale("en_US.UTF-8"));
        assert!(is_utf8_locale("zh_CN.UTF8"));
        assert!(is_utf8_locale("UTF-8"));
    }

    #[test]
    fn utf8_locale_detection_rejects_non_utf8_locales() {
        assert!(!is_utf8_locale(""));
        assert!(!is_utf8_locale("C"));
        assert!(!is_utf8_locale("POSIX"));
        assert!(!is_utf8_locale("en_US.ISO8859-1"));
    }

    #[test]
    fn terminal_command_environment_forces_utf8_text_handling() {
        let mut command = CommandBuilder::new(DEFAULT_SHELL);

        configure_terminal_environment(&mut command);

        let term = command
            .get_env("TERM")
            .expect("TERM is configured")
            .to_string_lossy();
        assert!(!term.trim().is_empty());

        let lang = command
            .get_env("LANG")
            .expect("LANG is configured")
            .to_string_lossy();
        assert!(is_utf8_locale(&lang));

        let lc_ctype = command
            .get_env("LC_CTYPE")
            .expect("LC_CTYPE is configured")
            .to_string_lossy();
        assert!(is_utf8_locale(&lc_ctype));

        if let Some(lc_all) = command.get_env("LC_ALL") {
            assert!(is_utf8_locale(&lc_all.to_string_lossy()));
        }
    }

    #[test]
    fn docker_exec_launch_builds_expected_argv() {
        let command = build_command(&TerminalLaunch::DockerExec {
            container: "terminal-finder-dev".to_string(),
            user: "terminal".to_string(),
            workdir: "/workspace".to_string(),
        });
        let argv: Vec<_> = command
            .get_argv()
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();

        assert_eq!(
            argv,
            vec![
                "docker",
                "exec",
                "-it",
                "--user",
                "terminal",
                "-w",
                "/workspace",
                "terminal-finder-dev",
                DEFAULT_SHELL,
                "-l",
            ]
        );
    }

    #[test]
    fn local_shell_launch_uses_default_shell() {
        let command = build_command(&TerminalLaunch::LocalShell {
            cwd: env::current_dir().expect("current directory is available"),
        });
        let argv: Vec<_> = command
            .get_argv()
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();

        assert_eq!(argv.first().map(String::as_str), Some(DEFAULT_SHELL));
    }

    #[tokio::test]
    async fn terminal_session_runs_utf8_text_through_child_shell() {
        if !PathBuf::from(DEFAULT_SHELL).exists() {
            return;
        }

        let (events, mut event_rx) = tokio_mpsc::channel(32);
        let session = TerminalSession::spawn(
            TerminalLaunch::LocalShell {
                cwd: env::current_dir().expect("current directory is available"),
            },
            80,
            24,
            events,
        )
        .expect("terminal session spawns");
        let marker = "__TF_UTF8__:你好:__END__";

        assert!(session.input(b"stty -echo\n".to_vec()));
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(session.input(format!("printf '%s' '{marker}'\nexit\n").into_bytes()));

        let mut output = Vec::new();
        let saw_marker = tokio::time::timeout(Duration::from_secs(3), async {
            while let Some(event) = event_rx.recv().await {
                match event {
                    TerminalEvent::Output { bytes, .. } => {
                        output.extend(bytes);
                        if String::from_utf8_lossy(&output).contains(marker) {
                            return true;
                        }
                    }
                    TerminalEvent::Exit { .. } => return false,
                    TerminalEvent::Error { message, .. } => {
                        panic!("terminal session emitted error: {message}")
                    }
                }
            }
            false
        })
        .await
        .expect("terminal session emits UTF-8 output before timeout");

        session.close();

        assert!(
            saw_marker,
            "terminal output did not include UTF-8 marker; output={}",
            String::from_utf8_lossy(&output)
        );
    }
}
