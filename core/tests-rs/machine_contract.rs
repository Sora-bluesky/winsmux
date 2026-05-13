#[path = "../src/machine_contract.rs"]
mod machine_contract;

use machine_contract::{canonical_role_for, machine_contract_catalog};

#[test]
fn machine_contract_exposes_version_and_canonical_roles() {
    let catalog = machine_contract_catalog();

    assert_eq!(catalog.version, "0.32.1");
    assert_eq!(
        catalog
            .roles
            .iter()
            .map(|role| role.canonical)
            .collect::<Vec<_>>(),
        vec!["operator", "worker", "reviewer", "builder"]
    );
    assert_eq!(canonical_role_for("Operator"), Some("operator"));
    assert_eq!(canonical_role_for("agent"), Some("worker"));
    assert_eq!(canonical_role_for("Reviewer"), Some("reviewer"));
    assert_eq!(canonical_role_for("Builder"), Some("builder"));
    assert_eq!(canonical_role_for("unknown"), None);
}

#[test]
fn machine_contract_exposes_worker_backend_contracts() {
    let catalog = machine_contract_catalog();

    assert_eq!(
        catalog
            .worker_backends
            .iter()
            .map(|backend| backend.id)
            .collect::<Vec<_>>(),
        vec!["local", "codex", "colab_cli", "noop"]
    );

    let local = catalog
        .worker_backends
        .iter()
        .find(|backend| backend.id == "local")
        .expect("local backend should exist");
    assert!(local.runtime_available);

    let colab = catalog
        .worker_backends
        .iter()
        .find(|backend| backend.id == "colab_cli")
        .expect("colab_cli backend should exist");
    assert!(colab.runtime_available);
    assert!(colab.config_fields.contains(&"session_name"));
    assert!(colab.config_fields.contains(&"gpu_preference"));
    assert!(colab.config_fields.contains(&"task_script"));

    let noop = catalog
        .worker_backends
        .iter()
        .find(|backend| backend.id == "noop")
        .expect("noop backend should exist");
    assert!(!noop.runtime_available);
}

#[test]
fn machine_contract_exposes_projection_surfaces_in_stable_order() {
    let catalog = machine_contract_catalog();

    assert_eq!(
        catalog
            .projection_surfaces
            .iter()
            .map(|surface| surface.name)
            .collect::<Vec<_>>(),
        vec![
            "status",
            "board",
            "inbox",
            "digest",
            "runs",
            "explain",
            "search-ledger",
            "poll-events",
            "dispatch-review",
            "review-request",
            "review-approve",
            "review-fail",
            "review-reset",
        ]
    );
    assert_eq!(
        catalog.projection_surfaces[5].command,
        "explain <run_id> --json"
    );
    assert_eq!(
        catalog
            .projection_surfaces
            .iter()
            .map(|surface| surface.rust_type)
            .collect::<Vec<_>>(),
        vec![
            "LedgerStatusPayload",
            "LedgerBoardPayload",
            "LedgerInboxPayload",
            "LedgerDigestPayload",
            "LedgerRunsPayload",
            "LedgerExplainPayload",
            "SearchLedgerPayload",
            "PollEventsPayload",
            "ReviewRequestDispatchPayload",
            "ReviewStateRecord",
            "ReviewStateRecord",
            "ReviewStateRecord",
            "ReviewResetPayload",
        ]
    );
}

#[test]
fn machine_contract_exposes_review_state_and_verdict_fields() {
    let catalog = machine_contract_catalog();

    assert_eq!(catalog.review_state_file.path, ".winsmux/review-state.json");
    assert_eq!(catalog.review_state_file.version, 1);
    assert!(catalog
        .review_state_file
        .required_fields
        .contains(&"status"));
    assert_eq!(
        catalog.review_state_file.states,
        ["PENDING", "PASS", "FAIL"]
    );

    let review_state = catalog
        .verdict_fields
        .iter()
        .find(|field| field.field == "review_state")
        .expect("review_state verdict field should exist");
    assert_eq!(review_state.allowed_values, ["PENDING", "PASS", "FAIL"]);

    let security = catalog
        .verdict_fields
        .iter()
        .find(|field| field.field == "security_verdict")
        .expect("security verdict field should exist");
    assert!(security.allowed_values.contains(&"BLOCK"));
}

#[test]
fn machine_contract_exposes_organization_contract() {
    let catalog = machine_contract_catalog();

    let terms = catalog
        .organization
        .terms
        .iter()
        .map(|term| term.name)
        .collect::<Vec<_>>();
    assert_eq!(
        terms,
        vec![
            "organization",
            "agent",
            "slot",
            "heartbeat",
            "task_checkout",
            "board_approval",
            "budget",
            "audit_trail",
        ]
    );

    let fields = catalog
        .organization
        .manifest_fields
        .iter()
        .map(|field| field.field)
        .collect::<Vec<_>>();
    assert_eq!(
        fields,
        vec![
            "agent_id",
            "title",
            "reports_to",
            "capabilities",
            "budget_monthly_cents",
            "spent_monthly_cents",
            "cost_soft_limit_pct",
            "cost_hard_limit_pct",
        ]
    );
    assert!(catalog
        .organization
        .manifest_fields
        .iter()
        .all(|field| !field.required));
    let budget = catalog
        .organization
        .manifest_fields
        .iter()
        .find(|field| field.field == "budget_monthly_cents")
        .expect("budget field should exist");
    assert_eq!(budget.shape, "u64 number or numeric string");
}

#[test]
fn machine_contract_exposes_event_taxonomy_groups() {
    let catalog = machine_contract_catalog();

    let groups = catalog
        .event_taxonomy
        .iter()
        .map(|group| group.group)
        .collect::<Vec<_>>();
    assert_eq!(
        groups,
        vec![
            "pane_lifecycle",
            "operator_actions",
            "consultation",
            "agent_heartbeat",
            "task_checkout",
            "board_approval",
            "verification",
            "security"
        ]
    );

    let verification = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "verification")
        .expect("verification taxonomy should exist");
    assert_eq!(
        verification.events,
        [
            "pipeline.verify.pass",
            "pipeline.verify.fail",
            "pipeline.verify.partial"
        ]
    );

    let pane_lifecycle = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "pane_lifecycle")
        .expect("pane lifecycle taxonomy should exist");
    assert!(pane_lifecycle.events.contains(&"approval_waiting"));
    assert!(pane_lifecycle.events.contains(&"monitor.status"));
    assert!(pane_lifecycle.events.contains(&"pane.approval_waiting"));
    assert!(pane_lifecycle.events.contains(&"pane.bootstrap_invalid"));
    assert!(pane_lifecycle.events.contains(&"pane.crashed"));

    let consultation = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "consultation")
        .expect("consultation taxonomy should exist");
    assert!(consultation.events.contains(&"pane.consult_error"));

    let security = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "security")
        .expect("security taxonomy should exist");
    assert!(security.events.contains(&"security.policy.allowed"));
    assert!(security.events.contains(&"security.policy.blocked"));

    let operator_actions = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "operator_actions")
        .expect("operator actions taxonomy should exist");
    assert!(operator_actions.events.contains(&"operator.blocked"));

    let heartbeat = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "agent_heartbeat")
        .expect("agent heartbeat taxonomy should exist");
    assert!(heartbeat.events.contains(&"agent.heartbeat.cost_recorded"));

    let checkout = catalog
        .event_taxonomy
        .iter()
        .find(|group| group.group == "task_checkout")
        .expect("task checkout taxonomy should exist");
    assert!(checkout.events.contains(&"task.checkout_conflict"));
}

#[test]
fn machine_contract_serializes_to_json() {
    let value = serde_json::to_value(machine_contract_catalog())
        .expect("machine contract should serialize to JSON");

    assert_eq!(value["version"], "0.32.1");
    assert_eq!(value["roles"][3]["canonical"], "builder");
    assert_eq!(value["roles"][3]["legacy_aliases"][0], "Builder");
    assert_eq!(value["organization"]["terms"][1]["name"], "agent");
    assert_eq!(value["worker_backends"][2]["id"], "colab_cli");
    assert_eq!(value["worker_backends"][2]["runtime_available"], true);
    assert_eq!(value["worker_backends"][3]["id"], "noop");
    assert_eq!(value["worker_backends"][3]["runtime_available"], false);
    assert_eq!(
        value["organization"]["manifest_fields"][4]["field"],
        "budget_monthly_cents"
    );
    assert_eq!(value["projection_surfaces"][6]["name"], "search-ledger");
    assert_eq!(value["projection_surfaces"][7]["name"], "poll-events");
    assert_eq!(
        value["projection_surfaces"][4]["rust_type"],
        "LedgerRunsPayload"
    );
    assert_eq!(value["review_state_file"]["states"][2], "FAIL");
    assert_eq!(value["event_taxonomy"][7]["group"], "security");
    assert_eq!(
        value["verdict_fields"][1]["field"],
        "verification_result.outcome"
    );
}
