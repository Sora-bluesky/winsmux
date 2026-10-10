#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::{canonical_request, parse_request, Request};
use winsmux_workspace::memory_testing::ObserveHold;

struct TempDir(PathBuf);
impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "winsmux-choice-{}-{}", std::process::id(), uuid::Uuid::new_v4()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn text(&self) -> String { self.0.to_string_lossy().into_owned() }
}
impl Drop for TempDir {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}
fn request(h: &Harness, id: u32, operation: &str, revision: Option<u64>, params: Value) -> Request {
    parse_request(&serde_json::to_vec(&json!({
        "schema_version":1,
        "instance_id":h.instance_id(),
        "operation_id":format!("{id:08x}-0000-4000-8000-000000000867"),
        "expected_topology_revision":revision,
        "operation":operation,
        "params":params,
    })).unwrap()).unwrap()
}
fn value(response: &winsmux_workspace::Response) -> Value {
    serde_json::to_value(response).unwrap()
}
fn owner(h: &Harness, id: u32, op: &str, rev: Option<u64>, params: Value) -> Value {
    value(&h.owner(&request(h, id, op, rev, params)))
}
fn error(response: &Value) -> &str {
    response["error"]["code"].as_str().expect("error code")
}
fn setup() -> (Harness, TempDir, TempDir, String, String, String) {
    let project = TempDir::new();
    let layout = TempDir::new();
    let h = Harness::new(Vec::new());
    assert!(h.authorization().testing_install_isolated_layout(&layout.0.join("v1")));
    fs::write(project.0.join("left.txt"), b"left").unwrap();
    fs::write(project.0.join("right.bin"), [0u8, 255]).unwrap();
    let opened = owner(&h, 1, "project.open", Some(0), json!({"path":project.text()}));
    assert_eq!(opened["accepted"], true, "{opened}");
    let project_id = opened["result"]["data"]["project_id"].as_str().unwrap().to_owned();
    let left = owner(&h, 2, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"left.txt","run_id":null}));
    let right = owner(&h, 3, "artifact.register", None,
        json!({"project_id":project_id,"relative_path":"right.bin","run_id":null}));
    assert_eq!(left["accepted"], true, "{left}");
    assert_eq!(right["accepted"], true, "{right}");
    let left_id = left["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap().to_owned();
    let right_id = right["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap().to_owned();
    (h, project, layout, project_id, left_id, right_id)
}
fn choose_params(project: &str, left: &str, right: &str, kept: &str) -> Value {
    json!({"project_id":project,"left_artifact_id":left,"right_artifact_id":right,"kept_artifact_id":kept})
}

#[test]
fn normalized_choice_replay_rechoice_and_independent_client_list() {
    let (h, project, _layout, project_id, left, right) = setup();
    let first_request = request(&h, 10, "artifact.choose", None,
        choose_params(&project_id, &right, &left, &left));
    let reversed = request(&h, 10, "artifact.choose", None,
        choose_params(&project_id, &left, &right, &left));
    assert_eq!(canonical_request(&first_request).unwrap(), canonical_request(&reversed).unwrap());
    let first = value(&h.owner(&first_request));
    assert_eq!(first["accepted"], true, "{first}");
    let expected_left = std::cmp::min(left.as_str(), right.as_str());
    let expected_right = std::cmp::max(left.as_str(), right.as_str());
    assert_eq!(first["result"]["data"], json!({
        "left_artifact_id":expected_left,
        "right_artifact_id":expected_right,
        "kept_artifact_id":left,
    }));
    assert_eq!(first, value(&h.owner(&reversed)));
    let conflict = owner(&h, 10, "artifact.choose", None,
        choose_params(&project_id, &left, &right, &right));
    assert_eq!(error(&conflict), "operation_conflict");

    // Git metadata cannot block the independent review choice observation.
    let info = project.0.join(".git").join("objects").join("info");
    fs::create_dir_all(&info).unwrap();
    fs::write(info.join("alternates"), b"C:/outside").unwrap();
    let rechoice = owner(&h, 11, "artifact.choose", None,
        choose_params(&project_id, &left, &right, &right));
    assert_eq!(rechoice["accepted"], true, "{rechoice}");
    let listed = owner(&h, 12, "artifact.choice.list", None, json!({"project_id":project_id}));
    assert_eq!(listed["result"]["data"]["choices"], json!([{
        "left_artifact_id":expected_left,
        "right_artifact_id":expected_right,
        "kept_artifact_id":right,
    }]));
    let client = h.connect("review-client.exe");
    let pending = value(&client.request(&request(&h, 13, "connection.request", None,
        json!({"project_ids":[project_id],"scopes":["read_output"]}))).unwrap());
    let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
    let grant = owner(&h, 14, "connection.decide", None,
        json!({"connection_id":connection_id,"decision":"allow","project_ids":[project_id],"scopes":["read_output"]}));
    assert_eq!(grant["accepted"], true, "{grant}");
    let client_list = value(&client.request(&request(&h, 15, "artifact.choice.list", None,
        json!({"project_id":project_id}))).unwrap());
    assert_eq!(client_list["result"]["data"]["choices"], listed["result"]["data"]["choices"]);
    let denied = value(&client.request(&request(&h, 16, "artifact.choose", None,
        choose_params(&project_id, &left, &right, &left))).unwrap());
    assert_eq!(error(&denied), "permission_denied");
    let revoked = owner(&h, 22, "connection.revoke", None,
        json!({"connection_id":connection_id}));
    assert_eq!(revoked["accepted"], true, "{revoked}");
    assert!(client.cancelled());
    assert!(client.request(&request(&h, 23, "artifact.choice.list", None,
        json!({"project_id":project_id}))).is_none());
    assert_eq!(owner(&h, 24, "artifact.choice.list", None,
        json!({"project_id":project_id}))["result"]["data"]["choices"],
        listed["result"]["data"]["choices"]);
    client.disconnect();

    let saved = owner(&h, 17, "layout.save", None, json!({}));
    assert_eq!(saved["accepted"], true, "{saved}");
    let stale = owner(&h, 18, "layout.restore", Some(0), json!({}));
    assert_eq!(error(&stale), "stale_topology");
    assert_eq!(owner(&h, 19, "artifact.choice.list", None,
        json!({"project_id":project_id}))["result"]["data"]["choices"], listed["result"]["data"]["choices"]);
    let restored = owner(&h, 20, "layout.restore", saved["topology_revision"].as_u64(), json!({}));
    assert_eq!(restored["accepted"], true, "{restored}");
    assert_eq!(owner(&h, 21, "artifact.choice.list", None,
        json!({"project_id":project_id}))["result"]["data"]["choices"], json!([]));
    assert_eq!(fs::read(project.0.join("left.txt")).unwrap(), b"left");
    assert_eq!(fs::read(project.0.join("right.bin")).unwrap(), [0u8, 255]);
}

#[test]
fn choice_validates_project_and_identity_and_survives_failed_publish() {
    let (h, project, _layout, project_id, left, right) = setup();
    let other = TempDir::new();
    fs::write(other.0.join("other.txt"), b"other").unwrap();
    let opened = owner(&h, 30, "project.open", Some(1), json!({"path":other.text()}));
    let other_id = opened["result"]["data"]["project_id"].as_str().unwrap();
    assert_eq!(error(&owner(&h, 31, "artifact.choose", None,
        choose_params(other_id, &left, &right, &left))), "target_not_found");
    let first = owner(&h, 32, "artifact.choose", None,
        choose_params(&project_id, &left, &right, &left));
    assert_eq!(first["accepted"], true, "{first}");
    h.fail_next_artifact_response_write();
    let failed = owner(&h, 33, "artifact.choose", None,
        choose_params(&project_id, &left, &right, &right));
    assert_eq!(error(&failed), "resource_exhausted");
    let listed = owner(&h, 34, "artifact.choice.list", None, json!({"project_id":project_id}));
    assert_eq!(listed["result"]["data"]["choices"][0]["kept_artifact_id"], left);
    fs::rename(project.0.join("right.bin"), project.0.join("moved.bin")).unwrap();
    assert_eq!(error(&owner(&h, 35, "artifact.choice.list", None,
        json!({"project_id":project_id}))), "target_not_found");
    assert_eq!(fs::read(project.0.join("left.txt")).unwrap(), b"left");
}

#[test]
fn forget_during_blocked_choose_never_publishes_choice() {
    let (h, project, _layout, project_id, left, right) = setup();
    let hold = ObserveHold::install(project.text());
    let worker_h = h.clone();
    let worker_project = project_id.clone();
    let worker = std::thread::spawn(move || owner(&worker_h, 40, "artifact.choose", None,
        choose_params(&worker_project, &left, &right, &left)));
    hold.wait_entered();
    hold.clear();
    let forgotten = owner(&h, 41, "project.forget", Some(1), json!({"project_id":project_id}));
    assert_eq!(forgotten["accepted"], true, "{forgotten}");
    hold.release_waiters();
    let result = worker.join().unwrap();
    assert_eq!(error(&result), "root_changed");
    assert_eq!(fs::read(project.0.join("left.txt")).unwrap(), b"left");
}
