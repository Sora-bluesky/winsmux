#[path = "../src/workflow.rs"]
mod workflow;
#[path = "../src/workspace_recipe.rs"]
mod workspace_recipe;

use std::fs;
use std::process::Command;

use workflow::normalize_workflow_from_value;
use workspace_recipe::{normalize_workspace_plan, parse_workspace_yaml, SlotCapabilities};

const VALID_RECIPE: &str = include_str!("../../tests/fixtures/workspace-recipes/valid-v1.yaml");
const VALID_PROVIDER_CAPABILITIES: &str =
    include_str!("../../tests/fixtures/workspace-recipes/valid-v1.provider-capabilities.json");

fn slots() -> Vec<SlotCapabilities> {
    vec![
        SlotCapabilities {
            slot_id: "worker-1".to_string(),
            supports_file_edit: true,
            supports_verification: false,
            supports_structured_result: false,
        },
        SlotCapabilities {
            slot_id: "reviewer-1".to_string(),
            supports_file_edit: false,
            supports_verification: true,
            supports_structured_result: true,
        },
    ]
}

fn workflow_yaml(nodes: &str) -> String {
    format!("{VALID_RECIPE}\nworkflows:\n  bugfix:\n    schema-version: 1\n    nodes:\n{nodes}")
}

fn normalize(yaml: &str) -> std::io::Result<workflow::NormalizedWorkflow> {
    let root = parse_workspace_yaml(yaml)?;
    let plan = normalize_workspace_plan(yaml, "bugfix-two-slot", Some("bugfix"), &slots())?;
    normalize_workflow_from_value(&root, "bugfix", "run-task-659", &plan)
}

#[test]
fn workflow_normalization_is_deterministic_and_resolves_runtime_slots() {
    let reverse_order = workflow_yaml(
        "      - node-id: verify\n        pane-ref: verify\n        depends-on: [build]\n        action: operator-dispatch\n      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n",
    );
    let forward_order = workflow_yaml(
        "      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n      - node-id: verify\n        pane-ref: verify\n        depends-on: [build]\n        action: operator-dispatch\n",
    );

    let first = normalize(&reverse_order).expect("reverse source order should normalize");
    let second = normalize(&forward_order).expect("forward source order should normalize");
    let first_bytes = serde_json::to_vec(&first).expect("serialize normalized workflow");
    let second_bytes = serde_json::to_vec(&second).expect("serialize normalized workflow");

    assert_eq!(first_bytes, second_bytes);
    assert_eq!(first.topological_order, ["build", "verify"]);
    assert_eq!(first.nodes[0].pane_ref, "worker-1");
    assert_eq!(first.nodes[1].pane_ref, "reviewer-1");
    assert_eq!(first.nodes[0].idempotency_key, "run-task-659:build");
    assert_eq!(first.nodes[1].idempotency_key, "run-task-659:verify");
}

#[test]
fn workflow_normalization_rejects_cycles_missing_nodes_and_duplicate_edges() {
    let cases = [
        (
            workflow_yaml(
                "      - node-id: build\n        pane-ref: implement\n        depends-on: [verify]\n        action: operator-dispatch\n      - node-id: verify\n        pane-ref: verify\n        depends-on: [build]\n        action: operator-dispatch\n",
            ),
            "workflow_cycle",
        ),
        (
            workflow_yaml(
                "      - node-id: build\n        pane-ref: implement\n        depends-on: [missing]\n        action: operator-dispatch\n",
            ),
            "depends on unknown node",
        ),
        (
            workflow_yaml(
                "      - node-id: build\n        pane-ref: implement\n        depends-on: [prepare, prepare]\n        action: operator-dispatch\n      - node-id: prepare\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n",
            ),
            "invalid dependency set",
        ),
    ];

    for (yaml, expected) in cases {
        let error = normalize(&yaml).expect_err("invalid workflow graph must fail closed");
        assert!(
            error.to_string().contains(expected),
            "expected {expected:?}, got {error}"
        );
    }
}

#[test]
fn workflow_normalization_rejects_unknown_panes_actions_fields_and_duplicate_nodes() {
    let cases = [
        workflow_yaml(
            "      - node-id: build\n        pane-ref: missing\n        depends-on: []\n        action: operator-dispatch\n",
        ),
        workflow_yaml(
            "      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: shell\n",
        ),
        workflow_yaml(
            "      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n        prompt: private\n",
        ),
        workflow_yaml(
            "      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n",
        ),
    ];

    for yaml in cases {
        normalize(&yaml).expect_err("unsupported workflow surface must fail closed");
    }
}

#[test]
#[cfg(windows)]
fn public_workspace_plan_requires_run_identity_and_emits_the_normalized_workflow() {
    let fixture = tempfile::tempdir().expect("create isolated workflow fixture");
    let project_dir = fixture.path().join("project");
    let runtime_dir = project_dir.join(".winsmux");
    let home_dir = fixture.path().join("home");
    fs::create_dir_all(&runtime_dir).expect("create runtime directory");
    fs::create_dir_all(&home_dir).expect("create isolated home");
    let yaml = workflow_yaml(
        "      - node-id: verify\n        pane-ref: verify\n        depends-on: [build]\n        action: operator-dispatch\n      - node-id: build\n        pane-ref: implement\n        depends-on: []\n        action: operator-dispatch\n",
    );
    fs::write(project_dir.join(".winsmux.yaml"), yaml).expect("write workflow config");
    fs::write(
        runtime_dir.join("provider-capabilities.json"),
        VALID_PROVIDER_CAPABILITIES,
    )
    .expect("write provider capabilities");

    let binary = env!("CARGO_BIN_EXE_winsmux");
    let output = Command::new(binary)
        .args([
            "workspace-plan",
            "--recipe-id",
            "bugfix-two-slot",
            "--workflow-id",
            "bugfix",
            "--run-id",
            "run-task-659",
            "--json",
            "--project-dir",
        ])
        .arg(&project_dir)
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .env_remove("PSMUX_TARGET_SESSION")
        .env_remove("PSMUX_TARGET_FULL")
        .env_remove("TMUX")
        .output()
        .expect("run public workspace-plan");
    assert!(
        output.status.success(),
        "workspace-plan stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("parse workspace-plan JSON");
    assert_eq!(payload["workflow"]["run_id"], "run-task-659");
    assert_eq!(
        payload["workflow"]["topological_order"],
        serde_json::json!(["build", "verify"])
    );
    assert_eq!(payload["workflow"]["nodes"][0]["pane_ref"], "worker-1");

    let missing_workflow = Command::new(binary)
        .args([
            "workspace-plan",
            "--recipe-id",
            "bugfix-two-slot",
            "--run-id",
            "run-task-659",
            "--json",
            "--project-dir",
        ])
        .arg(&project_dir)
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .output()
        .expect("run incomplete workspace-plan");
    assert!(!missing_workflow.status.success());
    assert!(String::from_utf8_lossy(&missing_workflow.stderr)
        .contains("workspace-plan --run-id requires --workflow-id"));

    let preview = Command::new(binary)
        .args([
            "workspace-plan",
            "--recipe-id",
            "bugfix-two-slot",
            "--workflow-id",
            "bugfix",
            "--json",
            "--project-dir",
        ])
        .arg(&project_dir)
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .output()
        .expect("run legacy recipe preview");
    assert!(preview.status.success());
    let preview_payload: serde_json::Value =
        serde_json::from_slice(&preview.stdout).expect("parse preview JSON");
    assert!(preview_payload.get("workflow").is_none());
}
