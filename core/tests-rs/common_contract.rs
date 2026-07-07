#[path = "../src/common_contract.rs"]
mod common_contract;

use common_contract::CommonContractPackage;
use serde_json::{json, Value};

fn fixture_value() -> Value {
    serde_json::from_str(include_str!(
        "../../tests/fixtures/rust-parity/common-contract-package.json"
    ))
    .expect("fixture should be valid JSON")
}

fn parse_value(value: Value) -> CommonContractPackage {
    CommonContractPackage::from_json(&value.to_string()).expect("contract should parse")
}

#[test]
fn common_contract_fixture_deserializes_and_validates() {
    let contract = parse_value(fixture_value());
    contract.validate().expect("contract should validate");
}

#[test]
fn common_contract_rejects_missing_surface() {
    let mut fixture = fixture_value();
    fixture["surfaces"] = json!(["provider", "readiness"]);
    let contract = parse_value(fixture);
    let error = contract
        .validate()
        .expect_err("missing surfaces should fail validation");
    assert!(error.contains("surfaces diverged"));
}

#[test]
fn common_contract_rejects_runtime_worker_state_outside_model_readiness() {
    let mut fixture = fixture_value();
    fixture["vocabularies"]["runtimeWorkerReadiness"]["values"] =
        json!(["runnable", "setup-required", "missing"]);
    let contract = parse_value(fixture);
    let error = contract
        .validate()
        .expect_err("runtime worker readiness must remain a model readiness subset");
    assert!(error.contains("missing is not in model readiness"));
}

#[test]
fn common_contract_rejects_conflated_readiness_vocabularies() {
    let mut fixture = fixture_value();
    let model_readiness = fixture["vocabularies"]["modelReadiness"]["values"].clone();
    fixture["vocabularies"]["workerPaneReadiness"]["values"] = model_readiness;
    let contract = parse_value(fixture);
    let error = contract
        .validate()
        .expect_err("worker pane readiness must not copy model readiness");
    assert!(error.contains("must stay separate"));
}

#[test]
fn common_contract_preserves_runtime_effort_order() {
    let mut fixture = fixture_value();
    fixture["vocabularies"]["reasoningEfforts"]["values"] =
        json!(["provider-default", "low", "medium", "high", "xhigh", "max"]);
    let contract = parse_value(fixture);
    let error = contract
        .validate()
        .expect_err("xhigh before max should fail validation");
    assert!(error.contains("must keep max before xhigh"));
}
