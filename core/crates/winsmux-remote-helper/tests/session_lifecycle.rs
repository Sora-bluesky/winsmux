#![cfg(target_os = "linux")]

//! Linux end-to-end coverage lives here so the frozen Windows-only CI remains unchanged.
//! The tests exercise the real broker binary, lock file, Unix socket, PTY, and process group.

use std::fs;
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};
use winsmux_remote_helper::{
    decode_payload, encode_frame, read_frame, Message, RejectCode, MAX_FRAME_LEN, PROTOCOL_VERSION,
};

struct RuntimeDir(PathBuf);

impl RuntimeDir {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "winsmux-task774-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }

    fn socket(&self) -> PathBuf {
        self.0
            .join("winsmux")
            .join("remote-helper")
            .join("broker.sock")
    }
}

impl Drop for RuntimeDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Frontend {
    child: Child,
    input: ChildStdin,
    output: ChildStdout,
}

impl Frontend {
    fn connect(runtime: &Path) -> Self {
        Self::connect_with_event(runtime, None)
    }

    fn connect_with_event(runtime: &Path, event_fd: Option<RawFd>) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_winsmux-remote-helper"));
        command
            .args(["serve", "--stdio"])
            .env("XDG_RUNTIME_DIR", runtime)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(event_fd) = event_fd {
            command.env("WINSMUX_TEST_BROKER_EVENT_FD", event_fd.to_string());
        }
        let mut child = command.spawn().unwrap();
        let input = child.stdin.take().unwrap();
        let output = child.stdout.take().unwrap();
        let mut frontend = Self {
            child,
            input,
            output,
        };
        frontend.send(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_version: "task774-test".to_string(),
            nonce: "ab".repeat(32),
            capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
            peer_frame_limit: MAX_FRAME_LEN,
        });
        assert!(matches!(frontend.recv(), Message::Welcome { .. }));
        frontend
    }

    fn send(&mut self, message: &Message) {
        use std::io::Write;
        self.input
            .write_all(&encode_frame(message).unwrap())
            .unwrap();
        self.input.flush().unwrap();
    }

    fn recv(&mut self) -> Message {
        let payload = read_frame(&mut self.output).unwrap().unwrap();
        decode_payload(&payload).unwrap()
    }

    fn recv_until(&mut self, expected: fn(&Message) -> bool) -> Message {
        loop {
            let message = self.recv();
            if expected(&message) {
                return message;
            }
            assert!(
                matches!(message, Message::PtyOutput { .. }),
                "unexpected interleaved message: {message:?}"
            );
        }
    }

    fn close(mut self) {
        drop(self.input);
        let status = self.child.wait().unwrap();
        assert!(status.success());
    }
}

struct EventPipe {
    reader: fs::File,
    writer: RawFd,
}

impl EventPipe {
    fn new() -> Self {
        let mut pipe = [0; 2];
        assert_eq!(unsafe { libc::pipe(pipe.as_mut_ptr()) }, 0);
        Self {
            reader: unsafe { fs::File::from_raw_fd(pipe[0]) },
            writer: pipe[1],
        }
    }
}

impl Drop for EventPipe {
    fn drop(&mut self) {
        unsafe { libc::close(self.writer) };
    }
}

fn start_cat(frontend: &mut Frontend) -> (String, u32) {
    frontend.send(&Message::PtyStart {
        executable: "/bin/cat".to_string(),
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    });
    match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    }
}

#[test]
fn detached_session_reconnects_to_same_child_and_stops_whole_group() {
    let runtime = RuntimeDir::new("reattach");
    let mut first = Frontend::connect(&runtime.0);
    let (session_id, child_pid) = start_cat(&mut first);
    first.send(&Message::PtyDetach);
    assert_eq!(first.recv(), Message::PtyDetached);
    first.close();

    let mut second = Frontend::connect(&runtime.0);
    second.send(&Message::PtyAttach {
        session_id: session_id.clone(),
    });
    assert_eq!(
        second.recv(),
        Message::PtyAttached {
            session_id: session_id.clone(),
            child_pid,
        }
    );
    second.send(&Message::PtyStop { session_id });
    assert_eq!(second.recv(), Message::PtyStopped);
    second.close();

    wait_socket_gone(&runtime.socket());
    let rc = unsafe { libc::kill(-(child_pid as i32), 0) };
    assert_eq!(rc, -1);
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
}

#[test]
fn second_controller_and_stale_session_are_rejected() {
    let runtime = RuntimeDir::new("controller");
    let mut owner = Frontend::connect(&runtime.0);
    let (session_id, _) = start_cat(&mut owner);
    let mut contender = Frontend::connect(&runtime.0);
    contender.send(&Message::PtyAttach {
        session_id: session_id.clone(),
    });
    assert!(matches!(contender.recv(), Message::Reject { .. }));

    owner.send(&Message::PtyStop {
        session_id: session_id.clone(),
    });
    assert_eq!(owner.recv(), Message::PtyStopped);
    contender.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        contender.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    owner.close();
    contender.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn natural_exit_removes_registry_and_process_group() {
    let runtime = RuntimeDir::new("natural-exit");
    let mut frontend = Frontend::connect(&runtime.0);
    frontend.send(&Message::PtyStart {
        executable: "/bin/true".to_string(),
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    };
    frontend.send(&Message::PtyDetach);
    assert_eq!(frontend.recv(), Message::PtyDetached);

    // Waiting for ESRCH proves the Agent group is gone. A registry row that has
    // not yet been collected must not still advertise a controller attachment.
    wait_process_group_gone(child_pid);
    frontend.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn detached_output_is_drained_until_natural_exit() {
    let runtime = RuntimeDir::new("detached-output");
    let mut frontend = Frontend::connect(&runtime.0);
    frontend.send(&Message::PtyStart {
        executable: "/usr/bin/seq".to_string(),
        argv: vec!["1".to_string(), "100000".to_string()],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    };
    frontend.send(&Message::PtyDetach);
    frontend.recv_until(|message| matches!(message, Message::PtyDetached));
    wait_process_group_gone(child_pid);
    frontend.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn pty_input_produces_bounded_output() {
    let runtime = RuntimeDir::new("io");
    let mut frontend = Frontend::connect(&runtime.0);
    let (session_id, _) = start_cat(&mut frontend);
    frontend.send(&Message::PtyInput {
        data_b64: "aGkK".to_string(),
    });
    match frontend.recv_until(|message| matches!(message, Message::PtyOutput { .. })) {
        Message::PtyOutput { data_b64 } => {
            assert!(!data_b64.is_empty());
            assert!(data_b64.len() <= 344);
        }
        _ => unreachable!(),
    }
    frontend.send(&Message::PtyStop {
        session_id: session_id.clone(),
    });
    frontend.recv_until(|message| matches!(message, Message::PtyStopped));
    frontend.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn unread_pty_input_does_not_strand_the_controller_lease() {
    let runtime = RuntimeDir::new("input-backpressure");
    let mut first = Frontend::connect(&runtime.0);
    first.send(&Message::PtyStart {
        executable: "/bin/sh".to_string(),
        argv: vec!["-c".to_string(), "stty -echo; exec sleep 600".to_string()],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match first.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    };

    // 64 chunks exceed the Linux PTY input queue while staying below the
    // frontend stdin pipe capacity. sleep keeps its stdin open but never reads.
    let data_b64 = format!("{}QQ==", "QUFB".repeat(85));
    for _ in 0..64 {
        first.send(&Message::PtyInput {
            data_b64: data_b64.clone(),
        });
    }
    first.close();

    let mut replacement = Frontend::connect(&runtime.0);
    replacement.send(&Message::PtyAttach {
        session_id: session_id.clone(),
    });
    assert_eq!(
        replacement.recv(),
        Message::PtyAttached {
            session_id: session_id.clone(),
            child_pid,
        }
    );
    replacement.send(&Message::PtyStop { session_id });
    assert_eq!(replacement.recv(), Message::PtyStopped);
    replacement.close();
    wait_socket_gone(&runtime.socket());
}

// The broker emits these records from the actual listener and shutdown branches.
const BROKER_READY: u8 = b'R';
const FRONTEND_LOCK_ACQUIRED: u8 = b'L';
const SHUTDOWN_LOCK_BUSY: u8 = b'B';
const NAMED_FRONTEND_ACCEPTED: u8 = b'A';
const SHUTDOWN_LOCK_ACQUIRED: u8 = b'S';

#[test]
fn lock_owner_exit_before_connect_wakes_idle_broker_shutdown() {
    let runtime = RuntimeDir::new("lock-owner-exits");
    let mut events = EventPipe::new();
    let first = Frontend::connect_with_event(&runtime.0, Some(events.writer));
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);

    let mut gate = [-1; 2];
    assert_eq!(unsafe { libc::pipe(gate.as_mut_ptr()) }, 0);
    let mut second = Command::new(env!("CARGO_BIN_EXE_winsmux-remote-helper"))
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime.0)
        .env("WINSMUX_TEST_BROKER_EVENT_FD", events.writer.to_string())
        .env("WINSMUX_TEST_FRONTEND_GATE_FD", gate[0].to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let second_pid = second.id() as i32;
    let mut second_input = second.stdin.take().unwrap();
    let second_output = second.stdout.take().unwrap();
    unsafe { libc::close(gate[0]) };
    use std::io::Write;
    second_input
        .write_all(
            &encode_frame(&Message::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_version: "lock-owner-exits".to_string(),
                nonce: "ef".repeat(32),
                capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
                peer_frame_limit: MAX_FRAME_LEN,
            })
            .unwrap(),
        )
        .unwrap();
    let (event, lock_owner_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, FRONTEND_LOCK_ACQUIRED);
    assert_eq!(lock_owner_pid, second_pid);

    first.close();
    let (event, busy_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, SHUTDOWN_LOCK_BUSY);
    assert_eq!(busy_pid, broker_pid);

    // B dies while it owns LOCK_EX and before it has called connect(2).
    assert_eq!(unsafe { libc::kill(second_pid, libc::SIGKILL) }, 0);
    drop(second_input);
    drop(second_output);
    assert!(!second.wait().unwrap().success());
    unsafe { libc::close(gate[1]) };

    let (event, shutdown_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, SHUTDOWN_LOCK_ACQUIRED);
    assert_eq!(shutdown_pid, broker_pid);
    wait_socket_gone(&runtime.socket());
    wait_process_gone(broker_pid);
}

#[test]
fn lock_owned_before_connect_blocks_shutdown_then_reuses_same_broker() {
    let runtime = RuntimeDir::new("lock-barrier");
    let mut events = EventPipe::new();

    let mut first = Command::new(env!("CARGO_BIN_EXE_winsmux-remote-helper"))
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime.0)
        .env("WINSMUX_TEST_BROKER_EVENT_FD", events.writer.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut first_input = first.stdin.take().unwrap();
    let mut first_output = first.stdout.take().unwrap();
    use std::io::Write;
    first_input
        .write_all(
            &encode_frame(&Message::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_version: "barrier".to_string(),
                nonce: "cd".repeat(32),
                capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
                peer_frame_limit: MAX_FRAME_LEN,
            })
            .unwrap(),
        )
        .unwrap();
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);
    let welcome = read_frame(&mut first_output).unwrap().unwrap();
    assert!(matches!(
        decode_payload(&welcome).unwrap(),
        Message::Welcome { .. }
    ));

    let mut gate = [-1; 2];
    assert_eq!(unsafe { libc::pipe(gate.as_mut_ptr()) }, 0);
    let mut second = Command::new(env!("CARGO_BIN_EXE_winsmux-remote-helper"))
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime.0)
        .env("WINSMUX_TEST_BROKER_EVENT_FD", events.writer.to_string())
        .env("WINSMUX_TEST_FRONTEND_GATE_FD", gate[0].to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let second_pid = second.id() as i32;
    let mut second_input = second.stdin.take().unwrap();
    let mut second_output = second.stdout.take().unwrap();
    unsafe { libc::close(gate[0]) };
    second_input
        .write_all(
            &encode_frame(&Message::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_version: "barrier-b".to_string(),
                nonce: "ef".repeat(32),
                capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
                peer_frame_limit: MAX_FRAME_LEN,
            })
            .unwrap(),
        )
        .unwrap();
    let (event, lock_owner_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, FRONTEND_LOCK_ACQUIRED);
    assert_eq!(lock_owner_pid, second_pid);

    drop(first_input);
    assert!(first.wait().unwrap().success());

    let (event, busy_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, SHUTDOWN_LOCK_BUSY);
    assert_eq!(busy_pid, broker_pid);

    assert_eq!(unsafe { libc::write(gate[1], [1u8].as_ptr().cast(), 1) }, 1);
    unsafe { libc::close(gate[1]) };
    let welcome = read_frame(&mut second_output).unwrap().unwrap();
    assert!(matches!(
        decode_payload(&welcome).unwrap(),
        Message::Welcome { .. }
    ));
    let (event, accepted_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, NAMED_FRONTEND_ACCEPTED);
    assert_eq!(accepted_pid, broker_pid);
    let second = Frontend {
        child: second,
        input: second_input,
        output: second_output,
    };
    second.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn idle_shutdown_acquires_nonblocking_lock_and_unlinks_socket() {
    let runtime = RuntimeDir::new("idle-shutdown");
    let mut events = EventPipe::new();
    let frontend = Frontend::connect_with_event(&runtime.0, Some(events.writer));
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);
    frontend.close();
    let (event, shutdown_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, SHUTDOWN_LOCK_ACQUIRED);
    assert_eq!(shutdown_pid, broker_pid);
    wait_socket_gone(&runtime.socket());
    wait_process_gone(broker_pid);
}

#[test]
fn broker_death_kills_agent_descendants_and_never_rebuilds_an_old_session_id() {
    let runtime = RuntimeDir::new("broker-death");
    let mut events = EventPipe::new();
    let mut first = Frontend::connect_with_event(&runtime.0, Some(events.writer));
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);
    first.send(&Message::PtyStart {
        executable: "/bin/sh".to_string(),
        argv: vec![
            "-c".to_string(),
            "sleep 600 & read -r _; printf ready; wait".to_string(),
        ],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match first.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    };
    // The shell starts sleep before read. This input/output rendezvous proves
    // the descendant exists before the broker is killed.
    first.send(&Message::PtyInput {
        data_b64: "Z28K".to_string(),
    });
    first.recv_until(|message| matches!(message, Message::PtyOutput { .. }));
    first.send(&Message::PtyDetach);
    first.recv_until(|message| matches!(message, Message::PtyDetached));

    assert_eq!(unsafe { libc::kill(broker_pid, libc::SIGKILL) }, 0);
    drop(first.input);
    assert!(first.child.wait().unwrap().success());
    wait_process_group_gone(child_pid);

    let mut replacement = Frontend::connect(&runtime.0);
    replacement.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        replacement.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    replacement.close();
    wait_socket_gone(&runtime.socket());
}

fn read_broker_event(reader: &mut fs::File) -> (u8, i32) {
    use std::io::Read;
    let mut record = [0; 5];
    reader.read_exact(&mut record).unwrap();
    (
        record[0],
        i32::from_ne_bytes(record[1..].try_into().unwrap()),
    )
}

fn wait_process_group_gone(child_pid: u32) {
    loop {
        let rc = unsafe { libc::kill(-(child_pid as i32), 0) };
        if rc == -1 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            panic!("kill(-pgid, 0) failed: {error}");
        }
        std::thread::yield_now();
    }
}

fn wait_process_gone(pid: i32) {
    loop {
        let rc = unsafe { libc::kill(pid, 0) };
        if rc == -1 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            panic!("kill(pid, 0) failed: {error}");
        }
        std::thread::yield_now();
    }
}

fn wait_socket_gone(socket: &Path) {
    loop {
        match fs::symlink_metadata(socket) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("lstat broker.sock failed: {error}"),
            Ok(_) => std::thread::yield_now(),
        }
    }
}
