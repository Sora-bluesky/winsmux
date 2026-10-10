#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::fs;
use std::process::Command;
use std::os::windows::fs::OpenOptionsExt;
use std::path::PathBuf;
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::{parse_request, Request};
use winsmux_workspace::memory_testing::ObserveHold;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "winsmux-artifact-{}-{}", std::process::id(), uuid::Uuid::new_v4()
        ));
        fs::create_dir(&path).expect("test root");
        Self(path)
    }

    fn text(&self) -> String { self.0.to_string_lossy().into_owned() }
}

impl Drop for TempDir {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

fn request(harness: &Harness, id: u32, operation: &str, revision: Option<u64>, params: Value) -> Request {
    parse_request(&serde_json::to_vec(&json!({
        "schema_version": 1,
        "instance_id": harness.instance_id(),
        "operation_id": format!("{id:08x}-0000-4000-8000-000000000867"),
        "expected_topology_revision": revision,
        "operation": operation,
        "params": params,
    })).expect("json")).expect("valid request")
}

fn value(response: &winsmux_workspace::Response) -> Value {
    serde_json::to_value(response).expect("response json")
}

fn owner(h: &Harness, id: u32, op: &str, revision: Option<u64>, params: Value) -> Value {
    value(&h.owner(&request(h, id, op, revision, params)))
}

fn error(response: &Value) -> &str {
    response["error"]["code"].as_str().expect("error code")
}

fn setup() -> (Harness, TempDir, TempDir, String) {
    let project = TempDir::new();
    let layout = TempDir::new();
    let harness = Harness::new(Vec::new());
    assert!(harness.authorization().testing_install_isolated_layout(&layout.0.join("v1")));
    let opened = owner(&harness, 1, "project.open", Some(0), json!({"path":project.text()}));
    assert_eq!(opened["accepted"], true, "{opened}");
    let id = opened["result"]["data"]["project_id"].as_str().unwrap().to_owned();
    (harness, project, layout, id)
}

#[test]
fn selected_file_is_pinned_bounded_and_replayed_without_writes() {
    let (h, project, _layout, project_id) = setup();
    let text = "こんにちは\n\\\"";
    fs::write(project.0.join("result.txt"), text.as_bytes()).unwrap();
    fs::write(project.0.join("binary.bin"), [0, 255, 42]).unwrap();
    let before = fs::read(project.0.join("result.txt")).unwrap();

    let params = json!({"project_id":project_id,"relative_path":"result.txt","run_id":null});
    let registered = owner(&h, 2, "artifact.register", None, params.clone());
    assert_eq!(registered["accepted"], true, "{registered}");
    let reference = &registered["result"]["data"]["artifact"];
    let id = reference["artifact_id"].as_str().unwrap().to_owned();
    assert_eq!(reference["association"], Value::Null);
    assert_eq!(registered, owner(&h, 2, "artifact.register", None, params));
    assert_eq!(error(&owner(&h, 2, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"binary.bin","run_id":null}))), "operation_conflict");

    let listed = owner(&h, 3, "artifact.list", None, json!({"project_id":project_id}));
    assert_eq!(listed["result"]["data"]["registered"], json!([reference]));
    assert_eq!(listed["result"]["data"]["git_candidates"], json!([]));
    assert_eq!(listed["result"]["data"]["git_candidates_error"], Value::Null);
    let full = owner(&h, 4, "artifact.read", None, json!({"artifact_id":id,"max_bytes":100}));
    assert_eq!(full["result"]["data"]["text"], text);
    assert_eq!(full["result"]["data"]["truncated"], false);
    assert_eq!(full["result"]["data"]["size_bytes"], before.len());
    let split = owner(&h, 5, "artifact.read", None, json!({"artifact_id":id,"max_bytes":4}));
    assert_eq!(split["result"]["data"]["text"], "こ");
    assert_eq!(split["result"]["data"]["truncated"], true);

    let binary = owner(&h, 6, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"binary.bin","run_id":null}));
    let binary_id = binary["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let read_binary = owner(&h, 7, "artifact.read", None, json!({"artifact_id":binary_id,"max_bytes":10}));
    assert_eq!(read_binary["result"]["data"]["kind"], "binary");
    assert_eq!(read_binary["result"]["data"]["text"], Value::Null);
    assert_eq!(read_binary["result"]["data"]["size_bytes"], 3);
    assert_eq!(fs::read(project.0.join("result.txt")).unwrap(), before);
}

#[test]
fn missing_replaced_hardlinked_and_directory_targets_fail_closed() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("old.txt"), b"old").unwrap();
    fs::write(project.0.join("second.txt"), b"second").unwrap();
    let registered = owner(&h, 10, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"old.txt","run_id":null}));
    let id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    fs::rename(project.0.join("old.txt"), project.0.join("moved.txt")).unwrap();
    assert_eq!(error(&owner(&h, 11, "artifact.read", None, json!({"artifact_id":id,"max_bytes":10}))), "target_not_found");
    fs::write(project.0.join("old.txt"), b"replacement").unwrap();
    assert_eq!(error(&owner(&h, 12, "artifact.read", None, json!({"artifact_id":id,"max_bytes":10}))), "root_changed");
    fs::hard_link(project.0.join("second.txt"), project.0.join("alias.txt")).unwrap();
    assert_eq!(error(&owner(&h, 13, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"alias.txt","run_id":null}))), "unsupported_file");
    fs::create_dir(project.0.join("directory")).unwrap();
    assert_eq!(error(&owner(&h, 14, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"directory","run_id":null}))), "unsupported_file");
    assert_eq!(error(&owner(&h, 15, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"absent.txt","run_id":null}))), "target_not_found");
    assert_eq!(error(&owner(&h, 16, "artifact.diff", None, json!({"artifact_id":id,"max_bytes":10}))), "root_changed");
}

#[test]
fn quote_expansion_stays_within_wire_frame() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("quotes.txt"), vec![b'"'; 600_000]).unwrap();
    let registered = owner(&h, 20, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"quotes.txt","run_id":null}));
    let id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let read = owner(&h, 21, "artifact.read", None, json!({"artifact_id":id,"max_bytes":600000}));
    assert_eq!(read["accepted"], true, "{read}");
    assert_eq!(read["result"]["data"]["truncated"], true);
    assert!(read["result"]["data"]["text"].as_str().unwrap().len() < 600_000);
    assert!(serde_json::to_vec(&read).unwrap().len() <= 1_048_576);
}

#[test]
fn client_grant_and_restore_epoch_gate_reads() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let client = h.connect("selected-client.exe");
    let pending = value(&client.request(&request(&h, 30, "connection.request", None,
        json!({"project_ids":[project_id],"scopes":["read_output"]}))).unwrap());
    let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
    let denied = client.request(&request(&h, 31, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}))).unwrap();
    assert_eq!(error(&value(&denied)), "permission_denied");
    let granted = owner(&h, 32, "connection.decide", None,
        json!({"connection_id":connection_id,"decision":"allow","project_ids":[project_id],"scopes":["read_output"]}));
    assert_eq!(granted["accepted"], true, "{granted}");
    let registered = value(&client.request(&request(&h, 33, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}))).unwrap());
    assert_eq!(registered["accepted"], true, "{registered}");
    let id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let read = value(&client.request(&request(&h, 34, "artifact.read", None,
        json!({"artifact_id":id,"max_bytes":100}))).unwrap());
    assert_eq!(read["result"]["data"]["text"], "selected");
    let other = TempDir::new();
    fs::write(other.0.join("other.txt"), b"other").unwrap();
    let opened_other = owner(&h, 341, "project.open", Some(1), json!({"path":other.text()}));
    let other_id = opened_other["result"]["data"]["project_id"].as_str().unwrap();
    let other_denied = value(&client.request(&request(&h, 342, "artifact.register", None,
        json!({"project_id":other_id,"relative_path":"other.txt","run_id":null}))).unwrap());
    assert_eq!(error(&other_denied), "permission_denied");
    let saved = owner(&h, 35, "layout.save", None, json!({}));
    assert_eq!(saved["accepted"], true, "{saved}");
    let stale = owner(&h, 36, "layout.restore", Some(0), json!({}));
    assert_eq!(error(&stale), "stale_topology");
    assert_eq!(owner(&h, 37, "artifact.read", None, json!({"artifact_id":id,"max_bytes":100}))["result"]["data"]["text"], "selected");
    client.disconnect();
    let revision = saved["topology_revision"].as_u64().unwrap();
    let restored = owner(&h, 38, "layout.restore", Some(revision), json!({}));
    assert_eq!(restored["accepted"], true, "{restored}");
    assert_eq!(error(&owner(&h, 39, "artifact.read", None, json!({"artifact_id":id,"max_bytes":100}))), "target_not_found");
}

#[test]
fn forget_during_blocked_registration_cannot_publish_reference() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let hold = ObserveHold::install(project.text());
    let thread_h = h.clone();
    let thread_project = project_id.clone();
    let worker = std::thread::spawn(move || owner(&thread_h, 40, "artifact.register", None,
        json!({"project_id":thread_project,"relative_path":"selected.txt","run_id":null})));
    hold.wait_entered();
    let forgotten = owner(&h, 41, "project.forget", Some(1), json!({"project_id":project_id}));
    assert_eq!(forgotten["accepted"], true, "{forgotten}");
    hold.release_waiters();
    hold.clear();
    let result = worker.join().unwrap();
    assert_eq!(error(&result), "root_changed");
    assert_eq!(fs::read(project.0.join("selected.txt")).unwrap(), b"selected");
}

#[test]
fn path_escape_and_leaf_reparse_never_return_outside_bytes() {
    let (h, project, _layout, project_id) = setup();
    let outside = TempDir::new();
    fs::write(outside.0.join("private.txt"), b"outside-sentinel").unwrap();
    for path in ["../private.txt", "C:/private.txt", "a:stream", "a\\b", "a/../private.txt"] {
        let raw = serde_json::to_vec(&json!({
            "schema_version":1,
            "instance_id":h.instance_id(),
            "operation_id":"60000000-0000-4000-8000-000000000867",
            "expected_topology_revision":null,
            "operation":"artifact.register",
            "params":{"project_id":project_id,"relative_path":path,"run_id":null},
        })).unwrap();
        assert!(parse_request(&raw).is_err(), "{path} passed the wire boundary");
    }
    if std::os::windows::fs::symlink_file(outside.0.join("private.txt"), project.0.join("link.txt")).is_ok() {
        assert_eq!(error(&owner(&h, 50, "artifact.register", None,
            json!({"project_id":project_id,"relative_path":"link.txt","run_id":null}))), "unsupported_file");
    }
    if std::os::windows::fs::symlink_dir(&outside.0, project.0.join("linked-directory")).is_ok() {
        assert_eq!(error(&owner(&h, 51, "artifact.register", None,
            json!({"project_id":project_id,"relative_path":"linked-directory/private.txt","run_id":null}))), "unsupported_file");
    }
    let sentinel = outside.0.join("private.txt");
    let user = std::env::var("USERNAME").expect("Windows test identity");
    let denied = std::process::Command::new("icacls")
        .args([sentinel.to_str().unwrap(), "/deny", &format!("{user}:(R)")])
        .output().expect("deny synthetic outside sentinel");
    assert!(denied.status.success(), "synthetic ACL deny failed");
    let denied_read = fs::read(&sentinel).map_err(|error| error.kind());
    let escape = serde_json::to_vec(&json!({
        "schema_version":1,
        "instance_id":h.instance_id(),
        "operation_id":"60000001-0000-4000-8000-000000000867",
        "expected_topology_revision":null,
        "operation":"artifact.register",
        "params":{"project_id":project_id,"relative_path":"../private.txt","run_id":null},
    })).unwrap();
    let escape_rejected = parse_request(&escape).is_err();
    let restored = std::process::Command::new("icacls")
        .args([sentinel.to_str().unwrap(), "/remove:d", &user])
        .output().expect("restore synthetic outside sentinel ACL");
    assert!(restored.status.success(), "synthetic ACL restore failed");
    assert_eq!(denied_read, Err(std::io::ErrorKind::PermissionDenied));
    assert!(escape_rejected);
    assert_eq!(fs::read(outside.0.join("private.txt")).unwrap(), b"outside-sentinel");
}

#[test]
fn allocation_failure_before_registration_preserves_old_ref_and_retry() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("old.txt"), b"old").unwrap();
    fs::write(project.0.join("new.txt"), b"new").unwrap();
    let old = owner(&h, 60, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"old.txt","run_id":null}));
    let old_id = old["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let req = request(&h, 61, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"new.txt","run_id":null}));
    let before = h.allocations().snapshot();
    let failed = value(&h.owner_after(&req, |authority| winsmux_workspace::memory_testing::fail_after_allocations(authority, 0)));
    assert_eq!(error(&failed), "resource_exhausted");
    let after = h.allocations().snapshot();
    assert_eq!(after.retained, before.retained, "failed reserve retained capacity");
    assert_eq!(after.active_owner, before.active_owner, "failed reserve active capacity");
    let listed = owner(&h, 62, "artifact.list", None, json!({"project_id":project_id}));
    let refs = listed["result"]["data"]["registered"].as_array().unwrap();
    assert_eq!(refs.len(), 1);
    assert_eq!(refs[0]["artifact_id"], old_id);
    assert_eq!(owner(&h, 63, "artifact.read", None, json!({"artifact_id":old_id,"max_bytes":3}))["result"]["data"]["text"], "old");
    let retried = value(&h.owner(&req));
    assert_eq!(retried["accepted"], true, "{retried}");
}

#[test]
fn preview_allocation_failure_preserves_reference_and_active_balance() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let registered = owner(&h, 70, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}));
    let id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap().to_owned();
    let before = h.allocations().snapshot();
    let hold = ObserveHold::install(project.text());
    let worker_h = h.clone();
    let worker_id = id.clone();
    let worker = std::thread::spawn(move || owner(&worker_h, 71, "artifact.read", None,
        json!({"artifact_id":worker_id,"max_bytes":100})));
    hold.wait_entered();
    // The root final-path buffer is the first allocation after this hold;
    // fail the following charged preview buffer allocation.
    winsmux_workspace::memory_testing::fail_after_allocations(&h.allocations(), 1);
    hold.release_waiters();
    hold.clear();
    let failed = worker.join().unwrap();
    assert_eq!(error(&failed), "resource_exhausted", "{failed}");
    let after = h.allocations().snapshot();
    assert_eq!(after.retained, before.retained);
    assert_eq!(after.active_owner, before.active_owner);
    let retried = owner(&h, 72, "artifact.read", None, json!({"artifact_id":id,"max_bytes":100}));
    assert_eq!(retried["result"]["data"]["text"], "selected");
}

#[test]
fn run_association_is_explicit_and_same_project_only() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let created = owner(&h, 80, "pane.create", Some(1),
        json!({"project_id":project_id,"shell_profile_id":"pwsh"}));
    assert_eq!(created["accepted"], true, "{created}");
    let run_id = created["result"]["data"]["run_id"].as_str().unwrap();
    let associated = owner(&h, 81, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":run_id}));
    assert_eq!(associated["accepted"], true, "{associated}");
    assert_eq!(associated["result"]["data"]["artifact"]["association"], "caller_selected");
    assert_eq!(associated["result"]["data"]["artifact"]["run_id"], run_id);
    let other = TempDir::new();
    fs::write(other.0.join("selected.txt"), b"other").unwrap();
    let opened = owner(&h, 82, "project.open", Some(2), json!({"path":other.text()}));
    assert_eq!(opened["accepted"], true, "{opened}");
    let other_id = opened["result"]["data"]["project_id"].as_str().unwrap();
    let cross = owner(&h, 83, "artifact.register", None,
        json!({"project_id":other_id,"relative_path":"selected.txt","run_id":run_id}));
    assert_eq!(error(&cross), "target_not_found", "{cross}");
    assert_eq!(fs::read(other.0.join("selected.txt")).unwrap(), b"other");
}

#[test]
fn exclusive_share_conflict_rejects_without_losing_other_references() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let exclusive = fs::OpenOptions::new().read(true).share_mode(0)
        .open(project.0.join("selected.txt")).expect("exclusive test hold");
    let blocked = owner(&h, 90, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}));
    assert_eq!(error(&blocked), "runtime_failed", "{blocked}");
    drop(exclusive);
    let registered = owner(&h, 91, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}));
    assert_eq!(registered["accepted"], true, "{registered}");
    assert_eq!(fs::read(project.0.join("selected.txt")).unwrap(), b"selected");
}

#[test]
fn successful_restore_during_blocked_read_invalidates_old_id() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let registered = owner(&h, 100, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}));
    let id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap().to_owned();
    let saved = owner(&h, 101, "layout.save", None, json!({}));
    assert_eq!(saved["accepted"], true, "{saved}");
    let revision = saved["topology_revision"].as_u64().unwrap();
    let hold = ObserveHold::install(project.text());
    let worker_h = h.clone();
    let worker_id = id.clone();
    let worker = std::thread::spawn(move || owner(&worker_h, 102, "artifact.read", None,
        json!({"artifact_id":worker_id,"max_bytes":100})));
    hold.wait_entered();
    hold.clear(); // Restore may observe the same root, so only the pinned read waits.
    let restored = owner(&h, 103, "layout.restore", Some(revision), json!({}));
    assert_eq!(restored["accepted"], true, "{restored}");
    hold.release_waiters();
    let result = worker.join().unwrap();
    assert_eq!(error(&result), "target_not_found", "{result}");
    assert_eq!(error(&owner(&h, 104, "artifact.read", None,
        json!({"artifact_id":id,"max_bytes":100}))), "target_not_found");
    assert_eq!(fs::read(project.0.join("selected.txt")).unwrap(), b"selected");
}

#[test]
fn revoke_during_blocked_client_read_cannot_return_file_bytes() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("selected.txt"), b"selected").unwrap();
    let registered = owner(&h, 110, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}));
    let id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap().to_owned();
    let client = h.connect("preview-client.exe");
    let pending = value(&client.request(&request(&h, 111, "connection.request", None,
        json!({"project_ids":[project_id],"scopes":["read_output"]}))).unwrap());
    let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap().to_owned();
    let granted = owner(&h, 112, "connection.decide", None,
        json!({"connection_id":connection_id,"decision":"allow","project_ids":[project_id],"scopes":["read_output"]}));
    assert_eq!(granted["accepted"], true, "{granted}");
    let hold = ObserveHold::install(project.text());
    let worker_h = h.clone();
    let worker_id = id.clone();
    let worker = std::thread::spawn(move || client.request(&request(&worker_h, 113, "artifact.read", None,
        json!({"artifact_id":worker_id,"max_bytes":100}))).map(|response| value(&response)));
    hold.wait_entered();
    hold.clear();
    let revoked = owner(&h, 114, "connection.revoke", None, json!({"connection_id":connection_id}));
    assert_eq!(revoked["accepted"], true, "{revoked}");
    hold.release_waiters();
    let result = worker.join().unwrap();
    if let Some(response) = result {
        assert_eq!(response["accepted"], false, "{response}");
        assert_eq!(response["result"], Value::Null, "{response}");
    }
    assert_eq!(fs::read(project.0.join("selected.txt")).unwrap(), b"selected");
}

#[test]
fn response_write_fault_keeps_old_ref_and_seals_register_error() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("old.txt"), b"old").unwrap();
    fs::write(project.0.join("new.txt"), b"new").unwrap();
    let old = owner(&h, 120, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"old.txt","run_id":null}));
    let old_id = old["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap().to_owned();
    let new_request = request(&h, 121, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"new.txt","run_id":null}));
    h.fail_next_artifact_response_write();
    let failed = value(&h.owner(&new_request));
    assert_eq!(error(&failed), "resource_exhausted", "{failed}");
    assert_eq!(failed["result"], Value::Null);
    assert_eq!(value(&h.owner(&new_request)), failed, "retained terminal error replay");
    let listed = owner(&h, 122, "artifact.list", None, json!({"project_id":project_id}));
    let refs = listed["result"]["data"]["registered"].as_array().unwrap();
    assert_eq!(refs.len(), 1);
    assert_eq!(refs[0]["artifact_id"], old_id);
    let before = h.allocations().snapshot();
    h.fail_next_artifact_response_write();
    let read_failed = owner(&h, 123, "artifact.read", None,
        json!({"artifact_id":old_id,"max_bytes":100}));
    assert_eq!(error(&read_failed), "resource_exhausted", "{read_failed}");
    assert_eq!(h.allocations().snapshot().active_owner, before.active_owner);
    assert_eq!(h.allocations().snapshot().retained, before.retained);
    let old_read = owner(&h, 124, "artifact.read", None,
        json!({"artifact_id":old_id,"max_bytes":100}));
    assert_eq!(old_read["result"]["data"]["text"], "old");
    let new_ref = owner(&h, 125, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"new.txt","run_id":null}));
    assert_eq!(new_ref["accepted"], true, "{new_ref}");
    assert_eq!(fs::read(project.0.join("old.txt")).unwrap(), b"old");
    assert_eq!(fs::read(project.0.join("new.txt")).unwrap(), b"new");
}

fn git(dir: &std::path::Path, args: &[&str]) {
    let output = Command::new(r"C:\Program Files\Git\bin\git.exe")
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "NUL")
        .args(args)
        .output()
        .expect("git");
    assert!(output.status.success(), "git {args:?} status={} stderr={}", output.status, String::from_utf8_lossy(&output.stderr));
}

struct JunctionLink(std::path::PathBuf);

impl Drop for JunctionLink {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.0);
    }
}

fn mklink_junction(link: &std::path::Path, target: &std::path::Path) -> JunctionLink {
    let output = Command::new("cmd").args(["/C", "mklink", "/J"]).arg(link).arg(target).output().expect("mklink");
    assert!(output.status.success(), "mklink status={} stdout={} stderr={}", output.status, String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    JunctionLink(link.to_path_buf())
}

#[test]
fn list_keeps_registered_artifacts_when_the_git_tree_exceeds_one_mebibyte() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("note.txt"), b"note").unwrap();
    let registered = owner(&h, 200, "artifact.register", None, json!({"project_id":project_id,"relative_path":"note.txt","run_id":null}));
    assert_eq!(registered["accepted"], true, "{registered}");
    let reference = &registered["result"]["data"]["artifact"];
    git(&project.0, &["-c", "init.defaultBranch=master", "init", "-q"]);
    fs::write(project.0.join("big.bin"), vec![b'x'; 1_100_000]).unwrap();
    let listed = owner(&h, 201, "artifact.list", None, json!({"project_id":project_id}));
    assert_eq!(listed["accepted"], true, "{listed}");
    assert_eq!(listed["result"]["data"]["registered"], json!([reference]));
    assert_eq!(listed["result"]["data"]["git_candidates"], json!([]));
    assert_eq!(listed["result"]["data"]["git_candidates_error"], "resource_exhausted");
    let failed = owner(&h, 202, "artifact.diff", None, json!({"artifact_id":reference["artifact_id"],"max_bytes":100}));
    assert_eq!(failed["accepted"], false, "{failed}");
    assert_eq!(error(&failed), "resource_exhausted");
}

#[test]
fn list_keeps_registered_artifacts_when_the_git_tree_contains_a_junction() {
    let (h, project, _layout, project_id) = setup();
    fs::write(project.0.join("note.txt"), b"note").unwrap();
    let registered = owner(&h, 210, "artifact.register", None, json!({"project_id":project_id,"relative_path":"note.txt","run_id":null}));
    assert_eq!(registered["accepted"], true, "{registered}");
    let reference = &registered["result"]["data"]["artifact"];
    git(&project.0, &["-c", "init.defaultBranch=master", "init", "-q"]);
    let before = owner(&h, 211, "artifact.list", None, json!({"project_id":project_id}));
    assert_ne!(before["error"]["code"].as_str(), Some("unsupported_file"), "{before}");
    assert_ne!(before["result"]["data"]["git_candidates_error"].as_str(), Some("unsupported_file"), "{before}");
    fs::create_dir(project.0.join("real")).unwrap();
    let _junction = mklink_junction(&project.0.join("linked"), &project.0.join("real"));
    let listed = owner(&h, 212, "artifact.list", None, json!({"project_id":project_id}));
    assert_eq!(listed["accepted"], true, "{listed}");
    assert_eq!(listed["result"]["data"]["registered"], json!([reference]));
    assert_eq!(listed["result"]["data"]["git_candidates"], json!([]));
    assert_eq!(listed["result"]["data"]["git_candidates_error"], "unsupported_file");
}
