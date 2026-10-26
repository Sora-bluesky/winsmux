#![cfg(all(windows, debug_assertions))]
mod support;
use serde_json::json;
use std::fs;
use support::*;
use winsmux_workspace::auth::testing::Harness;

#[test]
fn synthetic_carriers_do_not_enter_shared_diagnostics_or_metadata() {
    let markers = ["WMX_SYNTH_ARGV", "WMX_SYNTH_ENV", "WMX_SYNTH_OUTPUT", "WMX_SYNTH_PATH"];
    assert!(std::env::args().any(|arg| arg.contains(markers[0])), "argv carrier missing");
    assert_eq!(std::env::var("WINSMUX_PRIVACY_MARKER").unwrap(), markers[1]);
    let tree = Scratch::new(markers[3]);
    let project = tree.0.join("WMX_SYNTH_PATH_project"); fs::create_dir(&project).unwrap();
    fs::write(project.join("output.txt"), markers[2]).unwrap();
    let before = snapshot(&project);
    let h = Harness::new(Vec::new());
    assert!(h.authorization().testing_install_isolated_layout(&tree.0.join("new-store")));
    let opened = owner(&h, "project.open", json!({"path":project.to_str().unwrap()}));
    let project_id = accepted(&opened)["project_id"].as_str().unwrap();
    let client = h.connect("WMX_SYNTH_ARGV_observer.exe");
    let pending = serde_json::to_value(client.request(&request(&h, "connection.request",
        json!({"project_ids":[project_id],"scopes":["metadata"]}))).unwrap()).unwrap();
    let connection = accepted(&pending)["connection_id"].as_str().unwrap();
    accepted(&owner(&h, "connection.decide", json!({"connection_id":connection,
        "decision":"allow","project_ids":[project_id],"scopes":["metadata"]})));
    let mut shared = Vec::new();
    shared.push(owner(&h, "diagnostics.get", json!({})));
    for operation in ["diagnostics.get", "project.list"] {
        let response = serde_json::to_value(client.request(&request(&h, operation, json!({}))).unwrap()).unwrap();
        accepted(&response); shared.push(response);
    }
    assert_eq!(shared[1]["result"]["data"].as_object().unwrap().len(), 5);
    if std::env::var_os("WINSMUX_PRIVACY_NEGATIVE").is_some() {
        shared[0]["synthetic_leak"] = json!(markers[2]);
    }
    let text = serde_json::to_string(&shared).unwrap();
    for marker in markers { assert!(!text.contains(marker), "shared diagnostic leaked synthetic marker"); }
    assert_eq!(snapshot(&project), before);
    assert_eq!(h.authorization().testing_spawn_counts(), (0,0));
    println!("{{\"shared_projection_checks\":3,\"marker_carriers\":4,\"native_runtime_output\":\"not_run\"}}");
}
