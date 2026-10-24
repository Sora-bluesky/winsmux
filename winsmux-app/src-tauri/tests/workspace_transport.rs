#![cfg(windows)]

use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;
use winsmux_workspace::{
    contract::{Action, ErrorCode, Success},
    host::{WorkspaceOwner, WorkspaceRequestError},
    parse_request, serialize_response,
};

static HOST_TEST_LOCK: Mutex<()> = Mutex::new(());

fn request(
    operation: &str,
    instance: &str,
    number: u32,
    params: Value,
) -> winsmux_workspace::Request {
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": instance,
            "operation_id": format!("87000000-0000-4000-8000-{number:012x}"),
            "expected_topology_revision": null,
            "operation": operation,
            "params": params,
        }))
        .expect("request JSON"),
    )
    .expect("strict request")
}

fn stop_after_probe_cleanup(owner: &mut WorkspaceOwner, instance: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    let mut number = 100;
    loop {
        let stop = request("host.stop", instance, number, json!({}));
        assert!(matches!(stop.action, Action::HostStop(_)));
        let response = owner.request(&stop).expect("correlated host.stop response");
        if response.accepted {
            assert!(matches!(response.result.0, Some(Success::HostStop(_))));
            return;
        }
        assert_eq!(
            response.error.0.as_ref().map(|error| error.code()),
            Some(ErrorCode::OperationConflict)
        );
        assert!(
            std::time::Instant::now() < deadline,
            "provider cleanup did not finish"
        );
        std::thread::sleep(std::time::Duration::from_secs(1));
        number += 1;
    }
}

#[test]
fn headless_owner_keeps_cli_contract_and_refuses_stale_requests() {
    let _lock = HOST_TEST_LOCK.lock().expect("host test lock");
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let home = std::env::temp_dir().join(format!("winsmux-task870-home-{}", std::process::id()));
    std::fs::create_dir_all(home.join("AppData/Local")).expect("isolated host home");
    std::env::set_var("USERPROFILE", &home);
    std::env::set_var("HOME", &home);
    let sidecar = manifest.join(format!(
        "binaries/winsmux-{}.exe",
        env!("TAURI_ENV_TARGET_TRIPLE")
    ));
    assert!(sidecar.is_file(), "prepared companion CLI must exist");

    let mut owner = WorkspaceOwner::start(&sidecar).expect("real headless CLI host");
    let instance = owner.discovery().instance_id().as_str().to_owned();
    assert_eq!(owner.discovery().schema_version().get(), 1);
    assert!(owner
        .discovery()
        .pipe_name()
        .starts_with(r"\\.\pipe\winsmux-workspace-v1-"));

    let capabilities = request("capabilities.get", &instance, 1, json!({}));
    let first = owner.request(&capabilities).expect("capabilities response");
    assert!(first.accepted);
    assert!(matches!(first.result.0, Some(Success::CapabilitiesGet(_))));
    assert_eq!(first.instance_id.as_str(), instance);
    let bytes = serialize_response(&capabilities, &first).expect("canonical CLI response");
    assert_eq!(
        winsmux_workspace::parse_response(&capabilities, &bytes).expect("parse CLI response"),
        first
    );

    let stale = request(
        "project.list",
        "87000000-0000-4000-8000-000000000999",
        2,
        json!({}),
    );
    assert_eq!(
        owner.request(&stale),
        Err(WorkspaceRequestError::ProtocolFailed)
    );
    let ordinary = request("project.list", &instance, 3, json!({}));
    assert!(
        owner
            .request(&ordinary)
            .expect("owner usable after refusal")
            .accepted
    );

    let unavailable_target = request(
        "artifact.choice.list",
        &instance,
        4,
        json!({"project_id": "87000000-0000-4000-8000-000000000998"}),
    );
    let artifact_result = owner
        .request(&unavailable_target)
        .expect("authenticated artifact sidecar admits owner request");
    assert!(!artifact_result.accepted);
    assert!(
        owner
            .request(&request("project.list", &instance, 5, json!({})))
            .expect("ordinary request survives artifact preflight")
            .accepted
    );

    stop_after_probe_cleanup(&mut owner, &instance);
    owner.collect().expect("collect exact host child");

    for fault in [
        "WINSMUX_TASK867_FAIL_SIDECAR_CREATE",
        "WINSMUX_TASK867_FAIL_SIDECAR_PROOF",
    ] {
        std::env::set_var(fault, "1");
        let mut owner = WorkspaceOwner::start(&sidecar).expect("ordinary host remains available");
        std::env::remove_var(fault);
        let instance = owner.discovery().instance_id().as_str().to_owned();
        let choice = request(
            "artifact.choice.list",
            &instance,
            7,
            json!({
                "project_id": "87000000-0000-4000-8000-000000000998"
            }),
        );
        assert_eq!(
            owner.request(&choice),
            Err(WorkspaceRequestError::ProtocolFailed)
        );
        assert!(
            owner
                .request(&request("project.list", &instance, 8, json!({})))
                .expect("ordinary owner frame after sidecar refusal")
                .accepted
        );
        stop_after_probe_cleanup(&mut owner, &instance);
        owner.collect().expect("collect refused-sidecar child");
    }
}
