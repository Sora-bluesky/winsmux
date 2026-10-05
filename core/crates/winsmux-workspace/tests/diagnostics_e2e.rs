#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use winsmux_workspace::auth::testing::{Client, Harness};
use winsmux_workspace::contract::{parse_request, ErrorCode, ProjectId, Request, Response};
use winsmux_workspace::host::ProductHost;

const PROJECT: &str = "30000000-0000-4000-8000-000000000877";
const OPERATIONS: &[&str] = &[
    "artifact.choice.list",
    "artifact.choose",
    "artifact.diff",
    "artifact.list",
    "artifact.read",
    "artifact.register",
    "capabilities.get",
    "connection.decide",
    "connection.list",
    "connection.request",
    "connection.revoke",
    "diagnostics.get",
    "events.wait",
    "host.stop",
    "input.key",
    "input.write",
    "layout.restore",
    "layout.save",
    "operation.get",
    "output.read",
    "pane.close",
    "pane.create",
    "pane.list",
    "pane.resize",
    "pane.select",
    "pane.split",
    "project.forget",
    "project.list",
    "project.open",
    "project.select",
    "run.get",
    "run.interrupt",
    "shell.launch",
];

fn request(instance: Value, operation: &str, params: Value) -> Request {
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version":1, "instance_id":instance,
            "operation_id":uuid::Uuid::new_v4().to_string(),
            "expected_topology_revision":null, "operation":operation, "params":params,
        }))
        .unwrap(),
    )
    .unwrap()
}
fn value(response: &Response) -> Value {
    serde_json::to_value(response).unwrap()
}
fn success(response: &Response) -> Value {
    let v = value(response);
    assert_eq!(
        v["accepted"], true,
        "expected successful product response: {v}"
    );
    assert_eq!(v["error"], Value::Null);
    v
}
fn denied(response: &Response, code: &str) {
    let v = value(response);
    assert_eq!(v["accepted"], false, "{v}");
    assert_eq!(v["result"], Value::Null);
    assert_eq!(v["error"]["code"], code, "{v}");
}
fn diag(instance: Value) -> Request {
    request(instance, "diagnostics.get", json!({}))
}
fn harness() -> Harness {
    Harness::new(vec![ProjectId::new(PROJECT).unwrap()])
}
fn pending(h: &Harness, scopes: Value) -> Client {
    let c = h.connect("WMX_SYNTH_ARGV_private-observer");
    success(
        &c.request(&request(
            json!(h.instance_id()),
            "connection.request",
            json!({"project_ids":[PROJECT], "scopes":scopes}),
        ))
        .unwrap(),
    );
    c
}
fn allow(h: &Harness, c: &Client, scopes: Value) {
    success(&h.owner(&request(
        json!(h.instance_id()),
        "connection.decide",
        json!({"connection_id":c.connection_id(),"decision":"allow",
               "project_ids":[PROJECT],"scopes":scopes}),
    )));
}
fn expected_data() -> Value {
    let mut codes: Vec<Value> = ErrorCode::ALL.iter().map(|v| json!(v)).collect();
    codes.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
    json!({"product_version":"0.38.0","protocol_version":1,
           "capabilities":OPERATIONS,"connection_state":"granted","failure_codes":codes})
}

#[test]
fn owner_diagnostics_is_exact_public_projection() {
    let h = harness();
    let d = success(&h.owner(&diag(json!(h.instance_id()))));
    assert_eq!(d["result"]["operation"], "diagnostics.get");
    assert_eq!(d["result"]["data"], expected_data());
    let caps = success(&h.owner(&request(
        json!(h.instance_id()),
        "capabilities.get",
        json!({}),
    )));
    assert_eq!(
        caps["result"]["data"]["operations"],
        d["result"]["data"]["capabilities"]
    );
    assert_eq!(h.authorization().testing_spawn_counts(), (0, 0));
}

#[test]
fn metadata_diagnostics_preserves_all_permission_states() {
    let h = harness();
    let q = || diag(json!(h.instance_id()));
    let unpaired = h.connect("WMX_SYNTH_ENV_private-observer");
    denied(&unpaired.request(&q()).unwrap(), "permission_denied");
    for scopes in [
        json!(["control"]),
        json!(["read_output"]),
        json!(["metadata"]),
    ] {
        let c = pending(&h, scopes.clone());
        denied(&c.request(&q()).unwrap(), "permission_denied");
        allow(&h, &c, scopes.clone());
        if scopes == json!(["metadata"]) {
            let before = h.authorization().testing_spawn_counts();
            let d = success(&c.request(&q()).unwrap());
            assert_eq!(d["result"]["data"], expected_data());
            let caps = success(
                &c.request(&request(
                    json!(h.instance_id()),
                    "capabilities.get",
                    json!({}),
                ))
                .unwrap(),
            );
            assert_eq!(
                caps["result"]["data"]["operations"],
                d["result"]["data"]["capabilities"]
            );
            assert_eq!(h.authorization().testing_spawn_counts(), before);
            success(&h.owner(&request(
                json!(h.instance_id()),
                "connection.revoke",
                json!({"connection_id":c.connection_id()}),
            )));
            assert!(
                c.request(&q()).is_none(),
                "revoked observer must not receive a reply"
            );
        } else {
            denied(&c.request(&q()).unwrap(), "permission_denied");
        }
    }
    let c = pending(&h, json!(["metadata"]));
    success(&h.owner(&request(
        json!(h.instance_id()),
        "connection.decide",
        json!({"connection_id":c.connection_id(),"decision":"deny","project_ids":[],"scopes":[]}),
    )));
    assert!(c.request(&q()).is_none());
    unpaired.disconnect();
    assert!(unpaired.request(&q()).is_none());
}

#[test]
fn diagnostics_observations_reject_stale_instance_and_closed_generation() {
    let h = harness();
    let c = pending(&h, json!(["metadata"]));
    allow(&h, &c, json!(["metadata"]));
    let stale = diag(json!("10000000-0000-4000-8000-000000000877"));
    denied(&h.owner(&stale), "state_unknown");
    denied(&c.request(&stale).unwrap(), "state_unknown");
    let q = diag(json!(h.instance_id()));
    for _ in 0..64 {
        assert_eq!(success(&h.owner(&q))["result"]["data"], expected_data());
        assert_eq!(
            success(&c.request(&q).unwrap())["result"]["data"],
            expected_data()
        );
    }
    h.close_generation();
    assert!(h.try_owner(&q).is_none());
    assert!(c.request(&q).is_none());
}

#[test]
fn native_owner_and_public_pipe_diagnostics_use_real_dispatch() {
    let host = ProductHost::start(vec![ProjectId::new(PROJECT).unwrap()]).unwrap();
    let instance = json!(host.instance_id());
    let q = diag(instance.clone());
    let owner = success(&host.owner_request(&q).expect("native owner pipe"));
    assert_eq!(owner["result"]["operation"], "diagnostics.get");
    let c = host.connect_authenticated().unwrap();
    denied(&c.transact(&q).unwrap(), "permission_denied");
    let p = success(
        &c.transact(&request(
            instance.clone(),
            "connection.request",
            json!({"project_ids":[PROJECT],"scopes":["metadata"]}),
        ))
        .unwrap(),
    );
    success(
        &host
            .owner_request(&request(
                instance.clone(),
                "connection.decide",
                json!({"connection_id":p["result"]["data"]["connection_id"],"decision":"allow",
               "project_ids":[PROJECT],"scopes":["metadata"]}),
            ))
            .unwrap(),
    );
    let d = success(&c.transact(&diag(instance)).unwrap());
    assert_eq!(d["result"]["data"]["product_version"], "0.38.0");
    assert_eq!(d["result"]["data"]["protocol_version"], 1);
    assert_eq!(d["result"]["data"]["connection_state"], "granted");
    let raw = serde_json::to_string(&d).unwrap();
    assert!(!raw.contains("WMX_SYNTH_"));
    drop(c);
    host.shutdown()
        .expect("native owner and public workers joined");
}

#[test]
fn diagnostics_send_reservation_and_revocation_preserve_actor_and_generation() {
    use std::sync::mpsc;

    let h = harness();
    let c = pending(&h, json!(["metadata"]));
    allow(&h, &c, json!(["metadata"]));
    let q = diag(json!(h.instance_id()));
    let same_id = q.clone();
    let sending_client = c.clone();
    let (started_tx, started_rx) = mpsc::channel();
    let (cancelled_tx, cancelled_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let send = std::thread::spawn(move || {
        let observer = sending_client.clone();
        sending_client.request_with_send(&q, move |response| {
            assert_eq!(success(&response)["result"]["data"], expected_data());
            started_tx.send(()).unwrap();
            observer.wait_cancelled();
            cancelled_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            false
        })
    });
    started_rx.recv().unwrap();
    denied(&h.owner(&same_id), "permission_denied");
    assert_eq!(
        success(&h.owner(&diag(json!(h.instance_id()))))["result"]["data"],
        expected_data()
    );
    let revoking = h.clone();
    let connection_id = c.connection_id();
    let revoke = std::thread::spawn(move || {
        success(&revoking.owner(&request(
            json!(revoking.instance_id()),
            "connection.revoke",
            json!({"connection_id":connection_id}),
        )))
    });
    cancelled_rx.recv().unwrap();
    release_tx.send(()).unwrap();
    assert_eq!(send.join().unwrap(), Some(false));
    revoke.join().unwrap();
    assert!(c.request(&same_id).is_none());
    assert_eq!(c.cancellation_count(), 1);
    assert!(h
        .authorization()
        .testing_replay_phase(&same_id.operation_id)
        .is_none());
    assert_eq!(
        success(&h.owner(&same_id))["result"]["data"],
        expected_data()
    );
}

#[test]
fn repeated_diagnostics_release_charged_memory_without_retained_receipts() {
    let h = harness();
    let c = pending(&h, json!(["metadata"]));
    allow(&h, &c, json!(["metadata"]));
    let q = diag(json!(h.instance_id()));
    let before = h.allocations().snapshot();
    for _ in 0..64 {
        assert_eq!(success(&h.owner(&q))["result"]["data"], expected_data());
        assert_eq!(
            success(&c.request(&q).unwrap())["result"]["data"],
            expected_data()
        );
        assert_eq!(h.allocations().snapshot(), before);
        assert!(h
            .authorization()
            .testing_replay_phase(&q.operation_id)
            .is_none());
    }
}
