#![cfg(target_os = "linux")]

//! Linux end-to-end coverage runs in the required helper-linux-negatives Ubuntu CI job.
//! The tests exercise the real broker binary, lock file, Unix socket, PTY, and process group.

use std::ffi::OsString;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use winsmux_remote_helper::{
    decode_payload, encode_frame, encode_payload, AgentResolution, Message, RejectCode,
    MAX_EXECUTABLE_BYTES, MAX_FRAME_LEN, PREFIX_LEN, PROTOCOL_VERSION,
};

struct RuntimeDir(PathBuf);

static NEXT_RUNTIME_ID: AtomicU64 = AtomicU64::new(0);

fn helper_bin() -> PathBuf {
    std::env::var_os("WINSMUX_REMOTE_HELPER_UNDER_TEST")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_winsmux-remote-helper").into())
}

impl RuntimeDir {
    fn new(label: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let nonce = (nanos as u64) ^ ((nanos >> u64::BITS) as u64);
        Self::new_with_nonce(label, nonce)
    }

    fn new_with_nonce(_label: &str, nonce: u64) -> Self {
        let id = NEXT_RUNTIME_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "winsmux-task774-{}-{nonce:x}-{id:x}",
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

#[test]
fn runtime_dir_fixture_preserves_parallel_path_contract() {
    const PARALLEL_SAMPLE_SIZE: usize = 32;
    let barrier = Arc::new(Barrier::new(PARALLEL_SAMPLE_SIZE));
    let label = "long-runtime-label-".repeat(64);
    let creators: Vec<_> = (0..PARALLEL_SAMPLE_SIZE)
        .map(|_| {
            let barrier = Arc::clone(&barrier);
            let label = label.clone();
            thread::spawn(move || {
                barrier.wait();
                RuntimeDir::new_with_nonce(&label, 0)
            })
        })
        .collect();
    let runtimes: Vec<_> = creators
        .into_iter()
        .map(|creator| creator.join().unwrap())
        .collect();

    let mut paths = std::collections::HashSet::new();
    for runtime in &runtimes {
        assert!(
            paths.insert(runtime.0.clone()),
            "parallel RuntimeDir paths must be unique"
        );
        assert!(
            runtime.socket().as_os_str().as_bytes().len() <= 107,
            "socket path exceeds Linux sockaddr_un.sun_path"
        );
    }

    for runtime in runtimes {
        let path = runtime.0.clone();
        drop(runtime);
        assert!(!path.exists(), "RuntimeDir drop must remove its directory");
    }
}

struct Frontend {
    child: Child,
    input: ChildStdin,
    output: ChildStdout,
    stderr: Option<JoinHandle<Vec<u8>>>,
}

struct FrontendOptions {
    capabilities: Vec<String>,
    peer_frame_limit: u32,
    path: Option<OsString>,
    current_dir: Option<PathBuf>,
    home: Option<PathBuf>,
    capture_stderr: bool,
    agent_spawn_gate_fd: Option<RawFd>,
}

impl FrontendOptions {
    fn legacy() -> Self {
        Self {
            capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
            peer_frame_limit: MAX_FRAME_LEN,
            path: None,
            current_dir: None,
            home: None,
            capture_stderr: false,
            agent_spawn_gate_fd: None,
        }
    }

    fn agent() -> Self {
        let mut options = Self::legacy();
        options.capabilities.push("agent-path-v1".to_string());
        options
    }

    fn lifecycle() -> Self {
        let mut options = Self::legacy();
        options
            .capabilities
            .push("session-lifecycle-v1".to_string());
        options
    }
}

impl Frontend {
    fn connect(runtime: &Path) -> Self {
        Self::connect_with_event(runtime, None)
    }

    fn connect_capturing(runtime: &Path) -> Self {
        let mut options = FrontendOptions::legacy();
        options.capture_stderr = true;
        Self::connect_with_options(runtime, None, options)
    }

    fn connect_with_event(runtime: &Path, event_fd: Option<RawFd>) -> Self {
        Self::connect_with_options(runtime, event_fd, FrontendOptions::legacy())
    }

    fn connect_with_options(
        runtime: &Path,
        event_fd: Option<RawFd>,
        options: FrontendOptions,
    ) -> Self {
        Self::connect_with_options_and_gate(runtime, event_fd, None, options)
    }

    fn connect_with_options_and_gate(
        runtime: &Path,
        event_fd: Option<RawFd>,
        pty_started_gate_fd: Option<RawFd>,
        options: FrontendOptions,
    ) -> Self {
        let FrontendOptions {
            capabilities,
            peer_frame_limit,
            path,
            current_dir,
            home,
            capture_stderr,
            agent_spawn_gate_fd,
        } = options;
        let mut command = Command::new(helper_bin());
        command
            .args(["serve", "--stdio"])
            .env("XDG_RUNTIME_DIR", runtime)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(if capture_stderr {
                Stdio::piped()
            } else {
                Stdio::inherit()
            });
        if let Some(path) = path {
            command.env("PATH", path);
        }
        if let Some(current_dir) = current_dir {
            command.current_dir(current_dir);
        }
        if let Some(home) = home {
            command.env("HOME", home);
        }
        if let Some(event_fd) = event_fd {
            command.env("WINSMUX_TEST_BROKER_EVENT_FD", event_fd.to_string());
        }
        if let Some(gate_fd) = pty_started_gate_fd {
            command.env("WINSMUX_TEST_PTY_STARTED_GATE_FD", gate_fd.to_string());
        }
        if let Some(gate_fd) = agent_spawn_gate_fd {
            command.env("WINSMUX_TEST_AGENT_SPAWN_GATE_FD", gate_fd.to_string());
        }
        eprintln!("# connect {}", runtime.display());
        let mut child = command.spawn().unwrap();
        eprintln!("# spawned {}", child.id());
        let input = child.stdin.take().unwrap();
        let output = child.stdout.take().unwrap();
        let stderr =
            capture_stderr.then(|| drain_stderr(child.stderr.take().expect("stderr pipe")));
        let mut frontend = Self {
            child,
            input,
            output,
            stderr,
        };
        frontend.send(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_version: "task774-test".to_string(),
            nonce: "ab".repeat(32),
            capabilities,
            peer_frame_limit,
        });
        eprintln!("# hello sent");
        assert!(matches!(frontend.recv(), Message::Welcome { .. }));
        eprintln!("# welcome");
        frontend
    }

    fn send(&mut self, message: &Message) {
        write_all_deadline(&mut self.input, &encode_frame(message).unwrap(), "frontend");
    }

    fn recv(&mut self) -> Message {
        let payload = read_payload_deadline(&mut self.output, "frontend");
        decode_payload(&payload).unwrap()
    }

    fn recv_until(&mut self, expected: fn(&Message) -> bool) -> Message {
        let deadline = wait_deadline();
        loop {
            assert!(
                Instant::now() < deadline,
                "recv_until missed expected message within 15s"
            );
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

    fn try_recv(&mut self) -> Option<Message> {
        let mut poll_fd = libc::pollfd {
            fd: self.output.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut poll_fd, 1, 0) };
        assert!(result >= 0, "poll frontend output failed");
        (result > 0 && poll_fd.revents & libc::POLLIN != 0).then(|| self.recv())
    }

    fn close(mut self) {
        drop(self.input);
        let status = wait_child(&mut self.child, "frontend close");
        assert!(status.success());
    }

    fn close_and_read_stderr(mut self) -> Vec<u8> {
        drop(self.input);
        let status = wait_child(&mut self.child, "frontend close stderr");
        assert!(status.success());
        self.stderr
            .take()
            .expect("stderr drain")
            .join()
            .expect("stderr drain")
    }

    fn close_input_expecting_failure(mut self, what: &str) -> Vec<u8> {
        drop(self.input);
        drop(self.output);
        let status = wait_child(&mut self.child, what);
        assert!(!status.success(), "{what} unexpectedly succeeded");
        self.stderr
            .take()
            .expect("stderr drain")
            .join()
            .expect("stderr drain")
    }

    fn kill(mut self) {
        self.child.kill().unwrap();
        drop(self.input);
        drop(self.output);
        assert!(!wait_child(&mut self.child, "frontend kill").success());
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

struct GatePipe {
    reader: RawFd,
    writer: fs::File,
}

impl GatePipe {
    fn new() -> Self {
        let mut pipe = [0; 2];
        assert_eq!(unsafe { libc::pipe(pipe.as_mut_ptr()) }, 0);
        Self {
            reader: pipe[0],
            writer: unsafe { fs::File::from_raw_fd(pipe[1]) },
        }
    }

    fn release(&mut self, count: usize) {
        self.writer.write_all(&vec![1; count]).unwrap();
        self.writer.flush().unwrap();
    }
}

impl Drop for GatePipe {
    fn drop(&mut self) {
        unsafe { libc::close(self.reader) };
    }
}

fn start_cat(frontend: &mut Frontend) -> (String, u32) {
    eprintln!("# pty-start send");
    frontend.send(&Message::PtyStart {
        executable: "/bin/cat".to_string(),
        resolution: None,
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    });
    eprintln!("# pty-start recv");
    match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    }
}

fn start_sleep(frontend: &mut Frontend) -> (String, u32) {
    frontend.send(&Message::PtyStart {
        executable: "/bin/sleep".to_string(),
        resolution: None,
        argv: vec!["600".to_string()],
        cols: 80,
        rows: 24,
    });
    match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    }
}

fn start_reattach_transformer(frontend: &mut Frontend) -> (String, u32) {
    frontend.send(&Message::PtyStart {
        executable: "/bin/sh".to_string(),
        resolution: None,
        argv: vec![
            "-c".to_string(),
            "stty -echo; IFS= read -r _; printf 'task778-reattach-transform\\n'; exec sleep 600"
                .to_string(),
        ],
        cols: 80,
        rows: 24,
    });
    match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    }
}

fn start_partial_relay_probe(frontend: &mut Frontend) -> (String, u32) {
    frontend.send(&Message::PtyStart {
        executable: "/bin/sh".to_string(),
        resolution: None,
        argv: vec![
            "-c".to_string(),
            "stty -echo; IFS= read -r _; printf 'task778-partial-open\\n'; exec cat".to_string(),
        ],
        cols: 80,
        rows: 24,
    });
    match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    }
}

fn acknowledge_start(frontend: &mut Frontend, session_id: &str) {
    frontend.send(&Message::PtyStartAck {
        session_id: session_id.to_string(),
    });
}

fn resolution_start(
    executable: &str,
    absolute_path: Option<&Path>,
    user_candidates: &[PathBuf],
) -> Message {
    Message::PtyStart {
        executable: executable.to_string(),
        resolution: Some(AgentResolution {
            absolute_path: absolute_path.map(utf8_path),
            user_candidates: user_candidates.iter().map(|path| utf8_path(path)).collect(),
        }),
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    }
}

fn utf8_path(path: &Path) -> String {
    path.to_str().expect("UTF-8 fixture path").to_string()
}

fn make_agent_link(path: &Path) {
    fs::create_dir_all(path.parent().expect("agent parent")).unwrap();
    symlink("/bin/cat", path).unwrap();
}

fn make_marker_agent(path: &Path, marker: &Path) {
    fs::create_dir_all(path.parent().expect("agent parent")).unwrap();
    fs::write(
        path,
        format!(
            "#!/bin/sh\nprintf started > \"{}\"\nexec /bin/cat\n",
            marker.display()
        ),
    )
    .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

fn expect_resolved_start(frontend: &mut Frontend, expected: &Path) -> (String, u32) {
    match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            resolved_executable: Some(resolved_executable),
        } => {
            assert_eq!(resolved_executable, utf8_path(expected));
            (session_id, child_pid)
        }
        other => panic!("expected resolved pty-started, got {other:?}"),
    }
}

fn stop_started(frontend: &mut Frontend, session_id: String) {
    frontend.send(&Message::PtyStop { session_id });
    assert_eq!(frontend.recv(), Message::PtyStopped);
}

const PRIVATE_CANARY: &str = "task778-private-canary-7f3d9a";
const PRIVATE_CANARY_B64: &str = "dGFzazc3OC1wcml2YXRlLWNhbmFyeS03ZjNkOWE=";
const CONTROL_AGENT_BYTES_B64: &str =
    "eyJ0eXBlIjoicHR5LXN0b3BwZWQiLCJkZXRhaWwiOiJ0YXNrNzc4LXByaXZhdGUtY2FuYXJ5LTdmM2Q5YSJ9Cg==";

fn decode_test_base64(value: &str) -> Vec<u8> {
    fn sextet(byte: u8) -> u32 {
        match byte {
            b'A'..=b'Z' => (byte - b'A') as u32,
            b'a'..=b'z' => (byte - b'a' + 26) as u32,
            b'0'..=b'9' => (byte - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            _ => panic!("invalid test base64 byte: {byte}"),
        }
    }

    let bytes = value.as_bytes();
    assert_eq!(bytes.len() % 4, 0, "test base64 must be padded");
    let mut decoded = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks_exact(4) {
        let c = (chunk[2] != b'=').then(|| sextet(chunk[2])).unwrap_or(0);
        let d = (chunk[3] != b'=').then(|| sextet(chunk[3])).unwrap_or(0);
        if chunk[2] == b'=' {
            assert_eq!(chunk[3], b'=');
        }
        let word = (sextet(chunk[0]) << 18) | (sextet(chunk[1]) << 12) | (c << 6) | d;
        decoded.push((word >> 16) as u8);
        if chunk[2] != b'=' {
            decoded.push((word >> 8) as u8);
        }
        if chunk[3] != b'=' {
            decoded.push(word as u8);
        }
    }
    decoded
}

fn recv_agent_bytes(frontend: &mut Frontend, expected: &[u8]) {
    let mut observed = Vec::new();
    let deadline = wait_deadline();
    loop {
        assert!(
            Instant::now() < deadline,
            "agent bytes missing expected payload within 15s"
        );
        match frontend.recv() {
            Message::PtyOutput { data_b64 } => {
                observed.extend(decode_test_base64(&data_b64));
            }
            other => panic!("agent bytes became a control message: {other:?}"),
        }
        let normalized = observed
            .iter()
            .copied()
            .filter(|byte| *byte != b'\r')
            .collect::<Vec<_>>();
        if normalized
            .windows(expected.len())
            .any(|window| window == expected)
        {
            return;
        }
    }
}

fn expect_reject_without_canary(frontend: &mut Frontend, expected: RejectCode) {
    match frontend.recv() {
        Message::Reject { code, detail } => {
            assert_eq!(code, expected);
            assert!(!detail.contains(PRIVATE_CANARY));
            assert!(!detail.contains(PRIVATE_CANARY_B64));
        }
        other => panic!("expected {expected:?} reject, got {other:?}"),
    }
}

fn assert_log_has_no_canary(log: &[u8]) {
    let rendered = String::from_utf8_lossy(log);
    assert!(!rendered.contains(PRIVATE_CANARY), "private canary leaked");
    assert!(
        !rendered.contains(PRIVATE_CANARY_B64),
        "encoded private canary leaked"
    );
    assert!(
        !rendered.contains(CONTROL_AGENT_BYTES_B64),
        "encoded control payload leaked"
    );
}

fn directory_with_byte_len(base: &Path, target_len: usize) -> PathBuf {
    let mut path = base.to_path_buf();
    while path.as_os_str().as_bytes().len() < target_len {
        let current = path.as_os_str().as_bytes().len();
        let remaining = target_len - current;
        assert!(remaining >= 2, "cannot add a one-byte Unix path component");
        let mut increment = remaining.min(201);
        if remaining > increment && remaining - increment == 1 {
            increment -= 1;
        }
        path.push("x".repeat(increment - 1));
    }
    assert_eq!(path.as_os_str().as_bytes().len(), target_len);
    fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn truncated_stdin_prefix_and_payload_exit_nonzero() {
    let complete = encode_frame(&Message::PtyResize { cols: 81, rows: 25 }).unwrap();
    let cases = [
        ("prefix-1", complete[..1].to_vec()),
        ("prefix-2", complete[..2].to_vec()),
        ("prefix-3", complete[..3].to_vec()),
        ("payload", complete[..complete.len() - 1].to_vec()),
    ];

    for (label, fragment) in cases {
        let runtime = RuntimeDir::new(&format!("relay-truncated-{label}"));
        let mut frontend = Frontend::connect_capturing(&runtime.0);
        write_all_deadline(
            &mut frontend.input,
            &fragment,
            "truncated frontend fragment",
        );
        let stderr = frontend.close_input_expecting_failure("truncated frontend");
        let stderr = String::from_utf8_lossy(&stderr);
        assert!(
            stderr.contains("truncated stdin relay frame"),
            "missing truncated relay error for {label}: {stderr}"
        );
        wait_socket_gone(&runtime.socket());
    }
}

#[test]
fn partial_stdin_keeps_socket_progress_and_resumes_in_order() {
    let runtime = RuntimeDir::new("relay-partial-open");
    let mut frontend = Frontend::connect(&runtime.0);
    let (session_id, child_pid) = start_partial_relay_probe(&mut frontend);
    let trigger = encode_frame(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    })
    .unwrap();
    let resumed = encode_frame(&Message::PtyInput {
        data_b64: "cmVzdW1lCg==".to_string(),
    })
    .unwrap();
    let split = PREFIX_LEN + 1;
    let mut first_write = trigger;
    first_write.extend_from_slice(&resumed[..split]);
    write_all_deadline(
        &mut frontend.input,
        &first_write,
        "complete frame plus partial stdin frame",
    );

    recv_agent_bytes(&mut frontend, b"task778-partial-open\n");
    write_all_deadline(
        &mut frontend.input,
        &resumed[split..],
        "remaining stdin frame fragment",
    );
    recv_agent_bytes(&mut frontend, b"resume\n");

    frontend.send(&Message::PtyStop { session_id });
    assert_eq!(frontend.recv(), Message::PtyStopped);
    wait_process_group_gone(child_pid);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn complete_frame_reaches_agent_before_truncated_tail_fails() {
    let runtime = RuntimeDir::new("relay-complete-before-truncated");
    let options = FrontendOptions {
        capture_stderr: true,
        ..FrontendOptions::lifecycle()
    };
    let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);
    let (session_id, child_pid) = start_partial_relay_probe(&mut frontend);
    acknowledge_start(&mut frontend, &session_id);
    let trigger = encode_frame(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    })
    .unwrap();
    let tail = encode_frame(&Message::PtyInput {
        data_b64: "cmVzdW1lCg==".to_string(),
    })
    .unwrap();
    let mut input = trigger;
    input.extend_from_slice(&tail[..PREFIX_LEN + 1]);
    write_all_deadline(
        &mut frontend.input,
        &input,
        "complete frame plus truncated stdin tail",
    );

    recv_agent_bytes(&mut frontend, b"task778-partial-open\n");
    let stderr = frontend.close_input_expecting_failure("complete before truncated tail");
    let stderr = String::from_utf8_lossy(&stderr);
    assert!(
        stderr.contains("truncated stdin relay frame"),
        "missing truncated relay error: {stderr}"
    );

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
    wait_process_group_gone(child_pid);
    replacement.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn fragmented_and_coalesced_complete_frames_preserve_order() {
    let runtime = RuntimeDir::new("relay-fragmented-and-coalesced");
    let mut frontend = Frontend::connect(&runtime.0);
    let (session_id, child_pid) = start_partial_relay_probe(&mut frontend);
    let fragmented = encode_frame(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    })
    .unwrap();
    for byte in &fragmented {
        write_all_deadline(
            &mut frontend.input,
            std::slice::from_ref(byte),
            "one-byte complete stdin frame fragment",
        );
    }
    recv_agent_bytes(&mut frontend, b"task778-partial-open\n");

    let mut coalesced = encode_frame(&Message::PtyInput {
        data_b64: "cmVzdW1lCg==".to_string(),
    })
    .unwrap();
    coalesced.extend_from_slice(
        &encode_frame(&Message::PtyInput {
            data_b64: "dGhpcmQK".to_string(),
        })
        .unwrap(),
    );
    write_all_deadline(
        &mut frontend.input,
        &coalesced,
        "coalesced complete stdin frames",
    );
    recv_agent_bytes(&mut frontend, b"resume\nthird\n");

    frontend.send(&Message::PtyStop { session_id });
    assert_eq!(frontend.recv(), Message::PtyStopped);
    wait_process_group_gone(child_pid);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn partial_stdin_exits_after_broker_socket_eof() {
    let runtime = RuntimeDir::new("relay-partial-socket-eof");
    let mut events = EventPipe::new();
    let mut frontend = Frontend::connect_with_event(&runtime.0, Some(events.writer));
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);
    let (_, child_pid) = start_partial_relay_probe(&mut frontend);
    let trigger = encode_frame(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    })
    .unwrap();
    let partial = encode_frame(&Message::PtyInput {
        data_b64: "cmVzdW1lCg==".to_string(),
    })
    .unwrap();
    let mut input = trigger;
    input.extend_from_slice(&partial[..PREFIX_LEN + 1]);
    write_all_deadline(
        &mut frontend.input,
        &input,
        "complete frame plus partial stdin before socket eof",
    );
    recv_agent_bytes(&mut frontend, b"task778-partial-open\n");

    assert_eq!(unsafe { libc::kill(broker_pid, libc::SIGKILL) }, 0);
    let status = wait_child(&mut frontend.child, "partial stdin socket eof");
    assert!(status.success(), "partial stdin socket eof: {status}");
    wait_process_group_gone(child_pid);
}

#[test]
fn runtime_dir_final_symlink_is_rejected_without_leftovers() {
    eprintln!("# runtime_dir_final_symlink_is_rejected_without_leftovers");
    let root = RuntimeDir::new("runtime-final-symlink");
    let target = root.0.join("runtime-target");
    fs::create_dir(&target).unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
    let runtime_link = root.0.join("runtime-link");
    symlink(&target, &runtime_link).unwrap();

    let mut child = Command::new(helper_bin())
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime_link)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    drop(child.stdin.take());
    let status = wait_child(&mut child, "symlink runtime helper");
    let mut stdout = child.stdout.take().expect("stdout pipe");
    let stdout = read_to_end_deadline(&mut stdout, "symlink runtime stdout");

    assert!(!status.success());
    assert!(stdout.is_empty());
    assert!(!target.join("winsmux").exists());
    assert_eq!(fs::read_dir(&target).unwrap().count(), 0);
}

#[test]
fn resolution_without_agent_path_capability_rejects_before_agent_spawn() {
    let runtime = RuntimeDir::new("agent-capability");
    let marker = runtime.0.join("agent-started");
    let agent = runtime.0.join("fixtures/claude");
    make_marker_agent(&agent, &marker);
    let mut options = FrontendOptions::legacy();
    options.path = Some(OsString::new());
    let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);

    frontend.send(&resolution_start("claude", Some(&agent), &[]));
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::Unsupported,
            ..
        }
    ));
    assert!(!marker.exists(), "the Agent executable must not have run");
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn resolver_uses_absolute_then_inherited_path_then_candidates_for_both_agents() {
    for executable in ["claude", "codex"] {
        let runtime = RuntimeDir::new(&format!("precedence-{executable}"));
        let absolute = runtime.0.join("absolute").join(executable);
        let path_dir = runtime.0.join("path");
        let from_path = path_dir.join(executable);
        let candidate = runtime.0.join("candidate").join(executable);
        let later_candidate = runtime.0.join("later-candidate").join(executable);
        for path in [&absolute, &from_path, &candidate, &later_candidate] {
            make_agent_link(path);
        }
        let user_candidates = vec![candidate.clone(), later_candidate];
        let mut options = FrontendOptions::agent();
        options.path = Some(path_dir.as_os_str().to_os_string());
        options.capture_stderr = true;
        let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);

        frontend.send(&resolution_start(
            executable,
            Some(&absolute),
            &user_candidates,
        ));
        let (session_id, _) = expect_resolved_start(&mut frontend, &absolute);
        stop_started(&mut frontend, session_id);

        frontend.send(&resolution_start(executable, None, &user_candidates));
        let (session_id, _) = expect_resolved_start(&mut frontend, &from_path);
        stop_started(&mut frontend, session_id);

        fs::remove_file(&from_path).unwrap();
        frontend.send(&resolution_start(executable, None, &user_candidates));
        let (session_id, _) = expect_resolved_start(&mut frontend, &candidate);
        stop_started(&mut frontend, session_id);

        let stderr = String::from_utf8(frontend.close_and_read_stderr()).unwrap();
        for selected in [&absolute, &from_path, &candidate] {
            assert!(
                !stderr.contains(&utf8_path(selected)),
                "selected executable must not be logged"
            );
        }
        wait_socket_gone(&runtime.socket());
    }
}

#[test]
fn resolver_skips_unsafe_and_non_utf8_path_entries_without_private_scans() {
    let runtime = RuntimeDir::new("unsafe-path");
    let cwd = runtime.0.join("cwd");
    let relative = cwd.join("relative");
    let traversal_root = runtime.0.join("traversal");
    let traversal_safe = traversal_root.join("safe");
    let traversal_target = traversal_root.join("trap");
    let home = runtime.0.join("home");
    fs::create_dir_all(&traversal_safe).unwrap();
    for path in [
        cwd.join("claude"),
        relative.join("claude"),
        traversal_target.join("claude"),
        home.join(".local/bin/claude"),
        home.join(".claude/private/claude"),
    ] {
        make_agent_link(&path);
    }

    let mut invalid_bytes = runtime.0.as_os_str().as_bytes().to_vec();
    invalid_bytes.extend_from_slice(b"/invalid-\xff");
    let invalid_dir = PathBuf::from(OsString::from_vec(invalid_bytes));
    make_agent_link(&invalid_dir.join("claude"));

    let traversal_entry = traversal_safe.join("../trap");
    let mut path_bytes = b":.:relative:".to_vec();
    path_bytes.extend_from_slice(traversal_entry.as_os_str().as_bytes());
    path_bytes.push(b':');
    path_bytes.extend_from_slice(invalid_dir.as_os_str().as_bytes());
    let mut options = FrontendOptions::agent();
    options.path = Some(OsString::from_vec(path_bytes));
    options.current_dir = Some(cwd);
    options.home = Some(home);
    let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);

    frontend.send(&resolution_start("claude", None, &[]));
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::SpawnFailed,
            ..
        }
    ));
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn path_join_of_2567_bytes_is_skipped_for_bounded_candidate() {
    let runtime = RuntimeDir::new("overlong-path");
    let path_entry = directory_with_byte_len(&runtime.0.join("long"), 2_560);
    let overlong = path_entry.join("claude");
    assert_eq!(overlong.as_os_str().as_bytes().len(), 2_567);
    make_agent_link(&overlong);
    let candidate = runtime.0.join("candidate/claude");
    make_agent_link(&candidate);
    let mut options = FrontendOptions::agent();
    options.path = Some(path_entry.as_os_str().to_os_string());
    let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);

    frontend.send(&resolution_start(
        "claude",
        None,
        std::slice::from_ref(&candidate),
    ));
    let (session_id, _) = expect_resolved_start(&mut frontend, &candidate);
    stop_started(&mut frontend, session_id);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn missing_directory_and_non_executable_candidates_leave_no_registry_session() {
    for fixture in ["missing", "directory", "non-executable"] {
        let runtime = RuntimeDir::new(&format!("candidate-{fixture}"));
        let candidate = runtime.0.join("candidate/claude");
        match fixture {
            "missing" => {}
            "directory" => fs::create_dir_all(&candidate).unwrap(),
            "non-executable" => {
                fs::create_dir_all(candidate.parent().unwrap()).unwrap();
                fs::write(&candidate, b"not executable").unwrap();
                fs::set_permissions(&candidate, fs::Permissions::from_mode(0o600)).unwrap();
            }
            _ => unreachable!(),
        }
        let mut options = FrontendOptions::agent();
        options.path = Some(OsString::new());
        let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);
        frontend.send(&resolution_start(
            "claude",
            None,
            std::slice::from_ref(&candidate),
        ));
        assert!(matches!(
            frontend.recv(),
            Message::Reject {
                code: RejectCode::SpawnFailed,
                ..
            }
        ));
        frontend.close();
        wait_socket_gone(&runtime.socket());
    }
}

#[test]
fn other_execute_bit_without_euid_access_falls_through_to_path() {
    let runtime = RuntimeDir::new("other-x-only");
    let blocked = runtime.0.join("blocked/claude");
    fs::create_dir_all(blocked.parent().unwrap()).unwrap();
    fs::write(&blocked, b"#!/bin/sh\nexec /bin/cat\n").unwrap();
    fs::set_permissions(&blocked, fs::Permissions::from_mode(0o001)).unwrap();
    let usable = runtime.0.join("bin/claude");
    make_agent_link(&usable);
    let mut options = FrontendOptions::agent();
    options.path = Some(usable.parent().unwrap().as_os_str().to_os_string());
    let mut frontend = Frontend::connect_with_options(&runtime.0, None, options);
    frontend.send(&resolution_start("claude", Some(&blocked), &[]));
    let (session_id, _) = expect_resolved_start(&mut frontend, &usable);
    stop_started(&mut frontend, session_id);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn peer_limit_l_minus_one_rejects_before_spawn_and_l_may_start() {
    let rejected_runtime = RuntimeDir::new("peer-l-minus-one");
    let rejected_dir = directory_with_byte_len(&rejected_runtime.0.join("agent"), 249);
    let rejected_agent = rejected_dir.join("claude");
    assert_eq!(
        rejected_agent.as_os_str().as_bytes().len(),
        MAX_EXECUTABLE_BYTES
    );
    let marker = rejected_runtime.0.join("agent-started");
    make_marker_agent(&rejected_agent, &marker);
    let conservative_l = encode_payload(&Message::PtyStarted {
        session_id: "f".repeat(32),
        child_pid: u32::MAX,
        resolved_executable: Some(utf8_path(&rejected_agent)),
    })
    .unwrap()
    .len() as u32;
    assert!(conservative_l - 1 > 192, "Welcome must still fit");
    let mut options = FrontendOptions::agent();
    options.peer_frame_limit = conservative_l - 1;
    options.path = Some(OsString::new());
    let mut frontend = Frontend::connect_with_options(&rejected_runtime.0, None, options);
    frontend.send(&resolution_start("claude", Some(&rejected_agent), &[]));
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::PeerLimit,
            ..
        }
    ));
    assert!(!marker.exists(), "L-1 must reject before Agent execve");
    frontend.close();
    wait_socket_gone(&rejected_runtime.socket());

    let accepted_runtime = RuntimeDir::new("peer-l");
    let accepted_dir = directory_with_byte_len(&accepted_runtime.0.join("agent"), 249);
    let accepted_agent = accepted_dir.join("claude");
    assert_eq!(
        accepted_agent.as_os_str().as_bytes().len(),
        MAX_EXECUTABLE_BYTES
    );
    make_agent_link(&accepted_agent);
    let conservative_l = encode_payload(&Message::PtyStarted {
        session_id: "f".repeat(32),
        child_pid: u32::MAX,
        resolved_executable: Some(utf8_path(&accepted_agent)),
    })
    .unwrap()
    .len() as u32;
    let mut options = FrontendOptions::agent();
    options.peer_frame_limit = conservative_l;
    options.path = Some(OsString::new());
    let mut frontend = Frontend::connect_with_options(&accepted_runtime.0, None, options);
    frontend.send(&resolution_start("claude", Some(&accepted_agent), &[]));
    let response = frontend.recv();
    assert!(encode_payload(&response).unwrap().len() <= conservative_l as usize);
    let (session_id, resolved_executable) = match response {
        Message::PtyStarted {
            session_id,
            resolved_executable: Some(resolved_executable),
            ..
        } => (session_id, resolved_executable),
        other => panic!("expected pty-started at L, got {other:?}"),
    };
    assert_eq!(resolved_executable, utf8_path(&accepted_agent));
    stop_started(&mut frontend, session_id);
    frontend.close();
    wait_socket_gone(&accepted_runtime.socket());
}

#[test]
fn resolved_session_detaches_attaches_to_same_pid_and_stops() {
    let runtime = RuntimeDir::new("resolved-reattach");
    let candidate = runtime.0.join("candidate/claude");
    make_agent_link(&candidate);
    let mut options = FrontendOptions::agent();
    options.path = Some(OsString::new());
    let mut first = Frontend::connect_with_options(&runtime.0, None, options);
    first.send(&resolution_start(
        "claude",
        None,
        std::slice::from_ref(&candidate),
    ));
    let (session_id, child_pid) = expect_resolved_start(&mut first, &candidate);
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
    stop_started(&mut second, session_id.clone());
    second.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        second.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    second.close();
    wait_process_group_gone(child_pid);
    wait_socket_gone(&runtime.socket());
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
fn observer_controls_are_rejected_while_owner_can_still_stop() {
    let runtime = RuntimeDir::new("observer-controls");
    let mut owner = Frontend::connect_capturing(&runtime.0);
    let (session_id, _) = start_cat(&mut owner);
    let mut contender = Frontend::connect_capturing(&runtime.0);

    contender.send(&Message::PtyInput {
        data_b64: PRIVATE_CANARY_B64.to_string(),
    });
    expect_reject_without_canary(&mut contender, RejectCode::NotController);

    contender.send(&Message::PtyResize {
        cols: 100,
        rows: 30,
    });
    expect_reject_without_canary(&mut contender, RejectCode::NotController);

    contender.send(&Message::PtyStop {
        session_id: session_id.clone(),
    });
    expect_reject_without_canary(&mut contender, RejectCode::NotController);

    contender.send(&Message::PtyAttach {
        session_id: session_id.clone(),
    });
    expect_reject_without_canary(&mut contender, RejectCode::ControllerBusy);

    owner.send(&Message::PtyStop { session_id });
    owner.recv_until(|message| matches!(message, Message::PtyStopped));

    let contender_log = contender.close_and_read_stderr();
    let owner_log = owner.close_and_read_stderr();
    assert_log_has_no_canary(&contender_log);
    assert_log_has_no_canary(&owner_log);
    wait_socket_gone(&runtime.socket());
}

#[test]
fn fake_done_and_control_json_remain_agent_output_until_owner_stops() {
    let runtime = RuntimeDir::new("fake-done-output");
    let mut owner = Frontend::connect_capturing(&runtime.0);
    let (session_id, _) = start_cat(&mut owner);

    owner.send(&Message::PtyInput {
        data_b64: "ZG9uZQo=".to_string(),
    });
    recv_agent_bytes(&mut owner, b"done\n");

    owner.send(&Message::PtyInput {
        data_b64: CONTROL_AGENT_BYTES_B64.to_string(),
    });
    recv_agent_bytes(
        &mut owner,
        format!("{{\"type\":\"pty-stopped\",\"detail\":\"{PRIVATE_CANARY}\"}}\n").as_bytes(),
    );

    owner.send(&Message::PtyStop { session_id });
    owner.recv_until(|message| matches!(message, Message::PtyStopped));
    let owner_log = owner.close_and_read_stderr();
    assert_log_has_no_canary(&owner_log);
    wait_socket_gone(&runtime.socket());
}

#[test]
fn natural_exit_removes_registry_and_process_group() {
    let runtime = RuntimeDir::new("natural-exit");
    let mut frontend = Frontend::connect(&runtime.0);
    let (session_id, child_pid) = start_cat(&mut frontend);
    // EOT at an empty canonical input line gives cat EOF only after the
    // legacy PtyStarted contract has been observed.
    frontend.send(&Message::PtyInput {
        data_b64: "BA==".to_string(),
    });
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
        resolution: None,
        argv: vec!["1".to_string(), "100000".to_string()],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
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
        resolution: None,
        argv: vec!["-c".to_string(), "stty -echo; exec sleep 600".to_string()],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match first.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
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

#[test]
fn lifecycle_gate_a_reaps_pending_start_before_byte_one_and_recovers() {
    let runtime = RuntimeDir::new("lifecycle-gate-a");
    let mut events = EventPipe::new();
    let mut gate = GatePipe::new();
    let mut frontend = Frontend::connect_with_options_and_gate(
        &runtime.0,
        Some(events.writer),
        Some(gate.reader),
        FrontendOptions::lifecycle(),
    );

    frontend.send(&Message::PtyStart {
        executable: "/bin/cat".to_string(),
        resolution: None,
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    });
    let agent_pgid = read_event_with_code(&mut events.reader, PTY_STARTED_PENDING);
    kill_process_group(agent_pgid);
    wait_matching_w_without_g(&mut events.reader, agent_pgid);
    wait_process_group_gone(agent_pgid as u32);

    gate.release(1);
    assert!(matches!(
        frontend.recv(),
        Message::Reject {
            code: RejectCode::SpawnFailed,
            ..
        }
    ));
    assert!(drain_ready_events(&mut events.reader)
        .into_iter()
        .all(|(code, pgid)| code != PTY_STARTED_WRITING || pgid != agent_pgid));

    gate.release(2);
    let (session_id, _) = start_cat(&mut frontend);
    stop_started(&mut frontend, session_id);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn lifecycle_gate_b_finishes_started_then_reports_exit_and_recovers() {
    let runtime = RuntimeDir::new("lifecycle-gate-b");
    let mut events = EventPipe::new();
    let mut gate = GatePipe::new();
    let mut frontend = Frontend::connect_with_options_and_gate(
        &runtime.0,
        Some(events.writer),
        Some(gate.reader),
        FrontendOptions::lifecycle(),
    );

    frontend.send(&Message::PtyStart {
        executable: "/bin/sleep".to_string(),
        resolution: None,
        argv: vec!["600".to_string()],
        cols: 80,
        rows: 24,
    });
    let agent_pgid = read_event_with_code(&mut events.reader, PTY_STARTED_PENDING);
    gate.release(1);
    read_matching_event(&mut events.reader, PTY_STARTED_WRITING, agent_pgid);
    kill_process_group(agent_pgid);
    wait_process_group_gone(agent_pgid as u32);
    gate.release(1);

    let session_id = match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => {
            assert_eq!(child_pid, agent_pgid as u32);
            session_id
        }
        other => panic!("expected pty-started, got {other:?}"),
    };
    assert_eq!(
        frontend.recv_until(|message| matches!(message, Message::PtyExited { .. })),
        Message::PtyExited { session_id }
    );
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, agent_pgid);

    gate.release(2);
    let (recovery_id, _) = start_cat(&mut frontend);
    stop_started(&mut frontend, recovery_id);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn lifecycle_disconnect_before_ack_reaps_and_forgets_session() {
    let runtime = RuntimeDir::new("lifecycle-unacked-disconnect");
    let mut frontend =
        Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
    let (session_id, child_pid) = start_cat(&mut frontend);
    frontend.close();
    wait_process_group_gone(child_pid);

    let mut replacement =
        Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
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

#[test]
fn lifecycle_detach_before_ack_reaps_and_forgets_session() {
    let runtime = RuntimeDir::new("lifecycle-unacked-detach");
    let mut frontend =
        Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
    let (session_id, child_pid) = start_cat(&mut frontend);
    frontend.send(&Message::PtyDetach);
    assert_eq!(frontend.recv(), Message::PtyDetached);
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
fn failed_pty_started_write_reaps_row_and_allows_recovery() {
    let runtime = RuntimeDir::new("lifecycle-start-write-failure");
    let mut events = EventPipe::new();
    let mut gate = GatePipe::new();
    let mut frontend = Frontend::connect_with_options_and_gate(
        &runtime.0,
        Some(events.writer),
        Some(gate.reader),
        FrontendOptions::lifecycle(),
    );
    frontend.send(&Message::PtyStart {
        executable: "/bin/sleep".to_string(),
        resolution: None,
        argv: vec!["600".to_string()],
        cols: 80,
        rows: 24,
    });
    let agent_pgid = read_event_with_code(&mut events.reader, PTY_STARTED_PENDING);
    gate.release(1);
    read_matching_event(&mut events.reader, PTY_STARTED_WRITING, agent_pgid);
    frontend.kill();
    gate.release(1);
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, agent_pgid);
    wait_process_group_gone(agent_pgid as u32);

    gate.release(2);
    let mut recovery = Frontend::connect_with_options_and_gate(
        &runtime.0,
        Some(events.writer),
        Some(gate.reader),
        FrontendOptions::lifecycle(),
    );
    let (session_id, _) = start_cat(&mut recovery);
    stop_started(&mut recovery, session_id);
    recovery.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn acknowledged_unsolicited_exit_pushes_and_same_connection_recovers() {
    let runtime = RuntimeDir::new("lifecycle-acked-exit");
    let mut events = EventPipe::new();
    let mut frontend = Frontend::connect_with_options(
        &runtime.0,
        Some(events.writer),
        FrontendOptions::lifecycle(),
    );
    frontend.send(&Message::PtyStart {
        executable: "/bin/sh".to_string(),
        resolution: None,
        argv: vec!["-c".to_string(), "read _; exit 0".to_string()],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match frontend.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    };
    acknowledge_start(&mut frontend, &session_id);
    frontend.send(&Message::PtyInput {
        data_b64: "Cg==".to_string(),
    });
    assert_eq!(
        frontend.recv_until(|message| matches!(message, Message::PtyExited { .. })),
        Message::PtyExited {
            session_id: session_id.clone(),
        }
    );
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, child_pid as i32);

    let (recovery_id, _) = start_cat(&mut frontend);
    stop_started(&mut frontend, recovery_id);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

fn assert_ack_ok(reader: &mut fs::File, child_pid: i32) {
    let deadline = wait_deadline();
    loop {
        assert!(
            Instant::now() < deadline,
            "pty-start-ack event missing within 15s"
        );
        let (code, subject) = read_broker_event(reader);
        match code {
            PTY_START_ACK_OK => {
                assert_eq!(subject, child_pid);
                return;
            }
            PTY_START_ACK_REJECT => {
                panic!("pty-start-ack rejected (reason_tag={subject})")
            }
            PTY_DETACH_REAPED => {
                panic!("detach reaped before pty-start-ack ok (pgid={subject})")
            }
            _ => {}
        }
    }
}

#[test]
fn acknowledged_detach_and_close_remains_attachable() {
    std::env::set_var("WINSMUX_TEST_DISCONNECT_TRACE", "1");
    let runtime = RuntimeDir::new("lifecycle-acked-reattach");
    let mut events = EventPipe::new();
    let mut first = Frontend::connect_with_options(
        &runtime.0,
        Some(events.writer),
        FrontendOptions::lifecycle(),
    );
    let (code, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(code, BROKER_READY);
    let (session_id, child_pid) = start_reattach_transformer(&mut first);
    acknowledge_start(&mut first, &session_id);
    assert_ack_ok(&mut events.reader, child_pid as i32);
    assert_eq!(
        unsafe { libc::kill(child_pid as i32, 0) },
        0,
        "agent must be alive after ack"
    );
    first.send(&Message::PtyDetach);
    assert_eq!(first.recv(), Message::PtyDetached);
    assert_eq!(
        unsafe { libc::kill(child_pid as i32, 0) },
        0,
        "agent must be alive after detach (no unconfirmed reap)"
    );
    first.close();
    // After detach the controller is cleared; disconnect should leave the row.
    // X = remaining session count, Y = confirmed pgid, k = disconnect reap.
    let deadline = Instant::now() + Duration::from_millis(500);
    let mut saw_x = None;
    while Instant::now() < deadline {
        if let Some((code, subject)) = try_read_broker_event(&mut events.reader) {
            eprintln!(
                "# post-close-event code={} subject={}",
                code as char, subject
            );
            if code == AGENT_EXIT_STATUS {
                eprintln!("# agent-wait-status {}", format_wait_status(subject));
            }
            if code == b'X' {
                saw_x = Some(subject);
            }
            assert_ne!(code, DISCONNECT_REAP, "disconnect reaped pgid={subject}");
            assert_ne!(code, PTY_DETACH_REAPED, "late detach reap pgid={subject}");
            assert_ne!(
                code, PROCESS_GROUP_STOP,
                "agent signalled before reattach pgid={subject}"
            );
            assert_ne!(
                code, SESSION_ROW_REMOVED,
                "session row removed before reattach pgid={subject}"
            );
            assert_ne!(
                code, AGENT_WATCHER_REMOVED,
                "agent exited before reattach pgid={subject}"
            );
            assert_ne!(
                code, AGENT_EXIT_STATUS,
                "agent wait completed before reattach status={subject}"
            );
            assert_ne!(
                code, SHUTDOWN_LOCK_ACQUIRED,
                "broker shut down before reattach pid={subject}"
            );
        } else {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    assert_eq!(saw_x, Some(1), "expected one confirmed session after close");
    assert_eq!(
        unsafe { libc::kill(broker_pid, 0) },
        0,
        "broker must survive frontend close"
    );
    assert_eq!(
        unsafe { libc::kill(child_pid as i32, 0) },
        0,
        "agent must survive frontend close"
    );
    assert!(
        runtime.socket().exists(),
        "broker socket must remain while detached session persists"
    );

    let mut second = Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
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
    second.send(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    });
    recv_agent_bytes(&mut second, b"task778-reattach-transform\n");
    second.send(&Message::PtyStop { session_id });
    assert_eq!(second.recv(), Message::PtyStopped);
    wait_process_group_gone(child_pid);
    second.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn packaged_release_detach_close_reattach_io_and_stop_is_protocol_visible() {
    let runtime = RuntimeDir::new("packaged-release-reattach");
    let mut first = Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
    let (session_id, child_pid) = start_reattach_transformer(&mut first);
    acknowledge_start(&mut first, &session_id);
    first.send(&Message::PtyDetach);
    assert_eq!(first.recv(), Message::PtyDetached);
    first.close();

    let mut second = Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
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
    second.send(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    });
    recv_agent_bytes(&mut second, b"task778-reattach-transform\n");
    second.send(&Message::PtyStop {
        session_id: session_id.clone(),
    });
    assert_eq!(second.recv(), Message::PtyStopped);
    second.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        second.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    second.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn guardian_does_not_retain_unrelated_frontend_socket() {
    let runtime = RuntimeDir::new("guardian-fd");
    let mut owner = Frontend::connect(&runtime.0);
    let unrelated = Frontend::connect(&runtime.0);

    // The guardian is forked after both broker-side frontend sockets exist.
    // Closing the unrelated frontend can finish only if that guardian did not
    // retain the broker's copy of its socket.
    let (session_id, child_pid) = start_sleep(&mut owner);
    unrelated.close();
    assert_eq!(
        unsafe { libc::kill(child_pid as i32, 0) },
        0,
        "closing an unrelated frontend must not stop the guarded agent"
    );

    owner.send(&Message::PtyStop { session_id });
    assert_eq!(owner.recv(), Message::PtyStopped);
    wait_process_group_gone(child_pid);
    owner.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn stopping_one_session_does_not_wait_for_another_guardian() {
    let runtime = RuntimeDir::new("two-session-guardian-disarm");
    let mut first = Frontend::connect(&runtime.0);
    let (first_session_id, first_child_pid) = start_sleep(&mut first);
    let mut second = Frontend::connect(&runtime.0);
    let (second_session_id, second_child_pid) = start_reattach_transformer(&mut second);

    first.send(&Message::PtyStop {
        session_id: first_session_id,
    });
    assert_eq!(first.recv(), Message::PtyStopped);
    wait_process_group_gone(first_child_pid);

    assert_eq!(
        unsafe { libc::kill(-(second_child_pid as i32), 0) },
        0,
        "the second session must remain alive after the first session stops"
    );
    second.send(&Message::PtyInput {
        data_b64: "d2FrZQo=".to_string(),
    });
    recv_agent_bytes(&mut second, b"task778-reattach-transform\n");

    second.send(&Message::PtyStop {
        session_id: second_session_id,
    });
    assert_eq!(second.recv(), Message::PtyStopped);
    wait_process_group_gone(second_child_pid);
    second.close();
    first.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn concurrent_starts_are_serialized_before_fork_and_broker_death_kills_both_groups() {
    let runtime = RuntimeDir::new("concurrent-guardian-ownership");
    let mut events = EventPipe::new();
    let mut gate = GatePipe::new();
    let mut options = FrontendOptions::legacy();
    options.agent_spawn_gate_fd = Some(gate.reader);
    let mut first = Frontend::connect_with_options(&runtime.0, Some(events.writer), options);
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);
    let mut second = Frontend::connect(&runtime.0);

    let start_with_descendant = |marker: &str| {
        Message::PtyStart {
            executable: "/bin/sh".to_string(),
            resolution: None,
            argv: vec![
                "-c".to_string(),
                format!(
                    "sleep 600 & child=$!; until kill -0 \"$child\"; do :; done; printf '{marker}\\n'; read -r _; wait \"$child\""
                ),
            ],
            cols: 80,
            rows: 24,
        }
    };

    first.send(&start_with_descendant("task778-concurrent-a-ready"));
    assert_eq!(
        read_event_with_code(&mut events.reader, AGENT_SPAWN_GATE_ENTER),
        broker_pid
    );
    second.send(&start_with_descendant("task778-concurrent-b-ready"));
    assert_eq!(
        read_event_with_code(&mut events.reader, AGENT_SPAWN_LOCK_CONTENDED),
        broker_pid,
        "the second start must wait at the broker-wide spawn lock"
    );

    gate.release(1);
    assert_eq!(
        read_event_with_code(&mut events.reader, AGENT_SPAWN_GATE_ENTER),
        broker_pid
    );
    gate.release(1);

    let (_, first_child_pid) = match first.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected first pty-started, got {other:?}"),
    };
    let (_, second_child_pid) = match second.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected second pty-started, got {other:?}"),
    };
    recv_agent_bytes(&mut first, b"task778-concurrent-a-ready\n");
    recv_agent_bytes(&mut second, b"task778-concurrent-b-ready\n");

    assert_eq!(unsafe { libc::kill(broker_pid, libc::SIGKILL) }, 0);
    drop(first.input);
    drop(second.input);
    assert!(wait_child(&mut first.child, "concurrent first frontend").success());
    assert!(wait_child(&mut second.child, "concurrent second frontend").success());
    wait_process_group_gone(first_child_pid);
    wait_process_group_gone(second_child_pid);

    // A replacement broker must be able to remove the stale listener and bind
    // the same path; its normal idle shutdown then removes the socket entry.
    Frontend::connect(&runtime.0).close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn detached_unsolicited_exit_has_no_push_and_is_not_attachable() {
    let runtime = RuntimeDir::new("lifecycle-detached-exit");
    let mut events = EventPipe::new();
    let mut first = Frontend::connect_with_options(
        &runtime.0,
        Some(events.writer),
        FrontendOptions::lifecycle(),
    );
    let (session_id, child_pid) = start_sleep(&mut first);
    acknowledge_start(&mut first, &session_id);
    first.send(&Message::PtyDetach);
    assert_eq!(first.recv(), Message::PtyDetached);
    kill_process_group(child_pid as i32);
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, child_pid as i32);
    wait_process_group_gone(child_pid);
    assert_eq!(first.try_recv(), None);

    let mut second = Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
    second.send(&Message::PtyAttach { session_id });
    assert!(matches!(
        second.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    first.close();
    second.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn lifecycle_stop_returns_stopped_without_exited_push() {
    let runtime = RuntimeDir::new("lifecycle-stop");
    let mut events = EventPipe::new();
    let mut frontend = Frontend::connect_with_options(
        &runtime.0,
        Some(events.writer),
        FrontendOptions::lifecycle(),
    );
    let (session_id, child_pid) = start_sleep(&mut frontend);
    acknowledge_start(&mut frontend, &session_id);
    stop_started(&mut frontend, session_id);
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, child_pid as i32);
    assert_eq!(frontend.try_recv(), None);
    frontend.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn capable_birth_legacy_controller_gets_no_push_or_reconcile() {
    let runtime = RuntimeDir::new("lifecycle-capable-to-legacy");
    let mut events = EventPipe::new();
    let mut capable = Frontend::connect_with_options(
        &runtime.0,
        Some(events.writer),
        FrontendOptions::lifecycle(),
    );
    let (session_id, child_pid) = start_sleep(&mut capable);
    acknowledge_start(&mut capable, &session_id);
    capable.send(&Message::PtyDetach);
    assert_eq!(capable.recv(), Message::PtyDetached);
    capable.close();

    let mut legacy = Frontend::connect(&runtime.0);
    legacy.send(&Message::PtyAttach {
        session_id: session_id.clone(),
    });
    assert!(matches!(legacy.recv(), Message::PtyAttached { .. }));
    kill_process_group(child_pid as i32);
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, child_pid as i32);
    wait_process_group_gone(child_pid);
    assert_eq!(legacy.try_recv(), None);

    legacy.send(&Message::PtyStart {
        executable: "/bin/cat".to_string(),
        resolution: None,
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    });
    assert!(matches!(
        legacy.recv(),
        Message::Reject {
            code: RejectCode::ControllerBusy,
            ..
        }
    ));
    legacy.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn legacy_birth_capable_controller_gets_push_and_reconcile() {
    let runtime = RuntimeDir::new("lifecycle-legacy-to-capable");
    let mut events = EventPipe::new();
    let mut legacy = Frontend::connect_with_event(&runtime.0, Some(events.writer));
    let (session_id, child_pid) = start_sleep(&mut legacy);
    legacy.send(&Message::PtyDetach);
    assert_eq!(legacy.recv(), Message::PtyDetached);
    legacy.close();

    let mut capable =
        Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
    capable.send(&Message::PtyAttach {
        session_id: session_id.clone(),
    });
    assert!(matches!(capable.recv(), Message::PtyAttached { .. }));
    acknowledge_start(&mut capable, &session_id);
    assert_ack_ok(&mut events.reader, child_pid as i32);
    kill_process_group(child_pid as i32);
    read_matching_event(&mut events.reader, AGENT_WATCHER_REMOVED, child_pid as i32);
    wait_process_group_gone(child_pid);
    assert_eq!(
        capable.recv_until(|message| matches!(message, Message::PtyExited { .. })),
        Message::PtyExited { session_id }
    );

    let (recovery_id, _) = start_cat(&mut capable);
    stop_started(&mut capable, recovery_id);
    capable.close();
    wait_socket_gone(&runtime.socket());
}

#[test]
fn lifecycle_ack_requires_capability_and_controller_and_client_exited_is_unknown() {
    let runtime = RuntimeDir::new("lifecycle-direction-errors");
    let mut legacy = Frontend::connect(&runtime.0);
    let (session_id, _) = start_cat(&mut legacy);
    legacy.send(&Message::PtyStartAck {
        session_id: session_id.clone(),
    });
    assert!(matches!(
        legacy.recv(),
        Message::Reject {
            code: RejectCode::Unsupported,
            ..
        }
    ));
    legacy.send(&Message::PtyExited {
        session_id: session_id.clone(),
    });
    assert!(matches!(
        legacy.recv(),
        Message::Reject {
            code: RejectCode::UnknownType,
            ..
        }
    ));

    let mut capable =
        Frontend::connect_with_options(&runtime.0, None, FrontendOptions::lifecycle());
    capable.send(&Message::PtyStartAck {
        session_id: "f".repeat(32),
    });
    assert!(matches!(
        capable.recv(),
        Message::Reject {
            code: RejectCode::SessionNotFound,
            ..
        }
    ));
    capable.send(&Message::PtyStartAck {
        session_id: session_id.clone(),
    });
    assert!(matches!(
        capable.recv(),
        Message::Reject {
            code: RejectCode::NotController,
            ..
        }
    ));

    stop_started(&mut legacy, session_id);
    legacy.close();
    capable.close();
    wait_socket_gone(&runtime.socket());
}

// The broker emits these records from the actual listener and shutdown branches.
const BROKER_READY: u8 = b'R';
const FRONTEND_LOCK_ACQUIRED: u8 = b'L';
const SHUTDOWN_LOCK_BUSY: u8 = b'B';
const NAMED_FRONTEND_ACCEPTED: u8 = b'A';
const SHUTDOWN_LOCK_ACQUIRED: u8 = b'S';
const PTY_START_DISPATCHED: u8 = b'T';
const PTY_STARTED_PENDING: u8 = b'P';
const PTY_STARTED_WRITING: u8 = b'G';
const AGENT_SPAWN_GATE_ENTER: u8 = b'F';
const AGENT_SPAWN_LOCK_CONTENDED: u8 = b'f';
const PTY_START_ACK_OK: u8 = b'C';
const PTY_START_ACK_REJECT: u8 = b'c';
const PTY_DETACH_REAPED: u8 = b'D';
const DISCONNECT_KEEP: u8 = b'K';
const DISCONNECT_REAP: u8 = b'k';
const AGENT_WATCHER_REMOVED: u8 = b'W';
const SESSION_ROW_REMOVED: u8 = b'm';
const PROCESS_GROUP_STOP: u8 = b'Q';
const AGENT_EXIT_STATUS: u8 = b'e';

#[test]
fn lock_owner_exit_before_connect_wakes_idle_broker_shutdown() {
    let runtime = RuntimeDir::new("lock-owner-exits");
    let mut events = EventPipe::new();
    let first = Frontend::connect_with_event(&runtime.0, Some(events.writer));
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);

    let mut gate = [-1; 2];
    assert_eq!(unsafe { libc::pipe(gate.as_mut_ptr()) }, 0);
    let mut second = Command::new(helper_bin())
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime.0)
        .env("WINSMUX_TEST_BROKER_EVENT_FD", events.writer.to_string())
        .env("WINSMUX_TEST_FRONTEND_GATE_FD", gate[0].to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let second_pid = second.id() as i32;
    let mut second_input = second.stdin.take().unwrap();
    let second_output = second.stdout.take().unwrap();
    unsafe { libc::close(gate[0]) };
    write_all_deadline(
        &mut second_input,
        &encode_frame(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_version: "lock-owner-exits".to_string(),
            nonce: "ef".repeat(32),
            capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
            peer_frame_limit: MAX_FRAME_LEN,
        })
        .unwrap(),
        "lock-owner-exits hello",
    );
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
    assert!(!wait_child(&mut second, "lock-owner second").success());
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

    let mut first = Command::new(helper_bin())
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime.0)
        .env("WINSMUX_TEST_BROKER_EVENT_FD", events.writer.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut first_input = first.stdin.take().unwrap();
    let mut first_output = first.stdout.take().unwrap();
    write_all_deadline(
        &mut first_input,
        &encode_frame(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_version: "barrier".to_string(),
            nonce: "cd".repeat(32),
            capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
            peer_frame_limit: MAX_FRAME_LEN,
        })
        .unwrap(),
        "barrier hello",
    );
    let (event, broker_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, BROKER_READY);
    let welcome = read_frame_deadline(&mut first_output);
    assert!(matches!(
        decode_payload(&welcome).unwrap(),
        Message::Welcome { .. }
    ));

    let mut gate = [-1; 2];
    assert_eq!(unsafe { libc::pipe(gate.as_mut_ptr()) }, 0);
    let mut second = Command::new(helper_bin())
        .args(["serve", "--stdio"])
        .env("XDG_RUNTIME_DIR", &runtime.0)
        .env("WINSMUX_TEST_BROKER_EVENT_FD", events.writer.to_string())
        .env("WINSMUX_TEST_FRONTEND_GATE_FD", gate[0].to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let second_pid = second.id() as i32;
    let mut second_input = second.stdin.take().unwrap();
    let mut second_output = second.stdout.take().unwrap();
    unsafe { libc::close(gate[0]) };
    write_all_deadline(
        &mut second_input,
        &encode_frame(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_version: "barrier-b".to_string(),
            nonce: "ef".repeat(32),
            capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
            peer_frame_limit: MAX_FRAME_LEN,
        })
        .unwrap(),
        "barrier-b hello",
    );
    let (event, lock_owner_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, FRONTEND_LOCK_ACQUIRED);
    assert_eq!(lock_owner_pid, second_pid);

    drop(first_input);
    assert!(wait_child(&mut first, "barrier first").success());

    let (event, busy_pid) = read_broker_event(&mut events.reader);
    assert_eq!(event, SHUTDOWN_LOCK_BUSY);
    assert_eq!(busy_pid, broker_pid);

    assert_eq!(unsafe { libc::write(gate[1], [1u8].as_ptr().cast(), 1) }, 1);
    unsafe { libc::close(gate[1]) };
    let welcome = read_frame_deadline(&mut second_output);
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
        stderr: None,
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
        resolution: None,
        argv: vec![
            "-c".to_string(),
            "sleep 600 & child=$!; until kill -0 \"$child\"; do :; done; printf 'task778-descendant-ready\\n'; read -r _; wait \"$child\"".to_string(),
        ],
        cols: 80,
        rows: 24,
    });
    let (session_id, child_pid) = match first.recv() {
        Message::PtyStarted {
            session_id,
            child_pid,
            ..
        } => (session_id, child_pid),
        other => panic!("expected pty-started, got {other:?}"),
    };
    // The shell emits this marker only after `kill -0 "$!"` observes its
    // background child; it is not terminal echo from a frontend input frame.
    recv_agent_bytes(&mut first, b"task778-descendant-ready\n");
    first.send(&Message::PtyDetach);
    first.recv_until(|message| matches!(message, Message::PtyDetached));

    assert_eq!(unsafe { libc::kill(broker_pid, libc::SIGKILL) }, 0);
    drop(first.input);
    assert!(wait_child(&mut first.child, "killed-broker frontend").success());
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

fn drain_stderr(mut stderr: std::process::ChildStderr) -> JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr.read_to_end(&mut buf);
        buf
    })
}

fn wait_child(child: &mut Child, what: &str) -> std::process::ExitStatus {
    let deadline = wait_deadline();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let reap_until = Instant::now() + Duration::from_secs(2);
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    panic!("{what} still running after 15s; killed with {status}");
                }
                if Instant::now() >= reap_until {
                    panic!("{what} still running after 15s; kill did not reap");
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn format_wait_status(status: i32) -> String {
    let status = status as libc::c_int;
    if libc::WIFEXITED(status) {
        format!("exit:{}", libc::WEXITSTATUS(status))
    } else if libc::WIFSIGNALED(status) {
        format!("signal:{}", libc::WTERMSIG(status))
    } else {
        format!("raw:{status}")
    }
}

fn read_broker_event(reader: &mut fs::File) -> (u8, i32) {
    let mut poll_fd = libc::pollfd {
        fd: reader.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut poll_fd, 1, 15_000) };
    assert!(result >= 0, "poll broker event failed");
    assert!(result > 0, "broker event missing within 15s");
    let mut record = [0; 5];
    read_exact_until(reader, &mut record, wait_deadline(), "broker event");
    (
        record[0],
        i32::from_le_bytes(record[1..].try_into().unwrap()),
    )
}

fn try_read_broker_event(reader: &mut fs::File) -> Option<(u8, i32)> {
    let mut poll_fd = libc::pollfd {
        fd: reader.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut poll_fd, 1, 0) };
    if result <= 0 {
        return None;
    }
    let mut record = [0; 5];
    read_exact_until(
        reader,
        &mut record,
        Instant::now() + Duration::from_millis(200),
        "broker event",
    );
    Some((
        record[0],
        i32::from_le_bytes(record[1..].try_into().unwrap()),
    ))
}

fn read_event_with_code(reader: &mut fs::File, expected_code: u8) -> i32 {
    let deadline = wait_deadline();
    loop {
        assert!(
            Instant::now() < deadline,
            "broker event {expected_code} missing within 15s"
        );
        let (code, subject) = read_broker_event(reader);
        if code == expected_code {
            return subject;
        }
    }
}

fn read_matching_event(reader: &mut fs::File, expected_code: u8, expected_pgid: i32) {
    let deadline = wait_deadline();
    loop {
        assert!(
            Instant::now() < deadline,
            "matching broker event missing within 15s"
        );
        let (code, pgid) = read_broker_event(reader);
        if code == expected_code && pgid == expected_pgid {
            return;
        }
    }
}

fn wait_matching_w_without_g(reader: &mut fs::File, agent_pgid: i32) {
    let deadline = wait_deadline();
    loop {
        assert!(
            Instant::now() < deadline,
            "matching W without G missing within 15s"
        );
        let (code, pgid) = read_broker_event(reader);
        if pgid != agent_pgid {
            continue;
        }
        assert_ne!(
            code, PTY_STARTED_WRITING,
            "Gate A saw matching G before W for pgid {agent_pgid}"
        );
        if code == AGENT_WATCHER_REMOVED {
            return;
        }
    }
}

fn drain_ready_events(reader: &mut fs::File) -> Vec<(u8, i32)> {
    let mut events = Vec::new();
    loop {
        let mut poll_fd = libc::pollfd {
            fd: reader.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut poll_fd, 1, 0) };
        assert!(result >= 0, "poll broker events failed");
        if result == 0 || poll_fd.revents & libc::POLLIN == 0 {
            return events;
        }
        events.push(read_broker_event(reader));
    }
}

fn kill_process_group(pgid: i32) {
    assert_eq!(unsafe { libc::kill(-pgid, libc::SIGKILL) }, 0);
}

fn wait_deadline() -> Instant {
    Instant::now() + Duration::from_secs(15)
}

fn read_frame_deadline<R: Read + AsRawFd>(reader: &mut R) -> Vec<u8> {
    read_payload_deadline(reader, "frame")
}

fn read_payload_deadline<R: Read + AsRawFd>(reader: &mut R, what: &str) -> Vec<u8> {
    let deadline = wait_deadline();
    let mut prefix = [0u8; PREFIX_LEN];
    read_exact_until(reader, &mut prefix, deadline, what);
    let declared = u32::from_be_bytes(prefix);
    assert!(
        declared > 0 && declared <= MAX_FRAME_LEN,
        "{what} declared {declared} bytes"
    );
    let mut payload = vec![0u8; declared as usize];
    read_exact_until(reader, &mut payload, deadline, what);
    payload
}

fn set_nonblock(fd: RawFd) {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
    assert!(flags >= 0, "F_GETFL failed");
    if flags & libc::O_NONBLOCK == 0 {
        assert_eq!(
            unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0,
            "F_SETFL O_NONBLOCK failed"
        );
    }
}

fn write_all_deadline<W: Write + AsRawFd>(writer: &mut W, buf: &[u8], what: &str) {
    set_nonblock(writer.as_raw_fd());
    let deadline = wait_deadline();
    let mut off = 0;
    while off < buf.len() {
        let remain = deadline.saturating_duration_since(Instant::now());
        assert!(!remain.is_zero(), "{what} write stalled within 15s");
        let ms = i32::try_from(remain.as_millis().min(15_000)).unwrap_or(15_000);
        let mut poll_fd = libc::pollfd {
            fd: writer.as_raw_fd(),
            events: libc::POLLOUT,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut poll_fd, 1, ms) };
        assert!(result >= 0, "poll {what} write failed");
        assert!(result > 0, "{what} write stalled within 15s");
        match writer.write(&buf[off..]) {
            Ok(0) => panic!("{what} write eof"),
            Ok(n) => off += n,
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(error) => panic!("{what} write: {error}"),
        }
    }
    loop {
        let remain = deadline.saturating_duration_since(Instant::now());
        assert!(!remain.is_zero(), "{what} flush stalled within 15s");
        match writer.flush() {
            Ok(()) => return,
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                let ms = i32::try_from(remain.as_millis().min(15_000)).unwrap_or(15_000);
                let mut poll_fd = libc::pollfd {
                    fd: writer.as_raw_fd(),
                    events: libc::POLLOUT,
                    revents: 0,
                };
                let result = unsafe { libc::poll(&mut poll_fd, 1, ms) };
                assert!(result >= 0, "poll {what} flush failed");
                assert!(result > 0, "{what} flush stalled within 15s");
            }
            Err(error) => panic!("{what} flush: {error}"),
        }
    }
}

fn read_exact_until<R: Read + AsRawFd>(
    reader: &mut R,
    buf: &mut [u8],
    deadline: Instant,
    what: &str,
) {
    set_nonblock(reader.as_raw_fd());
    let mut off = 0;
    while off < buf.len() {
        let remain = deadline.saturating_duration_since(Instant::now());
        assert!(!remain.is_zero(), "{what} incomplete read within 15s");
        let ms = i32::try_from(remain.as_millis().min(15_000)).unwrap_or(15_000);
        let mut poll_fd = libc::pollfd {
            fd: reader.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut poll_fd, 1, ms) };
        assert!(result >= 0, "poll {what} failed");
        assert!(result > 0, "{what} stalled within 15s");
        match reader.read(&mut buf[off..]) {
            Ok(0) => panic!("{what} eof mid-frame"),
            Ok(n) => off += n,
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(error) => panic!("{what} read: {error}"),
        }
    }
}

fn read_to_end_deadline<R: Read + AsRawFd>(reader: &mut R, what: &str) -> Vec<u8> {
    set_nonblock(reader.as_raw_fd());
    let deadline = wait_deadline();
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let remain = deadline.saturating_duration_since(Instant::now());
        assert!(!remain.is_zero(), "{what} still open after 15s");
        let ms = i32::try_from(remain.as_millis().min(15_000)).unwrap_or(15_000);
        let mut poll_fd = libc::pollfd {
            fd: reader.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut poll_fd, 1, ms) };
        assert!(result >= 0, "poll {what} failed");
        if result == 0 {
            panic!("{what} still open after 15s");
        }
        match reader.read(&mut tmp) {
            Ok(0) => return buf,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(error) => panic!("{what} read: {error}"),
        }
    }
}

fn wait_process_group_gone(child_pid: u32) {
    let deadline = wait_deadline();
    loop {
        let rc = unsafe { libc::kill(-(child_pid as i32), 0) };
        if rc == -1 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            panic!("kill(-pgid, 0) failed: {error}");
        }
        assert!(
            Instant::now() < deadline,
            "process group {child_pid} still present after 15s"
        );
        std::thread::yield_now();
    }
}

fn wait_process_gone(pid: i32) {
    let deadline = wait_deadline();
    loop {
        let rc = unsafe { libc::kill(pid, 0) };
        if rc == -1 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            panic!("kill(pid, 0) failed: {error}");
        }
        assert!(
            Instant::now() < deadline,
            "process {pid} still present after 15s"
        );
        std::thread::yield_now();
    }
}

fn wait_socket_gone(socket: &Path) {
    let deadline = wait_deadline();
    loop {
        match fs::symlink_metadata(socket) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("lstat broker.sock failed: {error}"),
            Ok(_) => {
                assert!(
                    Instant::now() < deadline,
                    "broker socket still present after 15s: {}",
                    socket.display()
                );
                std::thread::yield_now();
            }
        }
    }
}
