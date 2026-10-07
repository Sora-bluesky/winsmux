#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::{parse_request, OperationId, OperationName, ProjectId, Request};
use winsmux_workspace::host::ProductHost;
use winsmux_workspace::memory_testing::{
    exclusive_directory_hold, ledger_class, AllocationPool, LedgerClass, ObserveHold, PhaseHold,
    ProductPhase, RETAINED_BYTES,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FirstKind {
    ObservationOk,
    EffectOk,
    Error(&'static str),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum IdRecord {
    Vacant,
    Done,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ClassRow {
    operation: OperationName,
    class: LedgerClass,
    owner_first: FirstKind,
    owner_record: IdRecord,
    public_first: FirstKind,
    public_record: IdRecord,
}

const CLASS_DECISION_TABLE: &[ClassRow] = &[
    ClassRow {
        operation: OperationName::CapabilitiesGet,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::ObservationOk,
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ConnectionRequest,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("invalid_request"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("invalid_request"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ConnectionList,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ConnectionDecide,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::EffectOk,
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ConnectionRevoke,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::EffectOk,
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::HostStop,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("runtime_failed"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ProjectList,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::ObservationOk,
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ProjectOpen,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::EffectOk,
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ProjectSelect,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::EffectOk,
        owner_record: IdRecord::Done,
        public_first: FirstKind::EffectOk,
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::ProjectForget,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::EffectOk,
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::PaneList,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::ObservationOk,
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::PaneCreate,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("stale_topology"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("stale_topology"),
        public_record: IdRecord::Done,
    },
    // Dummy pane UUID is target_not_found before stale topology; null pane selection
    // reaches the retained-effect revision check for owner after project selection clears.
    ClassRow {
        operation: OperationName::PaneSplit,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::PaneSelect,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("stale_topology"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("stale_topology"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::PaneClose,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::PaneResize,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::ShellLaunch,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::AgentLaunch,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::InputWrite,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::InputKey,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::RunGet,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::RunInterrupt,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("target_not_found"),
        public_record: IdRecord::Done,
    },
    ClassRow {
        operation: OperationName::OperationGet,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::ObservationOk,
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::OutputRead,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::EventsWait,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::ObservationOk,
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::LayoutSave,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::EffectOk,
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::LayoutRestore,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("stale_topology"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ArtifactRegister,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Done,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ArtifactList,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ArtifactRead,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ArtifactDiff,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ArtifactChoose,
        class: LedgerClass::RetainedEffect,
        owner_first: FirstKind::Error("target_not_found"),
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::ArtifactChoiceList,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::Error("permission_denied"),
        public_record: IdRecord::Vacant,
    },
    ClassRow {
        operation: OperationName::DiagnosticsGet,
        class: LedgerClass::CurrentObservation,
        owner_first: FirstKind::ObservationOk,
        owner_record: IdRecord::Vacant,
        public_first: FirstKind::ObservationOk,
        public_record: IdRecord::Vacant,
    },
];

struct World {
    folder_a: String,
    project_a: String,
    project_b: String,
    project_c: String,
    pending_id: String,
    victim_id: String,
    peer_id: String,
    revision: u64,
}

struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "winsmux-863-replay-{}-{}-{}",
            label,
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("time")
                .as_nanos(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).expect("temp");
        Self { path }
    }

    fn text(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn request_with(
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

fn instance(harness: &Harness) -> String {
    serde_json::to_value(harness.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("instance")
}

fn wire_name(operation: OperationName) -> String {
    serde_json::to_value(operation)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("wire")
}

fn operation_id(id: &str) -> OperationId {
    OperationId::new(id.to_owned()).expect("operation id")
}

fn phase(harness: &Harness, id: &str) -> Option<&'static str> {
    harness
        .authorization()
        .testing_replay_phase(&operation_id(id))
}

fn uuid_set(value: &Value) -> Vec<String> {
    let mut ids: Vec<String> = value
        .as_array()
        .expect("uuid set")
        .iter()
        .map(|item| item.as_str().expect("uuid").to_owned())
        .collect();
    ids.sort();
    ids
}

fn assert_accepted(response: &Value, context: &str) {
    assert_eq!(response["accepted"], json!(true), "{context} {response}");
}

fn assert_error(response: &Value, code: &str, context: &str) {
    assert_eq!(response["accepted"], json!(false), "{context} {response}");
    assert_eq!(
        response["error"]["code"],
        json!(code),
        "{context} {response}"
    );
}

fn assert_phase(harness: &Harness, id: &str, expected: IdRecord, context: &str) {
    let actual = phase(harness, id);
    match expected {
        IdRecord::Vacant => assert_eq!(actual, None, "{context} retained id {id}"),
        IdRecord::Done => assert_eq!(actual, Some("done"), "{context} retained id {id}"),
    }
}

fn track_revision(revision: &mut u64, response: &Value) {
    if let Some(next) = response["topology_revision"].as_u64() {
        if next > *revision {
            *revision = next;
        }
    }
}

fn connection_row<'a>(listed: &'a Value, executable: &str) -> &'a Value {
    listed["result"]["data"]["connections"]
        .as_array()
        .expect("connections")
        .iter()
        .find(|row| row["executable_name"] == json!(executable))
        .unwrap_or_else(|| panic!("missing {executable} in {listed}"))
}

fn diff_probe(operation: OperationName) -> (&'static str, Value) {
    if operation == OperationName::CapabilitiesGet {
        ("project.list", json!({}))
    } else {
        ("capabilities.get", json!({}))
    }
}

fn owner_params(operation: OperationName, world: &World) -> (Option<u64>, Value) {
    match operation {
        OperationName::CapabilitiesGet
        | OperationName::ConnectionList
        | OperationName::HostStop
        | OperationName::LayoutSave
        | OperationName::DiagnosticsGet
        | OperationName::ProjectList => (None, json!({})),
        OperationName::LayoutRestore => (Some(0), json!({})),
        OperationName::ConnectionRequest => (
            None,
            json!({"project_ids": [world.project_a], "scopes": ["metadata"]}),
        ),
        OperationName::ConnectionDecide => (
            None,
            json!({
                "connection_id": world.pending_id,
                "decision": "allow",
                "project_ids": [world.project_a, world.project_b],
                "scopes": ["metadata", "control"]
            }),
        ),
        OperationName::ConnectionRevoke => (None, json!({"connection_id": world.victim_id})),
        OperationName::ProjectOpen => (Some(world.revision), json!({"path": world.folder_a})),
        OperationName::ProjectSelect => {
            (Some(world.revision), json!({"project_id": world.project_a}))
        }
        OperationName::ProjectForget => {
            (Some(world.revision), json!({"project_id": world.project_c}))
        }
        OperationName::PaneList | OperationName::ArtifactList | OperationName::ArtifactChoiceList => {
            (None, json!({"project_id": world.project_a}))
        }
        OperationName::PaneCreate => (
            Some(0),
            json!({"project_id": world.project_a, "shell_profile_id": "pwsh"}),
        ),
        OperationName::PaneSplit => (
            Some(0),
            json!({"axis": "horizontal", "pane_id": "40000000-0000-4000-8000-000000000000"}),
        ),
        OperationName::PaneSelect => (Some(0), json!({"pane_id": null})),
        OperationName::PaneClose => (
            Some(0),
            json!({"pane_id": "40000000-0000-4000-8000-000000000000"}),
        ),
        OperationName::PaneResize => (
            None,
            json!({
                "cols": 80,
                "pane_id": "40000000-0000-4000-8000-000000000000",
                "rows": 24,
                "run_id": "50000000-0000-4000-8000-000000000000"
            }),
        ),
        OperationName::ShellLaunch => (
            None,
            json!({
                "pane_id": "40000000-0000-4000-8000-000000000000",
                "shell_profile_id": "pwsh"
            }),
        ),
        OperationName::AgentLaunch => (
            None,
            json!({
                "effort": null,
                "model": null,
                "pane_id": "40000000-0000-4000-8000-000000000000",
                "provider": "codex"
            }),
        ),
        OperationName::InputWrite => (
            None,
            json!({
                "pane_id": "40000000-0000-4000-8000-000000000000",
                "run_id": "50000000-0000-4000-8000-000000000000",
                "text": "x"
            }),
        ),
        OperationName::InputKey => (
            None,
            json!({
                "key": "enter",
                "pane_id": "40000000-0000-4000-8000-000000000000",
                "run_id": "50000000-0000-4000-8000-000000000000"
            }),
        ),
        OperationName::RunGet | OperationName::RunInterrupt => (
            None,
            json!({"run_id": "50000000-0000-4000-8000-000000000000"}),
        ),
        OperationName::OperationGet => (
            None,
            json!({"operation_id": "20000000-0000-4000-8000-000000000000"}),
        ),
        OperationName::OutputRead => (
            None,
            json!({
                "cursor": "c",
                "max_bytes": 1,
                "run_id": "50000000-0000-4000-8000-000000000000"
            }),
        ),
        OperationName::EventsWait => (None, json!({"after_event_seq": 0, "wait_ms": 1})),
        OperationName::ArtifactRegister => (
            None,
            json!({
                "project_id": world.project_a,
                "relative_path": "a.txt",
                "run_id": null
            }),
        ),
        OperationName::ArtifactRead | OperationName::ArtifactDiff => (
            None,
            json!({
                "artifact_id": "70000000-0000-4000-8000-000000000000",
                "max_bytes": 1
            }),
        ),
        OperationName::ArtifactChoose => (
            None,
            json!({
                "project_id": world.project_a,
                "left_artifact_id": "70000000-0000-4000-8000-000000000000",
                "right_artifact_id": "80000000-0000-4000-8000-000000000000",
                "kept_artifact_id": "70000000-0000-4000-8000-000000000000"
            }),
        ),
    }
}

fn public_params(operation: OperationName, world: &World) -> (Option<u64>, Value) {
    match operation {
        OperationName::ConnectionRequest => (
            None,
            json!({"project_ids": [world.project_a], "scopes": ["metadata"]}),
        ),
        OperationName::ConnectionDecide => (
            None,
            json!({
                "connection_id": world.peer_id,
                "decision": "allow",
                "project_ids": [world.project_a],
                "scopes": ["metadata", "control"]
            }),
        ),
        OperationName::ConnectionRevoke => (None, json!({"connection_id": world.peer_id})),
        OperationName::ProjectOpen => (Some(world.revision), json!({"path": world.folder_a})),
        OperationName::ProjectSelect => {
            (Some(world.revision), json!({"project_id": world.project_a}))
        }
        OperationName::ProjectForget => {
            (Some(world.revision), json!({"project_id": world.project_a}))
        }
        other => owner_params(other, world),
    }
}

fn assert_first(kind: FirstKind, response: &Value, context: &str) {
    match kind {
        FirstKind::ObservationOk | FirstKind::EffectOk => assert_accepted(response, context),
        FirstKind::Error(code) => assert_error(response, code, context),
    }
}

fn assert_owner_matrix(
    harness: &Harness,
    inst: &str,
    public: &winsmux_workspace::auth::testing::Client,
    row: ClassRow,
    op_id: &str,
    revision: Option<u64>,
    params: Value,
) -> Value {
    let wire = wire_name(row.operation);
    let first = value(&harness.owner(&request_with(
        &wire,
        Some(inst),
        op_id,
        revision,
        params.clone(),
    )));
    assert_first(row.owner_first, &first, &format!("owner {wire}"));
    assert_phase(
        harness,
        op_id,
        row.owner_record,
        &format!("owner {wire} first"),
    );

    let same = value(&harness.owner(&request_with(&wire, Some(inst), op_id, revision, params)));
    match row.owner_record {
        IdRecord::Done => assert_eq!(same, first, "owner {wire} stored equal"),
        IdRecord::Vacant => {
            assert_first(
                row.owner_first,
                &same,
                &format!("owner {wire} same-bytes vacant"),
            );
            assert_phase(
                harness,
                op_id,
                IdRecord::Vacant,
                &format!("owner {wire} same-bytes"),
            );
        }
    }

    if row.operation == OperationName::ProjectList {
        let selected = value(&harness.owner(&request_with(
            "project.select",
            Some(inst),
            &format!("20000000-0000-4000-8000-00000100{}", &op_id[32..]),
            Some(first["topology_revision"].as_u64().unwrap_or(0)),
            json!({"project_id": params_project_from_list_setup(&first)}),
        )));
        assert_accepted(&selected, "intervening owner select");
        let observed = value(&harness.owner(&request_with(
            "project.list",
            Some(inst),
            op_id,
            None,
            json!({}),
        )));
        assert_accepted(&observed, "owner project.list after select");
        assert_ne!(
            observed["result"]["data"]["selected_project_id"],
            first["result"]["data"]["selected_project_id"],
            "completed observation same id is a new current projection"
        );
        assert_phase(
            harness,
            op_id,
            IdRecord::Vacant,
            "project.list after mutation",
        );
    }

    let (probe_op, probe_params) = diff_probe(row.operation);
    let probe = value(&harness.owner(&request_with(
        probe_op,
        Some(inst),
        op_id,
        None,
        probe_params,
    )));
    match row.owner_record {
        IdRecord::Done => assert_error(
            &probe,
            "operation_conflict",
            &format!("owner {wire} diff-bytes"),
        ),
        IdRecord::Vacant => {
            assert_accepted(&probe, &format!("owner {wire} vacant reused as {probe_op}"));
            assert_phase(
                harness,
                op_id,
                IdRecord::Vacant,
                &format!("owner {wire} reused"),
            );
        }
    }

    let other = public
        .request(&request_with(
            "capabilities.get",
            None,
            op_id,
            None,
            json!({}),
        ))
        .expect("public other-actor probe");
    let other = value(&other);
    match row.owner_record {
        IdRecord::Done => assert_error(
            &other,
            "permission_denied",
            &format!("public vs owner {wire}"),
        ),
        IdRecord::Vacant => {
            assert_accepted(&other, &format!("public new admission after owner {wire}"))
        }
    }
    first
}

fn params_project_from_list_setup(list: &Value) -> String {
    list["result"]["data"]["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .find(|row| row["project_id"].as_str().is_some())
        .and_then(|row| row["project_id"].as_str())
        .expect("list project")
        .to_owned()
}

fn assert_public_matrix(
    harness: &Harness,
    inst: &str,
    public: &winsmux_workspace::auth::testing::Client,
    row: ClassRow,
    op_id: &str,
    revision: Option<u64>,
    params: Value,
) {
    let wire = wire_name(row.operation);
    let first = public
        .request(&request_with(
            &wire,
            Some(inst),
            op_id,
            revision,
            params.clone(),
        ))
        .unwrap_or_else(|| panic!("public {wire} first was locked"));
    let first = value(&first);
    assert_first(row.public_first, &first, &format!("public {wire}"));
    assert_phase(
        harness,
        op_id,
        row.public_record,
        &format!("public {wire} first"),
    );

    let same = public
        .request(&request_with(&wire, Some(inst), op_id, revision, params))
        .unwrap_or_else(|| panic!("public {wire} same-bytes was locked"));
    let same = value(&same);
    match row.public_record {
        IdRecord::Done => assert_eq!(same, first, "public {wire} stored equal"),
        IdRecord::Vacant => {
            assert_first(
                row.public_first,
                &same,
                &format!("public {wire} same-bytes vacant"),
            );
            assert_phase(
                harness,
                op_id,
                IdRecord::Vacant,
                &format!("public {wire} same-bytes"),
            );
        }
    }

    let (probe_op, probe_params) = diff_probe(row.operation);
    match row.public_record {
        IdRecord::Done => {
            let probe = public
                .request(&request_with(
                    probe_op,
                    Some(inst),
                    op_id,
                    None,
                    probe_params,
                ))
                .unwrap_or_else(|| panic!("public {wire} diff-bytes locked"));
            assert_error(
                &value(&probe),
                "operation_conflict",
                &format!("public {wire} diff-bytes"),
            );
            let owner_probe = value(&harness.owner(&request_with(
                "capabilities.get",
                Some(inst),
                op_id,
                None,
                json!({}),
            )));
            assert_error(
                &owner_probe,
                "permission_denied",
                &format!("owner vs public {wire}"),
            );
        }
        IdRecord::Vacant => {
            let owner_probe = value(&harness.owner(&request_with(
                probe_op,
                Some(inst),
                op_id,
                None,
                probe_params,
            )));
            assert_accepted(
                &owner_probe,
                &format!("owner new admission after public {wire}"),
            );
            assert_phase(
                harness,
                op_id,
                IdRecord::Vacant,
                &format!("public {wire} reused"),
            );
        }
    }
}

fn open_project(
    harness: &Harness,
    inst: &str,
    op_id: &str,
    revision: u64,
    path: &str,
) -> (String, u64) {
    let opened = value(&harness.owner(&request_with(
        "project.open",
        Some(inst),
        op_id,
        Some(revision),
        json!({"path": path}),
    )));
    assert_accepted(&opened, "project.open");
    (
        opened["result"]["data"]["project_id"]
            .as_str()
            .expect("project")
            .to_owned(),
        opened["topology_revision"].as_u64().expect("rev"),
    )
}

fn allow_connection(
    harness: &Harness,
    inst: &str,
    op_id: &str,
    connection_id: &str,
    projects: Value,
    scopes: Value,
) -> Value {
    let decided = value(&harness.owner(&request_with(
        "connection.decide",
        Some(inst),
        op_id,
        None,
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": projects,
            "scopes": scopes
        }),
    )));
    assert_accepted(&decided, "connection.decide");
    decided
}

fn stored_receipt(
    harness: &Harness,
    id: &str,
) -> winsmux_workspace::memory_testing::TestingReplayReceipt {
    harness
        .authorization()
        .testing_replay_receipt(&operation_id(id))
        .expect("stored receipt")
}

fn assert_stored_counters(harness: &Harness, id: &str, response: &Value, context: &str) {
    let stored = stored_receipt(harness, id);
    assert_eq!(stored.phase, "done", "{context}");
    assert_eq!(
        stored.event_seq,
        response["event_seq"].as_u64(),
        "{context} stored event_seq"
    );
    assert_eq!(
        stored.topology_revision,
        response["topology_revision"].as_u64(),
        "{context} stored topology"
    );
}

fn wait_client_cancelled(client: &winsmux_workspace::auth::testing::Client, context: &str) {
    let start = Instant::now();
    while !client.cancelled() {
        assert!(
            start.elapsed() < Duration::from_secs(15),
            "{context}: forget did not signal cancel"
        );
        std::thread::yield_now();
    }
}

fn pending_request(
    client: &winsmux_workspace::auth::testing::Client,
    op_id: &str,
    projects: Value,
    scopes: Value,
) -> String {
    let pending = client
        .request(&request_with(
            "connection.request",
            None,
            op_id,
            None,
            json!({"project_ids": projects, "scopes": scopes}),
        ))
        .expect("connection.request");
    let pending = value(&pending);
    assert_accepted(&pending, "connection.request");
    pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("cid")
        .to_owned()
}

fn assert_class_table_inventory() {
    assert_eq!(OperationName::ALL.len(), 34);
    assert_eq!(CLASS_DECISION_TABLE.len(), 34);
    for (index, operation) in OperationName::ALL.iter().enumerate() {
        let row = &CLASS_DECISION_TABLE[index];
        assert_eq!(row.operation, *operation, "table order {index}");
        assert_eq!(
            row.class,
            ledger_class(*operation),
            "{} class",
            wire_name(*operation)
        );
        match row.class {
            LedgerClass::CurrentObservation => {
                assert_eq!(row.owner_record, IdRecord::Vacant);
                match row.operation {
                    OperationName::RunGet
                    | OperationName::OutputRead
                    | OperationName::ArtifactRead
                    | OperationName::ArtifactDiff => {
                        assert_eq!(
                            row.owner_first,
                            FirstKind::Error("target_not_found"),
                            "{} inventory exception",
                            wire_name(row.operation)
                        );
                    }
                    _ => {
                        assert_eq!(row.owner_first, FirstKind::ObservationOk);
                    }
                }
            }
            LedgerClass::RetainedEffect | LedgerClass::Unsupported => {}
        }
    }
}

#[test]
fn admission_before_after_ack_loss() {
    let folder = TempDir::new("admit-a");
    let host = ProductHost::start(Vec::new()).expect("product host");
    let inst = serde_json::to_value(host.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("instance");
    let used = host.allocations().snapshot().retained;
    let fill = host
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill retained");
    let op = "20000000-0000-4000-8000-0000000000aa";
    let first = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            op,
            Some(0),
            json!({"path": folder.text()}),
        ))
        .expect("pre-Preparing exhaustion reply");
    let first = value(&first);
    assert_eq!(
        first["error"]["code"],
        json!("resource_exhausted"),
        "{first}"
    );
    drop(fill);
    let retry = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            op,
            Some(0),
            json!({"path": folder.text()}),
        ))
        .expect("same ID after release");
    let retry = value(&retry);
    assert_eq!(retry["accepted"], json!(true), "{retry}");
    let replay = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            op,
            Some(0),
            json!({"path": folder.text()}),
        ))
        .expect("stored terminal");
    assert_eq!(value(&replay), retry);
    let stale = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000ab",
            Some(0),
            json!({"path": folder.text()}),
        ))
        .expect("stale revision");
    let stale = value(&stale);
    assert_eq!(stale["error"]["code"], json!("stale_topology"), "{stale}");
    let again = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000ab",
            Some(0),
            json!({"path": folder.text()}),
        ))
        .expect("stale replay");
    assert_eq!(value(&again), stale);
    let blocked = TempDir::new("admit-block");
    let exclusive = exclusive_directory_hold(&blocked.text()).expect("share hold");
    let os_id = "20000000-0000-4000-8000-0000000000ac";
    let os_fail = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            os_id,
            Some(retry["topology_revision"].as_u64().expect("rev")),
            json!({"path": blocked.text()}),
        ))
        .expect("post-Preparing OS failure");
    let os_fail = value(&os_fail);
    assert_eq!(
        os_fail["error"]["code"],
        json!("runtime_failed"),
        "{os_fail}"
    );
    drop(exclusive);
    let os_replay = host
        .owner_request(&request_with(
            "project.open",
            Some(&inst),
            os_id,
            Some(retry["topology_revision"].as_u64().expect("rev")),
            json!({"path": blocked.text()}),
        ))
        .expect("stored OS failure");
    assert_eq!(value(&os_replay), os_fail);
    host.shutdown().expect("join");
}

#[test]
fn cross_actor_cross_class_replay() {
    assert_class_table_inventory();
    let folder_a = TempDir::new("class-a");
    let folder_b = TempDir::new("class-b");
    let folder_c = TempDir::new("class-c");
    let layout_root = TempDir::new("class-layout");
    let harness = Harness::new(Vec::new());
    assert!(harness
        .authorization()
        .testing_install_isolated_layout(&layout_root.path.join("v1")));
    let inst = instance(&harness);
    let (project_a, revision) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000b1",
        0,
        &folder_a.text(),
    );
    let (project_b, revision) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000b2",
        revision,
        &folder_b.text(),
    );
    let (project_c, mut revision) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000b3",
        revision,
        &folder_c.text(),
    );

    let peer = harness.connect("peer.exe");
    let peer_id = pending_request(
        &peer,
        "20000000-0000-4000-8000-0000000000b4",
        json!([project_a, project_b]),
        json!(["metadata", "control"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000b5",
        &peer_id,
        json!([project_a, project_b]),
        json!(["metadata", "control"]),
    );

    let pending = harness.connect("pending.exe");
    let pending_id = pending_request(
        &pending,
        "20000000-0000-4000-8000-0000000000b6",
        json!([project_a, project_b]),
        json!(["metadata", "control"]),
    );
    assert_eq!(
        pending_id,
        pending.connection_id().as_str(),
        "pending lease id"
    );

    let victim = harness.connect("victim.exe");
    let victim_id = pending_request(
        &victim,
        "20000000-0000-4000-8000-0000000000b7",
        json!([project_a]),
        json!(["metadata"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000b8",
        &victim_id,
        json!([project_a]),
        json!(["metadata"]),
    );

    let other = harness.connect("other.exe");
    let mut world = World {
        folder_a: folder_a.text(),
        project_a: project_a.clone(),
        project_b,
        project_c,
        pending_id,
        victim_id,
        peer_id: peer_id.clone(),
        revision,
    };

    for (index, row) in CLASS_DECISION_TABLE.iter().enumerate() {
        world.revision = revision;
        let op_id = format!("20000000-0000-4000-8000-00000000{index:04x}");
        let (rev, params) = owner_params(row.operation, &world);
        if row.operation == OperationName::HostStop {
            assert!(harness.authorization().testing_set_occupancy(
                &ProjectId::new(world.project_a.clone()).unwrap(),
                true,
                false
            ));
        }
        let first = assert_owner_matrix(&harness, &inst, &other, *row, &op_id, rev, params);
        if row.operation == OperationName::HostStop {
            assert!(harness.authorization().testing_set_occupancy(
                &ProjectId::new(world.project_a.clone()).unwrap(),
                false,
                false
            ));
        }
        track_revision(&mut revision, &first);
        if row.operation == OperationName::ProjectList {
            revision = value(&harness.owner(&request_with(
                "project.list",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000b9",
                None,
                json!({}),
            )))["topology_revision"]
                .as_u64()
                .expect("rev");
        }
        if row.operation == OperationName::ProjectForget {
            track_revision(&mut revision, &first);
        }
    }

    world.revision = revision;
    for (index, row) in CLASS_DECISION_TABLE.iter().enumerate() {
        let op_id = format!("20000000-0000-4000-8000-00000001{index:04x}");
        let (rev, params) = public_params(row.operation, &world);
        assert_public_matrix(&harness, &inst, &peer, *row, &op_id, rev, params);
    }

    let unknown = "60000000-0000-4000-8000-000000000099";
    let missing = value(&harness.owner(&request_with(
        "connection.decide",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ba",
        None,
        json!({
            "connection_id": unknown,
            "decision": "deny",
            "project_ids": [],
            "scopes": []
        }),
    )));
    assert_error(&missing, "target_not_found", "owner decide unknown");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000ba",
        IdRecord::Vacant,
        "unknown decide",
    );
    let reuse = value(&harness.owner(&request_with(
        "capabilities.get",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ba",
        None,
        json!({}),
    )));
    assert_accepted(&reuse, "unknown decide id was vacant");

    let granted_again = value(&harness.owner(&request_with(
        "connection.decide",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000bb",
        None,
        json!({
            "connection_id": peer_id,
            "decision": "allow",
            "project_ids": [project_a],
            "scopes": ["metadata", "control"]
        }),
    )));
    assert_error(&granted_again, "invalid_request", "decide already granted");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000bb",
        IdRecord::Vacant,
        "granted decide",
    );

    let missing_forget = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000bc",
        Some(revision),
        json!({"project_id": "30000000-0000-4000-8000-000000000099"}),
    )));
    assert_error(&missing_forget, "target_not_found", "forget unknown");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000bc",
        IdRecord::Vacant,
        "unknown forget",
    );

    let missing_select = value(&harness.owner(&request_with(
        "project.select",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000bd",
        Some(revision),
        json!({"project_id": "30000000-0000-4000-8000-000000000099"}),
    )));
    assert_error(&missing_select, "target_not_found", "select unknown");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000bd",
        IdRecord::Vacant,
        "unknown select",
    );

    let missing_revoke = value(&harness.owner(&request_with(
        "connection.revoke",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000be",
        None,
        json!({"connection_id": unknown}),
    )));
    assert_error(&missing_revoke, "target_not_found", "revoke unknown");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000be",
        IdRecord::Vacant,
        "unknown revoke",
    );

    let public_open = peer
        .request(&request_with(
            "project.open",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000ff",
            Some(revision),
            json!({"path": folder_a.text()}),
        ))
        .expect("public open");
    assert_error(&value(&public_open), "permission_denied", "public open");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000ff",
        IdRecord::Vacant,
        "public open",
    );

    let hold = ObserveHold::install(&folder_a.text());
    let inflight_id = "20000000-0000-4000-8000-0000000000c0";
    let inflight = {
        let harness = harness.clone();
        let inst = inst.clone();
        std::thread::spawn(move || {
            value(&harness.owner(&request_with(
                "project.list",
                Some(&inst),
                inflight_id,
                None,
                json!({}),
            )))
        })
    };
    hold.wait_entered();
    let in_progress = value(&harness.owner(&request_with(
        "project.list",
        Some(&inst),
        inflight_id,
        None,
        json!({}),
    )));
    assert_error(&in_progress, "in_progress", "owner observation slot");
    let conflict = value(&harness.owner(&request_with(
        "capabilities.get",
        Some(&inst),
        inflight_id,
        None,
        json!({}),
    )));
    assert_error(
        &conflict,
        "operation_conflict",
        "owner observation diff-bytes",
    );
    let denied = peer
        .request(&request_with(
            "project.list",
            Some(&inst),
            inflight_id,
            None,
            json!({}),
        ))
        .expect("public vs owner observation");
    assert_error(&value(&denied), "permission_denied", "public vs owner slot");
    assert_phase(
        &harness,
        inflight_id,
        IdRecord::Vacant,
        "observation is not retained",
    );
    hold.release_waiters();
    let finished = inflight.join().expect("join");
    hold.clear();
    assert_accepted(&finished, "inflight owner list");
    assert_phase(
        &harness,
        inflight_id,
        IdRecord::Vacant,
        "observation released",
    );
    let after = value(&harness.owner(&request_with(
        "project.list",
        Some(&inst),
        inflight_id,
        None,
        json!({}),
    )));
    assert_accepted(&after, "same id after observation release");
}

#[test]
fn observation_q_family_never_retains_replay_records() {
    assert_class_table_inventory();
    for row in CLASS_DECISION_TABLE {
        if row.class == LedgerClass::CurrentObservation {
            assert_eq!(
                row.owner_record,
                IdRecord::Vacant,
                "{} owner_record",
                wire_name(row.operation)
            );
            assert_eq!(
                row.public_record,
                IdRecord::Vacant,
                "{} public_record",
                wire_name(row.operation)
            );
        }
    }

    let folder = TempDir::new("q-obs");
    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);
    let (project, _revision) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-00000000e001",
        0,
        &folder.text(),
    );

    let meta = harness.connect("q-meta.exe");
    let meta_cid = pending_request(
        &meta,
        "20000000-0000-4000-8000-00000000e002",
        json!([project]),
        json!(["metadata"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-00000000e003",
        &meta_cid,
        json!([project]),
        json!(["metadata"]),
    );
    let control = harness.connect("q-control.exe");
    let control_cid = pending_request(
        &control,
        "20000000-0000-4000-8000-00000000e004",
        json!([project]),
        json!(["control"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-00000000e005",
        &control_cid,
        json!([project]),
        json!(["control"]),
    );

    let live_seq = harness.event_seq();
    let owner_wait_id = "20000000-0000-4000-8000-00000000e010";
    let owner_wait = value(&harness.owner(&request_with(
        "events.wait",
        Some(&inst),
        owner_wait_id,
        None,
        json!({"after_event_seq": live_seq, "wait_ms": 0}),
    )));
    assert_accepted(&owner_wait, "owner events.wait");
    assert_phase(
        &harness,
        owner_wait_id,
        IdRecord::Vacant,
        "owner events.wait success",
    );
    let owner_wait_again = value(&harness.owner(&request_with(
        "events.wait",
        Some(&inst),
        owner_wait_id,
        None,
        json!({"after_event_seq": live_seq, "wait_ms": 0}),
    )));
    assert_accepted(&owner_wait_again, "owner events.wait same-id");
    assert_phase(
        &harness,
        owner_wait_id,
        IdRecord::Vacant,
        "owner events.wait same-id",
    );

    let public_wait_id = "20000000-0000-4000-8000-00000000e011";
    let public_wait = meta
        .request(&request_with(
            "events.wait",
            Some(&inst),
            public_wait_id,
            None,
            json!({"after_event_seq": 0, "wait_ms": 0}),
        ))
        .expect("public events.wait first");
    let public_wait = value(&public_wait);
    assert_accepted(&public_wait, "public events.wait first");
    assert_phase(
        &harness,
        public_wait_id,
        IdRecord::Vacant,
        "public events.wait first must not retain Preparing",
    );
    let public_same = meta
        .request(&request_with(
            "events.wait",
            Some(&inst),
            public_wait_id,
            None,
            json!({"after_event_seq": 0, "wait_ms": 0}),
        ))
        .expect("public events.wait same-id");
    assert_accepted(&value(&public_same), "public events.wait same-id");
    assert_phase(
        &harness,
        public_wait_id,
        IdRecord::Vacant,
        "public events.wait same-id",
    );
    let other_q = value(&harness.owner(&request_with(
        "capabilities.get",
        Some(&inst),
        public_wait_id,
        None,
        json!({}),
    )));
    assert_accepted(&other_q, "other actor reuses vacant Q id");
    assert_phase(
        &harness,
        public_wait_id,
        IdRecord::Vacant,
        "Q id still vacant after other actor",
    );

    let quiet_id = "20000000-0000-4000-8000-00000000e012";
    let quiet = meta
        .request(&request_with(
            "events.wait",
            Some(&inst),
            quiet_id,
            None,
            json!({"after_event_seq": live_seq, "wait_ms": 0}),
        ))
        .expect("public events.wait live cursor");
    assert_accepted(&value(&quiet), "public events.wait live cursor");
    assert_phase(
        &harness,
        quiet_id,
        IdRecord::Vacant,
        "public events.wait no_change",
    );

    let future_id = "20000000-0000-4000-8000-00000000e013";
    let future_seq = harness.event_seq().saturating_add(1);
    let future = value(&harness.owner(&request_with(
        "events.wait",
        Some(&inst),
        future_id,
        None,
        json!({"after_event_seq": future_seq, "wait_ms": 0}),
    )));
    assert_error(&future, "invalid_request", "events.wait future cursor");
    assert_phase(
        &harness,
        future_id,
        IdRecord::Vacant,
        "events.wait future cursor",
    );
    let public_future_id = "20000000-0000-4000-8000-00000000e014";
    let public_future = meta
        .request(&request_with(
            "events.wait",
            Some(&inst),
            public_future_id,
            None,
            json!({"after_event_seq": future_seq, "wait_ms": 0}),
        ))
        .expect("public future cursor");
    assert_error(
        &value(&public_future),
        "invalid_request",
        "public events.wait future cursor",
    );
    assert_phase(
        &harness,
        public_future_id,
        IdRecord::Vacant,
        "public events.wait future cursor",
    );

    let scope_id = "20000000-0000-4000-8000-00000000e015";
    let scoped = control
        .request(&request_with(
            "events.wait",
            Some(&inst),
            scope_id,
            None,
            json!({"after_event_seq": 0, "wait_ms": 0}),
        ))
        .expect("control events.wait");
    assert_error(
        &value(&scoped),
        "permission_denied",
        "events.wait without metadata",
    );
    assert_phase(
        &harness,
        scope_id,
        IdRecord::Vacant,
        "events.wait scope miss",
    );

    let opget_id = "20000000-0000-4000-8000-00000000e016";
    let opget = value(&harness.owner(&request_with(
        "operation.get",
        Some(&inst),
        opget_id,
        None,
        json!({"operation_id": "20000000-0000-4000-8000-000000000000"}),
    )));
    assert_accepted(&opget, "owner operation.get");
    assert_phase(&harness, opget_id, IdRecord::Vacant, "owner operation.get");
    let public_opget_id = "20000000-0000-4000-8000-00000000e017";
    let public_opget = control
        .request(&request_with(
            "operation.get",
            Some(&inst),
            public_opget_id,
            None,
            json!({"operation_id": "20000000-0000-4000-8000-000000000000"}),
        ))
        .expect("public operation.get");
    assert_accepted(&value(&public_opget), "public operation.get");
    assert_phase(
        &harness,
        public_opget_id,
        IdRecord::Vacant,
        "public operation.get",
    );

    let plist_id = "20000000-0000-4000-8000-00000000e018";
    let plist = value(&harness.owner(&request_with(
        "pane.list",
        Some(&inst),
        plist_id,
        None,
        json!({"project_id": project}),
    )));
    assert_accepted(&plist, "owner pane.list");
    assert_phase(&harness, plist_id, IdRecord::Vacant, "owner pane.list");
    let public_plist_id = "20000000-0000-4000-8000-00000000e019";
    let public_plist = meta
        .request(&request_with(
            "pane.list",
            Some(&inst),
            public_plist_id,
            None,
            json!({"project_id": project}),
        ))
        .expect("public pane.list");
    assert_accepted(&value(&public_plist), "public pane.list");
    assert_phase(
        &harness,
        public_plist_id,
        IdRecord::Vacant,
        "public pane.list",
    );
    let missing_list_id = "20000000-0000-4000-8000-00000000e01a";
    let missing_list = value(&harness.owner(&request_with(
        "pane.list",
        Some(&inst),
        missing_list_id,
        None,
        json!({"project_id": "30000000-0000-4000-8000-000000000099"}),
    )));
    assert_error(&missing_list, "target_not_found", "pane.list unknown");
    assert_phase(
        &harness,
        missing_list_id,
        IdRecord::Vacant,
        "pane.list unknown",
    );

    let run_id = "20000000-0000-4000-8000-00000000e01b";
    let run_get = value(&harness.owner(&request_with(
        "run.get",
        Some(&inst),
        run_id,
        None,
        json!({"run_id": "50000000-0000-4000-8000-000000000000"}),
    )));
    assert_error(&run_get, "target_not_found", "run.get absent");
    assert_phase(&harness, run_id, IdRecord::Vacant, "run.get absent");
    let public_run_id = "20000000-0000-4000-8000-00000000e01c";
    let public_run = meta
        .request(&request_with(
            "run.get",
            Some(&inst),
            public_run_id,
            None,
            json!({"run_id": "50000000-0000-4000-8000-000000000000"}),
        ))
        .expect("public run.get");
    assert_error(
        &value(&public_run),
        "target_not_found",
        "public run.get absent",
    );
    assert_phase(
        &harness,
        public_run_id,
        IdRecord::Vacant,
        "public run.get absent",
    );

    let out_id = "20000000-0000-4000-8000-00000000e01d";
    let output = meta
        .request(&request_with(
            "output.read",
            Some(&inst),
            out_id,
            None,
            json!({
                "cursor": "c",
                "max_bytes": 1,
                "run_id": "50000000-0000-4000-8000-000000000000"
            }),
        ))
        .expect("public output.read");
    assert_error(
        &value(&output),
        "permission_denied",
        "output.read without read_output",
    );
    assert_phase(&harness, out_id, IdRecord::Vacant, "output.read scope");
    let owner_out_id = "20000000-0000-4000-8000-00000000e01e";
    let owner_out = value(&harness.owner(&request_with(
        "output.read",
        Some(&inst),
        owner_out_id,
        None,
        json!({
            "cursor": "c",
            "max_bytes": 1,
            "run_id": "50000000-0000-4000-8000-000000000000"
        }),
    )));
    assert_error(&owner_out, "target_not_found", "owner output.read absent");
    assert_phase(
        &harness,
        owner_out_id,
        IdRecord::Vacant,
        "owner output.read absent",
    );

    let caps_id = "20000000-0000-4000-8000-00000000e01f";
    let caps = value(&harness.owner(&request_with(
        "capabilities.get",
        Some(&inst),
        caps_id,
        None,
        json!({}),
    )));
    assert_accepted(&caps, "capabilities.get");
    assert_phase(&harness, caps_id, IdRecord::Vacant, "capabilities.get");
    let project_list_id = "20000000-0000-4000-8000-00000000e020";
    let project_list = value(&harness.owner(&request_with(
        "project.list",
        Some(&inst),
        project_list_id,
        None,
        json!({}),
    )));
    assert_accepted(&project_list, "project.list");
    assert_phase(
        &harness,
        project_list_id,
        IdRecord::Vacant,
        "project.list",
    );
    let clist_id = "20000000-0000-4000-8000-00000000e021";
    let clist = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        clist_id,
        None,
        json!({}),
    )));
    assert_accepted(&clist, "connection.list");
    assert_phase(&harness, clist_id, IdRecord::Vacant, "connection.list");
    let public_clist_id = "20000000-0000-4000-8000-00000000e022";
    let public_clist = meta
        .request(&request_with(
            "connection.list",
            Some(&inst),
            public_clist_id,
            None,
            json!({}),
        ))
        .expect("public connection.list");
    assert_error(
        &value(&public_clist),
        "permission_denied",
        "public connection.list",
    );
    assert_phase(
        &harness,
        public_clist_id,
        IdRecord::Vacant,
        "public connection.list",
    );

    let write_id = "20000000-0000-4000-8000-00000000e030";
    let write_params = json!({
        "pane_id": "40000000-0000-4000-8000-000000000000",
        "run_id": "50000000-0000-4000-8000-000000000000",
        "text": "x"
    });
    let write = value(&harness.owner(&request_with(
        "input.write",
        Some(&inst),
        write_id,
        None,
        write_params.clone(),
    )));
    assert_error(&write, "target_not_found", "input.write dummy");
    assert_phase(&harness, write_id, IdRecord::Done, "input.write Done");
    let write_replay = value(&harness.owner(&request_with(
        "input.write",
        Some(&inst),
        write_id,
        None,
        write_params,
    )));
    assert_eq!(write_replay, write, "input.write at-most-once");
    let write_diff = value(&harness.owner(&request_with(
        "input.write",
        Some(&inst),
        write_id,
        None,
        json!({
            "pane_id": "40000000-0000-4000-8000-000000000000",
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": "y"
        }),
    )));
    assert_error(
        &write_diff,
        "operation_conflict",
        "input.write different bytes",
    );
    let write_other = meta
        .request(&request_with(
            "capabilities.get",
            Some(&inst),
            write_id,
            None,
            json!({}),
        ))
        .expect("other actor vs write");
    assert_error(
        &value(&write_other),
        "permission_denied",
        "other actor vs retained write",
    );
    assert_phase(
        &harness,
        write_id,
        IdRecord::Done,
        "input.write remains Done",
    );

    let key_id = "20000000-0000-4000-8000-00000000e031";
    let key_params = json!({
        "key": "enter",
        "pane_id": "40000000-0000-4000-8000-000000000000",
        "run_id": "50000000-0000-4000-8000-000000000000"
    });
    let key = value(&harness.owner(&request_with(
        "input.key",
        Some(&inst),
        key_id,
        None,
        key_params.clone(),
    )));
    assert_error(&key, "target_not_found", "input.key dummy");
    assert_phase(&harness, key_id, IdRecord::Done, "input.key Done");
    let key_replay = value(&harness.owner(&request_with(
        "input.key",
        Some(&inst),
        key_id,
        None,
        key_params,
    )));
    assert_eq!(key_replay, key, "input.key at-most-once");

    meta.disconnect();
    let disc_id = "20000000-0000-4000-8000-00000000e040";
    let disconnected = meta.request(&request_with(
        "events.wait",
        Some(&inst),
        disc_id,
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    ));
    assert!(
        disconnected.is_none(),
        "disconnected events.wait is not retained"
    );
    assert_phase(
        &harness,
        disc_id,
        IdRecord::Vacant,
        "disconnect events.wait",
    );

    harness.close_generation();
    let close_id = "20000000-0000-4000-8000-00000000e041";
    let closed = harness.try_owner(&request_with(
        "events.wait",
        Some(&inst),
        close_id,
        None,
        json!({"after_event_seq": 0, "wait_ms": 0}),
    ));
    assert!(
        closed.is_none(),
        "generation close does not admit events.wait"
    );
    assert_phase(&harness, close_id, IdRecord::Vacant, "close events.wait");
    assert_phase(
        &harness,
        owner_wait_id,
        IdRecord::Vacant,
        "prior Q vacant after close",
    );
    assert_phase(
        &harness,
        public_wait_id,
        IdRecord::Vacant,
        "prior public Q vacant after close",
    );
    assert_phase(
        &harness,
        write_id,
        IdRecord::Done,
        "E/P Done remains after close",
    );
}

#[test]
fn receipt_send_policy_matrix() {
    let folder_a = TempDir::new("send-a");
    let folder_b = TempDir::new("send-b");
    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);
    let (project_a, revision) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000c1",
        0,
        &folder_a.text(),
    );
    let (project_b, revision) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000ce",
        revision,
        &folder_b.text(),
    );

    let two = harness.connect("two.exe");
    let two_id = pending_request(
        &two,
        "20000000-0000-4000-8000-0000000000c2",
        json!([project_a, project_b]),
        json!(["metadata", "control"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000c3",
        &two_id,
        json!([project_a, project_b]),
        json!(["metadata", "control"]),
    );
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000cf",
        None,
        json!({}),
    )));
    let mut expected_grants = vec![project_a.clone(), project_b.clone()];
    expected_grants.sort();
    assert_eq!(
        uuid_set(&connection_row(&listed, "two.exe")["granted_project_ids"]),
        expected_grants,
        "{listed}"
    );

    let select_null_id = "20000000-0000-4000-8000-0000000000d5";
    let public_null = two
        .request(&request_with(
            "project.select",
            Some(&inst),
            select_null_id,
            Some(revision),
            json!({"project_id": null}),
        ))
        .expect("public null with two grants");
    let public_null = value(&public_null);
    assert_accepted(&public_null, "two-grant select-null");
    assert_eq!(
        public_null["result"]["data"]["selected_project_id"],
        Value::Null
    );
    let stored_seq = public_null["event_seq"].as_u64().expect("seq");
    let stored_rev = public_null["topology_revision"].as_u64().expect("rev");
    assert_phase(
        &harness,
        select_null_id,
        IdRecord::Done,
        "select-null stored",
    );
    assert_stored_counters(
        &harness,
        select_null_id,
        &public_null,
        "select-null receipt",
    );

    let forget_a = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000c5",
        Some(stored_rev),
        json!({"project_id": project_a}),
    )));
    assert_accepted(&forget_a, "subset forget");
    let after_forget_seq = harness.event_seq();
    assert!(
        after_forget_seq > stored_seq,
        "forget advances current event_seq"
    );

    let replay_null = two.request(&request_with(
        "project.select",
        Some(&inst),
        select_null_id,
        Some(revision),
        json!({"project_id": null}),
    ));
    assert!(
        replay_null.is_none(),
        "two-grant select-null replay after subset forget must refuse send: {:?}",
        replay_null.as_ref().map(value)
    );
    assert_eq!(
        harness.event_seq(),
        after_forget_seq,
        "refused replay must not bump counters"
    );
    assert_phase(
        &harness,
        select_null_id,
        IdRecord::Done,
        "select-null still stored",
    );
    let owner_conflict = value(&harness.owner(&request_with(
        "capabilities.get",
        Some(&inst),
        select_null_id,
        None,
        json!({}),
    )));
    assert_error(
        &owner_conflict,
        "permission_denied",
        "stored public select-null remains a public actor record",
    );
    let listed = value(&harness.owner(&request_with(
        "project.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000d1",
        None,
        json!({}),
    )));
    assert_eq!(listed["result"]["data"]["selected_project_id"], Value::Null);
    let remaining: Vec<_> = listed["result"]["data"]["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .map(|row| row["project_id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(remaining, vec![project_b.clone()]);
    let connections = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000d2",
        None,
        json!({}),
    )));
    assert_eq!(
        connection_row(&connections, "two.exe")["granted_project_ids"],
        json!([project_b])
    );
    let forget_replay = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000c5",
        Some(stored_rev),
        json!({"project_id": project_a}),
    )));
    assert_eq!(forget_replay, forget_a);

    let targeted = two
        .request(&request_with(
            "project.select",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000c4",
            Some(forget_a["topology_revision"].as_u64().expect("rev")),
            json!({"project_id": project_b}),
        ))
        .expect("select remaining");
    let targeted = value(&targeted);
    assert_accepted(&targeted, "select remaining after subset forget");
    let forget_b = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000d9",
        Some(targeted["topology_revision"].as_u64().expect("rev")),
        json!({"project_id": project_b}),
    )));
    assert_accepted(&forget_b, "forget remaining");
    let replay_select = two.request(&request_with(
        "project.select",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000c4",
        Some(forget_a["topology_revision"].as_u64().expect("rev")),
        json!({"project_id": project_b}),
    ));
    assert!(
        replay_select.is_none(),
        "public targeted select replay after forget must not copy stored ACK: {:?}",
        replay_select.as_ref().map(value)
    );

    let control_only = harness.connect("control.exe");
    control_only
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000c6",
            None,
            json!({"project_ids": [], "scopes": ["control"]}),
        ))
        .expect("control pending");
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000c7",
        None,
        json!({}),
    )));
    let control_id = connection_row(&listed, "control.exe")["connection_id"]
        .as_str()
        .expect("control id")
        .to_owned();
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000c8",
        &control_id,
        json!([]),
        json!(["control"]),
    );
    let denied = control_only
        .request(&request_with(
            "project.list",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000c9",
            None,
            json!({}),
        ))
        .expect("control list");
    assert_error(&value(&denied), "permission_denied", "control-only list");
    let empty_null = control_only
        .request(&request_with(
            "project.select",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000c0",
            Some(0),
            json!({"project_id": null}),
        ))
        .expect("select-null without live grant");
    assert_error(
        &value(&empty_null),
        "permission_denied",
        "empty-grant select-null",
    );

    let output_only = harness.connect("output.exe");
    output_only
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000ca",
            None,
            json!({"project_ids": [], "scopes": ["read_output"]}),
        ))
        .expect("output pending");
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000cb",
        None,
        json!({}),
    )));
    let output_id = connection_row(&listed, "output.exe")["connection_id"]
        .as_str()
        .expect("output id")
        .to_owned();
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000cc",
        &output_id,
        json!([]),
        json!(["read_output"]),
    );
    let output_list = output_only
        .request(&request_with(
            "project.list",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000cd",
            None,
            json!({}),
        ))
        .expect("read_output list");
    assert_error(
        &value(&output_list),
        "permission_denied",
        "read_output list",
    );

    let folder_live = TempDir::new("send-live");
    let (project_live, live_rev) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000d0",
        forget_b["topology_revision"].as_u64().expect("rev"),
        &folder_live.text(),
    );
    let live = harness.connect("live.exe");
    let live_id = pending_request(
        &live,
        "20000000-0000-4000-8000-0000000000d4",
        json!([project_live]),
        json!(["metadata", "control"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000d6",
        &live_id,
        json!([project_live]),
        json!(["metadata", "control"]),
    );
    let public_null = live
        .request(&request_with(
            "project.select",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000d7",
            Some(live_rev),
            json!({"project_id": null}),
        ))
        .expect("one-grant public null");
    assert_accepted(&value(&public_null), "one-grant select-null");
    let selected = live
        .request(&request_with(
            "project.select",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000d8",
            Some(
                value(&public_null)["topology_revision"]
                    .as_u64()
                    .expect("rev"),
            ),
            json!({"project_id": project_live}),
        ))
        .expect("public select target");
    let selected = value(&selected);
    assert_accepted(&selected, "public select target");
    let same = live
        .request(&request_with(
            "project.select",
            Some(&inst),
            "20000000-0000-4000-8000-0000000000da",
            Some(selected["topology_revision"].as_u64().expect("rev")),
            json!({"project_id": project_live}),
        ))
        .expect("same selection");
    let same = value(&same);
    assert_accepted(&same, "same selection");
    assert_eq!(same["topology_revision"], selected["topology_revision"]);

    let folder_send = TempDir::new("send-gate");
    let (project_send, send_rev) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000f0",
        same["topology_revision"].as_u64().expect("rev"),
        &folder_send.text(),
    );
    let gated = harness.connect("gated.exe");
    let gated_id = pending_request(
        &gated,
        "20000000-0000-4000-8000-0000000000f1",
        json!([project_send]),
        json!(["metadata", "control"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000f2",
        &gated_id,
        json!([project_send]),
        json!(["metadata", "control"]),
    );
    let send_hold = PhaseHold::install_for(ProductPhase::SendGate, &gated.connection_id());
    let inflight_send = {
        let gated = gated.clone();
        let inst = inst.clone();
        std::thread::spawn(move || {
            gated.request(&request_with(
                "project.list",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000f3",
                None,
                json!({}),
            ))
        })
    };
    send_hold.wait_entered();
    let sibling_gate = control_only
        .hold_send_gate()
        .expect("idle sibling send_gate");
    let forget_send = {
        let harness = harness.clone();
        let inst = inst.clone();
        let project_send = project_send.clone();
        std::thread::spawn(move || {
            value(&harness.owner(&request_with(
                "project.forget",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000f4",
                Some(send_rev),
                json!({"project_id": project_send}),
            )))
        })
    };
    wait_client_cancelled(&gated, "SendGate list forget");
    send_hold.release_waiters();
    let gated_list = inflight_send.join().expect("join gated list");
    let forget_send = forget_send.join().expect("join forget at SendGate");
    send_hold.clear();
    drop(sibling_gate);
    assert!(
        gated_list.is_none(),
        "list at SendGate must refuse after covering forget: {:?}",
        gated_list.as_ref().map(value)
    );
    assert_accepted(&forget_send, "serial owner forget after SendGate drain");
    assert!(
        control_only.send_if_current(),
        "forget drains only the covering send_gate"
    );

    let cleared = value(&harness.owner(&request_with(
        "project.select",
        Some(&inst),
        "20000000-0000-4000-8000-000000000110",
        Some(forget_send["topology_revision"].as_u64().expect("rev")),
        json!({"project_id": null}),
    )));
    assert_accepted(
        &cleared,
        "clear selection before two-grant select-null send",
    );

    let folder_n1 = TempDir::new("null-a");
    let folder_n2 = TempDir::new("null-b");
    let (project_n1, n_rev) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000f5",
        cleared["topology_revision"].as_u64().expect("rev"),
        &folder_n1.text(),
    );
    let (project_n2, n_rev) = open_project(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000f6",
        n_rev,
        &folder_n2.text(),
    );
    let null_send = harness.connect("nullsend.exe");
    let null_send_id = pending_request(
        &null_send,
        "20000000-0000-4000-8000-0000000000f7",
        json!([project_n1, project_n2]),
        json!(["metadata", "control"]),
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000f8",
        &null_send_id,
        json!([project_n1, project_n2]),
        json!(["metadata", "control"]),
    );
    let null_hold = PhaseHold::install_for(ProductPhase::SendGate, &null_send.connection_id());
    let inflight_null = {
        let null_send = null_send.clone();
        let inst = inst.clone();
        std::thread::spawn(move || {
            null_send.request(&request_with(
                "project.select",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000f9",
                Some(n_rev),
                json!({"project_id": null}),
            ))
        })
    };
    null_hold.wait_entered();
    let current_rev = value(&harness.owner(&request_with(
        "project.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000fb",
        None,
        json!({}),
    )))["topology_revision"]
        .as_u64()
        .expect("rev after select-null commit");
    let forget_n1 = {
        let harness = harness.clone();
        let inst = inst.clone();
        let project_n1 = project_n1.clone();
        std::thread::spawn(move || {
            value(&harness.owner(&request_with(
                "project.forget",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000fa",
                Some(current_rev),
                json!({"project_id": project_n1}),
            )))
        })
    };
    wait_client_cancelled(&null_send, "SendGate select-null forget");
    null_hold.release_waiters();
    let null_ack = inflight_null.join().expect("join select-null send");
    let forget_n1 = forget_n1.join().expect("join subset forget");
    null_hold.clear();
    assert!(
        null_ack.is_none(),
        "select-null initial ACK at SendGate must refuse after subset forget: {:?}",
        null_ack.as_ref().map(value)
    );
    assert_accepted(&forget_n1, "subset forget during select-null send");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000f9",
        IdRecord::Done,
        "select-null sealed before refused send",
    );

    let hold = ObserveHold::install(&folder_live.text());
    let inflight = {
        let live = live.clone();
        let inst = inst.clone();
        std::thread::spawn(move || {
            live.request(&request_with(
                "project.list",
                Some(&inst),
                "20000000-0000-4000-8000-0000000000db",
                None,
                json!({}),
            ))
        })
    };
    hold.wait_entered();
    let forget_live = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000dc",
        Some(forget_n1["topology_revision"].as_u64().expect("rev")),
        json!({"project_id": project_live}),
    )));
    assert_accepted(&forget_live, "forget during list observe");
    hold.release_waiters();
    let stale_list = inflight.join().expect("join");
    hold.clear();
    assert!(
        stale_list.is_none(),
        "list generated then forget before send must refuse: {:?}",
        stale_list.as_ref().map(value)
    );
    assert!(
        control_only.send_if_current(),
        "unrelated connection continues"
    );
}

#[test]
fn pending_fresh_id_compatibility() {
    let harness = Harness::new(vec![winsmux_workspace::contract::ProjectId::new(
        "30000000-0000-4000-8000-000000000001",
    )
    .expect("seed")]);
    let client = harness.connect("fresh.exe");
    let first = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000d1",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
        ))
        .expect("first");
    let first = value(&first);
    assert_accepted(&first, "first pending");
    let replay = value(
        &client
            .request(&request_with(
                "connection.request",
                None,
                "20000000-0000-4000-8000-0000000000d1",
                None,
                json!({"project_ids": ["30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
            ))
            .expect("replay"),
    );
    assert_eq!(replay, first);
    let reversed = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000d2",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
        ))
        .expect("fresh id");
    let reversed = value(&reversed);
    assert_accepted(&reversed, "fresh same set");
    assert_eq!(
        reversed["result"]["data"]["connection_id"],
        first["result"]["data"]["connection_id"]
    );
    let changed = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000d3",
            None,
            json!({"project_ids": [], "scopes": ["control"]}),
        ))
        .expect("changed set");
    assert_error(&value(&changed), "invalid_request", "changed pending set");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000d3",
        IdRecord::Vacant,
        "changed set",
    );

    let harness = Harness::new(vec![
        winsmux_workspace::contract::ProjectId::new("30000000-0000-4000-8000-000000000001")
            .expect("seed"),
        winsmux_workspace::contract::ProjectId::new("30000000-0000-4000-8000-000000000002")
            .expect("seed"),
        winsmux_workspace::contract::ProjectId::new("30000000-0000-4000-8000-000000000003")
            .expect("seed"),
    ]);
    let inst = instance(&harness);
    let client = harness.connect("order.exe");
    let first = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000e1",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001", "30000000-0000-4000-8000-000000000002"], "scopes": ["metadata"]}),
        ))
        .expect("first");
    let first = value(&first);
    assert_accepted(&first, "two-project pending");
    let stored_seq = first["event_seq"].as_u64().expect("stored seq");
    let reversed = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000e2",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000002", "30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
        ))
        .expect("reversed");
    let reversed = value(&reversed);
    assert_accepted(&reversed, "reversed set");
    assert_eq!(
        reversed["result"]["data"]["connection_id"],
        first["result"]["data"]["connection_id"]
    );
    let other = harness.connect("other.exe");
    let other_pending = other
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000e3",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
        ))
        .expect("other connection");
    let other_pending = value(&other_pending);
    assert_accepted(&other_pending, "other pending");
    assert_ne!(
        other_pending["result"]["data"]["connection_id"],
        first["result"]["data"]["connection_id"]
    );
    let other_cid = other_pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("other cid")
        .to_owned();
    let other_decide = allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000e5",
        &other_cid,
        json!(["30000000-0000-4000-8000-000000000001"]),
        json!(["metadata"]),
    );
    assert_stored_counters(
        &harness,
        "20000000-0000-4000-8000-0000000000e5",
        &other_decide,
        "other decide stored",
    );
    let current_seq = harness.event_seq();
    assert!(
        current_seq > stored_seq,
        "unrelated decide must advance current event_seq: {current_seq} vs stored {stored_seq}"
    );
    let replay_allowed = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000e1",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001", "30000000-0000-4000-8000-000000000002"], "scopes": ["metadata"]}),
        ))
        .expect("stored request replay");
    assert_eq!(value(&replay_allowed), first);
    assert_eq!(
        value(&replay_allowed)["event_seq"]
            .as_u64()
            .expect("replay seq"),
        stored_seq
    );
    let fresh = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000e8",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001", "30000000-0000-4000-8000-000000000002"], "scopes": ["metadata"]}),
        ))
        .expect("fresh id current counter");
    let fresh = value(&fresh);
    assert_accepted(&fresh, "fresh id while pending");
    assert_eq!(
        fresh["result"]["data"]["connection_id"],
        first["result"]["data"]["connection_id"]
    );
    let fresh_seq = fresh["event_seq"].as_u64().expect("fresh seq");
    assert!(
        fresh_seq > stored_seq,
        "fresh ID stores current event_seq {fresh_seq} after unrelated events, not stored {stored_seq}"
    );
    assert_eq!(fresh_seq, current_seq);
    let stored_first = stored_receipt(&harness, "20000000-0000-4000-8000-0000000000e1");
    assert_eq!(stored_first.event_seq, Some(stored_seq));
    assert_ne!(stored_first.event_seq, Some(fresh_seq));
    let (now_seq, _) = harness.authorization().testing_counters();
    assert_eq!(now_seq, current_seq);

    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000e4",
        None,
        json!({}),
    )));
    let first_row = connection_row(&listed, "order.exe");
    assert_eq!(first_row["state"], json!("pending"));
    let forget = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000e6",
        Some(0),
        json!({"project_id": "30000000-0000-4000-8000-000000000002"}),
    )));
    assert_accepted(&forget, "forget B while first still pending");
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000e9",
        None,
        json!({}),
    )));
    let first_row = connection_row(&listed, "order.exe");
    assert_eq!(first_row["state"], json!("pending"), "{listed}");
    assert_eq!(
        first_row["requested_project_ids"],
        json!([
            "30000000-0000-4000-8000-000000000001",
            "30000000-0000-4000-8000-000000000002"
        ])
    );
    assert_eq!(first_row["granted_project_ids"], json!([]));
    let other_row = connection_row(&listed, "other.exe");
    assert_eq!(other_row["state"], json!("granted"));
    assert_eq!(
        other_row["granted_project_ids"],
        json!(["30000000-0000-4000-8000-000000000001"])
    );
    let other_replay = value(&harness.owner(&request_with(
        "connection.decide",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000e5",
        None,
        json!({
            "connection_id": other_cid,
            "decision": "allow",
            "project_ids": ["30000000-0000-4000-8000-000000000001"],
            "scopes": ["metadata"]
        }),
    )));
    assert_eq!(
        other_replay, other_decide,
        "historical owner decide after unrelated forget"
    );
    assert_stored_counters(
        &harness,
        "20000000-0000-4000-8000-0000000000e5",
        &other_decide,
        "historical decide counters unchanged",
    );

    let hist = harness.connect("hist.exe");
    let hist_id = pending_request(
        &hist,
        "20000000-0000-4000-8000-0000000000fc",
        json!(["30000000-0000-4000-8000-000000000003"]),
        json!(["metadata"]),
    );
    let hist_decide = allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000fd",
        &hist_id,
        json!(["30000000-0000-4000-8000-000000000003"]),
        json!(["metadata"]),
    );
    assert_stored_counters(
        &harness,
        "20000000-0000-4000-8000-0000000000fd",
        &hist_decide,
        "decide-then-forget stored",
    );
    let forget_hist = value(&harness.owner(&request_with(
        "project.forget",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000fe",
        Some(forget["topology_revision"].as_u64().expect("rev")),
        json!({"project_id": "30000000-0000-4000-8000-000000000003"}),
    )));
    assert_accepted(&forget_hist, "serial decide-then-forget");
    let hist_replay = value(&harness.owner(&request_with(
        "connection.decide",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000fd",
        None,
        json!({
            "connection_id": hist_id,
            "decision": "allow",
            "project_ids": ["30000000-0000-4000-8000-000000000003"],
            "scopes": ["metadata"]
        }),
    )));
    assert_eq!(
        hist_replay, hist_decide,
        "owner decide receipt survives target forget"
    );
    assert_stored_counters(
        &harness,
        "20000000-0000-4000-8000-0000000000fd",
        &hist_decide,
        "decide receipt after forget",
    );
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ff",
        None,
        json!({}),
    )));
    assert_eq!(
        connection_row(&listed, "hist.exe")["granted_project_ids"],
        json!([])
    );
    assert_eq!(
        connection_row(&listed, "hist.exe")["state"],
        json!("granted")
    );

    let first_cid = first["result"]["data"]["connection_id"]
        .as_str()
        .expect("cid")
        .to_owned();
    let allow_forgotten = value(&harness.owner(&request_with(
        "connection.decide",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ea",
        None,
        json!({
            "connection_id": first_cid,
            "decision": "allow",
            "project_ids": ["30000000-0000-4000-8000-000000000002"],
            "scopes": ["metadata"]
        }),
    )));
    assert_error(
        &allow_forgotten,
        "invalid_request",
        "allow forgotten project",
    );
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000ea",
        IdRecord::Vacant,
        "allow forgotten",
    );
    allow_connection(
        &harness,
        &inst,
        "20000000-0000-4000-8000-0000000000eb",
        &first_cid,
        json!(["30000000-0000-4000-8000-000000000001"]),
        json!(["metadata"]),
    );
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ec",
        None,
        json!({}),
    )));
    let first_row = connection_row(&listed, "order.exe");
    assert_eq!(first_row["state"], json!("granted"), "{listed}");
    assert_eq!(
        first_row["granted_project_ids"],
        json!(["30000000-0000-4000-8000-000000000001"])
    );
    let resurrect = client
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000e7",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000002"], "scopes": ["metadata"]}),
        ))
        .expect("forgotten id request");
    assert_error(
        &value(&resurrect),
        "invalid_request",
        "request forgotten id",
    );
    let revoked = value(&harness.owner(&request_with(
        "connection.revoke",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ed",
        None,
        json!({"connection_id": first_cid}),
    )));
    assert_accepted(&revoked, "revoke after subset grant");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000ed",
        IdRecord::Done,
        "revoke stored",
    );
    let listed = value(&harness.owner(&request_with(
        "connection.list",
        Some(&inst),
        "20000000-0000-4000-8000-0000000000ee",
        None,
        json!({}),
    )));
    let first_row = connection_row(&listed, "order.exe");
    assert_eq!(first_row["state"], json!("closing"), "{listed}");
    assert_eq!(first_row["granted_project_ids"], json!([]));

    let full = harness.connect("full.exe");
    let used = harness.allocations().snapshot().retained;
    let fill = harness
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill");
    let exhausted = full
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000ef",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
        ))
        .expect("pre-Preparing exhaust reply");
    assert_error(&value(&exhausted), "resource_exhausted", "pending exhaust");
    assert_phase(
        &harness,
        "20000000-0000-4000-8000-0000000000ef",
        IdRecord::Vacant,
        "exhaust vacant",
    );
    drop(fill);
    let recovered = full
        .request(&request_with(
            "connection.request",
            None,
            "20000000-0000-4000-8000-0000000000ef",
            None,
            json!({"project_ids": ["30000000-0000-4000-8000-000000000001"], "scopes": ["metadata"]}),
        ))
        .expect("same id after release");
    assert_accepted(&value(&recovered), "same id after release");
}
