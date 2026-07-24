#[path = "../src/workflow.rs"]
mod workflow;
#[path = "../src/workspace_recipe.rs"]
mod workspace_recipe;

use std::collections::{BTreeMap, BTreeSet};

use workflow::{
    initial_node_states, normalize_workflow_plan, reduce_workflow_state_value, release_ready_nodes,
    workflow_application_capability_requirements_from_value, NodeState, RunState,
    WorkflowPlanCliOptions,
};
use workspace_recipe::{
    normalize_workspace_plan, normalize_workspace_plan_from_value_with_implied_capabilities,
    parse_workspace_yaml, SlotCapabilities,
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

fn worktree_modes_for(bindings: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    bindings
        .keys()
        .map(|pane_ref| (pane_ref.clone(), "managed".to_string()))
        .collect()
}

fn policy_slots() -> Vec<SlotCapabilities> {
    vec![
        SlotCapabilities {
            slot_id: "worker-1".to_string(),
            supports_file_edit: true,
            supports_verification: false,
            supports_structured_result: false,
        },
        SlotCapabilities {
            slot_id: "worker-2".to_string(),
            supports_file_edit: false,
            supports_verification: true,
            supports_structured_result: true,
        },
    ]
}

fn workflow_payload_from_plan(
    yaml: &str,
    plan: &workspace_recipe::NormalizedWorkspacePlan,
) -> std::io::Result<Option<serde_json::Value>> {
    let root = parse_workspace_yaml(yaml)?;
    let arguments = [
        "--workflow-id".to_string(),
        "bugfix".to_string(),
        "--run-id".to_string(),
        "run-123".to_string(),
    ];
    let argument_refs = arguments.iter().collect::<Vec<_>>();
    let mut options = WorkflowPlanCliOptions::default();
    let mut index = 0;
    while index < argument_refs.len() {
        index = options.parse_option(&argument_refs, index)?;
    }
    options.validate()?;
    options.normalized_payload(&root, plan)
}

fn workflow_with_application_policy() -> String {
    format!(
        "{VALID}\nworkspace-recipes:\n  bugfix-two-slot:\n    schema-version: 1\n    panes:\n      - pane-key: implement\n        workflow-role: implementer\n        slot-ref: worker-1\n        requires-capabilities: [file-edit]\n        region: main\n        worktree:\n          mode: managed\n          name-template: \"{{{{workflow-id}}}}-implement\"\n      - pane-key: verify\n        workflow-role: verifier\n        slot-ref: worker-2\n        requires-capabilities: [review]\n        region: side\n        worktree:\n          mode: read-only-reference\n    startup-actions:\n      - action-id: prepare-implement-worktree\n        kind: ensure-managed-worktree\n        pane-ref: implement\n      - action-id: start-implement-slot\n        kind: ensure-slot-ready\n        pane-ref: implement\n      - action-id: start-verify-slot\n        kind: ensure-slot-ready\n        pane-ref: verify\n"
    )
}

#[test]
fn z02_authorizes_workflow_actions_against_the_normalized_pane_worktree_policy() {
    let valid_yaml = workflow_with_application_policy();
    let plan = normalize_workspace_plan(
        &valid_yaml,
        "bugfix-two-slot",
        Some("bugfix"),
        &policy_slots(),
    )
    .expect("normalize workspace application policy");
    workflow_payload_from_plan(&valid_yaml, &plan)
        .expect("managed write and read-only verification are allowed")
        .expect("workflow payload");

    let read_only_write_yaml = valid_yaml.replacen("pane-ref: implement", "pane-ref: verify", 1);
    let read_only_write = workflow_payload_from_plan(&read_only_write_yaml, &plan);

    let mut missing_policy_plan = plan.clone();
    missing_policy_plan
        .panes
        .retain(|pane| pane.pane_key != "verify");
    let missing_policy = workflow_payload_from_plan(&valid_yaml, &missing_policy_plan);

    let mut unknown_policy_plan = plan.clone();
    unknown_policy_plan
        .panes
        .iter_mut()
        .find(|pane| pane.pane_key == "verify")
        .expect("verify pane")
        .worktree
        .mode = "unknown".to_string();
    let unknown_policy = workflow_payload_from_plan(&valid_yaml, &unknown_policy_plan);

    assert!(
        read_only_write.is_err(),
        "operator-dispatch must not target read-only-reference"
    );
    assert!(
        missing_policy.is_err(),
        "workflow policy keys must cover every resolved pane"
    );
    assert!(
        unknown_policy.is_err(),
        "unknown normalized worktree policies must be rejected"
    );
}

#[test]
fn aa01_workflow_actions_use_actual_slot_capabilities_and_serialize_their_application_contract() {
    let yaml_without_explicit_requirements = workflow_with_application_policy()
        .replace("        requires-capabilities: [file-edit]\n", "")
        .replace("        requires-capabilities: [review]\n", "");
    let selector_yaml = yaml_without_explicit_requirements.replace(
        "        slot-ref: worker-1\n",
        "        slot-selector:\n          requires-capabilities: [review]\n",
    );
    let selector_slots = vec![
        SlotCapabilities {
            slot_id: "worker-1".to_string(),
            supports_file_edit: false,
            supports_verification: true,
            supports_structured_result: true,
        },
        policy_slots()[1].clone(),
        SlotCapabilities {
            slot_id: "worker-3".to_string(),
            supports_file_edit: true,
            supports_verification: true,
            supports_structured_result: true,
        },
    ];
    normalize_workspace_plan(
        &selector_yaml,
        "bugfix-two-slot",
        Some("bugfix"),
        &selector_slots,
    )
    .expect_err("recipe-only preview leaves the review selector ambiguous");
    let selector_root = parse_workspace_yaml(&selector_yaml).expect("selector workspace yaml");
    let implied_capabilities = workflow_application_capability_requirements_from_value(
        &selector_root,
        "bugfix",
        "bugfix-two-slot",
    )
    .expect("workflow actions compile to pane capability requirements");
    let selected = normalize_workspace_plan_from_value_with_implied_capabilities(
        &selector_root,
        "bugfix-two-slot",
        Some("bugfix"),
        &selector_slots,
        &implied_capabilities,
    )
    .expect("workflow-implied file-edit capability disambiguates before slot selection");
    assert_eq!(selected.resolved_bindings["implement"], "worker-3");
    assert_eq!(
        selected.panes[0].required_capabilities,
        vec!["review".to_string(), "file-edit".to_string()]
    );

    let capable_plan = normalize_workspace_plan(
        &yaml_without_explicit_requirements,
        "bugfix-two-slot",
        Some("bugfix"),
        &policy_slots(),
    )
    .expect("omitted recipe requirements must not erase actual slot capabilities");
    let payload = workflow_payload_from_plan(&yaml_without_explicit_requirements, &capable_plan)
        .expect("actual capabilities authorize the matching workflow actions")
        .expect("workflow-selected plan");

    assert_eq!(
        payload["panes"][0]["actual_capabilities"]["supports_file_edit"],
        true
    );
    assert_eq!(
        payload["panes"][1]["actual_capabilities"]["supports_verification"],
        true
    );
    assert_eq!(
        payload["panes"][1]["actual_capabilities"]["supports_structured_result"],
        true
    );
    assert_eq!(
        payload["workflow"]["application_contract"]["implement"]["slot_id"],
        "worker-1"
    );
    assert_eq!(
        payload["workflow"]["application_contract"]["implement"]["worktree"]["mode"],
        "managed"
    );
    assert_eq!(
        payload["workflow"]["application_contract"]["verify"]["slot_id"],
        "worker-2"
    );
    assert_eq!(
        payload["workflow"]["application_contract"]["verify"]["actual_capabilities"]
            ["supports_structured_result"],
        true
    );
    assert_eq!(
        payload["workflow"]["nodes"][0]["required_capability"],
        "file-edit"
    );
    assert_eq!(
        payload["workflow"]["nodes"][0]["allowed_worktree_modes"],
        serde_json::json!(["managed"])
    );
    assert_eq!(payload["workflow"]["nodes"][0]["may_advance_head"], true);
    assert_eq!(
        payload["workflow"]["nodes"][1]["required_capability"],
        "review"
    );
    assert_eq!(
        payload["workflow"]["nodes"][1]["allowed_worktree_modes"],
        serde_json::json!(["managed", "read-only-reference"])
    );
    assert_eq!(payload["workflow"]["nodes"][1]["may_advance_head"], false);

    let mut no_file_edit = policy_slots();
    no_file_edit[0].supports_file_edit = false;
    let no_file_edit_plan = normalize_workspace_plan(
        &yaml_without_explicit_requirements,
        "bugfix-two-slot",
        Some("bugfix"),
        &no_file_edit,
    )
    .expect("recipe-only normalization remains a pure preview");
    workflow_payload_from_plan(&yaml_without_explicit_requirements, &no_file_edit_plan).expect_err(
        "operator-dispatch must require the resolved slot's actual file-edit capability",
    );

    for (name, mutate) in [
        ("verification", (false, true)),
        ("structured-result", (true, false)),
    ] {
        let mut incomplete = policy_slots();
        incomplete[1].supports_verification = mutate.0;
        incomplete[1].supports_structured_result = mutate.1;
        let plan = normalize_workspace_plan(
            &yaml_without_explicit_requirements,
            "bugfix-two-slot",
            Some("bugfix"),
            &incomplete,
        )
        .expect("recipe-only normalization remains a pure preview");
        assert!(
            workflow_payload_from_plan(&yaml_without_explicit_requirements, &plan).is_err(),
            "verification must require actual {name} capability"
        );
    }
}

#[test]
fn w01_normalizes_dag_and_digest_deterministically_without_task_body() {
    let first = normalize_workflow_plan(
        VALID,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
    .expect("normalize valid workflow");
    let second = normalize_workflow_plan(
        VALID,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
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
fn s01_rejects_normalized_idempotency_keys_over_192_ascii_bytes() {
    let node_id = "n".repeat(12);
    let yaml = VALID.replace("inspect", &node_id);
    let accepted_run_id = "r".repeat(179);
    let rejected_run_id = "r".repeat(180);

    let accepted = normalize_workflow_plan(
        &yaml,
        "bugfix",
        &accepted_run_id,
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
    .expect("192-byte run_id:node_id must normalize");
    assert_eq!(accepted.nodes[0].idempotency_key.as_bytes().len(), 192);

    let error = normalize_workflow_plan(
        &yaml,
        "bugfix",
        &rejected_run_id,
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
    .expect_err("193-byte run_id:node_id must be rejected");
    assert!(error.to_string().contains("idempotency"));
}

#[test]
fn t01_rejects_expanded_state_over_one_mib_from_a_smaller_request() {
    let mut yaml = String::from(
        "config-version: 1\nworkflows:\n  bugfix:\n    schema-version: 1\n    recipe-ref: bugfix-two-slot\n    task-input:\n      source: runtime-task-file\n      privacy: digest-only\n    nodes:\n",
    );
    for index in 0..4_000 {
        yaml.push_str(&format!(
            "      - node-id: node-{index:04}\n        pane-ref: implement\n        action: operator-dispatch\n        idempotency-key: \"{{{{run-id}}}}:node-{index:04}\"\n        cleanup: retain\n"
        ));
    }
    yaml.push_str(
        "    resume-policy:\n      mode: operator-confirmed\n      reject-completed-runs: true\n    cleanup-policy:\n      mode: compensating-actions\n      on: [success, failure, cancel]\n      actions: [release-run-lock]\n",
    );
    let plan = normalize_workflow_plan(
        &yaml,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
    .expect("normalize large workflow below the request limit");
    let request = serde_json::json!({
        "schema_version": 1,
        "operation": "bootstrap",
        "plan": plan,
        "identity": {
            "run_id": "run-123",
            "generation_id": "generation-123",
            "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
            "source_head": "b".repeat(40),
            "task_sha256": format!("sha256:{}", "c".repeat(64)),
            "task_byte_count": 24
        }
    });

    let request_bytes = serde_json::to_vec(&request).expect("serialize reducer request");
    assert!(
        request_bytes.len() < 1_048_576,
        "fixture must remain below the reducer input limit"
    );
    let error = reduce_workflow_state_value(&request)
        .expect_err("expanded state over one MiB must be rejected before output");
    assert!(
        error.to_string().contains("exceeds 1048576 UTF-8 bytes"),
        "unexpected reducer error: {error}"
    );
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
        let error = normalize_workflow_plan(
            &yaml,
            "bugfix",
            "run-123",
            "bugfix-two-slot",
            &bindings(),
            &worktree_modes_for(&bindings()),
        )
        .expect_err(name);
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData, "{name}");
    }
}

#[test]
fn w03_w04_dependency_release_is_explicit_and_only_after_success() {
    let plan = normalize_workflow_plan(
        VALID,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
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
        VALID.replace("action: verification", "action: arbitrary-shell"),
        VALID.replace(
            "cleanup: retain",
            "payload: secret\n        cleanup: retain",
        ),
    ];
    for yaml in cases {
        normalize_workflow_plan(
            &yaml,
            "bugfix",
            "run-123",
            "bugfix-two-slot",
            &bindings(),
            &worktree_modes_for(&bindings()),
        )
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
        let error = normalize_workflow_plan(
            &yaml,
            "bugfix",
            "run-123",
            "bugfix-two-slot",
            &bindings(),
            &worktree_modes_for(&bindings()),
        )
        .expect_err(name);
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData, "{name}");
    }

    normalize_workflow_plan(
        VALID,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
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

fn reducer_bootstrap_request() -> serde_json::Value {
    let plan = normalize_workflow_plan(
        VALID,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
    .expect("normalize workflow");
    serde_json::json!({
        "schema_version": 1,
        "operation": "bootstrap",
        "plan": plan,
        "identity": {
            "run_id": "run-123",
            "generation_id": "generation-123",
            "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
            "source_head": "b".repeat(40),
            "task_sha256": format!("sha256:{}", "c".repeat(64)),
            "task_byte_count": 24
        }
    })
}

fn aa_reducer_bootstrap_request() -> serde_json::Value {
    let mut request = reducer_bootstrap_request();
    let yaml = workflow_with_application_policy();
    let workspace =
        normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("bugfix"), &policy_slots())
            .expect("normalize combined workspace plan");
    let payload = workflow_payload_from_plan(&yaml, &workspace)
        .expect("normalize combined workflow payload")
        .expect("workflow-selected payload");
    request["plan"] = payload["workflow"].clone();
    request
}

fn aa_sequential_writer_bootstrap_request() -> serde_json::Value {
    let yaml = VALID.replace(
        "      - node-id: verify\n        pane-ref: verify\n        depends-on: [inspect]\n        action: verification\n        context-pack-ref: review-pack\n        idempotency-key: \"{{run-id}}:verify\"\n        cleanup: retain\n",
        "      - node-id: refine\n        pane-ref: implement\n        depends-on: [inspect]\n        action: operator-dispatch\n        idempotency-key: \"{{run-id}}:refine\"\n        cleanup: retain\n      - node-id: verify\n        pane-ref: verify\n        depends-on: [inspect, refine]\n        action: verification\n        context-pack-ref: review-pack\n        idempotency-key: \"{{run-id}}:verify\"\n        cleanup: retain\n",
    );
    let plan = normalize_workflow_plan(
        &yaml,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &bindings(),
        &worktree_modes_for(&bindings()),
    )
    .expect("normalize sequential writer workflow");
    serde_json::json!({
        "schema_version": 1,
        "operation": "bootstrap",
        "plan": plan,
        "identity": {
            "run_id": "run-123",
            "generation_id": "generation-123",
            "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
            "source_head": "b".repeat(40),
            "task_sha256": format!("sha256:{}", "c".repeat(64)),
            "task_byte_count": 24
        }
    })
}

fn reducer_transition(
    run: serde_json::Value,
    event: serde_json::Value,
) -> std::io::Result<serde_json::Value> {
    let durable_proofs = durable_proofs_for_run(&run);
    reducer_transition_with_proofs(run, event, durable_proofs)
}

fn reducer_transition_with_proofs(
    run: serde_json::Value,
    event: serde_json::Value,
    durable_proofs: serde_json::Value,
) -> std::io::Result<serde_json::Value> {
    reduce_workflow_state_value(&serde_json::json!({
        "schema_version": 1,
        "operation": "transition",
        "run": run,
        "event": event,
        "durable_proofs": durable_proofs
    }))
}

fn durable_proofs_for_run(run: &serde_json::Value) -> serde_json::Value {
    let completion_acknowledgements = run["nodes"]
        .as_object()
        .into_iter()
        .flat_map(|nodes| nodes.values())
        .filter_map(|node| {
            (node["state"] == "succeeded")
                .then(|| node.get("completion_proof").cloned())
                .flatten()
        })
        .collect::<Vec<_>>();
    let cancellation_proofs = run
        .get("cancellation_proof")
        .filter(|proof| !proof.is_null())
        .cloned()
        .into_iter()
        .collect::<Vec<_>>();
    serde_json::json!({
        "completion_acknowledgements": completion_acknowledgements,
        "cancellation_proofs": cancellation_proofs
    })
}

fn no_durable_proofs() -> serde_json::Value {
    serde_json::json!({
        "completion_acknowledgements": [],
        "cancellation_proofs": []
    })
}

fn exact_ack(node_id: &str, pane_id: &str) -> serde_json::Value {
    let resolved_bindings = bindings();
    let pane_worktree_modes = worktree_modes_for(&resolved_bindings);
    serde_json::json!({
        "schema_version": 2,
        "run_id": "run-123",
        "node_id": node_id,
        "idempotency_key": format!("run-123:{node_id}"),
        "generation_id": "generation-123",
        "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
        "workflow_fingerprint": normalize_workflow_plan(
            VALID,
            "bugfix",
            "run-123",
            "bugfix-two-slot",
            &resolved_bindings,
            &pane_worktree_modes
        ).unwrap().workflow_fingerprint,
        "source_head": "b".repeat(40),
        "input_head": "b".repeat(40),
        "output_head": "b".repeat(40),
        "pane_id": pane_id,
        "status": "succeeded",
        "evidence_ref": format!("workflow-ack:run-123:{node_id}")
    })
}

fn aa_exact_completion_proof(
    run: &serde_json::Value,
    node_id: &str,
    pane_id: &str,
    input_head: &str,
    output_head: &str,
) -> serde_json::Value {
    serde_json::json!({
        "schema_version": 2,
        "run_id": run["run_id"],
        "node_id": node_id,
        "idempotency_key": run["nodes"][node_id]["idempotency_key"],
        "generation_id": run["generation_id"],
        "config_fingerprint": run["config_fingerprint"],
        "workflow_fingerprint": run["workflow_fingerprint"],
        "source_head": run["source_head"],
        "input_head": input_head,
        "output_head": output_head,
        "pane_id": pane_id,
        "status": "succeeded",
        "evidence_ref": format!(
            "workflow-ack:{}:{node_id}",
            run["run_id"].as_str().expect("run id")
        )
    })
}

fn exact_cancellation() -> serde_json::Value {
    let resolved_bindings = bindings();
    let pane_worktree_modes = worktree_modes_for(&resolved_bindings);
    serde_json::json!({
        "schema_version": 1,
        "run_id": "run-123",
        "idempotency_key": "run-123:cancel",
        "generation_id": "generation-123",
        "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
        "workflow_fingerprint": normalize_workflow_plan(
            VALID,
            "bugfix",
            "run-123",
            "bugfix-two-slot",
            &resolved_bindings,
            &pane_worktree_modes
        ).unwrap().workflow_fingerprint,
        "source_head": "b".repeat(40),
        "status": "cancelled",
        "evidence_ref": "workflow-cancel:run-123"
    })
}

#[test]
fn h01_verification_requires_one_resolved_producer_label() {
    let mut aliases = bindings();
    aliases.insert("implement-alias".to_string(), "worker-1".to_string());
    let same_label = VALID
        .replace("pane-ref: verify", "pane-ref: implement-alias")
        .replace("depends-on: [inspect]", "depends-on: [inspect, inspect-two]")
        .replace(
            "      - node-id: verify",
            "      - node-id: inspect-two\n        pane-ref: implement\n        action: operator-dispatch\n        idempotency-key: \"{{run-id}}:inspect-two\"\n        cleanup: retain\n      - node-id: verify",
        );
    normalize_workflow_plan(
        &same_label,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &aliases,
        &worktree_modes_for(&aliases),
    )
    .expect("aliases resolving to one producer label are executable");

    let distinct_labels = same_label.replace(
        "node-id: inspect-two\n        pane-ref: implement",
        "node-id: inspect-two\n        pane-ref: verify",
    );
    normalize_workflow_plan(
        &distinct_labels,
        "bugfix",
        "run-123",
        "bugfix-two-slot",
        &aliases,
        &worktree_modes_for(&aliases),
    )
    .expect_err("verification producers resolving to distinct labels must reject");
}

#[test]
fn h02_h12_reducer_owns_bootstrap_transitions_proofs_release_and_run_state() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).expect("bootstrap v3 run");
    assert_eq!(run["schema_version"], 3);
    assert_eq!(run["state"], "ready");
    assert_eq!(run["nodes"]["inspect"]["state"], "ready");
    assert_eq!(run["nodes"]["verify"]["state"], "pending");

    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .expect("persist dispatch intent");
    assert_eq!(dispatching["nodes"]["inspect"]["state"], "dispatching");
    assert_eq!(dispatching["nodes"]["inspect"]["attempt"], 1);
    assert_eq!(dispatching["state"], "running");

    let acknowledgement = exact_ack("inspect", "%2");
    let acknowledge_event = serde_json::json!({
        "type":"acknowledge",
        "node_id":"inspect",
        "acknowledgement": acknowledgement.clone(),
        "resolved_session_id":"%2"
    });
    let before_rejected_event = dispatching.clone();
    reducer_transition_with_proofs(
        dispatching.clone(),
        acknowledge_event.clone(),
        no_durable_proofs(),
    )
    .expect_err("AC01 acknowledgement event cannot create its own durable proof authority");
    assert_eq!(dispatching, before_rejected_event);

    let mut mismatched_event_proof = acknowledgement.clone();
    mismatched_event_proof["transport"] = serde_json::json!("mailbox");
    mismatched_event_proof["message_id"] = serde_json::json!("workflow-ack-ac01-event");
    let mut mismatched_external_proof = acknowledgement.clone();
    mismatched_external_proof["transport"] = serde_json::json!("mailbox");
    mismatched_external_proof["message_id"] = serde_json::json!("workflow-ack-ac01-proof");
    reducer_transition_with_proofs(
        dispatching.clone(),
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement": mismatched_event_proof,
            "resolved_session_id":"%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [mismatched_external_proof],
            "cancellation_proofs": []
        }),
    )
    .expect_err("AC01 event proof must equal the one external canonical proof");

    let succeeded = reducer_transition_with_proofs(
        dispatching,
        acknowledge_event,
        serde_json::json!({
            "completion_acknowledgements": [acknowledgement],
            "cancellation_proofs": []
        }),
    )
    .expect("exact acknowledgement succeeds only with its pre-existing durable proof");
    assert_eq!(succeeded["nodes"]["inspect"]["state"], "succeeded");
    assert_eq!(succeeded["nodes"]["verify"]["state"], "ready");
    assert_eq!(
        succeeded["nodes"]["inspect"]["evidence_refs"],
        serde_json::json!(["workflow-ack:run-123:inspect"])
    );
    assert!(succeeded["nodes"]["inspect"]["completion_proof"].is_object());

    let replay = reducer_transition(
        succeeded.clone(),
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement": exact_ack("inspect", "%2"),
            "resolved_session_id":"%2"
        }),
    )
    .expect("identical replay is idempotent");
    assert_eq!(replay, succeeded);
}

#[test]
fn aa02_ab03_run_v3_persists_input_and_empty_dependency_lease_before_first_send() {
    let base_head = "b".repeat(40);
    let implementation_head = "c".repeat(40);
    let run = reduce_workflow_state_value(&aa_reducer_bootstrap_request())
        .expect("combined application contract bootstraps run schema v3");
    assert_eq!(run["schema_version"], 3);
    assert_eq!(run["pane_head_leases"]["implement"]["base_head"], base_head);
    assert_eq!(
        run["pane_head_leases"]["implement"]["admitted_head"],
        base_head
    );
    assert!(run["pane_head_leases"].get("verify").is_none());

    let dispatching = reducer_transition(
        run,
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "inspect",
            "input_head": base_head
        }),
    )
    .expect("managed dispatch persists its exact input HEAD before send");
    assert_eq!(
        dispatching["nodes"]["inspect"]["execution_lease"]["input_head"],
        "b".repeat(40)
    );
    assert_eq!(
        dispatching["nodes"]["inspect"]["execution_lease"]["worktree_mode"],
        "managed"
    );
    assert_eq!(
        dispatching["nodes"]["inspect"]["execution_lease"]["dependency_inputs"],
        serde_json::json!([])
    );
    assert_eq!(
        dispatching["nodes"]["inspect"]["execution_lease"]["dependency_heads"],
        serde_json::json!({})
    );

    let completion = aa_exact_completion_proof(
        &dispatching,
        "inspect",
        "%2",
        &"b".repeat(40),
        &implementation_head,
    );
    let succeeded = reducer_transition_with_proofs(
        dispatching,
        serde_json::json!({
            "type": "acknowledge",
            "node_id": "inspect",
            "acknowledgement": completion.clone(),
            "resolved_session_id": "%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [completion],
            "cancellation_proofs": []
        }),
    )
    .expect("operator-observed descendant output atomically advances the pane ledger");
    assert_eq!(
        succeeded["nodes"]["inspect"]["application_outcome"]["input_head"],
        "b".repeat(40)
    );
    assert_eq!(
        succeeded["nodes"]["inspect"]["application_outcome"]["output_head"],
        implementation_head
    );
    assert_eq!(
        succeeded["pane_head_leases"]["implement"]["admitted_head"],
        "c".repeat(40)
    );
    assert_eq!(succeeded["nodes"]["verify"]["state"], "ready");

    let verification_dispatching = reducer_transition(
        succeeded,
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [{
                "node_id": "inspect",
                "pane_ref": "implement",
                "output_head": "c".repeat(40),
                "evidence_ref": "workflow-ack:run-123:inspect"
            }],
            "dependency_heads": {"implement": "c".repeat(40)}
        }),
    )
    .expect("read-only verification binds the immutable project source HEAD");
    let changed_verification = aa_exact_completion_proof(
        &verification_dispatching,
        "verify",
        "%3",
        &"b".repeat(40),
        &"d".repeat(40),
    );
    reducer_transition_with_proofs(
        verification_dispatching,
        serde_json::json!({
            "type": "acknowledge",
            "node_id": "verify",
            "acknowledgement": changed_verification.clone(),
            "resolved_session_id": "%3"
        }),
        serde_json::json!({
            "completion_acknowledgements": [changed_verification],
            "cancellation_proofs": []
        }),
    )
    .expect_err("verification may not publish a HEAD-changing outcome");
}

#[test]
fn ab06_reducer_rejects_noncanonical_dependency_lease_without_partial_state() {
    let base_head = "b".repeat(40);
    let output_head = "c".repeat(40);
    let run = reduce_workflow_state_value(&aa_reducer_bootstrap_request()).unwrap();
    let dispatching = reducer_transition(
        run,
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "inspect",
            "input_head": base_head
        }),
    )
    .unwrap();
    let completion =
        aa_exact_completion_proof(&dispatching, "inspect", "%2", &"b".repeat(40), &output_head);
    let succeeded = reducer_transition_with_proofs(
        dispatching,
        serde_json::json!({
            "type": "acknowledge",
            "node_id": "inspect",
            "acknowledgement": completion.clone(),
            "resolved_session_id": "%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [completion],
            "cancellation_proofs": []
        }),
    )
    .unwrap();
    let canonical_input = serde_json::json!({
        "node_id": "inspect",
        "pane_ref": "implement",
        "output_head": "c".repeat(40),
        "evidence_ref": "workflow-ack:run-123:inspect"
    });
    let invalid_events = [
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40)
        }),
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [canonical_input.clone(), canonical_input.clone()],
            "dependency_heads": {"implement": "c".repeat(40)}
        }),
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [{
                "node_id": "inspect",
                "pane_ref": "implement",
                "output_head": "c".repeat(40),
                "evidence_ref": "workflow-ack:run-123:other"
            }],
            "dependency_heads": {"implement": "c".repeat(40)}
        }),
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [canonical_input.clone(), {
                "node_id": "unrelated",
                "pane_ref": "implement",
                "output_head": "c".repeat(40),
                "evidence_ref": "workflow-ack:run-123:unrelated"
            }],
            "dependency_heads": {"implement": "c".repeat(40)}
        }),
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [canonical_input],
            "dependency_heads": {"implement": "d".repeat(40)}
        }),
    ];
    for event in invalid_events {
        reducer_transition(succeeded.clone(), event)
            .expect_err("noncanonical dependency lease must reject before persistence");
    }
    assert_eq!(succeeded["nodes"]["verify"]["state"], "ready");
    assert!(succeeded["nodes"]["verify"]["execution_lease"].is_null());
}

#[test]
fn aa02_sequential_writers_chain_one_pane_without_advancing_an_independent_pane() {
    let base_head = "b".repeat(40);
    let first_output = "c".repeat(40);
    let second_output = "d".repeat(40);
    let run = reduce_workflow_state_value(&aa_sequential_writer_bootstrap_request())
        .expect("bootstrap two independent managed pane ledgers");
    assert_eq!(
        run["pane_head_leases"]["implement"]["admitted_head"],
        base_head
    );
    assert_eq!(
        run["pane_head_leases"]["verify"]["admitted_head"],
        base_head
    );

    let first_dispatch = reducer_transition(
        run,
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "inspect",
            "input_head": base_head
        }),
    )
    .expect("first writer leases the pane base");
    let first_proof = aa_exact_completion_proof(
        &first_dispatch,
        "inspect",
        "%2",
        &"b".repeat(40),
        &first_output,
    );
    let first_succeeded = reducer_transition_with_proofs(
        first_dispatch,
        serde_json::json!({
            "type": "acknowledge",
            "node_id": "inspect",
            "acknowledgement": first_proof.clone(),
            "resolved_session_id": "%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [first_proof],
            "cancellation_proofs": []
        }),
    )
    .expect("first writer advances only its pane");
    assert_eq!(
        first_succeeded["pane_head_leases"]["implement"]["admitted_head"],
        first_output
    );
    assert_eq!(
        first_succeeded["pane_head_leases"]["verify"]["admitted_head"],
        "b".repeat(40)
    );
    assert_eq!(first_succeeded["nodes"]["refine"]["state"], "ready");

    reducer_transition(
        first_succeeded.clone(),
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "refine",
            "input_head": "b".repeat(40),
            "dependency_inputs": [{
                "node_id": "inspect",
                "pane_ref": "implement",
                "output_head": "c".repeat(40),
                "evidence_ref": "workflow-ack:run-123:inspect"
            }],
            "dependency_heads": {"implement": "c".repeat(40)}
        }),
    )
    .expect_err("a later same-pane writer cannot rebind to the run base");
    let second_dispatch = reducer_transition(
        first_succeeded,
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "refine",
            "input_head": "c".repeat(40),
            "dependency_inputs": [{
                "node_id": "inspect",
                "pane_ref": "implement",
                "output_head": "c".repeat(40),
                "evidence_ref": "workflow-ack:run-123:inspect"
            }],
            "dependency_heads": {"implement": "c".repeat(40)}
        }),
    )
    .expect("later same-pane writer leases the prior admitted output");
    let second_proof = aa_exact_completion_proof(
        &second_dispatch,
        "refine",
        "%2",
        &"c".repeat(40),
        &second_output,
    );
    let second_succeeded = reducer_transition_with_proofs(
        second_dispatch,
        serde_json::json!({
            "type": "acknowledge",
            "node_id": "refine",
            "acknowledgement": second_proof.clone(),
            "resolved_session_id": "%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [second_proof],
            "cancellation_proofs": []
        }),
    )
    .expect("second writer advances the same pane monotonically");
    assert_eq!(
        second_succeeded["pane_head_leases"]["implement"]["admitted_head"],
        second_output
    );
    assert_eq!(
        second_succeeded["pane_head_leases"]["verify"]["admitted_head"],
        "b".repeat(40)
    );
    assert_eq!(second_succeeded["nodes"]["verify"]["state"], "ready");

    reducer_transition(
        second_succeeded.clone(),
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [
                {
                    "node_id": "refine",
                    "pane_ref": "implement",
                    "output_head": "d".repeat(40),
                    "evidence_ref": "workflow-ack:run-123:refine"
                },
                {
                    "node_id": "inspect",
                    "pane_ref": "implement",
                    "output_head": "c".repeat(40),
                    "evidence_ref": "workflow-ack:run-123:inspect"
                }
            ],
            "dependency_heads": {"implement": "d".repeat(40)}
        }),
    )
    .expect_err("direct dependency inputs must remain in normalized depends-on order");
    let verification_dispatch = reducer_transition(
        second_succeeded,
        serde_json::json!({
            "type": "dispatch_intent",
            "node_id": "verify",
            "input_head": "b".repeat(40),
            "dependency_inputs": [
                {
                    "node_id": "inspect",
                    "pane_ref": "implement",
                    "output_head": "c".repeat(40),
                    "evidence_ref": "workflow-ack:run-123:inspect"
                },
                {
                    "node_id": "refine",
                    "pane_ref": "implement",
                    "output_head": "d".repeat(40),
                    "evidence_ref": "workflow-ack:run-123:refine"
                }
            ],
            "dependency_heads": {"implement": "d".repeat(40)}
        }),
    )
    .expect("independent managed verifier keeps its own base ledger");
    let verification_proof = aa_exact_completion_proof(
        &verification_dispatch,
        "verify",
        "%3",
        &"b".repeat(40),
        &"b".repeat(40),
    );
    let completed = reducer_transition_with_proofs(
        verification_dispatch,
        serde_json::json!({
            "type": "acknowledge",
            "node_id": "verify",
            "acknowledgement": verification_proof.clone(),
            "resolved_session_id": "%3"
        }),
        serde_json::json!({
            "completion_acknowledgements": [verification_proof],
            "cancellation_proofs": []
        }),
    )
    .expect("managed verification records an unchanged outcome");
    assert_eq!(completed["state"], "succeeded");
    assert_eq!(
        completed["pane_head_leases"]["verify"]["admitted_head"],
        "b".repeat(40)
    );
}

#[test]
fn h03_state_snapshot_is_untrusted_and_legacy_or_forged_proof_never_releases_dependencies() {
    for schema_version in [1, 2] {
        let mut legacy = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
        legacy["schema_version"] = serde_json::json!(schema_version);
        let error = reducer_transition(legacy, serde_json::json!({"type":"validate"}))
            .expect_err("legacy run schema requires migration");
        assert!(error
            .to_string()
            .contains("workflow_state_migration_required"));
    }

    let mut forged = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    forged["state"] = serde_json::json!("succeeded");
    forged["nodes"]["inspect"]["state"] = serde_json::json!("succeeded");
    forged["nodes"]["inspect"]["attempt"] = serde_json::json!(1);
    forged["nodes"]["inspect"]["agent_cli_session_id"] = serde_json::json!("%2");
    forged["nodes"]["inspect"]["evidence_refs"] =
        serde_json::json!(["workflow-ack:run-123:inspect"]);
    let error = reducer_transition(forged, serde_json::json!({"type":"validate"}))
        .expect_err("a succeeded string without a distinct exact proof is untrusted");
    assert!(error.to_string().contains("workflow_state_invalid"));
}

#[test]
fn h04_reducer_rejects_tuple_and_ack_identity_mutations_and_terminal_regression() {
    let base = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    for (name, state, attempt, session, evidence) in [
        ("ready-attempt", "ready", 1, "", Vec::<String>::new()),
        ("pending-session", "pending", 0, "%2", Vec::new()),
        (
            "dispatching-evidence",
            "dispatching",
            1,
            "",
            vec!["workflow-ack:run-123:inspect".to_string()],
        ),
        ("blocked-attempt", "blocked", 0, "", Vec::new()),
    ] {
        let mut candidate = base.clone();
        candidate["nodes"]["inspect"]["state"] = serde_json::json!(state);
        candidate["nodes"]["inspect"]["attempt"] = serde_json::json!(attempt);
        candidate["nodes"]["inspect"]["agent_cli_session_id"] = serde_json::json!(session);
        candidate["nodes"]["inspect"]["evidence_refs"] = serde_json::json!(evidence);
        reducer_transition(candidate, serde_json::json!({"type":"validate"})).expect_err(name);
    }

    let dispatching = reducer_transition(
        base,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .unwrap();
    for field in [
        "run_id",
        "node_id",
        "idempotency_key",
        "generation_id",
        "config_fingerprint",
        "workflow_fingerprint",
        "source_head",
        "pane_id",
        "status",
        "evidence_ref",
    ] {
        let mut ack = exact_ack("inspect", "%2");
        ack[field] = serde_json::json!("mutated");
        reducer_transition_with_proofs(
            dispatching.clone(),
            serde_json::json!({
                "type":"acknowledge", "node_id":"inspect", "acknowledgement":ack.clone(), "resolved_session_id":"%2"
            }),
            serde_json::json!({
                "completion_acknowledgements": [ack],
                "cancellation_proofs": []
            }),
        )
        .expect_err(field);
    }

    let failed = reducer_transition(
        dispatching,
        serde_json::json!({"type":"dispatch_failed","node_id":"inspect"}),
    )
    .unwrap();
    reducer_transition(
        failed,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .expect_err("terminal failed node must not regress");
}

#[test]
fn h05_no_or_ambiguous_ack_blocks_without_retry_and_unknown_or_private_request_fields_reject() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .unwrap();
    let blocked = reducer_transition(
        dispatching.clone(),
        serde_json::json!({"type":"block","node_id":"inspect"}),
    )
    .unwrap();
    assert_eq!(blocked["nodes"]["inspect"]["state"], "blocked");
    assert_eq!(blocked["nodes"]["inspect"]["attempt"], 1);
    reducer_transition(
        blocked,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .expect_err("blocked work is never redispatched");

    let mut private = serde_json::json!({
        "schema_version":1,
        "operation":"transition",
        "run": dispatching,
        "event":{"type":"block","node_id":"inspect"},
        "prompt":"secret"
    });
    reduce_workflow_state_value(&private).expect_err("unknown private request fields reject");
    private.as_object_mut().unwrap().remove("prompt");
    private["event"]["transcript"] = serde_json::json!("secret");
    reduce_workflow_state_value(&private).expect_err("unknown private event fields reject");
}

#[test]
fn h06_late_exact_ack_is_the_only_allowed_blocked_node_transition() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .unwrap();
    let blocked = reducer_transition(
        dispatching,
        serde_json::json!({"type":"block","node_id":"inspect"}),
    )
    .unwrap();
    let acknowledgement = exact_ack("inspect", "%2");
    let succeeded = reducer_transition_with_proofs(
        blocked,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement":acknowledgement.clone(),
            "resolved_session_id":"%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [acknowledgement],
            "cancellation_proofs": []
        }),
    )
    .expect("a late exact durable acknowledgement proves the blocked node");
    assert_eq!(succeeded["nodes"]["inspect"]["state"], "succeeded");
    assert_eq!(succeeded["nodes"]["verify"]["state"], "ready");
}

#[test]
fn h07_cleanup_is_a_typed_single_action_transition_owned_by_the_reducer() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .unwrap();
    let inspect_acknowledgement = exact_ack("inspect", "%2");
    let inspect_done = reducer_transition_with_proofs(
        dispatching,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement":inspect_acknowledgement.clone(),
            "resolved_session_id":"%2"
        }),
        serde_json::json!({
            "completion_acknowledgements": [inspect_acknowledgement],
            "cancellation_proofs": []
        }),
    )
    .unwrap();
    let verify_dispatching = reducer_transition(
        inspect_done,
        serde_json::json!({
            "type":"dispatch_intent",
            "node_id":"verify",
            "input_head":"b".repeat(40),
            "dependency_inputs":[{
                "node_id":"inspect",
                "pane_ref":"implement",
                "output_head":"b".repeat(40),
                "evidence_ref":"workflow-ack:run-123:inspect"
            }],
            "dependency_heads":{"implement":"b".repeat(40)}
        }),
    )
    .unwrap();
    let verify_acknowledgement = exact_ack("verify", "%3");
    let completed = reducer_transition_with_proofs(
        verify_dispatching,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"verify",
            "acknowledgement":verify_acknowledgement.clone(),
            "resolved_session_id":"%3"
        }),
        serde_json::json!({
            "completion_acknowledgements": [
                exact_ack("inspect", "%2"),
                verify_acknowledgement
            ],
            "cancellation_proofs": []
        }),
    )
    .unwrap();
    assert_eq!(completed["state"], "succeeded");

    let cleaning = reducer_transition(completed, serde_json::json!({"type":"cleanup_intent"}))
        .expect("successful run enters cleanup without a preserve override");
    assert_eq!(cleaning["state"], "cleanup_pending");
    assert_eq!(cleaning["cleanup_journal"][0]["state"], "running");
    let cleaned = reducer_transition(cleaning, serde_json::json!({"type":"cleanup_succeeded"}))
        .expect("running cleanup completes once");
    assert_eq!(cleaned["state"], "succeeded");
    assert_eq!(cleaned["cleanup_journal"][0]["state"], "succeeded");
    reducer_transition(cleaned, serde_json::json!({"type":"cleanup_succeeded"}))
        .expect_err("terminal cleanup cannot regress or repeat");
}

#[test]
fn h08_failed_run_cleanup_preserves_only_its_proof_derived_terminal_state() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect","input_head":"b".repeat(40)}),
    )
    .unwrap();
    let failed = reducer_transition(
        dispatching,
        serde_json::json!({"type":"dispatch_failed","node_id":"inspect"}),
    )
    .unwrap();
    assert_eq!(failed["state"], "failed");
    reducer_transition(
        failed.clone(),
        serde_json::json!({"type":"cleanup_intent","preserve_run_state":"succeeded"}),
    )
    .expect_err("caller cannot choose a terminal state unsupported by node proofs");
    let cleaning = reducer_transition(
        failed,
        serde_json::json!({"type":"cleanup_intent","preserve_run_state":"failed"}),
    )
    .expect("failed run cleanup preserves its derived terminal state");
    assert_eq!(cleaning["state"], "failed");
    let blocked =
        reducer_transition(cleaning, serde_json::json!({"type":"cleanup_blocked"})).unwrap();
    assert_eq!(blocked["state"], "failed");
    assert_eq!(blocked["cleanup_journal"][0]["state"], "blocked");
}

#[test]
fn h09_embedded_completion_proof_never_substitutes_for_external_durable_evidence() {
    let mut forged = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let acknowledgement = exact_ack("inspect", "%2");
    forged["state"] = serde_json::json!("running");
    forged["nodes"]["inspect"]["state"] = serde_json::json!("succeeded");
    forged["nodes"]["inspect"]["attempt"] = serde_json::json!(1);
    forged["nodes"]["inspect"]["agent_cli_session_id"] = serde_json::json!("%2");
    forged["nodes"]["inspect"]["evidence_refs"] =
        serde_json::json!(["workflow-ack:run-123:inspect"]);
    forged["nodes"]["inspect"]["completion_proof"] = acknowledgement.clone();
    forged["nodes"]["verify"]["state"] = serde_json::json!("ready");

    reducer_transition_with_proofs(
        forged.clone(),
        serde_json::json!({"type":"validate"}),
        no_durable_proofs(),
    )
    .expect_err("snapshot-local success proof is not external authority");

    let exact = serde_json::json!({
        "completion_acknowledgements": [acknowledgement.clone()],
        "cancellation_proofs": []
    });
    reducer_transition_with_proofs(
        forged.clone(),
        serde_json::json!({"type":"validate"}),
        exact,
    )
    .expect("one exact external durable proof validates succeeded state");

    let duplicates = serde_json::json!({
        "completion_acknowledgements": [acknowledgement.clone(), acknowledgement.clone()],
        "cancellation_proofs": []
    });
    reducer_transition_with_proofs(
        forged.clone(),
        serde_json::json!({"type":"validate"}),
        duplicates,
    )
    .expect("byte-identical external proof replay is one semantic proof");

    let mut conflict = acknowledgement.clone();
    conflict["pane_id"] = serde_json::json!("%3");
    reducer_transition_with_proofs(
        forged,
        serde_json::json!({"type":"validate"}),
        serde_json::json!({
            "completion_acknowledgements": [acknowledgement, conflict],
            "cancellation_proofs": []
        }),
    )
    .expect_err("same completion identity with different content is ambiguous");
}

#[test]
fn h10_cancelled_state_requires_an_external_typed_cancellation_proof() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let cancellation = exact_cancellation();
    reducer_transition_with_proofs(
        run.clone(),
        serde_json::json!({"type":"cancel","cancellation":cancellation.clone()}),
        no_durable_proofs(),
    )
    .expect_err("the typed cancel event cannot create its own external authority");

    let external = serde_json::json!({
        "completion_acknowledgements": [],
        "cancellation_proofs": [cancellation.clone(), cancellation.clone()]
    });
    let mut mismatched_event = cancellation.clone();
    mismatched_event["evidence_ref"] = serde_json::json!("workflow-cancel:another-run");
    reducer_transition_with_proofs(
        run.clone(),
        serde_json::json!({"type":"cancel","cancellation":mismatched_event}),
        external.clone(),
    )
    .expect_err("the cancel event must exactly match the external durable proof");
    let cancelled = reducer_transition_with_proofs(
        run,
        serde_json::json!({"type":"cancel","cancellation":cancellation.clone()}),
        external.clone(),
    )
    .expect("one exact external cancellation proof authorizes the transition");
    assert_eq!(cancelled["state"], "cancelled");

    reducer_transition_with_proofs(
        cancelled.clone(),
        serde_json::json!({"type":"validate"}),
        no_durable_proofs(),
    )
    .expect_err("persisted cancellation cannot prove itself");

    let validated = reducer_transition_with_proofs(
        cancelled,
        serde_json::json!({"type":"validate"}),
        external.clone(),
    )
    .expect("exact cancellation replay deduplicates to one semantic proof");
    let cleaning = reducer_transition_with_proofs(
        validated,
        serde_json::json!({"type":"cleanup_intent","preserve_run_state":"cancelled"}),
        external,
    )
    .expect("cancelled cleanup preserves only the externally proven terminal state");
    assert_eq!(cleaning["state"], "cancelled");
    assert_eq!(cleaning["cleanup_journal"][0]["state"], "running");
}

#[test]
fn i01_generation_id_accepts_managed_guid_n_or_legacy_stable_id_only() {
    for generation_id in ["0123456789abcdef0123456789abcdef", "generation-123"] {
        let mut request = reducer_bootstrap_request();
        request["identity"]["generation_id"] = serde_json::json!(generation_id);
        let run = reduce_workflow_state_value(&request)
            .unwrap_or_else(|error| panic!("{generation_id} must bootstrap: {error}"));
        assert_eq!(run["generation_id"], generation_id);
    }

    for generation_id in [
        "123",
        "0123456789abcdef0123456789abcde",
        "0123456789abcdef0123456789abcdef0",
        "0123456789abcdef0123456789abcdeF",
        "0123456789abcdef0123456789abcdeg",
        "-generation-123",
        " generation-123",
        "generation-123 ",
        "\u{4e16}\u{4ee3}-123",
    ] {
        let mut request = reducer_bootstrap_request();
        request["identity"]["generation_id"] = serde_json::json!(generation_id);
        let error = reduce_workflow_state_value(&request)
            .expect_err("only the managed GUID-N or legacy stable generation forms are accepted");
        assert!(
            error.to_string().contains("generation_id"),
            "{generation_id} must fail generation validation: {error}"
        );
    }
}
