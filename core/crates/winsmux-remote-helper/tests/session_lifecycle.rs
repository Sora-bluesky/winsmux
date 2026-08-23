#![cfg(target_os = "linux")]

//! Linux end-to-end coverage lives here so the frozen Windows-only CI remains unchanged.
//! The tests exercise the real broker binary, lock file, Unix socket, PTY, and process group.

use std::ffi::OsString;
use std::fs;
use std::io::Read;
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};
use winsmux_remote_helper::{
    decode_payload, encode_frame, encode_payload, read_frame, AgentResolution, Message, RejectCode,
    MAX_EXECUTABLE_BYTES, MAX_FRAME_LEN, PROTOCOL_VERSION,
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

struct FrontendOptions {
    capabilities: Vec<String>,
    peer_frame_limit: u32,
    path: Option<OsString>,
    current_dir: Option<PathBuf>,
    home: Option<PathBuf>,
}

impl FrontendOptions {
    fn legacy() -> Self {
        Self {
            capabilities: vec!["frame-v1".to_string(), "pty-v1".to_string()],
            peer_frame_limit: MAX_FRAME_LEN,
            path: None,
            current_dir: None,
            home: None,
        }
    }

    fn agent() -> Self {
        let mut options = Self::legacy();
        options.capabilities.push("agent-path-v1".to_string());
        options
    }
}

impl Frontend {
    fn connect(runtime: &Path) -> Self {
        Self::connect_with_event(runtime, None)
    }

    fn connect_with_event(runtime: &Path, event_fd: Option<RawFd>) -> Self {
        Self::connect_with_options(runtime, event_fd, FrontendOptions::legacy())
    }

    fn connect_with_options(
        runtime: &Path,
        event_fd: Option<RawFd>,
        options: FrontendOptions,
    ) -> Self {
        let FrontendOptions {
            capabilities,
            peer_frame_limit,
            path,
            current_dir,
            home,
        } = options;
        let mut command = Command::new(env!("CARGO_BIN_EXE_winsmux-remote-helper"));
        command
            .args(["serve", "--stdio"])
            .env("XDG_RUNTIME_DIR", runtime)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
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
            capabilities,
            peer_frame_limit,
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

    fn close_and_read_stderr(mut self) -> Vec<u8> {
        drop(self.input);
        let status = self.child.wait().unwrap();
        assert!(status.success());
        let mut stderr = Vec::new();
        self.child
            .stderr
            .take()
            .expect("stderr pipe")
            .read_to_end(&mut stderr)
            .unwrap();
        stderr
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
        resolution: None,
        argv: Vec::new(),
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
fn natural_exit_removes_registry_and_process_group() {
    let runtime = RuntimeDir::new("natural-exit");
    let mut frontend = Frontend::connect(&runtime.0);
    frontend.send(&Message::PtyStart {
        executable: "/bin/true".to_string(),
        resolution: None,
        argv: Vec::new(),
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
        resolution: None,
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
            ..
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
