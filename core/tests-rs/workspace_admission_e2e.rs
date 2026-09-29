#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::time::Duration;
use winsmux_workspace::contract::{
    canonical_request, parse_request, parse_response, ProjectId, Request, MAX_MESSAGE_BYTES,
};
use winsmux_workspace::host::{ProductHost, SupervisedPreauth};
use winsmux_workspace::memory_testing::{AllocationPool, ACTIVE_OWNER_BYTES};

fn request(operation: &str, instance_id: Option<&str>, params: Value) -> Request {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let value = json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": format!("20000000-0000-4000-8000-{n:012x}"),
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

fn seeded_projects(count: u32) -> Vec<ProjectId> {
    (1..=count)
        .map(|index| {
            ProjectId::new(format!("30000000-0000-4000-8000-{index:012x}"))
                .expect("seed project")
        })
        .collect()
}

fn ids_json(projects: &[ProjectId]) -> Value {
    Value::Array(projects.iter().map(|project| json!(project.as_str())).collect())
}

fn assert_same_bytes(left: &[u8], right: &[u8], what: &str) {
    if left == right {
        return;
    }
    let first = left
        .iter()
        .zip(right.iter())
        .position(|(a, b)| a != b)
        .unwrap_or(left.len().min(right.len()));
    let window = |buf: &[u8]| {
        let start = first.saturating_sub(24);
        let end = (first + 24).min(buf.len());
        buf[start..end].to_vec()
    };
    panic!(
        "{what}: len {} vs {}, first_diff {}, left_around {:?}, right_around {:?}",
        left.len(),
        right.len(),
        first,
        window(left),
        window(right)
    );
}

fn connection_states(listed: &Value) -> Vec<String> {
    listed["result"]["data"]["connections"]
        .as_array()
        .expect("connections")
        .iter()
        .map(|row| {
            row["state"]
                .as_str()
                .expect("state")
                .to_owned()
        })
        .collect()
}

#[test]
fn real_preauth_stall_and_owner_revoke() {
    let host = SupervisedPreauth::start().expect("supervised public accept");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let listed = loop {
        let listed = serde_json::to_value(&host.owner_list()).expect("list json");
        let connections = listed["result"]["data"]["connections"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        if !connections.is_empty() {
            break listed;
        }
        if std::time::Instant::now() >= deadline {
            panic!("product accept never published an authenticating row");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(listed["accepted"], json!(true));
    assert_eq!(
        listed["result"]["data"]["connections"][0]["state"],
        json!("authenticating")
    );
    assert_eq!(
        listed["result"]["data"]["connections"][0]["executable_name"],
        json!(null)
    );
    let connection_id = listed["result"]["data"]["connections"][0]["connection_id"]
        .as_str()
        .expect("connection id")
        .to_owned();
    let revoked = serde_json::to_value(&host.revoke(&connection_id)).expect("revoke json");
    assert_eq!(revoked["accepted"], json!(true));
    host.shutdown().expect("supervisor join");
}

#[test]
fn maximum_wire_management_list() {
    let projects = seeded_projects(800);
    let host = ProductHost::start(projects.clone()).expect("product host");
    let mut clients = Vec::new();
    let grant = json!({"project_ids": ids_json(&projects), "scopes": ["metadata"]});
    let overflow = loop {
        let client = host
            .connect_authenticated()
            .expect("product admit/name growth");
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while host.record_count() < clients.len() + 1 {
            if std::time::Instant::now() >= deadline {
                panic!("admit did not publish row {}", clients.len() + 1);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let req = request("connection.request", None, grant.clone());
        let req_bytes = canonical_request(&req).expect("canonical grant growth");
        client
            .send_bytes(&req_bytes)
            .expect("grant growth write");
        let first_raw = client.read_bytes().expect("grant growth read");
        let response = parse_response(&req, &first_raw).expect("grant growth parse");
        let value = as_json(&response);
        if value["accepted"] == json!(true) {
            clients.push(client);
            if clients.len() > 80 {
                panic!("product grant/admit growth never hit the 1MiB owner-list bound");
            }
            continue;
        }
        assert_eq!(value["error"]["code"], json!("resource_exhausted"));
        client
            .send_bytes(&req_bytes)
            .expect("post-Preparing grant-overflow replay write");
        let retried_raw = client
            .read_bytes()
            .expect("post-Preparing grant-overflow stored error replay");
        assert_same_bytes(
            &retried_raw,
            &first_raw,
            "exact recorded resource_exhausted bytes must replay on the live socket",
        );
        break client;
    };
    assert!(
        !clients.is_empty(),
        "1MiB-1 grant/admit growth must succeed at least once"
    );

    let instance = serde_json::to_value(host.instance_id())
        .expect("instance")
        .as_str()
        .expect("instance str")
        .to_owned();
    let list_req = request("connection.list", Some(&instance), json!({}));
    host.set_event_seq_to_max();
    let bytes = host.owner_frame(&list_req).expect("official owner_loop list");
    assert!(
        bytes.len() <= MAX_MESSAGE_BYTES,
        "official max-counter list exceeded 1MiB: {}",
        bytes.len()
    );
    assert!(
        bytes.len() > MAX_MESSAGE_BYTES / 2,
        "accepted grant/admit growth should sit on the 1MiB-1 side, got {}",
        bytes.len()
    );
    let listed = as_json(&parse_response(&list_req, &bytes).expect("stable list parse"));
    let rows = listed["result"]["data"]["connections"]
        .as_array()
        .expect("stable connections");
    assert_eq!(rows.len(), clients.len() + 1);
    let pending = rows
        .iter()
        .filter(|row| row["state"] == json!("pending"))
        .count();
    let unpaired = rows
        .iter()
        .filter(|row| row["state"] == json!("unpaired"))
        .count();
    assert_eq!(pending, clients.len());
    assert_eq!(unpaired, 1);
    let preserved = bytes.clone();
    assert_same_bytes(
        &host.owner_frame(&list_req).expect("preserved list"),
        &preserved,
        "stable live set must project the same current owner list",
    );

    drop(overflow);
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while host.record_count() != clients.len() {
        if std::time::Instant::now() >= deadline {
            panic!(
                "overflow worker did not join; leftover {}",
                host.record_count()
            );
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let after_join = host
        .owner_frame(&list_req)
        .expect("current list after overflow join");
    assert!(
        after_join.len() <= MAX_MESSAGE_BYTES,
        "list after join exceeded 1MiB: {}",
        after_join.len()
    );
    if after_join == preserved {
        panic!(
            "completed Q connection.list reused prior observation bytes ({} bytes)",
            after_join.len()
        );
    }
    let after = as_json(&parse_response(&list_req, &after_join).expect("after-join parse"));
    assert_eq!(after["accepted"], json!(true));
    let after_states = connection_states(&after);
    assert_eq!(after_states.len(), clients.len());
    assert!(
        after_states.iter().all(|state| state == "pending"),
        "joined overflow must not remain in the current list: {after_states:?}"
    );

    host.allocations()
        .claim(AllocationPool::ActiveOwner, 1)
        .expect("owner 128MiB remains after public admit/name/grant growth");
    let owner_used = host.allocations().snapshot().active_owner;
    host.allocations()
        .claim(AllocationPool::ActiveOwner, ACTIVE_OWNER_BYTES - owner_used)
        .expect("remaining owner bytes are independent of public list growth");

    drop(clients);
    host.shutdown().expect("join");
}
