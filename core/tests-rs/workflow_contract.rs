#[path = "../src/workflow.rs"]
mod workflow;
#[path = "../src/workspace_recipe.rs"]
mod workspace_recipe;

use std::collections::{BTreeMap, BTreeSet};

use workflow::{
    initial_node_states, normalize_workflow_plan, reduce_workflow_state_value, release_ready_nodes,
    NodeState, RunState,
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
        VALID.replace("action: verification", "action: arbitrary-shell"),
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

fn reducer_bootstrap_request() -> serde_json::Value {
    let plan = normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings())
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
    serde_json::json!({
        "schema_version": 1,
        "run_id": "run-123",
        "node_id": node_id,
        "idempotency_key": format!("run-123:{node_id}"),
        "generation_id": "generation-123",
        "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
        "workflow_fingerprint": normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings()).unwrap().workflow_fingerprint,
        "source_head": "b".repeat(40),
        "pane_id": pane_id,
        "status": "succeeded",
        "evidence_ref": format!("workflow-ack:run-123:{node_id}")
    })
}

fn exact_cancellation() -> serde_json::Value {
    serde_json::json!({
        "schema_version": 1,
        "run_id": "run-123",
        "idempotency_key": "run-123:cancel",
        "generation_id": "generation-123",
        "config_fingerprint": format!("sha256:{}", "a".repeat(64)),
        "workflow_fingerprint": normalize_workflow_plan(VALID, "bugfix", "run-123", "bugfix-two-slot", &bindings()).unwrap().workflow_fingerprint,
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
    )
    .expect_err("verification producers resolving to distinct labels must reject");
}

#[test]
fn h02_h12_reducer_owns_bootstrap_transitions_proofs_release_and_run_state() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).expect("bootstrap v2 run");
    assert_eq!(run["schema_version"], 2);
    assert_eq!(run["state"], "ready");
    assert_eq!(run["nodes"]["inspect"]["state"], "ready");
    assert_eq!(run["nodes"]["verify"]["state"], "pending");

    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
    )
    .expect("persist dispatch intent");
    assert_eq!(dispatching["nodes"]["inspect"]["state"], "dispatching");
    assert_eq!(dispatching["nodes"]["inspect"]["attempt"], 1);
    assert_eq!(dispatching["state"], "running");

    let succeeded = reducer_transition(
        dispatching,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement": exact_ack("inspect", "%2"),
            "resolved_session_id":"%2"
        }),
    )
    .expect("exact acknowledgement succeeds");
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
fn h03_state_snapshot_is_untrusted_and_v1_or_forged_proof_never_releases_dependencies() {
    let mut v1 = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    v1["schema_version"] = serde_json::json!(1);
    let error = reducer_transition(v1, serde_json::json!({"type":"validate"}))
        .expect_err("v1 requires migration");
    assert!(error
        .to_string()
        .contains("workflow_state_migration_required"));

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
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
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
        reducer_transition(dispatching.clone(), serde_json::json!({
            "type":"acknowledge", "node_id":"inspect", "acknowledgement":ack, "resolved_session_id":"%2"
        })).expect_err(field);
    }

    let failed = reducer_transition(
        dispatching,
        serde_json::json!({"type":"dispatch_failed","node_id":"inspect"}),
    )
    .unwrap();
    reducer_transition(
        failed,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
    )
    .expect_err("terminal failed node must not regress");
}

#[test]
fn h05_no_or_ambiguous_ack_blocks_without_retry_and_unknown_or_private_request_fields_reject() {
    let run = reduce_workflow_state_value(&reducer_bootstrap_request()).unwrap();
    let dispatching = reducer_transition(
        run,
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
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
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
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
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
    )
    .unwrap();
    let blocked = reducer_transition(
        dispatching,
        serde_json::json!({"type":"block","node_id":"inspect"}),
    )
    .unwrap();
    let succeeded = reducer_transition(
        blocked,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement":exact_ack("inspect", "%2"),
            "resolved_session_id":"%2"
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
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
    )
    .unwrap();
    let inspect_done = reducer_transition(
        dispatching,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"inspect",
            "acknowledgement":exact_ack("inspect", "%2"),
            "resolved_session_id":"%2"
        }),
    )
    .unwrap();
    let verify_dispatching = reducer_transition(
        inspect_done,
        serde_json::json!({"type":"dispatch_intent","node_id":"verify"}),
    )
    .unwrap();
    let completed = reducer_transition(
        verify_dispatching,
        serde_json::json!({
            "type":"acknowledge",
            "node_id":"verify",
            "acknowledgement":exact_ack("verify", "%3"),
            "resolved_session_id":"%3"
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
        serde_json::json!({"type":"dispatch_intent","node_id":"inspect"}),
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
    let cancelled = reducer_transition_with_proofs(
        run,
        serde_json::json!({"type":"cancel","cancellation":cancellation.clone()}),
        no_durable_proofs(),
    )
    .expect("the typed cancel event proof is external authority for this transition");
    assert_eq!(cancelled["state"], "cancelled");

    reducer_transition_with_proofs(
        cancelled.clone(),
        serde_json::json!({"type":"validate"}),
        no_durable_proofs(),
    )
    .expect_err("persisted cancellation cannot prove itself");

    let external = serde_json::json!({
        "completion_acknowledgements": [],
        "cancellation_proofs": [cancellation.clone(), cancellation]
    });
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
