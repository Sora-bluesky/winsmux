#![cfg(all(windows, debug_assertions))]

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use winsmux_workspace::contract::{
    canonical_request, parse_request, parse_response, Request, Response,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn next_operation_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!(
        "20000000-0000-4000-8000-{:012x}",
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

fn request(
    operation: &str,
    instance: Option<&str>,
    revision: Option<u64>,
    params: Value,
) -> Request {
    request_id(operation, instance, &next_operation_id(), revision, params)
}

fn request_id(
    operation: &str,
    instance: Option<&str>,
    operation_id: &str,
    revision: Option<u64>,
    params: Value,
) -> Request {
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": instance,
            "operation_id": operation_id,
            "expected_topology_revision": revision,
            "operation": operation,
            "params": params,
        }))
        .expect("json"),
    )
    .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

fn wait_until(deadline: Instant, mut probe: impl FnMut() -> bool, context: &str) {
    while Instant::now() < deadline {
        if probe() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("{context}");
}

fn compile_helper(name: &str, source: &str) -> PathBuf {
    let dir = PathBuf::from(std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| "target".into()))
        .join("task864-helpers");
    fs::create_dir_all(&dir).expect("helper dir");
    let src = dir.join(format!(
        "{name}-{}.rs",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    fs::write(&src, source.as_bytes()).expect("write helper");
    let out = dir.join(format!(
        "{name}-{}.exe",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    let status = Command::new("rustc")
        .args(["--edition", "2021", "-O", "-o"])
        .arg(&out)
        .arg(&src)
        .status()
        .expect("rustc");
    assert!(status.success(), "compile {name} from embedded source");
    out
}

const WAIT_FILE_SRC: &str = r#"
fn main() {
    let path = std::env::args().nth(1).expect("release");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while std::time::Instant::now() < deadline {
        if std::path::Path::new(&path).exists() { return; }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::process::exit(2);
}
"#;

struct ReleaseOnDrop(PathBuf);
impl Drop for ReleaseOnDrop {
    fn drop(&mut self) {
        let _ = fs::write(&self.0, b"go");
    }
}

#[path = "support/conpty_json.rs"]
mod conpty_json;
use conpty_json::JsonOutput as OutputStream;

struct CliHost {
    writer: Option<Box<dyn Write + Send>>,
    output: OutputStream,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    master: Option<Box<dyn portable_pty::MasterPty + Send>>,
    exited: bool,
}

impl CliHost {
    fn start(home: &Path) -> Self {
        fs::create_dir_all(home.join("AppData").join("Local"))
            .expect("prepare isolated Windows LocalAppData");
        // One Local\winsmux-workspace-v1-* mutex exists per logon; a second
        // `workspace host` exits at startup if that mutex is already held.
        let binary = PathBuf::from(env!("CARGO_BIN_EXE_winsmux"));
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 4096,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("open host ConPTY");
        let mut command = CommandBuilder::new(&binary);
        command.args(["workspace", "host"]);
        command.env("USERPROFILE", home);
        command.env("HOME", home);
        let child = pair
            .slave
            .spawn_command(command)
            .expect("spawn winsmux workspace host");
        drop(pair.slave);
        let reader = pair.master.try_clone_reader().expect("host reader");
        let mut writer = pair.master.take_writer().expect("host writer");
        writer
            .write_all(b"\x1b[1;1R")
            .and_then(|_| writer.flush())
            .expect("answer ConPTY cursor query");
        Self {
            writer: Some(writer),
            output: OutputStream::start(reader),
            child,
            master: Some(pair.master),
            exited: false,
        }
    }

    fn receive_json(&mut self) -> Value {
        let process = self
            .child
            .as_raw_handle()
            .expect("owned ConPTY client handle")
            as windows_sys::Win32::Foundation::HANDLE;
        match self.output.next_json_with_process(process) {
            Ok(value) => value,
            Err(exit) => {
                drop(self.writer.take());
                drop(self.master.take());
                self.output.join_nonpanic();
                if let Some(value) = self.output.finish_json_after_reader_join() {
                    return value;
                }
                let captured = self.output.captured();
                panic!(
                    "interactive client ended before JSON response: {exit:?}; output={}",
                    String::from_utf8_lossy(&captured)
                );
            }
        }
    }

    fn discovery(&mut self) -> Value {
        let value = self.receive_json();
        assert!(
            value.get("accepted").is_none(),
            "discovery was a response: {value}"
        );
        value
    }

    fn transact(&mut self, request: &Request) -> Value {
        let bytes = canonical_request(request).expect("canonical");
        let writer = self.writer.as_mut().expect("host writer");
        writer.write_all(&bytes).expect("write request");
        writer.write_all(b"\r\n").expect("terminate");
        writer.flush().expect("flush");
        let value = self.receive_json();
        assert!(value.get("accepted").is_some(), "not a response: {value}");
        let _ = parse_response(request, &serde_json::to_vec(&value).expect("bytes"));
        value
    }

    fn wait_for_natural_exit(&mut self) {
        let status = self.child.wait().expect("wait host after host.stop");
        assert_eq!(status.exit_code(), 0, "host.stop process exit: {status:?}");
        self.exited = true;
        drop(self.writer.take());
        drop(self.master.take());
        self.output.join();
    }
}

impl Drop for CliHost {
    fn drop(&mut self) {
        if !self.exited {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        drop(self.writer.take());
        drop(self.master.take());
        self.output.join_nonpanic();
    }
}

#[test]
fn real_cli_pane_runtime_journey() {
    let unique = format!(
        "winsmux-864-プロジェクト space-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    );
    let folder = std::env::temp_dir().join(&unique);
    fs::create_dir_all(&folder).expect("project folder");
    let path = folder.to_string_lossy().into_owned();
    let release = folder.join("unowned-release");
    let release_guard = ReleaseOnDrop(release.clone());
    let waiter = compile_helper("task864_wait_file", WAIT_FILE_SRC);
    let mut unowned = Command::new(&waiter)
        .arg(&release)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .expect("unowned sibling");

    let home = tempfile::tempdir().expect("isolated home");
    let mut host = CliHost::start(home.path());
    let discovery = host.discovery();
    let inst = discovery["instance_id"]
        .as_str()
        .expect("instance")
        .to_owned();

    let opened = host.transact(&request(
        "project.open",
        Some(&inst),
        Some(0),
        json!({"path": path}),
    ));
    assert_eq!(opened["accepted"], json!(true), "{opened}");
    let project_id = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("project")
        .to_owned();
    let revision = opened["topology_revision"].as_u64().expect("rev");

    let create_id = "20000000-0000-4000-8000-00000000ae01";
    let created = host.transact(&request_id(
        "pane.create",
        Some(&inst),
        create_id,
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    ));
    assert_eq!(created["accepted"], json!(true), "{created}");
    let pane_id = created["result"]["data"]["pane_id"]
        .as_str()
        .expect("pane")
        .to_owned();
    let run_id = created["result"]["data"]["run_id"]
        .as_str()
        .expect("run")
        .to_owned();
    let create_rev = created["topology_revision"].as_u64().expect("create rev");
    let create_seq = created["event_seq"].as_u64().expect("create seq");
    let replay = host.transact(&request_id(
        "pane.create",
        Some(&inst),
        create_id,
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    ));
    assert_eq!(replay["topology_revision"], json!(create_rev));
    assert_eq!(replay["event_seq"], json!(create_seq));
    assert_eq!(replay["result"]["data"]["run_id"], json!(run_id));

    let selected = host.transact(&request(
        "pane.select",
        Some(&inst),
        Some(create_rev),
        json!({"pane_id": pane_id}),
    ));
    assert_eq!(selected["accepted"], json!(true), "{selected}");
    let after_select = selected["topology_revision"].as_u64().expect("select rev");
    let split = host.transact(&request(
        "pane.split",
        Some(&inst),
        Some(after_select),
        json!({"axis": "vertical", "pane_id": pane_id}),
    ));
    assert_eq!(split["accepted"], json!(true), "{split}");
    let sibling_pane = split["result"]["data"]["pane_id"]
        .as_str()
        .expect("sibling pane")
        .to_owned();
    let sibling_run = split["result"]["data"]["run_id"]
        .as_str()
        .expect("sibling run")
        .to_owned();
    let after_split = split["topology_revision"].as_u64().expect("split rev");
    let resized = host.transact(&request(
        "pane.resize",
        Some(&inst),
        None,
        json!({"cols": 120, "pane_id": pane_id, "rows": 32, "run_id": run_id}),
    ));
    assert_eq!(resized["accepted"], json!(true), "{resized}");

    let mut seen = String::new();
    wait_until(
        Instant::now() + Duration::from_secs(20),
        || {
            let read = host.transact(&request(
                "output.read",
                Some(&inst),
                None,
                json!({"cursor": null, "max_bytes": 8192, "run_id": run_id}),
            ));
            assert_eq!(read["accepted"], json!(true), "{read}");
            seen = read["result"]["data"]["text"]
                .as_str()
                .unwrap_or("")
                .to_owned();
            seen.contains(&unique)
        },
        "unique Japanese+space cwd missing from real CLI output.read",
    );
    assert!(seen.contains(&unique), "cwd {unique} missing: {seen}");

    let stale = host.transact(&request(
        "run.interrupt",
        Some(&inst),
        None,
        json!({"run_id": "50000000-0000-4000-8000-000000000000"}),
    ));
    assert_eq!(stale["error"]["code"], json!("target_not_found"), "{stale}");
    let live = host.transact(&request(
        "run.get",
        Some(&inst),
        None,
        json!({"run_id": run_id}),
    ));
    assert_eq!(
        live["result"]["data"]["run"]["process"],
        json!("running"),
        "{live}"
    );

    let interrupt_id = "20000000-0000-4000-8000-00000000ae02";
    let interrupted = host.transact(&request_id(
        "run.interrupt",
        Some(&inst),
        interrupt_id,
        None,
        json!({"run_id": run_id}),
    ));
    assert_eq!(interrupted["accepted"], json!(true), "{interrupted}");
    assert_eq!(
        interrupted["result"]["data"]["phase"],
        json!("accepted"),
        "{interrupted}"
    );
    let replay_interrupt = host.transact(&request_id(
        "run.interrupt",
        Some(&inst),
        interrupt_id,
        None,
        json!({"run_id": run_id}),
    ));
    assert_eq!(replay_interrupt, interrupted);

    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let got = host.transact(&request(
                "run.get",
                Some(&inst),
                None,
                json!({"run_id": run_id}),
            ));
            got["result"]["data"]["run"]["process"] == json!("exited")
        },
        "addressed run did not exit after interrupt",
    );
    let sibling_live = host.transact(&request(
        "run.get",
        Some(&inst),
        None,
        json!({"run_id": sibling_run}),
    ));
    assert_eq!(
        sibling_live["result"]["data"]["run"]["process"],
        json!("running"),
        "{sibling_live}"
    );

    let mut close_rev = after_split;
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let closed = host.transact(&request(
                "pane.close",
                Some(&inst),
                Some(close_rev),
                json!({"pane_id": pane_id}),
            ));
            if closed["accepted"] == json!(true) {
                close_rev = closed["topology_revision"].as_u64().unwrap_or(close_rev);
                true
            } else if closed["error"]["code"] == json!("stale_topology") {
                close_rev = closed["topology_revision"].as_u64().unwrap_or(close_rev);
                false
            } else {
                false
            }
        },
        "first pane did not close",
    );

    let sib_interrupt = host.transact(&request(
        "run.interrupt",
        Some(&inst),
        None,
        json!({"run_id": sibling_run}),
    ));
    assert_eq!(sib_interrupt["accepted"], json!(true), "{sib_interrupt}");
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let got = host.transact(&request(
                "run.get",
                Some(&inst),
                None,
                json!({"run_id": sibling_run}),
            ));
            got["result"]["data"]["run"]["process"] == json!("exited")
        },
        "sibling run did not exit",
    );
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let closed = host.transact(&request(
                "pane.close",
                Some(&inst),
                Some(close_rev),
                json!({"pane_id": sibling_pane}),
            ));
            if closed["accepted"] == json!(true) {
                close_rev = closed["topology_revision"].as_u64().unwrap_or(close_rev);
                true
            } else if closed["error"]["code"] == json!("stale_topology") {
                close_rev = closed["topology_revision"].as_u64().unwrap_or(close_rev);
                false
            } else {
                false
            }
        },
        "last pane did not close",
    );

    let mut forgotten = None;
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let response = host.transact(&request(
                "project.forget",
                Some(&inst),
                Some(close_rev),
                json!({"project_id": project_id}),
            ));
            if response["accepted"] == json!(true) {
                forgotten = Some(response);
                true
            } else if response["error"]["code"] == json!("operation_conflict") {
                false
            } else {
                panic!("unexpected project.forget result: {response}");
            }
        },
        "project did not become forgettable after its runs exited",
    );
    let forgotten = forgotten.expect("accepted project.forget");
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");
    assert!(folder.exists(), "forget must not delete disk");
    assert!(
        unowned.try_wait().expect("unowned poll").is_none(),
        "unowned sibling must survive"
    );
    fs::write(&release, b"go").expect("release unowned");
    drop(release_guard);
    let status = unowned.wait().expect("unowned wait");
    assert!(status.success(), "{status:?}");
    let mut stopped = None;
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let response = host.transact(&request("host.stop", Some(&inst), None, json!({})));
            if response["accepted"] == json!(true) {
                stopped = Some(response);
                true
            } else if response["error"]["code"] == json!("operation_conflict") {
                false
            } else {
                panic!("unexpected host.stop result: {response}");
            }
        },
        "provider probes did not become safe to stop",
    );
    let stopped = stopped.expect("accepted host.stop");
    assert_eq!(stopped["accepted"], json!(true), "{stopped}");
    assert_eq!(
        stopped["result"]["data"]["stopped"],
        json!(true),
        "{stopped}"
    );
    host.wait_for_natural_exit();
    let _ = fs::remove_dir_all(&folder);
}
