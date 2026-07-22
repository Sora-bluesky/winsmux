#[path = "../src/workflow.rs"]
mod workflow;
#[path = "../src/workspace_recipe.rs"]
mod workspace_recipe;

use std::collections::{BTreeMap, BTreeSet};

use workflow::{
    initial_node_states, normalize_workflow_plan, release_ready_nodes, NodeState, RunState,
};

const VALID: &str = r#"
config-version: 1
workflows:
  bugfix:
    schema-version: 1
    recipe-ref: bugfix-two-slot
    task-input:
      source: runtime-task-file
      privacy: digest-only
    nodes:
      - node-id: inspect
        pane-ref: implement
        action: operator-dispatch
        idempotency-key: "{{run-id}}:inspect"
        cleanup: retain
      - node-id: verify
        pane-ref: verify
        depends-on: [inspect]
        action: verification
        context-pack-ref: review-pack
        idempotency-key: "{{run-id}}:verify"
        cleanup: retain
    resume-policy:
      mode: operator-confirmed
      reject-completed-runs: true
    cleanup-policy:
      mode: compensating-actions
      on: [success, failure, cancel]
      actions: [release-run-lock]
"#;

fn bindings() -> BTreeMap<String, String> {
    BTreeMap::from([
        ("implement".to_string(), "worker-1".to_string()),
        ("verify".to_string(), "worker-2".to_string()),
    ])
}

#[test]
fn w01_normalizes_dag_and_digest_deterministically_without_task_body() {
    let first = normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings())
        .expect("normalize valid workflow");
    let second =
        normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings())
            .expect("normalize valid workflow again");

    assert_eq!(first, second);
    assert_eq!(first.nodes[0].node_id, "inspect");
    assert_eq!(first.nodes[1].node_id, "verify");
    assert_eq!(first.nodes[0].idempotency_key, "run-123:inspect");
    assert_eq!(first.task_input.source, "runtime-task-file");
    let json = serde_json::to_string(&first).expect("serialize normalized workflow");
    assert!(!json.contains("Task:"));
    assert!(!json.contains("prompt"));
}

#[test]
fn w02_rejects_cycle_self_edge_missing_dependency_duplicate_and_unknown_pane() {
    let cases = [
        (
            "cycle",
            VALID.replace("depends-on: [inspect]", "depends-on: [verify]"),
        ),
        (
            "self-edge",
            VALID.replace(
                "action: operator-dispatch",
                "depends-on: [inspect]\n        action: operator-dispatch",
            ),
        ),
        (
            "missing",
            VALID.replace("depends-on: [inspect]", "depends-on: [missing]"),
        ),
        (
            "duplicate",
            VALID.replace("node-id: verify", "node-id: inspect"),
        ),
        (
            "pane",
            VALID.replace("pane-ref: verify", "pane-ref: unknown"),
        ),
    ];

    for (name, yaml) in cases {
        let error =
            normalize_workflow_plan(&yaml, "bugfix", "run-123", "bugfix-two-slot", &bindings())
                .expect_err(name);
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData, "{name}");
    }
}

#[test]
fn w03_w04_dependency_release_is_explicit_and_only_after_success() {
    let plan = normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings())
        .expect("normalize workflow");
    let mut states = initial_node_states(&plan);
    assert_eq!(states["inspect"], NodeState::Ready);
    assert_eq!(states["verify"], NodeState::Pending);

    assert!(release_ready_nodes(&plan, &mut states).is_empty());
    states.insert("inspect".to_string(), NodeState::Succeeded);
    assert_eq!(
        release_ready_nodes(&plan, &mut states),
        BTreeSet::from(["verify".to_string()])
    );
    assert_eq!(states["verify"], NodeState::Ready);
}

#[test]
fn schema_is_closed_for_task_input_cleanup_action_and_node_payload() {
    let cases = [
        VALID.replace("source: runtime-task-file", "source: inline"),
        VALID.replace("privacy: digest-only", "privacy: persist-body"),
        VALID.replace("cleanup: retain", "cleanup: delete-worktree"),
        VALID.replace("actions: [release-run-lock]", "actions: [run-shell]"),
        VALID.replace(
            "cleanup: retain",
            "payload: secret\n        cleanup: retain",
        ),
    ];
    for yaml in cases {
        normalize_workflow_plan(&yaml, "bugfix", "run-123", "bugfix-two-slot", &bindings())
            .expect_err("closed workflow schema must reject unsupported values");
    }
}

#[test]
fn f04_verification_requires_at_least_one_dependency_before_execution() {
    for (name, yaml) in [
        (
            "omitted",
            VALID.replace("        depends-on: [inspect]\n", ""),
        ),
        (
            "empty",
            VALID.replace("depends-on: [inspect]", "depends-on: []"),
        ),
    ] {
        let error =
            normalize_workflow_plan(&yaml, "bugfix", "run-123", "bugfix-two-slot", &bindings())
                .expect_err(name);
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData, "{name}");
    }

    normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings())
        .expect("one existing dependency is executable");
}

#[test]
fn w12_terminal_runs_are_not_resumable() {
    for state in [
        RunState::Succeeded,
        RunState::Cancelled,
        RunState::RolledBack,
    ] {
        assert!(!state.allows_resume(), "{state:?}");
    }
    for state in [RunState::Blocked, RunState::Failed, RunState::Running] {
        assert!(state.allows_resume(), "{state:?}");
    }
}
