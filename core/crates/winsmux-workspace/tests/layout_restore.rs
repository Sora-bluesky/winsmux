//! TASK-866 layout.save / layout.restore / host.stop automated journey tests.
//!
//! Tests drive the public owner/public contract through
//! `auth::testing::{Harness, Client}` and `parse_request` / `parse_snapshot` /
//! `serialize_snapshot`. A new `Harness` on the same isolated store root is
//! logical restart evidence in-process. It is not OS process exit and not
//! native CUA proof. Native same-binary host+launcher natural exit remains a
//! separate mandatory gate.
//!
//! `Authorization::testing_install_isolated_layout` is used only on a pristine
//! harness, before any request or connection, and with the same owned root for
//! restart. `testing_inject_layout_fault` is not available to this external
//! target. Class-wide store fault, ACL, lease, and allocation cases stay with
//! the package suite.

#![cfg(all(windows, debug_assertions))]

use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};
use winsmux_workspace::auth::testing::{Client, Harness};
use winsmux_workspace::contract::{
    parse_request, ConnectionId, OperationId, PaneId, ProjectId, Request, RunId,
};
use winsmux_workspace::{parse_snapshot, serialize_snapshot, Snapshot};

const WAIT: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(50);

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
        thread::sleep(POLL);
    }
    panic!("{context}");
}

fn current_revision(harness: &Harness) -> u64 {
    harness.authorization().testing_counters().1
}

fn assert_accepted(response: &Value, context: &str) {
    assert_eq!(response["accepted"], json!(true), "{context}: {response}");
    assert_eq!(response["error"], json!(null), "{context}: {response}");
}

fn assert_error(response: &Value, code: &str, context: &str) {
    assert_eq!(response["accepted"], json!(false), "{context}: {response}");
    assert_eq!(response["result"], json!(null), "{context}: {response}");
    assert_eq!(
        response["error"]["code"],
        json!(code),
        "{context}: {response}"
    );
}

fn unique_store_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "winsmux-866-{label}-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ))
}

fn harness_on(root: &Path) -> Harness {
    let harness = Harness::new(Vec::new());
    assert!(
        harness
            .authorization()
            .testing_install_isolated_layout(root),
        "pristine isolated layout install before requests or connections: {}",
        root.display()
    );
    harness
}

fn confirmed_path(root: &Path) -> PathBuf {
    root.join("confirmed.json")
}

fn backup_path(root: &Path) -> PathBuf {
    root.join("backup.json")
}

fn temp_path(root: &Path) -> PathBuf {
    root.join("temp.json")
}

fn read_if_present(path: &Path) -> Option<Vec<u8>> {
    match fs::read(path) {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => panic!("read {}: {error}", path.display()),
    }
}

fn load_snapshot(root: &Path) -> Snapshot {
    let bytes = fs::read(confirmed_path(root)).expect("confirmed snapshot bytes");
    let snapshot = parse_snapshot(&bytes).expect("parse confirmed snapshot");
    let encoded = serialize_snapshot(&snapshot).expect("serialize snapshot");
    let roundtrip = parse_snapshot(&encoded).expect("parse serialized snapshot");
    assert_eq!(snapshot, roundtrip, "public snapshot codec roundtrip");
    snapshot
}

fn run_typed(run: &str) -> RunId {
    RunId::new(run.to_owned()).expect("run id")
}

fn project_typed(id: &str) -> ProjectId {
    ProjectId::new(id.to_owned()).expect("project id")
}

fn operation_typed(id: &str) -> OperationId {
    OperationId::new(id.to_owned()).expect("operation id")
}

fn connection_typed(id: &str) -> ConnectionId {
    ConnectionId::new(id.to_owned()).expect("connection id")
}

fn wait_process(harness: &Harness, run: &str, want: &str, context: &str) {
    wait_until(
        Instant::now() + WAIT,
        || {
            let got = owner(harness, "run.get", None, json!({ "run_id": run }));
            got["accepted"] == json!(true)
                && got["result"]["data"]["run"]["process"] == json!(want)
        },
        context,
    );
}

struct OwnedRuns<'a> {
    harness: &'a Harness,
    runs: Vec<String>,
}

impl<'a> OwnedRuns<'a> {
    fn new(harness: &'a Harness) -> Self {
        Self {
            harness,
            runs: Vec::new(),
        }
    }

    fn track(&mut self, run: String) {
        self.runs.push(run);
    }

    fn interrupt_owned(&mut self, run: &str) {
        if !self.runs.iter().any(|owned| owned == run) {
            return;
        }
        interrupt_until_clean(self.harness, run);
        self.runs.retain(|owned| owned != run);
    }
}

impl Drop for OwnedRuns<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            while let Some(run) = self.runs.pop() {
                if let Err(payload) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    interrupt_until_clean(self.harness, &run);
                })) {
                    let message = payload
                        .downcast_ref::<String>()
                        .map(String::as_str)
                        .or_else(|| payload.downcast_ref::<&str>().copied())
                        .unwrap_or("owned run cleanup panicked");
                    eprintln!(
                        "owned run {run} cleanup failed during test unwind: {message}"
                    );
                }
            }
        } else {
            while let Some(run) = self.runs.pop() {
                interrupt_until_clean(self.harness, &run);
            }
        }
    }
}

fn session_clean_evidence(harness: &Harness, run: &str) -> bool {
    if !harness.authorization().testing_has_session(&run_typed(run)) {
        return true;
    }
    harness
        .authorization()
        .testing_session_clean_bits(&run_typed(run))
        .is_some_and(|bits| {
            bits.0
                && bits.1
                && bits.2
                && bits.3
                && bits.4
                && bits.5
                && bits.6
                && bits.7
                && bits.9.unwrap_or(0) == 0
        })
}

fn interrupt_until_clean(harness: &Harness, run: &str) {
    let current = owner(harness, "run.get", None, json!({ "run_id": run }));
    assert_accepted(&current, &format!("run.get {run}"));
    let process = current["result"]["data"]["run"]["process"]
        .as_str()
        .expect("process");
    if process != "exited" {
        let interrupted = owner(harness, "run.interrupt", None, json!({ "run_id": run }));
        assert_accepted(&interrupted, &format!("run.interrupt {run}"));
        assert_eq!(
            interrupted["result"]["data"]["run_id"],
            json!(run),
            "{interrupted}"
        );
    }
    wait_process(
        harness,
        run,
        "exited",
        &format!("{run} process exited after owned run.interrupt"),
    );
    wait_until(
        Instant::now() + WAIT,
        || session_clean_evidence(harness, run),
        &format!("{run} session clean bits after owned run.interrupt"),
    );
}

fn open_project(harness: &Harness) -> (PathBuf, String) {
    let fixture_parent = std::env::temp_dir().join(format!(
        "winsmux-866-project-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    let folder = fixture_parent.join(format!(
        "winsmux-866-プロジェクト space-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir_all(&folder).expect("owned Japanese/space project folder");
    let opened = owner(
        harness,
        "project.open",
        Some(current_revision(harness)),
        json!({ "path": folder.to_string_lossy() }),
    );
    assert_accepted(&opened, "project.open");
    let project_id = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("project_id")
        .to_owned();
    assert_eq!(
        opened["instance_id"],
        json!(instance(harness)),
        "{opened}"
    );
    (folder, project_id)
}

fn create_pwsh(harness: &Harness, project_id: &str) -> (String, String) {
    let created = owner(
        harness,
        "pane.create",
        Some(current_revision(harness)),
        json!({ "project_id": project_id, "shell_profile_id": "pwsh" }),
    );
    assert_accepted(&created, "pane.create");
    (
        created["result"]["data"]["pane_id"]
            .as_str()
            .expect("pane_id")
            .to_owned(),
        created["result"]["data"]["run_id"]
            .as_str()
            .expect("run_id")
            .to_owned(),
    )
}

fn split_pwsh(harness: &Harness, pane_id: &str) -> (String, String) {
    let split = owner(
        harness,
        "pane.split",
        Some(current_revision(harness)),
        json!({ "axis": "vertical", "pane_id": pane_id }),
    );
    assert_accepted(&split, "pane.split");
    (
        split["result"]["data"]["pane_id"]
            .as_str()
            .expect("split pane_id")
            .to_owned(),
        split["result"]["data"]["run_id"]
            .as_str()
            .expect("split run_id")
            .to_owned(),
    )
}

fn grant(harness: &Harness, exe: &str, projects: &[&str], scopes: &[&str]) -> Client {
    let client = harness.connect(exe);
    let pending = public(
        &client,
        None,
        "connection.request",
        None,
        json!({ "project_ids": projects, "scopes": scopes }),
    )
    .expect("connection.request must send");
    assert_accepted(&pending, "connection.request");
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
    assert_accepted(&allowed, "connection.decide");
    client
}

fn project_list(harness: &Harness) -> Value {
    let response = owner(harness, "project.list", None, json!({}));
    assert_accepted(&response, "project.list");
    assert_eq!(
        response["instance_id"],
        json!(instance(harness)),
        "{response}"
    );
    response["result"]["data"].clone()
}

fn pane_list(harness: &Harness, project_id: &str) -> Value {
    let response = owner(
        harness,
        "pane.list",
        None,
        json!({ "project_id": project_id }),
    );
    assert_accepted(&response, "pane.list");
    response["result"]["data"].clone()
}

fn pane_ids(data: &Value) -> Vec<String> {
    data["panes"]
        .as_array()
        .expect("panes")
        .iter()
        .map(|pane| {
            pane["pane_id"]
                .as_str()
                .expect("pane_id")
                .to_owned()
        })
        .collect()
}

fn assert_current_runs_null(data: &Value) {
    for pane in data["panes"].as_array().expect("panes") {
        assert_eq!(
            pane["current_run_id"],
            json!(null),
            "restored pane current_run_id must be null: {pane}"
        );
    }
}

fn assert_snapshot_omits_runs(snapshot: &Snapshot, runs: &[&str]) {
    let encoded = serde_json::to_value(snapshot).expect("snapshot json");
    let text = encoded.to_string();
    for run in runs {
        assert!(
            !text.contains(run),
            "snapshot must omit live run {run}: {encoded}"
        );
    }
    assert_eq!(encoded["schema_version"], json!(1), "{encoded}");
    for pane in encoded["panes"].as_array().expect("saved panes") {
        assert_eq!(pane["shell_profile_id"], json!("pwsh"), "{pane}");
        assert_eq!(pane["provider_profile"], json!(null), "{pane}");
        assert!(pane.get("current_run_id").is_none(), "{pane}");
        assert!(pane.get("run_id").is_none(), "{pane}");
    }
}

fn connection_state(harness: &Harness, connection_id: &str) -> Option<String> {
    harness
        .authorization()
        .testing_connection_snapshot(&connection_typed(connection_id))
        .map(|snapshot| snapshot.state.to_string())
}

fn assert_public_revoked(harness: &Harness, client: &Client, project_id: &str) {
    let listed = public(
        client,
        Some(&instance(harness)),
        "pane.list",
        None,
        json!({ "project_id": project_id }),
    );
    match listed {
        None => {}
        Some(response) => assert_eq!(
            response["accepted"],
            json!(false),
            "revoked public client must not keep using roots: {response}"
        ),
    }
    if let Some(state) = connection_state(harness, client.connection_id().as_str()) {
        assert!(
            state == "closing" || state == "finished" || state == "revoked",
            "public connection state after restore commit: {state}"
        );
    }
}

fn assert_store_snapshots_absent(root: &Path) {
    assert!(
        !confirmed_path(root).exists(),
        "confirmed.json must be unchanged/absent"
    );
    assert!(
        !backup_path(root).exists(),
        "backup.json must be unchanged/absent"
    );
    assert!(!temp_path(root).exists(), "temp.json must be unchanged/absent");
}

#[test]
fn layout_restore_journey_persists_tree_without_resuming_runs() {
    let root = unique_store_root("journey");
    let first = harness_on(&root);
    let first_instance = instance(&first);
    let (folder, project_id) = open_project(&first);
    let mut owned = OwnedRuns::new(&first);
    let (pane_a, run_a) = create_pwsh(&first, &project_id);
    owned.track(run_a.clone());
    wait_process(&first, &run_a, "running", "create run running");
    let (pane_b, run_b) = split_pwsh(&first, &pane_a);
    owned.track(run_b.clone());
    wait_process(&first, &run_b, "running", "split run running");
    let selected = owner(
        &first,
        "pane.select",
        Some(current_revision(&first)),
        json!({ "pane_id": pane_a }),
    );
    assert_accepted(&selected, "pane.select");
    let client = grant(
        &first,
        "pwsh",
        &[&project_id],
        &["metadata", "control"],
    );
    let projects_before = project_list(&first);
    let panes_before = pane_list(&first, &project_id);
    let public_panes = public(
        &client,
        Some(&instance(&first)),
        "pane.list",
        None,
        json!({ "project_id": project_id }),
    )
    .expect("public pane.list response");
    assert_accepted(&public_panes, "public pane.list before save");
    assert_eq!(
        pane_ids(&public_panes["result"]["data"]),
        pane_ids(&panes_before)
    );
    assert_eq!(public_panes["result"]["data"]["root"], panes_before["root"]);
    assert_eq!(projects_before["selected_project_id"], json!(project_id));
    assert_eq!(panes_before["selected_pane_id"], json!(pane_a));
    let mut expected_panes = vec![pane_a.clone(), pane_b.clone()];
    expected_panes.sort();
    assert_eq!(pane_ids(&panes_before), expected_panes);

    let saved = owner(&first, "layout.save", None, json!({}));
    assert_accepted(&saved, "layout.save while runs live");
    assert_eq!(saved["instance_id"], json!(first_instance), "{saved}");
    let live_a = owner(&first, "run.get", None, json!({ "run_id": run_a }));
    let live_b = owner(&first, "run.get", None, json!({ "run_id": run_b }));
    assert_accepted(&live_a, "run a still live after save");
    assert_accepted(&live_b, "run b still live after save");
    assert_ne!(live_a["result"]["data"]["run"]["process"], json!("exited"));
    assert_ne!(live_b["result"]["data"]["run"]["process"], json!("exited"));
    assert!(first.authorization().testing_has_session(&run_typed(&run_a)));
    assert!(first.authorization().testing_has_session(&run_typed(&run_b)));
    let live_snapshot = load_snapshot(&root);
    assert_snapshot_omits_runs(&live_snapshot, &[&run_a, &run_b]);
    assert_eq!(
        live_snapshot.projects.len(),
        1,
        "saved project set"
    );
    assert_eq!(live_snapshot.panes.len(), 2, "saved pane set");

    owned.interrupt_owned(&run_a);
    owned.interrupt_owned(&run_b);
    drop(owned);
    let stopped = owner(&first, "host.stop", None, json!({}));
    assert_accepted(&stopped, "host.stop after owned interrupts");
    assert_eq!(stopped["result"]["data"]["stopped"], json!(true), "{stopped}");
    assert_eq!(stopped["instance_id"], json!(first_instance), "{stopped}");
    assert!(first.generation_is_closed());
    assert!(!first.authentication_permitted());
    assert!(first.try_connect("pwsh").is_none());
    assert!(first
        .try_owner(&request(
            "project.list",
            Some(&first_instance),
            None,
            json!({})
        ))
        .is_none());
    let stop_snapshot = load_snapshot(&root);
    assert_snapshot_omits_runs(&stop_snapshot, &[&run_a, &run_b]);

    let second = harness_on(&root);
    let second_instance = instance(&second);
    assert_ne!(first_instance, second_instance, "new host instance");
    let empty = project_list(&second);
    assert_eq!(empty["projects"], json!([]), "{empty}");
    assert_eq!(empty["selected_project_id"], json!(null), "{empty}");
    assert!(!second.authorization().testing_has_session(&run_typed(&run_a)));
    assert!(!second.authorization().testing_has_session(&run_typed(&run_b)));

    let restored = owner(
        &second,
        "layout.restore",
        Some(current_revision(&second)),
        json!({}),
    );
    assert_accepted(&restored, "layout.restore after logical restart");
    assert_eq!(restored["instance_id"], json!(second_instance), "{restored}");
    assert_eq!(restored["result"]["data"]["restored"], json!(true), "{restored}");
    assert_eq!(
        restored["result"]["data"]["generation"],
        json!(stop_snapshot.generation.get()),
        "{restored}"
    );
    let projects_after = project_list(&second);
    let panes_after = pane_list(&second, &project_id);
    assert_eq!(
        projects_after["selected_project_id"],
        projects_before["selected_project_id"]
    );
    assert_eq!(
        projects_after["projects"][0]["project_id"],
        json!(project_id)
    );
    assert_eq!(pane_ids(&panes_after), pane_ids(&panes_before));
    assert_eq!(panes_after["root"], panes_before["root"]);
    assert_eq!(
        panes_after["selected_pane_id"],
        panes_before["selected_pane_id"]
    );
    assert_current_runs_null(&panes_after);
    assert!(!second.authorization().testing_has_session(&run_typed(&run_a)));
    assert!(!second.authorization().testing_has_session(&run_typed(&run_b)));
    assert_eq!(
        second.authorization().testing_selected().as_ref().map(|id| id.as_str()),
        Some(project_id.as_str())
    );
    let _ = (folder, client, pane_b);
}

#[test]
fn selection_pair_owner_public_null_stale_and_replay_keep_saved_state_consistent() {
    let root = unique_store_root("selection-pair");
    let harness = harness_on(&root);
    let (_folder_a, project_a) = open_project(&harness);
    let (_folder_b, project_b) = open_project(&harness);
    let mut owned = OwnedRuns::new(&harness);
    let (pane_a, run_a) = create_pwsh(&harness, &project_a);
    owned.track(run_a);
    let (pane_b, run_b) = create_pwsh(&harness, &project_b);
    owned.track(run_b);
    let client = grant(&harness, "pwsh", &[&project_b], &["metadata", "control"]);

    let clear_project = owner(
        &harness,
        "project.select",
        Some(current_revision(&harness)),
        json!({ "project_id": null }),
    );
    assert_accepted(&clear_project, "clear project before null pane selection");
    let counters = harness.authorization().testing_counters();
    let owner_null = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": null }),
    );
    assert_accepted(&owner_null, "owner pane.select null without project");
    assert_eq!(owner_null["result"]["data"]["selected_project_id"], json!(null));
    assert_eq!(owner_null["result"]["data"]["selected_pane_id"], json!(null));
    assert_eq!(harness.authorization().testing_counters(), counters);
    let public_null = public(
        &client,
        Some(&instance(&harness)),
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": null }),
    )
    .expect("public null response");
    assert_error(&public_null, "permission_denied", "public null without selected project");

    let select_a = owner(
        &harness,
        "project.select",
        Some(current_revision(&harness)),
        json!({ "project_id": project_a }),
    );
    assert_accepted(&select_a, "select A");
    let cross = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": pane_b }),
    );
    assert_accepted(&cross, "owner cross-project pane B");
    assert_eq!(cross["result"]["data"]["selected_project_id"], json!(project_b));
    assert_eq!(cross["result"]["data"]["selected_pane_id"], json!(pane_b));
    assert_eq!(project_list(&harness)["selected_project_id"], json!(project_b));
    assert_eq!(pane_list(&harness, &project_b)["selected_pane_id"], json!(pane_b));

    let save = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&save, "selection snapshot");
    let c_before = fs::read(confirmed_path(&root)).expect("C after selection");
    let before = harness.authorization().testing_counters();
    let stale = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness) + 1),
        json!({ "pane_id": pane_a }),
    );
    assert_error(&stale, "stale_topology", "stale cross-project pane A");
    assert_eq!(harness.authorization().testing_counters(), before);
    assert_eq!(project_list(&harness)["selected_project_id"], json!(project_b));
    assert_eq!(fs::read(confirmed_path(&root)).unwrap(), c_before);
    let denied = public(
        &client,
        Some(&instance(&harness)),
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": pane_a }),
    )
    .expect("public denied response");
    assert_error(&denied, "target_not_found", "B-only grant cannot discover A pane");
    assert_eq!(harness.authorization().testing_counters(), before);
    assert_eq!(fs::read(confirmed_path(&root)).unwrap(), c_before);

    let replay_id = uuid::Uuid::new_v4().to_string();
    let revision = current_revision(&harness);
    let first = owner_id(
        &harness,
        "pane.select",
        &replay_id,
        Some(revision),
        json!({ "pane_id": pane_a }),
    );
    assert_accepted(&first, "select A for replay");
    assert_eq!(first["result"]["data"]["selected_project_id"], json!(project_a));
    assert_eq!(first["result"]["data"]["selected_pane_id"], json!(pane_a));
    let after_first = harness.authorization().testing_counters();
    let replay = owner_id(
        &harness,
        "pane.select",
        &replay_id,
        Some(revision),
        json!({ "pane_id": pane_a }),
    );
    assert_eq!(replay, first, "same operation replay is byte-equivalent JSON");
    assert_eq!(harness.authorization().testing_counters(), after_first);
    let public_null_without_a_grant = public(
        &client,
        Some(&instance(&harness)),
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": null }),
    )
    .expect("public null response");
    assert_error(&public_null_without_a_grant, "permission_denied", "A lacks grant");

    let same_project = owner(
        &harness,
        "project.select",
        Some(current_revision(&harness)),
        json!({ "project_id": project_a }),
    );
    assert_accepted(&same_project, "same-project reselect clears pane");
    assert_eq!(same_project["result"]["data"]["selected_project_id"], json!(project_a));
    assert_eq!(same_project["result"]["data"]["selected_pane_id"], json!(null));
    assert_eq!(pane_list(&harness, &project_a)["selected_pane_id"], json!(null));
    let public_b = public(
        &client,
        Some(&instance(&harness)),
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": pane_b }),
    )
    .expect("public B response");
    assert_accepted(&public_b, "public selects permitted B");
    assert_eq!(public_b["result"]["data"]["selected_project_id"], json!(project_b));
    assert_eq!(public_b["result"]["data"]["selected_pane_id"], json!(pane_b));
    let public_clear = public(
        &client,
        Some(&instance(&harness)),
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": null }),
    )
    .expect("public clear response");
    assert_accepted(&public_clear, "public clears pane within granted B");
    assert_eq!(public_clear["result"]["data"]["selected_project_id"], json!(project_b));
    assert_eq!(public_clear["result"]["data"]["selected_pane_id"], json!(null));
    assert_eq!(project_list(&harness)["selected_project_id"], json!(project_b));
    drop(owned);
}

#[test]
fn clean_target_forget_does_not_block_on_sibling_run_but_global_exit_does() {
    let root = unique_store_root("forget-sibling");
    let harness = harness_on(&root);
    let (_folder_a, project_a) = open_project(&harness);
    let (_folder_b, project_b) = open_project(&harness);
    let mut owned = OwnedRuns::new(&harness);
    let (_pane_b, run_b) = create_pwsh(&harness, &project_b);
    owned.track(run_b.clone());
    wait_process(&harness, &run_b, "running", "sibling B still running");
    let saved = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&saved, "save while sibling live");
    let c_before = fs::read(confirmed_path(&root)).unwrap();

    let selected_a = owner(
        &harness,
        "project.select",
        Some(current_revision(&harness)),
        json!({ "project_id": project_a }),
    );
    assert_accepted(&selected_a, "select clean A");
    let forgotten_a = owner(
        &harness,
        "project.forget",
        Some(current_revision(&harness)),
        json!({ "project_id": project_a }),
    );
    assert_accepted(&forgotten_a, "forget clean A while B runs");
    assert_eq!(project_list(&harness)["selected_project_id"], json!(null));
    assert_eq!(project_list(&harness)["projects"].as_array().unwrap().len(), 1);
    wait_process(&harness, &run_b, "running", "B survives A forget");

    let before_denials = harness.authorization().testing_counters();
    let blocked_forget = owner(
        &harness,
        "project.forget",
        Some(current_revision(&harness)),
        json!({ "project_id": project_b }),
    );
    assert_error(&blocked_forget, "already_running", "cannot forget live B");
    let blocked_restore = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_error(&blocked_restore, "already_running", "global restore sees B");
    let blocked_stop = owner(&harness, "host.stop", None, json!({}));
    assert_error(&blocked_stop, "runtime_failed", "global stop sees B");
    assert_eq!(harness.authorization().testing_counters(), before_denials);
    assert_eq!(fs::read(confirmed_path(&root)).unwrap(), c_before);
    assert!(!harness.generation_is_closed());

    owned.interrupt_owned(&run_b);
    let forgotten_b = owner(
        &harness,
        "project.forget",
        Some(current_revision(&harness)),
        json!({ "project_id": project_b }),
    );
    assert_accepted(&forgotten_b, "forget B after actual session clean");
    let stopped = owner(&harness, "host.stop", None, json!({}));
    assert_accepted(&stopped, "stop with clean history and no projects");
    assert!(harness.generation_is_closed());
}

#[test]
fn public_save_restore_stop_denied_before_files_change() {
    let root = unique_store_root("public-deny");
    let harness = harness_on(&root);
    let client = harness.connect("pwsh");
    let host = instance(&harness);
    for operation in ["layout.save", "layout.restore", "host.stop"] {
        let revision = if operation == "layout.restore" {
            Some(current_revision(&harness))
        } else {
            None
        };
        let response = public(&client, Some(&host), operation, revision, json!({}))
            .expect("public reply");
        assert_error(&response, "permission_denied", operation);
    }
    assert_store_snapshots_absent(&root);
    assert!(!harness.generation_is_closed());
}

#[test]
fn restore_missing_corrupt_unknown_c_preserves_memory_grants_and_bytes() {
    let root = unique_store_root("c-failures");
    let harness = harness_on(&root);
    let first_save = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&first_save, "first empty save");
    let (folder, project_id) = open_project(&harness);
    let second_save = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&second_save, "later save with project");
    let client = grant(
        &harness,
        "pwsh",
        &[&project_id],
        &["metadata", "control"],
    );
    let memory_before = project_list(&harness);
    let counters_before = harness.authorization().testing_counters();
    let selected_before = harness.authorization().testing_selected();
    let confirmed = confirmed_path(&root);
    let backup = backup_path(&root);
    assert!(confirmed.exists(), "confirmed C after later save");
    assert!(backup.exists(), "backup B after later save");
    let backup_before = fs::read(&backup).expect("B bytes");
    assert!(parse_snapshot(&backup_before).is_ok(), "valid B");

    fs::write(&confirmed, b"not-a-snapshot").expect("corrupt owned C");
    assert!(parse_snapshot(b"not-a-snapshot").is_err());
    let corrupt = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_error(&corrupt, "persistence_failed", "corrupt C");
    assert_eq!(project_list(&harness), memory_before);
    assert_eq!(harness.authorization().testing_counters(), counters_before);
    assert_eq!(harness.authorization().testing_selected(), selected_before);
    assert_eq!(fs::read(&backup).expect("B after corrupt C"), backup_before);
    let public_after_corrupt = public(
        &client,
        Some(&instance(&harness)),
        "project.list",
        None,
        json!({}),
    )
    .expect("grant remains usable after refused restore");
    assert_accepted(&public_after_corrupt, "public project.list after corrupt C");

    let missing_evidence = root.join("confirmed.json.missing-evidence");
    assert!(
        harness
            .authorization()
            .testing_release_layout_guard_for_invalid_setup(),
        "release retained fixture guard before simulating an absent C"
    );
    fs::rename(&confirmed, &missing_evidence).expect("retain missing C evidence");
    let missing = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_error(&missing, "persistence_failed", "missing C with valid B");
    assert_eq!(project_list(&harness), memory_before);
    assert_eq!(harness.authorization().testing_counters(), counters_before);
    assert_eq!(fs::read(&backup).expect("B after missing C"), backup_before);
    assert!(!confirmed.exists());

    fs::write(
        &confirmed,
        br#"{"generation":0,"layouts":[],"panes":[],"projects":[],"schema_version":2,"selected_pane_id":null,"selected_project_id":null,"topology_revision":0}"#,
    )
    .expect("unknown schema C");
    assert!(parse_snapshot(&fs::read(&confirmed).expect("unknown C")).is_err());
    let unknown = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_error(&unknown, "persistence_failed", "unknown schema C with valid B");
    assert_eq!(project_list(&harness), memory_before);
    assert_eq!(harness.authorization().testing_counters(), counters_before);
    assert_eq!(harness.authorization().testing_selected(), selected_before);
    assert_eq!(fs::read(&backup).expect("B after unknown C"), backup_before);
    assert!(!harness.generation_is_closed());
    let public_after_unknown = public(
        &client,
        Some(&instance(&harness)),
        "project.list",
        None,
        json!({}),
    )
    .expect("grant remains usable after unknown schema C");
    assert_accepted(&public_after_unknown, "public project.list after unknown C");
    let _ = folder;
}

#[test]
fn valid_c_with_torn_temp_restores_c_not_b() {
    let root = unique_store_root("torn-temp");
    let harness = harness_on(&root);
    let first_save = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&first_save, "empty first save as B source");
    let (folder, project_id) = open_project(&harness);
    let selected = owner(
        &harness,
        "project.select",
        Some(current_revision(&harness)),
        json!({ "project_id": project_id }),
    );
    assert_accepted(&selected, "project.select");
    let second_save = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&second_save, "nonempty later save as C");
    let client = grant(
        &harness,
        "pwsh",
        &[&project_id],
        &["metadata", "control"],
    );
    let c_bytes = fs::read(confirmed_path(&root)).expect("C");
    let b_bytes = fs::read(backup_path(&root)).expect("B");
    let snapshot_c = parse_snapshot(&c_bytes).expect("valid C");
    let snapshot_b = parse_snapshot(&b_bytes).expect("valid B");
    assert_ne!(snapshot_c, snapshot_b, "C and B must differ");
    assert_eq!(snapshot_c.projects.len(), 1);
    assert_eq!(snapshot_b.projects.len(), 0);
    fs::write(temp_path(&root), b"{\"torn\":true").expect("torn owned T");
    assert!(parse_snapshot(b"{\"torn\":true").is_err());

    let restored = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_accepted(&restored, "restore valid C with torn T");
    let projects = project_list(&harness);
    assert_eq!(projects["projects"][0]["project_id"], json!(project_id));
    assert_eq!(projects["selected_project_id"], json!(project_id));
    assert_ne!(projects["projects"], json!([]), "must restore C, not empty B");
    assert_eq!(
        fs::read(confirmed_path(&root)).expect("C unchanged by restore"),
        c_bytes
    );
    assert_eq!(fs::read(backup_path(&root)).expect("B preserved"), b_bytes);
    assert_public_revoked(&harness, &client, &project_id);
    let _ = folder;
}

#[test]
fn foreign_instance_and_stale_topology_reject_without_io() {
    let root = unique_store_root("reject-no-io");
    let harness = harness_on(&root);
    let host = instance(&harness);
    let foreign = uuid::Uuid::new_v4().to_string();
    assert_ne!(host, foreign);

    let foreign_save = value(&harness.owner(&request(
        "layout.save",
        Some(&foreign),
        None,
        json!({}),
    )));
    assert_error(&foreign_save, "state_unknown", "foreign layout.save");
    let foreign_restore = value(&harness.owner(&request(
        "layout.restore",
        Some(&foreign),
        Some(current_revision(&harness)),
        json!({}),
    )));
    assert_error(&foreign_restore, "state_unknown", "foreign layout.restore");
    let stale = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness) + 1),
        json!({}),
    );
    assert_error(&stale, "stale_topology", "stale layout.restore");
    assert_store_snapshots_absent(&root);
    assert_eq!(harness.authorization().testing_counters(), (0, 0));
    assert!(!harness.generation_is_closed());
}

#[test]
fn identical_save_restore_replay_and_same_id_conflict() {
    let root = unique_store_root("replay-conflict");
    let harness = harness_on(&root);
    let save_id = uuid::Uuid::new_v4().to_string();
    let first_save = owner_id(&harness, "layout.save", &save_id, None, json!({}));
    assert_accepted(&first_save, "layout.save");
    assert_eq!(
        harness
            .authorization()
            .testing_replay_phase(&operation_typed(&save_id)),
        Some("done")
    );
    let confirmed_after_save = fs::read(confirmed_path(&root)).expect("C after save");
    let backup_after_save = read_if_present(&backup_path(&root));
    let replay_save = owner_id(&harness, "layout.save", &save_id, None, json!({}));
    assert_accepted(&replay_save, "identical layout.save replay");
    assert_eq!(replay_save["result"], first_save["result"]);
    assert_eq!(replay_save["topology_revision"], first_save["topology_revision"]);
    assert_eq!(
        fs::read(confirmed_path(&root)).expect("C after save replay"),
        confirmed_after_save
    );
    assert_eq!(read_if_present(&backup_path(&root)), backup_after_save);

    let restore_id = uuid::Uuid::new_v4().to_string();
    let expected = current_revision(&harness);
    let first_restore = owner_id(
        &harness,
        "layout.restore",
        &restore_id,
        Some(expected),
        json!({}),
    );
    assert_accepted(&first_restore, "layout.restore");
    let counters_after_restore = harness.authorization().testing_counters();
    let confirmed_after_restore = fs::read(confirmed_path(&root)).expect("C after restore");
    let replay_restore = owner_id(
        &harness,
        "layout.restore",
        &restore_id,
        Some(expected),
        json!({}),
    );
    assert_accepted(&replay_restore, "identical layout.restore replay");
    assert_eq!(replay_restore["result"], first_restore["result"]);
    assert_eq!(
        replay_restore["topology_revision"],
        first_restore["topology_revision"]
    );
    assert_eq!(
        harness.authorization().testing_counters(),
        counters_after_restore
    );
    assert_eq!(
        fs::read(confirmed_path(&root)).expect("C after restore replay"),
        confirmed_after_restore
    );

    let conflict = owner_id(
        &harness,
        "layout.restore",
        &save_id,
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_error(&conflict, "operation_conflict", "same id changed request");
    assert_eq!(
        fs::read(confirmed_path(&root)).expect("C after conflict"),
        confirmed_after_restore
    );
    assert!(!harness.generation_is_closed());
}

#[test]
fn live_reserved_preparing_restore_and_unclean_stop_denied() {
    let live_root = unique_store_root("live-occupancy");
    let live = harness_on(&live_root);
    let (live_folder, live_project) = open_project(&live);
    let mut live_owned = OwnedRuns::new(&live);
    let (_pane, live_run) = create_pwsh(&live, &live_project);
    live_owned.track(live_run.clone());
    wait_process(&live, &live_run, "running", "live occupancy run");
    let live_save = owner(&live, "layout.save", None, json!({}));
    assert_accepted(&live_save, "save with live run");
    let live_bytes = fs::read(confirmed_path(&live_root)).expect("live C");
    let live_restore = owner(
        &live,
        "layout.restore",
        Some(current_revision(&live)),
        json!({}),
    );
    assert_error(&live_restore, "already_running", "restore while live");
    let live_stop = owner(&live, "host.stop", None, json!({}));
    assert_error(&live_stop, "runtime_failed", "unclean host.stop");
    assert!(!live.generation_is_closed());
    assert_eq!(fs::read(confirmed_path(&live_root)).expect("live C after deny"), live_bytes);
    live_owned.interrupt_owned(&live_run);
    drop(live_owned);

    let reserved_root = unique_store_root("reserved-occupancy");
    let reserved = harness_on(&reserved_root);
    let (reserved_folder, reserved_project) = open_project(&reserved);
    let mut reserved_owned = OwnedRuns::new(&reserved);
    let (_reserved_pane, reserved_run) = create_pwsh(&reserved, &reserved_project);
    reserved_owned.track(reserved_run.clone());
    wait_process(&reserved, &reserved_run, "running", "reserved setup run");
    reserved_owned.interrupt_owned(&reserved_run);
    drop(reserved_owned);
    let reserved_save = owner(&reserved, "layout.save", None, json!({}));
    assert_accepted(&reserved_save, "save before reserved occupancy");
    let reserved_bytes = fs::read(confirmed_path(&reserved_root)).expect("reserved C");
    assert!(
        reserved.authorization().testing_set_occupancy(
            &project_typed(&reserved_project),
            false,
            true,
        ),
        "reserved occupancy on opened project"
    );
    let reserved_restore = owner(
        &reserved,
        "layout.restore",
        Some(current_revision(&reserved)),
        json!({}),
    );
    assert_error(
        &reserved_restore,
        "operation_conflict",
        "restore while reserved",
    );
    let reserved_stop = owner(&reserved, "host.stop", None, json!({}));
    assert_error(&reserved_stop, "runtime_failed", "stop while reserved");
    assert!(!reserved.generation_is_closed());
    assert_eq!(
        fs::read(confirmed_path(&reserved_root)).expect("reserved C after deny"),
        reserved_bytes
    );

    let preparing_root = unique_store_root("preparing-occupancy");
    let preparing = harness_on(&preparing_root);
    let preparing_save = owner(&preparing, "layout.save", None, json!({}));
    assert_accepted(&preparing_save, "save before preparing occupancy");
    let preparing_bytes = fs::read(confirmed_path(&preparing_root)).expect("preparing C");
    preparing
        .authorization()
        .testing_insert_preparing_run(
            ProjectId::new(uuid::Uuid::new_v4().to_string()).expect("preparing project"),
            PaneId::new(uuid::Uuid::new_v4().to_string()).expect("preparing pane"),
            RunId::new(uuid::Uuid::new_v4().to_string()).expect("preparing run"),
        )
        .expect("preparing session");
    let preparing_restore = owner(
        &preparing,
        "layout.restore",
        Some(current_revision(&preparing)),
        json!({}),
    );
    assert_error(
        &preparing_restore,
        "operation_conflict",
        "restore while preparing",
    );
    let preparing_stop = owner(&preparing, "host.stop", None, json!({}));
    assert_error(&preparing_stop, "runtime_failed", "stop while preparing");
    assert!(!preparing.generation_is_closed());
    assert_eq!(
        fs::read(confirmed_path(&preparing_root)).expect("preparing C after deny"),
        preparing_bytes
    );
    let _ = (live_folder, reserved_folder);
}

#[test]
fn changed_root_identity_does_not_restore_different_folder() {
    let root = unique_store_root("root-identity");
    let harness = harness_on(&root);
    let (folder, project_id) = open_project(&harness);
    let saved = owner(&harness, "layout.save", None, json!({}));
    assert_accepted(&saved, "save original root identity");
    let client = grant(
        &harness,
        "pwsh",
        &[&project_id],
        &["metadata", "control"],
    );
    let memory_before = project_list(&harness);
    assert_eq!(memory_before["projects"][0]["root_state"], json!("verified"));
    let selected_before = harness.authorization().testing_selected();
    let counters_before = harness.authorization().testing_counters();
    let c_before = fs::read(confirmed_path(&root)).expect("C before root change");
    let retained = folder.with_file_name(format!(
        "{} retained",
        folder
            .file_name()
            .expect("project folder name")
            .to_string_lossy()
    ));
    fs::rename(&folder, &retained).expect("retain original project folder");
    fs::create_dir_all(&folder).expect("replacement folder at saved path");

    let restored = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_error(&restored, "root_changed", "changed root identity");
    let mut observed_after = memory_before.clone();
    observed_after["projects"][0]["root_state"] = json!("changed");
    assert_eq!(project_list(&harness), observed_after);
    assert_eq!(harness.authorization().testing_selected(), selected_before);
    assert_eq!(harness.authorization().testing_counters(), counters_before);
    assert_eq!(fs::read(confirmed_path(&root)).expect("C after root_changed"), c_before);
    assert!(!harness.generation_is_closed());
    let public_listed = public(
        &client,
        Some(&instance(&harness)),
        "project.list",
        None,
        json!({}),
    )
    .expect("grants remain after refused root_changed restore");
    assert_accepted(&public_listed, "public project.list after root_changed");
    let public_data = &public_listed["result"]["data"];
    assert_eq!(public_data["projects"][0]["project_id"], json!(project_id));
    assert_eq!(public_data["projects"][0]["root_state"], json!("changed"));
    assert_eq!(public_data["projects"][0]["path"], json!(null));
    assert_eq!(public_data["projects"][0]["display_name"], json!(null));
}

#[test]
fn save_and_stop_revalidate_all_roots_before_persistence_or_close() {
    for operation in ["layout.save", "host.stop"] {
        for (stage, missing) in [
            ("first-changed", false),
            ("first-missing", true),
            ("later-changed", false),
            ("later-missing", true),
        ] {
            let root = unique_store_root(&format!("root-save-{operation}-{stage}"));
            let harness = harness_on(&root);
            let later = stage.starts_with("later");
            if later {
                assert_accepted(&owner(&harness, "layout.save", None, json!({})), "seed B");
            }
            let (first_folder, first_project) = open_project(&harness);
            let (folder, project_id) = if later {
                open_project(&harness)
            } else {
                (first_folder.clone(), first_project.clone())
            };
            if later {
                assert_accepted(&owner(&harness, "layout.save", None, json!({})), "seed C");
            }
            let client = grant(&harness, "pwsh", &[&project_id], &["metadata", "control"]);
            let before_projects = project_list(&harness);
            let before_selection = harness.authorization().testing_selected();
            let before_counters = harness.authorization().testing_counters();
            let before_c = read_if_present(&confirmed_path(&root));
            let before_b = read_if_present(&backup_path(&root));

            let retained = folder.with_file_name(format!(
                "{}-retained", folder.file_name().expect("folder name").to_string_lossy()
            ));
            fs::rename(&folder, &retained).expect("retain opened project root");
            if !missing {
                fs::create_dir(&folder).expect("replace root at cached path");
            }
            let operation_id = uuid::Uuid::new_v4().to_string();
            let refused = owner_id(&harness, operation, &operation_id, None, json!({}));
            assert_error(
                &refused,
                if missing { "target_not_found" } else { "root_changed" },
                &format!("{operation} {stage}"),
            );
            assert_eq!(
                harness.authorization().testing_replay_phase(&operation_typed(&operation_id)),
                Some("done"),
                "failed owner effect must be terminal"
            );
            assert_eq!(read_if_present(&confirmed_path(&root)), before_c, "C: {operation} {stage}");
            assert_eq!(read_if_present(&backup_path(&root)), before_b, "B: {operation} {stage}");
            assert_eq!(harness.authorization().testing_counters(), before_counters);
            assert_eq!(harness.authorization().testing_selected(), before_selection);
            assert!(!harness.generation_is_closed());
            let after_projects = project_list(&harness);
            assert_eq!(after_projects["selected_project_id"], before_projects["selected_project_id"]);
            assert_eq!(after_projects["projects"].as_array().map(Vec::len),
                       before_projects["projects"].as_array().map(Vec::len));
            let public_list = public(&client, Some(&instance(&harness)), "project.list", None, json!({}))
                .expect("grant retained after refused save");
            assert_accepted(&public_list, "grant retained");
            assert_eq!(public_list["result"]["data"]["projects"].as_array().map(Vec::len),
                       Some(1));

            if !missing {
                let displaced = folder.with_file_name(format!(
                    "{}-replacement", folder.file_name().expect("folder name").to_string_lossy()
                ));
                fs::rename(&folder, &displaced).expect("move replacement aside");
            }
            fs::rename(&retained, &folder).expect("restore original root");
            let replay = owner_id(&harness, operation, &operation_id, None, json!({}));
            assert_eq!(replay, refused, "same ID must retain the first result");
            assert_eq!(read_if_present(&confirmed_path(&root)), before_c);
            assert_eq!(read_if_present(&backup_path(&root)), before_b);
            let recovered = owner(&harness, operation, None, json!({}));
            assert_accepted(&recovered, "fresh ID after original root restored");
            assert!(read_if_present(&confirmed_path(&root)).is_some());
            assert_eq!(harness.generation_is_closed(), operation == "host.stop");
        }
    }
}

#[test]
fn pane_selection_reobserves_root_and_retains_pair_grants_and_c_on_failure() {
    let root = unique_store_root("pane-root-state");
    let (folder, project_id, pane_id) = {
        let first = harness_on(&root);
        let (folder, project_id) = open_project(&first);
        let mut owned = OwnedRuns::new(&first);
        let (pane_id, run_id) = create_pwsh(&first, &project_id);
        owned.track(run_id.clone());
        owned.interrupt_owned(&run_id);
        drop(owned);
        let saved = owner(&first, "layout.save", None, json!({}));
        assert_accepted(&saved, "save pane before new host");
        let stopped = owner(&first, "host.stop", None, json!({}));
        assert_accepted(&stopped, "stop after clean pane run");
        (folder, project_id, pane_id)
    };
    let harness = harness_on(&root);
    let restored = owner(
        &harness,
        "layout.restore",
        Some(current_revision(&harness)),
        json!({}),
    );
    assert_accepted(&restored, "restore pane in new host without run");
    let cleared = owner(
        &harness,
        "project.select",
        Some(current_revision(&harness)),
        json!({ "project_id": null }),
    );
    assert_accepted(&cleared, "clear selection before root replacement");
    let client = grant(&harness, "pwsh", &[&project_id], &["metadata", "control"]);
    let c_before = fs::read(confirmed_path(&root)).unwrap();
    let before = harness.authorization().testing_counters();
    let retained = folder.with_file_name(format!(
        "{} retained",
        folder.file_name().unwrap().to_string_lossy()
    ));
    fs::rename(&folder, &retained).expect("retain original root");

    let unavailable = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": pane_id }),
    );
    assert_error(&unavailable, "target_not_found", "pane root unavailable");
    assert_eq!(harness.authorization().testing_selected(), None);
    assert_eq!(harness.authorization().testing_counters(), before);
    assert_eq!(fs::read(confirmed_path(&root)).unwrap(), c_before);
    fs::create_dir_all(&folder).expect("different folder at same path");
    let changed = owner(
        &harness,
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": pane_id }),
    );
    assert_error(&changed, "root_changed", "pane root identity changed");
    let public_changed = public(
        &client,
        Some(&instance(&harness)),
        "pane.select",
        Some(current_revision(&harness)),
        json!({ "pane_id": pane_id }),
    )
    .expect("public changed root response");
    assert_error(&public_changed, "root_changed", "public pane root identity changed");
    assert_eq!(harness.authorization().testing_selected(), None);
    assert_eq!(harness.authorization().testing_counters(), before);
    assert_eq!(fs::read(confirmed_path(&root)).unwrap(), c_before);
    let public_list = public(
        &client,
        Some(&instance(&harness)),
        "project.list",
        None,
        json!({}),
    )
    .expect("grant still usable");
    assert_accepted(&public_list, "grant remains after root rejection");
}
