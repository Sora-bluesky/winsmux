#![cfg(all(windows, debug_assertions))]
#![allow(dead_code)]

use serde_json::{json, Value};
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use winsmux_workspace::contract::{parse_request, ConnectionId, OperationId, Request};
use winsmux_workspace::host::{HostError, ProductClient, ProductHost};
use winsmux_workspace::memory_testing::{
    console_host_pid, fail_after_allocations, AllocationPool, AllocationSnapshot, PhaseHold,
    ProductPhase, WriteBodyHold, RETAINED_BYTES,
};

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
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": instance,
            "operation_id": next_operation_id(),
            "expected_topology_revision": revision,
            "operation": operation,
            "params": params,
        }))
        .expect("json"),
    )
    .unwrap_or_else(|error| panic!("{operation}: {error}"))
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

fn value(response: &winsmux_workspace::Response) -> Value {
    serde_json::to_value(response).expect("json")
}

fn instance_of(host: &ProductHost) -> String {
    serde_json::to_value(host.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("instance")
}

fn temp_japanese() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "winsmux-863-プロジェクト-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    fs::create_dir_all(&path).expect("japanese folder");
    fs::write(path.join("marker.txt"), b"folder-bytes").expect("marker");
    path
}

/// CLI/protocol allocation and serialization class table.
/// Status is proven in this file with existing memory_testing APIs, or recorded
/// in missing-seams.json when the product has no reachable phase hook.
const CLASS_DECISION_TABLE: &[ClassRow] = &[
    ClassRow {
        id: "open.frame",
        operation: "project.open",
        phase: "frame",
        fail_after: Some(0),
        expected: FaultExpect::UncorrelatedClose,
    },
    ClassRow {
        id: "open.key_scratch",
        operation: "project.open",
        phase: "key_scratch",
        fail_after: Some(1),
        expected: FaultExpect::UncorrelatedClose,
    },
    ClassRow {
        id: "open.final_string_uncorrelated",
        operation: "project.open",
        phase: "final_string",
        fail_after: Some(2),
        expected: FaultExpect::UncorrelatedClose,
    },
    ClassRow {
        id: "open.instance_string_uncorrelated",
        operation: "project.open",
        phase: "final_string",
        fail_after: Some(3),
        expected: FaultExpect::UncorrelatedClose,
    },
    ClassRow {
        id: "open.escaped_and_final_string_correlated",
        operation: "project.open",
        phase: "escaped_string",
        fail_after: Some(4),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "open.canonical",
        operation: "project.open",
        phase: "canonical",
        fail_after: Some(5),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "open.terminal",
        operation: "project.open",
        phase: "terminal",
        fail_after: Some(7),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "open.table_growth",
        operation: "project.open",
        phase: "table_growth",
        fail_after: Some(8),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "list.canonical",
        operation: "project.list",
        phase: "canonical",
        fail_after: Some(4),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "list.projection",
        operation: "project.list",
        phase: "bounded_send_buffer",
        fail_after: None,
        expected: FaultExpect::BoundedProjection,
    },
    ClassRow {
        id: "list.send",
        operation: "project.list",
        phase: "write_frame_after_header",
        fail_after: None,
        expected: FaultExpect::WriteBodyForget,
    },
    ClassRow {
        id: "list.send_gate_wait_vs_forget",
        operation: "project.list",
        phase: "send_gate_wait",
        fail_after: None,
        expected: FaultExpect::SendGateForget,
    },
    ClassRow {
        id: "list.write_in_progress_vs_forget",
        operation: "project.list",
        phase: "write_in_progress",
        fail_after: None,
        expected: FaultExpect::WriteBodyForget,
    },
    ClassRow {
        id: "select.terminal",
        operation: "project.select",
        phase: "terminal",
        fail_after: Some(7),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "forget.terminal",
        operation: "project.forget",
        phase: "terminal",
        fail_after: Some(7),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "connection.request.final_vec",
        operation: "connection.request",
        phase: "final_vec",
        fail_after: Some(7),
        expected: FaultExpect::CorrelatedExhausted,
    },
    ClassRow {
        id: "idle_sibling_payload",
        operation: "project.list",
        phase: "idle_sibling_send",
        fail_after: None,
        expected: FaultExpect::IdleSiblingPayload,
    },
    ClassRow {
        id: "queued_decide_then_forget",
        operation: "connection.decide",
        phase: "serial_owner_queue",
        fail_after: None,
        expected: FaultExpect::QueuedOwnerOrder,
    },
    ClassRow {
        id: "queued_forget_then_decide",
        operation: "connection.decide",
        phase: "serial_owner_queue",
        fail_after: None,
        expected: FaultExpect::QueuedOwnerOrder,
    },
];

#[derive(Clone, Copy, Debug)]
struct ClassRow {
    id: &'static str,
    operation: &'static str,
    phase: &'static str,
    fail_after: Option<usize>,
    expected: FaultExpect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FaultExpect {
    UncorrelatedClose,
    CorrelatedExhausted,
    IdleSiblingPayload,
    BoundedProjection,
    SendGateForget,
    WriteBodyForget,
    QueuedOwnerOrder,
}

fn snapshot(host: &ProductHost) -> (AllocationSnapshot, u64) {
    (host.allocations().snapshot(), host.event_seq())
}

fn assert_ledger_unchanged(row: &str, before: &(AllocationSnapshot, u64), host: &ProductHost) {
    let after = snapshot(host);
    assert_eq!(
        before.0.retained, after.0.retained,
        "{row} retained {} -> {}",
        before.0.retained, after.0.retained
    );
    assert_eq!(
        before.0.active_owner, after.0.active_owner,
        "{row} active_owner {} -> {}",
        before.0.active_owner, after.0.active_owner
    );
    assert_eq!(
        before.0.active_public, after.0.active_public,
        "{row} active_public {} -> {}",
        before.0.active_public, after.0.active_public
    );
    assert_eq!(
        before.1, after.1,
        "{row} event_seq {} -> {}",
        before.1, after.1
    );
}

fn assert_resource_exhausted(row: &str, response: &winsmux_workspace::Response) {
    let body = value(response);
    assert_eq!(body["accepted"], json!(false), "{row} {body}");
    assert_eq!(
        body["error"]["code"],
        json!("resource_exhausted"),
        "{row} expected allocation exhaustion, not parse/auth/connection: {body}"
    );
    assert_ne!(
        body["error"]["code"],
        json!("invalid_request"),
        "{row} allocation failure must not be reported as invalid_request: {body}"
    );
}

fn unicode_escape_json_string(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        for unit in ch.encode_utf16(&mut [0; 2]) {
            out.push_str(&format!("\\u{unit:04x}"));
        }
    }
    out.push('"');
    out
}

fn escaped_open_bytes(instance: &str, operation_id: &str, path: &str) -> Vec<u8> {
    let path_json = unicode_escape_json_string(path);
    format!(
        "{{\"schema_version\":1,\"instance_id\":\"{instance}\",\"operation_id\":\"{operation_id}\",\"expected_topology_revision\":0,\"operation\":\"project.open\",\"params\":{{\"path\":{path_json}}}}}"
    )
    .into_bytes()
}

fn prove_uncorrelated_owner_close(row: &ClassRow, path: &str) {
    let host = ProductHost::start(Vec::new()).expect("isolated product host");
    let inst = instance_of(&host);
    let before = snapshot(&host);
    fail_after_allocations(
        host.allocations(),
        row.fail_after.expect("uncorrelated row has fail_after"),
    );
    let result = host.owner_request(&request_id(
        "project.open",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000a1",
        Some(0),
        json!({"path": path}),
    ));
    match result {
        Err(HostError::Transport) => {}
        Err(error) => panic!(
            "{} phase {} must close as Transport allocation failure, not {error:?} parse/auth/protocol",
            row.id, row.phase
        ),
        Ok(response) => panic!(
            "{} phase {} must close uncorrelated, not reply {}",
            row.id,
            row.phase,
            value(&response)
        ),
    }
    let after = snapshot(&host);
    assert_eq!(
        before.0.retained, after.0.retained,
        "{} retained must not keep a project/receipt charge",
        row.id
    );
    assert_eq!(
        before.1, after.1,
        "{} event_seq must stay {} not {}",
        row.id, before.1, after.1
    );
    let _ = host.shutdown();
}

fn prove_correlated_owner_fault(
    host: &ProductHost,
    row: &ClassRow,
    operation: &str,
    operation_id: &str,
    revision: Option<u64>,
    params: Value,
) {
    let inst = instance_of(host);
    let before = snapshot(host);
    fail_after_allocations(
        host.allocations(),
        row.fail_after.expect("correlated row has fail_after"),
    );
    let response = host
        .owner_request(&request_id(
            operation,
            Some(&inst),
            operation_id,
            revision,
            params,
        ))
        .unwrap_or_else(|error| {
            panic!(
                "{} phase {} must stay on the owner loop with resource_exhausted, not {error:?}",
                row.id, row.phase
            )
        });
    assert_resource_exhausted(row.id, &response);
    assert_ledger_unchanged(row.id, &before, host);
}

fn list_project_ids(listed: &Value) -> Vec<String> {
    listed["result"]["data"]["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .map(|row| row["project_id"].as_str().expect("project_id").to_owned())
        .collect()
}

fn assert_class_table_complete() {
    for expected in [
        "open.frame",
        "open.key_scratch",
        "open.escaped_and_final_string_correlated",
        "open.canonical",
        "open.terminal",
        "open.table_growth",
        "list.canonical",
        "list.projection",
        "list.send",
        "list.send_gate_wait_vs_forget",
        "list.write_in_progress_vs_forget",
        "select.terminal",
        "forget.terminal",
        "connection.request.final_vec",
        "idle_sibling_payload",
        "queued_decide_then_forget",
        "queued_forget_then_decide",
    ] {
        assert!(
            CLASS_DECISION_TABLE.iter().any(|row| row.id == expected),
            "class table missing {expected}"
        );
    }
}

fn pending_connection_id(host: &ProductHost) -> String {
    pending_connection_id_for(host, None)
}

fn pending_connection_id_for(host: &ProductHost, project_id: Option<&str>) -> String {
    let listed = value(&host.owner_list());
    listed["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| {
            row["state"] == json!("pending")
                && project_id.is_none_or(|project| {
                    row["requested_project_ids"]
                        .as_array()
                        .is_some_and(|ids| ids.iter().any(|id| id == &json!(project)))
                })
        })
        .and_then(|row| row["connection_id"].as_str())
        .unwrap_or_else(|| panic!("pending {project_id:?} in {listed}"))
        .to_owned()
}

fn assert_list_payload(row: &str, listed: &Value, project_id: &str) {
    assert_eq!(listed["accepted"], json!(true), "{row} {listed}");
    assert_eq!(
        listed["result"]["data"]["projects"][0]["project_id"],
        json!(project_id),
        "{row} {listed}"
    );
    assert!(
        listed["result"]["data"]["projects"][0]["path"]
            .as_str()
            .is_some(),
        "{row} must deliver a real project.list payload, not a control-only frame: {listed}"
    );
}

fn prove_bounded_list_projection(host: &ProductHost, client: &ProductClient, inst: &str) {
    let before = snapshot(host);
    let listed = client
        .transact(&request("project.list", Some(inst), None, json!({})))
        .expect("bounded list");
    let listed = value(&listed);
    assert_eq!(listed["accepted"], json!(true), "{listed}");
    let after = snapshot(host);
    assert_eq!(
        before.0.retained, after.0.retained,
        "list.projection Q must not consume retained; {} -> {}",
        before.0.retained, after.0.retained
    );
    assert_eq!(
        before.0.active_public, after.0.active_public,
        "list.projection must write into the pre-reserved public send buffer; {} -> {}",
        before.0.active_public, after.0.active_public
    );
}

#[test]
fn real_folder_project_journey() {
    assert_class_table_complete();
    let folder = temp_japanese();
    let folder_b = temp_japanese();
    let folder_c = temp_japanese();
    let path = folder.to_string_lossy().into_owned();
    let path_b = folder_b.to_string_lossy().into_owned();
    let path_c = folder_c.to_string_lossy().into_owned();

    for row in CLASS_DECISION_TABLE.iter().filter(|row| {
        row.expected == FaultExpect::UncorrelatedClose && row.operation == "project.open"
    }) {
        prove_uncorrelated_owner_close(row, &path);
    }

    let host = ProductHost::start(Vec::new()).expect("product host");
    let inst = instance_of(&host);

    let empty = host
        .owner_request(&request("project.list", Some(&inst), None, json!({})))
        .expect("empty list");
    let empty = value(&empty);
    assert_eq!(empty["accepted"], json!(true), "{empty}");
    assert_eq!(empty["result"]["data"]["projects"], json!([]));
    assert_eq!(empty["result"]["data"]["selected_project_id"], Value::Null);

    let list_canonical = CLASS_DECISION_TABLE
        .iter()
        .find(|row| row.id == "list.canonical")
        .expect("list.canonical");
    prove_correlated_owner_fault(
        &host,
        list_canonical,
        "project.list",
        "20000000-0000-4000-8000-0000000000c1",
        None,
        json!({}),
    );
    let empty_retry = value(
        &host
            .owner_request(&request("project.list", Some(&inst), None, json!({})))
            .expect("list after canonical fault"),
    );
    assert_eq!(empty_retry["result"]["data"]["projects"], json!([]));

    let open_id = "20000000-0000-4000-8000-0000000000e1";
    let escaped = CLASS_DECISION_TABLE
        .iter()
        .find(|row| row.id == "open.escaped_and_final_string_correlated")
        .expect("escaped");
    let before_escaped = snapshot(&host);
    fail_after_allocations(host.allocations(), escaped.fail_after.expect("n"));
    let escaped_raw = host
        .owner_bytes(&escaped_open_bytes(&inst, open_id, &path))
        .unwrap_or_else(|error| {
            panic!(
                "{} must reply resource_exhausted, not {error:?}",
                escaped.id
            )
        });
    let escaped_value: Value = serde_json::from_slice(&escaped_raw).expect("escaped json");
    assert_eq!(
        escaped_value["error"]["code"],
        json!("resource_exhausted"),
        "{} {}",
        escaped.id,
        escaped_value
    );
    assert_ledger_unchanged(escaped.id, &before_escaped, &host);

    for id in ["open.canonical", "open.terminal", "open.table_growth"] {
        let row = CLASS_DECISION_TABLE
            .iter()
            .find(|row| row.id == id)
            .expect(id);
        prove_correlated_owner_fault(
            &host,
            row,
            "project.open",
            open_id,
            Some(0),
            json!({"path": path}),
        );
    }

    let used = host.allocations().snapshot().retained;
    let fill = host
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill retained");
    let first_try = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            open_id,
            Some(0),
            json!({"path": path}),
        ))
        .expect("open attempt");
    assert_eq!(
        value(&first_try)["error"]["code"],
        json!("resource_exhausted"),
        "{}",
        value(&first_try)
    );
    drop(fill);
    let opened = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            open_id,
            Some(0),
            json!({"path": path}),
        ))
        .expect("open after fault");
    let opened = value(&opened);
    assert_eq!(opened["accepted"], json!(true), "{opened}");
    assert_eq!(opened["result"]["data"]["created"], json!(true));
    let project = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("id")
        .to_owned();
    let revision = opened["topology_revision"].as_u64().expect("rev");
    let replay_open = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            open_id,
            Some(0),
            json!({"path": path}),
        ))
        .expect("open replay");
    assert_eq!(value(&replay_open), opened);

    let used = host.allocations().snapshot().retained;
    let fill_list = host
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill for Q");
    let listed_full = host
        .owner_request(&request("project.list", Some(&inst), None, json!({})))
        .expect("list under retained fill");
    assert_eq!(value(&listed_full)["accepted"], json!(true));
    drop(fill_list);

    let listed = host
        .owner_request(&request("project.list", Some(&inst), None, json!({})))
        .expect("complete list");
    let listed = value(&listed);
    assert_eq!(listed["accepted"], json!(true), "{listed}");
    assert_eq!(
        listed["result"]["data"]["projects"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        listed["result"]["data"]["projects"][0]["project_id"],
        json!(project)
    );
    assert_eq!(
        listed["result"]["data"]["projects"][0]["root_state"],
        json!("verified")
    );
    assert!(listed["result"]["data"]["projects"][0]["path"]
        .as_str()
        .is_some());
    assert!(listed["result"]["data"]["projects"][0]["display_name"]
        .as_str()
        .is_some());

    let select_id = "20000000-0000-4000-8000-0000000000e3";
    let select_terminal = CLASS_DECISION_TABLE
        .iter()
        .find(|row| row.id == "select.terminal")
        .expect("select.terminal");
    prove_correlated_owner_fault(
        &host,
        select_terminal,
        "project.select",
        select_id,
        Some(revision),
        json!({"project_id": project}),
    );
    let listed_after_select_fault = value(
        &host
            .owner_request(&request("project.list", Some(&inst), None, json!({})))
            .expect("list after select fault"),
    );
    assert_eq!(
        listed_after_select_fault["result"]["data"]["selected_project_id"],
        Value::Null,
        "select allocation failure must not apply selection"
    );
    let used = host.allocations().snapshot().retained;
    let fill_select = host
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill for select");
    let select_try = host
        .owner_request(&request_id(
            "project.select",
            Some(&inst),
            select_id,
            Some(revision),
            json!({"project_id": project}),
        ))
        .expect("select under fill");
    assert_eq!(
        value(&select_try)["error"]["code"],
        json!("resource_exhausted"),
        "{}",
        value(&select_try)
    );
    drop(fill_select);
    let selected = host
        .owner_request(&request_id(
            "project.select",
            Some(&inst),
            select_id,
            Some(revision),
            json!({"project_id": project}),
        ))
        .expect("select");
    let selected = value(&selected);
    assert_eq!(selected["accepted"], json!(true), "{selected}");
    assert_eq!(
        selected["result"]["data"]["selected_project_id"],
        json!(project)
    );
    assert_eq!(selected["result"]["data"]["selected_pane_id"], Value::Null);
    let revision = selected["topology_revision"].as_u64().expect("rev");

    let public = host.connect_authenticated().expect("public");
    host.wait_connections(1, Duration::from_secs(2));
    let vec_row = CLASS_DECISION_TABLE
        .iter()
        .find(|row| row.id == "connection.request.final_vec")
        .expect("final_vec");
    let before_vec = snapshot(&host);
    fail_after_allocations(host.allocations(), vec_row.fail_after.expect("n"));
    let vec_try = public
        .transact(&request_id(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000b1",
            None,
            json!({"project_ids": [project], "scopes": ["metadata"]}),
        ))
        .unwrap_or_else(|error| {
            panic!(
                "{} must keep the public connection and reply resource_exhausted, not {error:?}",
                vec_row.id
            )
        });
    assert_resource_exhausted(vec_row.id, &vec_try);
    assert_ledger_unchanged(vec_row.id, &before_vec, &host);
    public
        .transact(&request(
            "connection.request",
            None,
            None,
            json!({"project_ids": [project], "scopes": ["metadata"]}),
        ))
        .expect("metadata request");
    let listed_conn = value(&host.owner_list());
    let connection_id = listed_conn["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["state"] == json!("pending"))
        .and_then(|row| row["connection_id"].as_str())
        .expect("pending")
        .to_owned();
    let decided = host.decide_allow(&connection_id, json!([project]), json!(["metadata"]));
    assert_eq!(
        value(&decided)["accepted"],
        json!(true),
        "{}",
        value(&decided)
    );
    let meta_list = public
        .transact(&request("project.list", Some(&inst), None, json!({})))
        .expect("metadata list");
    let meta_list = value(&meta_list);
    assert_eq!(meta_list["accepted"], json!(true), "{meta_list}");
    assert_eq!(
        meta_list["result"]["data"]["projects"][0]["path"],
        Value::Null
    );
    let denied_open = public
        .transact(&request(
            "project.open",
            Some(&inst),
            Some(revision),
            json!({"path": path}),
        ))
        .expect("public open");
    assert_eq!(
        value(&denied_open)["error"]["code"],
        json!("permission_denied")
    );

    let rich = host.connect_authenticated().expect("rich public");
    host.wait_connections(2, Duration::from_secs(2));
    rich.transact(&request(
        "connection.request",
        None,
        None,
        json!({"project_ids": [project], "scopes": ["metadata", "read_output", "control"]}),
    ))
    .expect("rich request");
    let listed_conn = value(&host.owner_list());
    let rich_id = listed_conn["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["state"] == json!("pending"))
        .and_then(|row| row["connection_id"].as_str())
        .expect("rich pending")
        .to_owned();
    host.decide_allow(
        &rich_id,
        json!([project]),
        json!(["metadata", "read_output", "control"]),
    );
    let rich_list = rich
        .transact(&request("project.list", Some(&inst), None, json!({})))
        .expect("rich list");
    let rich_list = value(&rich_list);
    assert!(rich_list["result"]["data"]["projects"][0]["path"]
        .as_str()
        .is_some());

    let opened_b = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000e5",
            Some(revision),
            json!({"path": path_b}),
        ))
        .expect("sibling open");
    let opened_b = value(&opened_b);
    assert_eq!(opened_b["accepted"], json!(true), "{opened_b}");
    let project_b = opened_b["result"]["data"]["project_id"]
        .as_str()
        .expect("id b")
        .to_owned();
    let revision = opened_b["topology_revision"].as_u64().expect("rev b");
    let sibling = host.connect_authenticated().expect("sibling public");
    host.wait_connections(3, Duration::from_secs(2));
    sibling
        .transact(&request(
            "connection.request",
            None,
            None,
            json!({"project_ids": [project_b], "scopes": ["metadata", "read_output", "control"]}),
        ))
        .expect("sibling request");
    let listed_conn = value(&host.owner_list());
    let sibling_id = listed_conn["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["state"] == json!("pending"))
        .and_then(|row| row["connection_id"].as_str())
        .expect("sibling pending")
        .to_owned();
    let decided_b = host.decide_allow(
        &sibling_id,
        json!([project_b]),
        json!(["metadata", "read_output", "control"]),
    );
    assert_eq!(
        value(&decided_b)["accepted"],
        json!(true),
        "{}",
        value(&decided_b)
    );
    let sibling_list = sibling
        .transact(&request("project.list", Some(&inst), None, json!({})))
        .expect("idle sibling list payload");
    let sibling_list = value(&sibling_list);
    assert_eq!(sibling_list["accepted"], json!(true), "{sibling_list}");
    assert_eq!(
        sibling_list["result"]["data"]["projects"][0]["project_id"],
        json!(project_b)
    );
    assert!(
        sibling_list["result"]["data"]["projects"][0]["path"]
            .as_str()
            .is_some(),
        "idle sibling must transmit a real project.list payload, not a control-only frame: {sibling_list}"
    );
    assert_eq!(
        list_project_ids(&sibling_list),
        vec![project_b.clone()],
        "sibling grant must not see the unrelated project"
    );
    prove_bounded_list_projection(&host, &sibling, &inst);

    let opened_c = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000c8",
            Some(revision),
            json!({"path": path_c}),
        ))
        .expect("queued-order open");
    let opened_c = value(&opened_c);
    assert_eq!(opened_c["accepted"], json!(true), "{opened_c}");
    let project_c = opened_c["result"]["data"]["project_id"]
        .as_str()
        .expect("id c")
        .to_owned();
    let revision = opened_c["topology_revision"].as_u64().expect("rev c");
    let order = host.connect_authenticated().expect("queued public");
    host.wait_connections(4, Duration::from_secs(2));
    order
        .transact(&request(
            "connection.request",
            None,
            None,
            json!({"project_ids": [project_c], "scopes": ["metadata"]}),
        ))
        .expect("queued request");
    let order_id = pending_connection_id(&host);
    let decide_id = "20000000-0000-4000-8000-0000000000d1";
    let decided_c = host
        .owner_request(&request_id(
            "connection.decide",
            Some(&inst),
            decide_id,
            None,
            json!({
                "connection_id": order_id,
                "decision": "allow",
                "project_ids": [project_c],
                "scopes": ["metadata"]
            }),
        ))
        .expect("queued decide");
    let decided_c = value(&decided_c);
    assert_eq!(decided_c["accepted"], json!(true), "{decided_c}");
    let grant = host
        .authorization()
        .testing_connection_snapshot(
            &ConnectionId::new(order_id.clone()).expect("order connection"),
        )
        .expect("order snapshot");
    assert_eq!(grant.state, "granted");
    assert_eq!(grant.granted_project_ids, vec![project_c.clone()]);
    let forget_c = host
        .owner_request(&request_id(
            "project.forget",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000c9",
            Some(revision),
            json!({"project_id": project_c}),
        ))
        .expect("queued forget after decide");
    let forget_c = value(&forget_c);
    assert_eq!(forget_c["accepted"], json!(true), "{forget_c}");
    let replay_decide = host
        .owner_request(&request_id(
            "connection.decide",
            Some(&inst),
            decide_id,
            None,
            json!({
                "connection_id": order_id,
                "decision": "allow",
                "project_ids": [project_c],
                "scopes": ["metadata"]
            }),
        ))
        .expect("owner decide receipt after target forget");
    assert_eq!(value(&replay_decide), decided_c);
    let after_forget_c = host
        .authorization()
        .testing_connection_snapshot(
            &ConnectionId::new(order_id.clone()).expect("order connection"),
        )
        .expect("order snapshot after forget");
    assert!(
        !after_forget_c.granted_project_ids.contains(&project_c),
        "forget after queued decide must strip the grant: {after_forget_c:?}"
    );
    let receipt = host
        .authorization()
        .testing_replay_receipt(&OperationId::new(decide_id).expect("decide id"))
        .expect("stored decide receipt");
    assert_eq!(receipt.phase, "done");

    let opened_c2 = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000ca",
            Some(forget_c["topology_revision"].as_u64().expect("rev")),
            json!({"path": path_c}),
        ))
        .expect("reopen after queued forget");
    let opened_c2 = value(&opened_c2);
    let project_c2 = opened_c2["result"]["data"]["project_id"]
        .as_str()
        .expect("c2")
        .to_owned();
    let revision = opened_c2["topology_revision"].as_u64().expect("rev c2");
    let order2 = host.connect_authenticated().expect("reverse-order public");
    host.wait_connections(5, Duration::from_secs(2));
    order2
        .transact(&request(
            "connection.request",
            None,
            None,
            json!({"project_ids": [project_c2], "scopes": ["metadata"]}),
        ))
        .expect("reverse request");
    let order2_id = pending_connection_id(&host);
    let forgotten_first = host
        .owner_request(&request_id(
            "project.forget",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000cb",
            Some(revision),
            json!({"project_id": project_c2}),
        ))
        .expect("queued forget before decide");
    let forgotten_first = value(&forgotten_first);
    assert_eq!(
        forgotten_first["accepted"],
        json!(true),
        "{forgotten_first}"
    );
    let decide_after = host
        .owner_request(&request_id(
            "connection.decide",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000d2",
            None,
            json!({
                "connection_id": order2_id,
                "decision": "allow",
                "project_ids": [project_c2],
                "scopes": ["metadata"]
            }),
        ))
        .expect("decide after forget");
    assert_eq!(
        value(&decide_after)["error"]["code"],
        json!("invalid_request"),
        "serial forget-then-decide must not grant a forgotten project: {}",
        value(&decide_after)
    );
    let revision = forgotten_first["topology_revision"].as_u64().expect("rev");

    let forget_id = "20000000-0000-4000-8000-0000000000e2";
    let forget_terminal = CLASS_DECISION_TABLE
        .iter()
        .find(|row| row.id == "forget.terminal")
        .expect("forget.terminal");
    prove_correlated_owner_fault(
        &host,
        forget_terminal,
        "project.forget",
        forget_id,
        Some(revision),
        json!({"project_id": project}),
    );
    let still_listed = value(
        &host
            .owner_request(&request("project.list", Some(&inst), None, json!({})))
            .expect("list after forget fault"),
    );
    let remaining = list_project_ids(&still_listed);
    assert!(
        remaining.contains(&project),
        "forget allocation failure must leave the project: {still_listed}"
    );
    assert_eq!(
        fs::read(folder.join("marker.txt")).expect("disk"),
        b"folder-bytes"
    );
    let used = host.allocations().snapshot().retained;
    let fill_forget = host
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill for forget");
    let forget_fill = host
        .owner_request(&request_id(
            "project.forget",
            Some(&inst),
            forget_id,
            Some(revision),
            json!({"project_id": project}),
        ))
        .expect("forget under fill");
    assert_eq!(
        value(&forget_fill)["error"]["code"],
        json!("resource_exhausted"),
        "{}",
        value(&forget_fill)
    );
    drop(fill_forget);
    let revision = value(
        &host
            .owner_request(&request("project.list", Some(&inst), None, json!({})))
            .expect("revision before send-gate forget"),
    )["topology_revision"]
        .as_u64()
        .expect("rev");
    let rich_cid = ConnectionId::new(rich_id.clone()).expect("rich cid");
    let send_hold = PhaseHold::install_for(ProductPhase::SendGate, &rich_cid);
    let inst_for_rich = inst.clone();
    let (stale_tx, stale_rx) = mpsc::channel();
    thread::spawn(move || {
        let result = rich.transact(&request(
            "project.list",
            Some(&inst_for_rich),
            None,
            json!({}),
        ));
        let _ = stale_tx.send(result);
    });
    send_hold.wait_entered();
    let outbound = host
        .authorization()
        .testing_connection_snapshot(&rich_cid)
        .expect("rich outbound");
    assert_eq!(
        outbound.state, "granted",
        "SendGate hold keeps the lease granted while the true send gate is held: {outbound:?}"
    );
    let forgotten = thread::scope(|scope| {
        let forget_thread = scope.spawn(|| {
            host.owner_request(&request_id(
                "project.forget",
                Some(&inst),
                forget_id,
                Some(revision),
                json!({"project_id": project}),
            ))
        });
        let sibling_during = sibling
            .transact(&request("project.list", Some(&inst), None, json!({})))
            .expect("sibling payload during send-gate wait");
        assert_list_payload(
            "list.send_gate_wait_vs_forget",
            &value(&sibling_during),
            &project_b,
        );
        send_hold.release_waiters();
        forget_thread.join().expect("forget thread")
    })
    .expect("forget after send-gate drain");
    let forgotten = value(&forgotten);
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");
    match stale_rx.recv_timeout(Duration::from_millis(400)) {
        Ok(Ok(response)) => {
            let body = value(&response);
            if body["accepted"] == json!(true) {
                assert!(
                    !list_project_ids(&body).contains(&project),
                    "queued stale list must not keep the forgotten project: {body}"
                );
            }
        }
        Ok(Err(_)) | Err(mpsc::RecvTimeoutError::Timeout) => {}
        Err(error) => panic!("stale list channel {error}"),
    }
    send_hold.clear();
    assert_eq!(
        fs::read(folder.join("marker.txt")).expect("disk"),
        b"folder-bytes"
    );
    let replay = host
        .owner_request(&request_id(
            "project.forget",
            Some(&inst),
            forget_id,
            Some(revision),
            json!({"project_id": project}),
        ))
        .expect("forget replay");
    assert_eq!(value(&replay), forgotten);

    let opened_a2 = host
        .owner_request(&request_id(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000cd",
            Some(forgotten["topology_revision"].as_u64().expect("rev")),
            json!({"path": path}),
        ))
        .expect("reopen after send-gate forget");
    let opened_a2 = value(&opened_a2);
    assert_eq!(opened_a2["accepted"], json!(true), "{opened_a2}");
    let project_a2 = opened_a2["result"]["data"]["project_id"]
        .as_str()
        .expect("a2")
        .to_owned();
    let writer = host.connect_authenticated().expect("write-body public");
    host.wait_connections(5, Duration::from_secs(2));
    writer
        .transact(&request(
            "connection.request",
            None,
            None,
            json!({"project_ids": [project_a2], "scopes": ["metadata", "read_output"]}),
        ))
        .expect("writer request");
    let writer_id = pending_connection_id_for(&host, Some(&project_a2));
    let decided_writer = value(&host.decide_allow(
        &writer_id,
        json!([project_a2]),
        json!(["metadata", "read_output"]),
    ));
    assert_eq!(
        decided_writer["accepted"],
        json!(true),
        "writer decide {writer_id} {decided_writer}"
    );
    let writer_cid = ConnectionId::new(writer_id.clone()).expect("writer cid");
    let write_hold = WriteBodyHold::install_for(&writer_cid);
    let inst_for_writer = inst.clone();
    let (body_tx, body_rx) = mpsc::channel();
    thread::spawn(move || {
        let result = writer.transact(&request(
            "project.list",
            Some(&inst_for_writer),
            None,
            json!({}),
        ));
        let _ = body_tx.send((result, writer));
    });
    write_hold.wait_header_written();
    let writing = host
        .authorization()
        .testing_connection_snapshot(&writer_cid)
        .expect("writer snapshot at header hold");
    assert_eq!(
        writing.state, "granted",
        "WriteBodyHold keeps the selected public lease granted after the 4-byte header: {writing:?}"
    );
    assert_eq!(writing.granted_project_ids, vec![project_a2.clone()]);
    let before_forget = snapshot(&host);
    let forgotten_a2 = thread::scope(|scope| {
        let forget_thread = scope.spawn(|| {
            host.owner_request(&request_id(
                "project.forget",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000ce",
                Some(opened_a2["topology_revision"].as_u64().expect("rev")),
                json!({"project_id": project_a2}),
            ))
        });
        let strip_deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let stripped = host
                .authorization()
                .testing_connection_snapshot(&writer_cid)
                .is_some_and(|snapshot| !snapshot.granted_project_ids.contains(&project_a2));
            if stripped {
                break;
            }
            assert!(
                Instant::now() < strip_deadline,
                "list.write_in_progress_vs_forget: ProductHost.owner_request(project.forget) must reach owner_loop and strip the writing grant while the public header hold is still active"
            );
            thread::sleep(Duration::from_millis(5));
        }
        let sibling_during = sibling
            .transact(&request("project.list", Some(&inst), None, json!({})))
            .expect("sibling payload during partial write");
        assert_list_payload(
            "list.write_in_progress_vs_forget",
            &value(&sibling_during),
            &project_b,
        );
        write_hold.release_body();
        forget_thread.join().expect("write-body forget thread")
    })
    .expect("forget after header drain");
    let forgotten_a2 = value(&forgotten_a2);
    assert_eq!(forgotten_a2["accepted"], json!(true), "{forgotten_a2}");
    let after_forget = snapshot(&host);
    assert_eq!(
        before_forget.0.active_owner, after_forget.0.active_owner,
        "write-body forget must keep the owner resource counter"
    );
    assert!(
        after_forget.1 > before_forget.1,
        "write-body forget must advance event_seq {} -> {}",
        before_forget.1,
        after_forget.1
    );
    write_hold.clear();
    match body_rx.recv_timeout(Duration::from_secs(5)) {
        Ok((result, writer)) => {
            match &result {
                Ok(response) => {
                    let body = value(response);
                    assert!(
                        !list_project_ids(&body).contains(&project_a2),
                        "partial-write must not deliver a stale complete body: {body}"
                    );
                }
                Err(_) => {}
            }
            match writer.transact(&request("project.list", Some(&inst), None, json!({}))) {
                Err(_) => {}
                Ok(response) => {
                    assert!(
                        result.is_ok(),
                        "partial-write connection must not be reused after a cancelled body: {}",
                        value(&response)
                    );
                    assert!(
                        !list_project_ids(&value(&response)).contains(&project_a2),
                        "reused writer must not resurrect the forgotten project: {}",
                        value(&response)
                    );
                }
            }
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            panic!("write-body list did not finish after header drain and forget")
        }
        Err(error) => panic!("write-body list channel {error}"),
    }
    let after_write_body = value(
        &host
            .owner_request(&request("project.list", Some(&inst), None, json!({})))
            .expect("list after write-body forget"),
    );
    assert!(
        !list_project_ids(&after_write_body).contains(&project_a2),
        "partial-write forget must remove the target: {after_write_body}"
    );

    let sibling_after = sibling
        .transact(&request("project.list", Some(&inst), None, json!({})))
        .expect("sibling payload after unrelated forget");
    let sibling_after = value(&sibling_after);
    assert_eq!(sibling_after["accepted"], json!(true), "{sibling_after}");
    assert_eq!(
        sibling_after["result"]["data"]["projects"][0]["project_id"],
        json!(project_b)
    );
    assert!(
        sibling_after["result"]["data"]["projects"][0]["path"]
            .as_str()
            .is_some(),
        "idle sibling payload must remain after unrelated forget: {sibling_after}"
    );
    let after_a = value(
        &host
            .owner_request(&request("project.list", Some(&inst), None, json!({})))
            .expect("after forget A"),
    );
    assert_eq!(list_project_ids(&after_a), vec![project_b.clone()]);
    let forgotten_b = host
        .owner_request(&request_id(
            "project.forget",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000e6",
            Some(after_a["topology_revision"].as_u64().expect("rev")),
            json!({"project_id": project_b}),
        ))
        .expect("forget sibling");
    assert_eq!(
        value(&forgotten_b)["accepted"],
        json!(true),
        "{}",
        value(&forgotten_b)
    );
    let after = host
        .owner_request(&request("project.list", Some(&inst), None, json!({})))
        .expect("after forget");
    assert_eq!(value(&after)["result"]["data"]["projects"], json!([]));

    host.shutdown().expect("join");
    let _ = fs::remove_dir_all(&folder);
    let _ = fs::remove_dir_all(&folder_b);
    let _ = fs::remove_dir_all(&folder_c);
}

#[link(name = "user32")]
extern "system" {
    fn EnumWindows(
        callback: Option<unsafe extern "system" fn(*mut core::ffi::c_void, isize) -> i32>,
        lparam: isize,
    ) -> i32;
    fn GetForegroundWindow() -> *mut core::ffi::c_void;
    fn GetWindowThreadProcessId(hwnd: *mut core::ffi::c_void, process_id: *mut u32) -> u32;
    fn GetClassNameW(hwnd: *mut core::ffi::c_void, class_name: *mut u16, max_count: i32) -> i32;
    fn GetWindow(hwnd: *mut core::ffi::c_void, cmd: u32) -> *mut core::ffi::c_void;
    fn GetWindowTextW(hwnd: *mut core::ffi::c_void, text: *mut u16, max_count: i32) -> i32;
    fn IsWindow(hwnd: *mut core::ffi::c_void) -> i32;
    fn IsWindowVisible(hwnd: *mut core::ffi::c_void) -> i32;
    fn ShowWindow(hwnd: *mut core::ffi::c_void, cmd: i32) -> i32;
    fn GetProcessWindowStation() -> *mut core::ffi::c_void;
    fn GetThreadDesktop(thread_id: u32) -> *mut core::ffi::c_void;
    fn GetUserObjectInformationW(
        handle: *mut core::ffi::c_void,
        index: i32,
        info: *mut core::ffi::c_void,
        length: u32,
        needed: *mut u32,
    ) -> i32;
}

#[repr(C)]
struct StartupInfoW {
    cb: u32,
    lp_reserved: *mut u16,
    lp_desktop: *mut u16,
    lp_title: *mut u16,
    dw_x: u32,
    dw_y: u32,
    dw_x_size: u32,
    dw_y_size: u32,
    dw_x_count_chars: u32,
    dw_y_count_chars: u32,
    dw_fill_attribute: u32,
    dw_flags: u32,
    w_show_window: u16,
    cb_reserved2: u16,
    lp_reserved2: *mut u8,
    h_std_input: *mut core::ffi::c_void,
    h_std_output: *mut core::ffi::c_void,
    h_std_error: *mut core::ffi::c_void,
}

#[repr(C)]
struct ProcessInformation {
    h_process: *mut core::ffi::c_void,
    h_thread: *mut core::ffi::c_void,
    dw_process_id: u32,
    dw_thread_id: u32,
}

#[repr(C)]
struct ProcessEntry32W {
    dw_size: u32,
    cnt_usage: u32,
    th32_process_id: u32,
    th32_default_heap_id: usize,
    th32_module_id: u32,
    cnt_threads: u32,
    th32_parent_process_id: u32,
    pc_pri_class_base: i32,
    dw_flags: u32,
    sz_exe_file: [u16; 260],
}

#[repr(C)]
struct FileTime {
    dw_low_date_time: u32,
    dw_high_date_time: u32,
}

#[repr(C)]
struct UserObjectFlags {
    f_inherit: i32,
    f_reserved: i32,
    dw_flags: u32,
}

#[link(name = "kernel32")]
extern "system" {
    fn OpenProcess(desired_access: u32, inherit: i32, process_id: u32) -> *mut core::ffi::c_void;
    fn TerminateProcess(handle: *mut core::ffi::c_void, exit_code: u32) -> i32;
    fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
    fn CreateProcessW(
        application: *const u16,
        command_line: *mut u16,
        process_attributes: *mut core::ffi::c_void,
        thread_attributes: *mut core::ffi::c_void,
        inherit_handles: i32,
        creation_flags: u32,
        environment: *mut core::ffi::c_void,
        current_directory: *const u16,
        startup_info: *mut StartupInfoW,
        process_information: *mut ProcessInformation,
    ) -> i32;
    fn GetLastError() -> u32;
    fn GetExitCodeProcess(handle: *mut core::ffi::c_void, exit_code: *mut u32) -> i32;
    fn GetProcessTimes(
        handle: *mut core::ffi::c_void,
        creation: *mut FileTime,
        exit: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) -> i32;
    fn GetProcessId(handle: *mut core::ffi::c_void) -> u32;
    fn WaitForSingleObject(handle: *mut core::ffi::c_void, milliseconds: u32) -> u32;
    fn GetCurrentThreadId() -> u32;
    fn ProcessIdToSessionId(process_id: u32, session_id: *mut u32) -> i32;
    fn FreeConsole() -> i32;
    fn AttachConsole(process_id: u32) -> i32;
    fn GetStdHandle(handle_id: u32) -> *mut core::ffi::c_void;
    fn GetConsoleScreenBufferInfo(
        handle: *mut core::ffi::c_void,
        info: *mut ConsoleScreenBufferInfo,
    ) -> i32;
    fn ReadConsoleOutputCharacterW(
        handle: *mut core::ffi::c_void,
        buffer: *mut u16,
        length: u32,
        read_coord: Coord,
        nread: *mut u32,
    ) -> i32;
    fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        security: *mut core::ffi::c_void,
        creation: u32,
        flags: u32,
        template: *mut core::ffi::c_void,
    ) -> *mut core::ffi::c_void;
    fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) -> *mut core::ffi::c_void;
    fn Process32FirstW(snapshot: *mut core::ffi::c_void, entry: *mut ProcessEntry32W) -> i32;
    fn Process32NextW(snapshot: *mut core::ffi::c_void, entry: *mut ProcessEntry32W) -> i32;
    fn QueryFullProcessImageNameW(
        process: *mut core::ffi::c_void,
        flags: u32,
        exe_name: *mut u16,
        size: *mut u32,
    ) -> i32;
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Coord {
    x: i16,
    y: i16,
}

#[repr(C)]
struct SmallRect {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
}

#[repr(C)]
struct ConsoleScreenBufferInfo {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
}

#[repr(C)]
struct Guid {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

#[link(name = "ole32")]
extern "system" {
    fn CoInitializeEx(reserved: *mut core::ffi::c_void, coinit: u32) -> i32;
    fn CoCreateInstance(
        clsid: *const Guid,
        outer: *mut core::ffi::c_void,
        context: u32,
        iid: *const Guid,
        ppv: *mut *mut core::ffi::c_void,
    ) -> i32;
    fn CoUninitialize();
}

#[link(name = "oleaut32")]
extern "system" {
    fn SysFreeString(bstr: *mut u16);
    fn SysStringLen(bstr: *mut u16) -> u32;
}

const STARTF_USESHOWWINDOW: u32 = 0x0000_0001;
const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
const CREATE_UNICODE_ENVIRONMENT: u32 = 0x0000_0400;
const SW_HIDE: u16 = 0;
const SW_SHOWNORMAL: u16 = 1;
const SW_SHOW: i32 = 5;
const SW_SHOWNA: i32 = 8;
const TH32CS_SNAPPROCESS: u32 = 0x0000_0002;
const STILL_ACTIVE: u32 = 259;
const ERROR_INVALID_PARAMETER: u32 = 87;
const OWNER_CLI_TITLE: &str = "TASK863-OWNER-CLI-HOST";
const CONSOLE_WINDOW_CLASS: &str = "ConsoleWindowClass";
const WAIT_OBJECT_0: u32 = 0;
const UOI_FLAGS: i32 = 1;
const UOI_NAME: i32 = 2;
const WSF_VISIBLE: u32 = 0x0001;
const PROCESS_TERMINATE: u32 = 0x0001;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

fn filetime_u64(time: FileTime) -> u64 {
    (u64::from(time.dw_high_date_time) << 32) | u64::from(time.dw_low_date_time)
}

fn process_creation(handle: *mut core::ffi::c_void) -> Option<u64> {
    let mut creation = FileTime {
        dw_low_date_time: 0,
        dw_high_date_time: 0,
    };
    let mut exit = FileTime {
        dw_low_date_time: 0,
        dw_high_date_time: 0,
    };
    let mut kernel = FileTime {
        dw_low_date_time: 0,
        dw_high_date_time: 0,
    };
    let mut user = FileTime {
        dw_low_date_time: 0,
        dw_high_date_time: 0,
    };
    let ok = unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) };
    if ok == 0 {
        None
    } else {
        Some(filetime_u64(creation))
    }
}

fn process_exit_code(handle: *mut core::ffi::c_void) -> Option<u32> {
    let mut code = 0u32;
    if unsafe { GetExitCodeProcess(handle, &mut code) } == 0 {
        None
    } else {
        Some(code)
    }
}

fn process_wait_status(handle: *mut core::ffi::c_void) -> Option<u32> {
    if handle.is_null() {
        None
    } else {
        Some(unsafe { WaitForSingleObject(handle, 0u32) })
    }
}

struct DesktopMeta {
    session_id: Option<u32>,
    window_station: String,
    station_visible: Option<bool>,
    desktop: String,
}

fn desktop_json(meta: &DesktopMeta) -> Value {
    json!({
        "session_id": meta.session_id,
        "window_station": meta.window_station,
        "station_visible": meta.station_visible,
        "desktop": meta.desktop,
        "lp_desktop": Value::Null,
        "inherit_parent": true
    })
}

fn user_object_name(handle: *mut core::ffi::c_void) -> String {
    if handle.is_null() {
        return String::new();
    }
    let mut buf = [0u16; 256];
    let mut needed = 0u32;
    let ok = unsafe {
        GetUserObjectInformationW(
            handle,
            UOI_NAME,
            buf.as_mut_ptr() as *mut core::ffi::c_void,
            (buf.len() * 2) as u32,
            &mut needed,
        )
    };
    if ok == 0 {
        return String::new();
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..len])
}

fn station_visible(handle: *mut core::ffi::c_void) -> Option<bool> {
    if handle.is_null() {
        return None;
    }
    let mut flags = UserObjectFlags {
        f_inherit: 0,
        f_reserved: 0,
        dw_flags: 0,
    };
    let mut needed = 0u32;
    let ok = unsafe {
        GetUserObjectInformationW(
            handle,
            UOI_FLAGS,
            &mut flags as *mut UserObjectFlags as *mut core::ffi::c_void,
            std::mem::size_of::<UserObjectFlags>() as u32,
            &mut needed,
        )
    };
    if ok == 0 {
        None
    } else {
        Some(flags.dw_flags & WSF_VISIBLE != 0)
    }
}

fn own_desktop_metadata() -> DesktopMeta {
    let mut session = 0u32;
    let session_ok = unsafe { ProcessIdToSessionId(std::process::id(), &mut session) } != 0;
    let winsta = unsafe { GetProcessWindowStation() };
    let desk = unsafe { GetThreadDesktop(GetCurrentThreadId()) };
    DesktopMeta {
        session_id: if session_ok { Some(session) } else { None },
        window_station: user_object_name(winsta),
        station_visible: station_visible(winsta),
        desktop: user_object_name(desk),
    }
}

fn wide_os(value: &std::ffi::OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

fn wide_str(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn isolated_environment(home: &Path) -> Vec<u16> {
    let home_os = home.as_os_str().to_os_string();
    let mut pairs: Vec<(OsString, OsString)> = std::env::vars_os().collect();
    for key in ["TMP", "TEMP", "TMPDIR", "HOME"] {
        if let Some(slot) = pairs
            .iter_mut()
            .find(|(name, _)| name.eq_ignore_ascii_case(key))
        {
            slot.1 = home_os.clone();
        } else {
            pairs.push((OsString::from(key), home_os.clone()));
        }
    }
    let mut block = Vec::new();
    for (name, value) in pairs {
        block.extend(name.encode_wide());
        block.push(u16::from(b'='));
        block.extend(value.encode_wide());
        block.push(0);
    }
    block.push(0);
    if block.len() == 1 {
        block.push(0);
    }
    block
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct WindowIdentity {
    hwnd: u64,
    pid: u32,
    creation: u64,
    class: String,
}

fn hwnd_ptr(hwnd: u64) -> *mut core::ffi::c_void {
    hwnd as usize as *mut core::ffi::c_void
}

fn window_class_name(hwnd: *mut core::ffi::c_void) -> String {
    if hwnd.is_null() {
        return String::new();
    }
    let mut class = [0u16; 256];
    let count = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), 256) };
    if count > 0 {
        String::from_utf16_lossy(&class[..count as usize])
    } else {
        String::new()
    }
}

fn window_title_text(hwnd: *mut core::ffi::c_void) -> String {
    if hwnd.is_null() {
        return String::new();
    }
    let mut buf = [0u16; 256];
    let n = unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), 256) };
    if n > 0 {
        String::from_utf16_lossy(&buf[..n as usize])
    } else {
        String::new()
    }
}

fn window_identity(hwnd: *mut core::ffi::c_void) -> Option<WindowIdentity> {
    if hwnd.is_null() || unsafe { IsWindow(hwnd) } == 0 {
        return None;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    if pid == 0 {
        return None;
    }
    let class = window_class_name(hwnd);
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() {
        return None;
    }
    let creation = process_creation(handle);
    unsafe {
        let _ = CloseHandle(handle);
    }
    Some(WindowIdentity {
        hwnd: hwnd as usize as u64,
        pid,
        creation: creation?,
        class,
    })
}

fn foreground_identity() -> Option<WindowIdentity> {
    window_identity(unsafe { GetForegroundWindow() })
}

fn identity_live(identity: &WindowIdentity) -> bool {
    window_identity(hwnd_ptr(identity.hwnd)).as_ref() == Some(identity)
}

fn identities_equal(left: &WindowIdentity, right: &WindowIdentity) -> bool {
    left == right
}

fn identity_json(identity: Option<&WindowIdentity>) -> Value {
    match identity {
        Some(identity) => json!({
            "hwnd": identity.hwnd,
            "pid": identity.pid,
            "creation": identity.creation,
            "class": identity.class,
        }),
        None => Value::Null,
    }
}

fn class_is_console(class: &str) -> bool {
    class.eq_ignore_ascii_case(CONSOLE_WINDOW_CLASS)
}

fn class_is_cascadia(class: &str) -> bool {
    let lower = class.to_ascii_lowercase();
    lower.contains("cascadia")
}

fn title_matches_owner_cli(title: &str) -> bool {
    let trimmed = title.trim();
    trimmed == OWNER_CLI_TITLE || trimmed.starts_with(OWNER_CLI_TITLE)
}

fn open_owned_process(pid: u32) -> Result<(u64, *mut core::ffi::c_void), u32> {
    let handle = unsafe {
        OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,
            0,
            pid,
        )
    };
    if handle.is_null() {
        return Err(unsafe { GetLastError() });
    }
    let observed_pid = unsafe { GetProcessId(handle) };
    if observed_pid != pid {
        unsafe {
            let _ = CloseHandle(handle);
        }
        return Err(ERROR_INVALID_PARAMETER);
    }
    match process_creation(handle) {
        Some(creation) => Ok((creation, handle)),
        None => {
            let gle = unsafe { GetLastError() };
            unsafe {
                let _ = CloseHandle(handle);
            }
            Err(if gle == 0 {
                ERROR_INVALID_PARAMETER
            } else {
                gle
            })
        }
    }
}

fn bind_console_host(
    client_pid: u32,
    client_creation: u64,
) -> Option<(u32, u64, *mut core::ffi::c_void)> {
    let host_pid = console_host_pid(client_pid)?;
    if host_pid == 0 {
        return None;
    }
    match open_owned_process(host_pid) {
        Ok((creation, handle)) => {
            if creation < client_creation && host_pid != client_pid {
                unsafe {
                    let _ = CloseHandle(handle);
                }
                return None;
            }
            Some((host_pid, creation, handle))
        }
        Err(_) => None,
    }
}

struct OwnedHost {
    exe: String,
    launcher: String,
    argv: Vec<String>,
    command_line: String,
    process: *mut core::ffi::c_void,
    pid: u32,
    tid: u32,
    creation: u64,
    console_host_process: *mut core::ffi::c_void,
    console_host_pid: u32,
    console_host_tid: u32,
    console_host_creation: u64,
    desktop: DesktopMeta,
    isolation_dir: PathBuf,
}

fn system_conhost_exe() -> PathBuf {
    let root = std::env::var_os("SystemRoot").unwrap_or_else(|| OsString::from(r"C:\Windows"));
    PathBuf::from(root).join("System32").join("conhost.exe")
}

fn process_image_path(handle: *mut core::ffi::c_void) -> Option<String> {
    if handle.is_null() {
        return None;
    }
    let mut buf = [0u16; 1024];
    let mut size = buf.len() as u32;
    let ok = unsafe { QueryFullProcessImageNameW(handle, 0, buf.as_mut_ptr(), &mut size) };
    if ok == 0 || size == 0 {
        return None;
    }
    Some(String::from_utf16_lossy(&buf[..size as usize]))
}

fn strip_win32_extended_path_prefix(path: &str) -> &str {
    path.strip_prefix(r"\\?\").unwrap_or(path)
}

fn owned_image_path_matches(image: Option<&str>, expected: &Path) -> bool {
    let Some(image) = image else {
        return false;
    };
    if image.is_empty() {
        return false;
    }
    let want = expected.to_string_lossy();
    if want.is_empty() {
        return false;
    }
    strip_win32_extended_path_prefix(image)
        .eq_ignore_ascii_case(strip_win32_extended_path_prefix(want.as_ref()))
}

#[cfg(test)]
mod owned_image_path_prefix_safety {
    use super::{owned_image_path_matches, strip_win32_extended_path_prefix};
    use std::path::Path;

    #[test]
    fn japanese_absolute_path_is_safe_and_matches() {
        let expected = Path::new(r"C:\検証\winsmux.exe");
        assert_eq!(
            strip_win32_extended_path_prefix(r"C:\検証\winsmux.exe"),
            r"C:\検証\winsmux.exe"
        );
        assert_eq!(
            strip_win32_extended_path_prefix(r"\\?\C:\検証\winsmux.exe"),
            r"C:\検証\winsmux.exe"
        );
        assert!(owned_image_path_matches(
            Some(r"C:\検証\winsmux.exe"),
            expected
        ));
        assert!(owned_image_path_matches(
            Some(r"\\?\C:\検証\winsmux.exe"),
            expected
        ));
    }

    #[test]
    fn short_and_multibyte_nonmatching_strings_do_not_panic() {
        let expected = Path::new(r"C:\検証\winsmux.exe");
        assert_eq!(strip_win32_extended_path_prefix(""), "");
        assert_eq!(strip_win32_extended_path_prefix("a"), "a");
        assert_eq!(strip_win32_extended_path_prefix("abc"), "abc");
        assert_eq!(strip_win32_extended_path_prefix("abcd"), "abcd");
        assert_eq!(strip_win32_extended_path_prefix("あ"), "あ");
        assert_eq!(strip_win32_extended_path_prefix("あい"), "あい");
        assert_eq!(strip_win32_extended_path_prefix("検証"), "検証");
        assert!(!owned_image_path_matches(None, expected));
        assert!(!owned_image_path_matches(Some(""), expected));
        assert!(!owned_image_path_matches(Some("a"), expected));
        assert!(!owned_image_path_matches(Some("あ"), expected));
        assert!(!owned_image_path_matches(Some("あい"), expected));
        assert!(!owned_image_path_matches(Some("検証"), expected));
        assert!(!owned_image_path_matches(
            Some(r"検証\winsmux.exe"),
            expected
        ));
    }

    #[test]
    fn relative_directory_and_ascii_case_remain_exact_and_safe() {
        let relative = Path::new(r"検証\winsmux.exe");
        assert!(owned_image_path_matches(
            Some(r"検証\winsmux.exe"),
            relative
        ));
        assert!(!owned_image_path_matches(
            Some(r"C:\検証\winsmux.exe"),
            relative
        ));
        let expected = Path::new(r"C:\検証\winsmux.exe");
        assert!(!owned_image_path_matches(
            Some(r"C:\他\winsmux.exe"),
            expected
        ));
        let ascii = Path::new(r"C:\Program Files\winsmux.exe");
        assert!(owned_image_path_matches(
            Some(r"c:\program files\winsmux.exe"),
            ascii
        ));
        assert!(owned_image_path_matches(
            Some(r"\\?\c:\program files\winsmux.exe"),
            ascii
        ));
        assert!(!owned_image_path_matches(
            Some(r"C:\Other\winsmux.exe"),
            ascii
        ));
    }
}

fn find_child_client(parent_pid: u32, exe: &Path) -> Option<(u32, u64, *mut core::ffi::c_void)> {
    if parent_pid == 0 {
        return None;
    }
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot.is_null() || snapshot == (-1isize as *mut core::ffi::c_void) {
        return None;
    }
    let mut entry = ProcessEntry32W {
        dw_size: std::mem::size_of::<ProcessEntry32W>() as u32,
        cnt_usage: 0,
        th32_process_id: 0,
        th32_default_heap_id: 0,
        th32_module_id: 0,
        cnt_threads: 0,
        th32_parent_process_id: 0,
        pc_pri_class_base: 0,
        dw_flags: 0,
        sz_exe_file: [0; 260],
    };
    let mut found = None;
    let mut ok = unsafe { Process32FirstW(snapshot, &mut entry) };
    while ok != 0 {
        if entry.th32_parent_process_id == parent_pid && entry.th32_process_id != 0 {
            if let Ok((creation, handle)) = open_owned_process(entry.th32_process_id) {
                if owned_image_path_matches(process_image_path(handle).as_deref(), exe) {
                    found = Some((entry.th32_process_id, creation, handle));
                    break;
                }
                unsafe {
                    let _ = CloseHandle(handle);
                }
            }
        }
        ok = unsafe { Process32NextW(snapshot, &mut entry) };
    }
    unsafe {
        let _ = CloseHandle(snapshot);
    }
    found
}

fn spawn_owner_cli(exe: &Path) -> Result<OwnedHost, (u32, String)> {
    let isolation_dir = std::env::temp_dir().join(format!(
        "winsmux-863-owner-cli-env-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    fs::create_dir_all(&isolation_dir).expect("owner CLI isolation directory");
    let mut env_block = isolated_environment(&isolation_dir);
    let launcher = system_conhost_exe();
    if !launcher.is_file() {
        let _ = fs::remove_dir_all(&isolation_dir);
        return Err((ERROR_INVALID_PARAMETER, launcher.display().to_string()));
    }
    let command_line = format!(
        "\"{}\" -- \"{}\" workspace host",
        launcher.display(),
        exe.display()
    );
    let application = wide_os(launcher.as_os_str());
    let mut cmdline = wide_str(&command_line);
    let mut title = wide_str(OWNER_CLI_TITLE);
    let cwd = wide_os(isolation_dir.as_os_str());
    let desktop = own_desktop_metadata();
    let mut startup = StartupInfoW {
        cb: std::mem::size_of::<StartupInfoW>() as u32,
        lp_reserved: ptr::null_mut(),
        lp_desktop: ptr::null_mut(),
        lp_title: title.as_mut_ptr(),
        dw_x: 0,
        dw_y: 0,
        dw_x_size: 0,
        dw_y_size: 0,
        dw_x_count_chars: 0,
        dw_y_count_chars: 0,
        dw_fill_attribute: 0,
        dw_flags: STARTF_USESHOWWINDOW,
        w_show_window: SW_SHOWNORMAL,
        cb_reserved2: 0,
        lp_reserved2: ptr::null_mut(),
        h_std_input: ptr::null_mut(),
        h_std_output: ptr::null_mut(),
        h_std_error: ptr::null_mut(),
    };
    let mut info = ProcessInformation {
        h_process: ptr::null_mut(),
        h_thread: ptr::null_mut(),
        dw_process_id: 0,
        dw_thread_id: 0,
    };
    let ok = unsafe {
        CreateProcessW(
            application.as_ptr(),
            cmdline.as_mut_ptr(),
            ptr::null_mut(),
            ptr::null_mut(),
            0,
            CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT,
            env_block.as_mut_ptr() as *mut core::ffi::c_void,
            cwd.as_ptr(),
            &mut startup,
            &mut info,
        )
    };
    if ok == 0 {
        let gle = unsafe { GetLastError() };
        let _ = fs::remove_dir_all(&isolation_dir);
        return Err((gle, command_line));
    }
    if !info.h_thread.is_null() {
        unsafe {
            let _ = CloseHandle(info.h_thread);
        }
    }
    let console_host_creation = process_creation(info.h_process).unwrap_or(0);
    Ok(OwnedHost {
        exe: exe.display().to_string(),
        launcher: launcher.display().to_string(),
        argv: vec!["workspace".into(), "host".into()],
        command_line,
        process: ptr::null_mut(),
        pid: 0,
        tid: 0,
        creation: 0,
        console_host_process: info.h_process,
        console_host_pid: info.dw_process_id,
        console_host_tid: info.dw_thread_id,
        console_host_creation,
        desktop,
        isolation_dir,
    })
}

fn process_identity_holds(handle: *mut core::ffi::c_void, pid: u32, creation: u64) -> bool {
    if handle.is_null() || pid == 0 {
        return false;
    }
    let live_pid = unsafe { GetProcessId(handle) };
    live_pid == pid && process_creation(handle) == Some(creation)
}

fn identity_holds(host: &OwnedHost) -> bool {
    process_identity_holds(host.process, host.pid, host.creation)
}

fn console_host_holds(host: &OwnedHost) -> bool {
    process_identity_holds(
        host.console_host_process,
        host.console_host_pid,
        host.console_host_creation,
    )
}

fn bind_client_process(host: &mut OwnedHost, exe: &Path) -> bool {
    if identity_holds(host) {
        return true;
    }
    if !host.process.is_null() {
        unsafe {
            let _ = CloseHandle(host.process);
        }
        host.process = ptr::null_mut();
        host.pid = 0;
        host.tid = 0;
        host.creation = 0;
    }
    let Some((pid, creation, handle)) = find_child_client(host.console_host_pid, exe) else {
        return false;
    };
    if creation < host.console_host_creation {
        unsafe {
            let _ = CloseHandle(handle);
        }
        return false;
    }
    host.process = handle;
    host.pid = pid;
    host.creation = creation;
    true
}

#[allow(dead_code)]
fn owned_window_titles(
    hwnds: &[(u32, u64, String, bool)],
) -> Vec<(u32, u64, String, bool, String)> {
    hwnds
        .iter()
        .map(|(pid, hwnd, class, visible)| {
            let title = window_title_text(hwnd_ptr(*hwnd));
            (*pid, *hwnd, class.clone(), *visible, title)
        })
        .collect()
}

fn pick_owned_console(
    hwnds: &[(u32, u64, String, bool, String)],
    family: &[u32],
) -> Result<(u32, u64, String, bool), String> {
    let mut cascadias = Vec::new();
    let mut consoles = Vec::new();
    for (pid, hwnd, class, visible, title) in hwnds {
        let family_ok = family.is_empty() || family.contains(pid);
        let titled = title_matches_owner_cli(title);
        if !family_ok && !titled {
            continue;
        }
        if class_is_cascadia(class) && (titled || family_ok) {
            cascadias.push((*pid, *hwnd, class.clone(), *visible, title.clone()));
            continue;
        }
        if class_is_console(class) && titled {
            consoles.push((*pid, *hwnd, class.clone(), *visible, title.clone()));
        }
    }
    if let Some((pid, hwnd, class, visible, title)) = cascadias.into_iter().next() {
        return Err(format!(
            "CREATE_NEW_CONSOLE produced {class} hwnd={hwnd} pid={pid} visible={visible} title={title:?}; ConsoleWindowClass host prerequisite is unmet"
        ));
    }
    consoles.sort_by_key(|(pid, _, _, _, _)| !family.contains(pid));
    consoles
        .into_iter()
        .next()
        .map(|(pid, hwnd, class, visible, _)| (pid, hwnd, class, visible))
        .ok_or_else(|| {
            "no ConsoleWindowClass HWND with owner-cli title in the owned family".to_owned()
        })
}

fn terminate_owned_identity(
    handle: *mut core::ffi::c_void,
    pid: u32,
    creation: u64,
) -> Result<(), String> {
    let mut owned = handle;
    let mut opened = false;
    if owned.is_null() {
        match open_owned_process(pid) {
            Ok((observed, handle)) => {
                if observed != creation {
                    unsafe {
                        let _ = CloseHandle(handle);
                    }
                    return Err(format!(
                        "creation mismatch for pid={pid}: live={observed} owned={creation}; refusing PID-only TerminateProcess"
                    ));
                }
                owned = handle;
                opened = true;
            }
            Err(gle) if gle == ERROR_INVALID_PARAMETER => {
                return Err(format!(
                    "OpenProcess gle=87 for pid={pid} creation={creation}; identity loss, not ordinary close"
                ));
            }
            Err(_) => return Ok(()),
        }
    }
    let live_pid = unsafe { GetProcessId(owned) };
    let live_creation = process_creation(owned);
    let matched = live_pid == pid && live_creation == Some(creation);
    if matched {
        unsafe {
            let _ = TerminateProcess(owned, 1);
        }
    }
    if opened {
        unsafe {
            let _ = CloseHandle(owned);
        }
    }
    if matched {
        Ok(())
    } else {
        Err(format!(
            "creation mismatch or HWND/process reuse for pid={pid} creation={creation} live_pid={live_pid} live_creation={live_creation:?}; refusing PID-only TerminateProcess"
        ))
    }
}

#[allow(dead_code)]
fn consoles_are_shared(launched_pid: u32) -> bool {
    let self_host = console_host_pid(std::process::id());
    let launched_host = console_host_pid(launched_pid);
    match (self_host, launched_host) {
        (Some(self_host), Some(launched_host)) => self_host == launched_host,
        _ => true,
    }
}

fn write_cua_acquire_evidence(value: &Value) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("verification-evidence")
        .join("cua-acquire-last.json");
    if let Ok(bytes) = serde_json::to_vec_pretty(value) {
        let _ = fs::write(path, bytes);
    }
}

struct EnumTopLevelWindows {
    pids: [u32; 4],
    pid_count: usize,
    filter_pids: bool,
    found: Vec<(u32, u64, String, bool, String)>,
}

unsafe extern "system" fn enum_top_level_windows(
    hwnd: *mut core::ffi::c_void,
    lparam: isize,
) -> i32 {
    if hwnd.is_null() {
        return 1;
    }
    let state = unsafe { &mut *(lparam as *mut EnumTopLevelWindows) };
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    if state.filter_pids && !(0..state.pid_count).any(|index| state.pids[index] == pid) {
        return 1;
    }
    let class_name = window_class_name(hwnd);
    let title = window_title_text(hwnd);
    let visible = unsafe { IsWindowVisible(hwnd) } != 0;
    state
        .found
        .push((pid, hwnd as usize as u64, class_name, visible, title));
    1
}

fn top_level_windows(pids: Option<&[u32]>) -> Vec<(u32, u64, String, bool, String)> {
    let mut state = EnumTopLevelWindows {
        pids: [0; 4],
        pid_count: 0,
        filter_pids: false,
        found: Vec::new(),
    };
    if let Some(pids) = pids {
        state.filter_pids = true;
        state.pid_count = pids.len().min(4);
        for (index, pid) in pids.iter().take(4).enumerate() {
            state.pids[index] = *pid;
        }
    }
    unsafe {
        EnumWindows(
            Some(enum_top_level_windows),
            &mut state as *mut EnumTopLevelWindows as isize,
        );
    }
    state.found
}

#[allow(dead_code)]
fn owned_top_level_windows(pids: &[u32]) -> Vec<(u32, u64, String, bool)> {
    top_level_windows(Some(pids))
        .into_iter()
        .map(|(pid, hwnd, class, visible, _)| (pid, hwnd, class, visible))
        .collect()
}

fn discover_family_windows(family: &[u32]) -> Vec<(u32, u64, String, bool, String)> {
    let mut found = top_level_windows(Some(family));
    let titled = top_level_windows(None)
        .into_iter()
        .filter(|(_, _, _, _, title)| title_matches_owner_cli(title));
    for window in titled {
        if !found.iter().any(|row| row.1 == window.1) {
            found.push(window);
        }
    }
    found
}

fn windows_array(listed: &Value) -> Vec<Value> {
    listed
        .get("windows")
        .or_else(|| listed.pointer("/structuredContent/windows"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

#[allow(dead_code)]
fn family_window_ids(listed: &Value, family: &[u64]) -> Vec<(u64, u64)> {
    windows_array(listed)
        .iter()
        .filter_map(|window| {
            let pid = window.get("pid").and_then(Value::as_u64)?;
            if !family.contains(&pid) {
                return None;
            }
            Some((pid, window.get("window_id").and_then(Value::as_u64)?))
        })
        .collect()
}

fn cua_driver_bin() -> PathBuf {
    let local = PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_default())
        .join(r"Programs\Cua\cua-driver\bin\cua-driver.exe");
    if local.is_file() {
        local
    } else {
        PathBuf::from("cua-driver")
    }
}

fn cua_call(tool: &str, args: Value) -> (i32, String, String) {
    let mut child = Command::new(cua_driver_bin())
        .args(["call", tool])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| panic!("spawn cua-driver {tool}: {error}"));
    child
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(args.to_string().as_bytes())
        .expect("write cua stdin");
    drop(child.stdin.take());
    let call_pid = child.id();
    let (call_creation, call_handle) = match open_owned_process(call_pid) {
        Ok(bound) => bound,
        Err(_) => (0, ptr::null_mut()),
    };
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let output = child.wait_with_output();
        let _ = tx.send(output);
    });
    match rx.recv_timeout(Duration::from_secs(20)) {
        Ok(Ok(output)) => {
            if !call_handle.is_null() {
                unsafe {
                    let _ = CloseHandle(call_handle);
                }
            }
            (
                output.status.code().unwrap_or(1),
                String::from_utf8_lossy(&output.stdout).into_owned(),
                String::from_utf8_lossy(&output.stderr).into_owned(),
            )
        }
        Ok(Err(error)) => {
            if !call_handle.is_null() {
                unsafe {
                    let _ = CloseHandle(call_handle);
                }
            }
            panic!("wait cua-driver {tool}: {error}")
        }
        Err(_) => {
            let _ = terminate_owned_identity(call_handle, call_pid, call_creation);
            if !call_handle.is_null() {
                unsafe {
                    let _ = CloseHandle(call_handle);
                }
            }
            panic!("cua-driver {tool} exceeded 20s");
        }
    }
}

fn cua_json(tool: &str, args: Value) -> Value {
    let (code, stdout, stderr) = cua_call(tool, args.clone());
    assert_eq!(
        code, 0,
        "cua-driver {tool} exit {code} args={args} stdout={stdout} stderr={stderr}"
    );
    serde_json::from_str(&stdout).unwrap_or_else(|error| {
        panic!("cua-driver {tool} JSON parse {error}: stdout={stdout} stderr={stderr}")
    })
}

fn ensure_cua_service() {
    let bin = cua_driver_bin();
    let first = Command::new(&bin)
        .args(["status"])
        .output()
        .unwrap_or_else(|error| panic!("cua-driver status: {error}"));
    let first_text = format!(
        "{}{}",
        String::from_utf8_lossy(&first.stdout),
        String::from_utf8_lossy(&first.stderr)
    );
    if first.status.success() && !first_text.contains("not running") {
        return;
    }
    panic!(
        "host-owned cua-driver is not already running; fixture must not serve or stop: {first_text}"
    );
}

fn json_values_in(text: &str) -> Vec<Value> {
    let mut values = Vec::new();
    let bytes = text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'{' {
            index += 1;
            continue;
        }
        let mut depth = 0usize;
        let mut in_string = false;
        let mut escaped = false;
        for end in index..bytes.len() {
            let byte = bytes[end];
            if in_string {
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    in_string = false;
                }
                continue;
            }
            match byte {
                b'"' => in_string = true,
                b'{' => depth += 1,
                b'}' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        if let Ok(value) = serde_json::from_slice::<Value>(&bytes[index..=end]) {
                            values.push(value);
                        }
                        index = end;
                        break;
                    }
                }
                _ => {}
            }
        }
        index += 1;
    }
    values
}

fn snapshot_text(state: &Value) -> String {
    let mut parts = Vec::new();
    if let Some(tree) = state.get("tree_markdown").and_then(Value::as_str) {
        parts.push(tree.to_owned());
    }
    if let Some(tree) = state
        .pointer("/structuredContent/tree_markdown")
        .and_then(Value::as_str)
    {
        parts.push(tree.to_owned());
    }
    parts.push(state.to_string());
    parts.join("\n")
}

fn cua_root(value: &Value) -> &Value {
    value
        .get("structuredContent")
        .or_else(|| value.get("result"))
        .unwrap_or(value)
}

fn cua_bool(value: &Value, key: &str) -> Option<bool> {
    cua_root(value)
        .get(key)
        .and_then(Value::as_bool)
        .or_else(|| value.get(key).and_then(Value::as_bool))
}

fn cua_text_field(value: &Value) -> Option<String> {
    let root = cua_root(value);
    for key in ["text", "content", "clipboard_text", "value"] {
        if let Some(text) = root.get(key).and_then(Value::as_str) {
            return Some(text.to_owned());
        }
        if let Some(text) = value.get(key).and_then(Value::as_str) {
            return Some(text.to_owned());
        }
    }
    None
}

fn parse_cua_value(stdout: &str) -> Option<Value> {
    let trimmed = stdout.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return Some(value);
    }
    json_values_in(stdout).into_iter().next()
}

/// Public Cua session identity is `args.session` (input/daemon.rs), not transport `session_id`.
/// The live fixture consumes the CLI run_call body: one JSON object (structuredContent printed
/// as stdout). Session interpretation never merges outer/inner fields and never uses generic
/// cua_root/cua_bool fallbacks. Start must itself prove matching session + active true.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SessionOutcome {
    Active,
    Inactive,
    Ending,
    Absent,
    EndedRejected,
    TransportFailed,
    Failed,
    Malformed,
    WrongSession,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SessionOperation {
    Start,
    Get,
    End,
}

const SESSION_AUTHORITATIVE_KEYS: [&str; 7] = [
    "session", "active", "state", "code", "error", "ok", "isError",
];

fn session_select_authoritative_body(parsed: &Value) -> Result<&Value, SessionOutcome> {
    let Some(object) = parsed.as_object() else {
        return Err(SessionOutcome::Malformed);
    };
    match object.get("structuredContent") {
        Some(inner) if inner.is_object() => {
            let outer_has_authority = SESSION_AUTHORITATIVE_KEYS
                .iter()
                .any(|key| object.contains_key(*key));
            if outer_has_authority {
                Err(SessionOutcome::Malformed)
            } else {
                Ok(inner)
            }
        }
        Some(_) => Err(SessionOutcome::Malformed),
        None => Ok(parsed),
    }
}

fn session_field_str<'a>(body: &'a Value, key: &str) -> Result<Option<&'a str>, SessionOutcome> {
    match body.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                Err(SessionOutcome::Malformed)
            } else {
                Ok(Some(trimmed))
            }
        }
        Some(_) => Err(SessionOutcome::Malformed),
    }
}

fn session_field_bool(body: &Value, key: &str) -> Result<Option<bool>, SessionOutcome> {
    match body.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(SessionOutcome::Malformed),
    }
}

fn session_explicit_error(body: &Value) -> Result<bool, SessionOutcome> {
    let error = match body.get("error") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::String(text)) if text.is_empty() => false,
        Some(_) => true,
    };
    let ok_false = match body.get("ok") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(ok)) => !ok,
        Some(_) => return Err(SessionOutcome::Malformed),
    };
    let is_error = match body.get("isError") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(_) => return Err(SessionOutcome::Malformed),
    };
    Ok(error || ok_false || is_error)
}

fn session_state_value(body: &Value) -> Result<Option<&str>, SessionOutcome> {
    match session_field_str(body, "state")? {
        None => Ok(None),
        Some("active") => Ok(Some("active")),
        Some("ending") => Ok(Some("ending")),
        Some(_) => Err(SessionOutcome::Malformed),
    }
}

fn session_authoritative_conflict(active: Option<bool>, state: Option<&str>) -> bool {
    matches!(
        (active, state),
        (Some(true), Some("ending"))
            | (Some(false), Some("active"))
            | (Some(false), Some("ending"))
    )
}

fn session_has_cleanup_claim(body: &Value) -> bool {
    [
        "cleanup_pending",
        "cleanup_partial",
        "session_cleanup_pending",
        "session_cleanup_partial",
    ]
    .iter()
    .any(|key| match body.get(*key) {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::String(text)) if text.is_empty() => false,
        Some(_) => true,
    })
}

fn interpret_start_session(
    requested: &str,
    code: i32,
    stdout: &str,
    stderr: &str,
) -> SessionOutcome {
    interpret_session_response(SessionOperation::Start, requested, code, stdout, stderr)
}

fn interpret_get_session(requested: &str, code: i32, stdout: &str, stderr: &str) -> SessionOutcome {
    interpret_session_response(SessionOperation::Get, requested, code, stdout, stderr)
}

fn interpret_end_session(requested: &str, code: i32, stdout: &str, stderr: &str) -> SessionOutcome {
    interpret_session_response(SessionOperation::End, requested, code, stdout, stderr)
}

fn session_ended_get_rejected_message(session: &str) -> String {
    format!(
        "session '{session}' has ended; tool call 'get_session' was rejected. Call start_session with this id to revive it before issuing further actions, or use a new session id."
    )
}

fn stderr_is_ended_get_rejected(stderr: &str, session: &str) -> bool {
    let expected = session_ended_get_rejected_message(session);
    let body = stderr
        .strip_suffix("\r\n")
        .or_else(|| stderr.strip_suffix('\n'))
        .unwrap_or(stderr);
    body == expected
}

fn get_session_cli_is_ended_rejection(
    requested: &str,
    code: i32,
    stdout: &str,
    stderr: &str,
) -> bool {
    code == 1 && stdout.is_empty() && stderr_is_ended_get_rejected(stderr, requested)
}

fn interpret_session_response(
    operation: SessionOperation,
    requested: &str,
    code: i32,
    stdout: &str,
    stderr: &str,
) -> SessionOutcome {
    if operation == SessionOperation::Get
        && get_session_cli_is_ended_rejection(requested, code, stdout, stderr)
    {
        return SessionOutcome::EndedRejected;
    }
    if code != 0 {
        return SessionOutcome::TransportFailed;
    }
    let Some(parsed) = parse_cua_value(stdout) else {
        return SessionOutcome::Malformed;
    };
    let body = match session_select_authoritative_body(&parsed) {
        Ok(body) => body,
        Err(outcome) => return outcome,
    };
    let session_name = match session_field_str(body, "session") {
        Ok(name) => name,
        Err(outcome) => return outcome,
    };
    let active = match session_field_bool(body, "active") {
        Ok(active) => active,
        Err(outcome) => return outcome,
    };
    let state = match session_state_value(body) {
        Ok(state) => state,
        Err(outcome) => return outcome,
    };
    let structured_code = match session_field_str(body, "code") {
        Ok(code) => code,
        Err(outcome) => return outcome,
    };
    let explicit_error = match session_explicit_error(body) {
        Ok(flag) => flag,
        Err(outcome) => return outcome,
    };
    if session_authoritative_conflict(active, state) {
        return SessionOutcome::Malformed;
    }
    if operation == SessionOperation::Get && structured_code == Some("session_not_started") {
        if explicit_error || active.is_some() || state.is_some() || session_has_cleanup_claim(body)
        {
            return SessionOutcome::Malformed;
        }
        if session_name.is_some_and(|name| name != requested) {
            return SessionOutcome::WrongSession;
        }
        return SessionOutcome::Absent;
    }
    if structured_code.is_some() || explicit_error {
        return SessionOutcome::Failed;
    }
    if session_name.is_some_and(|name| name != requested) {
        return SessionOutcome::WrongSession;
    }
    match operation {
        SessionOperation::Start => match (session_name, active) {
            (Some(_), Some(true)) => SessionOutcome::Active,
            (Some(_), Some(false)) => SessionOutcome::Inactive,
            _ => SessionOutcome::Malformed,
        },
        SessionOperation::Get => match (session_name, state) {
            (Some(_), Some("active")) => SessionOutcome::Active,
            (Some(_), Some("ending")) => SessionOutcome::Ending,
            _ => SessionOutcome::Malformed,
        },
        SessionOperation::End => match (session_name, active, state) {
            (Some(_), Some(false), None) => SessionOutcome::Inactive,
            (Some(_), Some(true), None) => SessionOutcome::Active,
            _ => SessionOutcome::Malformed,
        },
    }
}

fn session_start_is_proven(outcome: SessionOutcome) -> bool {
    outcome == SessionOutcome::Active
}

fn session_start_accepted(start: SessionOutcome, follow_up_get_activity: Option<bool>) -> bool {
    let _ = follow_up_get_activity;
    session_start_is_proven(start)
}

fn session_end_body_is_inactive(outcome: SessionOutcome) -> bool {
    outcome == SessionOutcome::Inactive
}

fn session_get_is_active(outcome: SessionOutcome) -> bool {
    outcome == SessionOutcome::Active
}

fn session_get_is_ending(outcome: SessionOutcome) -> bool {
    outcome == SessionOutcome::Ending
}

fn session_get_is_recognized_absence(outcome: SessionOutcome) -> bool {
    outcome == SessionOutcome::Absent
}

fn session_get_is_ended_rejection(outcome: SessionOutcome) -> bool {
    outcome == SessionOutcome::EndedRejected
}

fn session_get_activity(outcome: SessionOutcome) -> Option<bool> {
    match outcome {
        SessionOutcome::Active => Some(true),
        SessionOutcome::Ending => Some(false),
        _ => None,
    }
}

fn session_end_cleanup_is_complete(ended: SessionOutcome, after: SessionOutcome) -> bool {
    session_end_body_is_inactive(ended) && session_get_is_ended_rejection(after)
}

fn session_post_end_is_recognized_absence(outcome: SessionOutcome) -> bool {
    session_get_is_ended_rejection(outcome)
}

fn session_post_end_is_not_proof(outcome: SessionOutcome) -> bool {
    !session_post_end_is_recognized_absence(outcome)
}

fn cua_elements(state: &Value) -> Vec<Value> {
    let root = cua_root(state);
    root.get("elements")
        .or_else(|| state.get("elements"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn element_actions(element: &Value) -> Vec<String> {
    element
        .get("actions")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MenuStage {
    Open,
    Leaf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MenuTarget {
    snapshot_id: String,
    element_index: u64,
    element_token: String,
    actions: Vec<String>,
    label: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MenuLookupError {
    Missing,
    Ambiguous,
    Stale,
    IncompleteIdentity,
    WrongWindow,
}

fn snapshot_id_of(state: &Value) -> Option<String> {
    let root = cua_root(state);
    for candidate in [root.get("snapshot_id"), state.get("snapshot_id")] {
        if let Some(text) = candidate
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
        {
            return Some(text.to_owned());
        }
    }
    None
}

fn has_named_action(actions: &[String], name: &str) -> bool {
    actions
        .iter()
        .any(|action| action.eq_ignore_ascii_case(name))
}

fn menu_stage_supported(actions: &[String], stage: MenuStage) -> bool {
    match stage {
        MenuStage::Open => {
            has_named_action(actions, "expand") || has_named_action(actions, "invoke")
        }
        MenuStage::Leaf => {
            has_named_action(actions, "invoke")
                || has_named_action(actions, "toggle")
                || has_named_action(actions, "select")
        }
    }
}

fn find_menu_target(
    state: &Value,
    needle: &str,
    window_id: Option<u64>,
) -> Result<MenuTarget, MenuLookupError> {
    let snapshot_id = match snapshot_id_of(state) {
        Some(snapshot_id) => snapshot_id,
        None => {
            let labeled_menu_item = cua_elements(state).into_iter().any(|element| {
                let label = element.get("label").and_then(Value::as_str).unwrap_or("");
                let role = element.get("role").and_then(Value::as_str).unwrap_or("");
                label.contains(needle) && role.eq_ignore_ascii_case("MenuItem")
            });
            return if labeled_menu_item {
                Err(MenuLookupError::IncompleteIdentity)
            } else {
                Err(MenuLookupError::Missing)
            };
        }
    };
    let mut hits = Vec::new();
    let mut stale = false;
    let mut incomplete = false;
    let mut wrong_window = false;
    for element in cua_elements(state) {
        let label = element.get("label").and_then(Value::as_str).unwrap_or("");
        if !label.contains(needle) {
            continue;
        }
        let role = element.get("role").and_then(Value::as_str).unwrap_or("");
        if !role.eq_ignore_ascii_case("MenuItem") {
            continue;
        }
        if let (Some(expected), Some(got)) =
            (window_id, element.get("window_id").and_then(Value::as_u64))
        {
            if got != expected {
                wrong_window = true;
                continue;
            }
        }
        let index = element.get("element_index").and_then(Value::as_u64);
        let token = element
            .get("element_token")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty());
        match (index, token) {
            (Some(index), Some(token)) => {
                if token != format!("{snapshot_id}:{index}") {
                    stale = true;
                    continue;
                }
                hits.push(MenuTarget {
                    snapshot_id: snapshot_id.clone(),
                    element_index: index,
                    element_token: token.to_owned(),
                    actions: element_actions(&element),
                    label: label.to_owned(),
                });
            }
            _ => incomplete = true,
        }
    }
    match hits.len() {
        0 if stale => Err(MenuLookupError::Stale),
        0 if incomplete => Err(MenuLookupError::IncompleteIdentity),
        0 if wrong_window => Err(MenuLookupError::WrongWindow),
        0 => Err(MenuLookupError::Missing),
        1 => Ok(hits.remove(0)),
        _ => Err(MenuLookupError::Ambiguous),
    }
}

fn assert_startup_foreground(t0: Option<&WindowIdentity>, owned_hwnd: Option<u64>, stage: &str) {
    let fg = foreground_identity();
    if let Some(owned) = owned_hwnd {
        if fg.as_ref().is_some_and(|identity| identity.hwnd == owned) {
            panic!("{stage}: owned ConsoleWindowClass HWND became foreground");
        }
    }
    match t0 {
        Some(t0) if identity_live(t0) => {
            let Some(fg) = fg else {
                panic!("{stage}: T0 is live but foreground is empty");
            };
            if !identities_equal(t0, &fg) {
                panic!(
                    "{stage}: T0 is live so FG must equal T0 identity HWND+pid+creation+class; fg={fg:?} t0={t0:?}"
                );
            }
        }
        Some(_) | None => {
            if let Some(fg) = fg {
                if owned_hwnd == Some(fg.hwnd) {
                    panic!("{stage}: owned HWND is foreground after T0 left");
                }
            }
        }
    }
}

fn show_owned_without_activate(hwnd: u64) {
    let shown = unsafe { ShowWindow(hwnd_ptr(hwnd), SW_SHOWNA) };
    let _ = shown;
}

fn clipboard_read_text(session: &str) -> Option<String> {
    let (code, stdout, _stderr) = cua_call(
        "clipboard_read",
        json!({ "session": session, "include_text": true }),
    );
    if code != 0 {
        return None;
    }
    parse_cua_value(&stdout).and_then(|value| cua_text_field(&value))
}

fn clipboard_write_text(session: &str, text: &str) -> (i32, String, String) {
    cua_call(
        "clipboard_write",
        json!({ "session": session, "text": text }),
    )
}

struct ClipboardGuard {
    session: String,
    preimage: Option<String>,
    ours: Option<String>,
}

impl ClipboardGuard {
    fn capture(session: &str) -> Self {
        Self {
            session: session.to_owned(),
            preimage: clipboard_read_text(session),
            ours: None,
        }
    }

    fn write_owned(&mut self, text: &str) {
        let (code, stdout, stderr) = clipboard_write_text(&self.session, text);
        assert_eq!(
            code, 0,
            "clipboard_write of owned paste payload failed: exit={code} stdout={stdout} stderr={stderr}"
        );
        let readback = clipboard_read_text(&self.session);
        assert_eq!(
            readback.as_deref(),
            Some(text),
            "clipboard_read did not match the owned paste payload: {readback:?}"
        );
        self.ours = Some(text.to_owned());
    }

    fn restore_if_owned(&mut self) {
        let Some(ours) = self.ours.clone() else {
            return;
        };
        let current = clipboard_read_text(&self.session);
        if current.as_deref() != Some(ours.as_str()) {
            self.ours = None;
            return;
        }
        match &self.preimage {
            Some(preimage) => {
                let (code, stdout, stderr) = clipboard_write_text(&self.session, preimage);
                if code == 0 {
                    let readback = clipboard_read_text(&self.session);
                    if readback.as_deref() == Some(preimage.as_str()) {
                        self.ours = None;
                    } else {
                        let _ = (stdout, stderr);
                    }
                }
            }
            None => {
                let _ = clipboard_write_text(&self.session, "");
                self.ours = None;
            }
        }
    }
}

impl Drop for ClipboardGuard {
    fn drop(&mut self) {
        self.restore_if_owned();
    }
}

struct SessionGuard {
    session: String,
    ended: bool,
}

impl SessionGuard {
    fn start(session: &str) -> Self {
        let (code, stdout, stderr) = cua_call("start_session", json!({ "session": session }));
        assert_eq!(
            code, 0,
            "start_session failed: exit={code} stdout={stdout} stderr={stderr}"
        );
        let started = interpret_start_session(session, code, &stdout, &stderr);
        assert!(
            session_start_accepted(started, None),
            "start_session must itself prove matching session + active true; malformed/failed/wrong-session/inactive/transport start is never repaired by get_session: start={started:?} stdout={stdout} stderr={stderr}"
        );
        Self {
            session: session.to_owned(),
            ended: false,
        }
    }

    fn end_asserted(&mut self) {
        let (code, stdout, stderr) = cua_call("end_session", json!({ "session": self.session }));
        assert_eq!(
            code, 0,
            "end_session failed: exit={code} stdout={stdout} stderr={stderr}"
        );
        let ended = interpret_end_session(&self.session, code, &stdout, &stderr);
        assert!(
            session_end_body_is_inactive(ended),
            "end_session must return matching session and active false; ending/absent/error/transport/wrong-session/malformed cannot complete cleanup: {ended:?} stdout={stdout} stderr={stderr}"
        );
        let (get_code, get_stdout, get_stderr) =
            cua_call("get_session", json!({ "session": self.session }));
        let after = interpret_get_session(&self.session, get_code, &get_stdout, &get_stderr);
        assert!(
            session_end_cleanup_is_complete(ended, after),
            "after end_session, get_session must be the serve.rs ended rejection for this id (exit 1, empty stdout, exact has-ended/get_session-rejected stderr); never-started session_not_started is not ended: end={ended:?} after={after:?} exit={get_code} stdout={get_stdout} stderr={get_stderr}"
        );
        self.ended = true;
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        if !self.ended {
            let _ = cua_call("end_session", json!({ "session": self.session }));
            self.ended = true;
        }
    }
}

fn get_session_active(session: &str) -> Option<bool> {
    let (code, stdout, stderr) = cua_call("get_session", json!({ "session": session }));
    session_get_activity(interpret_get_session(session, code, &stdout, &stderr))
}

fn snapshot_window(pid: u64, window_id: u64, session: &str) -> Value {
    cua_json(
        "get_window_state",
        json!({
            "pid": pid,
            "window_id": window_id,
            "session": session,
            "include_screenshot": false
        }),
    )
}

fn click_structured_body(parsed: &Value) -> &Value {
    cua_root(parsed)
}

fn click_path_field(parsed: &Value) -> Option<&str> {
    let root = click_structured_body(parsed);
    root.get("path")
        .and_then(Value::as_str)
        .or_else(|| parsed.get("path").and_then(Value::as_str))
}

fn click_route_is_forbidden(path: &str) -> bool {
    matches!(
        path.to_ascii_lowercase().as_str(),
        "pixel" | "post_message" | "msaa"
    )
}

fn click_route_is_ax_semantic(path: &str) -> bool {
    let path = path.to_ascii_lowercase();
    path == "ax" || path == "uia_expand_collapse"
}

fn click_tool_result_proves_effect(parsed: &Value) -> bool {
    let root = click_structured_body(parsed);
    let verified = root
        .get("verified")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let effect = root.get("effect").and_then(Value::as_str).unwrap_or("");
    verified && !effect.is_empty() && !effect.eq_ignore_ascii_case("unverifiable")
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ClickRoute {
    Ax,
    Forbidden,
    Unparseable,
    Nonzero,
}

fn interpret_click_cli(code: i32, stdout: &str, stderr: &str) -> ClickRoute {
    let _ = stderr;
    if code != 0 {
        return ClickRoute::Nonzero;
    }
    let Some(parsed) = parse_cua_value(stdout) else {
        return ClickRoute::Unparseable;
    };
    let Some(path) = click_path_field(&parsed) else {
        return ClickRoute::Unparseable;
    };
    if click_route_is_forbidden(path) {
        return ClickRoute::Forbidden;
    }
    if click_route_is_ax_semantic(path) {
        ClickRoute::Ax
    } else {
        ClickRoute::Unparseable
    }
}

fn background_menu_click(
    pid: u64,
    window_id: u64,
    session: &str,
    target: &MenuTarget,
    label: &str,
) -> Value {
    let (code, stdout, stderr) = cua_call(
        "click",
        json!({
            "pid": pid,
            "window_id": window_id,
            "session": session,
            "element_index": target.element_index,
            "element_token": target.element_token,
            "snapshot_id": target.snapshot_id,
            "delivery_mode": "background"
        }),
    );
    assert_eq!(
        code, 0,
        "background click of {label} failed: exit={code} stdout={stdout} stderr={stderr}"
    );
    match interpret_click_cli(code, &stdout, &stderr) {
        ClickRoute::Ax => {}
        ClickRoute::Forbidden => panic!(
            "background click of {label} used forbidden pixel/post_message/msaa/synthetic route, not ax: stdout={stdout} stderr={stderr}"
        ),
        ClickRoute::Nonzero | ClickRoute::Unparseable => panic!(
            "background click of {label} did not prove CLI-visible ax semantic path: stdout={stdout} stderr={stderr}"
        ),
    }
    parse_cua_value(&stdout).unwrap_or_else(|| json!({ "stdout": stdout }))
}

fn wait_for_menu_element(
    pid: u64,
    window_id: u64,
    session: &str,
    needle: &str,
    label: &str,
    stage: MenuStage,
) -> (MenuTarget, Value) {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = Value::Null;
    while Instant::now() < deadline {
        last = snapshot_window(pid, window_id, session);
        match find_menu_target(&last, needle, Some(window_id)) {
            Ok(target) if menu_stage_supported(&target.actions, stage) => {
                return (target, last);
            }
            Ok(target) => panic!(
                "{label} MenuItem present without supported {stage:?} action (open=expand|invoke, leaf=invoke|toggle|select): actions={:?} snapshot={}",
                target.actions,
                snapshot_text(&last)
            ),
            Err(MenuLookupError::Missing) => {}
            Err(error) => panic!(
                "{label} {error:?} on a fresh same-window snapshot: {}",
                snapshot_text(&last)
            ),
        }
        thread::sleep(Duration::from_millis(150));
    }
    panic!(
        "{label} token-bearing MenuItem with supported {stage:?} action was not present on a fresh snapshot: {}",
        snapshot_text(&last)
    );
}

const CLSID_CUI_AUTOMATION: Guid = Guid {
    data1: 0xFF48_DBA4,
    data2: 0x60EF,
    data3: 0x4201,
    data4: [0xAA, 0x87, 0x54, 0x10, 0x3E, 0xEF, 0x59, 0x4E],
};

const IID_IUI_AUTOMATION: Guid = Guid {
    data1: 0x30CBE57D,
    data2: 0xD9D0,
    data3: 0x452A,
    data4: [0xAB, 0x13, 0x7A, 0xC5, 0xAC, 0x48, 0x25, 0xEE],
};

const IID_IUI_AUTOMATION_TEXT_PATTERN: Guid = Guid {
    data1: 0x32EBA289,
    data2: 0x3583,
    data3: 0x42C9,
    data4: [0x9C, 0x59, 0x3B, 0x6D, 0x9A, 0x1E, 0x9B, 0x6A],
};

fn create_owned_ui_automation() -> (*mut core::ffi::c_void, i32) {
    const CLSCTX_INPROC_SERVER: u32 = 0x1;
    let mut automation = ptr::null_mut();
    let hr = unsafe {
        CoCreateInstance(
            &CLSID_CUI_AUTOMATION,
            ptr::null_mut(),
            CLSCTX_INPROC_SERVER,
            &IID_IUI_AUTOMATION,
            &mut automation,
        )
    };
    if hr < 0 {
        (ptr::null_mut(), hr)
    } else {
        (automation, hr)
    }
}

fn com_vtbl(object: *mut core::ffi::c_void) -> *mut *mut core::ffi::c_void {
    unsafe { *(object as *mut *mut *mut core::ffi::c_void) }
}

unsafe fn com_release(object: *mut core::ffi::c_void) {
    if object.is_null() {
        return;
    }
    let release: unsafe extern "system" fn(*mut core::ffi::c_void) -> u32 =
        std::mem::transmute(*com_vtbl(object).add(2));
    let _ = release(object);
}

fn bstr_to_string(bstr: *mut u16) -> String {
    if bstr.is_null() {
        return String::new();
    }
    let len = unsafe { SysStringLen(bstr) } as usize;
    let text = unsafe { String::from_utf16_lossy(std::slice::from_raw_parts(bstr, len)) };
    unsafe { SysFreeString(bstr) };
    text
}

fn owned_element_text(element: *mut core::ffi::c_void, iid_text: &Guid) -> String {
    const UIA_TEXT_PATTERN_ID: i32 = 10014;
    if element.is_null() {
        return String::new();
    }
    let get_pattern: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        i32,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(element).add(16)) };
    let mut pattern = ptr::null_mut();
    let got_pattern = unsafe { get_pattern(element, UIA_TEXT_PATTERN_ID, &mut pattern) };
    if got_pattern < 0 || pattern.is_null() {
        return String::new();
    }
    let query_interface: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        *const Guid,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(pattern).add(0)) };
    let mut text_pattern = ptr::null_mut();
    let qi = unsafe { query_interface(pattern, iid_text, &mut text_pattern) };
    unsafe { com_release(pattern) };
    if qi < 0 || text_pattern.is_null() {
        return String::new();
    }
    let get_document_range: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(text_pattern).add(7)) };
    let mut range = ptr::null_mut();
    let got_range = unsafe { get_document_range(text_pattern, &mut range) };
    if got_range < 0 || range.is_null() {
        unsafe { com_release(text_pattern) };
        return String::new();
    }
    let get_text: unsafe extern "system" fn(*mut core::ffi::c_void, i32, *mut *mut u16) -> i32 =
        unsafe { std::mem::transmute(*com_vtbl(range).add(12)) };
    let mut bstr = ptr::null_mut();
    let got_text = unsafe { get_text(range, -1, &mut bstr) };
    let text = if got_text >= 0 {
        bstr_to_string(bstr)
    } else {
        String::new()
    };
    unsafe {
        com_release(range);
        com_release(text_pattern);
    }
    text
}

fn sole_nonempty_owned_document(documents: &[String]) -> String {
    let mut nonempty = documents.iter().filter(|document| !document.is_empty());
    match (nonempty.next(), nonempty.next()) {
        (Some(only), None) => only.clone(),
        _ => String::new(),
    }
}

fn collect_owned_hwnd_subtree_text(hwnd: u64) -> Result<String, i32> {
    const TREE_SCOPE_SUBTREE: i32 = 7;
    let (automation, created) = create_owned_ui_automation();
    if created < 0 || automation.is_null() {
        return Err(created);
    }
    let element_from_handle: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        *mut core::ffi::c_void,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(automation).add(6)) };
    let mut element = ptr::null_mut();
    let got_element = unsafe {
        element_from_handle(
            automation,
            hwnd as usize as *mut core::ffi::c_void,
            &mut element,
        )
    };
    if got_element < 0 || element.is_null() {
        unsafe { com_release(automation) };
        return Ok(String::new());
    }
    let create_true_condition: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(automation).add(21)) };
    let mut condition = ptr::null_mut();
    let got_condition = unsafe { create_true_condition(automation, &mut condition) };
    if got_condition < 0 || condition.is_null() {
        unsafe {
            com_release(element);
            com_release(automation);
        }
        return Ok(String::new());
    }
    let find_all: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        i32,
        *mut core::ffi::c_void,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(element).add(6)) };
    let mut found = ptr::null_mut();
    let got_found = unsafe { find_all(element, TREE_SCOPE_SUBTREE, condition, &mut found) };
    if got_found < 0 || found.is_null() {
        unsafe {
            com_release(condition);
            com_release(element);
            com_release(automation);
        }
        return Ok(String::new());
    }
    let get_length: unsafe extern "system" fn(*mut core::ffi::c_void, *mut i32) -> i32 =
        unsafe { std::mem::transmute(*com_vtbl(found).add(3)) };
    let mut length = 0i32;
    let got_length = unsafe { get_length(found, &mut length) };
    if got_length < 0 || length < 0 {
        unsafe {
            com_release(found);
            com_release(condition);
            com_release(element);
            com_release(automation);
        }
        return Ok(String::new());
    }
    let get_array_element: unsafe extern "system" fn(
        *mut core::ffi::c_void,
        i32,
        *mut *mut core::ffi::c_void,
    ) -> i32 = unsafe { std::mem::transmute(*com_vtbl(found).add(4)) };
    let mut texts = Vec::new();
    for index in 0..length {
        let mut child = ptr::null_mut();
        let got_child = unsafe { get_array_element(found, index, &mut child) };
        if got_child < 0 || child.is_null() {
            continue;
        }
        let child_text = owned_element_text(child, &IID_IUI_AUTOMATION_TEXT_PATTERN);
        unsafe { com_release(child) };
        if !child_text.is_empty() {
            texts.push(child_text);
        }
    }
    unsafe {
        com_release(found);
        com_release(condition);
        com_release(element);
        com_release(automation);
    }
    Ok(sole_nonempty_owned_document(&texts))
}

fn read_owned_window_text(hwnd: u64) -> String {
    if hwnd == 0 {
        return String::new();
    }
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    let hr_init = unsafe { CoInitializeEx(ptr::null_mut(), COINIT_APARTMENTTHREADED) };
    const RPC_E_CHANGED_MODE: i32 = -2147417850;
    if hr_init < 0 && hr_init != RPC_E_CHANGED_MODE {
        return String::new();
    }
    let uninitialize = hr_init >= 0;
    let text = match collect_owned_hwnd_subtree_text(hwnd) {
        Ok(text) => text,
        Err(hr) => {
            if uninitialize {
                unsafe { CoUninitialize() };
            }
            panic!(
                "UI Automation factory failed stage=CoCreateInstance hr={} (0x{:08X})",
                hr,
                hr as u32,
            );
        }
    };
    if uninitialize {
        unsafe { CoUninitialize() };
    }
    text
}

#[test]
fn native_ui_automation_factory_creates_and_releases_interface() {
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const RPC_E_CHANGED_MODE: i32 = -2147417850;
    let hr_init = unsafe { CoInitializeEx(ptr::null_mut(), COINIT_APARTMENTTHREADED) };
    if hr_init < 0 && hr_init != RPC_E_CHANGED_MODE {
        panic!(
            "UI Automation factory failed stage=CoInitializeEx hr={} (0x{:08X})",
            hr_init,
            hr_init as u32,
        );
    }
    let uninitialize = hr_init >= 0;
    let (automation, created) = create_owned_ui_automation();
    if created < 0 || automation.is_null() {
        if uninitialize {
            unsafe { CoUninitialize() };
        }
        panic!(
            "UI Automation factory failed stage=CoCreateInstance hr={} (0x{:08X})",
            created,
            created as u32,
        );
    }
    unsafe { com_release(automation) };
    if uninitialize {
        unsafe { CoUninitialize() };
    }
}

const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;
const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 0x0000_0001;
const FILE_SHARE_WRITE: u32 = 0x0000_0002;
const OPEN_EXISTING: u32 = 3;

fn restore_parent_console() {
    unsafe {
        let _ = FreeConsole();
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

fn read_owned_console_buffer(client_pid: u32) -> (String, u32) {
    unsafe {
        let _ = FreeConsole();
        if AttachConsole(client_pid) == 0 {
            let gle = GetLastError();
            let _ = AttachConsole(ATTACH_PARENT_PROCESS);
            return (String::new(), gle);
        }
    }
    let mut conout: Vec<u16> = "CONOUT$".encode_utf16().chain(std::iter::once(0)).collect();
    let handle = unsafe {
        CreateFileW(
            conout.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            ptr::null_mut(),
            OPEN_EXISTING,
            0,
            ptr::null_mut(),
        )
    };
    if handle.is_null() || handle == (-1isize as *mut core::ffi::c_void) {
        let gle = unsafe { GetLastError() };
        restore_parent_console();
        return (String::new(), gle);
    }
    let mut info = ConsoleScreenBufferInfo {
        size: Coord { x: 0, y: 0 },
        cursor: Coord { x: 0, y: 0 },
        attributes: 0,
        window: SmallRect {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        },
        maximum_window_size: Coord { x: 0, y: 0 },
    };
    if unsafe { GetConsoleScreenBufferInfo(handle, &mut info) } == 0 {
        let gle = unsafe { GetLastError() };
        unsafe {
            let _ = CloseHandle(handle);
        }
        restore_parent_console();
        return (String::new(), gle);
    }
    let rows = (info.cursor.y + 1).clamp(1, info.size.y.max(1));
    let cols = info.size.x.max(1);
    let length = (rows as usize).saturating_mul(cols as usize).min(32_768);
    let mut buf = vec![0u16; length];
    let mut nread = 0u32;
    let ok = unsafe {
        ReadConsoleOutputCharacterW(
            handle,
            buf.as_mut_ptr(),
            length as u32,
            Coord { x: 0, y: 0 },
            &mut nread,
        )
    };
    let gle = if ok == 0 {
        unsafe { GetLastError() }
    } else {
        0
    };
    unsafe {
        let _ = CloseHandle(handle);
    }
    restore_parent_console();
    if ok == 0 {
        return (String::new(), gle);
    }
    let text = String::from_utf16_lossy(&buf[..nread as usize]);
    (text, gle)
}

fn read_owned_console_buffer_all(client_pid: u32) -> (String, u32) {
    unsafe {
        let _ = FreeConsole();
        if AttachConsole(client_pid) == 0 {
            let gle = GetLastError();
            let _ = AttachConsole(ATTACH_PARENT_PROCESS);
            return (String::new(), gle);
        }
    }
    let mut conout: Vec<u16> = "CONOUT$".encode_utf16().chain(std::iter::once(0)).collect();
    let handle = unsafe {
        CreateFileW(
            conout.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            ptr::null_mut(),
            OPEN_EXISTING,
            0,
            ptr::null_mut(),
        )
    };
    if handle.is_null() || handle == (-1isize as *mut core::ffi::c_void) {
        let gle = unsafe { GetLastError() };
        restore_parent_console();
        return (String::new(), gle);
    }
    let mut info = ConsoleScreenBufferInfo {
        size: Coord { x: 0, y: 0 },
        cursor: Coord { x: 0, y: 0 },
        attributes: 0,
        window: SmallRect {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        },
        maximum_window_size: Coord { x: 0, y: 0 },
    };
    if unsafe { GetConsoleScreenBufferInfo(handle, &mut info) } == 0 {
        let gle = unsafe { GetLastError() };
        unsafe {
            let _ = CloseHandle(handle);
        }
        restore_parent_console();
        return (String::new(), gle);
    }
    let rows = info.size.y.max(1);
    let cols = info.size.x.max(1);
    let length = (rows as usize).saturating_mul(cols as usize).min(32_768);
    let mut buf = vec![0u16; length];
    let mut nread = 0u32;
    let ok = unsafe {
        ReadConsoleOutputCharacterW(
            handle,
            buf.as_mut_ptr(),
            length as u32,
            Coord { x: 0, y: 0 },
            &mut nread,
        )
    };
    let gle = if ok == 0 {
        unsafe { GetLastError() }
    } else {
        0
    };
    unsafe {
        let _ = CloseHandle(handle);
    }
    restore_parent_console();
    if ok == 0 {
        return (String::new(), gle);
    }
    let text = String::from_utf16_lossy(&buf[..nread as usize]);
    (text, gle)
}

fn target_evidence_root() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_winsmux"))
        .parent()
        .map(Path::to_path_buf)
        .expect("target dir for CARGO_BIN_EXE_winsmux")
        .join("evidence")
}

fn new_run_evidence_dir() -> PathBuf {
    let root = target_evidence_root();
    fs::create_dir_all(&root).expect("target evidence root");
    let dir = root.join(format!(
        "task864-owner-cli-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    fs::create_dir_all(&dir).expect("run evidence directory");
    fs::canonicalize(&dir).unwrap_or(dir)
}

fn write_run_evidence(dir: &Path, name: &str, value: &Value) {
    if let Ok(bytes) = serde_json::to_vec_pretty(value) {
        let _ = fs::write(dir.join(name), bytes);
    }
}

fn write_immutable_manifest(path: &Path, value: &Value) {
    let bytes = serde_json::to_vec_pretty(value).expect("manifest json");
    fs::write(path, bytes).expect("write immutable manifest");
}

fn print_manifest_path(path: &Path) {
    let mut out = std::io::stdout();
    writeln!(out, "{}", path.display()).expect("print manifest path");
    out.flush().expect("flush manifest path");
}

fn publish_protocol_request(
    dir: &Path,
    seq: u32,
    operation: &str,
    operation_id: &str,
    body: &Value,
) -> PathBuf {
    let path = dir.join(format!("request-{seq:02}-{operation}-{operation_id}.json"));
    let bytes = serde_json::to_vec(body).expect("product protocol request json");
    fs::write(&path, bytes).expect("publish immutable request");
    path
}

struct OwnedConsoleResponseExpect<'a> {
    instance_id: &'a str,
    operation_id: &'a str,
    operation: &'a str,
}

fn owned_console_response_is_accepted(
    value: &Value,
    expect: &OwnedConsoleResponseExpect<'_>,
    data: impl Fn(&Value) -> bool,
) -> bool {
    value.get("schema_version") == Some(&json!(1))
        && value.get("instance_id").and_then(Value::as_str) == Some(expect.instance_id)
        && value.get("operation_id").and_then(Value::as_str) == Some(expect.operation_id)
        && value.get("accepted") == Some(&json!(true))
        && value.get("error") == Some(&Value::Null)
        && value.pointer("/result/operation") == Some(&json!(expect.operation))
        && data(value)
}

fn find_accepted_owned_console_response(
    console_text: &str,
    expect: &OwnedConsoleResponseExpect<'_>,
    data: impl Fn(&Value) -> bool,
    baseline: &[Value],
) -> Option<Value> {
    json_values_in(console_text).into_iter().find(|value| {
        !baseline.iter().any(|prior| prior == value)
            && owned_console_response_is_accepted(value, expect, &data)
    })
}

fn observe_owned_console_values(owned: &WindowIdentity) -> (String, Vec<Value>, u32) {
    // Last tuple field is always 0; it is not an AttachConsole status.
    if !identity_live(owned) {
        return (String::new(), Vec::new(), 0);
    }
    let text = read_owned_window_text(owned.hwnd);
    if !identity_live(owned) {
        return (String::new(), Vec::new(), 0);
    }
    let values = json_values_in(&text);
    (text, values, 0)
}

/// If the test runner is killed, HostGuard Drop does not run. The outer
/// executor must terminate the manifest client and console-host using
/// pid+creation (never PID-only) and must leave failed-run evidence in place.
const OUTER_EXECUTOR_CLEANUP_OBLIGATION: &str = "If the test runner is killed, OwnedHost/HostGuard Drop does not run. The outer executor must terminate the client and console-host processes identified in this manifest using pid+creation (OpenProcess + GetProcessTimes match), never PID-only, and must leave this evidence directory in place on failure.";
const OPERATOR_CANCEL_ACTION: &str = r#"No operator input remains pending; missing input never succeeds. Codex built-in Computer Use delivers published protocol requests to the owned console. To cancel this owned wait, write operator_cancel_request with exact JSON {"instance_id":"<manifest instance_id>","cancel":true}. Wrong instance_id or malformed or partial bytes fail this owned fixture with evidence and never succeed. Cancellation never passes. Process death or identity loss keep the existing failure and owned cleanup path."#;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OperatorCancelRequest {
    Absent,
    Cancel,
    WrongIdentity,
    Malformed,
}

fn operator_cancel_request_path(evidence_dir: &Path) -> PathBuf {
    evidence_dir.join("operator-cancel-request.json")
}

fn interpret_operator_cancel_request(
    request: Option<&[u8]>,
    expected_instance_id: &str,
) -> OperatorCancelRequest {
    let Some(bytes) = request else {
        return OperatorCancelRequest::Absent;
    };
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(bytes) else {
        return OperatorCancelRequest::Malformed;
    };
    let instance = match object.get("instance_id") {
        Some(Value::String(text)) if !text.is_empty() => text.as_str(),
        _ => return OperatorCancelRequest::Malformed,
    };
    if instance != expected_instance_id {
        return OperatorCancelRequest::WrongIdentity;
    }
    if object.len() != 2 {
        return OperatorCancelRequest::Malformed;
    }
    match object.get("cancel") {
        Some(Value::Bool(true)) => OperatorCancelRequest::Cancel,
        _ => OperatorCancelRequest::Malformed,
    }
}

fn load_operator_cancel_request(
    evidence_dir: &Path,
    expected_instance_id: &str,
) -> OperatorCancelRequest {
    match fs::read(operator_cancel_request_path(evidence_dir)) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => OperatorCancelRequest::Absent,
        Err(_) => OperatorCancelRequest::Malformed,
        Ok(bytes) => {
            interpret_operator_cancel_request(Some(bytes.as_slice()), expected_instance_id)
        }
    }
}

fn wait_for_owned_console_response(
    host: &OwnedHost,
    owned: &WindowIdentity,
    expect: &OwnedConsoleResponseExpect<'_>,
    data: impl Fn(&Value) -> bool,
    baseline: &[Value],
    evidence_dir: &Path,
    label: &str,
) -> Value {
    let mut last = String::new();
    loop {
        if let Some((evidence_name, reason)) =
            match load_operator_cancel_request(evidence_dir, expect.instance_id) {
                OperatorCancelRequest::Absent => None,
                OperatorCancelRequest::Cancel => {
                    Some(("operator-wait-cancelled.json", "cancelled"))
                }
                OperatorCancelRequest::WrongIdentity => Some((
                    "operator-wait-cancel-wrong-identity.json",
                    "cancel request bound to a different instance_id",
                )),
                OperatorCancelRequest::Malformed => Some((
                    "operator-wait-cancel-malformed.json",
                    "malformed or partial operator cancel request",
                )),
            }
        {
            let request = fs::read(operator_cancel_request_path(evidence_dir))
                .ok()
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
            write_run_evidence(
                evidence_dir,
                evidence_name,
                &json!({
                    "label": label,
                    "expect_operation": expect.operation,
                    "expect_operation_id": expect.operation_id,
                    "expect_instance_id": expect.instance_id,
                    "operator_cancel_request": request,
                    "last_console": last,
                    "observer": "owned-window-uia-text-pattern", "legacy_attach_gle": null,
                }),
            );
            panic!(
                "operator wait {reason} for {label}; pending is never success; cancellation never passes; evidence={}",
                evidence_dir.display()
            );
        }
        if !identity_holds(host) || !console_host_holds(host) {
            write_run_evidence(
                evidence_dir,
                "operator-wait-identity-lost.json",
                &json!({
                    "label": label,
                    "client_pid": host.pid,
                    "client_creation": host.creation,
                    "console_host_pid": host.console_host_pid,
                    "console_host_creation": host.console_host_creation,
                    "last_console": last,
                    "observer": "owned-window-uia-text-pattern", "legacy_attach_gle": null,
                }),
            );
            panic!(
                "owned client/console-host identity lost while waiting for {label}; evidence={}",
                evidence_dir.display()
            );
        }
        if unsafe { WaitForSingleObject(host.process, 0) } == WAIT_OBJECT_0
            || unsafe { WaitForSingleObject(host.console_host_process, 0) } == WAIT_OBJECT_0
        {
            write_run_evidence(
                evidence_dir,
                "operator-wait-process-exited.json",
                &json!({
                    "label": label,
                    "client_exit": process_exit_code(host.process),
                    "console_host_exit": process_exit_code(host.console_host_process),
                    "last_console": last,
                    "observer": "owned-window-uia-text-pattern", "legacy_attach_gle": null,
                }),
            );
            panic!(
                "owned process exited while waiting for {label} (operator wait cancelled by process death); evidence={}",
                evidence_dir.display()
            );
        }
        if !identity_live(owned) {
            write_run_evidence(
                evidence_dir,
                "operator-wait-hwnd-lost.json",
                &json!({
                    "label": label,
                    "hwnd": owned.hwnd,
                    "pid": owned.pid,
                    "creation": owned.creation,
                    "class": owned.class,
                    "last_console": last,
                    "observer": "owned-window-uia-text-pattern", "legacy_attach_gle": null,
                }),
            );
            panic!(
                "owned HWND identity lost while waiting for {label}; evidence={}",
                evidence_dir.display()
            );
        }
        let observed = observe_owned_console_values(owned);
        last = observed.0;
        if let Some(value) = find_accepted_owned_console_response(&last, expect, &data, baseline) {
            return value;
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_startup_discovery(
    host: &OwnedHost,
    owned: &WindowIdentity,
    evidence_dir: &Path,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut last = String::new();
    while Instant::now() < deadline {
        let identity_holds = identity_holds(host);
        let console_host_holds = console_host_holds(host);
        let identity_live = identity_live(owned);
        if !identity_holds || !console_host_holds || !identity_live {
            write_run_evidence(
                evidence_dir,
                "discovery-identity-lost.json",
                &json!({
                    "client_pid": host.pid,
                    "client_creation": host.creation,
                    "console_host_pid": host.console_host_pid,
                    "hwnd": owned.hwnd,
                    "last_console": last,
                    "observer": "owned-window-uia-text-pattern", "legacy_attach_gle": null,
                    "identity_holds": identity_holds,
                    "console_host_holds": console_host_holds,
                    "identity_live": identity_live,
                    "expected_owned_identity": identity_json(Some(owned)),
                    "actual_window_identity": identity_json(
                        window_identity(hwnd_ptr(owned.hwnd)).as_ref(),
                    ),
                    "console_host_creation": host.console_host_creation,
                    "client_exit_code": process_exit_code(host.process),
                    "console_host_exit_code": process_exit_code(host.console_host_process),
                    "client_wait_for_single_object": process_wait_status(host.process),
                    "console_host_wait_for_single_object": process_wait_status(
                        host.console_host_process,
                    ),
                }),
            );
            panic!(
                "owned identity lost before discovery JSON; evidence={}",
                evidence_dir.display()
            );
        }
        let observed = observe_owned_console_values(owned);
        last = observed.0;
        for value in json_values_in(&last) {
            let instance = value.get("instance_id").and_then(Value::as_str);
            if value.get("pipe_name").is_some() && instance.is_some_and(|id| !id.is_empty()) {
                return value;
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    write_run_evidence(
        evidence_dir,
        "discovery-timeout.json",
        &json!({
            "last_console": last,
            "observer": "owned-window-uia-text-pattern", "legacy_attach_gle": null,
            "client_pid": host.pid,
            "hwnd": owned.hwnd,
        }),
    );
    panic!(
        "owned console did not expose discovery JSON with pipe_name and instance_id within 20s; owned-window-uia-text-pattern last_console={last} evidence={}",
        evidence_dir.display()
    );
}

fn wait_for_json(
    pid: u64,
    window_id: u64,
    session: &str,
    buffer_pid: u32,
    predicate: impl Fn(&Value) -> bool,
    label: &str,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut last = String::new();
    let mut buffer_gle = 0u32;
    while Instant::now() < deadline {
        let state = snapshot_window(pid, window_id, session);
        last = snapshot_text(&state);
        let owned_text = read_owned_window_text(window_id);
        if !owned_text.is_empty() {
            last.push('\n');
            last.push_str(&owned_text);
        }
        let (buffer, gle) = read_owned_console_buffer(buffer_pid);
        buffer_gle = gle;
        if !buffer.is_empty() {
            last.push('\n');
            last.push_str(&buffer);
        }
        if buffer_pid != pid as u32 {
            let (client_buffer, _) = read_owned_console_buffer(pid as u32);
            if !client_buffer.is_empty() {
                last.push('\n');
                last.push_str(&client_buffer);
            }
        }
        for value in json_values_in(&last) {
            if predicate(&value) {
                return value;
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    panic!("CUA owner CLI did not expose {label} in the dedicated test window tree, owned HWND text, or owned console buffer. attach/read gle={buffer_gle} last_snapshot={last}");
}

fn window_count(pid: u64, session: &str) -> (usize, Value) {
    let listed = cua_json("list_windows", json!({"pid": pid, "session": session}));
    let windows = listed
        .get("windows")
        .or_else(|| listed.pointer("/structuredContent/windows"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    (windows.len(), listed)
}

#[allow(dead_code)]
fn debug_window_count(pid: u64) -> (usize, String, Value) {
    let debug = cua_json("debug_window_info", json!({"pid": pid}));
    let windows = debug
        .get("windows")
        .or_else(|| debug.pointer("/structuredContent/windows"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let exe = debug
        .get("exe_basename")
        .or_else(|| debug.pointer("/structuredContent/exe_basename"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    (windows.len(), exe, debug)
}

fn first_window_id(listed: &Value) -> Option<(u64, u64)> {
    let windows = listed
        .get("windows")
        .or_else(|| listed.pointer("/structuredContent/windows"))
        .and_then(Value::as_array)?;
    let window = windows.first()?;
    Some((
        window.get("pid").and_then(Value::as_u64).unwrap_or(0),
        window.get("window_id").and_then(Value::as_u64)?,
    ))
}

fn type_line(pid: u64, window_id: u64, session: &str, text: &str, clipboard: &mut ClipboardGuard) {
    let payload = format!("{text}\r");
    let (system, _) = wait_for_menu_element(
        pid,
        window_id,
        session,
        "システム",
        "システム",
        MenuStage::Open,
    );
    background_menu_click(pid, window_id, session, &system, "システム");
    let (edit, _) = wait_for_menu_element(pid, window_id, session, "編集", "編集", MenuStage::Open);
    background_menu_click(pid, window_id, session, &edit, "編集");
    let (paste, _) = wait_for_menu_element(
        pid,
        window_id,
        session,
        "貼り付け",
        "貼り付け",
        MenuStage::Leaf,
    );
    clipboard.write_owned(&payload);
    background_menu_click(pid, window_id, session, &paste, "貼り付け");
}

#[test]
#[ignore = "requires operator input in the owned Windows console; run explicitly for manual E2E"]
fn real_cua_owner_cli_project_journey() {
    let winsmux = PathBuf::from(env!("CARGO_BIN_EXE_winsmux"));
    assert!(winsmux.is_file(), "{}", winsmux.display());
    let evidence_dir = new_run_evidence_dir();
    let folder = temp_japanese();
    let mut host = match spawn_owner_cli(&winsmux) {
        Ok(host) => host,
        Err((gle, command_line)) => {
            write_run_evidence(
                &evidence_dir,
                "creation_failed.json",
                &json!({
                    "state": "creation_failed",
                    "exe": winsmux.display().to_string(),
                    "launcher": system_conhost_exe().display().to_string(),
                    "argv": ["workspace", "host"],
                    "command_line": command_line,
                    "create_gle": gle,
                    "creation_flags": "CREATE_NEW_CONSOLE|CREATE_UNICODE_ENVIRONMENT",
                    "w_show_window": "SW_SHOWNORMAL",
                    "desktop": desktop_json(&own_desktop_metadata()),
                    "cleanup_obligation": OUTER_EXECUTOR_CLEANUP_OBLIGATION,
                }),
            );
            panic!(
                "explicit system conhost CreateProcessW of cargo winsmux workspace host failed: gle={gle} command_line={command_line} evidence={}",
                evidence_dir.display()
            );
        }
    };
    struct HostGuard {
        client_process: *mut core::ffi::c_void,
        client_pid: u32,
        client_creation: u64,
        console_host_process: *mut core::ffi::c_void,
        console_host_pid: u32,
        console_host_creation: u64,
        isolation_dir: PathBuf,
        self_conhost: Option<u32>,
    }
    // Drop terminates the owned client and console-host using pid+creation.
    // If the test runner is killed, Drop does not run; see OUTER_EXECUTOR_CLEANUP_OBLIGATION.
    impl Drop for HostGuard {
        fn drop(&mut self) {
            if self.client_pid != 0 {
                let _ = terminate_owned_identity(
                    self.client_process,
                    self.client_pid,
                    self.client_creation,
                );
            }
            if !self.client_process.is_null() {
                unsafe {
                    let _ = CloseHandle(self.client_process);
                }
                self.client_process = ptr::null_mut();
            }
            if self.console_host_pid != 0 && Some(self.console_host_pid) != self.self_conhost {
                let _ = terminate_owned_identity(
                    self.console_host_process,
                    self.console_host_pid,
                    self.console_host_creation,
                );
            }
            if !self.console_host_process.is_null() {
                unsafe {
                    let _ = CloseHandle(self.console_host_process);
                }
                self.console_host_process = ptr::null_mut();
            }
            let _ = fs::remove_dir_all(&self.isolation_dir);
        }
    }
    let self_conhost = console_host_pid(std::process::id());
    if Some(host.console_host_pid) == self_conhost {
        write_run_evidence(
            &evidence_dir,
            "shared_console_refused.json",
            &json!({
                "state": "shared_console_refused",
                "console_host_pid": host.console_host_pid,
                "self_conhost": self_conhost,
                "desktop": desktop_json(&host.desktop),
            }),
        );
        panic!(
            "explicit system conhost shared the test process console host pid={}; owned console was not created; evidence={}",
            host.console_host_pid,
            evidence_dir.display()
        );
    }
    let mut guard = HostGuard {
        client_process: host.process,
        client_pid: host.pid,
        client_creation: host.creation,
        console_host_process: host.console_host_process,
        console_host_pid: host.console_host_pid,
        console_host_creation: host.console_host_creation,
        isolation_dir: host.isolation_dir.clone(),
        self_conhost,
    };
    let mut win32 = Vec::new();
    let mut window: Option<(u32, u64, String, bool)> = None;
    let acquire_deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if !console_host_holds(&host) {
            let exit = process_exit_code(host.console_host_process);
            write_run_evidence(
                &evidence_dir,
                "conhost-exited.json",
                &json!({
                    "state": "created_and_exited",
                    "exe": host.exe,
                    "launcher": host.launcher,
                    "argv": host.argv,
                    "command_line": host.command_line,
                    "console_host_pid": host.console_host_pid,
                    "console_host_tid": host.console_host_tid,
                    "console_host_creation": host.console_host_creation,
                    "client_pid": host.pid,
                    "client_creation": host.creation,
                    "exit_code": exit,
                    "desktop": desktop_json(&host.desktop),
                }),
            );
            panic!(
                "explicit system conhost exited or PID reused before owned window: conhost_pid={} creation={} exit={exit:?} evidence={}",
                host.console_host_pid,
                host.console_host_creation,
                evidence_dir.display()
            );
        }
        if unsafe { WaitForSingleObject(host.console_host_process, 0) } == WAIT_OBJECT_0 {
            let exit = process_exit_code(host.console_host_process);
            write_run_evidence(
                &evidence_dir,
                "conhost-signaled.json",
                &json!({
                    "state": "created_and_exited",
                    "console_host_pid": host.console_host_pid,
                    "exit_code": exit,
                    "client_pid": host.pid,
                    "desktop": desktop_json(&host.desktop),
                }),
            );
            panic!(
                "explicit system conhost CreateProcessW succeeded then process exited: pid={} exit={exit:?} evidence={}",
                host.console_host_pid,
                evidence_dir.display()
            );
        }
        let client_bound = bind_client_process(&mut host, &winsmux);
        guard.client_process = host.process;
        guard.client_pid = host.pid;
        guard.client_creation = host.creation;
        if client_bound {
            if unsafe { WaitForSingleObject(host.process, 0) } == WAIT_OBJECT_0 {
                let exit = process_exit_code(host.process);
                write_run_evidence(
                    &evidence_dir,
                    "client-exited.json",
                    &json!({
                        "state": "created_and_exited",
                        "client_pid": host.pid,
                        "client_creation": host.creation,
                        "exit_code": exit,
                        "console_host_pid": host.console_host_pid,
                    }),
                );
                panic!(
                    "cargo winsmux client exited before owned window: pid={} creation={} exit={exit:?} evidence={}",
                    host.pid,
                    host.creation,
                    evidence_dir.display()
                );
            }
        }
        let family_u32: Vec<u32> = std::iter::once(host.console_host_pid)
            .chain((host.pid != 0).then_some(host.pid))
            .collect();
        win32 = discover_family_windows(&family_u32);
        match pick_owned_console(&win32, &family_u32) {
            Ok(found) => {
                if host.pid != 0 {
                    window = Some(found);
                    break;
                }
            }
            Err(error) if error.contains("CASCADIA") || error.contains("cascadia") => {
                write_run_evidence(
                    &evidence_dir,
                    "cascadia-after-spawn.json",
                    &json!({
                        "state": "cascadia_after_spawn",
                        "error": error,
                        "console_host_pid": host.console_host_pid,
                        "client_pid": host.pid,
                        "win32_owned_hwnds": win32,
                        "desktop": desktop_json(&host.desktop),
                    }),
                );
                panic!(
                    "CASCADIA after explicit system conhost is a required journey failure, not a completed substitute: {error} evidence={}",
                    evidence_dir.display()
                );
            }
            Err(_) => {}
        }
        if Instant::now() >= acquire_deadline {
            let exit = process_exit_code(host.console_host_process);
            write_run_evidence(
                &evidence_dir,
                "running-without-consolewindowclass.json",
                &json!({
                    "state": "running_without_consolewindowclass",
                    "exe": host.exe,
                    "launcher": host.launcher,
                    "argv": host.argv,
                    "command_line": host.command_line,
                    "console_host_pid": host.console_host_pid,
                    "console_host_creation": host.console_host_creation,
                    "client_pid": host.pid,
                    "client_creation": host.creation,
                    "exit_code": exit,
                    "still_active": exit == Some(STILL_ACTIVE),
                    "self_conhost": self_conhost,
                    "win32_owned_hwnds": win32,
                    "desktop": desktop_json(&host.desktop),
                    "cleanup_obligation": OUTER_EXECUTOR_CLEANUP_OBLIGATION,
                }),
            );
            panic!(
                "no ConsoleWindowClass HWND after explicit system conhost of cargo winsmux workspace host: \
                 conhost_pid={} creation={} client_pid={} client_creation={} \
                 self_conhost={self_conhost:?} win32={win32:?} \
                 desktop={}\\{} station_visible={:?} session={:?} exit={exit:?} evidence={}",
                host.console_host_pid,
                host.console_host_creation,
                host.pid,
                host.creation,
                host.desktop.window_station,
                host.desktop.desktop,
                host.desktop.station_visible,
                host.desktop.session_id,
                evidence_dir.display()
            );
        }
        thread::sleep(Duration::from_millis(200));
    }
    let Some((window_pid, window_id, window_class, window_visible)) = window.clone() else {
        panic!(
            "hidden discovery returned no window; evidence={}",
            evidence_dir.display()
        );
    };
    assert!(
        class_is_console(&window_class),
        "owned window class must be ConsoleWindowClass, got {window_class}"
    );
    let owned = window_identity(hwnd_ptr(window_id)).unwrap_or_else(|| {
        write_run_evidence(
            &evidence_dir,
            "hwnd-identity-missing.json",
            &json!({
                "hwnd": window_id,
                "window_pid": window_pid,
                "window_class": window_class,
                "client_pid": host.pid,
                "client_creation": host.creation,
                "console_host_pid": host.console_host_pid,
                "console_host_creation": host.console_host_creation,
            }),
        );
        panic!(
            "owned HWND could not be bound with pid+creation identity; evidence={}",
            evidence_dir.display()
        )
    });
    let window_creation_ok = if owned.pid == host.pid {
        owned.creation == host.creation
    } else if owned.pid == host.console_host_pid {
        owned.creation == host.console_host_creation
    } else {
        false
    };
    if !window_creation_ok {
        write_run_evidence(
            &evidence_dir,
            "hwnd-identity-mismatch.json",
            &json!({
                "owned": identity_json(Some(&owned)),
                "client_pid": host.pid,
                "client_creation": host.creation,
                "console_host_pid": host.console_host_pid,
                "console_host_creation": host.console_host_creation,
            }),
        );
        panic!(
            "owned HWND pid+creation is not the client or console-host identity (PID-only ownership refused): owned={owned:?} evidence={}",
            evidence_dir.display()
        );
    }
    if unsafe { IsWindowVisible(hwnd_ptr(window_id)) } == 0 || !window_visible {
        unsafe {
            let _ = ShowWindow(hwnd_ptr(window_id), SW_SHOW);
        }
    }
    let _guard = guard;
    let discovery = wait_for_startup_discovery(&host, &owned, &evidence_dir);
    let instance = discovery["instance_id"]
        .as_str()
        .expect("instance")
        .to_owned();
    let manifest_path = evidence_dir.join("manifest.json");
    write_immutable_manifest(
        &manifest_path,
        &json!({
            "binary": host.exe,
            "launcher": host.launcher,
            "argv": host.argv,
            "command_line": host.command_line,
            "client": {
                "pid": host.pid,
                "tid": host.tid,
                "creation": host.creation
            },
            "console_host": {
                "pid": host.console_host_pid,
                "tid": host.console_host_tid,
                "creation": host.console_host_creation
            },
            "hwnd": owned.hwnd,
            "window": {
                "pid": owned.pid,
                "creation": owned.creation,
                "class": owned.class
            },
            "instance_id": instance,
            "discovery": discovery,
            "evidence_dir": evidence_dir.display().to_string(),
            "operator_cancel_request": operator_cancel_request_path(&evidence_dir).display().to_string(),
            "operator_cancel_action": OPERATOR_CANCEL_ACTION,
            "cleanup_obligation": OUTER_EXECUTOR_CLEANUP_OBLIGATION,
        }),
    );
    print_manifest_path(&manifest_path);

    let list_id = "20000000-0000-4000-8000-0000000000f1";
    let list_req = json!({
        "schema_version": 1,
        "instance_id": instance,
        "operation_id": list_id,
        "expected_topology_revision": null,
        "operation": "project.list",
        "params": {}
    });
    let list_expect = OwnedConsoleResponseExpect {
        instance_id: &instance,
        operation_id: list_id,
        operation: "project.list",
    };
    let baseline = observe_owned_console_values(&owned).1;
    publish_protocol_request(&evidence_dir, 1, "project.list", list_id, &list_req);
    let empty = wait_for_owned_console_response(
        &host,
        &owned,
        &list_expect,
        |value| value.pointer("/result/data/projects") == Some(&json!([])),
        &baseline,
        &evidence_dir,
        "empty project.list",
    );
    assert_eq!(empty["result"]["data"]["projects"], json!([]));

    let open_id = "20000000-0000-4000-8000-0000000000f2";
    let open_req = json!({
        "schema_version": 1,
        "instance_id": instance,
        "operation_id": open_id,
        "expected_topology_revision": 0,
        "operation": "project.open",
        "params": {"path": folder.to_string_lossy()}
    });
    let open_expect = OwnedConsoleResponseExpect {
        instance_id: &instance,
        operation_id: open_id,
        operation: "project.open",
    };
    let baseline = observe_owned_console_values(&owned).1;
    publish_protocol_request(&evidence_dir, 2, "project.open", open_id, &open_req);
    let opened = wait_for_owned_console_response(
        &host,
        &owned,
        &open_expect,
        |value| {
            value
                .pointer("/result/data/project_id")
                .and_then(Value::as_str)
                .is_some()
        },
        &baseline,
        &evidence_dir,
        "project.open",
    );
    let project = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("id")
        .to_owned();
    let revision = opened["topology_revision"].as_u64().expect("rev");

    let list2_id = "20000000-0000-4000-8000-0000000000f3";
    let list2 = json!({
        "schema_version": 1,
        "instance_id": instance,
        "operation_id": list2_id,
        "expected_topology_revision": null,
        "operation": "project.list",
        "params": {}
    });
    let list2_expect = OwnedConsoleResponseExpect {
        instance_id: &instance,
        operation_id: list2_id,
        operation: "project.list",
    };
    let baseline = observe_owned_console_values(&owned).1;
    publish_protocol_request(&evidence_dir, 3, "project.list", list2_id, &list2);
    wait_for_owned_console_response(
        &host,
        &owned,
        &list2_expect,
        |value| value.pointer("/result/data/projects/0/project_id") == Some(&json!(project)),
        &baseline,
        &evidence_dir,
        "complete project.list",
    );

    let select_id = "20000000-0000-4000-8000-0000000000f4";
    let select_req = json!({
        "schema_version": 1,
        "instance_id": instance,
        "operation_id": select_id,
        "expected_topology_revision": revision,
        "operation": "project.select",
        "params": {"project_id": project}
    });
    let select_expect = OwnedConsoleResponseExpect {
        instance_id: &instance,
        operation_id: select_id,
        operation: "project.select",
    };
    let baseline = observe_owned_console_values(&owned).1;
    publish_protocol_request(&evidence_dir, 4, "project.select", select_id, &select_req);
    let selected = wait_for_owned_console_response(
        &host,
        &owned,
        &select_expect,
        |value| value.pointer("/result/data/selected_project_id") == Some(&json!(project)),
        &baseline,
        &evidence_dir,
        "project.select",
    );
    let revision = selected["topology_revision"].as_u64().expect("rev");

    let forget_id = "20000000-0000-4000-8000-0000000000f5";
    let forget_req = json!({
        "schema_version": 1,
        "instance_id": instance,
        "operation_id": forget_id,
        "expected_topology_revision": revision,
        "operation": "project.forget",
        "params": {"project_id": project}
    });
    let forget_expect = OwnedConsoleResponseExpect {
        instance_id: &instance,
        operation_id: forget_id,
        operation: "project.forget",
    };
    let baseline = observe_owned_console_values(&owned).1;
    publish_protocol_request(&evidence_dir, 5, "project.forget", forget_id, &forget_req);
    wait_for_owned_console_response(
        &host,
        &owned,
        &forget_expect,
        |value| value.pointer("/result/data/removed") == Some(&json!(true)),
        &baseline,
        &evidence_dir,
        "project.forget",
    );
    assert_eq!(
        fs::read(folder.join("marker.txt")).expect("disk"),
        b"folder-bytes"
    );
    let _ = fs::remove_dir_all(&folder);
}

const SESSION_OUTCOME_REQUESTED: &str = "task863-owner-cli";

fn session_start_from(code: i32, stdout: &str) -> SessionOutcome {
    interpret_start_session(SESSION_OUTCOME_REQUESTED, code, stdout, "")
}

fn session_get_from(code: i32, stdout: &str) -> SessionOutcome {
    interpret_get_session(SESSION_OUTCOME_REQUESTED, code, stdout, "")
}

fn session_get_from_stderr(code: i32, stdout: &str, stderr: &str) -> SessionOutcome {
    interpret_get_session(SESSION_OUTCOME_REQUESTED, code, stdout, stderr)
}

fn session_end_from(code: i32, stdout: &str) -> SessionOutcome {
    interpret_end_session(SESSION_OUTCOME_REQUESTED, code, stdout, "")
}

// Source-derived from session_tools.rs StartSessionOutput constructors; not live-verified.
const SOURCE_DERIVED_START_ACTIVE: &str = r#"{"session":"task863-owner-cli","capture_scope":"auto","effective_scope":"window","desktop_capture_authorized":false,"active":true,"revived":false}"#;
const SOURCE_DERIVED_GET_ACTIVE: &str =
    r#"{"session":"task863-owner-cli","implicit":false,"state":"active","client_kind":"cli"}"#;
const SOURCE_DERIVED_GET_ENDING: &str =
    r#"{"session":"task863-owner-cli","implicit":false,"state":"ending","client_kind":"cli"}"#;
const SOURCE_DERIVED_END_INACTIVE: &str = r#"{"session":"task863-owner-cli","active":false}"#;
// Live measured get_session residue: exit 0, stderr empty, stdout SHA 56785b26a7b1d9e9891b6cd5b6b467812ee41ea6f4b5d488091fb4052d4038ba.
const LIVE_GET_SESSION_NOT_STARTED: &str = r#"{"code":"session_not_started"}"#;
// serve.rs:510-512 + cli.rs:2408-2412 named-session Get after End; live stdout empty, exit 1.
const LIVE_GET_SESSION_ENDED_REJECTED_STDERR: &str = "session 'task863-owner-cli' has ended; tool call 'get_session' was rejected. Call start_session with this id to revive it before issuing further actions, or use a new session id.";

#[test]
fn session_outcome_source_derived_start_active_true() {
    let outcome = session_start_from(0, SOURCE_DERIVED_START_ACTIVE);
    assert_eq!(outcome, SessionOutcome::Active);
    assert!(session_start_is_proven(outcome));
    assert!(session_start_accepted(outcome, None));
    assert!(!session_end_body_is_inactive(outcome));
    assert!(session_post_end_is_not_proof(outcome));
}

#[test]
fn session_outcome_source_derived_start_structured_content() {
    let outcome = session_start_from(
        0,
        r#"{"structuredContent":{"session":"task863-owner-cli","capture_scope":"auto","effective_scope":"window","desktop_capture_authorized":false,"active":true,"revived":false}}"#,
    );
    assert_eq!(outcome, SessionOutcome::Active);
    assert!(session_start_is_proven(outcome));
    assert!(session_start_accepted(outcome, None));
}

#[test]
fn session_outcome_source_derived_get_state_active() {
    let outcome = session_get_from(0, SOURCE_DERIVED_GET_ACTIVE);
    assert_eq!(outcome, SessionOutcome::Active);
    assert!(session_get_is_active(outcome));
    assert_eq!(session_get_activity(outcome), Some(true));
    assert!(!session_get_is_ending(outcome));
    assert!(!session_get_is_recognized_absence(outcome));
    assert!(!session_start_accepted(
        SessionOutcome::Malformed,
        session_get_activity(outcome)
    ));
}

#[test]
fn session_outcome_source_derived_get_optional_diagnostics_are_not_required() {
    let outcome = session_get_from(
        0,
        r#"{"session":"task863-owner-cli","state":"active","cursor_visible":true,"recording_active":false,"idle_seconds":0,"expires_in_seconds":30}"#,
    );
    assert_eq!(outcome, SessionOutcome::Active);
    assert_eq!(session_get_activity(outcome), Some(true));
}

#[test]
fn session_outcome_source_derived_get_state_ending() {
    let outcome = session_get_from(0, SOURCE_DERIVED_GET_ENDING);
    assert_eq!(outcome, SessionOutcome::Ending);
    assert!(session_get_is_ending(outcome));
    assert!(!session_get_is_active(outcome));
    assert_eq!(session_get_activity(outcome), Some(false));
    assert!(!session_get_is_recognized_absence(outcome));
    assert!(session_post_end_is_not_proof(outcome));
    assert!(!session_start_is_proven(outcome));
    assert!(!session_end_body_is_inactive(outcome));
    assert!(!session_end_cleanup_is_complete(
        session_end_from(0, SOURCE_DERIVED_END_INACTIVE),
        outcome
    ));
}

#[test]
fn session_outcome_source_derived_end_active_false() {
    let outcome = session_end_from(0, SOURCE_DERIVED_END_INACTIVE);
    assert_eq!(outcome, SessionOutcome::Inactive);
    assert!(session_end_body_is_inactive(outcome));
    assert!(!session_start_is_proven(outcome));
    assert!(session_post_end_is_not_proof(outcome));
}

#[test]
fn session_outcome_live_get_session_not_started_exit_zero() {
    let outcome = session_get_from(0, LIVE_GET_SESSION_NOT_STARTED);
    assert_eq!(outcome, SessionOutcome::Absent);
    assert!(session_get_is_recognized_absence(outcome));
    // get_session body session_not_started is never-started/not-visible, not serve.rs ended rejection.
    assert!(!session_post_end_is_recognized_absence(outcome));
    assert!(session_post_end_is_not_proof(outcome));
    assert!(!session_get_is_ended_rejection(outcome));
    assert_eq!(session_get_activity(outcome), None);
    assert!(!session_start_is_proven(outcome));
    assert!(!session_end_body_is_inactive(outcome));
}

#[test]
fn session_outcome_wrong_identity_cannot_prove() {
    let start = session_start_from(0, r#"{"session":"other-session","active":true}"#);
    let get = session_get_from(0, r#"{"session":"other-session","state":"active"}"#);
    let ended = session_end_from(0, r#"{"session":"other-session","active":false}"#);
    assert_eq!(start, SessionOutcome::WrongSession);
    assert_eq!(get, SessionOutcome::WrongSession);
    assert_eq!(ended, SessionOutcome::WrongSession);
    assert!(!session_start_is_proven(start));
    assert!(!session_start_accepted(start, Some(true)));
    assert!(!session_get_is_active(get));
    assert!(!session_end_body_is_inactive(ended));
    assert!(session_post_end_is_not_proof(get));
}

#[test]
fn session_outcome_missing_identity_on_positive_cannot_prove() {
    let start = session_start_from(0, r#"{"active":true,"revived":false}"#);
    let get = session_get_from(0, r#"{"state":"active"}"#);
    let ended = session_end_from(0, r#"{"active":false}"#);
    assert_eq!(start, SessionOutcome::Malformed);
    assert_eq!(get, SessionOutcome::Malformed);
    assert_eq!(ended, SessionOutcome::Malformed);
    assert!(!session_start_is_proven(start));
    assert!(!session_get_is_active(get));
    assert!(!session_end_body_is_inactive(ended));
}

#[test]
fn session_outcome_active_by_presence_matching_session_field() {
    let body = r#"{"session":"task863-owner-cli"}"#;
    let start = session_start_from(0, body);
    let get = session_get_from(0, body);
    assert_eq!(start, SessionOutcome::Malformed);
    assert_eq!(get, SessionOutcome::Malformed);
    assert!(!session_start_is_proven(start));
    assert!(!session_get_is_active(get));
    assert_eq!(session_get_activity(get), None);
    assert!(!session_start_accepted(start, session_get_activity(get)));
}

#[test]
fn session_outcome_get_active_boolean_is_not_activity() {
    let outcome = session_get_from(0, r#"{"session":"task863-owner-cli","active":true}"#);
    assert_eq!(outcome, SessionOutcome::Malformed);
    assert!(!session_get_is_active(outcome));
    assert_eq!(session_get_activity(outcome), None);
    assert!(!session_get_is_recognized_absence(outcome));
}

#[test]
fn session_outcome_unknown_malformed_error_cannot_prove() {
    let unknown = session_get_from(0, r#"{"code":"not_a_real_session_code"}"#);
    let malformed = session_start_from(0, r#"{"ok":true,"result":"ready"}"#);
    let non_json = session_start_from(0, "started");
    let error = session_get_from(0, r#"{"ok":false,"error":"session missing"}"#);
    assert_eq!(unknown, SessionOutcome::Failed);
    assert_eq!(malformed, SessionOutcome::Malformed);
    assert_eq!(non_json, SessionOutcome::Malformed);
    assert_eq!(error, SessionOutcome::Failed);
    assert!(!session_start_is_proven(malformed));
    assert!(!session_start_is_proven(non_json));
    assert!(!session_get_is_active(unknown));
    assert!(!session_get_is_recognized_absence(unknown));
    assert!(!session_get_is_recognized_absence(error));
    assert!(session_post_end_is_not_proof(unknown));
    assert!(session_post_end_is_not_proof(malformed));
    assert!(session_post_end_is_not_proof(error));
}

#[test]
fn session_outcome_start_active_false_is_not_start() {
    let outcome = session_start_from(0, r#"{"session":"task863-owner-cli","active":false}"#);
    assert_eq!(outcome, SessionOutcome::Inactive);
    assert!(!session_start_is_proven(outcome));
    assert!(!session_start_accepted(outcome, Some(true)));
}

#[test]
fn session_outcome_end_active_true_is_not_end() {
    let outcome = session_end_from(0, r#"{"session":"task863-owner-cli","active":true}"#);
    assert_eq!(outcome, SessionOutcome::Active);
    assert!(!session_end_body_is_inactive(outcome));
    assert!(!session_end_cleanup_is_complete(
        outcome,
        session_get_from(0, LIVE_GET_SESSION_NOT_STARTED)
    ));
}

#[test]
fn session_outcome_cleanup_pending_cannot_complete() {
    let pending = session_end_from(0, r#"{"code":"session_cleanup_pending"}"#);
    let pending_short = session_end_from(0, r#"{"code":"cleanup_pending"}"#);
    let after = session_get_from(0, LIVE_GET_SESSION_NOT_STARTED);
    assert_eq!(pending, SessionOutcome::Failed);
    assert_eq!(pending_short, SessionOutcome::Failed);
    assert!(!session_end_body_is_inactive(pending));
    assert!(!session_end_cleanup_is_complete(pending, after));
    assert!(!session_end_cleanup_is_complete(pending_short, after));
    assert!(!session_start_is_proven(pending));
}

#[test]
fn session_outcome_cleanup_partial_cannot_complete() {
    let partial = session_end_from(0, r#"{"code":"session_cleanup_partial"}"#);
    let partial_short = session_end_from(0, r#"{"code":"cleanup_partial"}"#);
    let unavailable = session_start_from(0, r#"{"code":"session_unavailable"}"#);
    let policy = session_get_from(0, r#"{"code":"session_policy_conflict"}"#);
    let policy_short = session_get_from(0, r#"{"code":"policy_conflict"}"#);
    let after = session_get_from(0, LIVE_GET_SESSION_NOT_STARTED);
    assert_eq!(partial, SessionOutcome::Failed);
    assert_eq!(partial_short, SessionOutcome::Failed);
    assert_eq!(unavailable, SessionOutcome::Failed);
    assert_eq!(policy, SessionOutcome::Failed);
    assert_eq!(policy_short, SessionOutcome::Failed);
    assert!(!session_end_cleanup_is_complete(partial, after));
    assert!(!session_end_cleanup_is_complete(partial_short, after));
    assert!(!session_start_is_proven(unavailable));
    assert!(!session_get_is_active(policy));
    assert!(!session_get_is_recognized_absence(policy));
}

#[test]
fn session_outcome_nonzero_transport_is_not_absence() {
    let after = session_get_from(1, LIVE_GET_SESSION_NOT_STARTED);
    let after_success_body = session_get_from(2, r#"{"error":"not found"}"#);
    assert_eq!(after, SessionOutcome::TransportFailed);
    assert_eq!(after_success_body, SessionOutcome::TransportFailed);
    assert!(!session_get_is_recognized_absence(after));
    assert!(!session_get_is_recognized_absence(after_success_body));
    assert!(session_post_end_is_not_proof(after));
    assert!(session_post_end_is_not_proof(after_success_body));
    let ended = session_end_from(0, SOURCE_DERIVED_END_INACTIVE);
    assert!(session_end_body_is_inactive(ended));
    assert!(!session_end_cleanup_is_complete(ended, after));
    assert!(!session_end_cleanup_is_complete(ended, after_success_body));
}

#[test]
fn session_outcome_valid_end_then_recognized_get_absence() {
    let ended = session_end_from(0, SOURCE_DERIVED_END_INACTIVE);
    let after = session_get_from_stderr(1, "", LIVE_GET_SESSION_ENDED_REJECTED_STDERR);
    assert!(session_end_body_is_inactive(ended));
    assert!(session_get_is_ended_rejection(after));
    assert!(!session_get_is_recognized_absence(after));
    assert!(session_end_cleanup_is_complete(ended, after));
    assert!(session_post_end_is_recognized_absence(after));
    assert!(!session_post_end_is_not_proof(after));
    let never_started = session_get_from(0, LIVE_GET_SESSION_NOT_STARTED);
    assert!(session_get_is_recognized_absence(never_started));
    assert!(!session_end_cleanup_is_complete(ended, never_started));
}

#[test]
fn session_outcome_post_end_malformed_is_not_rejection_proof() {
    let after = session_get_from(0, r#"{"ok":true}"#);
    assert_eq!(after, SessionOutcome::Malformed);
    assert!(session_post_end_is_not_proof(after));
    assert!(!session_post_end_is_recognized_absence(after));
    assert!(!session_end_cleanup_is_complete(
        session_end_from(0, SOURCE_DERIVED_END_INACTIVE),
        after
    ));
}

#[test]
fn session_outcome_post_end_wrong_session_is_not_rejection_proof() {
    let after = session_get_from(0, r#"{"session":"other-session","state":"active"}"#);
    assert_eq!(after, SessionOutcome::WrongSession);
    assert!(session_post_end_is_not_proof(after));
    assert!(!session_end_cleanup_is_complete(
        session_end_from(0, SOURCE_DERIVED_END_INACTIVE),
        after
    ));
}

#[test]
fn session_outcome_exit_zero_without_identity_or_active_is_malformed() {
    let start = session_start_from(0, r#"{"ok":true,"result":"ready"}"#);
    let get = session_get_from(0, r#"{"ok":true,"result":"ready"}"#);
    let ended = session_end_from(0, r#"{"ok":true,"result":"ready"}"#);
    assert_eq!(start, SessionOutcome::Malformed);
    assert_eq!(get, SessionOutcome::Malformed);
    assert_eq!(ended, SessionOutcome::Malformed);
    assert!(!session_start_is_proven(start));
    assert!(!session_end_body_is_inactive(ended));
    assert!(session_post_end_is_not_proof(get));
}

#[test]
fn session_outcome_exit_zero_without_not_found_is_not_active() {
    let start = session_start_from(0, "started");
    let get = session_get_from(0, "started");
    assert_eq!(start, SessionOutcome::Malformed);
    assert_eq!(get, SessionOutcome::Malformed);
    assert!(!session_start_is_proven(start));
    assert!(!session_get_is_active(get));
    assert!(!session_get_is_recognized_absence(get));
}

#[test]
fn session_outcome_error_payload_is_failed() {
    let outcome = session_get_from(0, r#"{"ok":false,"error":"session missing"}"#);
    assert_eq!(outcome, SessionOutcome::Failed);
    assert!(!session_start_is_proven(outcome));
    assert!(!session_get_is_recognized_absence(outcome));
    assert!(session_post_end_is_not_proof(outcome));
}

#[test]
fn session_outcome_malformed_start_may_follow_up_get_state_active() {
    let start = session_start_from(0, r#"{"ok":true}"#);
    let follow_up = session_get_activity(session_get_from(0, SOURCE_DERIVED_GET_ACTIVE));
    assert_eq!(start, SessionOutcome::Malformed);
    assert_eq!(follow_up, Some(true));
    assert!(!session_start_accepted(start, follow_up));
    assert!(!session_start_accepted(start, None));
    assert!(!session_start_accepted(start, Some(false)));
    assert!(!session_start_accepted(
        session_start_from(0, r#"{"session":"task863-owner-cli","active":false}"#),
        Some(true)
    ));
}

#[test]
fn session_outcome_invalid_start_classes_remain_failure_for_every_follow_up() {
    let invalid = [
        session_start_from(0, r#"{"ok":true}"#),
        session_start_from(0, r#"{"session":"task863-owner-cli"}"#),
        session_start_from(0, r#"{"session":"task863-owner-cli","active":false}"#),
        session_start_from(0, r#"{"session":"other-session","active":true}"#),
        session_start_from(0, r#"{"code":"session_unavailable"}"#),
        session_start_from(0, r#"{"code":"session_not_started"}"#),
        session_start_from(1, SOURCE_DERIVED_START_ACTIVE),
        session_start_from(
            0,
            r#"{"session":"task863-owner-cli","active":true,"state":"ending"}"#,
        ),
        session_start_from(
            0,
            r#"{"session":"task863-owner-cli","structuredContent":{"active":true}}"#,
        ),
    ];
    for start in invalid {
        assert!(!session_start_is_proven(start), "{start:?}");
        for follow_up in [None, Some(true), Some(false)] {
            assert!(
                !session_start_accepted(start, follow_up),
                "{start:?} follow_up={follow_up:?}"
            );
        }
    }
}

#[test]
fn session_outcome_start_end_contradictory_state_cannot_prove() {
    let start_ending = session_start_from(
        0,
        r#"{"session":"task863-owner-cli","active":true,"state":"ending"}"#,
    );
    let end_active_state = session_end_from(
        0,
        r#"{"session":"task863-owner-cli","active":false,"state":"active"}"#,
    );
    let end_ending = session_end_from(
        0,
        r#"{"session":"task863-owner-cli","active":false,"state":"ending"}"#,
    );
    let unknown_state = session_get_from(0, r#"{"session":"task863-owner-cli","state":"running"}"#);
    assert_eq!(start_ending, SessionOutcome::Malformed);
    assert_eq!(end_active_state, SessionOutcome::Malformed);
    assert_eq!(end_ending, SessionOutcome::Malformed);
    assert_eq!(unknown_state, SessionOutcome::Malformed);
    assert!(!session_start_is_proven(start_ending));
    assert!(!session_end_body_is_inactive(end_active_state));
    assert!(!session_end_body_is_inactive(end_ending));
    assert!(!session_get_is_active(unknown_state));
}

#[test]
fn session_outcome_malformed_and_conflicting_absence_is_not_absence() {
    let with_state = session_get_from(0, r#"{"code":"session_not_started","state":"active"}"#);
    let with_ending = session_get_from(0, r#"{"code":"session_not_started","state":"ending"}"#);
    let with_active = session_get_from(0, r#"{"code":"session_not_started","active":true}"#);
    let with_error = session_get_from(0, r#"{"code":"session_not_started","error":"missing"}"#);
    let with_ok_false = session_get_from(0, r#"{"code":"session_not_started","ok":false}"#);
    let with_cleanup = session_get_from(
        0,
        r#"{"code":"session_not_started","cleanup_pending":true}"#,
    );
    let bad_state_type = session_get_from(0, r#"{"code":"session_not_started","state":1}"#);
    for outcome in [
        with_state,
        with_ending,
        with_active,
        with_error,
        with_ok_false,
        with_cleanup,
        bad_state_type,
    ] {
        assert_eq!(outcome, SessionOutcome::Malformed, "{outcome:?}");
        assert!(!session_get_is_recognized_absence(outcome));
        assert!(session_post_end_is_not_proof(outcome));
        assert!(!session_end_cleanup_is_complete(
            session_end_from(0, SOURCE_DERIVED_END_INACTIVE),
            outcome
        ));
    }
}

#[test]
fn session_outcome_cross_object_field_rescue_cannot_prove() {
    let start = session_start_from(
        0,
        r#"{"session":"task863-owner-cli","structuredContent":{"active":true}}"#,
    );
    let get = session_get_from(
        0,
        r#"{"state":"active","structuredContent":{"session":"task863-owner-cli"}}"#,
    );
    let ended = session_end_from(
        0,
        r#"{"session":"task863-owner-cli","structuredContent":{"active":false}}"#,
    );
    let envelope_conflict = session_start_from(
        0,
        r#"{"active":true,"structuredContent":{"session":"task863-owner-cli","active":true,"revived":false}}"#,
    );
    assert_eq!(start, SessionOutcome::Malformed);
    assert_eq!(get, SessionOutcome::Malformed);
    assert_eq!(ended, SessionOutcome::Malformed);
    assert_eq!(envelope_conflict, SessionOutcome::Malformed);
    assert!(!session_start_is_proven(start));
    assert!(!session_get_is_active(get));
    assert!(!session_end_body_is_inactive(ended));
    assert!(!session_start_accepted(envelope_conflict, Some(true)));
}

fn class_proof_snapshot(elements: Vec<Value>) -> Value {
    json!({
        "snapshot_id": "s0000000a",
        "elements": elements
    })
}

fn class_proof_menuitem(label: &str, actions: &[&str], index: u64) -> Value {
    json!({
        "label": label,
        "role": "MenuItem",
        "actions": actions,
        "element_index": index,
        "element_token": format!("s0000000a:{index}")
    })
}

#[test]
fn menu_target_system_expand_is_open_not_leaf() {
    let state = class_proof_snapshot(vec![
        class_proof_menuitem("システム", &["expand"], 6),
        json!({
            "label": "最小化",
            "role": "Button",
            "actions": ["invoke"],
            "element_index": 1,
            "element_token": "s0000000a:1"
        }),
        json!({
            "label": "最大化",
            "role": "Button",
            "actions": ["invoke"],
            "element_index": 2,
            "element_token": "s0000000a:2"
        }),
        json!({
            "label": "閉じる",
            "role": "Button",
            "actions": ["invoke"],
            "element_index": 3,
            "element_token": "s0000000a:3"
        }),
        json!({
            "label": "1 行上",
            "role": "Button",
            "actions": ["invoke"],
            "element_index": 4,
            "element_token": "s0000000a:4"
        }),
    ]);
    let target = find_menu_target(&state, "システム", None).expect("system");
    assert_eq!(target.element_index, 6);
    assert_eq!(target.element_token, "s0000000a:6");
    assert_eq!(target.snapshot_id, "s0000000a");
    assert!(menu_stage_supported(&target.actions, MenuStage::Open));
    assert!(!menu_stage_supported(&target.actions, MenuStage::Leaf));
    assert_eq!(
        find_menu_target(&state, "最小化", None),
        Err(MenuLookupError::Missing)
    );
    assert_eq!(
        find_menu_target(&state, "編集", None),
        Err(MenuLookupError::Missing)
    );
    assert_eq!(
        find_menu_target(&state, "貼り付け", None),
        Err(MenuLookupError::Missing)
    );
}

#[test]
fn menu_target_system_and_edit_invoke_are_open_stage() {
    let state = class_proof_snapshot(vec![
        class_proof_menuitem("システム", &["invoke"], 6),
        class_proof_menuitem("編集", &["expand"], 8),
    ]);
    let system = find_menu_target(&state, "システム", None).expect("system");
    let edit = find_menu_target(&state, "編集", None).expect("edit");
    assert!(menu_stage_supported(&system.actions, MenuStage::Open));
    assert!(menu_stage_supported(&edit.actions, MenuStage::Open));
}

#[test]
fn menu_target_paste_requires_leaf_action() {
    let leaf = class_proof_snapshot(vec![class_proof_menuitem("貼り付け", &["invoke"], 12)]);
    let toggle = class_proof_snapshot(vec![class_proof_menuitem("貼り付け", &["toggle"], 12)]);
    let select = class_proof_snapshot(vec![class_proof_menuitem("貼り付け", &["select"], 12)]);
    let expand_only = class_proof_snapshot(vec![class_proof_menuitem("貼り付け", &["expand"], 12)]);
    let nonempty_scroll =
        class_proof_snapshot(vec![class_proof_menuitem("貼り付け", &["scroll"], 12)]);
    let empty = class_proof_snapshot(vec![class_proof_menuitem("貼り付け", &[], 12)]);
    let paste = find_menu_target(&leaf, "貼り付け", None).expect("paste");
    assert!(menu_stage_supported(&paste.actions, MenuStage::Leaf));
    assert!(menu_stage_supported(
        &find_menu_target(&toggle, "貼り付け", None)
            .expect("toggle")
            .actions,
        MenuStage::Leaf
    ));
    assert!(menu_stage_supported(
        &find_menu_target(&select, "貼り付け", None)
            .expect("select")
            .actions,
        MenuStage::Leaf
    ));
    let expand_target = find_menu_target(&expand_only, "貼り付け", None).expect("expand");
    assert!(!menu_stage_supported(
        &expand_target.actions,
        MenuStage::Leaf
    ));
    assert!(menu_stage_supported(
        &expand_target.actions,
        MenuStage::Open
    ));
    let scroll_target = find_menu_target(&nonempty_scroll, "貼り付け", None).expect("scroll");
    assert!(!menu_stage_supported(
        &scroll_target.actions,
        MenuStage::Leaf
    ));
    let empty_target = find_menu_target(&empty, "貼り付け", None).expect("empty");
    assert!(!menu_stage_supported(
        &empty_target.actions,
        MenuStage::Leaf
    ));
    assert!(!menu_stage_supported(
        &empty_target.actions,
        MenuStage::Open
    ));
}

#[test]
fn menu_target_wrong_role_menubar_and_missing_token_fail() {
    let menubar = class_proof_snapshot(vec![json!({
        "label": "システム",
        "role": "MenuBar",
        "actions": ["expand"],
        "element_index": 6,
        "element_token": "s0000000a:6"
    })]);
    let no_token = class_proof_snapshot(vec![json!({
        "label": "システム",
        "role": "MenuItem",
        "actions": ["expand"],
        "element_index": 6
    })]);
    assert_eq!(
        find_menu_target(&menubar, "システム", None),
        Err(MenuLookupError::Missing)
    );
    assert_eq!(
        find_menu_target(&no_token, "システム", None),
        Err(MenuLookupError::IncompleteIdentity)
    );
}

#[test]
fn menu_target_ambiguous_stale_and_wrong_window_fail() {
    let ambiguous = class_proof_snapshot(vec![
        class_proof_menuitem("システム", &["expand"], 6),
        class_proof_menuitem("システム メニュー", &["invoke"], 7),
    ]);
    let stale = class_proof_snapshot(vec![json!({
        "label": "システム",
        "role": "MenuItem",
        "actions": ["expand"],
        "element_index": 6,
        "element_token": "s00000009:6"
    })]);
    let stale_index = class_proof_snapshot(vec![json!({
        "label": "システム",
        "role": "MenuItem",
        "actions": ["expand"],
        "element_index": 6,
        "element_token": "s0000000a:9"
    })]);
    let wrong_window = class_proof_snapshot(vec![json!({
        "label": "システム",
        "role": "MenuItem",
        "actions": ["expand"],
        "element_index": 6,
        "element_token": "s0000000a:6",
        "window_id": 111
    })]);
    assert_eq!(
        find_menu_target(&ambiguous, "システム", None),
        Err(MenuLookupError::Ambiguous)
    );
    assert_eq!(
        find_menu_target(&stale, "システム", None),
        Err(MenuLookupError::Stale)
    );
    assert_eq!(
        find_menu_target(&stale_index, "システム", None),
        Err(MenuLookupError::Stale)
    );
    assert_eq!(
        find_menu_target(&wrong_window, "システム", Some(222)),
        Err(MenuLookupError::WrongWindow)
    );
    let same_window = find_menu_target(&wrong_window, "システム", Some(111)).expect("window");
    assert_eq!(same_window.element_index, 6);
}

#[test]
fn click_cli_ax_is_semantic_and_unverifiable_is_not_effect() {
    let ax = r#"{"path":"ax","verified":false,"effect":"unverifiable"}"#;
    assert_eq!(interpret_click_cli(0, ax, ""), ClickRoute::Ax);
    let parsed = parse_cua_value(ax).expect("ax json");
    assert!(!click_tool_result_proves_effect(&parsed));
    assert_eq!(
        interpret_click_cli(
            0,
            r#"{"path":"pixel","verified":false,"effect":"unverifiable"}"#,
            ""
        ),
        ClickRoute::Forbidden
    );
    assert_eq!(
        interpret_click_cli(
            0,
            r#"{"path":"post_message","verified":false,"effect":"unverifiable"}"#,
            ""
        ),
        ClickRoute::Forbidden
    );
    assert_eq!(
        interpret_click_cli(
            0,
            r#"{"path":"msaa","verified":false,"effect":"unverifiable"}"#,
            ""
        ),
        ClickRoute::Forbidden
    );
    assert_eq!(
        interpret_click_cli(0, "✅ Performed UIA Invoke on [6]", ""),
        ClickRoute::Unparseable
    );
    assert_eq!(
        interpret_click_cli(1, ax, "UIA Invoke failed"),
        ClickRoute::Nonzero
    );
}

#[test]
fn session_outcome_ended_native_fixture_is_ended_rejection() {
    let ended = session_end_from(0, SOURCE_DERIVED_END_INACTIVE);
    let after = session_get_from_stderr(1, "", LIVE_GET_SESSION_ENDED_REJECTED_STDERR);
    let after_newline = session_get_from_stderr(
        1,
        "",
        &format!("{LIVE_GET_SESSION_ENDED_REJECTED_STDERR}\n"),
    );
    let after_crlf = session_get_from_stderr(
        1,
        "",
        &format!("{LIVE_GET_SESSION_ENDED_REJECTED_STDERR}\r\n"),
    );
    assert_eq!(after, SessionOutcome::EndedRejected);
    assert_eq!(after_newline, SessionOutcome::EndedRejected);
    assert_eq!(after_crlf, SessionOutcome::EndedRejected);
    assert!(session_get_is_ended_rejection(after));
    assert!(session_end_cleanup_is_complete(ended, after));
    assert!(session_post_end_is_recognized_absence(after));
    assert!(!session_get_is_recognized_absence(after));
    assert!(!session_get_is_active(after));
    assert_eq!(session_get_activity(after), None);
}

#[test]
fn session_outcome_ended_wrong_id_tool_code_and_stdout_cannot_prove() {
    let ended = session_end_from(0, SOURCE_DERIVED_END_INACTIVE);
    let wrong_id = session_get_from_stderr(
        1,
        "",
        "session 'other-session' has ended; tool call 'get_session' was rejected. Call start_session with this id to revive it before issuing further actions, or use a new session id.",
    );
    let wrong_tool = session_get_from_stderr(
        1,
        "",
        "session 'task863-owner-cli' has ended; tool call 'click' was rejected. Call start_session with this id to revive it before issuing further actions, or use a new session id.",
    );
    let wrong_code = session_get_from_stderr(2, "", LIVE_GET_SESSION_ENDED_REJECTED_STDERR);
    let stdout_contaminated = session_get_from_stderr(
        1,
        LIVE_GET_SESSION_NOT_STARTED,
        LIVE_GET_SESSION_ENDED_REJECTED_STDERR,
    );
    let extra_stderr = session_get_from_stderr(
        1,
        "",
        &format!("{LIVE_GET_SESSION_ENDED_REJECTED_STDERR}\nextra"),
    );
    let daemon_down = session_get_from_stderr(
        1,
        "",
        "Cua Driver daemon is not running on \\\\.\\pipe\\cua-driver.sock",
    );
    let transport = session_get_from_stderr(
        1,
        "",
        "Cua Driver daemon request on \\\\.\\pipe\\cua-driver.sock failed: connection reset",
    );
    let unknown_tool = session_get_from_stderr(64, "", "Unknown tool: get_session");
    for outcome in [
        wrong_id,
        wrong_tool,
        wrong_code,
        stdout_contaminated,
        extra_stderr,
        daemon_down,
        transport,
        unknown_tool,
    ] {
        assert_eq!(outcome, SessionOutcome::TransportFailed, "{outcome:?}");
        assert!(!session_get_is_ended_rejection(outcome));
        assert!(!session_get_is_recognized_absence(outcome));
        assert!(session_post_end_is_not_proof(outcome));
        assert!(!session_end_cleanup_is_complete(ended, outcome));
    }
}

#[test]
fn session_outcome_never_started_is_not_ended_and_invalid_start_stays_failed() {
    let never_started = session_get_from(0, LIVE_GET_SESSION_NOT_STARTED);
    let ended_body = session_end_from(0, SOURCE_DERIVED_END_INACTIVE);
    assert_eq!(never_started, SessionOutcome::Absent);
    assert!(session_get_is_recognized_absence(never_started));
    assert!(!session_get_is_ended_rejection(never_started));
    assert!(session_post_end_is_not_proof(never_started));
    assert!(!session_end_cleanup_is_complete(ended_body, never_started));
    let start = session_start_from(1, "");
    assert_eq!(start, SessionOutcome::TransportFailed);
    assert!(!session_start_accepted(start, Some(true)));
    assert!(!session_start_accepted(
        start,
        session_get_activity(session_get_from(0, SOURCE_DERIVED_GET_ACTIVE))
    ));
    assert!(!session_start_accepted(
        start,
        session_get_activity(session_get_from_stderr(
            1,
            "",
            LIVE_GET_SESSION_ENDED_REJECTED_STDERR
        ))
    ));
}

fn owned_list_expect() -> OwnedConsoleResponseExpect<'static> {
    OwnedConsoleResponseExpect {
        instance_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        operation_id: "20000000-0000-4000-8000-0000000000f1",
        operation: "project.list",
    }
}

fn owned_empty_list_data(value: &Value) -> bool {
    value.pointer("/result/data/projects") == Some(&json!([]))
}

fn owned_valid_empty_list_response() -> Value {
    json!({
        "schema_version": 1,
        "instance_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        "operation_id": "20000000-0000-4000-8000-0000000000f1",
        "accepted": true,
        "error": null,
        "result": {
            "operation": "project.list",
            "data": {
                "projects": [],
                "selected_project_id": null
            }
        }
    })
}

fn owned_list_request_echo() -> Value {
    json!({
        "schema_version": 1,
        "instance_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        "operation_id": "20000000-0000-4000-8000-0000000000f1",
        "expected_topology_revision": null,
        "operation": "project.list",
        "params": {}
    })
}

#[test]
fn sole_nonempty_owned_document_accepts_one_real_shape_response() {
    let expect = owned_list_expect();
    let valid = owned_valid_empty_list_response();
    let document = valid.to_string();
    let collected = sole_nonempty_owned_document(&[document.clone()]);
    assert_eq!(collected, document);
    let found = find_accepted_owned_console_response(
        &collected,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(found.as_ref(), Some(&valid));
    let japanese = String::from("日本語テキスト");
    let retained = sole_nonempty_owned_document(&[japanese.clone()]);
    assert_eq!(retained, japanese);
    assert_eq!(retained.as_bytes(), japanese.as_bytes());
}

#[test]
fn sole_nonempty_owned_document_rejects_empty_source() {
    let expect = owned_list_expect();
    let collected = sole_nonempty_owned_document(&[]);
    assert_eq!(collected, "");
    let found = find_accepted_owned_console_response(
        &collected,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(found, None);
    let blanks = sole_nonempty_owned_document(&[String::new(), String::new()]);
    assert_eq!(blanks, "");
    let blank_found = find_accepted_owned_console_response(
        &blanks,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(blank_found, None);
}

#[test]
fn sole_nonempty_owned_document_rejects_complementary_json_fragments() {
    let expect = owned_list_expect();
    let valid = owned_valid_empty_list_response();
    let whole = valid.to_string();
    let split_at = whole.find(',').expect("accepted response JSON has multiple keys");
    let left = whole[..split_at].to_string();
    let right = whole[split_at..].to_string();
    assert!(!left.is_empty());
    assert!(!right.is_empty());
    assert_eq!(
        find_accepted_owned_console_response(
            &left,
            &expect,
            owned_empty_list_data,
            &[],
        ),
        None
    );
    assert_eq!(
        find_accepted_owned_console_response(
            &right,
            &expect,
            owned_empty_list_data,
            &[],
        ),
        None
    );
    let joined = [left.as_str(), right.as_str()].join("\n");
    let jointly = find_accepted_owned_console_response(
        &joined,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(jointly.as_ref(), Some(&valid));
    let collected = sole_nonempty_owned_document(&[left, right]);
    assert_eq!(collected, "");
    let found = find_accepted_owned_console_response(
        &collected,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(found, None);
}

#[test]
fn sole_nonempty_owned_document_rejects_multiple_complete_documents() {
    let expect = owned_list_expect();
    let valid = owned_valid_empty_list_response();
    let first = valid.to_string();
    let second = valid.to_string();
    let joined = [first.as_str(), second.as_str()].join("\n");
    let jointly = find_accepted_owned_console_response(
        &joined,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(jointly.as_ref(), Some(&valid));
    let collected = sole_nonempty_owned_document(&[first, second]);
    assert_eq!(collected, "");
    let found = find_accepted_owned_console_response(
        &collected,
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(found, None);
}

#[test]
fn owned_console_response_accepts_valid_product_response() {
    let expect = owned_list_expect();
    let valid = owned_valid_empty_list_response();
    assert!(owned_console_response_is_accepted(
        &valid,
        &expect,
        owned_empty_list_data
    ));
    let found = find_accepted_owned_console_response(
        &valid.to_string(),
        &expect,
        owned_empty_list_data,
        &[],
    );
    assert_eq!(found.as_ref(), Some(&valid));
}

#[test]
fn owned_console_response_rejects_request_echo() {
    let expect = owned_list_expect();
    let echo = owned_list_request_echo();
    assert!(!owned_console_response_is_accepted(
        &echo,
        &expect,
        owned_empty_list_data
    ));
    assert!(!owned_console_response_is_accepted(&echo, &expect, |_| {
        true
    }));
    let console = format!("{echo}{}", owned_valid_empty_list_response());
    let found = find_accepted_owned_console_response(&console, &expect, owned_empty_list_data, &[]);
    assert_eq!(found, Some(owned_valid_empty_list_response()));
}

#[test]
fn owned_console_response_rejects_wrong_identity() {
    let expect = owned_list_expect();
    let mut wrong = owned_valid_empty_list_response();
    wrong["instance_id"] = json!("00000000-0000-4000-8000-000000000000");
    assert!(!owned_console_response_is_accepted(
        &wrong,
        &expect,
        owned_empty_list_data
    ));
}

#[test]
fn owned_console_response_rejects_wrong_sequence_and_request() {
    let expect = owned_list_expect();
    let mut wrong_seq = owned_valid_empty_list_response();
    wrong_seq["operation_id"] = json!("20000000-0000-4000-8000-0000000000f2");
    assert!(!owned_console_response_is_accepted(
        &wrong_seq,
        &expect,
        owned_empty_list_data
    ));
    let mut prior_run = owned_valid_empty_list_response();
    prior_run["instance_id"] = json!("bbbbbbbb-bbbb-4ccc-8ddd-ffffffffffff");
    prior_run["operation_id"] = json!("20000000-0000-4000-8000-0000000000f1");
    assert!(!owned_console_response_is_accepted(
        &prior_run,
        &expect,
        owned_empty_list_data
    ));
}

#[test]
fn owned_console_response_rejects_wrong_operation() {
    let expect = owned_list_expect();
    let mut wrong_op = owned_valid_empty_list_response();
    wrong_op["result"]["operation"] = json!("project.open");
    assert!(!owned_console_response_is_accepted(
        &wrong_op,
        &expect,
        owned_empty_list_data
    ));
}

#[test]
fn owned_console_response_rejects_old_response() {
    let current = OwnedConsoleResponseExpect {
        instance_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        operation_id: "20000000-0000-4000-8000-0000000000f2",
        operation: "project.open",
    };
    let old_list = owned_valid_empty_list_response();
    assert!(!owned_console_response_is_accepted(
        &old_list,
        &current,
        |_| true
    ));
    let baseline = vec![owned_valid_empty_list_response()];
    assert_eq!(
        find_accepted_owned_console_response(
            &old_list.to_string(),
            &owned_list_expect(),
            owned_empty_list_data,
            &baseline,
        ),
        None
    );
}

#[test]
fn owned_console_response_rejects_failed_response() {
    let expect = owned_list_expect();
    let mut denied = owned_valid_empty_list_response();
    denied["accepted"] = json!(false);
    denied["error"] = json!({"code": "invalid_request"});
    assert!(!owned_console_response_is_accepted(
        &denied,
        &expect,
        owned_empty_list_data
    ));
    let mut error_set = owned_valid_empty_list_response();
    error_set["error"] = json!({"code": "resource_exhausted"});
    assert!(!owned_console_response_is_accepted(
        &error_set,
        &expect,
        owned_empty_list_data
    ));
}

#[test]
fn owned_console_response_rejects_partial_response() {
    let expect = owned_list_expect();
    let partial_text = r#"{"schema_version":1,"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","operation_id":"20000000-0000-4000-8000-0000000000f1""#;
    assert_eq!(
        find_accepted_owned_console_response(partial_text, &expect, owned_empty_list_data, &[]),
        None
    );
    let mut missing_result = owned_valid_empty_list_response();
    missing_result.as_object_mut().unwrap().remove("result");
    assert!(!owned_console_response_is_accepted(
        &missing_result,
        &expect,
        owned_empty_list_data
    ));
    let mut missing_error = owned_valid_empty_list_response();
    missing_error.as_object_mut().unwrap().remove("error");
    assert!(!owned_console_response_is_accepted(
        &missing_error,
        &expect,
        owned_empty_list_data
    ));
    let mut wrong_data = owned_valid_empty_list_response();
    wrong_data["result"]["data"]["projects"] = json!([{"project_id": "not-empty"}]);
    assert!(!owned_console_response_is_accepted(
        &wrong_data,
        &expect,
        owned_empty_list_data
    ));
}

#[test]
fn owned_image_path_matches_exact_extended_prefix_and_case() {
    let exe = Path::new(r"C:\winsmux-task864\winsmux.exe");
    assert!(owned_image_path_matches(
        Some(r"C:\winsmux-task864\winsmux.exe"),
        exe
    ));
    assert!(owned_image_path_matches(
        Some(r"\\?\C:\winsmux-task864\winsmux.exe"),
        exe
    ));
    assert!(owned_image_path_matches(
        Some(r"c:\WINSMUX-TASK864\Winsmux.EXE"),
        exe
    ));
    let prefixed = Path::new(r"\\?\C:\winsmux-task864\winsmux.exe");
    assert!(owned_image_path_matches(
        Some(r"C:\winsmux-task864\winsmux.exe"),
        prefixed
    ));
    assert!(owned_image_path_matches(
        Some(r"\\?\c:\winsmux-task864\winsmux.exe"),
        prefixed
    ));
}

#[test]
fn owned_image_path_rejects_empty_unavailable_and_same_basename_different_directory() {
    let exe = Path::new(r"C:\winsmux-task864\winsmux.exe");
    assert!(!owned_image_path_matches(None, exe));
    assert!(!owned_image_path_matches(Some(""), exe));
    assert!(!owned_image_path_matches(Some("winsmux.exe"), exe));
    assert!(!owned_image_path_matches(
        Some(r"C:\other-dir\winsmux.exe"),
        exe
    ));
    assert!(!owned_image_path_matches(
        Some(r"\\?\C:\other-dir\winsmux.exe"),
        exe
    ));
}

#[test]
fn operator_cancel_request_correct_identity_cancels() {
    let instance = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    let body = br#"{"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","cancel":true}"#;
    assert_eq!(
        interpret_operator_cancel_request(Some(body), instance),
        OperatorCancelRequest::Cancel
    );
    let reordered = br#"{"cancel":true,"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}"#;
    assert_eq!(
        interpret_operator_cancel_request(Some(reordered), instance),
        OperatorCancelRequest::Cancel
    );
}

#[test]
fn operator_cancel_request_wrong_identity_fails() {
    let instance = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    let body = br#"{"instance_id":"00000000-0000-4000-8000-000000000000","cancel":true}"#;
    assert_eq!(
        interpret_operator_cancel_request(Some(body), instance),
        OperatorCancelRequest::WrongIdentity
    );
}

#[test]
fn operator_cancel_request_malformed_and_partial_fail() {
    let instance = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    let cases: [&[u8]; 7] = [
        b"",
        br#"{"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee""#,
        br#"{"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}"#,
        br#"{"cancel":true}"#,
        br#"{"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","cancel":false}"#,
        br#"{"instance_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","cancel":true,"extra":true}"#,
        b"not-json",
    ];
    for body in cases {
        assert_eq!(
            interpret_operator_cancel_request(Some(body), instance),
            OperatorCancelRequest::Malformed,
            "{}",
            String::from_utf8_lossy(body)
        );
    }
}

#[test]
fn operator_cancel_request_absent_is_not_success() {
    assert_eq!(
        interpret_operator_cancel_request(None, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
        OperatorCancelRequest::Absent
    );
}
