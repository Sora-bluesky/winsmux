#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::time::Duration;
use winsmux_workspace::contract::{parse_request, ProjectId, Request};
use winsmux_workspace::host::ProductHost;
use winsmux_workspace::memory_testing::{
    fail_after_allocations, AllocationPool, ACTIVE_OWNER_BYTES, ACTIVE_PUBLIC_BYTES, RETAINED_BYTES,
};

const PROJECT_A: &str = "30000000-0000-4000-8000-000000000001";
const OP_A: &str = "20000000-0000-4000-8000-00000000000a";
const OP_B: &str = "20000000-0000-4000-8000-00000000000b";
const OP_C: &str = "20000000-0000-4000-8000-00000000000c";

fn project(id: &str) -> ProjectId {
    ProjectId::new(id).expect("project")
}

fn request_with_id(
    operation: &str,
    instance_id: Option<&str>,
    operation_id: &str,
    params: Value,
) -> Request {
    let value = json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": operation_id,
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

fn assert_error(response: &winsmux_workspace::Response, code: &str) {
    let value = as_json(response);
    assert_eq!(value["accepted"], json!(false), "{value}");
    assert_eq!(value["error"]["code"], json!(code), "{value}");
}

fn assert_accepted(response: &winsmux_workspace::Response) {
    let value = as_json(response);
    assert_eq!(value["accepted"], json!(true), "{value}");
}

#[test]
fn frame_shape_and_allocation_bound() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let client = host.connect_authenticated().expect("authenticated public");
    host.wait_connections(1, Duration::from_secs(2));

    fail_after_allocations(host.allocations(), 0);
    let uncorrelated = request_with_id("capabilities.get", None, OP_A, json!({}));
    let closed = client.transact(&uncorrelated);
    assert!(
        closed.is_err(),
        "uncorrelated host exhaustion must close rather than reply: {closed:?}"
    );
    drop(client);
    host.wait_idle(Duration::from_secs(2));

    let mut correlated = false;
    for successful_allocations in 1..16 {
        let client = host.connect_authenticated().expect("retry public");
        host.wait_connections(1, Duration::from_secs(2));
        fail_after_allocations(host.allocations(), successful_allocations);
        let request = request_with_id("capabilities.get", None, OP_B, json!({}));
        match client.transact(&request) {
            Ok(response) => {
                let value = as_json(&response);
                if value["error"]["code"] == json!("resource_exhausted") {
                    correlated = true;
                    let retry = client
                        .transact(&request_with_id(
                            "capabilities.get",
                            None,
                            "20000000-0000-4000-8000-00000000000c",
                            json!({}),
                        ))
                        .expect("connection remains after correlated exhaustion");
                    assert_accepted(&retry);
                    break;
                }
            }
            Err(_) => {
                drop(client);
                host.wait_idle(Duration::from_secs(2));
            }
        }
    }
    assert!(
        correlated,
        "product public loop must reply resource_exhausted after correlation and keep the connection"
    );
    host.shutdown().expect("join");
}

#[test]
fn retained_saturation_recovery() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let client = host.connect_authenticated().expect("authenticated");
    host.wait_connections(1, Duration::from_secs(2));
    let listed = host.owner_list();
    assert_accepted(&listed);
    let used = host.allocations().snapshot().retained;
    let fill = host
        .allocations()
        .claim(AllocationPool::Retained, RETAINED_BYTES - used)
        .expect("fill remaining retained");
    let first = request_with_id(
        "connection.request",
        None,
        OP_A,
        json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
    );
    let exhausted = client
        .transact(&first)
        .expect("pre-Preparing exhaustion is unstored");
    assert_error(&exhausted, "resource_exhausted");
    drop(fill);
    let retry = client
        .transact(&first)
        .expect("same ID admits after retained release");
    assert_accepted(&retry);
    host.shutdown().expect("join");
}

#[test]
fn active_public_owner_isolation() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let public = host
        .allocations()
        .claim(AllocationPool::ActivePublic, ACTIVE_PUBLIC_BYTES)
        .expect("fill public");
    let listed = host.owner_list();
    assert_accepted(&listed);
    let owner_probe = host
        .allocations()
        .claim(AllocationPool::ActiveOwner, 1)
        .expect("owner remains while public is full");
    drop(public);
    let used_owner = host.allocations().snapshot().active_owner;
    let remaining = host
        .allocations()
        .claim(AllocationPool::ActiveOwner, ACTIVE_OWNER_BYTES - used_owner)
        .expect("fill remaining owner");
    drop(remaining);
    drop(owner_probe);
    let revoked_ok = host.owner_list();
    assert_accepted(&revoked_ok);
    host.shutdown().expect("generation close while isolated");
}

#[test]
fn identity_replay_conflict_actor_and_ack_loss() {
    let host = ProductHost::start(vec![project(PROJECT_A)]).expect("product host");
    let client = host.connect_authenticated().expect("public");
    let listed = host.wait_connections(1, Duration::from_secs(2));
    let connection_id = listed["result"]["data"]["connections"][0]["connection_id"]
        .as_str()
        .expect("id")
        .to_owned();

    let first = request_with_id(
        "connection.request",
        None,
        OP_A,
        json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
    );
    let pending = client.transact(&first).expect("first request");
    assert_accepted(&pending);

    let replay = client.transact(&first).expect("same actor same bytes");
    assert_eq!(as_json(&replay), as_json(&pending));

    let different = request_with_id(
        "capabilities.get",
        None,
        OP_A,
        json!({}),
    );
    let conflict = client.transact(&different).expect("same ID different bytes");
    assert_error(&conflict, "operation_conflict");
    assert_eq!(as_json(&client.transact(&first).expect("stored terminal unchanged")), as_json(&pending));

    let other = host.connect_authenticated().expect("other actor");
    host.wait_connections(2, Duration::from_secs(2));
    let denied = other.transact(&first).expect("other actor");
    assert_error(&denied, "permission_denied");

    let revoked = host.revoke(&connection_id);
    assert_accepted(&revoked);
    assert!(
        client.transact(&first).is_err(),
        "ticket revocation must refuse Done send without mutating the stored terminal"
    );

    let observation = request_with_id("capabilities.get", None, OP_B, json!({}));
    let first_q = other.transact(&observation).expect("Q");
    assert_accepted(&first_q);
    let second_q = other.transact(&observation).expect("observation reclaim");
    assert_accepted(&second_q);

    host.set_event_seq_to_max();
    let post = request_with_id(
        "connection.request",
        None,
        OP_C,
        json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
    );
    let post_bytes = winsmux_workspace::canonical_request(&post).expect("canonical");
    other
        .send_bytes(&post_bytes)
        .expect("post-Preparing write");
    let first_raw = other
        .read_bytes()
        .expect("post-Preparing resource_exhausted");
    let exhausted = winsmux_workspace::parse_response(&post, &first_raw)
        .expect("post-Preparing parse");
    assert_error(&exhausted, "resource_exhausted");
    other
        .send_bytes(&post_bytes)
        .expect("post-Preparing replay write");
    let retried_raw = other
        .read_bytes()
        .expect("post-Preparing stored error replay");
    assert_eq!(
        retried_raw, first_raw,
        "post-Preparing resource_exhausted must be stored"
    );

    let listed = serde_json::to_value(&host.owner_list()).expect("list after error terminal");
    let other_id = listed["result"]["data"]["connections"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["state"] == json!("unpaired"))
        .and_then(|row| row["connection_id"].as_str())
        .expect("unpaired other")
        .to_owned();
    assert_accepted(&host.revoke(&other_id));
    assert!(
        other.transact(&post).is_err(),
        "stored error ticket must refuse send after revoke without mutating the terminal"
    );

    host.shutdown().expect("join");
}
