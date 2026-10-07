#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::time::Duration;
use winsmux_workspace::contract::{parse_request, ProjectId, Request, MAX_SAFE_INTEGER};
use winsmux_workspace::host::ProductHost;

const PROJECT_A: &str = "30000000-0000-4000-8000-000000000001";

fn project(id: &str) -> ProjectId {
    ProjectId::new(id).expect("project")
}

fn request(operation: &str, instance_id: Option<&str>, params: Value) -> Request {
    let value = json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": uuid::Uuid::new_v4().to_string(),
        "expected_topology_revision": null,
        "operation": operation,
        "params": params,
    });
    parse_request(&serde_json::to_vec(&value).expect("request JSON"))
        .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

fn as_json(response: &winsmux_workspace::Response) -> Value {
    serde_json::to_value(response).expect("response json")
}

fn assert_accepted(response: &winsmux_workspace::Response) {
    let value = as_json(response);
    assert_eq!(value["accepted"], json!(true), "{value}");
}

fn states(listed: &Value) -> Vec<String> {
    listed["result"]["data"]["connections"]
        .as_array()
        .expect("connections")
        .iter()
        .map(|row| row["state"].as_str().expect("state").to_owned())
        .collect()
}

#[test]
fn all_lifecycle_stages_recoverable() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let authenticating = host.connect_stalled().expect("authenticating accept");
    let listed = host.wait_connections(1, Duration::from_secs(2));
    assert!(states(&listed).contains(&"authenticating".to_owned()), "{listed}");
    assert_eq!(
        listed["result"]["data"]["connections"][0]["executable_name"],
        json!(null)
    );

    let unpaired = host.connect_authenticated().expect("unpaired");
    let granted = host.connect_authenticated().expect("to grant");
    granted
        .transact(&request(
            "connection.request",
            None,
            json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        ))
        .expect("granted request");
    let listed = serde_json::to_value(&host.owner_list()).expect("list");
    let granted_id = listed["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["state"] == json!("pending"))
        .and_then(|row| row["connection_id"].as_str())
        .expect("pending id")
        .to_owned();
    let decided = host.decide_allow(
        &granted_id,
        json!([PROJECT_A]),
        json!(["metadata"]),
    );
    assert_accepted(&decided);
    let pending = host.connect_authenticated().expect("pending");
    pending
        .transact(&request(
            "connection.request",
            None,
            json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        ))
        .expect("pending request");
    host.wait_connections(4, Duration::from_secs(2));

    let mut live = states(&serde_json::to_value(&host.owner_list()).expect("list"));
    live.sort();
    assert!(live.contains(&"authenticating".to_owned()), "{live:?}");
    assert!(live.contains(&"unpaired".to_owned()), "{live:?}");
    assert!(live.contains(&"pending".to_owned()), "{live:?}");
    assert!(live.contains(&"granted".to_owned()), "{live:?}");

    let listed = serde_json::to_value(&host.owner_list()).expect("list");
    for row in listed["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
    {
        let id = row["connection_id"].as_str().expect("id");
        let revoked = host.revoke(id);
        assert_accepted(&revoked);
    }
    drop(authenticating);
    drop(unpaired);
    drop(pending);
    drop(granted);
    host.wait_idle(Duration::from_secs(5));
    host.shutdown().expect("join");
}

#[test]
fn worker_churn_join_reclaims() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    for index in 0..1000 {
        let client = host
            .connect_stalled()
            .unwrap_or_else(|error| panic!("accept {index}: {error:?}"));
        host.wait_connections(1, Duration::from_secs(2));
        drop(client);
        host.wait_idle(Duration::from_secs(5));
        assert_eq!(host.record_count(), 0, "leftover JoinHandle after accept {index}");
    }
    host.shutdown().expect("join");
}

#[test]
fn generation_close_all_stages() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let _authenticating = host.connect_stalled().expect("authenticating");
    let unpaired = host.connect_authenticated().expect("unpaired");
    let pending = host.connect_authenticated().expect("pending");
    pending
        .transact(&request(
            "connection.request",
            None,
            json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        ))
        .expect("pending");
    host.wait_connections(3, Duration::from_secs(2));
    drop(unpaired);
    host.shutdown().expect("generation close joins product workers");
}

#[test]
fn counter_saturation_keeps_recovery() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let waiting = host.connect_stalled().expect("open worker");
    host.wait_connections(1, Duration::from_secs(2));
    host.set_event_seq_to_max();
    assert_eq!(host.event_seq(), MAX_SAFE_INTEGER);
    assert!(host.generation_is_open());
    drop(waiting);
    host.shutdown().expect("close at counter saturation");
}
