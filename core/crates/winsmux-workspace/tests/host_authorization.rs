#![cfg(windows)]

#[path = "support/run_completion.rs"]
mod run_completion;

use serde::Serialize;
use serde_json::{json, Value};
use std::sync::mpsc;
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::{parse_request, parse_snapshot, ProjectId, Request, Response};
use winsmux_workspace::host::testing::{
    run_framing_probes, run_generation_closure_probes, run_generation_io_probes,
    run_host_epilogue_probes, run_os_authentication_probes, run_server_capability_probes,
};

fn guard_request(instance: &str, operation: &str, revision: Option<u64>, params: Value) -> Request {
    parse_request(&serde_json::to_vec(&json!({"schema_version":1,"instance_id":instance,"operation_id":uuid::Uuid::new_v4().to_string(),"expected_topology_revision":revision,"operation":operation,"params":params})).unwrap()).unwrap()
}

/// Actual owner/public pipes and native runs; only this fixture's isolated store.
fn close_guard_pipe_race(public_close: bool, expected_null: bool) {
    use std::time::{Duration, Instant};
    use winsmux_workspace::contract::RunId;
    use winsmux_workspace::host::ProductHost;
    let root = std::env::temp_dir().join(format!("task871-guard-{}", uuid::Uuid::new_v4()));
    let project_path = root.join("project");
    let store = root.join("store");
    std::fs::create_dir_all(&project_path).unwrap();
    let host = ProductHost::start(Vec::new()).expect("dedicated pipe host");
    assert!(host.authorization().testing_install_isolated_layout(&store));
    let instance = scalar(host.instance_id());
    let owner = |operation: &str, revision, params| host.owner_request(&guard_request(&instance, operation, revision, params)).expect("owner pipe response");
    let opened = assert_success(&owner("project.open", Some(0), json!({"path":project_path.to_string_lossy()})), "project.open");
    let project = opened["result"]["data"]["project_id"].as_str().unwrap().to_owned();
    let created = assert_success(&owner("pane.create", Some(1), json!({"project_id":project,"shell_profile_id":"pwsh"})), "pane.create");
    let pane = created["result"]["data"]["pane_id"].as_str().unwrap().to_owned();
    let first = created["result"]["data"]["run_id"].as_str().unwrap().to_owned();
    let clean = |run: &str| {
        let typed = RunId::new(run).unwrap();
        let identity = host.authorization().testing_owned_process_identity(&typed).expect("owned native identity");
        let interrupted = assert_success(&owner("run.interrupt", None, json!({"run_id":run})), "run.interrupt");
        assert_eq!(interrupted["result"]["data"]["phase"], "accepted");
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let got = assert_success(&owner("run.get", None, json!({"run_id":run})), "run.get");
            if run_completion::projected_cleanup_matches(&got, host.authorization().testing_session_clean_bits(&typed).is_some_and(|bits| bits.0)) {
                assert_eq!(got["result"]["data"]["run"]["process"], "exited");
                assert_eq!(got["result"]["data"]["run"]["evidence"], "process_exit");
                let job = host.authorization().testing_job_stop_stats(&typed).unwrap();
                assert_eq!(job.5, Some(0));
                eprintln!("TASK871_NATIVE_RUN {}", json!({"instance":instance,"run":run,"pid":identity.0,"creation_filetime":identity.1,"exited":true,"clean":true,"job_empty":true}));
                break;
            }
            assert!(Instant::now() < deadline, "owned run did not become clean");
            std::thread::sleep(Duration::from_millis(25));
        }
    };
    clean(&first);
    let mut revision = created["topology_revision"].as_u64().unwrap();
    if expected_null {
        assert_success(&owner("layout.save", None, json!({})), "layout.save");
        let restored = assert_success(&owner("layout.restore", Some(revision), json!({})), "layout.restore");
        revision = restored["topology_revision"].as_u64().unwrap();
        let listed = assert_success(&owner("pane.list", None, json!({"project_id":project})), "pane.list");
        assert_eq!(listed["result"]["data"]["panes"][0]["current_run_id"], Value::Null);
        // Matching null really closes only the unstarted restored pane.
        let matched = assert_success(&owner("pane.close", Some(revision), json!({"pane_id":pane,"expected_current_run_id":null})), "pane.close");
        revision = matched["topology_revision"].as_u64().unwrap();
        let restored = assert_success(&owner("layout.restore", Some(revision), json!({})), "layout.restore");
        revision = restored["topology_revision"].as_u64().unwrap();
    }
    assert_success(&owner("layout.save", None, json!({})), "layout.save");
    assert_success(&owner("layout.save", None, json!({})), "layout.save");
    let stored = ["confirmed.json", "backup.json"].map(|name| std::fs::read(store.join(name)).unwrap());
    let client = host.connect_authenticated().expect("separate authenticated public pipe");
    let pending = assert_success(&client.transact(&guard_request(&instance, "connection.request", None, json!({"project_ids":[project],"scopes":["metadata","control"]}))).unwrap(), "connection.request");
    let connection = pending["result"]["data"]["connection_id"].as_str().unwrap();
    assert_success(&owner("connection.decide", None, json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["metadata","control"]})), "connection.decide");
    let launch = guard_request(&instance, "shell.launch", None, json!({"pane_id":pane,"shell_profile_id":"pwsh"}));
    let second = assert_success(&client.transact(&launch).unwrap(), "shell.launch");
    let run2 = second["result"]["data"]["run_id"].as_str().unwrap().to_owned();
    assert_ne!(run2, first);
    assert_eq!(second["topology_revision"], revision, "R launch must not bump T revision");
    let expected = if expected_null { Value::Null } else { json!(first) };
    let send_close = |expected: Value| {
        let req = guard_request(&instance, "pane.close", Some(revision), json!({"pane_id":pane,"expected_current_run_id":expected}));
        if public_close { client.transact(&req).unwrap() } else { host.owner_request(&req).unwrap() }
    };
    // The expected identity guard wins before occupancy, in running and clean states.
    assert_error(&send_close(expected.clone()), "target_not_found");
    clean(&run2);
    let before = assert_success(&owner("pane.list", None, json!({"project_id":project})), "pane.list");
    let denied = send_close(expected);
    assert_error(&denied, "target_not_found");
    let after = assert_success(&owner("pane.list", None, json!({"project_id":project})), "pane.list");
    assert_eq!(before["topology_revision"], after["topology_revision"]);
    for key in ["root", "selected_pane_id", "project_id"] { assert_eq!(before["result"]["data"][key], after["result"]["data"][key]); }
    assert_eq!(after["result"]["data"]["panes"][0]["current_run_id"], run2);
    for (index, name) in ["confirmed.json", "backup.json"].iter().enumerate() { assert_eq!(stored[index], std::fs::read(store.join(name)).unwrap()); }
    let final_request = guard_request(&instance, "pane.close", Some(revision), json!({"pane_id":pane,"expected_current_run_id":run2}));
    let final_send = |request: &Request| if public_close { client.transact(request).unwrap() } else { host.owner_request(request).unwrap() };
    let matched = final_send(&final_request);
    assert_success(&matched, "pane.close");
    assert_eq!(value(&matched), value(&final_send(&final_request)), "same canonical guarded close replays without another effect");
    for params in [json!({"pane_id":pane}), json!({"pane_id":pane,"expected_current_run_id":null}), json!({"pane_id":pane,"expected_current_run_id":first})] {
        let mut changed = value(&final_request);
        changed["params"] = params;
        let changed = parse_request(&serde_json::to_vec(&changed).unwrap()).unwrap();
        assert_error(&final_send(&changed), "operation_conflict");
    }
    drop(client);
    host.shutdown().expect("owned empty host joined");
}

#[test]
fn task871_guard_owner_preserves_replaced_clean_run() { close_guard_pipe_race(false, false); }
#[test]
fn task871_guard_public_preserves_replaced_clean_run() { close_guard_pipe_race(true, false); }
#[test]
fn task871_guard_owner_preserves_null_replacement() { close_guard_pipe_race(false, true); }
#[test]
fn task871_guard_public_preserves_null_replacement() { close_guard_pipe_race(true, true); }

#[test]
fn task871_guard_invalid_public_wire_disconnects_without_response_or_owner_effect() {
    let host = winsmux_workspace::host::ProductHost::start(Vec::new()).unwrap();
    let instance = scalar(host.instance_id());
    for params in [json!({"pane_id":PANE,"expected_current_run_id":false}), json!({"pane_id":PANE,"expected_current_run_id":null,"unknown":true})] {
        let client = host.connect_authenticated().unwrap();
        let input = json!({"schema_version":1,"instance_id":instance,"operation_id":OP_FOR_GUARD,"expected_topology_revision":0,"operation":"pane.close","params":params});
        client.send_bytes(&serde_json::to_vec(&input).unwrap()).unwrap();
        assert!(client.read_bytes().is_err(), "Protocol ingress must emit no Response");
        let response = host.owner_request(&guard_request(&instance,"capabilities.get",None,json!({}))).unwrap();
        assert_success(&response,"capabilities.get");
        assert_eq!(value(&response)["topology_revision"], 0);
        assert!(host.generation_is_open());
    }
    host.shutdown().unwrap();
}

const OP_FOR_GUARD: &str = "20000000-0000-4000-8000-000000000000";

const PROJECT_A: &str = "30000000-0000-4000-8000-000000000001";
const PROJECT_B: &str = "30000000-0000-4000-8000-000000000002";
const PANE: &str = "40000000-0000-4000-8000-000000000000";
const RUN: &str = "50000000-0000-4000-8000-000000000000";
const UNKNOWN_CONNECTION: &str = "60000000-0000-4000-8000-000000000000";
const OLD_INSTANCE: &str = "80000000-0000-4000-8000-000000000000";

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

fn value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).expect("response JSON")
}

fn scalar<T: Serialize>(value: &T) -> String {
    self::value(value)
        .as_str()
        .expect("string scalar")
        .to_owned()
}

fn assert_error(response: &Response, code: &str) {
    let response = value(response);
    assert_eq!(response["accepted"], json!(false), "{response}");
    assert_eq!(response["result"], Value::Null, "{response}");
    assert_eq!(response["error"]["code"], json!(code), "{response}");
}

fn assert_success(response: &Response, operation: &str) -> Value {
    let response = value(response);
    assert_eq!(response["accepted"], json!(true), "{response}");
    assert_eq!(response["error"], Value::Null, "{response}");
    assert_eq!(response["result"]["operation"], json!(operation));
    response
}

fn owner(harness: &Harness, operation: &str, params: Value) -> Response {
    let instance = scalar(&harness.instance_id());
    harness.owner(&request(operation, Some(&instance), params))
}

fn pending_client(
    harness: &Harness,
    executable: &str,
    projects: Value,
    scopes: Value,
) -> winsmux_workspace::auth::testing::Client {
    let client = harness.connect(executable);
    let response = client
        .request(&request(
            "connection.request",
            None,
            json!({"project_ids": projects, "scopes": scopes}),
        ))
        .expect("pending response");
    assert_success(&response, "connection.request");
    client
}

#[test]
fn capabilities_and_connection_state_follow_the_frozen_decision_table() {
    let project_a = ProjectId::new(PROJECT_A).expect("project A");
    let project_b = ProjectId::new(PROJECT_B).expect("project B");
    let harness = Harness::new(vec![project_a, project_b]);
    let client = harness.connect("client.exe");

    let capabilities = client
        .request(&request("capabilities.get", None, json!({})))
        .expect("capabilities response");
    let capabilities = assert_success(&capabilities, "capabilities.get");
    assert_eq!(
        capabilities["result"]["data"]["operations"],
        json!([
            "artifact.list",
            "artifact.read",
            "artifact.register",
            "capabilities.get",
            "connection.decide",
            "connection.list",
            "connection.request",
            "connection.revoke",
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
            "shell.launch"
        ])
    );
    assert_eq!(capabilities["result"]["data"]["providers"], Value::Null);
    assert_eq!(
        capabilities["result"]["data"]["replay_capacity"],
        json!({"retained_bytes": 134217728, "active_bytes": 268435456})
    );
    assert_eq!(
        capabilities["result"]["data"]["shell_profile_ids"],
        Value::Null
    );

    let first = client
        .request(&request(
            "connection.request",
            None,
            json!({
                "project_ids": [PROJECT_A, PROJECT_B],
                "scopes": ["metadata", "read_output", "control"]
            }),
        ))
        .expect("first pending response");
    let first = assert_success(&first, "connection.request");
    let connection_id = first["result"]["data"]["connection_id"]
        .as_str()
        .expect("connection ID")
        .to_owned();
    let first_event = first["event_seq"].as_u64().expect("event sequence");

    let repeated = client
        .request(&request(
            "connection.request",
            None,
            json!({
                "project_ids": [PROJECT_B, PROJECT_A],
                "scopes": ["control", "metadata", "read_output"]
            }),
        ))
        .expect("repeated pending response");
    let repeated = assert_success(&repeated, "connection.request");
    assert_eq!(repeated["result"]["data"]["connection_id"], connection_id);
    assert_eq!(repeated["event_seq"], first_event);
    assert_eq!(harness.record_count(), 1);

    let changed = client
        .request(&request(
            "connection.request",
            None,
            json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        ))
        .expect("changed request response");
    assert_error(&changed, "invalid_request");

    let listed = assert_success(
        &owner(&harness, "connection.list", json!({})),
        "connection.list",
    );
    let entries = listed["result"]["data"]["connections"]
        .as_array()
        .expect("connection list");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["executable_name"], json!("client.exe"));
    assert_eq!(entries[0]["state"], json!("pending"));

    let allowed = owner(
        &harness,
        "connection.decide",
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": [PROJECT_A],
            "scopes": ["metadata"]
        }),
    );
    assert_success(&allowed, "connection.decide");

    let rich = client
        .request(&request("capabilities.get", None, json!({})))
        .expect("granted capabilities response");
    let rich = assert_success(&rich, "capabilities.get");
    assert_eq!(rich["result"]["data"]["providers"], json!([]));
    assert_eq!(rich["result"]["data"]["shell_profile_ids"], json!(["pwsh"]));

    let instance = scalar(&harness.instance_id());
    let listed_projects = client
        .request(&request("project.list", Some(&instance), json!({})))
        .expect("authorized project list");
    let listed_projects = assert_success(&listed_projects, "project.list");
    assert_eq!(
        listed_projects["result"]["data"]["projects"][0]["project_id"],
        json!(PROJECT_A)
    );
    assert_eq!(
        listed_projects["result"]["data"]["projects"][0]["path"],
        Value::Null
    );
    assert_eq!(
        listed_projects["result"]["data"]["projects"][0]["display_name"],
        Value::Null
    );
    let missing_scope = client
        .request(&request(
            "output.read",
            Some(&instance),
            json!({"run_id": RUN, "cursor": "cursor", "max_bytes": 100}),
        ))
        .expect("scope rejection response");
    assert_error(&missing_scope, "permission_denied");
    let request_after_grant = client
        .request(&request(
            "connection.request",
            None,
            json!({"project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        ))
        .expect("request after grant response");
    assert_error(&request_after_grant, "invalid_request");

    for (operation, params) in [
        ("connection.list", json!({})),
        (
            "connection.decide",
            json!({"connection_id": connection_id, "decision": "allow", "project_ids": [], "scopes": []}),
        ),
        ("connection.revoke", json!({"connection_id": connection_id})),
        ("host.stop", json!({})),
    ] {
        let response = client
            .request(&request(operation, Some(&instance), params))
            .expect("non-owner rejection");
        assert_error(&response, "permission_denied");
    }
    let before_stop = harness.authorization().testing_counters();
    assert_error(&owner(&harness, "host.stop", json!({})), "persistence_failed");
    assert_eq!(harness.authorization().testing_counters(), before_stop);
    assert!(!harness.generation_is_closed());

    let revoked = owner(
        &harness,
        "connection.revoke",
        json!({"connection_id": connection_id}),
    );
    assert_success(&revoked, "connection.revoke");
    assert!(client.cancelled());
    assert!(client
        .request(&request("capabilities.get", None, json!({})))
        .is_none());
    let after = assert_success(
        &owner(&harness, "connection.list", json!({})),
        "connection.list",
    );
    let closing = after["result"]["data"]["connections"]
        .as_array()
        .expect("closing connection list");
    assert_eq!(closing.len(), 1);
    assert_eq!(closing[0]["connection_id"], connection_id);
    assert_eq!(closing[0]["executable_name"], json!("client.exe"));
    assert_eq!(closing[0]["state"], json!("closing"));
    assert_eq!(closing[0]["granted_project_ids"], json!([]));
    assert_eq!(closing[0]["granted_scopes"], json!([]));
    assert_error(
        &owner(
            &harness,
            "connection.revoke",
            json!({"connection_id": connection_id}),
        ),
        "target_not_found",
    );
}

#[test]
fn owner_stop_accepts_an_empty_isolated_workspace_and_writes_c() {
    let root = std::env::temp_dir().join(format!(
        "winsmux-866-host-auth-stop-{}",
        uuid::Uuid::new_v4()
    ));
    let harness = Harness::new(Vec::new());
    assert!(harness.authorization().testing_install_isolated_layout(&root));
    let stopped = assert_success(&owner(&harness, "host.stop", json!({})), "host.stop");
    assert_eq!(stopped["result"]["data"]["stopped"], json!(true));
    assert!(harness.generation_is_closed());
    let confirmed = std::fs::read(root.join("confirmed.json")).expect("confirmed C");
    let snapshot = parse_snapshot(&confirmed).expect("valid C");
    assert!(snapshot.projects.is_empty());
    assert!(snapshot.panes.is_empty());
    assert!(snapshot.layouts.is_empty());
    assert!(snapshot.selected_project_id.0.is_none());
    assert!(snapshot.selected_pane_id.0.is_none());
    assert!(!root.join("backup.json").exists());
}

#[test]
fn empty_registry_invalid_transitions_and_deny_preserve_authority() {
    let empty = Harness::new(Vec::new());
    let empty_client = empty.connect("empty.exe");
    let unknown_project = empty_client
        .request(&request(
            "connection.request",
            None,
            json!({"project_ids": [PROJECT_A], "scopes": []}),
        ))
        .expect("empty registry rejection");
    assert_error(&unknown_project, "invalid_request");
    assert_eq!(empty.record_count(), 1);
    let empty_pending = empty_client
        .request(&request(
            "connection.request",
            None,
            json!({"project_ids": [], "scopes": []}),
        ))
        .expect("empty request is legal");
    assert_success(&empty_pending, "connection.request");

    let harness = Harness::new(vec![ProjectId::new(PROJECT_A).expect("project A")]);
    let client = pending_client(
        &harness,
        "deny.exe",
        json!([PROJECT_A]),
        json!(["metadata"]),
    );
    let connection_id = scalar(&client.connection_id());

    let invalid_deny = json!({
        "schema_version": 1,
        "instance_id": scalar(&harness.instance_id()),
        "operation_id": uuid::Uuid::new_v4().to_string(),
        "expected_topology_revision": null,
        "operation": "connection.decide",
        "params": {
            "connection_id": connection_id,
            "decision": "deny",
            "project_ids": [PROJECT_A],
            "scopes": []
        }
    });
    assert!(parse_request(&serde_json::to_vec(&invalid_deny).unwrap()).is_err());
    assert!(!client.cancelled());

    let outside_grant = owner(
        &harness,
        "connection.decide",
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": [PROJECT_B],
            "scopes": ["control"]
        }),
    );
    assert_error(&outside_grant, "invalid_request");
    assert!(!client.cancelled());

    let old_instance = harness.owner(&request(
        "connection.decide",
        Some(OLD_INSTANCE),
        json!({
            "connection_id": connection_id,
            "decision": "deny",
            "project_ids": [],
            "scopes": []
        }),
    ));
    assert_error(&old_instance, "state_unknown");
    assert!(!client.cancelled());

    let other = harness.connect("other.exe");
    let instance = scalar(&harness.instance_id());
    let cross_connection = other
        .request(&request(
            "connection.decide",
            Some(&instance),
            json!({
                "connection_id": connection_id,
                "decision": "deny",
                "project_ids": [],
                "scopes": []
            }),
        ))
        .expect("cross-connection rejection");
    assert_error(&cross_connection, "permission_denied");

    assert_error(
        &owner(
            &harness,
            "connection.revoke",
            json!({"connection_id": UNKNOWN_CONNECTION}),
        ),
        "target_not_found",
    );
    let denied = owner(
        &harness,
        "connection.decide",
        json!({
            "connection_id": connection_id,
            "decision": "deny",
            "project_ids": [],
            "scopes": []
        }),
    );
    assert_success(&denied, "connection.decide");
    assert!(client.cancelled());
    assert_error(
        &owner(
            &harness,
            "connection.decide",
            json!({
                "connection_id": connection_id,
                "decision": "allow",
                "project_ids": [],
                "scopes": []
            }),
        ),
        "target_not_found",
    );
}

#[test]
fn concurrent_decisions_commit_one_legal_transition() {
    let harness = Harness::new(vec![ProjectId::new(PROJECT_A).expect("project A")]);
    let client = pending_client(
        &harness,
        "race.exe",
        json!([PROJECT_A]),
        json!(["metadata"]),
    );
    let connection_id = scalar(&client.connection_id());
    let allow_harness = harness.clone();
    let deny_harness = harness.clone();
    let allow_id = connection_id.clone();
    let deny_id = connection_id.clone();
    let allow = std::thread::spawn(move || {
        owner(
            &allow_harness,
            "connection.decide",
            json!({"connection_id": allow_id, "decision": "allow", "project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        )
    });
    let deny = std::thread::spawn(move || {
        owner(
            &deny_harness,
            "connection.decide",
            json!({"connection_id": deny_id, "decision": "deny", "project_ids": [], "scopes": []}),
        )
    });
    let responses = [
        allow.join().expect("allow thread"),
        deny.join().expect("deny thread"),
    ];
    let values = responses.iter().map(value).collect::<Vec<_>>();
    assert_eq!(
        values
            .iter()
            .filter(|response| response["accepted"] == json!(true))
            .count(),
        1,
        "{values:?}"
    );
    assert!(values
        .iter()
        .all(|response| response["event_seq"] == json!(2)));
    let listed = assert_success(
        &owner(&harness, "connection.list", json!({})),
        "connection.list",
    );
    assert!(matches!(
        listed["result"]["data"]["connections"]
            .as_array()
            .map(Vec::len),
        Some(0 | 1)
    ));
}

#[test]
fn revoke_cancels_an_inflight_send_without_holding_the_auth_mutex() {
    let harness = Harness::new(vec![ProjectId::new(PROJECT_A).expect("project A")]);
    let client = pending_client(
        &harness,
        "slow.exe",
        json!([PROJECT_A]),
        json!(["metadata"]),
    );
    let connection_id = scalar(&client.connection_id());
    assert_success(
        &owner(
            &harness,
            "connection.decide",
            json!({"connection_id": connection_id, "decision": "allow", "project_ids": [PROJECT_A], "scopes": ["metadata"]}),
        ),
        "connection.decide",
    );
    let sibling = harness.connect("sibling.exe");
    let instance = scalar(&harness.instance_id());
    let operation = request("project.list", Some(&instance), json!({}));

    let (started_sender, started_receiver) = mpsc::channel();
    let (cancel_sender, cancel_receiver) = mpsc::channel();
    let (release_sender, release_receiver) = mpsc::channel();
    let slow_client = client.clone();
    let send = std::thread::spawn(move || {
        let observed_client = slow_client.clone();
        slow_client.request_with_send(&operation, move |_| {
            started_sender.send(()).expect("send started");
            observed_client.wait_cancelled();
            cancel_sender.send(()).expect("cancel observed");
            release_receiver.recv().expect("release send");
            false
        })
    });
    started_receiver.recv().expect("inflight send");

    let revoke_harness = harness.clone();
    let revoke = std::thread::spawn(move || {
        owner(
            &revoke_harness,
            "connection.revoke",
            json!({"connection_id": connection_id}),
        )
    });
    cancel_receiver.recv().expect("revoke cancellation");

    let sibling_response = sibling
        .request(&request("capabilities.get", None, json!({})))
        .expect("sibling response while revoke waits on only the slow gate");
    assert_success(&sibling_response, "capabilities.get");
    release_sender.send(()).expect("release slow send");
    assert_eq!(send.join().expect("send thread"), Some(false));
    assert_success(&revoke.join().expect("revoke thread"), "connection.revoke");
    assert!(client
        .request(&request("capabilities.get", None, json!({})))
        .is_none());
}

#[test]
fn actor_and_owner_injection_are_rejected_by_the_shared_codec() {
    let base = json!({
        "schema_version": 1,
        "instance_id": null,
        "operation_id": "20000000-0000-4000-8000-000000000000",
        "expected_topology_revision": null,
        "operation": "connection.request",
        "params": {"project_ids": [], "scopes": []}
    });
    for (path, injected) in [
        ("actor", json!("TASK862_SECRET_MARKER")),
        ("owner", json!(true)),
    ] {
        let mut candidate = base.clone();
        candidate[path] = injected;
        assert!(parse_request(&serde_json::to_vec(&candidate).unwrap()).is_err());
    }
    let mut nested = base;
    nested["params"]["actor"] = json!({"connection_id": UNKNOWN_CONNECTION});
    assert!(parse_request(&serde_json::to_vec(&nested).unwrap()).is_err());
}

#[test]
fn real_overlapped_pipe_framing_handles_boundaries_partial_io_eof_and_cancel() {
    let evidence = run_framing_probes().expect("real framing probes");
    assert!(evidence.zero_length_rejected, "{evidence:?}");
    assert!(evidence.over_limit_rejected, "{evidence:?}");
    assert!(evidence.exact_limit_accepted, "{evidence:?}");
    assert!(evidence.split_header_and_body_round_trip, "{evidence:?}");
    assert!(evidence.consecutive_frames_preserved, "{evidence:?}");
    assert!(evidence.partial_eof_rejected, "{evidence:?}");
    assert!(evidence.pending_read_cancelled_and_drained, "{evidence:?}");
}

#[test]
fn real_overlapped_io_prefers_cancel_and_drains_every_operation() {
    let evidence = run_generation_io_probes().expect("generation I/O probes");
    assert!(
        evidence.read_prestart_cancelled_without_consuming,
        "{evidence:?}"
    );
    assert!(evidence.read_sync_completion_cancelled, "{evidence:?}");
    assert!(
        evidence.read_pending_completion_cancelled_and_drained,
        "{evidence:?}"
    );
    assert!(evidence.read_partial_cancelled, "{evidence:?}");
    assert!(
        evidence.write_prestart_cancelled_without_writing,
        "{evidence:?}"
    );
    assert!(evidence.write_sync_completion_cancelled, "{evidence:?}");
    assert!(
        evidence.write_pending_completion_cancelled_and_drained,
        "{evidence:?}"
    );
    assert!(evidence.write_partial_frame_cancelled, "{evidence:?}");
    assert!(evidence.connect_prestart_cancelled, "{evidence:?}");
    assert!(evidence.connect_already_connected_cancelled, "{evidence:?}");
    assert!(
        evidence.connect_pending_completion_cancelled_and_drained,
        "{evidence:?}"
    );
}

#[test]
fn real_pipe_generation_closure_blocks_auth_proof_late_attach_and_response() {
    let evidence = run_generation_closure_probes().expect("generation closure probes");
    assert_eq!(evidence.owner_eof_cases, 5, "{evidence:?}");
    assert!(evidence.close_before_authentication_read, "{evidence:?}");
    assert!(
        evidence.authentication_permit_then_close_cancelled_read,
        "{evidence:?}"
    );
    assert!(evidence.close_before_proof_send, "{evidence:?}");
    assert!(
        evidence.proof_permit_then_close_cancelled_write,
        "{evidence:?}"
    );
    assert_eq!(evidence.late_attach_records, 0, "{evidence:?}");
    assert_eq!(evidence.late_response_bytes, 0, "{evidence:?}");
    assert!(evidence.late_worker_joined, "{evidence:?}");
}

#[test]
fn host_generation_epilogue_collects_all_threads_for_every_exit() {
    let evidence = run_host_epilogue_probes().expect("host generation epilogue probes");
    assert!(evidence.startup_failure_preserved, "{evidence:?}");
    assert!(evidence.protocol_failure_preserved, "{evidence:?}");
    assert!(evidence.transport_failure_preserved, "{evidence:?}");
    assert!(evidence.owner_eof_remains_success, "{evidence:?}");
    assert!(evidence.owner_cancel_remains_cancelled, "{evidence:?}");
    assert!(
        evidence.accept_error_closed_cancelled_and_collected,
        "{evidence:?}"
    );
    assert!(
        evidence.accept_panic_closed_cancelled_and_collected,
        "{evidence:?}"
    );
    assert!(
        evidence.worker_panic_did_not_skip_later_join,
        "{evidence:?}"
    );
    assert!(
        evidence.first_error_won_after_later_failures,
        "{evidence:?}"
    );
}

#[test]
fn real_windows_tokens_are_rejected_by_both_acl_and_header_first_peer_checks() {
    let evidence = run_os_authentication_probes().expect("real Windows token probes");
    assert!(evidence.anonymous_user_differs, "{evidence:?}");
    assert!(evidence.anonymous_has_no_logon, "{evidence:?}");
    assert!(evidence.anonymous_production_acl_denied, "{evidence:?}");
    assert_eq!(
        evidence.anonymous_peer.failure, "UserMismatch",
        "{evidence:?}"
    );
    assert!(evidence.anonymous_peer.impersonated, "{evidence:?}");
    assert!(evidence.anonymous_peer.user_checked, "{evidence:?}");
    assert!(!evidence.anonymous_peer.logon_checked, "{evidence:?}");
    assert!(evidence.anonymous_peer.reverted, "{evidence:?}");
    assert!(evidence.anonymous_peer.body_marker_unread, "{evidence:?}");
    assert_eq!(
        evidence.anonymous_peer.authorization_records, 0,
        "{evidence:?}"
    );

    assert!(evidence.new_credentials_same_user, "{evidence:?}");
    assert!(evidence.new_credentials_has_logon, "{evidence:?}");
    assert!(evidence.new_credentials_logon_differs, "{evidence:?}");
    assert!(
        evidence
            .new_credentials_current_logon_group_attributes
            .is_some(),
        "{evidence:?}"
    );
    assert!(
        evidence.new_credentials_current_logon_group_enabled,
        "{evidence:?}"
    );
    assert!(
        !evidence.new_credentials_current_logon_group_deny_only,
        "{evidence:?}"
    );
    assert!(
        evidence.new_credentials_production_acl_allowed,
        "{evidence:?}"
    );
    assert_eq!(
        evidence.new_credentials_peer.failure, "LogonMismatch",
        "{evidence:?}"
    );
    assert!(evidence.new_credentials_peer.impersonated, "{evidence:?}");
    assert!(evidence.new_credentials_peer.user_checked, "{evidence:?}");
    assert!(evidence.new_credentials_peer.logon_checked, "{evidence:?}");
    assert!(evidence.new_credentials_peer.reverted, "{evidence:?}");
    assert!(
        evidence.new_credentials_peer.body_marker_unread,
        "{evidence:?}"
    );
    assert_eq!(
        evidence.new_credentials_peer.authorization_records, 0,
        "{evidence:?}"
    );
    assert!(evidence.restricted_same_user, "{evidence:?}");
    assert!(evidence.restricted_logon_unchanged, "{evidence:?}");
    assert!(
        evidence.restricted_current_logon_group_attributes.is_some(),
        "{evidence:?}"
    );
    assert!(
        !evidence.restricted_current_logon_group_enabled,
        "{evidence:?}"
    );
    assert!(
        evidence.restricted_current_logon_group_deny_only,
        "{evidence:?}"
    );
    assert!(evidence.restricted_production_acl_denied, "{evidence:?}");
}

#[test]
fn real_windows_server_capability_is_separate_from_client_data_access() {
    let evidence = run_server_capability_probes().expect("real server capability probes");
    assert!(evidence.same_user, "{evidence:?}");
    assert!(evidence.distinct_logon, "{evidence:?}");
    assert!(evidence.logon_group_enabled, "{evidence:?}");
    assert!(evidence.logon_group_not_deny_only, "{evidence:?}");
    assert!(evidence.token_not_inherited, "{evidence:?}");
    assert!(evidence.first_instance_created, "{evidence:?}");
    assert!(evidence.second_instance_created, "{evidence:?}");
    assert!(evidence.original_server_create_denied, "{evidence:?}");
    assert!(evidence.separate_server_token_create_denied, "{evidence:?}");
    assert!(evidence.original_data_connect_succeeded, "{evidence:?}");
    assert!(evidence.original_write_dac_denied, "{evidence:?}");
    assert!(evidence.original_write_owner_denied, "{evidence:?}");
}

#[test]
fn control_scope_does_not_authorize_output_reads() {
    let harness = Harness::new(Vec::new());
    let client = pending_client(&harness, "control.exe", json!([]), json!(["control"]));
    let connection_id = scalar(&client.connection_id());
    assert_success(
        &owner(
            &harness,
            "connection.decide",
            json!({"connection_id": connection_id, "decision": "allow", "project_ids": [], "scopes": ["control"]}),
        ),
        "connection.decide",
    );
    let instance = scalar(&harness.instance_id());
    let control = client
        .request(&request(
            "input.key",
            Some(&instance),
            json!({"pane_id": PANE, "run_id": RUN, "key": "enter"}),
        ))
        .expect("control request");
    assert_error(&control, "target_not_found");
    let output = client
        .request(&request(
            "output.read",
            Some(&instance),
            json!({"run_id": RUN, "cursor": "cursor", "max_bytes": 100}),
        ))
        .expect("output request");
    assert_error(&output, "permission_denied");
}

#[test]
fn generation_close_is_linearizable_idempotent_and_fail_closed() {
    let harness = Harness::new(Vec::new());
    let unpaired = harness.connect("unpaired.exe");
    let pending = pending_client(&harness, "pending.exe", json!([]), json!(["metadata"]));
    let granted = pending_client(&harness, "granted.exe", json!([]), json!(["metadata"]));
    assert_success(
        &owner(
            &harness,
            "connection.decide",
            json!({
                "connection_id": scalar(&granted.connection_id()),
                "decision": "allow",
                "project_ids": [],
                "scopes": ["metadata"]
            }),
        ),
        "connection.decide",
    );
    let revoked = pending_client(&harness, "revoked.exe", json!([]), json!(["metadata"]));
    assert_success(
        &owner(
            &harness,
            "connection.decide",
            json!({
                "connection_id": scalar(&revoked.connection_id()),
                "decision": "deny",
                "project_ids": [],
                "scopes": []
            }),
        ),
        "connection.decide",
    );
    assert_eq!(revoked.cancellation_count(), 1);
    assert!(harness.authentication_permitted());
    assert!(harness.proof_send_permitted());
    harness.set_event_seq_to_max();

    harness.close_generation();
    assert!(harness.generation_is_closed());
    assert_eq!(harness.event_seq(), u64::MAX >> 11);
    assert_eq!(harness.record_count(), 4);
    assert_eq!(
        harness.record_states(),
        vec!["closing", "closing", "closing", "closing"]
    );
    for client in [&unpaired, &pending, &granted, &revoked] {
        assert!(client.cancelled());
        assert!(!client.send_if_current());
        assert!(client
            .request(&request("capabilities.get", None, json!({})))
            .is_none());
    }
    assert_eq!(unpaired.cancellation_count(), 1);
    assert_eq!(pending.cancellation_count(), 1);
    assert_eq!(granted.cancellation_count(), 1);
    assert_eq!(revoked.cancellation_count(), 1);
    assert!(harness.try_connect("late-after-close.exe").is_none());
    assert!(!harness.authentication_permitted());
    assert!(!harness.proof_send_permitted());
    let instance = scalar(&harness.instance_id());
    assert!(harness
        .try_owner(&request("connection.list", Some(&instance), json!({})))
        .is_none());

    harness.close_generation();
    assert_eq!(harness.event_seq(), u64::MAX >> 11);
    assert_eq!(unpaired.cancellation_count(), 1);
    assert_eq!(pending.cancellation_count(), 1);
    assert_eq!(granted.cancellation_count(), 1);
    assert_eq!(revoked.cancellation_count(), 1);

    let empty = Harness::new(Vec::new());
    empty.close_generation();
    empty.close_generation();
    assert!(empty.generation_is_closed());
    assert_eq!(empty.event_seq(), 0);
    assert!(empty.try_connect("late-empty.exe").is_none());

    let poisoned = Harness::new(Vec::new());
    let existing = poisoned.connect("before-poison.exe");
    poisoned.poison();
    poisoned.close_generation();
    assert!(poisoned.try_connect("after-poison.exe").is_none());
    assert!(!poisoned.authentication_permitted());
    assert!(!poisoned.proof_send_permitted());
    assert!(!existing.send_if_current());
    assert!(existing
        .request(&request("capabilities.get", None, json!({})))
        .is_none());
}

#[test]
fn generation_close_releases_auth_lock_before_cancelling_and_draining_send() {
    let harness = Harness::new(Vec::new());
    let client = pending_client(&harness, "closing-send.exe", json!([]), json!(["metadata"]));
    assert_success(
        &owner(
            &harness,
            "connection.decide",
            json!({
                "connection_id": scalar(&client.connection_id()),
                "decision": "allow",
                "project_ids": [],
                "scopes": ["metadata"]
            }),
        ),
        "connection.decide",
    );
    let instance = scalar(&harness.instance_id());
    let operation = request("project.list", Some(&instance), json!({}));
    let (started_sender, started_receiver) = mpsc::channel();
    let (cancel_sender, cancel_receiver) = mpsc::channel();
    let (release_sender, release_receiver) = mpsc::channel();
    let sending_client = client.clone();
    let send = std::thread::spawn(move || {
        let observed_client = sending_client.clone();
        sending_client.request_with_send(&operation, move |_| {
            started_sender.send(()).expect("send started");
            observed_client.wait_cancelled();
            cancel_sender.send(()).expect("cancel observed");
            release_receiver.recv().expect("release send");
            false
        })
    });
    started_receiver.recv().expect("inflight send");

    let closing_harness = harness.clone();
    let close = std::thread::spawn(move || closing_harness.close_generation());
    cancel_receiver.recv().expect("generation cancellation");

    assert!(harness.generation_is_closed());
    assert!(harness.try_connect("while-draining.exe").is_none());
    assert!(!harness.authentication_permitted());
    assert!(!harness.proof_send_permitted());
    release_sender.send(()).expect("release inflight send");
    assert_eq!(send.join().expect("send thread"), Some(false));
    close.join().expect("generation close thread");
    assert_eq!(client.cancellation_count(), 1);
}
