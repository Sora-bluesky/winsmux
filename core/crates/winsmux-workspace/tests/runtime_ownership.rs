//! Additive TASK-864 ownership proofs: HANDLE, job, Ctrl+C, isolation, UTF-8.

#![cfg(windows)]

#[path = "support/run_completion.rs"]
mod run_completion;


use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};
use winsmux_workspace::auth::testing::Harness;

use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
use winsmux_workspace::contract::{parse_request, OperationId, PaneId, ProjectId, Request, RunId};
use winsmux_workspace::memory_testing::{
    handle_signaled, issue_pending_overlapped_write, prove_overlapped_cancel_is_not_delivery,
    prove_readfile_after_pty_and_job_close, retained_write_count, retained_write_identities,
    resume_once, spawn_suspended_shell, suspend_once, IoObservation, ReadClass, RuntimeService,
    STILL_ACTIVE,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn request_id(
    operation: &str,
    instance_id: Option<&str>,
    operation_id: &str,
    revision: Option<u64>,
    params: Value,
) -> Request {
    let value = json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": operation_id,
        "expected_topology_revision": revision,
        "operation": operation,
        "params": params,
    });
    parse_request(&serde_json::to_vec(&value).expect("request JSON"))
        .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

fn request(
    operation: &str,
    instance_id: Option<&str>,
    revision: Option<u64>,
    params: Value,
) -> Request {
    request_id(
        operation,
        instance_id,
        &uuid::Uuid::new_v4().to_string(),
        revision,
        params,
    )
}

fn value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).expect("response JSON")
}

fn instance(harness: &Harness) -> String {
    value(&harness.instance_id())
        .as_str()
        .expect("instance")
        .to_owned()
}

fn owner(harness: &Harness, operation: &str, revision: Option<u64>, params: Value) -> Value {
    value(&harness.owner(&request(
        operation,
        Some(&instance(harness)),
        revision,
        params,
    )))
}

fn owner_id(
    harness: &Harness,
    operation: &str,
    operation_id: &str,
    revision: Option<u64>,
    params: Value,
) -> Value {
    value(&harness.owner(&request_id(
        operation,
        Some(&instance(harness)),
        operation_id,
        revision,
        params,
    )))
}

fn phase(harness: &Harness, operation_id: &str) -> Option<&'static str> {
    harness
        .authorization()
        .testing_replay_phase(&OperationId::new(operation_id.to_owned()).expect("operation id"))
}

fn helper_dir() -> PathBuf {
    let out_dir =
        PathBuf::from(std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| "target".to_owned()))
            .join("task864-helpers");
    fs::create_dir_all(&out_dir).expect("helper dir");
    out_dir
}

fn compile_helper(name: &str, source: &str) -> PathBuf {
    let dir = helper_dir();
    let src = dir.join(format!("{name}-{}.rs", uuid::Uuid::new_v4()));
    fs::write(&src, source.as_bytes()).expect("write helper source");
    let out = dir.join(format!("{name}-{}.exe", uuid::Uuid::new_v4()));
    let status = Command::new("rustc")
        .args(["--edition", "2021", "-O", "-C", "debuginfo=0", "-o"])
        .arg(&out)
        .arg(&src)
        .status()
        .expect("rustc");
    assert!(status.success(), "rustc {name} from embedded source");
    out
}

const EXIT259_SRC: &str = r#"fn main() { std::process::exit(259); }"#;

const WAIT_FILE_SRC: &str = r#"
fn main() {
    let path = std::env::args().nth(1).or_else(|| std::env::var("WINSMUX_TASK864_RELEASE").ok()).expect("release");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while std::time::Instant::now() < deadline {
        if std::path::Path::new(&path).exists() { return; }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::process::exit(2);
}
"#;

const CTRL_C_SRC: &str = r#"
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};
static GOT: AtomicBool = AtomicBool::new(false);
const STD_INPUT_HANDLE: u32 = (-10i32) as u32;
const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
#[link(name = "kernel32")]
extern "system" {
    fn SetConsoleCtrlHandler(handler: Option<unsafe extern "system" fn(u32) -> i32>, add: i32) -> i32;
    fn GetStdHandle(kind: u32) -> *mut std::ffi::c_void;
    fn GetConsoleMode(handle: *mut std::ffi::c_void, mode: *mut u32) -> i32;
    fn SetConsoleMode(handle: *mut std::ffi::c_void, mode: u32) -> i32;
}
unsafe extern "system" fn handler(control: u32) -> i32 {
    if control == 0 { GOT.store(true, Ordering::SeqCst); 1 } else { 0 }
}
fn main() {
    let report = std::env::var("WINSMUX_TASK864_REPORT").expect("report");
    let ready = format!("{report}.ready");
    unsafe {
        SetConsoleCtrlHandler(None, 0);
        SetConsoleCtrlHandler(Some(handler), 1);
        let stdin = GetStdHandle(STD_INPUT_HANDLE);
        let mut mode = 0u32;
        if GetConsoleMode(stdin, &mut mode) != 0 {
            let _ = SetConsoleMode(stdin, mode | ENABLE_PROCESSED_INPUT);
        }
    }
    let _ = std::fs::write(&ready, b"ready\n");
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if GOT.load(Ordering::SeqCst) {
            let _ = std::fs::write(&report, b"ctrl_c\n");
            thread::sleep(Duration::from_secs(2));
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::write(&report, b"timeout\n");
    std::process::exit(3);
}
"#;

const HANDLE_PROBE_SRC: &str = r#"
use std::env;
#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentProcess() -> *mut std::ffi::c_void;
    fn DuplicateHandle(a: *mut std::ffi::c_void, b: *mut std::ffi::c_void, c: *mut std::ffi::c_void, d: *mut *mut std::ffi::c_void, access: u32, inherit: i32, options: u32) -> i32;
    fn CloseHandle(h: *mut std::ffi::c_void) -> i32;
}
fn parse_handle(name: &str) -> *mut std::ffi::c_void {
    let text = env::var(name).unwrap_or_default();
    let value = usize::from_str_radix(text.trim_start_matches("0x"), 16).unwrap_or(0);
    value as *mut std::ffi::c_void
}
fn inherited(handle: *mut std::ffi::c_void) -> bool {
    if handle.is_null() { return false; }
    let mut duplicated = std::ptr::null_mut();
    let ok = unsafe { DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), &mut duplicated, 0, 0, 2) };
    if ok != 0 && !duplicated.is_null() { unsafe { CloseHandle(duplicated); } true } else { false }
}
fn main() {
    let report = env::var("WINSMUX_TASK864_REPORT").expect("report");
    let body = format!("owner={}\npublic={}\n", inherited(parse_handle("WINSMUX_TASK864_OWNER_HANDLE")) as u8, inherited(parse_handle("WINSMUX_TASK864_PUBLIC_HANDLE")) as u8);
    let _ = std::fs::write(report, body);
}
"#;

const DESCENDANT_SRC: &str = r#"
use std::os::windows::process::CommandExt;
use std::process::Command;
const CREATE_NO_WINDOW: u32 = 0x08000000;
fn main() {
    if std::env::var("WINSMUX_TASK864_CHILD").ok().as_deref() == Some("1") {
        let path = std::env::var("WINSMUX_TASK864_RELEASE").expect("release");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        while std::time::Instant::now() < deadline {
            if std::path::Path::new(&path).exists() { return; }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        std::process::exit(2);
    }
    let exe = std::env::current_exe().expect("exe");
    let release = std::env::var("WINSMUX_TASK864_RELEASE").expect("release");
    let _child = Command::new(exe)
        .env("WINSMUX_TASK864_CHILD", "1")
        .env("WINSMUX_TASK864_RELEASE", release)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .expect("spawn descendant");
}
"#;

const CWD_SRC: &str = r#"
fn main() {
    let report = std::env::var("WINSMUX_TASK864_REPORT").expect("report");
    let cwd = std::env::current_dir().expect("cwd");
    let _ = std::fs::write(report, cwd.to_string_lossy().as_bytes());
    let release = std::env::var("WINSMUX_TASK864_RELEASE").unwrap_or_default();
    if !release.is_empty() {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while std::time::Instant::now() < deadline {
            if std::path::Path::new(&release).exists() { return; }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
}
"#;

fn wait_until(deadline: Instant, mut probe: impl FnMut() -> bool, context: &str) {
    while Instant::now() < deadline {
        if probe() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("{context}");
}

fn open_project(harness: &Harness) -> (PathBuf, String, u64) {
    let folder = std::env::temp_dir().join(format!(
        "winsmux-864-プロジェクト space-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir_all(&folder).expect("temp project");
    let opened = owner(
        harness,
        "project.open",
        Some(0),
        json!({"path": folder.to_string_lossy()}),
    );
    assert_eq!(opened["accepted"], json!(true), "{opened}");
    let project_id = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("project")
        .to_owned();
    let revision = opened["topology_revision"].as_u64().expect("revision");
    (folder, project_id, revision)
}

fn wait_session_clean(harness: &Harness, pane_id: &str, run_id: &str, revision: u64) -> u64 {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut live = revision;
    let mut last = json!(null);
    while Instant::now() < deadline {
        let closed = owner(
            harness,
            "pane.close",
            Some(live),
            json!({"pane_id": pane_id}),
        );
        last = closed.clone();
        if closed["accepted"] == json!(true) {
            return closed["topology_revision"].as_u64().unwrap_or(live);
        } else if closed["error"]["code"] == json!("stale_topology") {
            live = closed["topology_revision"].as_u64().unwrap_or(live);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let bits = harness
        .authorization()
        .testing_session_clean_bits(&RunId::new(run_id.to_owned()).expect("run"));
    panic!("pane did not become closeable: {last} bits={bits:?}");
}

#[test]
fn pane_list_and_stale_create_are_sealed() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, _) = open_project(&harness);
    let list_id = "20000000-0000-4000-8000-00000000aa01";
    let listed = owner_id(
        &harness,
        "pane.list",
        list_id,
        None,
        json!({"project_id": project_id}),
    );
    assert_eq!(listed["accepted"], json!(true), "{listed}");
    assert_eq!(phase(&harness, list_id), None, "Q must not retain");
    let stale_id = "20000000-0000-4000-8000-00000000aa02";
    let stale = owner_id(
        &harness,
        "pane.create",
        stale_id,
        Some(0),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(stale["accepted"], json!(false), "{stale}");
    assert_eq!(stale["error"]["code"], json!("stale_topology"), "{stale}");
    assert_eq!(phase(&harness, stale_id), Some("done"));
    let replay = owner_id(
        &harness,
        "pane.create",
        stale_id,
        Some(0),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(replay, stale);
    let _ = fs::remove_dir_all(&folder);
}

#[test]
fn usual_shell_create_replay_read_interrupt_close_forget() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let create_id = "20000000-0000-4000-8000-00000000ab01";
    let created = owner_id(
        &harness,
        "pane.create",
        create_id,
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    let pane_id = created["result"]["data"]["pane_id"]
        .as_str()
        .expect("pane")
        .to_owned();
    let run_id = created["result"]["data"]["run_id"]
        .as_str()
        .expect("run")
        .to_owned();
    let create_revision = created["topology_revision"]
        .as_u64()
        .expect("create revision");
    let create_seq = created["event_seq"].as_u64().expect("create seq");
    assert_eq!(phase(&harness, create_id), Some("done"));
    let replay = owner_id(
        &harness,
        "pane.create",
        create_id,
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(replay["topology_revision"], json!(create_revision));
    assert_eq!(replay["event_seq"], json!(create_seq));
    assert_eq!(replay["result"]["data"]["pane_id"], json!(pane_id));
    assert_eq!(replay["result"]["data"]["run_id"], json!(run_id));
    let flags = harness
        .authorization()
        .testing_isolation_flags(&RunId::new(run_id.clone()).expect("run"))
        .expect("isolation");
    assert_eq!(flags, (false, false, false));

    let listed = owner(
        &harness,
        "pane.list",
        None,
        json!({"project_id": project_id}),
    );
    assert_eq!(listed["accepted"], json!(true), "{listed}");
    assert_eq!(
        listed["result"]["data"]["panes"][0]["pane_id"],
        json!(pane_id)
    );

    let get_id = "20000000-0000-4000-8000-00000000ab02";
    let got = owner_id(&harness, "run.get", get_id, None, json!({"run_id": run_id}));
    assert_eq!(got["accepted"], json!(true), "{got}");
    assert_eq!(got["result"]["data"]["run"]["process"], json!("running"));
    assert_eq!(phase(&harness, get_id), None, "run.get must not retain");

    let deadline = Instant::now() + Duration::from_secs(20);
    let mut output_text = String::new();
    while Instant::now() < deadline {
        let read_id = uuid::Uuid::new_v4().to_string();
        let read = owner_id(
            &harness,
            "output.read",
            &read_id,
            None,
            json!({"cursor": null, "max_bytes": 4096, "run_id": run_id}),
        );
        assert_eq!(read["accepted"], json!(true), "{read}");
        assert_eq!(
            phase(&harness, &read_id),
            None,
            "output.read must not retain"
        );
        output_text = read["result"]["data"]["text"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        if output_text.contains("プロジェクト") && output_text.contains(" space-") {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let io = harness
        .authorization()
        .testing_session_io(&RunId::new(run_id.clone()).expect("run"))
        .expect("io");
    let unique_name = folder
        .file_name()
        .and_then(|name| name.to_str())
        .expect("unique folder name");
    assert!(
        output_text.contains(unique_name),
        "child cwd must equal unique Japanese+space directory {unique_name}, got {output_text} drain={} reader_returned={} reader_error={} decoded={}",
        io.0,
        io.1,
        io.2,
        io.3
    );

    let selected = owner(
        &harness,
        "pane.select",
        Some(create_revision),
        json!({"pane_id": pane_id}),
    );
    assert_eq!(selected["accepted"], json!(true), "{selected}");
    let after_select = selected["topology_revision"].as_u64().expect("select rev");
    let split = owner(
        &harness,
        "pane.split",
        Some(after_select),
        json!({"axis": "vertical", "pane_id": pane_id}),
    );
    assert_eq!(split["accepted"], json!(true), "{split}");
    let sibling = split["result"]["data"]["pane_id"]
        .as_str()
        .expect("split pane")
        .to_owned();
    let sibling_run = split["result"]["data"]["run_id"]
        .as_str()
        .expect("split run")
        .to_owned();
    let after_split = split["topology_revision"].as_u64().expect("split rev");
    let resized = owner(
        &harness,
        "pane.resize",
        None,
        json!({"cols": 100, "pane_id": pane_id, "rows": 30, "run_id": run_id}),
    );
    assert_eq!(resized["accepted"], json!(true), "{resized}");

    let stale = owner(
        &harness,
        "run.interrupt",
        None,
        json!({"run_id": "50000000-0000-4000-8000-000000000000"}),
    );
    assert_eq!(stale["error"]["code"], json!("target_not_found"), "{stale}");
    let still = owner(&harness, "run.get", None, json!({"run_id": run_id}));
    assert_eq!(
        still["result"]["data"]["run"]["process"],
        json!("running"),
        "{still}"
    );

    let interrupt_id = "20000000-0000-4000-8000-00000000ab03";
    let interrupted = owner_id(
        &harness,
        "run.interrupt",
        interrupt_id,
        None,
        json!({"run_id": run_id}),
    );
    assert_eq!(interrupted["accepted"], json!(true), "{interrupted}");
    assert_eq!(
        interrupted["result"]["data"]["phase"],
        json!("accepted"),
        "{interrupted}"
    );
    let interrupt_replay = owner_id(
        &harness,
        "run.interrupt",
        interrupt_id,
        None,
        json!({"run_id": run_id}),
    );
    assert_eq!(interrupt_replay, interrupted);

    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let got = owner(&harness, "run.get", None, json!({"run_id": run_id}));
            got["result"]["data"]["run"]["process"] == json!("exited")
        },
        "addressed run did not exit",
    );
    let (writes, delivered, cancelled, _) = harness
        .authorization()
        .testing_ctrl_c_stats(&RunId::new(run_id.clone()).expect("run"))
        .expect("ctrl stats");
    assert_eq!(writes, 1, "single completed 0x03");
    assert!(delivered);
    assert!(!cancelled);
    let interrupt_replay_again = owner_id(
        &harness,
        "run.interrupt",
        interrupt_id,
        None,
        json!({"run_id": run_id}),
    );
    assert_eq!(interrupt_replay_again, interrupted);
    let (writes2, _, _, _) = harness
        .authorization()
        .testing_ctrl_c_stats(&RunId::new(run_id.clone()).expect("run"))
        .expect("ctrl stats replay");
    assert_eq!(writes2, 1, "replay must not write a second 0x03");
    let sibling_live = owner(&harness, "run.get", None, json!({"run_id": sibling_run}));
    assert_eq!(
        sibling_live["result"]["data"]["run"]["process"],
        json!("running"),
        "{sibling_live}"
    );

    let after_first = wait_session_clean(&harness, &pane_id, &run_id, after_split);
    let interrupt_sib = owner(
        &harness,
        "run.interrupt",
        None,
        json!({"run_id": sibling_run}),
    );
    assert_eq!(interrupt_sib["accepted"], json!(true), "{interrupt_sib}");
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let got = owner(&harness, "run.get", None, json!({"run_id": sibling_run}));
            got["result"]["data"]["run"]["process"] == json!("exited")
        },
        "sibling run did not exit",
    );
    let after_second = wait_session_clean(&harness, &sibling, &sibling_run, after_first);
    let forgotten = owner(
        &harness,
        "project.forget",
        Some(after_second),
        json!({"project_id": project_id}),
    );
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");
    assert!(folder.exists(), "forget must not delete disk");
    let _ = fs::remove_dir_all(&folder);
}

#[test]
fn public_grant_and_missing_targets() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let client = harness.connect("client.exe");
    let pending = client
        .request(&request(
            "connection.request",
            None,
            None,
            json!({"project_ids": [project_id], "scopes": ["metadata", "control"]}),
        ))
        .expect("pending");
    let pending = value(&pending);
    let connection_id = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("cid")
        .to_owned();
    let allowed = owner(
        &harness,
        "connection.decide",
        None,
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": [project_id],
            "scopes": ["metadata", "control"]
        }),
    );
    assert_eq!(allowed["accepted"], json!(true), "{allowed}");
    let inst = instance(&harness);
    let listed = client
        .request(&request(
            "pane.list",
            Some(&inst),
            None,
            json!({"project_id": project_id}),
        ))
        .expect("public list");
    assert_eq!(value(&listed)["accepted"], json!(true));
    let denied_output = client
        .request(&request(
            "output.read",
            Some(&inst),
            None,
            json!({"cursor": "c", "max_bytes": 1, "run_id": "50000000-0000-4000-8000-000000000000"}),
        ))
        .expect("denied output");
    assert_eq!(
        value(&denied_output)["error"]["code"],
        json!("permission_denied")
    );
    let created = owner(
        &harness,
        "pane.create",
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    let _ = fs::remove_dir_all(&folder);
}

#[test]
fn spawn_path_exit259_ctrl_c_and_handle_isolation() {
    let cwd = std::env::temp_dir().join(format!("winsmux-864-spawn-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("cwd");
    let exit259 = compile_helper("task864_exit259", EXIT259_SRC);
    let mut child =
        spawn_suspended_shell(cwd.to_str().expect("cwd"), exit259.to_str().expect("exe"))
            .expect("spawn 259");
    let previous = resume_once(child.thread.0);
    assert_eq!(previous, 1, "owned suspension previous count");
    child.disarm();
    let code = child.wait_exit().expect("exit");
    assert_eq!(code, STILL_ACTIVE, "259 is a real exit");
    assert_eq!(handle_signaled(child.process.0), Some(true));
    drop(child);

    let report = cwd.join("ctrl.txt");
    std::env::set_var("WINSMUX_TASK864_REPORT", report.to_string_lossy().as_ref());
    let ctrl = compile_helper("task864_ctrl_c", CTRL_C_SRC);
    let mut child = spawn_suspended_shell(cwd.to_str().expect("cwd"), ctrl.to_str().expect("exe"))
        .expect("spawn ctrl");
    let previous = resume_once(child.thread.0);
    assert_eq!(previous, 1);
    child.disarm();
    let ready = PathBuf::from(format!("{}.ready", report.display()));
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || ready.exists(),
        "ctrl-c helper did not become ready",
    );
    let mut wrote = false;
    wait_until(
        Instant::now() + Duration::from_secs(20),
        || {
            if child.write_ctrl_c() {
                wrote = true;
            }
            fs::read_to_string(&report)
                .map(|text| text.contains("ctrl_c"))
                .unwrap_or(false)
        },
        "CTRL_C_EVENT was not observed",
    );
    assert!(wrote, "completed 0x03 write");
    drop(child);

    let owner_file = fs::File::create(cwd.join("owner.bin")).expect("owner file");
    let public_file = fs::File::create(cwd.join("public.bin")).expect("public file");
    std::env::set_var(
        "WINSMUX_TASK864_OWNER_HANDLE",
        format!("{:x}", owner_file.as_raw_handle() as usize),
    );
    std::env::set_var(
        "WINSMUX_TASK864_PUBLIC_HANDLE",
        format!("{:x}", public_file.as_raw_handle() as usize),
    );
    let probe_report = cwd.join("handles.txt");
    std::env::set_var(
        "WINSMUX_TASK864_REPORT",
        probe_report.to_string_lossy().as_ref(),
    );
    let probe = compile_helper("task864_handle_probe", HANDLE_PROBE_SRC);
    let mut child = spawn_suspended_shell(cwd.to_str().expect("cwd"), probe.to_str().expect("exe"))
        .expect("spawn probe");
    assert!(!child.b_inherit_handles);
    assert!(!child.inherit_owner);
    assert!(!child.inherit_public);
    let previous = resume_once(child.thread.0);
    assert_eq!(previous, 1);
    child.disarm();
    let _ = child.wait_exit();
    let body = fs::read_to_string(&probe_report).unwrap_or_default();
    assert!(body.contains("owner=0"), "{body}");
    assert!(body.contains("public=0"), "{body}");
    drop(child);
    drop(owner_file);
    drop(public_file);

    let release = cwd.join("release.txt");
    let waiter = compile_helper("task864_wait_file", WAIT_FILE_SRC);
    let mut unowned = Command::new(&waiter)
        .arg(&release)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .expect("unowned");
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let created = owner(
        &harness,
        "pane.create",
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    harness.close_generation();
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        unowned.try_wait().expect("poll unowned").is_none(),
        "unowned must survive generation close"
    );
    fs::write(&release, b"go").expect("release unowned");
    let status = unowned.wait().expect("unowned wait");
    assert!(status.success(), "{status:?}");
    let _ = fs::remove_dir_all(&folder);
    let _ = fs::remove_dir_all(&cwd);
}

#[test]
fn utf8_budget_and_shell_launch_occupancy() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let created = owner(
        &harness,
        "pane.create",
        Some(revision),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    let pane_id = created["result"]["data"]["pane_id"]
        .as_str()
        .expect("pane")
        .to_owned();
    let run_id = created["result"]["data"]["run_id"]
        .as_str()
        .expect("run")
        .to_owned();
    let after = created["topology_revision"].as_u64().expect("rev");
    let unique_name = folder
        .file_name()
        .and_then(|name| name.to_str())
        .expect("unique");
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut filled = String::new();
    let mut filled_read = json!(null);
    while Instant::now() < deadline {
        let read = owner(
            &harness,
            "output.read",
            None,
            json!({"cursor": null, "max_bytes": 4096, "run_id": run_id}),
        );
        assert_eq!(read["accepted"], json!(true), "{read}");
        filled = read["result"]["data"]["text"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        filled_read = read;
        if !filled.is_empty() && filled.contains(unique_name) {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        !filled.is_empty() && filled.contains(unique_name),
        "utf8 fixture produced no child output: {filled}"
    );
    let live = winsmux_workspace::memory_testing::decode_cursor(
        filled_read["result"]["data"]["next_cursor"]
            .as_str()
            .expect("opaque next_cursor"),
    )
    .expect("host-issued next_cursor");
    assert_eq!(live.instance_id.as_str(), instance(&harness));
    assert_eq!(live.run_id.as_str(), run_id);
    let origin = live
        .offset
        .checked_sub(filled.len() as u64)
        .expect("next_cursor offset covers returned text bytes");
    let jp = filled.find("プロジェクト").expect("japanese in output") as u64;
    let cursor = winsmux_workspace::memory_testing::encode_cursor(
        &live.instance_id,
        &live.run_id,
        origin.saturating_add(jp),
    );
    let one_byte = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": cursor.as_str(), "max_bytes": 1, "run_id": run_id}),
    );
    assert_eq!(one_byte["accepted"], json!(true), "{one_byte}");
    let text = one_byte["result"]["data"]["text"].as_str().unwrap_or("");
    assert!(
        text.is_empty(),
        "max_bytes=1 at a 3-byte Japanese char must not emit a partial character: {text:?}"
    );
    assert_eq!(
        one_byte["result"]["data"]["truncated"],
        json!(true),
        "{one_byte}"
    );
    let three = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": cursor.as_str(), "max_bytes": 3, "run_id": run_id}),
    );
    assert_eq!(three["accepted"], json!(true), "{three}");
    let three_text = three["result"]["data"]["text"].as_str().unwrap_or("");
    assert_eq!(three_text, "プ", "exact UTF-8 character boundary: {three}");
    let huge = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": null, "max_bytes": 4000000, "run_id": run_id}),
    );
    assert_eq!(huge["accepted"], json!(true), "{huge}");
    let body = serde_json::to_vec(&huge).expect("json");
    assert!(body.len() <= 1_048_576, "oversized {}", body.len());
    assert!(!huge["result"]["data"]["text"]
        .as_str()
        .unwrap_or("")
        .is_empty());
    let running_launch = owner(
        &harness,
        "shell.launch",
        None,
        json!({"pane_id": pane_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(
        running_launch["error"]["code"],
        json!("already_running"),
        "{running_launch}"
    );
    let _ = (folder, project_id, pane_id, run_id, after);
}

#[test]
fn overlapped_cancel_is_not_ctrl_c_delivery() {
    assert!(
        prove_overlapped_cancel_is_not_delivery(),
        "CancelIoEx of a pending overlapped 0x03 must not count as delivery"
    );
}

#[test]
fn resume_states_immediate_259_and_failed_publication() {
    let cwd = std::env::temp_dir().join(format!("winsmux-864-resume-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("cwd");
    let exe = compile_helper("task864_exit259", EXIT259_SRC);
    let mut child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn");
    let extra = suspend_once(child.thread.0);
    assert!(extra >= 1, "extra SuspendThread {extra}");
    let previous = resume_once(child.thread.0);
    assert!(previous > 1, "previous after extra suspend {previous}");
    child.disarm();
    drop(child);

    let mut child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn 259");
    let previous = resume_once(child.thread.0);
    assert_eq!(previous, 1);
    child.disarm();
    let code = child.wait_exit().expect("exit");
    assert_eq!(code, STILL_ACTIVE);
    assert_eq!(handle_signaled(child.process.0), Some(true));
    drop(child);

    let runtime = RuntimeService::new();
    let project = ProjectId::new("30000000-0000-4000-8000-00000000aa01").expect("p");
    let pane = PaneId::new("40000000-0000-4000-8000-00000000aa01").expect("pane");
    let run = RunId::new("50000000-0000-4000-8000-00000000aa01").expect("run");
    runtime
        .insert_preparing(project.clone(), pane.clone(), run.clone())
        .expect("prep");
    let mut child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn already-runnable");
    let previous = resume_once(child.thread.0);
    assert_eq!(previous, 1);
    child.disarm();
    runtime.attach_child(&run, child).expect("attach");
    match runtime.resume_and_observe(&run) {
        Ok(winsmux_workspace::memory_testing::Activation::AlreadyRunnable) => {}
        other => panic!("expected already-runnable containment, got {other:?}"),
    }
    runtime.finalize_failure(&run, true);
    assert!(
        !runtime.testing_has_session(&run),
        "failed publication must drop the session"
    );

    let run2 = RunId::new("50000000-0000-4000-8000-00000000aa02").expect("run2");
    runtime
        .insert_preparing(project.clone(), pane.clone(), run2.clone())
        .expect("prep2");
    let child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn extra");
    let _ = suspend_once(child.thread.0);
    runtime.attach_child(&run2, child).expect("attach extra");
    match runtime.resume_and_observe(&run2) {
        Ok(winsmux_workspace::memory_testing::Activation::ExtraSuspension) => {}
        other => panic!("expected extra-suspension containment, got {other:?}"),
    }
    runtime.finalize_failure(&run2, true);
    assert!(!runtime.testing_has_session(&run2));

    let run3 = RunId::new("50000000-0000-4000-8000-00000000aa03").expect("run3");
    runtime
        .insert_preparing(project, pane, run3.clone())
        .expect("prep3");
    let mut child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn fail");
    child.thread.close();
    runtime.attach_child(&run3, child).expect("attach fail");
    match runtime.resume_and_observe(&run3) {
        Ok(winsmux_workspace::memory_testing::Activation::ResumeFailed) => {}
        other => panic!("expected resume failure containment, got {other:?}"),
    }
    runtime.finalize_failure(&run3, true);
    assert!(!runtime.testing_has_session(&run3));
    let _ = fs::remove_dir_all(&cwd);
}

#[test]
fn generation_close_contains_preparing_and_published() {
    let cwd = std::env::temp_dir().join(format!("winsmux-864-close-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("cwd");
    let waiter = compile_helper("task864_wait_file", WAIT_FILE_SRC);
    let runtime = RuntimeService::new();
    let project = ProjectId::new("30000000-0000-4000-8000-00000000ab01").expect("p");
    let pane = PaneId::new("40000000-0000-4000-8000-00000000ab01").expect("pane");
    let preparing = RunId::new("50000000-0000-4000-8000-00000000ab01").expect("prep");
    let published = RunId::new("50000000-0000-4000-8000-00000000ab02").expect("pub");
    runtime
        .insert_preparing(project.clone(), pane.clone(), preparing.clone())
        .expect("prep");
    let mut child =
        spawn_suspended_shell(cwd.to_str().expect("cwd"), waiter.to_str().expect("exe"))
            .expect("preparing child");
    child.disarm();
    runtime
        .attach_child(&preparing, child)
        .expect("attach preparing");
    runtime
        .insert_preparing(project.clone(), pane, published.clone())
        .expect("pub rec");
    let child = spawn_suspended_shell(cwd.to_str().expect("cwd"), waiter.to_str().expect("exe"))
        .expect("published child");
    runtime
        .attach_child(&published, child)
        .expect("attach published");
    match runtime.resume_and_observe(&published) {
        Ok(winsmux_workspace::memory_testing::Activation::Published { .. }) => {}
        other => panic!("expected publish, got {other:?}"),
    }
    let jobs = runtime.take_jobs_for_generation_close();
    assert!(
        !jobs.is_empty(),
        "generation close must take preparing and published jobs"
    );
    for job in jobs {
        if !job.is_null() && job != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(job);
            }
        }
    }
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        !runtime.session_clean(&preparing) || !runtime.testing_has_session(&preparing),
        "preparing must be contained without ResumeThread"
    );
    let _ = fs::remove_dir_all(&cwd);
}

#[test]
fn natural_root_exit_leaves_descendants_unclean() {
    let cwd = std::env::temp_dir().join(format!("winsmux-864-desc-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("cwd");
    let release = cwd.join("release.txt");
    std::env::set_var(
        "WINSMUX_TASK864_RELEASE",
        release.to_string_lossy().as_ref(),
    );
    let exe = compile_helper("task864_descendant", DESCENDANT_SRC);
    let runtime = RuntimeService::new();
    let project = ProjectId::new("30000000-0000-4000-8000-00000000ac01").expect("p");
    let pane = PaneId::new("40000000-0000-4000-8000-00000000ac01").expect("pane");
    let run = RunId::new("50000000-0000-4000-8000-00000000ac01").expect("run");
    runtime
        .insert_preparing(project, pane, run.clone())
        .expect("prep");
    let child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn descendant parent");
    let process = child.process.0;
    runtime.attach_child(&run, child).expect("attach");
    match runtime.resume_and_observe(&run) {
        Ok(winsmux_workspace::memory_testing::Activation::Published { .. }) => {}
        other => panic!("expected publish, got {other:?}"),
    }
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || handle_signaled(process) == Some(true),
        "root HANDLE did not signal",
    );
    let bits = runtime.testing_session_clean_bits(&run).expect("bits");
    assert!(bits.1, "root handle signaled");
    assert!(!bits.2, "descendants must keep the job non-empty");
    assert!(
        !bits.0,
        "ordinary close must not pass while descendants remain"
    );
    fs::write(&release, b"go").expect("release descendants");
    let _ = fs::remove_dir_all(&cwd);
}

#[test]
fn cwd_helper_matches_unique_japanese_space_directory() {
    let unique = format!("winsmux-864-プロジェクト space-{}", uuid::Uuid::new_v4());
    let folder = std::env::temp_dir().join(&unique);
    fs::create_dir_all(&folder).expect("folder");
    let report = folder.join("cwd.txt");
    std::env::set_var("WINSMUX_TASK864_REPORT", report.to_string_lossy().as_ref());
    std::env::set_var(
        "WINSMUX_TASK864_RELEASE",
        folder.join("go.txt").to_string_lossy().as_ref(),
    );
    let exe = compile_helper("task864_cwd", CWD_SRC);
    let mut child =
        spawn_suspended_shell(folder.to_str().expect("cwd"), exe.to_str().expect("exe"))
            .expect("spawn cwd");
    assert_eq!(resume_once(child.thread.0), 1);
    child.disarm();
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || report.exists(),
        "cwd helper did not report",
    );
    let body = fs::read_to_string(&report).expect("cwd report");
    assert!(
        body.contains(&unique),
        "child GetCurrentDirectory must equal unique Japanese+space path, got {body}"
    );
    fs::write(folder.join("go.txt"), b"go").ok();
    drop(child);
    let _ = fs::remove_dir_all(&folder);
}

#[test]
fn readfile_after_pty_and_job_close_is_terminal_not_request() {
    let cwd = std::env::temp_dir().join(format!("winsmux-864-read-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("cwd");
    let exe = compile_helper("task864_exit259", EXIT259_SRC);
    let proof = prove_readfile_after_pty_and_job_close(
        cwd.to_str().expect("cwd"),
        exe.to_str().expect("exe"),
    )
    .expect("native ReadFile after PTY/job close");
    eprintln!(
        "readfile_after_close csi_gle={} first_ok={} first_n={} first_gle={:?} first_class={:?} second_ok={} second_n={} second_gle={} second_class={:?} job_ok={} job_n={} job_gle={} job_class={:?}",
        proof.csi_gle,
        proof.first_ok,
        proof.first_n,
        proof.first_gle,
        proof.first_class,
        proof.second_ok,
        proof.second_n,
        proof.second_gle,
        proof.second_class,
        proof.job_ok,
        proof.job_n,
        proof.job_gle,
        proof.job_class
    );
    assert!(
        proof.csi_not_found,
        "CancelIoEx on a never-issued OVERLAPPED must be ERROR_NOT_FOUND, gle={}",
        proof.csi_gle
    );
    assert_ne!(
        proof.first_class,
        ReadClass::TrueZero,
        "TRUE n==0 is not EOF and was not the ClosePseudoConsole terminal"
    );
    assert!(
        matches!(proof.first_class, ReadClass::Drain | ReadClass::ReadError),
        "in-flight ReadFile after ClosePseudoConsole must complete, class={:?}",
        proof.first_class
    );
    assert!(
        matches!(proof.second_class, ReadClass::Drain | ReadClass::ReadError),
        "subsequent ReadFile after teardown must complete, class={:?}",
        proof.second_class
    );
    assert!(
        matches!(proof.job_class, ReadClass::Drain | ReadClass::ReadError),
        "ReadFile after job-close request must complete as observed I/O, class={:?}",
        proof.job_class
    );
    let _ = fs::remove_dir_all(&cwd);
}

#[test]
fn write_pin_identity_survives_query_and_runtime_drop() {
    let before = retained_write_count();
    let (op, issued, obs) =
        issue_pending_overlapped_write().expect("actual pending overlapped 0x03");
    let queried = op.identity();
    assert_eq!(issued, queried, "HANDLE+OVERLAPPED+hEvent+pin must stay put");
    match obs {
        IoObservation::Pending => {}
        IoObservation::QueryFailed(gle) => {
            eprintln!("query failed gle={gle} retained as unknown");
        }
        IoObservation::Completed { .. } => {
            panic!("fill-until-pending 0x03 must not complete immediately: {obs:?}")
        }
    }
    let runtime = RuntimeService::new();
    let project = ProjectId::new("30000000-0000-4000-8000-00000000ad01").expect("p");
    let pane = PaneId::new("40000000-0000-4000-8000-00000000ad01").expect("pane");
    let run = RunId::new("50000000-0000-4000-8000-00000000ad01").expect("run");
    runtime
        .insert_preparing(project, pane, run.clone())
        .expect("prep");
    runtime
        .testing_install_write(&run, op)
        .expect("install pending write");
    drop(runtime);
    let after = retained_write_count();
    assert!(
        after > before,
        "pending write must remain HostRetainedIo after RuntimeService Drop, before={before} after={after}"
    );
    assert!(
        retained_write_identities().iter().any(|id| *id == issued),
        "retained Pin must keep the issued HANDLE+OVERLAPPED+hEvent identity"
    );
}

#[test]
fn natural_exit_can_drain_before_pty_close() {
    let cwd = std::env::temp_dir().join(format!("winsmux-864-eof-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("cwd");
    let exe = compile_helper("task864_exit259", EXIT259_SRC);
    let runtime = RuntimeService::new();
    let project = ProjectId::new("30000000-0000-4000-8000-00000000ae01").expect("p");
    let pane = PaneId::new("40000000-0000-4000-8000-00000000ae01").expect("pane");
    let run = RunId::new("50000000-0000-4000-8000-00000000ae01").expect("run");
    runtime
        .insert_preparing(project, pane, run.clone())
        .expect("prep");
    let child = spawn_suspended_shell(cwd.to_str().expect("cwd"), exe.to_str().expect("exe"))
        .expect("spawn");
    runtime.attach_child(&run, child).expect("attach");
    match runtime.resume_and_observe(&run) {
        Ok(winsmux_workspace::memory_testing::Activation::Published { .. }) => {}
        other => panic!("expected publish, got {other:?}"),
    }
    let mut saw_drain_before_pty = false;
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || {
            let bits = runtime.testing_session_clean_bits(&run);
            if let Some((_, _, _, drain, reader, _, _, pty, _, _)) = bits {
                if (drain || reader) && !pty {
                    saw_drain_before_pty = true;
                }
                drain && reader && pty
            } else {
                false
            }
        },
        "reader/PTY did not finish after natural child exit",
    );
    let io = runtime.testing_session_io(&run).expect("io");
    eprintln!(
        "natural_exit drain={} reader_returned={} reader_error={} drain_before_pty={saw_drain_before_pty}",
        io.0, io.1, io.2
    );
    assert!(io.0 || io.2, "natural exit must produce drain or a classified read error, not hang");
    assert!(io.1, "reader must return");
    let _ = fs::remove_dir_all(&cwd);
}


#[cfg(debug_assertions)]
mod launch_guard_proof {
    use super::*;
    use std::sync::{mpsc, Arc, Mutex};
    use std::thread::{self, JoinHandle};
    use winsmux_workspace::auth::testing::{Client, SpawnPreparedGuard};
    use winsmux_workspace::auth::{RetainedCleanupObservation, RetainedCleanupSnapshot};

    struct Fixture {
        harness: Harness,
        root: PathBuf,
        project: String,
        pane: String,
        original: String,
        revision: u64,
    }

    impl Fixture {
        fn new() -> Self {
            let root =
                std::env::temp_dir().join(format!("task873-launch-guard-{}", uuid::Uuid::new_v4()));
            let folder = root.join("empty-project");
            fs::create_dir_all(&folder).unwrap();
            let harness = Harness::new(Vec::new());
            assert!(harness
                .authorization()
                .testing_install_isolated_layout(&root.join("store")));
            let opened = owner(
                &harness,
                "project.open",
                Some(0),
                json!({"path":folder.to_string_lossy()}),
            );
            assert_eq!(opened["accepted"], true, "{opened}");
            let project = opened["result"]["data"]["project_id"]
                .as_str()
                .unwrap()
                .to_owned();
            let created = owner(
                &harness,
                "pane.create",
                opened["topology_revision"].as_u64(),
                json!({"project_id":project,"shell_profile_id":"pwsh"}),
            );
            assert_eq!(created["accepted"], true, "{created}");
            let pane = created["result"]["data"]["pane_id"]
                .as_str()
                .unwrap()
                .to_owned();
            let original = created["result"]["data"]["run_id"]
                .as_str()
                .unwrap()
                .to_owned();
            let revision = created["topology_revision"].as_u64().unwrap();
            Self {
                harness,
                root,
                project,
                pane,
                original,
                revision,
            }
        }

        fn stop_clean(&self, run: &str) {
            let typed = RunId::new(run).unwrap();
            let identity = self
                .harness
                .authorization()
                .testing_owned_process_identity(&typed)
                .expect("same owned native process");
            let initial = owner(&self.harness, "run.get", None, json!({"run_id":run}));
            assert_eq!(initial["accepted"], true, "{initial}");
            if initial["result"]["data"]["run"]["process"] != "exited" {
                let interrupted =
                    owner(&self.harness, "run.interrupt", None, json!({"run_id":run}));
                assert!(
                    interrupted["accepted"] == true
                        || interrupted["error"]["code"] == "not_running",
                    "{interrupted}"
                );
            }
            let deadline = Instant::now() + Duration::from_secs(30);
            loop {
                let status = owner(&self.harness, "run.get", None, json!({"run_id":run}));
                assert_eq!(status["accepted"], true, "{status}");
                let cleanup_flags = self.harness.authorization()
                    .testing_session_clean_bits(&typed).is_some_and(|bits| bits.0);
                if run_completion::projected_cleanup_matches(&status, cleanup_flags) {
                    assert_eq!(status["result"]["data"]["run"]["process"], "exited");
                    assert_eq!(status["result"]["data"]["run"]["evidence"], "process_exit");
                    assert_eq!(
                        self.harness
                            .authorization()
                            .testing_job_stop_stats(&typed)
                            .unwrap()
                            .5,
                        Some(0)
                    );
                    eprintln!(
                        "TASK873_RUNTIME_FLAGS {}",
                        json!({"run":run,"pid":identity.0,"creation_filetime":identity.1,"process_exit":true,"session_clean":true,"job_active":0})
                    );
                    return;
                }
                assert!(Instant::now() < deadline, "same run not clean: {status}");
                thread::sleep(Duration::from_millis(50));
            }
        }

        fn restore_empty(&mut self) {
            self.stop_clean(&self.original);
            let saved = owner(&self.harness, "layout.save", None, json!({}));
            assert_eq!(saved["accepted"], true, "{saved}");
            let restored = owner(
                &self.harness,
                "layout.restore",
                Some(self.revision),
                json!({}),
            );
            assert_eq!(restored["accepted"], true, "{restored}");
            self.revision = restored["topology_revision"].as_u64().unwrap();
            assert_eq!(
                self.list()["result"]["data"]["panes"][0]["current_run_id"],
                Value::Null
            );
        }

        fn list(&self) -> Value {
            owner(
                &self.harness,
                "pane.list",
                None,
                json!({"project_id":self.project}),
            )
        }

        fn grant(&self, scopes: Value) -> (Client, String) {
            let client = self.harness.connect("task873-fixture.exe");
            let pending = value(
                &client
                    .request(&request(
                        "connection.request",
                        None,
                        None,
                        json!({"project_ids":[self.project],"scopes":scopes}),
                    ))
                    .unwrap(),
            );
            let connection = pending["result"]["data"]["connection_id"]
                .as_str()
                .unwrap()
                .to_owned();
            let allowed = owner(
                &self.harness,
                "connection.decide",
                None,
                json!({"connection_id":connection,"decision":"allow","project_ids":[self.project],"scopes":scopes}),
            );
            assert_eq!(allowed["accepted"], true, "{allowed}");
            (client, connection)
        }

        fn ready(&self, provider: &str) {
            self.harness.start_provider_probes();
            let deadline = Instant::now() + Duration::from_secs(60);
            loop {
                let capabilities = owner(&self.harness, "capabilities.get", None, json!({}));
                if capabilities["result"]["data"]["providers"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|p| p["provider"] == provider)
                {
                    eprintln!(
                        "TASK873_OFFICIAL_CAPABILITY {}",
                        json!({"provider":provider,"capabilities":capabilities["result"]["data"]["providers"]})
                    );
                    return;
                }
                assert!(
                    Instant::now() < deadline,
                    "official provider not ready: {capabilities}"
                );
                thread::sleep(Duration::from_millis(50));
            }
        }

        fn finish(&self, run: &str) {
            self.stop_clean(run);
            let closed = owner(
                &self.harness,
                "pane.close",
                Some(self.revision),
                json!({"pane_id":self.pane,"expected_current_run_id":run}),
            );
            assert_eq!(closed["accepted"], true, "{closed}");
            let forgotten = owner(
                &self.harness,
                "project.forget",
                closed["topology_revision"].as_u64(),
                json!({"project_id":self.project}),
            );
            assert_eq!(forgotten["accepted"], true, "{forgotten}");
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            self.harness.close_generation();
        }
    }

    fn params(kind: &str, pane: &str, expected: Option<Value>) -> Value {
        let mut value = if kind == "shell" {
            json!({"pane_id":pane,"shell_profile_id":"pwsh"})
        } else {
            json!({"pane_id":pane,"provider":kind,"model":null,"effort":null})
        };
        if let Some(expected) = expected {
            value["expected_current_run_id"] = expected;
        }
        value
    }
    fn operation(kind: &str) -> &'static str {
        if kind == "shell" {
            "shell.launch"
        } else {
            "agent.launch"
        }
    }
    fn counts(f: &Fixture) -> (u64, u64) {
        f.harness.authorization().testing_spawn_counts()
    }
    fn delta(before: (u64, u64), after: (u64, u64)) -> (u64, u64) {
        (after.0 - before.0, after.1 - before.1)
    }

    fn retained_released(s: &RetainedCleanupSnapshot) -> bool {
        s.process_signaled
            && s.reader_signaled
            && s.waiter_signaled
            && s.teardown_signaled
            && s.handle_signaled
            && s.drain_complete
            && s.reader_returned
            && s.waiter_returned
            && s.teardown_returned
            && s.pty_closed
            && !s.write_pending
            && s.io.pty_closed
            && !s.io.write_pending
            && !s.io.pin_present
            && !s.io.input_handle_present
            && !s.io.hpcon_handle_present
            && s.io.input_lease_count == 0
            && s.io.hpcon_lease_count == 0
    }

    // One completion owner and predicate for every prepared launch outcome.
    fn prove_retained_cleanup(
        observer: &RetainedCleanupObservation,
        before: &RetainedCleanupSnapshot,
        run: &RunId,
        label: &str,
    ) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let snapshot = observer.snapshot().expect("same retained native observation");
            assert_eq!(&snapshot.run_id, run);
            assert_eq!(snapshot.process_id, before.process_id);
            assert_eq!(snapshot.creation_time, before.creation_time);
            if retained_released(&snapshot) {
                // The real callback-boundary test in runtime proves returned=true
                // while waiter_signaled=false is possible. The success and refusal
                // completion owner must reject that state and every sibling HANDLE.
                for axis in 0..4 {
                    let mut incomplete = snapshot.clone();
                    match axis {
                        0 => incomplete.process_signaled = false,
                        1 => incomplete.reader_signaled = false,
                        2 => incomplete.waiter_signaled = false,
                        _ => incomplete.teardown_signaled = false,
                    }
                    assert!(!retained_released(&incomplete), "returned flags cannot complete axis {axis}");
                }
                assert_eq!(observer.snapshot().unwrap(), snapshot, "stable nonmutating completed snapshot");
                eprintln!("TASK873_RETAINED_CLEANUP label={} run={} before={:?} after={:?}", label, run.as_str(), before, snapshot);
                return;
            }
            assert!(Instant::now() < deadline, "retained cleanup incomplete: {snapshot:?}");
            thread::sleep(Duration::from_millis(50));
        }
    }

    struct AcceptedRun {
        observer: RetainedCleanupObservation,
        before: RetainedCleanupSnapshot,
        run: RunId,
    }

    impl AcceptedRun {
        fn launch(f: &Fixture, kind: &str, id: &str, params: Value) -> (Value, Self) {
            let authorization = f.harness.authorization();
            let captured = Arc::new(Mutex::new(None));
            let slot = captured.clone();
            let counts_before = counts(f);
            let guard = f.harness.use_hook_for_next_prepared_spawn(Arc::new(move |run| {
                assert_eq!(authorization.testing_spawn_counts(), (counts_before.0 + 1, counts_before.1));
                let observer = authorization.testing_retain_cleanup(run).expect("prepare-time observer required");
                let before = observer.snapshot().expect("nonmutating prepared snapshot");
                assert_eq!(before.run_id, *run);
                assert_eq!(before.prepared_job_members, 1);
                assert!(!before.process_signaled && !retained_released(&before));
                assert_eq!(observer.snapshot().unwrap(), before);
                let mut slot = slot.lock().unwrap();
                assert!(slot.is_none(), "one observer per actual prepared run");
                *slot = Some(Self { observer, before, run: run.clone() });
            }));
            let response = owner_id(&f.harness, operation(kind), id, None, params);
            drop(guard);
            assert_eq!(response["accepted"], true, "{response}");
            let retained = captured.lock().unwrap().take().expect("exact prepared run captured");
            assert_eq!(response["result"]["data"]["run_id"], retained.run.as_str());
            let current = retained.observer.snapshot().unwrap();
            assert_eq!(current.process_id, retained.before.process_id);
            assert_eq!(current.creation_time, retained.before.creation_time);
            (response, retained)
        }

        fn stop_clean(&self, f: &Fixture, label: &str) {
            f.stop_clean(self.run.as_str());
            prove_retained_cleanup(&self.observer, &self.before, &self.run, label);
        }
    }

    struct Paused {
        release: Option<mpsc::Sender<()>>,
        worker: Option<JoinHandle<Option<winsmux_workspace::contract::Response>>>,
        _guard: SpawnPreparedGuard,
        observer: RetainedCleanupObservation,
        before: RetainedCleanupSnapshot,
        run: RunId,
    }
    impl Paused {
        fn start(f: &Fixture, client: &Client, req: Request) -> Self {
            let (prepared_tx, prepared_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let release_rx = Mutex::new(release_rx);
            let guard = f
                .harness
                .use_hook_for_next_prepared_spawn(Arc::new(move |run| {
                    prepared_tx.send(run.clone()).expect("prepared receiver");
                    let _ = release_rx.lock().unwrap().recv();
                }));
            let client = client.clone();
            let worker = thread::spawn(move || client.request(&req));
            // Own release and join before receiving, so failed setup still unblocks.
            let mut partial = PausedSetup {
                release: Some(release_tx),
                worker: Some(worker),
            };
            let run = prepared_rx
                .recv_timeout(Duration::from_secs(60))
                .expect("actual suspended child");
            let observer = f
                .harness
                .authorization()
                .testing_retain_cleanup(&run)
                .expect("retained exact process and workers required");
            let before = observer.snapshot().expect("immutable native snapshot");
            assert_eq!(before.prepared_job_members, 1);
            assert!(!before.process_signaled);
            Self {
                release: partial.release.take(),
                worker: partial.worker.take(),
                _guard: guard,
                observer,
                before,
                run,
            }
        }
        fn finish(&mut self) -> Option<Value> {
            if let Some(release) = self.release.take() {
                let _ = release.send(());
            }
            self.worker
                .take()
                .unwrap()
                .join()
                .expect("launch thread")
                .map(|r| value(&r))
        }
        fn prove_cleanup(&self) {
            prove_retained_cleanup(&self.observer, &self.before, &self.run, "prepared-refusal");
        }
    }

    struct PausedSetup {
        release: Option<mpsc::Sender<()>>,
        worker: Option<JoinHandle<Option<winsmux_workspace::contract::Response>>>,
    }
    impl Drop for PausedSetup {
        fn drop(&mut self) {
            if let Some(x) = self.release.take() {
                let _ = x.send(());
            }
            if let Some(x) = self.worker.take() {
                let _ = x.join();
            }
        }
    }
    impl Drop for Paused {
        fn drop(&mut self) {
            if let Some(x) = self.release.take() {
                let _ = x.send(());
            }
            if let Some(x) = self.worker.take() {
                let _ = x.join();
            }
        }
    }

    fn positive_and_swap(kind: &str) {
        let mut f = Fixture::new();
        f.restore_empty();
        if kind != "shell" {
            f.ready(kind);
        }
        let before = counts(&f);
        // A UUID cannot authorize the actual null current-run state.
        let wrong = owner(
            &f.harness,
            operation(kind),
            None,
            params(kind, &f.pane, Some(json!(f.original))),
        );
        assert_eq!(wrong["error"]["code"], "target_not_found", "{wrong}");
        assert_eq!(counts(&f), before);
        let id = uuid::Uuid::new_v4().to_string();
        let p = params(kind, &f.pane, Some(Value::Null));
        let (launched, retained_null) = AcceptedRun::launch(&f, kind, &id, p.clone());
        assert_eq!(launched["accepted"], true, "{launched}");
        assert_eq!(delta(before, counts(&f)), (1, 1));
        let run = launched["result"]["data"]["run_id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            f.list()["result"]["data"]["panes"][0]["current_run_id"],
            run
        );
        assert_eq!(
            owner_id(&f.harness, operation(kind), &id, None, p.clone()),
            launched
        );
        for guard in [None, Some(json!(run)), Some(json!(f.original))] {
            let denied = owner_id(
                &f.harness,
                operation(kind),
                &id,
                None,
                params(kind, &f.pane, guard),
            );
            assert_eq!(denied["error"]["code"], "operation_conflict", "{denied}");
        }
        if kind != "shell" {
            for field in ["model", "effort", "provider"] {
                let mut changed = p.clone();
                changed[field] = json!(if field == "provider" {
                    if kind == "codex" {
                        "claude"
                    } else {
                        "codex"
                    }
                } else {
                    "different"
                });
                let denied = owner_id(&f.harness, operation(kind), &id, None, changed);
                assert_eq!(denied["error"]["code"], "operation_conflict", "{denied}");
            }
        }
        assert_eq!(
            delta(before, counts(&f)),
            (1, 1),
            "replays never prepare a second child"
        );
        // Same current identity still cannot replace a live run.
        let live = owner(
            &f.harness,
            operation(kind),
            None,
            params(kind, &f.pane, Some(json!(run))),
        );
        assert_eq!(live["error"]["code"], "already_running", "{live}");
        retained_null.stop_clean(&f, "accepted-null-after-replay");
        let before = counts(&f);
        let (matched, retained_current) = AcceptedRun::launch(
            &f,
            kind,
            &uuid::Uuid::new_v4().to_string(),
            params(kind, &f.pane, Some(json!(run))),
        );
        assert_eq!(matched["accepted"], true, "{matched}");
        assert_eq!(delta(before, counts(&f)), (1, 1));
        let same_target_run = matched["result"]["data"]["run_id"]
            .as_str()
            .unwrap()
            .to_owned();
        retained_current.stop_clean(&f, "accepted-current");
        // Real ordinary shell exchange after GUI confirmation, without a T change.
        let (swapped, retained_replacement) = AcceptedRun::launch(
            &f,
            "shell",
            &uuid::Uuid::new_v4().to_string(),
            params("shell", &f.pane, None),
        );
        assert_eq!(swapped["accepted"], true, "{swapped}");
        assert_eq!(swapped["topology_revision"], f.revision);
        let replacement = swapped["result"]["data"]["run_id"]
            .as_str()
            .unwrap()
            .to_owned();
        retained_replacement.stop_clean(&f, "ordinary-replacement");
        let before_list = f.list();
        let before_count = counts(&f);
        let saved = owner(&f.harness, "layout.save", None, json!({}));
        assert_eq!(saved["accepted"], true);
        let stored = fs::read(f.root.join("store/confirmed.json")).unwrap();
        for denied_kind in ["shell", "codex", "claude"] {
            for expected in [Value::Null, json!(same_target_run)] {
                let p = params(denied_kind, &f.pane, Some(expected));
                let id = uuid::Uuid::new_v4().to_string();
                let denied = owner_id(&f.harness, operation(denied_kind), &id, None, p.clone());
                assert_eq!(denied["error"]["code"], "target_not_found", "{denied}");
                assert_eq!(
                    owner_id(&f.harness, operation(denied_kind), &id, None, p),
                    denied
                );
            }
        }
        assert_eq!(counts(&f), before_count);
        let after_list = f.list();
        assert_eq!(
            before_list["topology_revision"],
            after_list["topology_revision"]
        );
        let mut before_data = before_list["result"]["data"].clone();
        let mut after_data = after_list["result"]["data"].clone();
        // run.get/pane.list refresh their query timestamp even for an exited run.
        // Preserve every identity and state field; only the observation time varies.
        let before_time = before_data["panes"][0]["observation"]
            .as_object_mut()
            .unwrap()
            .remove("observed_at")
            .unwrap();
        let after_time = after_data["panes"][0]["observation"]
            .as_object_mut()
            .unwrap()
            .remove("observed_at")
            .unwrap();
        assert!(after_time.as_str().unwrap() >= before_time.as_str().unwrap());
        assert_eq!(before_data, after_data);
        assert_eq!(
            stored,
            fs::read(f.root.join("store/confirmed.json")).unwrap()
        );
        eprintln!(
            "TASK873_GUARD_POSITIVE_SWAP {}",
            json!({"kind":kind,"old_confirmed":same_target_run,"replacement":replacement,"topology":f.revision,"initial_rejection_spawn_delta":[0,0],"guarded_success_delta":[1,1],"replay_additional_delta":[0,0]})
        );
        f.finish(&replacement);
        prove_retained_cleanup(&retained_null.observer, &retained_null.before, &retained_null.run, "accepted-null-after-session-removal");
        prove_retained_cleanup(&retained_current.observer, &retained_current.before, &retained_current.run, "accepted-current-after-session-removal");
        prove_retained_cleanup(&retained_replacement.observer, &retained_replacement.before, &retained_replacement.run, "replacement-after-session-removal");
    }

    fn prepared_races(kind: &str) {
        for action in ["pane.close", "connection.revoke", "generation.close"] {
            let f = Fixture::new();
            f.stop_clean(&f.original);
            if kind != "shell" {
                f.ready(kind);
            }
            let (client, connection) = f.grant(json!(["metadata", "control"]));
            let req = request(
                operation(kind),
                Some(&instance(&f.harness)),
                None,
                params(kind, &f.pane, Some(json!(f.original))),
            );
            let before = counts(&f);
            let mut paused = Paused::start(&f, &client, req);
            assert_eq!(delta(before, counts(&f)), (1, 0));
            let reserved = f.list();
            assert_eq!(
                reserved["result"]["data"]["panes"][0]["current_run_id"],
                f.original
            );
            let sibling = owner(
                &f.harness,
                "shell.launch",
                None,
                params("shell", &f.pane, Some(json!(f.original))),
            );
            assert_eq!(sibling["error"]["code"], "already_running", "{sibling}");
            if kind != "shell" {
                let sibling = owner(
                    &f.harness,
                    "agent.launch",
                    None,
                    params(kind, &f.pane, Some(json!(f.original))),
                );
                assert_eq!(sibling["error"]["code"], "already_running", "{sibling}");
            }
            let restore = owner(&f.harness, "layout.restore", Some(f.revision), json!({}));
            assert_eq!(restore["error"]["code"], "operation_conflict", "{restore}");
            let forget = owner(
                &f.harness,
                "project.forget",
                Some(f.revision),
                json!({"project_id":f.project}),
            );
            assert_eq!(forget["error"]["code"], "operation_conflict", "{forget}");
            assert_eq!(counts(&f), (before.0 + 1, before.1));
            match action {
                "pane.close" => {
                    let close = owner(
                        &f.harness,
                        "pane.close",
                        Some(f.revision),
                        json!({"pane_id":f.pane,"expected_current_run_id":f.original}),
                    );
                    assert_eq!(close["accepted"], true, "{close}");
                }
                "connection.revoke" => {
                    let revoke = owner(
                        &f.harness,
                        "connection.revoke",
                        None,
                        json!({"connection_id":connection}),
                    );
                    assert_eq!(revoke["accepted"], true, "{revoke}");
                }
                _ => f.harness.close_generation(),
            }
            let result = paused.finish();
            if let Some(response) = &result {
                assert_ne!(response["accepted"], true, "{response}");
            }
            assert_eq!(
                delta(before, counts(&f)),
                (1, 0),
                "prepared child was never resumed"
            );
            paused.prove_cleanup();
            assert!(!f.harness.authorization().testing_has_session(&paused.run));
            if action != "generation.close" {
                let listed = f.list();
                if action == "pane.close" {
                    assert_eq!(listed["result"]["data"]["panes"], json!([]));
                } else {
                    assert_eq!(
                        listed["result"]["data"]["panes"][0]["current_run_id"],
                        f.original
                    );
                }
            }
            eprintln!(
                "TASK873_PREPARED_RACE {}",
                json!({"kind":kind,"action":action,"run":paused.run.as_str(),"counts_delta":[1,0],"response":result,"native_cleanup":true})
            );
        }
    }

    #[test]
    fn cleanup_read_metadata_authorization_absence_and_history() {
        let f = Fixture::new();
        let (reader, _) = f.grant(json!(["metadata"]));
        let (control_only, _) = f.grant(json!(["control"]));
        for extended in [false, true] {
            let mut params = json!({"run_id":f.original});
            if extended { params["include_cleanup"] = json!(true); }
            let query = request("run.get", Some(&instance(&f.harness)), None, params);
            let allowed = value(&reader.request(&query).unwrap());
            assert_eq!(allowed["accepted"], true, "{allowed}");
            assert_eq!(allowed["result"]["data"]["run"]["run_id"], f.original);
            assert_eq!(allowed["result"]["data"].as_object().unwrap().contains_key("cleanup_complete"), extended);
            if extended { assert_eq!(allowed["result"]["data"]["cleanup_complete"], false); }
            let denied = value(&control_only.request(&query).unwrap());
            assert_eq!(denied["accepted"], false, "{denied}");
            assert_eq!(denied["error"]["code"], "permission_denied", "{denied}");
        }
        let missing = "50000000-0000-4000-8000-00000000ffff";
        let legacy_missing = owner(&f.harness, "run.get", None, json!({"run_id":missing}));
        let extended_missing = owner(&f.harness, "run.get", None, json!({"include_cleanup":true,"run_id":missing}));
        assert_eq!(legacy_missing["accepted"], false);
        assert_eq!(extended_missing["error"], legacy_missing["error"]);
        f.stop_clean(&f.original);
        let ready = owner(&f.harness, "run.get", None, json!({"include_cleanup":true,"run_id":f.original}));
        assert_eq!(ready["result"]["data"]["cleanup_complete"], true, "{ready}");
        let launched = owner(&f.harness, "shell.launch", None, params("shell", &f.pane, Some(json!(f.original))));
        assert_eq!(launched["accepted"], true, "{launched}");
        let successor = launched["result"]["data"]["run_id"].as_str().unwrap();
        for extended in [false, true] {
            let mut params = json!({"run_id":f.original});
            if extended { params["include_cleanup"] = json!(true); }
            let historical = value(&reader.request(&request("run.get", Some(&instance(&f.harness)), None, params)).unwrap());
            assert_eq!(historical["accepted"], true, "{historical}");
            assert_eq!(historical["result"]["data"]["run"]["current"], false, "{historical}");
            assert_eq!(historical["result"]["data"].as_object().unwrap().contains_key("cleanup_complete"), extended);
            if extended { assert!(historical["result"]["data"]["cleanup_complete"].is_boolean()); }
        }
        f.finish(successor);
    }

    #[test]
    fn cleanup_read_actual_descendant_release_then_guarded_successor() {
        let f = Fixture::new();
        let executable = compile_helper("task873_cleanup_descendant", DESCENDANT_SRC);
        let release = f.root.join("descendant-release.txt");
        struct ReleaseOnDrop(PathBuf);
        impl Drop for ReleaseOnDrop {
            fn drop(&mut self) { let _ = fs::write(&self.0, b"release"); }
        }
        let _release_on_failure = ReleaseOnDrop(release.clone());
        let command = format!("$env:WINSMUX_TASK864_RELEASE='{}'; & '{}'; exit 0\r", release.to_string_lossy().replace('\'', "''"), executable.to_string_lossy().replace('\'', "''"));
        let written = owner(&f.harness, "input.write", None, json!({"pane_id":f.pane,"run_id":f.original,"text":command}));
        assert_eq!(written["accepted"], true, "{written}");
        let typed = RunId::new(&f.original).unwrap();
        wait_until(Instant::now() + Duration::from_secs(30), || f.harness.authorization().testing_session_clean_bits(&typed).is_some_and(|bits| bits.1), "same shell root did not exit");
        let native = f.harness.authorization().testing_job_stop_stats(&typed).unwrap();
        assert!(native.5.is_some_and(|members| members > 0), "descendant must still own a real job member");
        let unfinished = owner(&f.harness, "run.get", None, json!({"include_cleanup":true,"run_id":f.original}));
        assert_eq!(unfinished["accepted"], true, "{unfinished}");
        assert_eq!(unfinished["result"]["data"]["run"]["process"], "exited", "{unfinished}");
        assert_eq!(unfinished["result"]["data"]["run"]["evidence"], "process_exit");
        assert_eq!(unfinished["result"]["data"]["cleanup_complete"], false, "{unfinished}");
        fs::write(&release, b"release").unwrap();
        wait_until(Instant::now() + Duration::from_secs(30), || {
            let read = owner(&f.harness, "run.get", None, json!({"include_cleanup":true,"run_id":f.original}));
            read["result"]["data"]["cleanup_complete"] == true
        }, "released descendant did not finish complete cleanup");
        assert!(f.harness.authorization().testing_session_clean_bits(&typed).unwrap().0);
        assert_eq!(f.harness.authorization().testing_job_stop_stats(&typed).unwrap().5, Some(0));
        let before = counts(&f);
        let launched = owner(&f.harness, "shell.launch", None, params("shell", &f.pane, Some(json!(f.original))));
        assert_eq!(launched["accepted"], true, "{launched}");
        assert_eq!(counts(&f), (before.0 + 1, before.1 + 1));
        let successor = launched["result"]["data"]["run_id"].as_str().unwrap();
        eprintln!("TASK873_CLEANUP_READER descendant_active_after_exit=true cleanup_before_release=false cleanup_after_release=true guarded_successor_once=true");
        f.finish(successor);
    }

    #[test]
    fn launch_guard_completion_requires_fresh_terminal_projection() {
        let f = Fixture::new();
        let stale = owner(&f.harness, "run.get", None, json!({"run_id":f.original}));
        assert_eq!(stale["result"]["data"]["run"]["process"], "running");
        f.stop_clean(&f.original);
        let current = owner(&f.harness, "run.get", None, json!({"run_id":f.original}));
        assert!(!run_completion::projected_cleanup_matches(&stale, true), "later cleanup never changes the earlier running projection");
        assert!(!run_completion::projected_cleanup_matches(&current, false));
        assert!(run_completion::projected_cleanup_matches(&current, true));
        let mut wrong_evidence = current.clone();
        wrong_evidence["result"]["data"]["run"]["evidence"] = json!("unknown");
        assert!(!run_completion::projected_cleanup_matches(&wrong_evidence, true));
        eprintln!("TASK873_OBSERVATION_ORDER stale={} current={} later_clean=true stale_completed=false", stale, current);
        f.finish(&f.original);
    }

    #[test]
    fn launch_guard_shell_current_null_replay_and_legal_swap() {
        positive_and_swap("shell");
    }
    #[test]
    fn launch_guard_shell_prepared_legal_close_revoke_generation() {
        prepared_races("shell");
    }
    #[test]
    fn launch_guard_authorization_precedes_identity_and_missing_pane() {
        let f = Fixture::new();
        let (client, _) = f.grant(json!(["metadata"]));
        let before = counts(&f);
        for kind in ["shell", "codex", "claude"] {
            for expected in [Value::Null, json!(f.original)] {
                let denied = value(
                    &client
                        .request(&request(
                            operation(kind),
                            Some(&instance(&f.harness)),
                            None,
                            params(kind, &f.pane, Some(expected)),
                        ))
                        .unwrap(),
                );
                assert_eq!(denied["error"]["code"], "permission_denied", "{denied}");
            }
            let denied = owner(
                &f.harness,
                operation(kind),
                None,
                params(
                    kind,
                    "40000000-0000-4000-8000-000000000000",
                    Some(Value::Null),
                ),
            );
            assert_eq!(denied["error"]["code"], "target_not_found", "{denied}");
        }
        assert_eq!(counts(&f), before);
        f.finish(&f.original);
    }
    #[test]
    fn launch_guard_prepared_hook_is_one_shot_and_scoped() {
        let f = Fixture::new();
        let called = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let c = called.clone();
        let guard = f
            .harness
            .use_hook_for_next_prepared_spawn(Arc::new(move |_| {
                c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }));
        drop(guard);
        f.stop_clean(&f.original);
        let result = owner(
            &f.harness,
            "shell.launch",
            None,
            params("shell", &f.pane, Some(json!(f.original))),
        );
        assert_eq!(result["accepted"], true, "{result}");
        assert_eq!(called.load(std::sync::atomic::Ordering::SeqCst), 0);
        let run = result["result"]["data"]["run_id"].as_str().unwrap().to_owned();
        f.stop_clean(&run);
        let second = called.clone();
        let consumed = f.harness.use_hook_for_next_prepared_spawn(Arc::new(move |_| {
            second.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }));
        let result = owner(&f.harness, "shell.launch", None, params("shell", &f.pane, Some(json!(run))));
        assert_eq!(result["accepted"], true, "{result}");
        let run = result["result"]["data"]["run_id"].as_str().unwrap().to_owned();
        assert_eq!(called.load(std::sync::atomic::Ordering::SeqCst), 1);
        f.stop_clean(&run);
        let third = called.clone();
        let replacement = f.harness.use_hook_for_next_prepared_spawn(Arc::new(move |_| {
            third.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }));
        drop(consumed); // A consumed guard cannot cancel a separately armed hook.
        let result = owner(&f.harness, "shell.launch", None, params("shell", &f.pane, Some(json!(run))));
        assert_eq!(result["accepted"], true, "{result}");
        assert_eq!(called.load(std::sync::atomic::Ordering::SeqCst), 2);
        drop(replacement);
        let run = result["result"]["data"]["run_id"].as_str().unwrap();
        f.finish(run);
    }
    #[test]
    #[ignore = "requires installed official Codex CLI and actual suspended ConPTY processes"]
    fn launch_guard_official_codex_positive_replay_and_swap() {
        positive_and_swap("codex");
    }
    #[test]
    #[ignore = "requires installed official Claude CLI and actual suspended ConPTY processes"]
    fn launch_guard_official_claude_positive_replay_and_swap() {
        positive_and_swap("claude");
    }
    #[test]
    #[ignore = "requires installed official Codex CLI and actual suspended ConPTY processes"]
    fn launch_guard_official_codex_prepared_legal_races() {
        prepared_races("codex");
    }
    #[test]
    #[ignore = "requires installed official Claude CLI and actual suspended ConPTY processes"]
    fn launch_guard_official_claude_prepared_legal_races() {
        prepared_races("claude");
    }
}
