#![cfg(all(windows, debug_assertions))]

use serde_json::json;
use winsmux_workspace::contract::parse_request;
use winsmux_workspace::host::ProductHost;

fn public_capabilities(host: &ProductHost) {
    let client = host.connect_authenticated().expect("ordinary public authentication");
    let request = parse_request(&serde_json::to_vec(&json!({
        "schema_version":1,
        "instance_id":null,
        "operation_id":uuid::Uuid::new_v4().to_string(),
        "expected_topology_revision":null,
        "operation":"capabilities.get",
        "params":{},
    })).unwrap()).unwrap();
    let response = client.transact(&request).expect("ordinary public request");
    assert!(response.accepted);
    let value = serde_json::to_value(response).unwrap();
    let operations = value["result"]["data"]["operations"].as_array().unwrap();
    assert_eq!(operations.len(), 33);
    for name in ["artifact.choose", "artifact.diff", "artifact.choice.list", "diagnostics.get"] {
        assert!(operations.contains(&json!(name)), "missing supported operation: {name}");
    }
}

#[test]
fn sidecar_proof_and_optional_failures_leave_original_host_usable() {
    let host = ProductHost::start(Vec::new()).expect("new host");
    assert!(host.extension_proof_available(), "current-instance signed identity");
    public_capabilities(&host);
    host.shutdown().unwrap();

    std::env::set_var("WINSMUX_TASK867_FAIL_SIDECAR_CREATE", "1");
    let host = ProductHost::start(Vec::new()).expect("ordinary host despite sidecar creation failure");
    std::env::remove_var("WINSMUX_TASK867_FAIL_SIDECAR_CREATE");
    assert!(!host.extension_proof_available());
    public_capabilities(&host);
    host.shutdown().unwrap();

    let host = ProductHost::start(Vec::new()).expect("new host for admission failure");
    std::env::set_var("WINSMUX_TASK867_FAIL_SIDECAR_ADMISSION", "1");
    assert!(!host.extension_proof_available());
    std::env::remove_var("WINSMUX_TASK867_FAIL_SIDECAR_ADMISSION");
    public_capabilities(&host);
    host.shutdown().unwrap();

    let host = ProductHost::start(Vec::new()).expect("new host for sidecar resource failure");
    std::env::set_var("WINSMUX_TASK867_FAIL_SIDECAR_RESOURCE", "1");
    assert!(!host.extension_proof_available());
    std::env::remove_var("WINSMUX_TASK867_FAIL_SIDECAR_RESOURCE");
    public_capabilities(&host);
    host.shutdown().unwrap();
}
