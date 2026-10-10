#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::fs;
use std::thread;
use std::time::{Duration, Instant};
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::parse_request;

fn owner(harness: &Harness, operation: &str, revision: Option<u64>, params: Value) -> Value {
    owner_id(
        harness,
        operation,
        &uuid::Uuid::new_v4().to_string(),
        revision,
        params,
    )
}

fn owner_id(
    harness: &Harness,
    operation: &str,
    operation_id: &str,
    revision: Option<u64>,
    params: Value,
) -> Value {
    let request = json!({
        "schema_version": 1,
        "instance_id": serde_json::to_value(harness.instance_id()).expect("instance"),
        "operation_id": operation_id,
        "expected_topology_revision": revision,
        "operation": operation,
        "params": params,
    });
    let bytes = serde_json::to_vec(&request).expect("request JSON");
    let parsed =
        parse_request(&bytes).unwrap_or_else(|error| panic!("{operation} schema: {error}"));
    serde_json::to_value(harness.owner(&parsed)).expect("response JSON")
}

#[test]
fn claude_not_ready_is_terminal_and_does_not_start_a_run() {
    let harness = Harness::new(Vec::new());
    let capabilities = owner(&harness, "capabilities.get", None, json!({}));
    assert_eq!(capabilities["result"]["data"]["providers"], json!([]));
    assert!(!capabilities["result"]["data"]["operations"]
        .as_array()
        .expect("operations")
        .contains(&json!("agent.launch")));
    let folder = std::env::temp_dir().join(format!("winsmux-claude-absent-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&folder).expect("isolated project");
    let opened = owner(&harness, "project.open", Some(0), json!({"path": folder.to_string_lossy()}));
    assert_eq!(opened["accepted"], json!(true), "{opened}");
    let created = owner(
        &harness,
        "pane.create",
        opened["topology_revision"].as_u64(),
        json!({"project_id": opened["result"]["data"]["project_id"], "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    let pane = created["result"]["data"]["pane_id"].clone();
    let shell_run = created["result"]["data"]["run_id"].clone();
    let interrupted = owner(&harness, "run.interrupt", None, json!({"run_id": shell_run}));
    assert_eq!(interrupted["accepted"], json!(true), "{interrupted}");
    let exit_deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = owner(&harness, "run.get", None, json!({"run_id": shell_run}));
        if status["result"]["data"]["run"]["process"] == json!("exited") {
            break;
        }
        assert!(Instant::now() < exit_deadline, "shell did not exit");
        thread::sleep(Duration::from_millis(50));
    }
    let params = json!({"pane_id": pane, "provider": "claude", "model": null, "effort": null});
    let launch_deadline = Instant::now() + Duration::from_secs(30);
    let (launch_id, denied) = loop {
        let id = uuid::Uuid::new_v4().to_string();
        let response = owner_id(&harness, "agent.launch", &id, None, params.clone());
        if response["error"]["code"] != json!("already_running") {
            break (id, response);
        }
        assert!(Instant::now() < launch_deadline, "shell cleanup did not finish");
        thread::sleep(Duration::from_secs(1));
    };
    assert_eq!(denied["error"]["code"], json!("unsupported_capability"), "{denied}");
    let replay = owner_id(&harness, "agent.launch", &launch_id, None, params);
    assert_eq!(replay, denied, "terminal rejection must be replayed");
    let unchanged = owner(&harness, "run.get", None, json!({"run_id": shell_run}));
    assert_eq!(unchanged["result"]["data"]["run"]["pane_id"], pane);
    let _ = fs::remove_dir_all(folder);
}

#[test]
#[ignore = "requires installed official Claude CLI and a real ConPTY"]
fn official_claude_is_advertised_and_launches_once_in_project() {
    let harness = Harness::new(Vec::new());
    let folder = std::env::temp_dir().join(format!("winsmux-869-project-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&folder).expect("isolated project");
    let before = owner(&harness, "capabilities.get", None, json!({}));
    assert_eq!(before["result"]["data"]["providers"], json!([]));
    harness.start_provider_probes();
    let deadline = Instant::now() + Duration::from_secs(60);
    let capabilities = loop {
        let response = owner(&harness, "capabilities.get", None, json!({}));
        let providers = response["result"]["data"]["providers"]
            .as_array()
            .expect("providers");
        if providers
            .iter()
            .any(|provider| provider["provider"] == json!("claude"))
        {
            break response;
        }
        assert!(
            Instant::now() < deadline,
            "Claude version probe did not become ready"
        );
        thread::sleep(Duration::from_millis(50));
    };
    assert!(capabilities["result"]["data"]["operations"]
        .as_array()
        .expect("operations")
        .contains(&json!("agent.launch")));
    let opened = owner(
        &harness,
        "project.open",
        Some(0),
        json!({"path": folder.to_string_lossy()}),
    );
    assert_eq!(opened["accepted"], json!(true), "{opened}");
    let project = opened["result"]["data"]["project_id"].clone();
    let created = owner(
        &harness,
        "pane.create",
        Some(opened["topology_revision"].as_u64().expect("revision")),
        json!({"project_id": project, "shell_profile_id": "pwsh"}),
    );
    assert_eq!(created["accepted"], json!(true), "{created}");
    let pane = created["result"]["data"]["pane_id"].clone();
    let shell_run = created["result"]["data"]["run_id"].clone();
    let interrupted = owner(
        &harness,
        "run.interrupt",
        None,
        json!({"run_id": shell_run}),
    );
    assert_eq!(interrupted["accepted"], json!(true), "{interrupted}");
    let shell_exit_deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = owner(&harness, "run.get", None, json!({"run_id": shell_run}));
        if status["result"]["data"]["run"]["process"] == json!("exited") {
            break;
        }
        assert!(
            Instant::now() < shell_exit_deadline,
            "shell did not exit: {status}"
        );
        thread::sleep(Duration::from_millis(50));
    }
    let launch_id = uuid::Uuid::new_v4().to_string();
    let launch_params =
        json!({"pane_id": pane, "provider": "claude", "model": null, "effort": null});
    let launch = owner_id(
        &harness,
        "agent.launch",
        &launch_id,
        None,
        launch_params.clone(),
    );
    assert_eq!(launch["accepted"], json!(true), "{launch}");
    assert_eq!(launch["result"]["data"]["phase"], json!("accepted"));
    let replay = owner_id(&harness, "agent.launch", &launch_id, None, launch_params);
    assert_eq!(replay["result"]["data"], launch["result"]["data"]);
    let run = launch["result"]["data"]["run_id"].clone();
    let got = owner(&harness, "run.get", None, json!({"run_id": run}));
    assert_eq!(got["accepted"], json!(true), "{got}");
    assert_eq!(got["result"]["data"]["run"]["pane_id"], pane);
    let stopped = owner(&harness, "run.interrupt", None, json!({"run_id": run}));
    assert!(
        stopped["accepted"] == json!(true) || stopped["error"]["code"] == json!("not_running"),
        "{stopped}"
    );
    let _ = fs::remove_dir_all(&folder);
}
