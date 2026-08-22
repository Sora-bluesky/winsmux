//! Single-attempt Windows OpenSSH stdio transport.
//!
//! TASK-773 first PR. Rust-direct `winsmux ssh-helper-stdio -- <alias>`.
//! One HostProfile registration query, then exactly one `ssh.exe` spawn.
//! Byte-for-byte stdin/stdout. Stderr separate. No retry, keepalive, or reattach.

use std::io::{self, ErrorKind, Read, Write};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;

pub(crate) const USAGE: &str = "usage: winsmux ssh-helper-stdio -- <alias>";

const SSH_PROGRAM: &str = "ssh.exe";

#[cfg(test)]
thread_local! {
    static SPAWN_COUNT: std::cell::Cell<usize> = std::cell::Cell::new(0);
}

struct SshCommandSpec {
    program: String,
    args: Vec<String>,
}

struct ReapOnDrop {
    child: Option<Child>,
}

impl ReapOnDrop {
    fn new(child: Child) -> Self {
        Self { child: Some(child) }
    }
}

impl Drop for ReapOnDrop {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

pub(crate) fn run_ssh_helper_stdio_command(args: &[&String]) -> io::Result<()> {
    if args.is_empty() || should_print_help(args) {
        println!("{USAGE}");
        return Ok(());
    }
    let alias = parse_alias(args)?;
    run_registered_stdio(alias, io::stdin(), io::stdout(), io::stderr())
}

fn should_print_help(args: &[&String]) -> bool {
    if args.first().map(|arg| arg.as_str()) == Some("--") {
        return false;
    }
    args.iter()
        .any(|arg| matches!(arg.as_str(), "-h" | "--help" | "help"))
}

fn parse_alias<'a>(args: &'a [&String]) -> io::Result<&'a str> {
    match args {
        [dash, alias] if dash.as_str() == "--" => Ok(alias.as_str()),
        _ => Err(io::Error::new(ErrorKind::InvalidInput, USAGE.to_string())),
    }
}

fn command_spec(alias: &str) -> SshCommandSpec {
    SshCommandSpec {
        program: ssh_program(),
        args: vec![
            "-T".to_string(),
            "-o".to_string(),
            "BatchMode=yes".to_string(),
            "--".to_string(),
            alias.to_string(),
            "winsmux-remote-helper".to_string(),
            "serve".to_string(),
            "--stdio".to_string(),
        ],
    }
}

fn ssh_program() -> String {
    #[cfg(test)]
    if let Some(path) = env_nonempty("WINSMUX_SSH_HELPER_STDIO_SSH") {
        return path;
    }
    SSH_PROGRAM.to_string()
}

#[cfg(test)]
fn env_nonempty(name: &str) -> Option<String> {
    match std::env::var(name) {
        Ok(value) if !value.trim().is_empty() => Some(value),
        _ => None,
    }
}

fn fail_if_not_registered(alias: &str) -> io::Result<()> {
    match crate::host_profile::is_registered_alias(alias) {
        Ok(true) => Ok(()),
        Ok(false) => Err(io::Error::new(
            ErrorKind::NotFound,
            format!("ssh-helper-stdio: HostProfile '{alias}' is not registered"),
        )),
        Err(error) => Err(error),
    }
}

fn spawn_once(spec: &SshCommandSpec) -> io::Result<Child> {
    #[cfg(test)]
    SPAWN_COUNT.with(|count| count.set(count.get() + 1));
    Command::new(&spec.program)
        .args(&spec.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("ssh-helper-stdio failed to exec ssh.exe: {error}"),
            )
        })
}

fn run_registered_stdio<R, W, E>(
    alias: &str,
    stdin: R,
    stdout: W,
    stderr: E,
) -> io::Result<()>
where
    R: Read + Send + 'static,
    W: Write + Send,
    E: Write + Send,
{
    fail_if_not_registered(alias)?;
    let spec = command_spec(alias);
    let child = spawn_once(&spec)?;
    let status = relay_and_reap_io(child, stdin, stdout, stderr)?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::new(
            ErrorKind::Other,
            format!("ssh.exe exited with {status}"),
        ))
    }
}

fn relay_and_reap_io<R, W, E>(
    child: Child,
    mut input: R,
    mut output: W,
    mut err_out: E,
) -> io::Result<ExitStatus>
where
    R: Read + Send + 'static,
    W: Write + Send,
    E: Write + Send,
{
    let mut reaper = ReapOnDrop::new(child);
    let (mut child_stdin, mut child_stdout, mut child_stderr) = {
        let child = reaper
            .child
            .as_mut()
            .ok_or_else(|| io::Error::new(ErrorKind::Other, "ssh.exe child missing"))?;
        (
            child.stdin.take().ok_or_else(|| {
                io::Error::new(ErrorKind::BrokenPipe, "ssh.exe stdin pipe missing")
            })?,
            child.stdout.take().ok_or_else(|| {
                io::Error::new(ErrorKind::BrokenPipe, "ssh.exe stdout pipe missing")
            })?,
            child.stderr.take().ok_or_else(|| {
                io::Error::new(ErrorKind::BrokenPipe, "ssh.exe stderr pipe missing")
            })?,
        )
    };

    let stdin_thread = thread::spawn(move || {
        let result = copy_ignore_pipe_close(&mut input, &mut child_stdin);
        drop(child_stdin);
        result
    });
    let status = thread::scope(|scope| -> io::Result<ExitStatus> {
        let stdout_thread = scope.spawn(|| io::copy(&mut child_stdout, &mut output));
        let stderr_thread = scope.spawn(|| io::copy(&mut child_stderr, &mut err_out));
        let status = reaper
            .child
            .as_mut()
            .ok_or_else(|| io::Error::new(ErrorKind::Other, "ssh.exe child missing"))?
            .wait()?;
        interrupt_stdin_read();
        stdout_thread.join().unwrap()?;
        stderr_thread.join().unwrap()?;
        Ok(status)
    })?;
    drop(stdin_thread);
    let _ = reaper.child.take();
    Ok(status)
}

fn interrupt_stdin_read() {
    #[cfg(windows)]
    stdin_interrupt::interrupt_stdin_read();
}

#[cfg(windows)]
mod stdin_interrupt {
    const STD_INPUT_HANDLE: u32 = 0xFFFF_FFF6;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetStdHandle(n_std_handle: u32) -> *mut core::ffi::c_void;
        fn CancelIoEx(handle: *mut core::ffi::c_void, overlapped: *mut core::ffi::c_void) -> i32;
    }

    pub(super) fn interrupt_stdin_read() {
        unsafe {
            let handle = GetStdHandle(STD_INPUT_HANDLE);
            if !handle.is_null() && handle != (-1isize as *mut core::ffi::c_void) {
                let _ = CancelIoEx(handle, std::ptr::null_mut());
            }
        }
    }
}

fn copy_ignore_pipe_close<R: Read, W: Write>(reader: &mut R, writer: &mut W) -> io::Result<u64> {
    match io::copy(reader, writer) {
        Err(error) if is_benign_pipe_close(&error) => Ok(0),
        other => other,
    }
}

fn is_benign_pipe_close(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::BrokenPipe | ErrorKind::UnexpectedEof
    ) || matches!(error.raw_os_error(), Some(109 | 232))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host_profile::lock_test_env;
    use serde_json::json;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command as StdCommand;
    use std::time::{Duration, Instant};

    fn reset_spawn_count() {
        SPAWN_COUNT.with(|count| count.set(0));
    }

    fn spawn_count() -> usize {
        SPAWN_COUNT.with(|count| count.get())
    }

    fn write_record(dir: &Path, alias: &str, state: &str) {
        let payload = json!({
            "alias": alias,
            "hostname": "192.0.2.10",
            "port": 22,
            "user": "ubuntu",
            "state": state,
        });
        fs::write(
            dir.join(format!("{alias}.json")),
            serde_json::to_vec_pretty(&payload).unwrap(),
        )
        .unwrap();
    }

    fn install_fake_ssh(dir: &Path) -> PathBuf {
        fs::write(
            dir.join("fake-ssh.ps1"),
            r#"$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Content -LiteralPath (Join-Path $dir 'ssh-argv.txt') -Value ($args -join ' ')
Add-Content -LiteralPath (Join-Path $dir 'ssh-spawn.txt') -Value 'spawned'
$mode = $env:WINSMUX_SSH_FAKE_MODE
if ($mode -eq 'fail') {
    [Console]::Error.WriteLine('fake-ssh failed')
    exit 1
}
if ($mode -eq 'hang') {
    Start-Sleep -Seconds 30
    exit 0
}
if ($mode -eq 'helper') {
    & $env:WINSMUX_FAKE_SSH_INNER 'serve' '--stdio'
    exit $LASTEXITCODE
}
[Console]::Error.Write('stderr-noise')
[Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())
"#,
        )
        .unwrap();
        fs::write(
            dir.join("ssh.cmd"),
            "@echo off\r\npwsh -NoProfile -File \"%~dp0fake-ssh.ps1\" %*\r\n",
        )
        .unwrap();
        dir.join("ssh.cmd")
    }

    fn helper_exe() -> Option<PathBuf> {
        if let Ok(dir) = std::env::var("CARGO_TARGET_DIR") {
            let path = PathBuf::from(dir)
                .join("debug")
                .join("winsmux-remote-helper.exe");
            if path.is_file() {
                return Some(path);
            }
        }
        let mut path = std::env::current_exe().ok()?;
        path.pop();
        if path.file_name().is_some_and(|name| name == "deps") {
            path.pop();
        }
        path.push("winsmux-remote-helper.exe");
        path.is_file().then_some(path)
    }

    fn arg(value: &str) -> String {
        value.to_string()
    }

    #[test]
    fn command_spec_is_frozen_including_hostile_alias_after_dash_dash() {
        let _guard = lock_test_env();
        std::env::remove_var("WINSMUX_SSH_HELPER_STDIO_SSH");
        let spec = command_spec("-oProxyJump=evil");
        assert_eq!(spec.program, SSH_PROGRAM);
        assert_eq!(
            spec.args.iter().map(String::as_str).collect::<Vec<_>>(),
            vec![
                "-T",
                "-o",
                "BatchMode=yes",
                "--",
                "-oProxyJump=evil",
                "winsmux-remote-helper",
                "serve",
                "--stdio",
            ]
        );
        assert!(!spec.program.to_ascii_lowercase().contains("cmd"));
        assert!(!spec.program.to_ascii_lowercase().contains("powershell"));
        assert!(!spec.program.to_ascii_lowercase().contains("bash"));
        assert!(!spec.args.iter().any(|arg| arg.contains("bash")
            || arg.contains("cmd.exe")
            || arg.contains("-lc")));
    }

    #[test]
    fn unregistered_pending_blocked_and_lookup_error_fail_before_spawn() {
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var(
            "WINSMUX_SSH_HELPER_STDIO_SSH",
            dir.path().join("ssh-should-not-run.exe"),
        );
        reset_spawn_count();

        let missing = [arg("--"), arg("lab")];
        let refs: Vec<&String> = missing.iter().collect();
        let error = run_ssh_helper_stdio_command(&refs).unwrap_err();
        assert!(
            error.to_string().contains("not registered"),
            "error={error}"
        );
        assert_eq!(spawn_count(), 0);

        write_record(dir.path(), "lab", "pending");
        reset_spawn_count();
        run_ssh_helper_stdio_command(&refs).unwrap_err();
        assert_eq!(spawn_count(), 0);

        write_record(dir.path(), "lab", "blocked");
        reset_spawn_count();
        run_ssh_helper_stdio_command(&refs).unwrap_err();
        assert_eq!(spawn_count(), 0);

        fs::write(dir.path().join("lab.json"), "{").unwrap();
        reset_spawn_count();
        let error = run_ssh_helper_stdio_command(&refs).unwrap_err();
        assert_eq!(spawn_count(), 0);
        assert!(
            error.kind() == ErrorKind::InvalidData || error.to_string().contains("expected"),
            "error={error}"
        );

        let hostile = [arg("--"), arg("-oProxyJump=evil")];
        let hostile_refs: Vec<&String> = hostile.iter().collect();
        reset_spawn_count();
        run_ssh_helper_stdio_command(&hostile_refs).unwrap_err();
        assert_eq!(spawn_count(), 0);
    }

    #[test]
    fn registered_failure_spawns_exactly_once() {
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        write_record(dir.path(), "lab", "registered");
        let ssh = install_fake_ssh(dir.path());
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var("WINSMUX_SSH_HELPER_STDIO_SSH", &ssh);
        std::env::set_var("WINSMUX_SSH_FAKE_MODE", "fail");
        reset_spawn_count();

        let error = run_registered_stdio("lab", io::empty(), Vec::new(), Vec::new()).unwrap_err();
        assert_eq!(spawn_count(), 1, "error={error}");
        let spawn_log = fs::read_to_string(dir.path().join("ssh-spawn.txt")).unwrap();
        assert_eq!(spawn_log.lines().count(), 1);
        let argv = fs::read_to_string(dir.path().join("ssh-argv.txt")).unwrap();
        assert!(
            argv.contains("-T")
                && argv.contains("BatchMode=yes")
                && argv.contains("--")
                && argv.contains("lab")
                && argv.contains("winsmux-remote-helper")
                && argv.contains("serve")
                && argv.contains("--stdio"),
            "argv={argv}"
        );
    }

    #[test]
    fn stdout_is_byte_for_byte_and_stderr_stays_separate() {
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        write_record(dir.path(), "lab", "registered");
        let ssh = install_fake_ssh(dir.path());
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var("WINSMUX_SSH_HELPER_STDIO_SSH", &ssh);
        std::env::remove_var("WINSMUX_SSH_FAKE_MODE");
        reset_spawn_count();

        let payload = b"hello\x00world\n\xff".to_vec();
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        run_registered_stdio(
            "lab",
            io::Cursor::new(payload.clone()),
            &mut stdout,
            &mut stderr,
        )
        .unwrap();
        assert_eq!(spawn_count(), 1);
        assert_eq!(stdout, payload);
        assert_eq!(stderr, b"stderr-noise");
        assert!(!stdout.windows(b"stderr-noise".len()).any(|w| w == b"stderr-noise"));
    }

    #[test]
    fn drop_reaps_child_while_io_is_blocked() {
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        write_record(dir.path(), "lab", "registered");
        let ssh = install_fake_ssh(dir.path());
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var("WINSMUX_SSH_HELPER_STDIO_SSH", &ssh);
        std::env::set_var("WINSMUX_SSH_FAKE_MODE", "hang");
        reset_spawn_count();

        let spec = command_spec("lab");
        fail_if_not_registered("lab").unwrap();
        let child = spawn_once(&spec).unwrap();
        assert_eq!(spawn_count(), 1);
        let started = Instant::now();
        drop(ReapOnDrop::new(child));
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "child was not reaped on drop"
        );
    }

    #[test]
    fn helper_hello_welcome_bytes_are_unmodified() {
        let Some(helper) = helper_exe() else {
            panic!("winsmux-remote-helper.exe missing; build it before this test");
        };
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        write_record(dir.path(), "lab", "registered");
        let ssh = install_fake_ssh(dir.path());
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var("WINSMUX_SSH_HELPER_STDIO_SSH", &ssh);
        std::env::set_var("WINSMUX_SSH_FAKE_MODE", "helper");
        std::env::set_var("WINSMUX_FAKE_SSH_INNER", &helper);
        reset_spawn_count();

        let hello = winsmux_remote_helper::Message::Hello {
            protocol_version: winsmux_remote_helper::PROTOCOL_VERSION,
            client_version: "winsmux-test".to_string(),
            nonce: "ab".repeat(winsmux_remote_helper::NONCE_LEN),
            capabilities: vec!["frame-v1".to_string()],
            peer_frame_limit: winsmux_remote_helper::MAX_FRAME_LEN,
        };
        let hello_frame = winsmux_remote_helper::encode_frame(&hello).unwrap();
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        run_registered_stdio(
            "lab",
            io::Cursor::new(hello_frame),
            &mut stdout,
            &mut stderr,
        )
        .unwrap();
        assert_eq!(spawn_count(), 1);
        let mut cursor = stdout.as_slice();
        let payload = winsmux_remote_helper::read_frame(&mut cursor)
            .unwrap()
            .expect("welcome payload");
        let welcome = winsmux_remote_helper::decode_payload(&payload).unwrap();
        assert!(matches!(
            welcome,
            winsmux_remote_helper::Message::Welcome { .. }
        ));
        assert!(
            !stderr.windows(payload.len()).any(|window| window == payload.as_slice()),
            "protocol bytes leaked onto stderr"
        );
    }

    #[test]
    fn missing_dash_dash_does_not_spawn() {
        let _guard = lock_test_env();
        reset_spawn_count();
        let args = [arg("lab")];
        let refs: Vec<&String> = args.iter().collect();
        let error = run_ssh_helper_stdio_command(&refs).unwrap_err();
        assert!(error.to_string().contains("usage:"), "error={error}");
        assert_eq!(spawn_count(), 0);
    }

    #[test]
    fn help_after_dash_dash_is_an_alias() {
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var(
            "WINSMUX_SSH_HELPER_STDIO_SSH",
            dir.path().join("ssh-should-not-run.exe"),
        );
        reset_spawn_count();
        let args = [arg("--"), arg("help")];
        let refs: Vec<&String> = args.iter().collect();
        let error = run_ssh_helper_stdio_command(&refs).unwrap_err();
        assert!(
            error.to_string().contains("not registered"),
            "error={error}"
        );
        assert_eq!(spawn_count(), 0);
    }

    #[test]
    fn child_exit_returns_while_stdin_is_blocked() {
        let _guard = lock_test_env();
        let dir = tempfile::tempdir().unwrap();
        write_record(dir.path(), "lab", "registered");
        let ssh = install_fake_ssh(dir.path());
        std::env::set_var("WINSMUX_HOST_PROFILE_DIR", dir.path());
        std::env::set_var("WINSMUX_SSH_HELPER_STDIO_SSH", &ssh);
        std::env::set_var("WINSMUX_SSH_FAKE_MODE", "fail");
        reset_spawn_count();
        let (reader, writer) = io::pipe().unwrap();
        let started = Instant::now();
        let error = run_registered_stdio("lab", reader, Vec::new(), Vec::new()).unwrap_err();
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "relay deadlocked on blocked stdin: {error}"
        );
        assert_eq!(spawn_count(), 1);
        drop(writer);
    }

    #[test]
    fn default_program_is_ssh_exe() {
        let _guard = lock_test_env();
        std::env::remove_var("WINSMUX_SSH_HELPER_STDIO_SSH");
        let spec = command_spec("lab");
        assert_eq!(spec.program, "ssh.exe");
        let _ = StdCommand::new(&spec.program);
    }
}
