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

fn current_versioned_fixture_value() -> Value {
    serde_json::from_str(include_str!(
        "../../tests/fixtures/rust-parity/common-contract-package-v0.36.28.json"
    ))
    .expect("versioned fixture should be valid JSON")
}

fn backend_migration_fixture_value() -> Value {
    serde_json::from_str(include_str!(
        "../../tests/fixtures/rust-parity/common-contract-backend-migration-v0.36.28.json"
    ))
    .expect("backend migration fixture should be valid JSON")
}

fn readiness_vocabulary_fixture_value() -> Value {
    serde_json::from_str(include_str!(
        "../../tests/fixtures/rust-parity/common-contract-readiness-vocabulary-fixtures.json"
    ))
    .expect("readiness vocabulary fixtures should be valid JSON")
}

fn parse_value(value: Value) -> CommonContractPackage {
    CommonContractPackage::from_json(&value.to_string()).expect("contract should parse")
}

fn parse_error(value: Value) -> String {
    CommonContractPackage::from_json(&value.to_string())
        .expect_err("contract should fail to parse")
        .to_string()
}

fn apply_readiness_vocabulary_mutation(mut package: Value, mutation: &Value) -> Value {
    if let Some(copy) = mutation.get("copyVocabularyValues") {
        let from = copy["from"]
            .as_str()
            .expect("copyVocabularyValues.from should be a string");
        let to = copy["to"]
            .as_str()
            .expect("copyVocabularyValues.to should be a string");
        let values = package["vocabularies"][from]["values"].clone();
        package["vocabularies"][to]["values"] = values;
        return package;
    }

    if let Some(remove) = mutation.get("removeVocabularyValue") {
        let vocabulary = remove["vocabulary"]
            .as_str()
            .expect("removeVocabularyValue.vocabulary should be a string");
        let value = remove["value"]
            .as_str()
            .expect("removeVocabularyValue.value should be a string");
        let values = package["vocabularies"][vocabulary]["values"]
            .as_array_mut()
            .expect("readiness vocabulary values should be an array");
        let before = values.len();
        values.retain(|item| item.as_str() != Some(value));
        assert_ne!(before, values.len(), "fixture should remove {}", value);
        return package;
    }

    panic!("unsupported readiness vocabulary mutation: {}", mutation);
}

#[test]
fn common_contract_fixture_deserializes_and_validates() {
    let contract = parse_value(fixture_value());
    contract.validate().expect("contract should validate");
}

#[test]
fn common_contract_v03628_fixture_matches_current_baseline() {
    assert_eq!(current_versioned_fixture_value(), fixture_value());
    let contract = parse_value(current_versioned_fixture_value());
    contract
        .validate()
        .expect("versioned contract fixture should validate");
}

#[test]
fn common_contract_v03628_records_breaking_backend_migration() {
    let migration = backend_migration_fixture_value();
    let current = current_versioned_fixture_value();
    assert_eq!(
        migration["from_versions"],
        json!(["0.36.24", "0.36.25", "0.36.26", "0.36.27"])
    );
    assert_eq!(migration["to_version"], current["version"]);
    assert_eq!(migration["prior_backend_count"], 5);
    assert_eq!(migration["current_backend_count"], 4);
    assert_eq!(migration["removed_count"], 1);
    assert_eq!(migration["breaking"], true);
    assert_eq!(migration["source_commit"], "59f7ade8");
    assert_eq!(
        migration["prior_backend_count"].as_u64(),
        migration["current_backend_count"]
            .as_u64()
            .map(|value| value + 1)
    );
}

#[test]
fn common_contract_rejects_older_versions_without_implicit_migration() {
    for version in ["0.36.24", "0.36.25", "0.36.26", "0.36.27"] {
        let mut older = current_versioned_fixture_value();
        older["version"] = json!(version);
        let contract = parse_value(older);
        let error = contract
            .validate()
            .expect_err("older versions must not migrate implicitly");
        assert!(error.contains(&format!("unsupported common contract version: {}", version)));
    }
}

#[test]
fn common_contract_rejects_an_unexpected_backend_capability() {
    let mut fixture = fixture_value();
    fixture["vocabularies"]["backendCapabilities"]["values"]
        .as_array_mut()
        .expect("backend capabilities should be an array")
        .push(json!("unexpected-capability"));

    let contract = parse_value(fixture);
    let error = contract
        .validate()
        .expect_err("an unexpected backend capability must fail validation");
    assert!(error.contains("backend capabilities diverged"));
}

#[test]
fn common_contract_rejects_unknown_top_level_field() {
    let mut fixture = fixture_value();
    fixture["unexpected"] = json!(true);
    let error = parse_error(fixture);
    assert!(error.contains("unknown field"));
    assert!(error.contains("unexpected"));
}

#[test]
fn common_contract_rejects_unknown_vocabulary_collection() {
    let mut fixture = fixture_value();
    fixture["vocabularies"]["unexpectedVocabulary"] = json!({
        "owner": "tests",
        "values": ["unexpected"]
    });
    let error = parse_error(fixture);
    assert!(error.contains("unknown field"));
    assert!(error.contains("unexpectedVocabulary"));
}

#[test]
fn common_contract_rejects_unknown_vocabulary_field() {
    let mut fixture = fixture_value();
    fixture["vocabularies"]["modelReadiness"]["unexpected"] = json!("field");
    let error = parse_error(fixture);
    assert!(error.contains("unknown field"));
    assert!(error.contains("unexpected"));
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
fn common_contract_rejects_task722_readiness_vocabulary_fixtures() {
    let fixtures = readiness_vocabulary_fixture_value();
    assert_eq!(fixtures["version"], "0.36.28");

    for fixture in fixtures["fixtures"]
        .as_array()
        .expect("fixtures should be an array")
    {
        let id = fixture["id"]
            .as_str()
            .expect("fixture id should be a string");
        let expected_error = fixture["expectedError"]
            .as_str()
            .expect("fixture expectedError should be a string");
        let mutated = apply_readiness_vocabulary_mutation(fixture_value(), &fixture["mutation"]);
        let contract = parse_value(mutated);
        let error = contract
            .validate()
            .expect_err("readiness vocabulary fixture should fail validation");
        assert!(
            error.contains(expected_error),
            "{} expected error containing {:?}, got {:?}",
            id,
            expected_error,
            error
        );
    }
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
