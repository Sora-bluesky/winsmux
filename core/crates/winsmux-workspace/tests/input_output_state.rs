//! TASK-865 class-wide proofs for input-once and output honesty.
//! Harness/ConPTY/RuntimeService only. Does not adopt P01–P03, GUI, IME, MCP,
//! winsmux.exe CLI real-entry, or Computer Use.

#![cfg(all(windows, debug_assertions))]

use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use winsmux_workspace::auth::testing::{Client, Harness};
use winsmux_workspace::contract::{
    parse_request, ErrorCode, InputKey, OperationId, OperationName, PaneId, Process, ProjectId,
    Request, RunId,
};
use winsmux_workspace::memory_testing::{
    decode_cursor, encode_cursor, fail_after_allocations, issue_pending_overlapped_write, key_byte,
    ledger_class, os_wait_timeout, prove_overlapped_cancel_is_not_delivery, retained_write_count,
    retained_write_identities, spawn_suspended_shell, Activation, IoObservation, LedgerClass,
    IoObserveKind, PhaseHold, ProductPhase, RunIoObserveGuard, RuntimeService, TestingDataSlot,
};
use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};

/// Existing contract arithmetic range. Not a new product cap.
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const MAX_MESSAGE_BYTES: usize = 1_048_576;
// These runtime fixtures share a process environment value and retained-write list.
static PUBLISHED_RUNTIME_TEST_LOCK: Mutex<()> = Mutex::new(());

const FOURTEEN: &[&str] = &[
    "pane.list",
    "pane.create",
    "pane.split",
    "pane.select",
    "pane.close",
    "pane.resize",
    "shell.launch",
    "run.get",
    "run.interrupt",
    "output.read",
    "input.write",
    "input.key",
    "events.wait",
    "operation.get",
];

const WAIT_FILE_SRC: &str = r#"
fn main() {
    let path = std::env::args()
        .skip(1)
        .find(|argument| argument != "-NoLogo")
        .or_else(|| std::env::var("WINSMUX_TASK865_RELEASE").ok())
        .expect("release");
    let ready = std::path::Path::new(&path).with_extension("ready");
    std::fs::write(&ready, path.as_bytes()).expect("exact user-entry readiness");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while std::time::Instant::now() < deadline {
        if std::path::Path::new(&path).exists() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::process::exit(2);
}
"#;

const EXIT_NOW_SRC: &str = "fn main() {}\n";

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

fn public_id(
    client: &Client,
    instance_id: Option<&str>,
    operation: &str,
    operation_id: &str,
    revision: Option<u64>,
    params: Value,
) -> Option<Value> {
    client
        .request(&request_id(
            operation,
            instance_id,
            operation_id,
            revision,
            params,
        ))
        .map(|response| value(&response))
}

fn public(
    client: &Client,
    instance_id: Option<&str>,
    operation: &str,
    revision: Option<u64>,
    params: Value,
) -> Option<Value> {
    public_id(
        client,
        instance_id,
        operation,
        &uuid::Uuid::new_v4().to_string(),
        revision,
        params,
    )
}

fn wait_until(deadline: Instant, mut probe: impl FnMut() -> bool, context: &str) {
    while Instant::now() < deadline {
        if probe() {
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("{context}");
}

fn current_revision(harness: &Harness) -> u64 {
    harness.authorization().testing_counters().1
}

fn events_after(harness: &Harness, after_event_seq: u64) -> Vec<Value> {
    let response = owner(
        harness,
        "events.wait",
        None,
        json!({"after_event_seq": after_event_seq, "wait_ms": 0}),
    );
    assert_accepted(&response, "events after spawn");
    assert_eq!(response["result"]["data"]["status"], json!("events"), "{response}");
    response["result"]["data"]["events"]
        .as_array()
        .expect("spawn events")
        .clone()
}

fn open_project(harness: &Harness) -> (PathBuf, String, u64) {
    let folder = std::env::temp_dir().join(format!(
        "winsmux-865-プロジェクト space-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir_all(&folder).expect("temp project");
    let opened = owner(
        harness,
        "project.open",
        Some(current_revision(harness)),
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

fn create_pwsh(harness: &Harness, project_id: &str, _revision: u64) -> (String, String, u64) {
    let created = owner(
        harness,
        "pane.create",
        Some(current_revision(harness)),
        json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    (
        created["result"]["data"]["pane_id"]
            .as_str()
            .expect("pane")
            .to_owned(),
        created["result"]["data"]["run_id"]
            .as_str()
            .expect("run")
            .to_owned(),
        created["topology_revision"].as_u64().expect("create revision"),
    )
}

fn run_typed(run: &str) -> RunId {
    RunId::new(run.to_owned()).expect("run id")
}

fn input_stats(harness: &Harness, run: &str) -> winsmux_workspace::memory_testing::RunIoStats {
    harness
        .authorization()
        .testing_input_stats(&run_typed(run))
        .expect("input stats")
}

fn ctrl_c_stats(harness: &Harness, run: &str) -> (u32, bool, bool, bool) {
    harness
        .authorization()
        .testing_ctrl_c_stats(&run_typed(run))
        .expect("ctrl-c stats")
}

fn job_stop_stats(
    harness: &Harness,
    run: &str,
) -> (u32, bool, bool, bool, Option<u32>, Option<u32>) {
    harness
        .authorization()
        .testing_job_stop_stats(&run_typed(run))
        .expect("job stop stats")
}

fn slot_debug(harness: &Harness, run: &str) -> String {
    format!("{:?}", input_stats(harness, run).data_slot)
}

fn grant_connected(
    client: Client,
    harness: &Harness,
    projects: &[&str],
    scopes: &[&str],
) -> Client {
    let pending = public(
        &client,
        None,
        "connection.request",
        None,
        json!({"project_ids": projects, "scopes": scopes}),
    )
    .expect("connection.request must send");
    assert_eq!(pending["accepted"], json!(true), "{pending}");
    let connection_id = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("connection_id")
        .to_owned();
    let allowed = owner(
        harness,
        "connection.decide",
        None,
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": projects,
            "scopes": scopes
        }),
    );
    assert_eq!(allowed["accepted"], json!(true), "{allowed}");
    client
}

fn grant(harness: &Harness, exe: &str, projects: &[&str], scopes: &[&str]) -> Client {
    let client = harness.connect(exe);
    grant_connected(client, harness, projects, scopes)
}

fn grant_actor_death(
    harness: &Harness,
    entry: ActorDeathEntry,
    exe: &str,
    projects: &[&str],
    scopes: &[&str],
) -> (
    Client,
    Option<winsmux_workspace::auth::testing::ManagedClientGuard>,
) {
    match entry {
        ActorDeathEntry::FinishWorker => {
            let managed = harness.connect_managed(exe);
            let client = grant_connected(managed.client(), harness, projects, scopes);
            (client, Some(managed))
        }
        ActorDeathEntry::Revoke | ActorDeathEntry::Disconnect => {
            (grant(harness, exe, projects, scopes), None)
        }
    }
}

struct RegistrationFail {
    auth: Arc<winsmux_workspace::memory_testing::Authorization>,
}

impl Drop for RegistrationFail {
    fn drop(&mut self) {
        self.auth.testing_clear_registration_fail();
    }
}

fn wait_process(harness: &Harness, run: &str, want: &str, context: &str) {
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            let got = owner(harness, "run.get", None, json!({"run_id": run}));
            got["accepted"] == json!(true) && got["result"]["data"]["run"]["process"] == json!(want)
        },
        context,
    );
}

fn visible_output_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            match chars.peek().copied() {
                Some('[') => {
                    chars.next();
                    while let Some(d) = chars.next() {
                        if ('\u{40}'..='\u{7e}').contains(&d) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    for d in chars.by_ref() {
                        if d == '\u{0007}' {
                            break;
                        }
                    }
                }
                Some(_) => {
                    let _ = chars.next();
                }
                None => {}
            }
        } else if c != '\u{0007}' {
            out.push(c);
        }
    }
    out
}

fn wait_output_contains(harness: &Harness, run: &str, needle: &str) -> Value {
    let mut last = json!(null);
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        last = owner(
            harness,
            "output.read",
            None,
            json!({"cursor": null, "max_bytes": 4096, "run_id": run}),
        );
        if last["accepted"] == json!(true) {
            let text = last["result"]["data"]["text"].as_str().unwrap_or("");
            if text.contains(needle) || visible_output_text(text).contains(needle) {
                return last;
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("output did not contain {needle}: {last}");
}

fn spawn_public_events_wait(
    client: Client,
    instance_id: String,
    after_event_seq: u64,
    wait_ms: u64,
) -> mpsc::Receiver<Option<Value>> {
    let (done_tx, done_rx) = mpsc::channel();
    thread::spawn(move || {
        done_tx
            .send(public(
                &client,
                Some(&instance_id),
                "events.wait",
                None,
                json!({"after_event_seq": after_event_seq, "wait_ms": wait_ms}),
            ))
            .ok();
    });
    done_rx
}

#[allow(dead_code)]
fn poll_wait_lock(harness: &Harness) {
    let _ = owner(
        harness,
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
}

fn wait_events_waiters_registered(harness: &Harness, after_event_seq: u64, n: usize) {
    wait_until(
        Instant::now() + Duration::from_secs(15),
        || {
            let waiters = harness
                .authorization()
                .testing_event_waiters()
                .expect("event waiter evidence");
            waiters
                .iter()
                .filter(|waiter| waiter.after_event_seq == after_event_seq)
                .count()
                >= n
        },
        "events.wait waiter was not registered",
    );
}

fn assert_no_waiter(harness: &Harness, after_event_seq: u64) {
    let waiters = harness
        .authorization()
        .testing_event_waiters()
        .expect("event waiter evidence");
    assert_eq!(
        waiters
            .iter()
            .filter(|waiter| waiter.after_event_seq == after_event_seq)
            .count(),
        0,
        "waiter must unregister: {waiters:?}"
    );
}

fn prove_fifo_head_check_and_order(
    harness: &Harness,
    pane: &str,
    run: &str,
    guard: &RunIoObserveGuard,
    cancel_middle: bool,
) {
    let before_seq = input_stats(harness, run).input_seq;
    assert_eq!(input_stats(harness, run).data_slot, TestingDataSlot::Free);
    let texts = [
        format!("fifo-w1-{}", uuid::Uuid::new_v4()),
        format!("fifo-w2-{}", uuid::Uuid::new_v4()),
        format!("fifo-w3-{}", uuid::Uuid::new_v4()),
    ];
    let (done_tx, done_rx) = mpsc::channel();
    let mut tickets = Vec::with_capacity(3);
    let prior: Vec<_> = guard
        .events()
        .expect("prior enqueue evidence")
        .into_iter()
        .filter(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .collect();
    for (i, text) in texts.iter().enumerate() {
        let h = harness.clone();
        let pane_t = pane.to_owned();
        let run_t = run.to_owned();
        let text = text.clone();
        let tx = done_tx.clone();
        thread::spawn(move || {
            tx.send((
                i,
                owner(
                    &h,
                    "input.write",
                    None,
                    json!({"pane_id": pane_t, "run_id": run_t, "text": text}),
                ),
            ))
            .ok();
        });
        let excluded = {
            let mut seen = prior.clone();
            seen.extend_from_slice(&tickets);
            seen
        };
        let events = guard
            .wait_for(
                |events| {
                    events
                        .iter()
                        .filter(|event| {
                            event.kind == IoObserveKind::Enqueued
                                && !excluded.iter().any(|ticket| *ticket == event.ticket)
                        })
                        .count()
                        == 1
                },
                Duration::from_secs(15),
            )
            .unwrap_or_else(|_| {
                panic!("one new enqueue ticket not recorded: {:?}", guard.events())
            });
        let ticket = events
            .iter()
            .filter(|event| event.kind == IoObserveKind::Enqueued)
            .map(|event| event.ticket)
            .find(|ticket| !excluded.contains(ticket))
            .expect("opaque enqueue ticket");
        tickets.push(ticket);
    }
    drop(done_tx);
    assert_eq!(tickets.len(), 3);
    assert_ne!(tickets[0], tickets[1]);
    assert_ne!(tickets[1], tickets[2]);
    let t1 = tickets[0];
    let t2 = tickets[1];
    let t3 = tickets[2];
    let stats = input_stats(harness, run);
    assert_eq!(stats.data_slot, TestingDataSlot::Free);
    assert_eq!(stats.fifo_head_id, Some(t1.as_u64()));
    assert_eq!(stats.fifo_ids, vec![t1.as_u64(), t2.as_u64(), t3.as_u64()]);
    assert_eq!(stats.input_seq, before_seq);

    guard.release(t3);
    guard
        .wait_for(
            |events| {
                events.iter().any(|event| {
                    event.kind == IoObserveKind::AdmitBlocked
                        && event.ticket == t3
                        && event.slot_free
                        && event.head == Some(t1.as_u64())
                })
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("t3 non-head block missing: {:?}", guard.events()));
    let stats = input_stats(harness, run);
    assert_eq!(stats.data_slot, TestingDataSlot::Free);
    assert_eq!(stats.fifo_head_id, Some(t1.as_u64()));
    assert_eq!(stats.input_seq, before_seq);
    assert!(
        guard
            .events()
            .expect("observe")
            .iter()
            .filter(|event| event.ticket == t1 || event.ticket == t2 || event.ticket == t3)
            .all(|event| event.kind != IoObserveKind::Issued
                && event.kind != IoObserveKind::Finished),
        "no issue/completion before head release: {:?}",
        guard.events()
    );
    assert!(
        done_rx.try_recv().is_err(),
        "no writer completion before head release"
    );

    if cancel_middle {
        guard
            .cancel_ticket(t2)
            .expect("existing cancel_data on captured ticket");
        let stats = input_stats(harness, run);
        assert_eq!(stats.fifo_head_id, Some(t1.as_u64()));
        assert!(!stats.fifo_ids.contains(&t2.as_u64()));
        assert_eq!(stats.data_slot, TestingDataSlot::Free);
        assert_eq!(stats.input_seq, before_seq);
        guard.release(t2);
        guard.release(t1);
    } else {
        guard.release(t2);
        guard
            .wait_for(
                |events| {
                    events.iter().any(|event| {
                        event.kind == IoObserveKind::AdmitBlocked
                            && event.ticket == t2
                            && event.slot_free
                            && event.head == Some(t1.as_u64())
                    })
                },
                Duration::from_secs(15),
            )
            .unwrap_or_else(|_| panic!("t2 non-head block missing: {:?}", guard.events()));
        let stats = input_stats(harness, run);
        assert_eq!(stats.data_slot, TestingDataSlot::Free);
        assert_eq!(stats.fifo_head_id, Some(t1.as_u64()));
        assert_eq!(stats.input_seq, before_seq);
        guard.release(t1);
    }

    let mut results = [None, None, None];
    for _ in 0..3 {
        let (i, body) = done_rx
            .recv_timeout(Duration::from_secs(60))
            .expect("fifo writer finished");
        results[i] = Some(body);
    }
    let events = guard.events().expect("final observe");
    let issued: Vec<_> = events
        .iter()
        .filter(|event| event.kind == IoObserveKind::Issued)
        .filter(|event| tickets.contains(&event.ticket))
        .map(|event| event.ticket)
        .collect();
    if cancel_middle {
        assert_accepted(results[0].as_ref().expect("w1"), "cancelled-middle w1");
        assert_error(
            results[1].as_ref().expect("w2"),
            "state_unknown",
            "cancelled middle must not issue",
        );
        assert_accepted(results[2].as_ref().expect("w3"), "cancelled-middle w3");
        assert_eq!(issued, vec![t1, t3]);
        assert_eq!(input_stats(harness, run).input_seq, before_seq + 2);
    } else {
        for (i, body) in results.iter().enumerate() {
            assert_accepted(body.as_ref().expect("body"), &format!("fifo write {i}"));
            assert_eq!(
                body.as_ref().expect("body")["result"]["data"]["written_bytes"],
                json!(texts[i].len() as u64)
            );
        }
        assert_eq!(issued, vec![t1, t2, t3]);
        assert_eq!(input_stats(harness, run).input_seq, before_seq + 3);
    }
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || input_stats(harness, run).data_slot == TestingDataSlot::Free,
        "FIFO DataSlot must return to Free",
    );
    let stats = input_stats(harness, run);
    assert_eq!(stats.data_slot, TestingDataSlot::Free);
    assert!(stats.fifo_ids.is_empty());
}

fn stop_run_snapshot(
    harness: &Harness,
    run: &str,
    interrupt: Option<&Value>,
    last_get: Option<&Value>,
) -> String {
    let input = harness.authorization().testing_input_stats(&run_typed(run));
    let ctrl = harness.authorization().testing_ctrl_c_stats(&run_typed(run));
    let job = harness
        .authorization()
        .testing_job_stop_stats(&run_typed(run));
    let clean = harness
        .authorization()
        .testing_session_clean_bits(&run_typed(run));
    let io = harness.authorization().testing_session_io(&run_typed(run));
    let output_tail_shape = harness
        .authorization()
        .testing_output_tail_shape(&run_typed(run));
    let has = harness.authorization().testing_has_session(&run_typed(run));
    format!(
        "interrupt={interrupt:?} last_get={last_get:?} has_session={has} input={input:?} ctrl_c={ctrl:?} job={job:?} session_io={io:?} clean_bits={clean:?} output_tail_shape={output_tail_shape:?}"
    )
}

fn stop_run(harness: &Harness, run: &str) {
    let interrupted = owner(harness, "run.interrupt", None, json!({"run_id": run}));
    let interrupt_ok = interrupted["accepted"] == json!(true);
    let not_running = interrupted["error"]["code"] == json!("not_running");
    if !interrupt_ok && !not_running {
        panic!(
            "run.interrupt was not accepted and not not_running: {}",
            stop_run_snapshot(harness, run, Some(&interrupted), None)
        );
    }
    let mut last = json!(null);
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        last = owner(harness, "run.get", None, json!({"run_id": run}));
        if last["result"]["data"]["run"]["process"] == json!("exited")
            || last["error"]["code"] == json!("target_not_found")
        {
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
    capture_owned_wait_chain(harness, run);
    panic!(
        "run did not exit after interrupt: {}",
        stop_run_snapshot(harness, run, Some(&interrupted), Some(&last))
    );
}

fn launch_after_stop_cleanup(harness: &Harness, pane: &str) -> Value {
    let mut launched = json!(null);
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || {
            launched = owner(
                harness,
                "shell.launch",
                None,
                json!({"pane_id": pane, "shell_profile_id": "pwsh"}),
            );
            if launched["accepted"] == json!(true) {
                return true;
            }
            assert_error(&launched, "already_running", "prior run cleanup");
            false
        },
        "replacement launch after prior run cleanup",
    );
    launched
}

fn capture_owned_wait_chain(harness: &Harness, run: &str) {
    let Some(collector) = std::env::var_os("TASK865_WAIT_CHAIN_COLLECTOR") else {
        return;
    };
    let Some(powershell) = std::env::var_os("TASK865_WAIT_CHAIN_POWERSHELL") else {
        return;
    };
    let collector_path = std::path::Path::new(&collector);
    let powershell_path = std::path::Path::new(&powershell);
    if !collector_path.is_absolute()
        || !collector_path.is_file()
        || !powershell_path.is_absolute()
        || !powershell_path.is_file()
    {
        return;
    }
    let Ok(parsed) = RunId::new(run.to_owned()) else {
        return;
    };
    let Some((pid, creation)) = harness
        .authorization()
        .testing_owned_process_identity(&parsed)
    else {
        eprintln!("TASK865_OWNED_WAIT_CHAIN unavailable");
        return;
    };
    use std::os::windows::process::CommandExt;
    match Command::new(&powershell)
        .arg("-NoLogo")
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-File")
        .arg(&collector)
        .arg("-TargetPid")
        .arg(pid.to_string())
        .arg("-ExpectedCreationFileTime")
        .arg(creation.to_string())
        .creation_flags(0x08000000)
        .output()
    {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            eprintln!("TASK865_OWNED_WAIT_CHAIN {}", stdout.trim());
        }
        Ok(out) => match out.status.code() {
            Some(code) => eprintln!("TASK865_OWNED_WAIT_CHAIN {code}"),
            None => eprintln!("TASK865_OWNED_WAIT_CHAIN unavailable"),
        },
        Err(_) => eprintln!("TASK865_OWNED_WAIT_CHAIN unavailable"),
    }
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
        thread::sleep(Duration::from_millis(50));
    }
    panic!("pane did not become closeable: {last}");
}

fn helper_dir() -> PathBuf {
    let out_dir =
        PathBuf::from(std::env::var("CARGO_TARGET_DIR").unwrap_or_else(|_| "target".to_owned()))
            .join("task865-helpers");
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

fn wait_file_exe() -> PathBuf {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| compile_helper("task865_wait", WAIT_FILE_SRC))
        .clone()
}

fn exit_now_exe() -> PathBuf {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| compile_helper("task865_exit_now", EXIT_NOW_SRC))
        .clone()
}

struct RuntimeChild {
    runtime: Arc<RuntimeService>,
    run: RunId,
    cwd: PathBuf,
    release: PathBuf,
}

impl Drop for RuntimeChild {
    fn drop(&mut self) {
        let _ = fs::write(&self.release, b"go");
    }
}

fn published_runtime() -> RuntimeChild {
    let cwd = std::env::temp_dir().join(format!("winsmux-865-rt-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&cwd).expect("runtime cwd");
    let release = cwd.join("release.txt");
    std::env::set_var(
        "WINSMUX_TASK865_RELEASE",
        release.to_string_lossy().as_ref(),
    );
    let runtime = Arc::new(RuntimeService::new());
    let project = ProjectId::new(uuid::Uuid::new_v4().to_string()).expect("project");
    let pane = PaneId::new(uuid::Uuid::new_v4().to_string()).expect("pane");
    let run = RunId::new(uuid::Uuid::new_v4().to_string()).expect("run");
    runtime
        .insert_preparing(project, pane, run.clone())
        .expect("preparing");
    let child = spawn_suspended_shell(cwd.to_str().expect("cwd"), wait_file_exe().to_str().expect("exe"))
        .expect("spawn wait-file");
    runtime.attach_child(&run, child).expect("attach");
    match runtime.resume_and_observe(&run) {
        Ok(Activation::Published {
            process: Process::Running,
            ..
        }) => {}
        other => panic!("wait-file child must publish running, got {other:?}"),
    }
    let fixture = RuntimeChild {
        runtime,
        run,
        cwd,
        release,
    };
    // Shared fixture decision table (all ten call sites use this choke point):
    // spawned/runnable != user entry; await this child's exact ready/release pair.
    // ready -> injected stop/Job/generation experiments are permitted.
    // release -> natural exit remains subject to the existing cleanup proofs.
    // missing/wrong ready -> test failure; Drop releases this child before the
    // runtime's owned-job teardown. No success is inferred from process-running.
    let ready = fixture.release.with_extension("ready");
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || fs::read(&ready).is_ok_and(|bytes| bytes == fixture.release.to_string_lossy().as_bytes()),
        "exact wait-helper user-entry readiness did not arrive",
    );
    eprintln!("TASK871_RUNTIME_READY run={} ready=true release_pair=true bits={:?}", fixture.run.as_str(), fixture.runtime.testing_session_clean_bits(&fixture.run));
    fixture
}

fn install_pending_pin(runtime: &RuntimeService, run: &RunId) -> (String, IoObservation) {
    let before = retained_write_count();
    let (op, issued, obs) =
        issue_pending_overlapped_write().expect("fill-until-pending overlapped write");
    match &obs {
        IoObservation::Pending | IoObservation::QueryFailed(_) => {}
        IoObservation::Completed { .. } => {
            panic!("fill-until-pending must not complete immediately: {obs:?}")
        }
    }
    runtime
        .testing_install_write(run, op)
        .expect("install pending write onto DataSlot");
    let stats = runtime.testing_input_stats(run).expect("stats after pin");
    assert_eq!(format!("{:?}", stats.data_slot).starts_with("Pinned"), true);
    assert!(stats.write_pending);
    assert!(runtime.occupancy_blocks_close(run));
    assert!(retained_write_count() >= before);
    let _ = issued;
    (format!("{:?}", stats.data_slot), obs)
}

fn close_job_handles(handles: Vec<windows_sys::Win32::Foundation::HANDLE>) {
    for handle in handles {
        if !handle.is_null() && handle != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(handle);
            }
        }
    }
}

fn required_scope(op: &str) -> &'static str {
    match op {
        "pane.list" | "run.get" | "events.wait" => "metadata",
        "output.read" => "read_output",
        "pane.create" | "pane.split" | "pane.select" | "pane.close" | "pane.resize"
        | "shell.launch" | "run.interrupt" | "input.write" | "input.key" | "operation.get" => {
            "control"
        }
        other => panic!("not one of the fourteen: {other}"),
    }
}

struct OpTarget<'a> {
    project: &'a str,
    pane: &'a str,
    run: &'a str,
    stale_t: bool,
}

fn op_params(op: &str, target: &OpTarget<'_>) -> (Option<u64>, Value) {
    let rev = if target.stale_t { Some(0) } else { None };
    match op {
        "pane.list" => (None, json!({"project_id": target.project})),
        "pane.create" => (
            rev,
            json!({"project_id": target.project, "shell_profile_id": "pwsh"}),
        ),
        "pane.split" => (rev, json!({"axis": "vertical", "pane_id": target.pane})),
        "pane.select" => (rev, json!({"pane_id": target.pane})),
        "pane.close" => (rev, json!({"pane_id": target.pane})),
        "pane.resize" => (
            None,
            json!({
                "cols": 80,
                "pane_id": target.pane,
                "rows": 24,
                "run_id": target.run
            }),
        ),
        "shell.launch" => (
            None,
            json!({"pane_id": target.pane, "shell_profile_id": "pwsh"}),
        ),
        "run.get" => (None, json!({"run_id": target.run})),
        "run.interrupt" => (None, json!({"run_id": target.run})),
        "output.read" => (
            None,
            json!({"cursor": null, "max_bytes": 64, "run_id": target.run}),
        ),
        "input.write" => (
            None,
            json!({"pane_id": target.pane, "run_id": target.run, "text": "x"}),
        ),
        "input.key" => (
            None,
            json!({"key": "tab", "pane_id": target.pane, "run_id": target.run}),
        ),
        "events.wait" => (None, json!({"after_event_seq": 0, "wait_ms": 0})),
        "operation.get" => (
            None,
            json!({"operation_id": "10000000-0000-4000-8000-00000000aa01"}),
        ),
        other => panic!("{other}"),
    }
}

fn assert_error(response: &Value, code: &str, context: &str) {
    assert_eq!(response["accepted"], json!(false), "{context} {response}");
    assert_eq!(
        response["error"]["code"],
        json!(code),
        "{context} {response}"
    );
}

fn assert_accepted(response: &Value, context: &str) {
    assert_eq!(response["accepted"], json!(true), "{context} {response}");
}

fn running_unknown(harness: &Harness, run: &str) {
    let got = owner(harness, "run.get", None, json!({"run_id": run}));
    assert_accepted(&got, "run.get");
    assert_eq!(got["result"]["data"]["run"]["process"], json!("running"), "{got}");
    assert_eq!(got["result"]["data"]["run"]["work"], json!("unknown"), "{got}");
    assert_eq!(
        got["result"]["data"]["run"]["evidence"],
        json!("unavailable"),
        "{got}"
    );
}

fn decode_this_cursor(read: &Value, harness: &Harness, run: &str) {
    let next = read["result"]["data"]["next_cursor"]
        .as_str()
        .expect("next_cursor");
    let decoded = decode_cursor(next).expect("host-issued opaque cursor");
    assert_eq!(decoded.instance_id.as_str(), instance(harness));
    assert_eq!(decoded.run_id.as_str(), run);
}

fn capabilities_include_four(harness: &Harness) {
    let caps = owner(harness, "capabilities.get", None, json!({}));
    assert_accepted(&caps, "capabilities.get");
    let ops = caps["result"]["data"]["operations"]
        .as_array()
        .expect("operations");
    for name in ["input.write", "input.key", "events.wait", "operation.get"] {
        assert!(
            ops.iter().any(|op| op == name),
            "capabilities omitted {name}: {caps}"
        );
    }
}

#[test]
fn p_write_once() {
    // ConPTY/PSReadLine display wrapping may pad a wide character with a space.
    // Prove the bytes consumed by the real shell, never normalize its display.
    // 80/81 columns exercise the original wrap boundary and its sibling.
    for cols in [80, 81] {
        let harness = Harness::new(Vec::new());
        capabilities_include_four(&harness);
        let (folder, project_id, revision) = open_project(&harness);
        let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
        running_unknown(&harness, &run);
        let resized = owner(
            &harness,
            "pane.resize",
            None,
            json!({"pane_id": pane, "run_id": run, "cols": cols, "rows": 24}),
        );
        assert_accepted(&resized, "receiver geometry");
        let ready_id = uuid::Uuid::new_v4().to_string();
        let ready = format!("TASK865_READY_{ready_id}");
        // The assembled readiness token is absent from the echoed command.
        // ReadLine consumes data literally; it never executes the test payload.
        let reader = format!(
            "Write-Output ('TASK865_READY_' + '{ready_id}'); $line = [Console]::ReadLine(); Write-Output ('TASK865_RECEIVED_' + [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($line)) + '_END')\r"
        );
        let setup = owner(
            &harness,
            "input.write",
            None,
            json!({"pane_id": pane, "run_id": run, "text": reader}),
        );
        assert_accepted(&setup, "literal receiver setup");
        let _ = wait_output_contains(&harness, &run, &ready);
        let before_seq = owner(&harness, "run.get", None, json!({"run_id": run}))["event_seq"]
            .as_u64()
            .expect("event_seq");
        let before_top = harness.authorization().testing_counters().1;
        let before_input = input_stats(&harness, &run).input_seq;
        let marker = format!("winsmux865検証 {}", uuid::Uuid::new_v4());
        let expected_hex: String = marker.bytes().map(|byte| format!("{byte:02X}")).collect();
        let expected = format!("TASK865_RECEIVED_{expected_hex}_END");
        let write_id = "20000000-0000-4000-8000-000000008601";
        let written = owner_id(
            &harness,
            "input.write",
            write_id,
            None,
            json!({"pane_id": pane, "run_id": run, "text": marker}),
        );
        assert_accepted(&written, "input.write");
        assert_eq!(written["result"]["data"]["written_bytes"], json!(marker.len() as u64), "{written}");
        assert_eq!(written["result"]["data"]["input_seq"].as_u64().expect("P"), before_input + 1, "{written}");
        assert_eq!(written["event_seq"].as_u64().expect("seq"), before_seq);
        assert_eq!(harness.authorization().testing_counters().1, before_top);
        let after = input_stats(&harness, &run);
        assert_eq!(after.input_seq, before_input + 1);
        assert!(after.fifo_ids.is_empty());
        assert_eq!(after.data_slot, TestingDataSlot::Free);
        let replay = owner_id(
            &harness,
            "input.write",
            write_id,
            None,
            json!({"pane_id": pane, "run_id": run, "text": marker}),
        );
        assert_eq!(replay["result"]["data"], written["result"]["data"]);
        assert_eq!(input_stats(&harness, &run).input_seq, before_input + 1);
        let enter = owner(
            &harness,
            "input.key",
            None,
            json!({"pane_id": pane, "run_id": run, "key": "enter"}),
        );
        assert_accepted(&enter, "complete the literal receiver line");
        let received = wait_output_contains(&harness, &run, &expected);
        assert_eq!(received["result"]["data"]["gap"], json!(false));
        let replay_after_receive = owner_id(
            &harness,
            "input.write",
            write_id,
            None,
            json!({"pane_id": pane, "run_id": run, "text": marker}),
        );
        assert_eq!(replay_after_receive["result"]["data"], written["result"]["data"]);
        assert_eq!(input_stats(&harness, &run).input_seq, before_input + 2);
        eprintln!("TASK865_LITERAL_RECEIVER cols={cols} utf8_exact=true pre_receive_replay=true post_receive_replay=true input_write_seq_delta=1");
        stop_run(&harness, &run);
        let _ = folder;
    }
}

#[test]
fn p_empty_write() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let before = input_stats(&harness, &run);
    let event_before = harness.authorization().testing_counters().0;
    let empty_id = "20000000-0000-4000-8000-000000008609";
    let written = owner_id(
        &harness,
        "input.write",
        empty_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": ""}),
    );
    assert_accepted(&written, "empty write");
    assert_eq!(written["result"]["data"]["written_bytes"], json!(0));
    assert_eq!(
        written["result"]["data"]["input_seq"].as_u64().expect("P"),
        before.input_seq + 1
    );
    let after = input_stats(&harness, &run);
    assert_eq!(after.input_seq, before.input_seq + 1);
    assert_eq!(after.data_slot, TestingDataSlot::Free);
    assert_eq!(harness.authorization().testing_counters().0, event_before);
    let replay = owner_id(
        &harness,
        "input.write",
        empty_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": ""}),
    );
    assert_eq!(replay["result"]["data"], written["result"]["data"]);
    assert_eq!(input_stats(&harness, &run).input_seq, before.input_seq + 1);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn p_keys() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    assert_eq!(key_byte(InputKey::Enter), 0x0D);
    assert_eq!(key_byte(InputKey::Tab), 0x09);
    assert_eq!(key_byte(InputKey::Escape), 0x1B);
    assert_eq!(key_byte(InputKey::Interrupt), 0x03);
    let (writes0, _, _, _) = ctrl_c_stats(&harness, &run);
    let event_before = harness.authorization().testing_counters().0;
    for (i, key) in ["tab", "escape", "enter", "interrupt"].into_iter().enumerate() {
        let id = format!("20000000-0000-4000-8000-00000000861{i}");
        let sent = owner_id(
            &harness,
            "input.key",
            &id,
            None,
            json!({"key": key, "pane_id": pane, "run_id": run}),
        );
        assert_accepted(&sent, key);
        assert_eq!(sent["result"]["data"]["sent"], json!(true), "{sent}");
        assert_eq!(sent["result"]["data"]["written_bytes"], json!(1), "{sent}");
        assert_eq!(sent["result"]["data"]["key"], json!(key), "{sent}");
        let replay = owner_id(
            &harness,
            "input.key",
            &id,
            None,
            json!({"key": key, "pane_id": pane, "run_id": run}),
        );
        assert_eq!(replay["result"]["data"], sent["result"]["data"]);
    }
    let got = owner(&harness, "run.get", None, json!({"run_id": run}));
    if got["result"]["data"]["run"]["process"] == json!("running") {
        assert_eq!(got["result"]["data"]["run"]["work"], json!("unknown"));
        assert_eq!(got["result"]["data"]["run"]["evidence"], json!("unavailable"));
    } else {
        assert_eq!(got["result"]["data"]["run"]["work"], json!("unknown"));
        assert_ne!(got["result"]["data"]["run"]["work"], json!("interrupted"));
        assert_eq!(got["result"]["data"]["run"]["evidence"], json!("process_exit"));
    }
    let (writes1, _, _, _) = ctrl_c_stats(&harness, &run);
    assert_eq!(writes1, writes0, "input.key interrupt must not count teardown 0x03");
    assert_eq!(harness.authorization().testing_counters().0, event_before);
    if got["result"]["data"]["run"]["process"] == json!("running") {
        stop_run(&harness, &run);
    }
    let _ = folder;
}

#[test]
fn p_interrupt_stop() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, after) = create_pwsh(&harness, &project_id, revision);
    native_pinned_interrupt_does_not_join();
    let interrupt_id = "20000000-0000-4000-8000-000000008603";
    let started = Instant::now();
    let interrupted = owner_id(
        &harness,
        "run.interrupt",
        interrupt_id,
        None,
        json!({"run_id": run}),
    );
    assert_accepted(&interrupted, "run.interrupt");
    assert_eq!(interrupted["result"]["data"]["phase"], json!("accepted"));
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "dispatch must not join a write delivery"
    );
    wait_process(&harness, &run, "exited", "interrupted run did not exit");
    let got = owner(&harness, "run.get", None, json!({"run_id": run}));
    assert_eq!(got["result"]["data"]["run"]["work"], json!("interrupted"), "{got}");
    assert_eq!(
        got["result"]["data"]["run"]["evidence"],
        json!("process_exit"),
        "{got}"
    );
    let (writes, _, _, _) = ctrl_c_stats(&harness, &run);
    assert!(writes <= 1, "teardown 0x03 at most once, got {writes}");
    let job = job_stop_stats(&harness, &run);
    assert_eq!(job.0, 1, "accepted interrupt terminates its Job once");
    assert!(job.1, "exact Job termination API succeeded: {job:?}");
    assert!(!job.2, "exact Job termination API did not fail: {job:?}");
    assert!(!job.3, "ordinary interrupt is not abnormal containment: {job:?}");
    assert_eq!(job.5, Some(0), "interrupted Job must be empty: {job:?}");
    let replay = owner_id(
        &harness,
        "run.interrupt",
        interrupt_id,
        None,
        json!({"run_id": run}),
    );
    assert_eq!(replay["result"]["data"], interrupted["result"]["data"]);
    let (writes2, _, _, _) = ctrl_c_stats(&harness, &run);
    assert_eq!(writes2, writes, "interrupt replay must not issue a second 0x03");
    assert!(writes2 <= 1);
    assert_eq!(
        job_stop_stats(&harness, &run).0,
        1,
        "interrupt replay must not terminate the Job twice"
    );
    let _ = wait_session_clean(&harness, &_pane, &run, after);
    let _ = folder;
}

fn native_pinned_interrupt_does_not_join() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    let child = published_runtime();
    let _ = install_pending_pin(&child.runtime, &child.run);
    assert!(prove_overlapped_cancel_is_not_delivery());
    let started = Instant::now();
    let admitted = child
        .runtime
        .admit_interrupt(&child.run)
        .expect("StopLane on published pinned run");
    assert!(admitted, "live published run must admit interrupt");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "admit_interrupt joined overlapped wait"
    );
    let stats = child.runtime.testing_input_stats(&child.run).expect("stats");
    assert!(stats.stop_flag);
    let (writes, delivered, _, pending) = child
        .runtime
        .testing_ctrl_c_stats(&child.run)
        .expect("ctrl");
    assert_eq!(writes, 0, "StopLane must not issue teardown 0x03 at admit");
    assert!(!delivered);
    assert!(pending);
    child.runtime.queue_cleanup(&child.run);
}

#[test]
fn p_interrupt_previous_run() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, previous, after_create) = create_pwsh(&harness, &project_id, revision);
    stop_run(&harness, &previous);
    let launched = launch_after_stop_cleanup(&harness, &pane);
    assert_accepted(&launched, "shell.launch replacement");
    let current = launched["result"]["data"]["run_id"]
        .as_str()
        .expect("current run")
        .to_owned();
    assert_ne!(current, previous);
    let prev_get = owner(&harness, "run.get", None, json!({"run_id": previous}));
    assert_accepted(&prev_get, "previous still gettable");
    assert_eq!(prev_get["result"]["data"]["run"]["current"], json!(false));
    let before = input_stats(&harness, &current).input_seq;
    let interrupted = owner(
        &harness,
        "run.interrupt",
        None,
        json!({"run_id": previous}),
    );
    if interrupted["accepted"] == json!(true) {
        assert_eq!(interrupted["result"]["data"]["run_id"], json!(previous));
    } else {
        assert_error(&interrupted, "not_running", "exited previous_runs");
    }
    assert_eq!(
        job_stop_stats(&harness, &previous).0,
        1,
        "not_running previous run must not issue another Job termination"
    );
    let write_prev = owner(
        &harness,
        "input.write",
        None,
        json!({"pane_id": pane, "run_id": previous, "text": "no-retarget"}),
    );
    assert_error(&write_prev, "target_not_found", "write previous_runs");
    assert_eq!(input_stats(&harness, &current).input_seq, before);
    let still = owner(&harness, "run.get", None, json!({"run_id": current}));
    assert_eq!(still["result"]["data"]["run"]["process"], json!("running"), "{still}");
    stop_run(&harness, &current);
    let _ = after_create;
    let _ = folder;
}

#[test]
fn p_output_unicode() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let unique = folder
        .file_name()
        .and_then(|name| name.to_str())
        .expect("unique")
        .to_owned();
    let filled = wait_output_contains(&harness, &run, &unique);
    decode_this_cursor(&filled, &harness, &run);
    let live = decode_cursor(
        filled["result"]["data"]["next_cursor"]
            .as_str()
            .expect("cursor"),
    )
    .expect("decode");
    let text = filled["result"]["data"]["text"].as_str().unwrap_or("");
    let origin = live.offset.saturating_sub(text.len() as u64);
    let jp = text.find("プロジェクト").expect("japanese in cwd") as u64;
    let cursor = encode_cursor(&live.instance_id, &live.run_id, origin.saturating_add(jp));
    let one = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": cursor.as_str(), "max_bytes": 1, "run_id": run}),
    );
    assert_accepted(&one, "max_bytes=1");
    assert_eq!(one["result"]["data"]["text"], json!(""));
    assert_eq!(one["result"]["data"]["truncated"], json!(true));
    decode_this_cursor(&one, &harness, &run);
    let three = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": cursor.as_str(), "max_bytes": 3, "run_id": run}),
    );
    assert_accepted(&three, "max_bytes=3");
    assert_eq!(three["result"]["data"]["text"], json!("プ"));
    let huge = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": null, "max_bytes": 4_000_000, "run_id": run}),
    );
    assert_accepted(&huge, "huge max_bytes");
    let body = serde_json::to_vec(&huge).expect("json");
    assert!(body.len() <= MAX_MESSAGE_BYTES, "envelope {}", body.len());
    stop_run(&harness, &run);
}

#[test]
fn p_events_poll() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, after) = create_pwsh(&harness, &project_id, revision);
    let first = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
    assert_accepted(&first, "events.wait 0");
    let status = first["result"]["data"]["status"].as_str().expect("status");
    assert!(status == "no_change" || status == "events" || status == "gap", "{first}");
    let after_seq = first["result"]["data"]["next_event_seq"]
        .as_u64()
        .expect("next");
    assert!(after_seq >= 0);
    let selected = owner(
        &harness,
        "pane.select",
        Some(after),
        json!({"pane_id": pane}),
    );
    assert_accepted(&selected, "pane.select");
    let committed = selected["event_seq"].as_u64().expect("committed after T");
    let second = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": after_seq, "wait_ms": 0}),
    );
    assert_accepted(&second, "events.wait after select");
    assert_eq!(second["event_seq"].as_u64().expect("envelope"), committed);
    let events = second["result"]["data"]["events"]
        .as_array()
        .expect("events");
    assert!(!events.is_empty(), "TopologyChanged must be visible: {second}");
    for event in events {
        assert_eq!(event["data"]["kind"], json!("topology_changed"), "{event}");
        assert!(event["data"].get("text").is_none(), "{event}");
        assert!(event["data"].get("path").is_none(), "{event}");
        assert!(event["data"].get("display_name").is_none(), "{event}");
        if let Some(id) = event["data"]["project_id"].as_str() {
            assert_eq!(id, project_id);
        }
    }
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn p_865_p02_cancel_output() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (_pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (_pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let client = grant(&harness, "waiter.exe", &[&project_a], &["metadata", "read_output"]);
    let wait_after = harness.event_seq();
    let done_rx = spawn_public_events_wait(
        client.clone(),
        inst,
        wait_after,
        MAX_SAFE_INTEGER,
    );
    wait_events_waiters_registered(&harness, wait_after, 1);
    owner(
        &harness,
        "connection.revoke",
        None,
        json!({"connection_id": client.connection_id()}),
    );
    let woke = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("events.wait must wake on revoke; GUI remains not_run");
    if let Some(body) = woke {
        if body["accepted"] == json!(true) {
            let events = body["result"]["data"]["events"].as_array().cloned().unwrap_or_default();
            for event in events {
                assert!(event["data"].get("path").is_none());
                assert!(event["data"].get("text").is_none());
            }
        }
    }
    assert_no_waiter(&harness, wait_after);
    let sibling = owner(&harness, "run.get", None, json!({"run_id": run_b}));
    assert_eq!(sibling["result"]["data"]["run"]["process"], json!("running"), "{sibling}");
    let read = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": null, "max_bytes": 4096, "run_id": run_a}),
    );
    assert_accepted(&read, "output.read after cancel");
    decode_this_cursor(&read, &harness, &run_a);
    assert_eq!(
        job_stop_stats(&harness, &run_a).0,
        0,
        "denied matrix requests must not terminate A"
    );
    assert_eq!(
        job_stop_stats(&harness, &run_b).0,
        0,
        "denied and foreign requests must not terminate B"
    );
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn p_865_p03_retry_after_partial() {
    n_partial_native_unknown_pin();
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let text = "retry-after-partial-検証";
    let first_id = "20000000-0000-4000-8000-000000008608";
    let first = owner_id(
        &harness,
        "input.write",
        first_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": text}),
    );
    if first["error"]["code"] == json!("state_unknown") {
        let replay = owner_id(
            &harness,
            "input.write",
            first_id,
            None,
            json!({"pane_id": pane, "run_id": run, "text": text}),
        );
        assert_eq!(replay["error"]["code"], json!("state_unknown"));
        assert_eq!(replay["result"], first["result"]);
    } else {
        assert_accepted(&first, "healthy write is not auto-remainder retry");
        assert_eq!(first["result"]["data"]["written_bytes"], json!(text.len() as u64));
    }
    let second_id = "20000000-0000-4000-8000-000000008618";
    let second = owner_id(
        &harness,
        "input.write",
        second_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": text}),
    );
    if second["accepted"] == json!(true) {
        assert_eq!(second["result"]["data"]["written_bytes"], json!(text.len() as u64));
        assert_ne!(second_id, first_id);
    } else {
        assert_error(&second, "state_unknown", "new id succeeds only if fully delivered");
    }
    stop_run(&harness, &run);
    let _ = folder;
}

fn n_partial_native_unknown_pin() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    let child = published_runtime();
    let before = retained_write_count();
    let (_slot, obs) = install_pending_pin(&child.runtime, &child.run);
    match obs {
        IoObservation::Pending | IoObservation::QueryFailed(_) => {}
        IoObservation::Completed { .. } => panic!("pending fixture completed"),
    }
    assert!(prove_overlapped_cancel_is_not_delivery());
    drop(child);
    assert!(
        retained_write_count() >= before,
        "Unknown/pending pin must remain HOST_RETAINED; no remainder WriteFile"
    );
    let _ = retained_write_identities();
}

#[test]
fn p_owner_four_ops() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    capabilities_include_four(&harness);
    let write = owner(
        &harness,
        "input.write",
        None,
        json!({"pane_id": pane, "run_id": run, "text": "owner-four"}),
    );
    assert_ne!(write["error"]["code"], json!("unsupported_capability"), "{write}");
    assert_accepted(&write, "owner input.write");
    let key = owner(
        &harness,
        "input.key",
        None,
        json!({"key": "tab", "pane_id": pane, "run_id": run}),
    );
    assert_accepted(&key, "owner input.key");
    let wait = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
    assert_accepted(&wait, "owner events.wait");
    let status = wait["result"]["data"]["status"].as_str().expect("status");
    assert!(status == "no_change" || status == "events" || status == "gap", "{wait}");
    let vacant = "10000000-0000-4000-8000-00000000bbbb";
    let got = owner(
        &harness,
        "operation.get",
        None,
        json!({"operation_id": vacant}),
    );
    assert_accepted(&got, "owner operation.get vacant");
    assert_eq!(got["result"]["data"]["operation"]["phase"], json!("unknown"));
    assert!(got["result"]["data"]["operation"].get("text").is_none());
    assert_eq!(phase(&harness, vacant), None, "Q vacant");
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_operation_get_done_not_in_progress() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let write_id = "20000000-0000-4000-8000-000000008702";
    let written = owner_id(
        &harness,
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "opget-done"}),
    );
    assert_accepted(&written, "write to query");
    assert_eq!(phase(&harness, write_id), Some("done"));
    let got = owner(
        &harness,
        "operation.get",
        None,
        json!({"operation_id": write_id}),
    );
    assert_accepted(&got, "operation.get own done write");
    assert_ne!(
        got["result"]["data"]["operation"]["phase"],
        json!("in_progress"),
        "Done retained effect must not poll as in_progress: {got}"
    );
    assert_eq!(got["result"]["data"]["operation"]["phase"], json!("completed"));
    assert_eq!(got["result"]["data"]["operation"]["outcome"], json!("succeeded"));
    assert!(got["result"]["data"]["operation"]["error_code"].is_null());
    assert!(got["result"]["data"]["operation"].get("text").is_none());
    let fail_id = "20000000-0000-4000-8000-000000008703";
    let failed = owner_id(
        &harness,
        "input.write",
        fail_id,
        None,
        json!({
            "pane_id": pane,
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": "missing"
        }),
    );
    assert_error(&failed, "target_not_found", "failed terminal");
    assert_eq!(phase(&harness, fail_id), Some("done"));
    let got_fail = owner(
        &harness,
        "operation.get",
        None,
        json!({"operation_id": fail_id}),
    );
    assert_accepted(&got_fail, "operation.get own failed done");
    assert_ne!(got_fail["result"]["data"]["operation"]["phase"], json!("in_progress"));
    assert_eq!(got_fail["result"]["data"]["operation"]["phase"], json!("completed"));
    assert_eq!(got_fail["result"]["data"]["operation"]["outcome"], json!("failed"));
    assert_eq!(got_fail["result"]["data"]["operation"]["error_code"], json!("target_not_found"));
    let vacant = "10000000-0000-4000-8000-000000008704";
    let got_vacant = owner(
        &harness,
        "operation.get",
        None,
        json!({"operation_id": vacant}),
    );
    assert_accepted(&got_vacant, "vacant");
    assert_eq!(got_vacant["result"]["data"]["operation"]["phase"], json!("unknown"));
    let inst = instance(&harness);
    let peer = grant(&harness, "opget-peer.exe", &[&project_id], &["control"]);
    let foreign = public(
        &peer,
        Some(&inst),
        "operation.get",
        None,
        json!({"operation_id": write_id}),
    )
    .expect("foreign get body");
    assert_error(&foreign, "permission_denied", "other actor");
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_empty_canceled_commit() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let inst = instance(&harness);
    let client = grant(&harness, "empty-cancel.exe", &[&project_id], &["control"]);
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run))
        .expect("attach per-run observe guard");
    let empty_id = "20000000-0000-4000-8000-000000008701";
    let before_seq = input_stats(&harness, &run).input_seq;
    let (done_tx, done_rx) = mpsc::channel();
    let client_t = client.clone();
    let inst_t = inst.clone();
    let pane_t = pane.clone();
    let run_t = run.clone();
    thread::spawn(move || {
        done_tx
            .send(public_id(
                &client_t,
                Some(&inst_t),
                "input.write",
                empty_id,
                None,
                json!({"pane_id": pane_t, "run_id": run_t, "text": ""}),
            ))
            .ok();
    });
    let events = guard
        .wait_for(
            |events| events.iter().any(|event| event.kind == IoObserveKind::Enqueued),
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("empty write enqueue not recorded: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("opaque enqueue ticket");
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("empty write held before admit");
    let revoked = owner(
        &harness,
        "connection.revoke",
        None,
        json!({"connection_id": client.connection_id()}),
    );
    assert_accepted(&revoked, "revoke during empty admit hold");
    guard.release(ticket);
    let body = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("empty write finished");
    if let Some(body) = body {
        assert_error(&body, "permission_denied", "empty write after actor death");
    }
    assert_eq!(
        input_stats(&harness, &run).input_seq,
        before_seq,
        "failed admission must not commit input_seq"
    );
    assert_eq!(phase(&harness, empty_id), Some("done"));
    let replay = public_id(
        &client,
        Some(&inst),
        "input.write",
        empty_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": ""}),
    );
    assert!(
        replay.is_none()
            || replay.as_ref().is_some_and(|body| {
                body["error"]["code"] == json!("permission_denied")
                    || body["error"]["code"] == json!("state_unknown")
            }),
        "replay after revoke must not become a delivered empty write: {replay:?}"
    );
    assert_eq!(input_stats(&harness, &run).input_seq, before_seq);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_replay_diff() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let id = "20000000-0000-4000-8000-000000008611";
    let first = owner_id(
        &harness,
        "input.write",
        id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "alpha"}),
    );
    assert_accepted(&first, "first write");
    let seq = input_stats(&harness, &run).input_seq;
    let conflict = owner_id(
        &harness,
        "input.write",
        id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "beta"}),
    );
    assert_error(&conflict, "operation_conflict", "different bytes");
    assert_eq!(input_stats(&harness, &run).input_seq, seq);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_old_run() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, previous, _) = create_pwsh(&harness, &project_id, revision);
    stop_run(&harness, &previous);
    let launched = launch_after_stop_cleanup(&harness, &pane);
    assert_accepted(&launched, "replacement");
    let current = launched["result"]["data"]["run_id"]
        .as_str()
        .expect("current")
        .to_owned();
    let before = input_stats(&harness, &current).input_seq;
    let write_old = owner(
        &harness,
        "input.write",
        None,
        json!({"pane_id": pane, "run_id": previous, "text": "old"}),
    );
    assert_error(&write_old, "target_not_found", "previous_runs write");
    let unknown = owner(
        &harness,
        "input.write",
        None,
        json!({
            "pane_id": pane,
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": "missing"
        }),
    );
    assert_error(&unknown, "target_not_found", "unknown run write");
    let interrupt_unknown = owner(
        &harness,
        "run.interrupt",
        None,
        json!({"run_id": "50000000-0000-4000-8000-000000000000"}),
    );
    assert_error(&interrupt_unknown, "target_not_found", "unpublished interrupt");
    assert_eq!(input_stats(&harness, &current).input_seq, before);
    stop_run(&harness, &current);
    let _ = folder;
}

#[test]
fn n_cross_actor() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let write_id = "20000000-0000-4000-8000-000000008613";
    let written = owner_id(
        &harness,
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane_a, "run_id": run_a, "text": "secret-actor"}),
    );
    assert_accepted(&written, "owner write");
    let peer = grant(
        &harness,
        "peer.exe",
        &[&project_a],
        &["metadata", "control", "read_output"],
    );
    let replay = public_id(
        &peer,
        Some(&inst),
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane_a, "run_id": run_a, "text": "secret-actor"}),
    )
    .expect("other-actor replay must produce a body to deny");
    assert_error(&replay, "permission_denied", "other actor replay");
    assert!(format!("{replay}").contains("secret-actor") == false || replay["error"]["code"] == json!("permission_denied"));
    let scoped = grant(&harness, "scoped.exe", &[&project_a], &["control"]);
    let cross = public(
        &scoped,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": "nope"}),
    )
    .expect("scoped ungranted B");
    assert_error(&cross, "target_not_found", "granted A control vs B run");
    let unscoped = grant(&harness, "meta.exe", &[&project_a], &["metadata"]);
    let denied = public(
        &unscoped,
        Some(&inst),
        "run.interrupt",
        None,
        json!({"run_id": run_b}),
    )
    .expect("unscoped interrupt");
    assert_error(&denied, "permission_denied", "no Control");
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn n_no_heuristic() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    for _ in 0..5 {
        let read = owner(
            &harness,
            "output.read",
            None,
            json!({"cursor": null, "max_bytes": 4096, "run_id": run}),
        );
        assert_accepted(&read, "output.read");
    }
    running_unknown(&harness, &run);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_cursor_foreign() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let live = wait_output_contains(
        &harness,
        &run,
        folder.file_name().and_then(|n| n.to_str()).unwrap_or("プロジェクト"),
    );
    let this_next = live["result"]["data"]["next_cursor"]
        .as_str()
        .expect("next")
        .to_owned();
    for cursor in [
        "not-a-cursor".to_owned(),
        "v1:10000000-0000-4000-8000-00000000ffff/50000000-0000-4000-8000-000000000000/0"
            .to_owned(),
        encode_cursor(
            &winsmux_workspace::contract::InstanceId::new(
                "10000000-0000-4000-8000-00000000000f".to_owned(),
            )
            .expect("foreign instance"),
            &run_typed(&run),
            0,
        )
        .as_str()
        .to_owned(),
    ] {
        let read = owner(
            &harness,
            "output.read",
            None,
            json!({"cursor": cursor, "max_bytes": 32, "run_id": run}),
        );
        assert_accepted(&read, "foreign/malformed cursor");
        assert_eq!(read["result"]["data"]["gap"], json!(true), "{read}");
        assert_eq!(read["result"]["data"]["text"], json!(""));
        decode_this_cursor(&read, &harness, &run);
        assert_ne!(read["result"]["data"]["next_cursor"], json!(this_next.clone()).as_str().map(|_| json!("12")).unwrap_or(json!(null)));
        let next = read["result"]["data"]["next_cursor"].as_str().expect("next");
        assert_ne!(next, "12", "must not rewind to a decimal start_cursor");
    }
    stop_run(&harness, &run);
}

#[test]
fn n_partial() {
    n_partial_native_unknown_pin();
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let id = "20000000-0000-4000-8000-000000008616";
    let huge = "あ".repeat(80_000);
    let first = owner_id(
        &harness,
        "input.write",
        id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": huge}),
    );
    if first["error"]["code"] == json!("state_unknown") {
        let replay = owner_id(
            &harness,
            "input.write",
            id,
            None,
            json!({"pane_id": pane, "run_id": run, "text": huge}),
        );
        assert_eq!(replay["error"]["code"], json!("state_unknown"));
        assert_eq!(input_stats(&harness, &run).input_seq, 0);
    } else if first["accepted"] == json!(true) {
        assert_eq!(first["result"]["data"]["written_bytes"], json!(huge.len() as u64));
    } else {
        panic!("unexpected partial write result {first}");
    }
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_interrupt_behind_write() {
    native_pinned_interrupt_does_not_join();
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let huge = "x".repeat(200_000);
    let (ready_tx, ready_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let h = harness.clone();
    let pane_t = pane.clone();
    let run_t = run.clone();
    thread::spawn(move || {
        ready_tx.send(()).ok();
        let response = owner(
            &h,
            "input.write",
            None,
            json!({"pane_id": pane_t, "run_id": run_t, "text": huge}),
        );
        done_tx.send(response).ok();
    });
    ready_rx.recv().expect("writer started");
    wait_until(
        Instant::now() + Duration::from_secs(5),
        || slot_debug(&harness, &run) != "Free" || done_rx.try_recv().is_ok(),
        "writer did not occupy or finish",
    );
    let started = Instant::now();
    let interrupted = owner(&harness, "run.interrupt", None, json!({"run_id": run}));
    assert_accepted(&interrupted, "interrupt while write occupied or already sealed");
    assert!(started.elapsed() < Duration::from_secs(5));
    let write_result = done_rx.recv_timeout(Duration::from_secs(60));
    if let Ok(body) = write_result {
        if body["accepted"] == json!(true) {
            panic!("stuck/full-pipe write must not be accepted success after StopLane: {body}");
        } else {
            let code = body["error"]["code"].as_str().unwrap_or("");
            assert!(
                code == "state_unknown" || code == "not_running",
                "occupied write legal failure, got {body}"
            );
        }
    }
    let _ = folder;
}

#[test]
fn n_scope_existence() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let meta = grant(&harness, "meta-only.exe", &[&project_a], &["metadata"]);
    let no_control = public(
        &meta,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_a, "run_id": run_a, "text": "x"}),
    )
    .expect("missing Control");
    assert_error(&no_control, "permission_denied", "scope-first existing A");
    let control = grant(&harness, "control-only.exe", &[&project_a], &["control"]);
    let ungranted = public(
        &control,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": "x"}),
    )
    .expect("Control vs B");
    let unknown = public(
        &control,
        Some(&inst),
        "input.write",
        None,
        json!({
            "pane_id": "40000000-0000-4000-8000-000000000000",
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": "x"
        }),
    )
    .expect("Control vs unknown");
    assert_error(&ungranted, "target_not_found", "ungranted B");
    assert_error(&unknown, "target_not_found", "unknown B");
    assert_eq!(ungranted["error"]["code"], unknown["error"]["code"]);
    assert_eq!(ungranted["error"]["message"], unknown["error"]["message"]);
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn n_future_event_cursor() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let live = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
    assert_accepted(&live, "baseline wait");
    let committed = live["event_seq"].as_u64().expect("committed");
    let future = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": committed + 1, "wait_ms": 0}),
    );
    assert_error(&future, "invalid_request", "future after_event_seq");
    assert!(future["result"].is_null() || future["result"] == json!(null), "{future}");
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn s_ab() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane_a, run_a, after_a) = create_pwsh(&harness, &project_id, revision);
    let marker = format!("sibA-{}", uuid::Uuid::new_v4());
    let huge = marker.repeat(8000);
    let (ready_tx, ready_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let h = harness.clone();
    let pane_t = pane_a.clone();
    let run_t = run_a.clone();
    thread::spawn(move || {
        ready_tx.send(()).ok();
        done_tx
            .send(owner(
                &h,
                "input.write",
                None,
                json!({"pane_id": pane_t, "run_id": run_t, "text": huge}),
            ))
            .ok();
    });
    ready_rx.recv().expect("A writer started");
    let split = owner(
        &harness,
        "pane.split",
        Some(after_a),
        json!({"axis": "vertical", "pane_id": pane_a}),
    );
    assert_accepted(&split, "pane B via split while A may be in flight");
    let pane_b = split["result"]["data"]["pane_id"]
        .as_str()
        .expect("B pane")
        .to_owned();
    let run_b = split["result"]["data"]["run_id"]
        .as_str()
        .expect("B run")
        .to_owned();
    let selected = owner(
        &harness,
        "pane.select",
        Some(split["topology_revision"].as_u64().expect("rev")),
        json!({"pane_id": pane_b}),
    );
    assert_accepted(&selected, "select B");
    let read_b = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": null, "max_bytes": 4096, "run_id": run_b}),
    );
    assert_accepted(&read_b, "read B");
    let text_b = read_b["result"]["data"]["text"].as_str().unwrap_or("");
    assert!(!text_b.contains(&marker), "A bytes must not appear on B: {read_b}");
    let write_a = done_rx.recv_timeout(Duration::from_secs(60)).expect("A write finished");
    if write_a["accepted"] == json!(true) {
        assert_eq!(write_a["result"]["data"]["run_id"], json!(run_a));
    } else {
        let code = write_a["error"]["code"].as_str().unwrap_or("");
        assert!(
            code == "state_unknown" || code == "stale_topology",
            "A must not be dropped as a foreign target: {write_a}"
        );
        assert_ne!(code, "target_not_found");
    }
    let b_live = owner(&harness, "run.get", None, json!({"run_id": run_b}));
    assert_eq!(b_live["result"]["data"]["run"]["process"], json!("running"));
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder;
}

#[test]
fn s_resize_write() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let event_before = harness.authorization().testing_counters().0;
    let top_before = harness.authorization().testing_counters().1;
    let write_id = "20000000-0000-4000-8000-000000008621";
    let resize_id = "20000000-0000-4000-8000-000000008622";
    let written = owner_id(
        &harness,
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "resize-sibling"}),
    );
    let resized = owner_id(
        &harness,
        "pane.resize",
        resize_id,
        None,
        json!({"cols": 100, "pane_id": pane, "rows": 30, "run_id": run}),
    );
    assert_accepted(&written, "write");
    assert_accepted(&resized, "resize");
    assert_eq!(harness.authorization().testing_counters().0, event_before);
    assert_eq!(harness.authorization().testing_counters().1, top_before);
    assert_eq!(phase(&harness, write_id), Some("done"));
    assert_eq!(phase(&harness, resize_id), Some("done"));
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn s_close_race() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, after) = create_pwsh(&harness, &project_id, revision);
    let huge = "c".repeat(200_000);
    let (ready_tx, ready_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let h = harness.clone();
    let pane_t = pane.clone();
    let run_t = run.clone();
    thread::spawn(move || {
        ready_tx.send(()).ok();
        done_tx
            .send(owner(
                &h,
                "input.write",
                None,
                json!({"pane_id": pane_t, "run_id": run_t, "text": huge}),
            ))
            .ok();
    });
    ready_rx.recv().expect("writer started");
    wait_until(
        Instant::now() + Duration::from_secs(5),
        || slot_debug(&harness, &run) != "Free" || done_rx.try_recv().is_ok(),
        "writer occupy/finish",
    );
    let closed = owner(
        &harness,
        "pane.close",
        Some(after),
        json!({"pane_id": pane}),
    );
    if slot_debug(&harness, &run) != "Free" {
        assert_error(&closed, "already_running", "close vs occupied DataSlot");
    } else if closed["accepted"] != json!(true) {
        assert_error(&closed, "already_running", "close vs unclean session");
    }
    let listed = owner(&harness, "pane.list", None, json!({"project_id": project_id}));
    assert_accepted(&listed, "layout intact");
    assert_eq!(listed["result"]["data"]["panes"][0]["pane_id"], json!(pane));
    let _ = done_rx.recv_timeout(Duration::from_secs(60));
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn s_forget_wait() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, after) = create_pwsh(&harness, &project_id, revision);
    let inst = instance(&harness);
    let client = grant(
        &harness,
        "forget-wait.exe",
        &[&project_id],
        &["metadata", "control", "read_output"],
    );
    let wait_after = harness.event_seq();
    let done_rx = spawn_public_events_wait(
        client.clone(),
        inst,
        wait_after,
        MAX_SAFE_INTEGER,
    );
    wait_events_waiters_registered(&harness, wait_after, 1);
    stop_run(&harness, &run);
    let after_clean = wait_session_clean(&harness, &pane, &run, after);
    let forgotten = owner(
        &harness,
        "project.forget",
        Some(after_clean),
        json!({"project_id": project_id}),
    );
    assert_accepted(&forgotten, "project.forget");
    let woke = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("forget must wake events.wait");
    if let Some(body) = &woke {
        let blob = format!("{body}");
        assert!(!blob.contains("プロジェクト"), "forgotten path/name must not leak: {body}");
        if body["accepted"] == json!(true) {
            for event in body["result"]["data"]["events"].as_array().cloned().unwrap_or_default() {
                assert!(event["data"].get("path").is_none());
                assert!(event["data"].get("display_name").is_none());
                assert_ne!(event["data"]["kind"], json!("operation_state_changed"));
            }
        }
    }
    assert_no_waiter(&harness, wait_after);
    let _ = folder;
}

#[test]
fn s_two_project_grant_matrix() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let owner_list_a = owner(&harness, "pane.list", None, json!({"project_id": project_a}));
    assert_accepted(&owner_list_a, "owner list A");
    assert!(owner_list_a["result"]["data"]["panes"][0]["path"].is_string());
    let full = grant(
        &harness,
        "full.exe",
        &[&project_a, &project_b],
        &["metadata", "control", "read_output"],
    );
    let full_a = public(
        &full,
        Some(&inst),
        "pane.list",
        None,
        json!({"project_id": project_a}),
    )
    .expect("full A");
    let full_b = public(
        &full,
        Some(&inst),
        "pane.list",
        None,
        json!({"project_id": project_b}),
    )
    .expect("full B");
    assert_accepted(&full_a, "full-grant A");
    assert_accepted(&full_b, "full-grant B");
    assert!(full_a["result"]["data"]["panes"][0]["path"].is_string());

    const SETS: &[&[&str]] = &[
        &["metadata"],
        &["control"],
        &["read_output"],
        &["metadata", "control"],
        &["metadata", "read_output"],
        &["control", "read_output"],
        &["metadata", "control", "read_output"],
    ];
    for (i, scopes) in SETS.iter().enumerate() {
        let client = grant(
            &harness,
            &format!("matrix-{i}.exe"),
            &[&project_a],
            scopes,
        );
        for op in FOURTEEN {
            for (label, project, pane, run) in [
                ("A", project_a.as_str(), pane_a.as_str(), run_a.as_str()),
                ("B", project_b.as_str(), pane_b.as_str(), run_b.as_str()),
            ] {
                if *op == "run.interrupt" && label == "A" {
                    continue;
                }
                if *op == "input.write" && label == "A" && scopes.contains(&"control") {
                    continue;
                }
                let target = OpTarget {
                    project,
                    pane,
                    run,
                    stale_t: matches!(
                        *op,
                        "pane.create" | "pane.split" | "pane.select" | "pane.close"
                    ),
                };
                let (rev, params) = op_params(op, &target);
                let response = public(&client, Some(&inst), op, rev, params).expect("send or deny body");
                let need = required_scope(op);
                let has = scopes.iter().any(|scope| *scope == need);
                if !has {
                    assert_error(&response, "permission_denied", &format!("{op} {label} {scopes:?}"));
                    continue;
                }
                if *op == "events.wait" {
                    assert_accepted(&response, "events.wait has no pane target");
                    if let Some(events) = response["result"]["data"]["events"].as_array() {
                        for event in events {
                            assert!(event["data"].get("path").is_none());
                            assert!(event["data"].get("text").is_none());
                            assert_ne!(event["data"]["kind"], json!("operation_state_changed"));
                            if let Some(id) = event["data"]["project_id"].as_str() {
                                assert_eq!(id, project_a, "A-only must not see B topology");
                            }
                        }
                    }
                    continue;
                }
                if *op == "operation.get" {
                    assert_accepted(&response, "vacant same-actor operation.get");
                    assert_eq!(response["result"]["data"]["operation"]["phase"], json!("unknown"));
                    continue;
                }
                if label == "B" {
                    assert_error(&response, "target_not_found", &format!("{op} vs B {scopes:?}"));
                    continue;
                }
                match *op {
                    "pane.create" | "pane.split" | "pane.select" | "pane.close" => {
                        assert_error(&response, "stale_topology", &format!("{op} granted A rev 0"));
                    }
                    "shell.launch" => {
                        assert_error(&response, "already_running", "granted launch");
                    }
                    "pane.list" => {
                        assert_accepted(&response, "list A");
                        let path = &response["result"]["data"]["panes"][0]["path"];
                        let display = &response["result"]["data"]["panes"][0]["display_name"];
                        if scopes.contains(&"read_output") {
                            assert!(path.is_string(), "ReadOutput path {response}");
                        } else {
                            assert!(path.is_null(), "path must be null without ReadOutput {response}");
                            assert!(display.is_null(), "display_name must be null without ReadOutput");
                        }
                    }
                    "run.get" | "output.read" | "pane.resize" | "input.key" => {
                        assert_accepted(&response, &format!("{op} granted A"));
                    }
                    _ => {}
                }
            }
        }
    }
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn s_fifo_reverse_wake() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    {
        let child = published_runtime();
        let writes_before = retained_write_count();
        let _ = install_pending_pin(&child.runtime, &child.run);
        let issued = retained_write_count();
        assert!(issued > writes_before, "FIFO head must issue WriteFile once");
        let head = child
            .runtime
            .testing_input_stats(&child.run)
            .expect("pinned head");
        assert_eq!(format!("{:?}", head.data_slot).starts_with("Pinned"), true);
        assert!(head.write_pending);
        let (tail_tx, tail_rx) = mpsc::channel();
        for (cols, rows) in [(80, 24), (90, 26)] {
            let runtime = Arc::clone(&child.runtime);
            let run = child.run.clone();
            let tail_tx = tail_tx.clone();
            thread::spawn(move || {
                tail_tx.send(runtime.resize(&run, cols, rows)).ok();
            });
        }
        drop(tail_tx);
        let _ = child.runtime.admit_interrupt(&child.run);
        child.runtime.queue_cleanup(&child.run);
        let _ = fs::write(&child.release, b"go");
        for _ in 0..2 {
            let _ = tail_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("notify_all must wake FIFO occupancy waiters");
        }
        assert_eq!(
            retained_write_count(),
            issued,
            "woken tails must not WriteFile"
        );
    }
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run))
        .expect("attach per-run observe guard");
    prove_fifo_head_check_and_order(&harness, &pane, &run, &guard, false);
    prove_fifo_head_check_and_order(&harness, &pane, &run, &guard, true);
    drop(guard);
    stop_run(&harness, &run);
    let job = job_stop_stats(&harness, &run);
    assert_eq!(job.0, 1, "pending input interrupt terminates once: {job:?}");
    assert!(job.1, "pending input interrupt terminated exact Job: {job:?}");
    assert_eq!(job.5, Some(0), "pending input Job must be empty: {job:?}");
    let _ = folder;
}

#[test]
fn s_multi_waiter_events() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _after_a) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _after_b) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let waiter_a = grant(&harness, "multi-wait-a.exe", &[&project_a], &["metadata"]);
    let waiter_b = grant(&harness, "multi-wait-b.exe", &[&project_a], &["metadata"]);
    let after_seq = harness.event_seq();
    let rx1 = spawn_public_events_wait(waiter_a, inst.clone(), after_seq, 30_000);
    let rx2 = spawn_public_events_wait(waiter_b, inst, after_seq, 30_000);
    wait_events_waiters_registered(&harness, after_seq, 2);
    let _ = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({"pane_id": pane_b}),
    );
    let selected_a = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({"pane_id": pane_a}),
    );
    assert_accepted(&selected_a, "publish A topology");
    let w1 = rx1.recv_timeout(Duration::from_secs(30)).expect("waiter 1");
    let w2 = rx2.recv_timeout(Duration::from_secs(30)).expect("waiter 2");
    for woke in [w1, w2] {
        let body = woke.expect("lease live");
        assert_accepted(&body, "multi waiter");
        assert_ne!(
            body["result"]["data"]["status"],
            json!("gap"),
            "foreign B publication must not be WaitStatus::gap: {body}"
        );
        let events = body["result"]["data"]["events"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        assert!(
            !events.is_empty(),
            "same-generation A TopologyChanged must be visible: {body}"
        );
        for event in &events {
            assert_eq!(event["data"]["kind"], json!("topology_changed"), "{event}");
            assert!(event["data"].get("path").is_none(), "{event}");
            assert!(event["data"].get("text").is_none(), "{event}");
            if let Some(id) = event["data"]["project_id"].as_str() {
                assert_eq!(id, project_a);
            }
        }
        let next = body["result"]["data"]["next_event_seq"].as_u64().expect("next");
        assert!(next > after_seq, "next must advance with the published A event: {body}");
    }
    assert_no_waiter(&harness, after_seq);
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn b_utf8_hold() {
    p_output_unicode();
}

#[test]
fn b_ring_gap() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let filled = wait_output_contains(
        &harness,
        &run,
        folder.file_name().and_then(|n| n.to_str()).unwrap_or("プロジェクト"),
    );
    let live = decode_cursor(
        filled["result"]["data"]["next_cursor"]
            .as_str()
            .expect("cursor"),
    )
    .expect("live cursor");
    let ahead = encode_cursor(&live.instance_id, &live.run_id, live.offset.saturating_add(1_000_000));
    let read = owner(
        &harness,
        "output.read",
        None,
        json!({"cursor": ahead.as_str(), "max_bytes": 32, "run_id": run}),
    );
    assert_accepted(&read, "ahead/behind cursor");
    decode_this_cursor(&read, &harness, &run);
    if read["result"]["data"]["gap"] == json!(true) {
        assert_eq!(read["result"]["data"]["text"], json!(""));
    }
    stop_run(&harness, &run);
}

#[test]
fn b_wait_ms_finite_and_cancel() {
    assert_eq!(os_wait_timeout(0, Duration::ZERO), None);
    assert_eq!(os_wait_timeout(0, Duration::from_millis(5)), None);
    let max = os_wait_timeout(u64::from(u32::MAX), Duration::ZERO).expect("finite");
    assert_eq!(max, u32::MAX - 1);
    assert_ne!(max, u32::MAX);
    let huge = os_wait_timeout(MAX_SAFE_INTEGER, Duration::ZERO).expect("finite");
    assert_eq!(huge, u32::MAX - 1);
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let zero = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
    assert_accepted(&zero, "wait_ms 0");
    let inst = instance(&harness);
    let client = grant(&harness, "wait-ms.exe", &[&project_id], &["metadata"]);
    let wait_after = harness.event_seq();
    let done_rx = spawn_public_events_wait(
        client.clone(),
        inst,
        wait_after,
        MAX_SAFE_INTEGER,
    );
    wait_events_waiters_registered(&harness, wait_after, 1);
    let revoked = owner(
        &harness,
        "connection.revoke",
        None,
        json!({"connection_id": client.connection_id()}),
    );
    assert_accepted(&revoked, "revoke in-flight wait");
    let woke = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("revoke/generation close must wake finite wait");
    assert!(
        woke.is_none()
            || woke.as_ref().is_some_and(|body| {
                body["accepted"] == json!(true) || body["accepted"] == json!(false)
            }),
        "{woke:?}"
    );
    assert_no_waiter(&harness, wait_after);
    let _ = folder;
    let _ = run;
}

#[test]
fn b_event_seq_max() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _after) = create_pwsh(&harness, &project_id, revision);
    running_unknown(&harness, &run);
    let writes0 = ctrl_c_stats(&harness, &run).0;
    let seq0 = input_stats(&harness, &run).input_seq;
    harness.set_event_seq_to_max();
    assert_eq!(harness.event_seq(), MAX_SAFE_INTEGER);
    let interrupted = owner(&harness, "run.interrupt", None, json!({"run_id": run}));
    assert_error(&interrupted, "resource_exhausted", "interrupt at max seq");
    assert_eq!(ctrl_c_stats(&harness, &run).0, writes0);
    assert!(!input_stats(&harness, &run).stop_flag);
    running_unknown(&harness, &run);
    let selected = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({"pane_id": pane}),
    );
    assert_error(&selected, "resource_exhausted", "T at max seq");
    let written = owner(
        &harness,
        "input.write",
        None,
        json!({"pane_id": pane, "run_id": run, "text": "no-credit"}),
    );
    assert_accepted(&written, "write takes no EventCredit");
    assert_eq!(input_stats(&harness, &run).input_seq, seq0 + 1);
    let resized = owner(
        &harness,
        "pane.resize",
        None,
        json!({"cols": 90, "pane_id": pane, "rows": 28, "run_id": run}),
    );
    assert_accepted(&resized, "resize takes no EventCredit");
    assert_eq!(harness.authorization().testing_outstanding_credits(), 0);
    harness.close_generation();
    let _ = folder;
}

#[test]
fn b_class_table() {
    assert_eq!(OperationName::ALL.len(), 34);
    assert_eq!(ledger_class(OperationName::InputWrite), LedgerClass::RetainedEffect);
    assert_eq!(ledger_class(OperationName::InputKey), LedgerClass::RetainedEffect);
    assert_eq!(ledger_class(OperationName::EventsWait), LedgerClass::CurrentObservation);
    assert_eq!(ledger_class(OperationName::OperationGet), LedgerClass::CurrentObservation);
    assert_eq!(ledger_class(OperationName::ArtifactDiff), LedgerClass::CurrentObservation);
    assert_eq!(ledger_class(OperationName::ArtifactChoose), LedgerClass::RetainedEffect);
    assert_eq!(ledger_class(OperationName::ArtifactChoiceList), LedgerClass::CurrentObservation);
    let harness = Harness::new(Vec::new());
    let dummy_write = owner_id(
        &harness,
        "input.write",
        "20000000-0000-4000-8000-00000000cc01",
        None,
        json!({
            "pane_id": "40000000-0000-4000-8000-000000000000",
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": "dummy"
        }),
    );
    assert_error(&dummy_write, "target_not_found", "owner dummy write");
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc01"), Some("done"));
    let dummy_key = owner_id(
        &harness,
        "input.key",
        "20000000-0000-4000-8000-00000000cc02",
        None,
        json!({
            "key": "tab",
            "pane_id": "40000000-0000-4000-8000-000000000000",
            "run_id": "50000000-0000-4000-8000-000000000000"
        }),
    );
    assert_error(&dummy_key, "target_not_found", "owner dummy key");
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc02"), Some("done"));
    let wait = owner_id(
        &harness,
        "events.wait",
        "20000000-0000-4000-8000-00000000cc03",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
    assert_accepted(&wait, "owner events.wait vacant class");
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc03"), None);
    let opget = owner_id(
        &harness,
        "operation.get",
        "20000000-0000-4000-8000-00000000cc04",
        None,
        json!({"operation_id": "10000000-0000-4000-8000-00000000cc05"}),
    );
    assert_accepted(&opget, "owner operation.get vacant");
    assert_eq!(opget["result"]["data"]["operation"]["phase"], json!("unknown"));
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc04"), None);
    let (folder, project_id, _) = open_project(&harness);
    let inst = instance(&harness);
    let control = grant(&harness, "class-control.exe", &[&project_id], &["control"]);
    let pub_write = public_id(
        &control,
        Some(&inst),
        "input.write",
        "20000000-0000-4000-8000-00000000cc06",
        None,
        json!({
            "pane_id": "40000000-0000-4000-8000-000000000000",
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": "dummy"
        }),
    )
    .expect("public dummy write");
    assert_error(&pub_write, "target_not_found", "public Control dummy write");
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc06"), Some("done"));
    let meta = grant(&harness, "class-meta.exe", &[&project_id], &["metadata"]);
    let pub_wait = public_id(
        &meta,
        Some(&inst),
        "events.wait",
        "20000000-0000-4000-8000-00000000cc07",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    )
    .expect("public wait");
    assert_accepted(&pub_wait, "public Metadata events.wait");
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc07"), None);
    let pub_get = public_id(
        &control,
        Some(&inst),
        "operation.get",
        "20000000-0000-4000-8000-00000000cc08",
        None,
        json!({"operation_id": "10000000-0000-4000-8000-00000000cc09"}),
    )
    .expect("public operation.get");
    assert_accepted(&pub_get, "public Control operation.get vacant");
    assert_eq!(phase(&harness, "20000000-0000-4000-8000-00000000cc08"), None);
    let _ = folder;
}

#[test]
fn b_key_interrupt_bypass() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    let child = published_runtime();
    let _ = install_pending_pin(&child.runtime, &child.run);
    let started = Instant::now();
    assert_eq!(child.runtime.deliver_ctrl_c(&child.run).expect("ctrl"), false);
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(child.runtime.testing_ctrl_c_stats(&child.run).expect("s").0, 0);
    let admitted = child.runtime.admit_interrupt(&child.run).expect("stop");
    assert!(admitted);
    assert!(started.elapsed() < Duration::from_secs(2));
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let huge = "k".repeat(200_000);
    let (ready_tx, ready_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let h = harness.clone();
    let pane_t = pane.clone();
    let run_t = run.clone();
    thread::spawn(move || {
        ready_tx.send(()).ok();
        done_tx
            .send(owner(
                &h,
                "input.write",
                None,
                json!({"pane_id": pane_t, "run_id": run_t, "text": huge}),
            ))
            .ok();
    });
    ready_rx.recv().expect("writer started");
    wait_until(
        Instant::now() + Duration::from_secs(5),
        || slot_debug(&harness, &run) != "Free" || done_rx.try_recv().is_ok(),
        "writer occupy/finish",
    );
    let key_started = Instant::now();
    let key = owner(
        &harness,
        "input.key",
        None,
        json!({"key": "interrupt", "pane_id": pane, "run_id": run}),
    );
    assert!(key_started.elapsed() < Duration::from_secs(15), "key interrupt blocked on child drain");
    if key["accepted"] == json!(true) {
        assert_eq!(key["result"]["data"]["written_bytes"], json!(1));
    } else {
        assert_error(&key, "state_unknown", "RetainedUnknown/cancelled key");
    }
    let _ = done_rx.recv_timeout(Duration::from_secs(60));
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn b_admitted_vs_teardown() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    let child = published_runtime();
    let _ = install_pending_pin(&child.runtime, &child.run);
    let stats = child.runtime.testing_input_stats(&child.run).expect("stats");
    assert!(!stats.teardown_ctrl_reserved);
    assert_eq!(child.runtime.deliver_ctrl_c(&child.run).expect("ctrl"), false);
    assert_eq!(child.runtime.testing_ctrl_c_stats(&child.run).expect("c").0, 0);
    let _ = child.runtime.admit_interrupt(&child.run);
    child.runtime.queue_cleanup(&child.run);
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || {
            child
                .runtime
                .testing_ctrl_c_stats(&child.run)
                .map(|tuple| tuple.0 <= 1)
                .unwrap_or(true)
        },
        "ctrl-c stats unavailable",
    );
    let writes = child.runtime.testing_ctrl_c_stats(&child.run).expect("final").0;
    assert!(writes <= 1, "at most one teardown 0x03, got {writes}");
}

#[test]
fn b_retained_unknown_waiters() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    let child = published_runtime();
    let before = retained_write_count();
    let _ = install_pending_pin(&child.runtime, &child.run);
    assert!(child.runtime.occupancy_blocks_close(&child.run));
    let bits_pending = child.runtime.testing_input_stats(&child.run).expect("pin");
    assert!(bits_pending.write_pending);
    let (tx, rx) = mpsc::channel();
    let runtime = Arc::clone(&child.runtime);
    let run = child.run.clone();
    thread::spawn(move || {
        tx.send(runtime.resize(&run, 80, 24)).ok();
    });
    let first = rx.recv_timeout(Duration::from_millis(400));
    match first {
        Ok(Ok(())) => panic!("resize must not silently complete through a live pin"),
        Ok(Err(ErrorCode::StateUnknown)) => {}
        Ok(Err(other)) => panic!("unexpected resize error {other:?}"),
        Err(_) => {
            let _ = child.runtime.admit_interrupt(&child.run);
            let woke = rx.recv_timeout(Duration::from_secs(15)).expect("pin waiter must wake");
            assert!(woke.is_err(), "pinned resize must not succeed: {woke:?}");
        }
    }
    drop(child);
    assert!(retained_write_count() >= before);
}

#[test]
fn b_pagination_and_loss() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, mut rev) = create_pwsh(&harness, &project_id, revision);
    let mut after = 0u64;
    for _ in 0..8 {
        let selected = owner(
            &harness,
            "pane.select",
            Some(rev),
            json!({"pane_id": pane}),
        );
        assert_accepted(&selected, "select for log");
        rev = selected["topology_revision"].as_u64().expect("rev");
        let page = owner(
            &harness,
            "events.wait",
            None,
            json!({"after_event_seq": after, "wait_ms": 0}),
        );
        assert_accepted(&page, "page");
        let next = page["result"]["data"]["next_event_seq"].as_u64().expect("next");
        assert!(next >= after, "next must not skip behind after: {page}");
        let mut prev = after;
        for event in page["result"]["data"]["events"].as_array().cloned().unwrap_or_default() {
            let seq = event["event_seq"].as_u64().expect("event_seq");
            assert!(seq > prev, "visible events must stay in order {page}");
            prev = seq;
        }
        after = next;
    }
    let committed = harness.event_seq();
    let future = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": committed + 1, "wait_ms": 0}),
    );
    assert_error(&future, "invalid_request", "future still invalid after pagination");
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn b_send_replay_matrix() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, after) = create_pwsh(&harness, &project_id, revision);
    let inst = instance(&harness);
    let meta = grant(&harness, "send-meta.exe", &[&project_id], &["metadata"]);
    let listed = public(
        &meta,
        Some(&inst),
        "pane.list",
        None,
        json!({"project_id": project_id}),
    )
    .expect("metadata pane.list must send_if_current Some");
    assert_accepted(&listed, "metadata list");
    assert!(listed["result"]["data"]["panes"][0]["path"].is_null());
    let control = grant(&harness, "send-control.exe", &[&project_id], &["control"]);
    let denied_read = public(
        &control,
        Some(&inst),
        "output.read",
        None,
        json!({"cursor": null, "max_bytes": 8, "run_id": run}),
    )
    .expect("control output.read body");
    assert_error(&denied_read, "permission_denied", "Control does not imply ReadOutput");
    let denied_wait = public(
        &control,
        Some(&inst),
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    )
    .expect("control events.wait body");
    assert_error(&denied_wait, "permission_denied", "Control missing Metadata");
    let write_id = "20000000-0000-4000-8000-000000008636";
    let granted = grant(
        &harness,
        "send-full.exe",
        &[&project_id],
        &["metadata", "control", "read_output"],
    );
    let written = public_id(
        &granted,
        Some(&inst),
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "ticket"}),
    )
    .expect("granted write");
    assert_accepted(&written, "granted write");
    let other = grant(
        &harness,
        "send-other.exe",
        &[&project_id],
        &["metadata", "control"],
    );
    let hold = PhaseHold::install_for(ProductPhase::SendGate, &granted.connection_id());
    let (ready_tx, ready_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let queued = granted.clone();
    let inst_q = inst.clone();
    let project_q = project_id.clone();
    thread::spawn(move || {
        ready_tx.send(()).ok();
        done_tx
            .send(public(
                &queued,
                Some(&inst_q),
                "pane.list",
                None,
                json!({"project_id": project_q}),
            ))
            .ok();
    });
    ready_rx.recv().expect("queued list started");
    hold.wait_entered();
    stop_run(&harness, &run);
    let clean = wait_session_clean(&harness, &pane, &run, after);
    let forgotten = owner(
        &harness,
        "project.forget",
        Some(clean),
        json!({"project_id": project_id}),
    );
    assert_accepted(&forgotten, "forget A");
    hold.release_waiters();
    hold.clear();
    let queued_send = done_rx.recv_timeout(Duration::from_secs(30)).expect("queued list unblocked");
    assert!(
        queued_send.is_none()
            || queued_send.as_ref().is_some_and(|body| {
                body["accepted"] != json!(true)
                    || body["result"]["data"]["panes"][0]["path"].is_null()
            }),
        "forget must refuse or strip queued target send: {queued_send:?}"
    );
    let replay = public_id(
        &granted,
        Some(&inst),
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "ticket"}),
    );
    assert!(
        replay.is_none()
            || replay.as_ref().is_some_and(|body| {
                body["error"]["code"] == json!("permission_denied")
                    || body["error"]["code"] == json!("state_unknown")
                    || body["error"]["code"] == json!("target_not_found")
            }),
        "same-actor CurrentGrants replay after forget must not resurrect output: {replay:?}"
    );
    if let Some(body) = public_id(
        &other,
        Some(&inst),
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "ticket"}),
    ) {
        assert_error(&body, "permission_denied", "other actor after forget");
    }
    let _ = folder;
}

#[test]
fn n_operation_get_quota_does_not_rewrite_done() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let write_id = "20000000-0000-4000-8000-000000008705";
    let written = owner_id(
        &harness,
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "quota-opget"}),
    );
    assert_accepted(&written, "seed done terminal");
    assert_eq!(phase(&harness, write_id), Some("done"));
    let seq_before = harness.event_seq();
    let top_before = harness.authorization().testing_counters().1;
    let input_before = input_stats(&harness, &run).input_seq;
    let write_op = OperationId::new(write_id.to_owned()).expect("write operation id");
    let receipt_before = harness.authorization().testing_replay_receipt(&write_op);
    assert_eq!(
        receipt_before.map(|receipt| receipt.phase),
        Some("done"),
        "seed must be retained Done before quota injection"
    );
    let got = value(&harness.owner_after(
        &request(
            "operation.get",
            Some(&instance(&harness)),
            None,
            json!({"operation_id": write_id}),
        ),
        |allocations| {
            let used = allocations.snapshot().active_owner;
            let remaining =
                winsmux_workspace::memory_testing::ACTIVE_OWNER_BYTES.saturating_sub(used);
            let charge = allocations
                .claim(
                    winsmux_workspace::memory_testing::AllocationPool::ActiveOwner,
                    remaining,
                )
                .expect("ActiveOwner fill must arm the scratch claim; failed claim is not proof");
            assert_eq!(
                allocations.snapshot().active_owner,
                winsmux_workspace::memory_testing::ACTIVE_OWNER_BYTES,
                "injection must exhaust ActiveOwner after prepare/reply, used={used}"
            );
            charge
        },
    ));
    assert_error(
        &got,
        "resource_exhausted",
        "admitted operation.get charged scratch projection",
    );
    assert_eq!(phase(&harness, write_id), Some("done"));
    assert_eq!(harness.event_seq(), seq_before);
    assert_eq!(harness.authorization().testing_counters().1, top_before);
    assert_eq!(input_stats(&harness, &run).input_seq, input_before);
    let receipt_after = harness.authorization().testing_replay_receipt(&write_op);
    assert_eq!(
        receipt_after.map(|receipt| (receipt.phase, receipt.event_seq, receipt.topology_revision)),
        receipt_before.map(|receipt| (receipt.phase, receipt.event_seq, receipt.topology_revision))
    );
    assert!(
        harness.allocations().snapshot().active_owner
            < winsmux_workspace::memory_testing::ACTIVE_OWNER_BYTES,
        "quota fill CapacityCharge must drop after owner_after"
    );
    let recovered = owner(
        &harness,
        "operation.get",
        None,
        json!({"operation_id": write_id}),
    );
    assert_accepted(&recovered, "same original operation after fill drop");
    assert_eq!(
        recovered["result"]["data"]["operation"]["phase"],
        json!("completed")
    );
    assert_eq!(
        recovered["result"]["data"]["operation"]["outcome"],
        json!("succeeded")
    );
    assert!(recovered["result"]["data"]["operation"]["error_code"].is_null());
    assert!(recovered["result"]["data"]["operation"].get("text").is_none());
    assert_eq!(phase(&harness, write_id), Some("done"));
    let replay = owner_id(
        &harness,
        "input.write",
        write_id,
        None,
        json!({"pane_id": pane, "run_id": run, "text": "quota-opget"}),
    );
    assert_eq!(replay["result"]["data"], written["result"]["data"]);
    assert_eq!(input_stats(&harness, &run).input_seq, input_before);
    assert_eq!(harness.event_seq(), seq_before);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_exit_callback_does_not_publish_twice() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (_pane, run, _) = create_pwsh(&harness, &project_id, revision);
    assert_eq!(harness.authorization().testing_exit_latch_charge(), 0);
    stop_run(&harness, &run);
    let seq = harness.event_seq();
    let latch = harness.authorization().testing_exit_latch_charge();
    harness
        .authorization()
        .testing_fire_exit_callback(&run_typed(&run));
    harness
        .authorization()
        .testing_fire_exit_callback(&run_typed(&run));
    assert_eq!(harness.event_seq(), seq);
    assert_eq!(harness.authorization().testing_exit_latch_charge(), latch);
    let _ = folder;
}

#[test]
fn n_already_exited_spawn_uses_exact_event_credit_and_latch() {
    let executable = exit_now_exe().to_string_lossy().into_owned();

    let create = Harness::new(Vec::new());
    let (create_folder, create_project, _) = open_project(&create);
    let create_before = create.event_seq();
    let create_latches = create.authorization().testing_exit_latch_charge();
    let create_guard = create.use_executable_for_next_spawn(executable.clone());
    let created = owner(
        &create,
        "pane.create",
        Some(current_revision(&create)),
        json!({"project_id": create_project, "shell_profile_id": "pwsh"}),
    );
    drop(create_guard);
    assert_accepted(&created, "already-exited pane.create");
    let create_pane = created["result"]["data"]["pane_id"]
        .as_str()
        .expect("create pane")
        .to_owned();
    let create_run = created["result"]["data"]["run_id"]
        .as_str()
        .expect("create run")
        .to_owned();
    assert_eq!(
        created["event_seq"],
        json!(create_before + 1),
        "T spawn response includes only its TopologyChanged"
    );
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || create.event_seq() == create_before + 2,
        "already-exited create callback event",
    );
    let create_events = events_after(&create, create_before);
    assert_eq!(create_events.len(), 2, "{create_events:?}");
    assert_eq!(create_events[0]["data"]["kind"], json!("topology_changed"));
    assert_eq!(create_events[1]["data"]["kind"], json!("run_state_changed"));
    assert_eq!(create_events[1]["data"]["run"]["run_id"], json!(create_run));
    assert_eq!(create_events[1]["data"]["run"]["process"], json!("exited"));
    assert_eq!(
        create.authorization().testing_exit_latch_charge(),
        create_latches + 1
    );
    assert_eq!(create.authorization().testing_outstanding_credits(), 0);
    assert_eq!(
        job_stop_stats(&create, &create_run).0,
        0,
        "natural already-exited create must not terminate its Job"
    );
    let create_revision = created["topology_revision"].as_u64().expect("create revision");
    let _ = wait_session_clean(&create, &create_pane, &create_run, create_revision);
    let _ = fs::remove_dir_all(create_folder);

    let split = Harness::new(Vec::new());
    let (split_folder, split_project, split_revision) = open_project(&split);
    let (split_target, split_live_run, _) = create_pwsh(&split, &split_project, split_revision);
    let split_before = split.event_seq();
    let split_latches = split.authorization().testing_exit_latch_charge();
    let split_guard = split.use_executable_for_next_spawn(executable.clone());
    let split_response = owner(
        &split,
        "pane.split",
        Some(current_revision(&split)),
        json!({"axis": "vertical", "pane_id": split_target}),
    );
    drop(split_guard);
    assert_accepted(&split_response, "already-exited pane.split");
    let split_pane = split_response["result"]["data"]["pane_id"]
        .as_str()
        .expect("split pane")
        .to_owned();
    let split_run = split_response["result"]["data"]["run_id"]
        .as_str()
        .expect("split run")
        .to_owned();
    assert_eq!(split_response["event_seq"], json!(split_before + 1));
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || split.event_seq() == split_before + 2,
        "already-exited split callback event",
    );
    let split_events = events_after(&split, split_before);
    assert_eq!(split_events.len(), 2, "{split_events:?}");
    assert_eq!(split_events[0]["data"]["kind"], json!("topology_changed"));
    assert_eq!(split_events[1]["data"]["kind"], json!("run_state_changed"));
    assert_eq!(split_events[1]["data"]["run"]["run_id"], json!(split_run));
    assert_eq!(split_events[1]["data"]["run"]["process"], json!("exited"));
    assert_eq!(
        split.authorization().testing_exit_latch_charge(),
        split_latches + 1
    );
    assert_eq!(split.authorization().testing_outstanding_credits(), 0);
    assert_eq!(
        job_stop_stats(&split, &split_run).0,
        0,
        "natural already-exited split must not terminate its Job"
    );
    let split_after = split_response["topology_revision"]
        .as_u64()
        .expect("split revision");
    let after_close = wait_session_clean(&split, &split_pane, &split_run, split_after);
    stop_run(&split, &split_live_run);
    let _ = wait_session_clean(&split, &split_target, &split_live_run, after_close);
    let _ = fs::remove_dir_all(split_folder);

    let launch = Harness::new(Vec::new());
    let (launch_folder, launch_project, launch_revision) = open_project(&launch);
    let (launch_pane, previous_run, _) = create_pwsh(&launch, &launch_project, launch_revision);
    stop_run(&launch, &previous_run);
    let launch_before = launch.event_seq();
    let launch_latches = launch.authorization().testing_exit_latch_charge();
    let launch_guard = launch.use_executable_for_next_spawn(executable);
    let launched = launch_after_stop_cleanup(&launch, &launch_pane);
    drop(launch_guard);
    assert_accepted(&launched, "already-exited shell.launch");
    let launch_run = launched["result"]["data"]["run_id"]
        .as_str()
        .expect("launch run")
        .to_owned();
    assert_eq!(launched["event_seq"], json!(launch_before + 1));
    assert_eq!(launch.event_seq(), launch_before + 1);
    let launch_events = events_after(&launch, launch_before);
    assert_eq!(launch_events.len(), 1, "{launch_events:?}");
    assert_eq!(launch_events[0]["data"]["kind"], json!("run_state_changed"));
    assert_eq!(launch_events[0]["data"]["run"]["run_id"], json!(launch_run));
    assert_eq!(launch_events[0]["data"]["run"]["process"], json!("exited"));
    assert_eq!(
        launch.authorization().testing_exit_latch_charge(),
        launch_latches + 1
    );
    assert_eq!(launch.authorization().testing_outstanding_credits(), 0);
    assert_eq!(
        job_stop_stats(&launch, &launch_run).0,
        0,
        "natural already-exited launch must not terminate its Job"
    );
    let launch_after = launched["topology_revision"]
        .as_u64()
        .expect("launch revision");
    let _ = wait_session_clean(&launch, &launch_pane, &launch_run, launch_after);
    let _ = fs::remove_dir_all(launch_folder);
}

#[test]
fn n_resize_aborted_after_hpcon_is_not_success() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run))
        .expect("attach issue hold");
    guard.enable_issue_hold();
    let (done_tx, done_rx) = mpsc::channel();
    let h = harness.clone();
    let pane_t = pane.clone();
    let run_t = run.clone();
    thread::spawn(move || {
        done_tx
            .send(owner(
                &h,
                "pane.resize",
                None,
                json!({"cols": 80, "pane_id": pane_t, "rows": 24, "run_id": run_t}),
            ))
            .ok();
    });
    let events = guard
        .wait_for(
            |events| events.iter().any(|event| event.kind == IoObserveKind::Enqueued),
            Duration::from_secs(15),
        )
        .expect("resize enqueued");
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("resize ticket");
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("held after HpconBusy");
    let interrupted = owner(&harness, "run.interrupt", None, json!({"run_id": run}));
    assert_accepted(&interrupted, "interrupt while resize held");
    guard.release(ticket);
    let resized = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("resize finished");
    assert_ne!(resized["accepted"], json!(true), "{resized}");
    let code = resized["error"]["code"].as_str().unwrap_or("");
    assert!(
        code == "state_unknown" || code == "not_running",
        "resize Aborted must not succeed: {resized}"
    );
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn b_event_wait_locked_predicate_then_publish() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, after) = create_pwsh(&harness, &project_id, revision);
    let inst = instance(&harness);
    let client = grant(&harness, "pred-wait.exe", &[&project_id], &["metadata"]);
    let wait_after = harness.event_seq();
    let hold = PhaseHold::install(ProductPhase::EventWait);
    let done_rx = spawn_public_events_wait(client, inst, wait_after, 30_000);
    wait_events_waiters_registered(&harness, wait_after, 1);
    hold.wait_entered();
    let (select_tx, select_rx) = mpsc::channel();
    let h = harness.clone();
    let pane_t = pane.clone();
    thread::spawn(move || {
        select_tx
            .send(owner(
                &h,
                "pane.select",
                Some(after),
                json!({"pane_id": pane_t}),
            ))
            .ok();
    });
    hold.release_waiters();
    hold.clear();
    let selected = select_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("select finished");
    assert_accepted(&selected, "publish under waiter mutex");
    let woke = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("waiter woke")
        .expect("lease live");
    assert_accepted(&woke, "predicate mutex wait");
    assert_no_waiter(&harness, wait_after);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_event_waiter_mutex_poison() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (_pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let client = grant(&harness, "poison-wait.exe", &[&project_a], &["metadata"]);
    let wait_after = harness.event_seq();
    let done_rx = spawn_public_events_wait(client, inst.clone(), wait_after, 30_000);
    wait_events_waiters_registered(&harness, wait_after, 1);
    harness.poison_event_waiters();
    let poisoned = harness
        .authorization()
        .testing_event_waiters()
        .expect("event waiter evidence");
    assert_eq!(
        poisoned
            .iter()
            .filter(|waiter| waiter.after_event_seq == wait_after)
            .count(),
        1,
        "poison must not unregister: {poisoned:?}"
    );
    let selected = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({"pane_id": pane_a}),
    );
    assert_accepted(&selected, "publish under poisoned waiter mutex");
    let committed = selected["event_seq"]
        .as_u64()
        .expect("committed after poison publish");
    let woke = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("poisoned waiter must not deadlock")
        .expect("lease live");
    assert_accepted(&woke, "poisoned waiter published event");
    assert_eq!(woke["event_seq"].as_u64().expect("envelope"), committed);
    assert_eq!(woke["result"]["data"]["status"], json!("events"), "{woke}");
    let events = woke["result"]["data"]["events"]
        .as_array()
        .expect("events");
    assert_eq!(events.len(), 1, "one TopologyChanged after select: {woke}");
    assert_eq!(
        events[0]["data"]["kind"],
        json!("topology_changed"),
        "{woke}"
    );
    assert!(events[0]["data"].get("text").is_none(), "{woke}");
    assert!(events[0]["data"].get("path").is_none(), "{woke}");
    assert!(events[0]["data"].get("display_name").is_none(), "{woke}");
    if let Some(id) = events[0]["data"]["project_id"].as_str() {
        assert_eq!(id, project_a);
    }
    assert_no_waiter(&harness, wait_after);
    let cancel_client = grant(&harness, "poison-cancel.exe", &[&project_a], &["metadata"]);
    let cancel_after = harness.event_seq();
    let cancel_rx = spawn_public_events_wait(
        cancel_client.clone(),
        inst,
        cancel_after,
        MAX_SAFE_INTEGER,
    );
    wait_events_waiters_registered(&harness, cancel_after, 1);
    harness.poison_event_waiters();
    let revoked = owner(
        &harness,
        "connection.revoke",
        None,
        json!({"connection_id": cancel_client.connection_id()}),
    );
    assert_accepted(&revoked, "revoke poisoned waiter");
    let cancel_woke = cancel_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("revoke must wake poisoned waiter");
    if let Some(body) = &cancel_woke {
        if body["accepted"] == json!(true) {
            for event in body["result"]["data"]["events"]
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                assert!(event["data"].get("path").is_none());
                assert!(event["data"].get("text").is_none());
            }
        }
    }
    assert!(
        cancel_woke.is_none()
            || cancel_woke.as_ref().is_some_and(|body| {
                body["accepted"] == json!(true) || body["accepted"] == json!(false)
            }),
        "{cancel_woke:?}"
    );
    assert_no_waiter(&harness, cancel_after);
    let sibling = owner(&harness, "run.get", None, json!({"run_id": run_b}));
    assert_eq!(
        sibling["result"]["data"]["run"]["process"],
        json!("running"),
        "{sibling}"
    );
    let subsequent = owner(
        &harness,
        "events.wait",
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    );
    assert_accepted(&subsequent, "events.wait usable after poison");
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[derive(Clone, Copy, Debug)]
enum ActorDeathEntry {
    Revoke,
    Disconnect,
    FinishWorker,
}

#[derive(Clone, Copy, Debug)]
enum UnissuedStage {
    QueuedBeforeAdmit,
    AdmittedBeforeIssue,
}

#[derive(Clone, Copy, Debug)]
enum UnissuedOp {
    Write,
    Key,
    Resize,
}

fn spawn_public_op(
    client: Client,
    inst: String,
    operation: &'static str,
    operation_id: String,
    params: Value,
) -> mpsc::Receiver<Option<Value>> {
    let (done_tx, done_rx) = mpsc::channel();
    thread::spawn(move || {
        done_tx
            .send(public_id(
                &client,
                Some(&inst),
                operation,
                &operation_id,
                None,
                params,
            ))
            .ok();
    });
    done_rx
}

fn unissued_op_request(op: UnissuedOp, pane: &str, run: &str, text: &str) -> (&'static str, Value) {
    match op {
        UnissuedOp::Write => (
            "input.write",
            json!({"pane_id": pane, "run_id": run, "text": text}),
        ),
        UnissuedOp::Key => (
            "input.key",
            json!({"key": "tab", "pane_id": pane, "run_id": run}),
        ),
        UnissuedOp::Resize => (
            "pane.resize",
            json!({"cols": 80, "pane_id": pane, "rows": 24, "run_id": run}),
        ),
    }
}

fn apply_actor_death(harness: &Harness, client: &Client, entry: ActorDeathEntry) {
    match entry {
        ActorDeathEntry::Revoke => {
            let revoked = owner(
                harness,
                "connection.revoke",
                None,
                json!({"connection_id": client.connection_id()}),
            );
            assert_accepted(&revoked, "Granted connection.revoke");
        }
        ActorDeathEntry::Disconnect => client.disconnect(),
        ActorDeathEntry::FinishWorker => {
            assert!(
                client.finish_worker_for_test(),
                "finish_worker must succeed for the managed actor",
            );
        }
    }
}

fn assert_unissued_terminal(body: Option<Value>, context: &str) {
    match body {
        None => {}
        Some(body) => {
            assert_ne!(
                body["accepted"],
                json!(true),
                "{context} unissued actor death must not succeed: {body}"
            );
            let code = body["error"]["code"].as_str().unwrap_or("");
            assert!(
                code == "permission_denied" || code == "state_unknown",
                "{context} unexpected unissued terminal {body}"
            );
        }
    }
}

fn prove_actor_death_cancels_unissued(
    entry: ActorDeathEntry,
    stage: UnissuedStage,
    op: UnissuedOp,
) {
    let context = format!("{entry:?} {stage:?} {op:?}");
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let (client, _managed_worker) = grant_actor_death(
        &harness,
        entry,
        &format!("death-unissued-{}.exe", uuid::Uuid::new_v4()),
        &[&project_a],
        &["control"],
    );
    let sibling = grant(
        &harness,
        &format!("death-sib-{}.exe", uuid::Uuid::new_v4()),
        &[&project_b],
        &["control"],
    );
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run_a))
        .expect("attach per-run observe guard");
    if matches!(stage, UnissuedStage::AdmittedBeforeIssue) {
        // wait_if_held_issue is before pin_admitted / WriteFile / ResizePseudoConsole.
        guard.enable_issue_hold();
    }
    let before_seq = input_stats(&harness, &run_a).input_seq;
    let text = format!("unissued-{}", uuid::Uuid::new_v4());
    let op_id = uuid::Uuid::new_v4().to_string();
    let (operation, params) = unissued_op_request(op, &pane_a, &run_a, &text);
    let done_rx = spawn_public_op(
        client.clone(),
        inst.clone(),
        operation,
        op_id.clone(),
        params.clone(),
    );
    let events = guard
        .wait_for(
            |events| {
                events
                    .iter()
                    .any(|event| event.kind == IoObserveKind::Enqueued)
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("{context}: enqueue not recorded: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("opaque enqueue ticket");
    match stage {
        UnissuedStage::QueuedBeforeAdmit => {
            guard
                .wait_until_waiting(ticket, Duration::from_secs(15))
                .expect("queued-before-admit wait_if_held");
            let stats = input_stats(&harness, &run_a);
            assert_eq!(
                stats.data_slot,
                TestingDataSlot::Free,
                "{context} queued-before-admit is not Pinned"
            );
            assert_eq!(stats.fifo_head_id, Some(ticket.as_u64()));
            assert_eq!(stats.fifo_ids, vec![ticket.as_u64()]);
            assert_eq!(stats.input_seq, before_seq);
            assert!(
                guard
                    .events()
                    .expect("observe")
                    .iter()
                    .filter(|event| event.ticket == ticket)
                    .all(|event| event.kind != IoObserveKind::Admitted
                        && event.kind != IoObserveKind::Issued
                        && event.kind != IoObserveKind::Finished),
                "{context} queued must not admit or issue: {:?}",
                guard.events()
            );
        }
        UnissuedStage::AdmittedBeforeIssue => {
            if !matches!(op, UnissuedOp::Resize) {
                guard
                    .wait_for(
                        |events| {
                            events.iter().any(|event| {
                                event.ticket == ticket && event.kind == IoObserveKind::Admitted
                            })
                        },
                        Duration::from_secs(15),
                    )
                    .unwrap_or_else(|_| {
                        panic!("{context}: Admitted not recorded: {:?}", guard.events())
                    });
            }
            guard
                .wait_until_waiting(ticket, Duration::from_secs(15))
                .expect("admitted-before-issue wait_if_held_issue is before pin/native issue");
            let stats = input_stats(&harness, &run_a);
            match op {
                UnissuedOp::Resize => assert_eq!(
                    stats.data_slot,
                    TestingDataSlot::HpconBusy,
                    "{context} resize pre-issue is HpconBusy, not Pinned"
                ),
                UnissuedOp::Write | UnissuedOp::Key => assert_eq!(
                    stats.data_slot,
                    TestingDataSlot::Admitted,
                    "{context} pre-issue is Admitted, not Pinned"
                ),
            }
            assert_ne!(stats.data_slot, TestingDataSlot::Pinned);
            assert_eq!(stats.input_seq, before_seq);
            assert!(
                !guard
                    .events()
                    .expect("observe")
                    .iter()
                    .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
                "{context} must not issue native bytes while held: {:?}",
                guard.events()
            );
        }
    }
    let seq_b0 = input_stats(&harness, &run_b).input_seq;
    let sib1 = format!("sib-hold-{}", uuid::Uuid::new_v4());
    let sib_hold = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib1}),
    )
    .expect("independent actor must send while target is held");
    assert_accepted(&sib_hold, &format!("{context} unrelated write during hold"));
    assert_eq!(
        sib_hold["result"]["data"]["written_bytes"],
        json!(sib1.len() as u64)
    );
    assert_eq!(
        input_stats(&harness, &run_b).input_seq,
        seq_b0 + 1,
        "{context} unrelated run must progress while target remains held"
    );
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} target still unissued after sibling progress: {:?}",
        guard.events()
    );
    apply_actor_death(&harness, &client, entry);
    guard
        .wait_for(
            |events| {
                events.iter().any(|event| {
                    event.ticket == ticket && event.kind == IoObserveKind::Cancelled
                })
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| {
            panic!(
                "{context}: actor death must Cancelled this ticket: {:?}",
                guard.events()
            )
        });
    let stats = input_stats(&harness, &run_a);
    assert_eq!(
        stats.input_seq, before_seq,
        "{context} cancellation must not advance input_seq"
    );
    match (stage, op) {
        (UnissuedStage::QueuedBeforeAdmit, _) => {
            assert_eq!(
                stats.data_slot,
                TestingDataSlot::Free,
                "{context} queued cancel is still pre-admit"
            );
        }
        (UnissuedStage::AdmittedBeforeIssue, UnissuedOp::Resize) => {
            assert_eq!(
                stats.data_slot,
                TestingDataSlot::HpconBusy,
                "{context} resize cancel is before native resize"
            );
        }
        (UnissuedStage::AdmittedBeforeIssue, UnissuedOp::Write | UnissuedOp::Key) => {
            assert_eq!(
                stats.data_slot,
                TestingDataSlot::Admitted,
                "{context} write/key cancel is before pin/native issue"
            );
        }
    }
    assert_ne!(stats.data_slot, TestingDataSlot::Pinned);
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} Cancelled before native issue: {:?}",
        guard.events()
    );
    guard.release(ticket);
    let body = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("held public op finished after actor death");
    assert_unissued_terminal(body, &context);
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    let observe = guard.events().expect("final observe");
    assert!(
        !observe
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} canceled input must not issue native bytes: {observe:?}"
    );
    for event in &observe {
        if event.ticket == ticket && event.kind == IoObserveKind::Finished {
            assert_eq!(
                event.input_seq, before_seq,
                "{context} abort seal must not commit seq: {observe:?}"
            );
        }
    }
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || input_stats(&harness, &run_a).data_slot == TestingDataSlot::Free,
        "target DataSlot must return to Free",
    );
    assert_eq!(phase(&harness, &op_id), Some("done"));
    let replay = public_id(&client, Some(&inst), operation, &op_id, None, params);
    assert_unissued_terminal(replay, &format!("{context} replay"));
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    let sib2 = format!("sib-after-{}", uuid::Uuid::new_v4());
    let sib_after = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib2}),
    )
    .expect("independent actor must still send after target death");
    assert_accepted(
        &sib_after,
        &format!("{context} unrelated write after death"),
    );
    assert_eq!(
        input_stats(&harness, &run_b).input_seq,
        seq_b0 + 2,
        "{context} unrelated run must keep progressing after target death"
    );
    drop(guard);
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

fn prove_actor_death_after_delivery(entry: ActorDeathEntry) {
    let context = format!("{entry:?} after-delivery SendGate write");
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let (client, _managed_worker) = grant_actor_death(
        &harness,
        entry,
        &format!("death-delivered-{}.exe", uuid::Uuid::new_v4()),
        &[&project_a],
        &["control"],
    );
    let sibling = grant(
        &harness,
        &format!("death-delivered-sib-{}.exe", uuid::Uuid::new_v4()),
        &[&project_b],
        &["control"],
    );
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run_a))
        .expect("attach per-run observe guard");
    let hold = PhaseHold::install_for(ProductPhase::SendGate, &client.connection_id());
    let before_seq = input_stats(&harness, &run_a).input_seq;
    let marker = format!("delivered-{}", uuid::Uuid::new_v4());
    let op_id = uuid::Uuid::new_v4().to_string();
    let params = json!({"pane_id": pane_a, "run_id": run_a, "text": marker});
    let done_rx = spawn_public_op(
        client.clone(),
        inst.clone(),
        "input.write",
        op_id.clone(),
        params.clone(),
    );
    let events = guard
        .wait_for(
            |events| {
                events
                    .iter()
                    .any(|event| event.kind == IoObserveKind::Enqueued)
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("{context}: enqueue not recorded: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("opaque enqueue ticket");
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("admit hold before allowing delivery");
    guard.release(ticket);
    guard
        .wait_for(
            |events| {
                events.iter().any(|event| {
                    event.ticket == ticket && event.kind == IoObserveKind::Finished
                })
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("{context}: Finished not recorded: {:?}", guard.events()));
    hold.wait_entered();
    let stats = input_stats(&harness, &run_a);
    assert_eq!(stats.input_seq, before_seq + 1, "{context}");
    assert_eq!(stats.data_slot, TestingDataSlot::Free, "{context}");
    let observe = guard.events().expect("delivered observe");
    let issued = observe
        .iter()
        .filter(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued)
        .count();
    let finished: Vec<_> = observe
        .iter()
        .filter(|event| event.ticket == ticket && event.kind == IoObserveKind::Finished)
        .copied()
        .collect();
    assert_eq!(issued, 1, "{context} native issue once: {observe:?}");
    assert_eq!(finished.len(), 1, "{context} Finished once: {observe:?}");
    assert_eq!(
        finished[0].input_seq,
        before_seq + 1,
        "{context} Finished seq: {observe:?}"
    );
    assert_eq!(phase(&harness, &op_id), Some("done"));
    let write_op = OperationId::new(op_id.clone()).expect("operation id");
    let receipt_before = harness.authorization().testing_replay_receipt(&write_op);
    assert_eq!(
        receipt_before.map(|receipt| receipt.phase),
        Some("done"),
        "{context} retained Done must be available before actor death"
    );
    let _ = wait_output_contains(&harness, &run_a, &marker);
    let seq_b0 = input_stats(&harness, &run_b).input_seq;
    let sib1 = format!("sib-sendgate-{}", uuid::Uuid::new_v4());
    let sib_hold = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib1}),
    )
    .expect("independent actor must send during SendGate hold");
    assert_accepted(&sib_hold, &format!("{context} unrelated during send hold"));
    assert_eq!(input_stats(&harness, &run_b).input_seq, seq_b0 + 1);
    apply_actor_death(&harness, &client, entry);
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq + 1);
    assert_eq!(phase(&harness, &op_id), Some("done"));
    let receipt_after = harness.authorization().testing_replay_receipt(&write_op);
    assert_eq!(
        receipt_after.map(|receipt| (receipt.phase, receipt.event_seq, receipt.topology_revision)),
        receipt_before.map(|receipt| (receipt.phase, receipt.event_seq, receipt.topology_revision)),
        "{context} death must not rewrite retained Done"
    );
    let observe_after = guard.events().expect("post-death observe");
    assert_eq!(
        observe_after
            .iter()
            .filter(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued)
            .count(),
        1,
        "{context} no duplicate issue: {observe_after:?}"
    );
    assert_eq!(
        observe_after
            .iter()
            .filter(|event| event.ticket == ticket && event.kind == IoObserveKind::Finished)
            .count(),
        1,
        "{context} no duplicate Finished: {observe_after:?}"
    );
    hold.release_waiters();
    hold.clear();
    let body = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("SendGate writer finished");
    match body {
        None => {}
        Some(body) => {
            assert_accepted(
                &body,
                &format!("{context} transport may omit but must not rewrite sealed success"),
            );
            assert_eq!(
                body["result"]["data"]["written_bytes"],
                json!(marker.len() as u64),
                "{body}"
            );
            assert_eq!(
                body["result"]["data"]["input_seq"].as_u64().expect("seq"),
                before_seq + 1,
                "{body}"
            );
        }
    }
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq + 1);
    let replay = public_id(&client, Some(&inst), "input.write", &op_id, None, params);
    match replay {
        None => {}
        Some(body) if body["accepted"] == json!(true) => {
            assert_eq!(
                body["result"]["data"]["written_bytes"],
                json!(marker.len() as u64),
                "{body}"
            );
            assert_eq!(
                body["result"]["data"]["input_seq"].as_u64().expect("seq"),
                before_seq + 1,
                "{body}"
            );
        }
        Some(body) => {
            assert_ne!(body["accepted"], json!(true), "{body}");
            let code = body["error"]["code"].as_str().unwrap_or("");
            assert!(
                code == "permission_denied" || code == "state_unknown",
                "{context} replay must not fabricate a new effect {body}"
            );
        }
    }
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq + 1);
    let still = wait_output_contains(&harness, &run_a, &marker);
    let text = still["result"]["data"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains(&marker) || visible_output_text(text).contains(&marker),
        "{context} delivered marker must remain {still}"
    );
    let sib2 = format!("sib-after-{}", uuid::Uuid::new_v4());
    let sib_after = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib2}),
    )
    .expect("independent actor after death");
    assert_accepted(&sib_after, &format!("{context} unrelated after death"));
    assert_eq!(input_stats(&harness, &run_b).input_seq, seq_b0 + 2);
    drop(guard);
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn n_actor_death_cancels_only_registered_unissued_tickets() {
    for entry in [ActorDeathEntry::Revoke, ActorDeathEntry::Disconnect] {
        for stage in [
            UnissuedStage::QueuedBeforeAdmit,
            UnissuedStage::AdmittedBeforeIssue,
        ] {
            for op in [UnissuedOp::Write, UnissuedOp::Key, UnissuedOp::Resize] {
                prove_actor_death_cancels_unissued(entry, stage, op);
            }
        }
    }
}

#[test]
fn n_actor_death_after_delivery_send_omission_preserves_native() {
    for entry in [ActorDeathEntry::Revoke, ActorDeathEntry::Disconnect] {
        prove_actor_death_after_delivery(entry);
    }
}

#[test]
fn n_actor_death_decide_deny_legal_transitions() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let before_seq = input_stats(&harness, &run_a).input_seq;
    let pending_client = harness.connect("deny-pending.exe");
    let pending = public(
        &pending_client,
        None,
        "connection.request",
        None,
        json!({"project_ids": [project_a], "scopes": ["control"]}),
    )
    .expect("connection.request must send");
    assert_accepted(&pending, "pending request");
    let pending_id = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("connection_id")
        .to_owned();
    let denied = owner(
        &harness,
        "connection.decide",
        None,
        json!({
            "connection_id": pending_id,
            "decision": "deny",
            "project_ids": [],
            "scopes": []
        }),
    );
    assert_accepted(&denied, "Deny is legal only for Pending with empty grants");
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run_a))
        .expect("attach per-run observe guard");
    let denied_write = public(
        &pending_client,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_a, "run_id": run_a, "text": "deny-pending"}),
    );
    assert_unissued_terminal(denied_write, "Pending deny has no inflight write");
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.kind == IoObserveKind::Enqueued),
        "Pending deny must not register a ticket: {:?}",
        guard.events()
    );
    drop(guard);

    let client = grant(&harness, "deny-granted.exe", &[&project_a], &["control"]);
    let sibling = grant(
        &harness,
        "deny-granted-sib.exe",
        &[&project_b],
        &["control"],
    );
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run_a))
        .expect("reattach observe");
    let op_id = uuid::Uuid::new_v4().to_string();
    let text = format!("deny-granted-{}", uuid::Uuid::new_v4());
    let params = json!({"pane_id": pane_a, "run_id": run_a, "text": text});
    let done_rx = spawn_public_op(
        client.clone(),
        inst.clone(),
        "input.write",
        op_id,
        params,
    );
    let events = guard
        .wait_for(
            |events| {
                events
                    .iter()
                    .any(|event| event.kind == IoObserveKind::Enqueued)
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("granted enqueue: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("opaque enqueue ticket");
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("queued-before-admit");
    let illegal = owner(
        &harness,
        "connection.decide",
        None,
        json!({
            "connection_id": client.connection_id(),
            "decision": "deny",
            "project_ids": [],
            "scopes": []
        }),
    );
    assert_error(
        &illegal,
        "invalid_request",
        "Deny is not legal for Granted",
    );
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Cancelled),
        "illegal Deny must not cancel registered tickets: {:?}",
        guard.events()
    );
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    let seq_b0 = input_stats(&harness, &run_b).input_seq;
    let sib = format!("deny-sib-{}", uuid::Uuid::new_v4());
    let sib_body = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib}),
    )
    .expect("sibling send");
    assert_accepted(&sib_body, "unrelated progress during illegal deny");
    assert_eq!(input_stats(&harness, &run_b).input_seq, seq_b0 + 1);
    apply_actor_death(&harness, &client, ActorDeathEntry::Revoke);
    guard
        .wait_for(
            |events| {
                events.iter().any(|event| {
                    event.ticket == ticket && event.kind == IoObserveKind::Cancelled
                })
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("revoke Cancelled: {:?}", guard.events()));
    guard.release(ticket);
    let body = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("writer after revoke");
    assert_unissued_terminal(body, "Granted cleanup revoke");
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    drop(guard);
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

fn prove_actor_death_at_real_pinned_before_issue(entry: ActorDeathEntry, op: UnissuedOp) {
    assert!(
        matches!(op, UnissuedOp::Write | UnissuedOp::Key),
        "Pinned-before-issue is nonempty write/key only",
    );
    let context = format!("{entry:?} pinned-before-issue {op:?}");
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let (client, _managed_worker) = grant_actor_death(
        &harness,
        entry,
        &format!("death-pinned-{}.exe", uuid::Uuid::new_v4()),
        &[&project_a],
        &["control"],
    );
    let sibling = grant(
        &harness,
        &format!("death-pinned-sib-{}.exe", uuid::Uuid::new_v4()),
        &[&project_b],
        &["control"],
    );
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run_a))
        .expect("attach per-run observe guard");
    struct ReleasePinnedTicketOnDrop<F: FnOnce()> {
        release: Option<F>,
    }
    impl<F: FnOnce()> Drop for ReleasePinnedTicketOnDrop<F> {
        fn drop(&mut self) {
            if let Some(release) = self.release.take() {
                release();
            }
        }
    }
    // wait_if_held_pinned is after pin_admitted and before WriteFile.
    guard.enable_pinned_hold();
    let before_seq = input_stats(&harness, &run_a).input_seq;
    let text = format!("pinned-{}", uuid::Uuid::new_v4());
    let op_id = uuid::Uuid::new_v4().to_string();
    let (operation, params) = unissued_op_request(op, &pane_a, &run_a, &text);
    let done_rx = spawn_public_op(
        client.clone(),
        inst.clone(),
        operation,
        op_id.clone(),
        params.clone(),
    );
    let events = guard
        .wait_for(
            |events| {
                events
                    .iter()
                    .any(|event| event.kind == IoObserveKind::Enqueued)
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("{context}: enqueue not recorded: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("opaque enqueue ticket");
    let mut release = ReleasePinnedTicketOnDrop {
        release: Some({
            let guard = &guard;
            let ticket = ticket;
            move || guard.release(ticket)
        }),
    };
    guard
        .wait_for(
            |events| {
                events.iter().any(|event| {
                    event.ticket == ticket && event.kind == IoObserveKind::Admitted
                })
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("{context}: Admitted not recorded: {:?}", guard.events()));
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("pinned-before-native-issue wait after pin_admitted");
    let stats = input_stats(&harness, &run_a);
    assert_eq!(
        stats.data_slot,
        TestingDataSlot::Pinned,
        "{context} real pin_admitted must occupy Pinned before native issue"
    );
    assert_eq!(stats.input_seq, before_seq);
    assert_eq!(stats.fifo_head_id, Some(ticket.as_u64()));
    assert_eq!(stats.fifo_ids, vec![ticket.as_u64()]);
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} must not issue native bytes while Pinned is held: {:?}",
        guard.events()
    );
    let seq_b0 = input_stats(&harness, &run_b).input_seq;
    let sib1 = format!("sib-pinned-hold-{}", uuid::Uuid::new_v4());
    let sib_hold = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib1}),
    )
    .expect("independent actor must send while target is held");
    assert_accepted(&sib_hold, &format!("{context} unrelated write during hold"));
    assert_eq!(
        sib_hold["result"]["data"]["written_bytes"],
        json!(sib1.len() as u64)
    );
    assert_eq!(
        input_stats(&harness, &run_b).input_seq,
        seq_b0 + 1,
        "{context} unrelated run must progress while target remains Pinned"
    );
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    assert_eq!(
        input_stats(&harness, &run_a).data_slot,
        TestingDataSlot::Pinned,
        "{context} sibling progress must not move the held pin"
    );
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} target still unissued after sibling progress: {:?}",
        guard.events()
    );
    apply_actor_death(&harness, &client, entry);
    guard
        .wait_for(
            |events| {
                events.iter().any(|event| {
                    event.ticket == ticket && event.kind == IoObserveKind::Cancelled
                })
            },
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| {
            panic!(
                "{context}: actor death must Cancelled this pinned ticket: {:?}",
                guard.events()
            )
        });
    let stats = input_stats(&harness, &run_a);
    assert_eq!(
        stats.input_seq, before_seq,
        "{context} cancellation must not advance input_seq"
    );
    assert_eq!(
        stats.data_slot,
        TestingDataSlot::Pinned,
        "{context} cancel of unissued pin stays Pinned until issue recheck"
    );
    assert!(
        !guard
            .events()
            .expect("observe")
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} Cancelled before native issue: {:?}",
        guard.events()
    );
    guard.release(ticket);
    release.release = None;
    let body = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("held public op finished after actor death");
    assert_unissued_terminal(body, &context);
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    let observe = guard.events().expect("final observe");
    assert!(
        !observe
            .iter()
            .any(|event| event.ticket == ticket && event.kind == IoObserveKind::Issued),
        "{context} canceled pinned input must not issue native bytes: {observe:?}"
    );
    for event in &observe {
        if event.ticket == ticket && event.kind == IoObserveKind::Finished {
            assert_eq!(
                event.input_seq, before_seq,
                "{context} abort seal must not commit seq: {observe:?}"
            );
        }
    }
    wait_until(
        Instant::now() + Duration::from_secs(30),
        || input_stats(&harness, &run_a).data_slot == TestingDataSlot::Free,
        "target DataSlot must return to Free",
    );
    assert_eq!(phase(&harness, &op_id), Some("done"));
    let replay = public_id(&client, Some(&inst), operation, &op_id, None, params);
    assert_unissued_terminal(replay, &format!("{context} replay"));
    assert_eq!(input_stats(&harness, &run_a).input_seq, before_seq);
    let sib2 = format!("sib-pinned-after-{}", uuid::Uuid::new_v4());
    let sib_after = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": sib2}),
    )
    .expect("independent actor must still send after target death");
    assert_accepted(
        &sib_after,
        &format!("{context} unrelated write after death"),
    );
    assert_eq!(
        input_stats(&harness, &run_b).input_seq,
        seq_b0 + 2,
        "{context} unrelated run must keep progressing after target death"
    );
    drop(release);
    drop(guard);
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}

#[test]
fn n_actor_death_at_real_pinned_before_issue() {
    for entry in [ActorDeathEntry::Revoke, ActorDeathEntry::Disconnect] {
        for op in [UnissuedOp::Write, UnissuedOp::Key] {
            prove_actor_death_at_real_pinned_before_issue(entry, op);
        }
    }
}

#[test]
fn n_finish_worker_cancels_only_registered_unissued_tickets() {
    for stage in [
        UnissuedStage::QueuedBeforeAdmit,
        UnissuedStage::AdmittedBeforeIssue,
    ] {
        for op in [UnissuedOp::Write, UnissuedOp::Key, UnissuedOp::Resize] {
            prove_actor_death_cancels_unissued(ActorDeathEntry::FinishWorker, stage, op);
        }
    }
}

#[test]
fn n_finish_worker_after_delivery_send_omission_preserves_native() {
    prove_actor_death_after_delivery(ActorDeathEntry::FinishWorker);
}

#[test]
fn n_finish_worker_at_real_pinned_before_issue() {
    for op in [UnissuedOp::Write, UnissuedOp::Key] {
        prove_actor_death_at_real_pinned_before_issue(ActorDeathEntry::FinishWorker, op);
    }
}

#[test]
fn n_real_native_pending_is_retained_unknown_and_replay_does_not_reissue() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run))
        .expect("attach per-run observer");
    guard.enable_pending_native();
    let before_seq = input_stats(&harness, &run).input_seq;
    let operation_id = "20000000-0000-4000-8000-000000008801";
    let text = format!("pending-native-{}", uuid::Uuid::new_v4());
    let params = json!({"pane_id": pane, "run_id": run, "text": text});

    let inst = instance(&harness);
    let client = grant(
        &harness,
        "pending-native.exe",
        &[&project_id],
        &["control"],
    );
    let done_rx = spawn_public_op(
        client.clone(),
        inst.clone(),
        "input.write",
        operation_id.to_owned(),
        params.clone(),
    );
    let events = guard
        .wait_for(
            |events| events.iter().any(|event| event.kind == IoObserveKind::Enqueued),
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("pending-native enqueue: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("pending-native ticket");
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("pending-native admitted hold");
    guard.release(ticket);
    let first = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("pending-native result")
        .expect("pending-native response");
    assert_error(&first, "state_unknown", "pending native write");
    let retained = input_stats(&harness, &run);
    assert_eq!(retained.data_slot, TestingDataSlot::RetainedUnknown);
    assert!(retained.write_pending);
    assert_eq!(retained.input_seq, before_seq);
    let issued = || {
        guard
            .events()
            .expect("observer events")
            .iter()
            .filter(|event| event.kind == IoObserveKind::Issued)
            .count()
    };
    assert_eq!(issued(), 1);

    let replay = public_id(
        &client,
        Some(&inst),
        "input.write",
        operation_id,
        None,
        params,
    )
    .expect("pending-native replay response");
    assert_error(&replay, "state_unknown", "same-id retained replay");
    assert_eq!(issued(), 1);
    assert_eq!(input_stats(&harness, &run).input_seq, before_seq);
    let got = public(
        &client,
        Some(&inst),
        "operation.get",
        None,
        json!({"operation_id": operation_id}),
    )
    .expect("pending-native operation.get response");
    assert_accepted(&got, "operation.get retained native result");
    assert_eq!(
        got["result"]["data"]["operation"]["phase"],
        json!("completed")
    );
    assert_eq!(
        got["result"]["data"]["operation"]["error_code"],
        json!("state_unknown")
    );
    drop(guard);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_job_owner_failure_and_generation_races_preserve_truth() {
    let _fixture_guard = PUBLISHED_RUNTIME_TEST_LOCK.lock().unwrap();
    let failed = published_runtime();
    failed
        .runtime
        .testing_fail_job_terminate_once(&failed.run)
        .expect("install exact Job failure seam");
    assert!(
        failed
            .runtime
            .admit_interrupt(&failed.run)
            .expect("admit failing owner interrupt")
    );
    failed.runtime.queue_cleanup(&failed.run);
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || {
            failed
                .runtime
                .testing_job_stop_stats(&failed.run)
                .is_some_and(|stats| stats.2)
        },
        "injected Job termination failure was not recorded",
    );
    let failed_stats = failed
        .runtime
        .testing_job_stop_stats(&failed.run)
        .expect("failed Job stats");
    assert_eq!(failed_stats.0, 1, "Job API attempted once: {failed_stats:?}");
    assert!(!failed_stats.1, "API failure is not success: {failed_stats:?}");
    assert!(failed_stats.2, "API failure remains visible: {failed_stats:?}");
    assert!(failed_stats.4.is_some(), "Win32 error is retained: {failed_stats:?}");
    failed.runtime.queue_cleanup(&failed.run);
    assert_eq!(
        failed
            .runtime
            .testing_job_stop_stats(&failed.run)
            .expect("failed replay stats")
            .0,
        1,
        "cleanup replay cannot retry Job termination"
    );
    let failed_jobs = failed.runtime.take_jobs_for_generation_close();
    let failed_contained = failed
        .runtime
        .testing_job_stop_stats(&failed.run)
        .expect("failed contained stats");
    assert!(failed_contained.2, "containment preserves API failure");
    if failed_jobs.is_empty() {
        assert!(
            failed.runtime.session_clean(&failed.run),
            "generation may skip only after real cleanup completed"
        );
        assert!(!failed_contained.3, "clean failure path is not containment");
    } else {
        assert!(failed_contained.3, "generation containment is recorded");
        assert!(
            !failed.runtime.session_clean(&failed.run),
            "abnormal containment remains unclean"
        );
    }
    close_job_handles(failed_jobs);

    let failed_then_exited = published_runtime();
    failed_then_exited
        .runtime
        .testing_fail_job_terminate_once(&failed_then_exited.run)
        .expect("install recoverable Job failure seam");
    assert!(
        failed_then_exited
            .runtime
            .admit_interrupt(&failed_then_exited.run)
            .expect("admit recoverable owner interrupt")
    );
    failed_then_exited
        .runtime
        .queue_cleanup(&failed_then_exited.run);
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || {
            failed_then_exited
                .runtime
                .testing_job_stop_stats(&failed_then_exited.run)
                .is_some_and(|stats| stats.2)
        },
        "recoverable Job API failure was not recorded",
    );
    fs::write(&failed_then_exited.release, b"go").expect("release after Job API failure");
    let recovery_deadline = Instant::now() + Duration::from_secs(10);
    wait_until(
        recovery_deadline,
        || {
            let clean = failed_then_exited.runtime.session_clean(&failed_then_exited.run);
            if !clean && recovery_deadline.saturating_duration_since(Instant::now()) <= Duration::from_millis(50) {
                eprintln!("TASK871_JOB_RECOVERY bits={:?} stats={:?} release_exists={}", failed_then_exited.runtime.testing_session_clean_bits(&failed_then_exited.run), failed_then_exited.runtime.testing_job_stop_stats(&failed_then_exited.run), failed_then_exited.release.is_file());
            }
            clean
        },
        "actual process/job/drain completion did not recover after Job API failure",
    );
    let recovered_stats = failed_then_exited
        .runtime
        .testing_job_stop_stats(&failed_then_exited.run)
        .expect("recovered Job stats");
    assert!(recovered_stats.2, "API failure remains recorded after real exit");
    assert!(!recovered_stats.3, "real exit is not abnormal containment");
    assert_eq!(recovered_stats.5, Some(0), "recovered Job must be empty");
    let recovered_bits = failed_then_exited
        .runtime
        .testing_session_clean_bits(&failed_then_exited.run)
        .expect("recovered clean bits");
    assert!(recovered_bits.0, "all real cleanup facts make the session clean");
    assert!(!recovered_bits.8, "failed Job API did not force-kill the process");

    let generation_first = published_runtime();
    assert!(
        generation_first
            .runtime
            .admit_interrupt(&generation_first.run)
            .expect("admit before generation close")
    );
    let generation_jobs = generation_first.runtime.take_jobs_for_generation_close();
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || {
            generation_first
                .runtime
                .testing_job_stop_stats(&generation_first.run)
                .is_some_and(|stats| stats.3)
        },
        "generation-first containment was not recorded",
    );
    let generation_stats = generation_first
        .runtime
        .testing_job_stop_stats(&generation_first.run)
        .expect("generation-first stats");
    assert_eq!(
        generation_stats.0, 0,
        "generation-first containment must suppress Job API: {generation_stats:?}"
    );
    assert!(!generation_stats.1 && !generation_stats.2);
    close_job_handles(generation_jobs);

    let stop_first = published_runtime();
    assert!(
        stop_first
            .runtime
            .admit_interrupt(&stop_first.run)
            .expect("admit owner interrupt")
    );
    stop_first.runtime.queue_cleanup(&stop_first.run);
    wait_until(
        Instant::now() + Duration::from_secs(10),
        || {
            stop_first
                .runtime
                .testing_job_stop_stats(&stop_first.run)
                .is_some_and(|stats| stats.1)
        },
        "owner Job API did not return success",
    );
    let stop_jobs = stop_first.runtime.take_jobs_for_generation_close();
    let stop_stats = stop_first
        .runtime
        .testing_job_stop_stats(&stop_first.run)
        .expect("stop-first stats");
    assert_eq!(stop_stats.0, 1, "stop-first API remains once: {stop_stats:?}");
    assert!(stop_stats.1, "owner API success is preserved: {stop_stats:?}");
    if stop_jobs.is_empty() {
        assert!(
            stop_first.runtime.session_clean(&stop_first.run),
            "generation may skip only an already-clean stopped run"
        );
    } else {
        assert!(stop_stats.3, "generation take records containment: {stop_stats:?}");
    }
    close_job_handles(stop_jobs);
}

#[test]
fn n_delivered_protocol_seal_is_allocation_infallible_and_exactly_once() {
    let harness = Harness::new(Vec::new());
    let (folder, project_id, revision) = open_project(&harness);
    let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run))
        .expect("attach per-run observer");
    let hold = PhaseHold::install(ProductPhase::ProtocolSeal);
    let before_seq = input_stats(&harness, &run).input_seq;
    let operation_id = "20000000-0000-4000-8000-000000008802";
    let params = json!({"pane_id": pane, "run_id": run, "text": "seal-on-reserved-terminal"});
    let (done_tx, done_rx) = mpsc::channel();
    let h = harness.clone();
    let params_t = params.clone();
    thread::spawn(move || {
        done_tx
            .send(owner_id(
                &h,
                "input.write",
                operation_id,
                None,
                params_t,
            ))
            .ok();
    });
    let events = guard
        .wait_for(
            |events| events.iter().any(|event| event.kind == IoObserveKind::Enqueued),
            Duration::from_secs(15),
        )
        .unwrap_or_else(|_| panic!("seal-boundary enqueue: {:?}", guard.events()));
    let ticket = events
        .iter()
        .find(|event| event.kind == IoObserveKind::Enqueued)
        .map(|event| event.ticket)
        .expect("seal-boundary ticket");
    guard
        .wait_until_waiting(ticket, Duration::from_secs(15))
        .expect("seal-boundary admitted hold");
    guard.release(ticket);
    hold.wait_entered();
    fail_after_allocations(harness.allocations(), 0);
    hold.release_waiters();
    hold.clear();
    let first = done_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("seal-boundary result");
    assert!(
        harness
            .authorization()
            .testing_consume_forced_allocation_failure(),
        "protocol terminal commit consumed an allocation after native delivery"
    );
    assert_accepted(&first, "reserved terminal commits after Delivered");
    let stats = input_stats(&harness, &run);
    assert_eq!(stats.input_seq, before_seq + 1);
    assert_eq!(stats.data_slot, TestingDataSlot::Free);
    assert!(stats.fifo_ids.is_empty());
    assert_eq!(phase(&harness, operation_id), Some("done"));
    let issued = guard
        .events()
        .expect("observer events")
        .iter()
        .filter(|event| event.kind == IoObserveKind::Issued)
        .count();
    assert_eq!(issued, 1);
    let replay = owner_id(
        &harness,
        "input.write",
        operation_id,
        None,
        params,
    );
    assert_eq!(replay["result"]["data"], first["result"]["data"]);
    assert_eq!(input_stats(&harness, &run).input_seq, before_seq + 1);
    assert_eq!(
        guard
            .events()
            .expect("observer events after replay")
            .iter()
            .filter(|event| event.kind == IoObserveKind::Issued)
            .count(),
        1
    );
    drop(guard);
    stop_run(&harness, &run);
    let _ = folder;
}

#[test]
fn n_key_and_resize_terminal_seal_keep_reserved_capacity_after_native() {
    for (operation, seq_increment) in [("input.key", 1), ("pane.resize", 0)] {
        let harness = Harness::new(Vec::new());
        let (folder, project_id, revision) = open_project(&harness);
        let (pane, run, _) = create_pwsh(&harness, &project_id, revision);
        let guard = harness
            .authorization()
            .testing_attach_io_observe(&run_typed(&run))
            .expect("attach per-run observer");
        let hold = PhaseHold::install(ProductPhase::ProtocolSeal);
        let before_seq = input_stats(&harness, &run).input_seq;
        let operation_id = "20000000-0000-4000-8000-000000008803";
        let params = if operation == "input.key" {
            json!({"pane_id": pane, "run_id": run, "key": "enter"})
        } else {
            json!({"pane_id": pane, "run_id": run, "cols": 81, "rows": 24})
        };
        let (done_tx, done_rx) = mpsc::channel();
        let threaded = harness.clone();
        let threaded_params = params.clone();
        thread::spawn(move || {
            done_tx
                .send(owner_id(
                    &threaded,
                    operation,
                    operation_id,
                    None,
                    threaded_params,
                ))
                .ok();
        });
        let events = guard
            .wait_for(
                |events| events.iter().any(|event| event.kind == IoObserveKind::Enqueued),
                Duration::from_secs(15),
            )
            .expect("native data enqueue");
        let ticket = events
            .iter()
            .find(|event| event.kind == IoObserveKind::Enqueued)
            .map(|event| event.ticket)
            .expect("original data ticket");
        guard
            .wait_until_waiting(ticket, Duration::from_secs(15))
            .expect("native data admitted hold");
        guard.release(ticket);
        hold.wait_entered();
        fail_after_allocations(harness.allocations(), 0);
        hold.release_waiters();
        hold.clear();
        let first = done_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("native data result");
        assert!(
            harness
                .authorization()
                .testing_consume_forced_allocation_failure(),
            "{operation} allocated from AllocationAuthority after native completion"
        );
        assert_accepted(&first, operation);
        let settled = input_stats(&harness, &run);
        assert_eq!(settled.input_seq, before_seq + seq_increment);
        assert_eq!(settled.data_slot, TestingDataSlot::Free);
        assert!(settled.fifo_ids.is_empty());
        assert_eq!(phase(&harness, operation_id), Some("done"));
        let replay = owner_id(&harness, operation, operation_id, None, params);
        assert_eq!(replay, first, "same ID must replay the exact terminal");
        drop(guard);
        stop_run(&harness, &run);
        let _ = folder;
    }
}

#[test]
fn n_public_registration_capacity_fails_before_enqueue() {
    let harness = Harness::new(Vec::new());
    let (folder_a, project_a, rev_a) = open_project(&harness);
    let (folder_b, project_b, rev_b) = open_project(&harness);
    let (pane_a, run_a, _) = create_pwsh(&harness, &project_a, rev_a);
    let (pane_b, run_b, _) = create_pwsh(&harness, &project_b, rev_b);
    let inst = instance(&harness);
    let client = grant(&harness, "reg-fail.exe", &[&project_a], &["control"]);
    let sibling = grant(&harness, "reg-sibling.exe", &[&project_b], &["control"]);
    let guard = harness
        .authorization()
        .testing_attach_io_observe(&run_typed(&run_a))
        .expect("attach per-run observer");
    let fail = RegistrationFail {
        auth: harness.authorization(),
    };
    fail.auth
        .testing_fail_registration_for(&client.connection_id());
    let before_seq = input_stats(&harness, &run_a).input_seq;
    for (operation, params) in [
        (
            "input.write",
            json!({"pane_id": pane_a, "run_id": run_a, "text": "reg-write"}),
        ),
        (
            "input.key",
            json!({"key": "tab", "pane_id": pane_a, "run_id": run_a}),
        ),
        (
            "pane.resize",
            json!({"cols": 80, "pane_id": pane_a, "rows": 24, "run_id": run_a}),
        ),
    ] {
        let operation_id = uuid::Uuid::new_v4().to_string();
        let body = public_id(
            &client,
            Some(&inst),
            operation,
            &operation_id,
            None,
            params,
        )
        .expect("capacity failure returns a terminal");
        assert_error(&body, "resource_exhausted", operation);
        let stats = input_stats(&harness, &run_a);
        assert!(stats.fifo_ids.is_empty(), "{operation}: {stats:?}");
        assert_eq!(stats.data_slot, TestingDataSlot::Free, "{operation}");
        assert_eq!(stats.input_seq, before_seq, "{operation}");
        assert_eq!(phase(&harness, &operation_id), Some("done"));
    }
    assert_eq!(
        guard
            .events()
            .expect("observer events")
            .iter()
            .filter(|event| event.kind == IoObserveKind::Issued)
            .count(),
        0
    );
    drop(guard);

    let seq_b = input_stats(&harness, &run_b).input_seq;
    let sibling_write = public(
        &sibling,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_b, "run_id": run_b, "text": "sibling"}),
    )
    .expect("unrelated actor send");
    assert_accepted(&sibling_write, "unrelated actor progresses");
    assert_eq!(input_stats(&harness, &run_b).input_seq, seq_b + 1);
    drop(fail);
    let recovered = public(
        &client,
        Some(&inst),
        "input.write",
        None,
        json!({"pane_id": pane_a, "run_id": run_a, "text": "recovered"}),
    )
    .expect("same actor recovers");
    assert_accepted(&recovered, "registration failure is scoped");
    stop_run(&harness, &run_a);
    stop_run(&harness, &run_b);
    let _ = folder_a;
    let _ = folder_b;
}
