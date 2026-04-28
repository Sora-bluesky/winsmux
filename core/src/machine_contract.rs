use serde::Serialize;

pub const MACHINE_CONTRACT_VERSION: &str = "0.24.2";

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct MachineContractCatalog<'a> {
    pub version: &'a str,
    pub roles: &'a [RoleContract<'a>],
    pub organization: OrganizationContract<'a>,
    pub projection_surfaces: &'a [ProjectionSurfaceContract<'a>],
    pub review_state_file: ReviewStateFileContract<'a>,
    pub event_taxonomy: &'a [EventTaxonomyGroup<'a>],
    pub verdict_fields: &'a [VerdictFieldContract<'a>],
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct RoleContract<'a> {
    pub canonical: &'a str,
    pub legacy_aliases: &'a [&'a str],
    pub agent_facing: bool,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct ProjectionSurfaceContract<'a> {
    pub name: &'a str,
    pub command: &'a str,
    pub shape: &'a str,
    pub rust_type: &'a str,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct OrganizationContract<'a> {
    pub terms: &'a [OrganizationTermContract<'a>],
    pub manifest_fields: &'a [ManifestFieldContract<'a>],
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct OrganizationTermContract<'a> {
    pub name: &'a str,
    pub description: &'a str,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct ManifestFieldContract<'a> {
    pub field: &'a str,
    pub shape: &'a str,
    pub required: bool,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct ReviewStateFileContract<'a> {
    pub path: &'a str,
    pub version: u32,
    pub required_fields: &'a [&'a str],
    pub optional_fields: &'a [&'a str],
    pub states: &'a [&'a str],
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct EventTaxonomyGroup<'a> {
    pub group: &'a str,
    pub events: &'a [&'a str],
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct VerdictFieldContract<'a> {
    pub field: &'a str,
    pub allowed_values: &'a [&'a str],
}

pub fn machine_contract_catalog() -> MachineContractCatalog<'static> {
    MachineContractCatalog {
        version: MACHINE_CONTRACT_VERSION,
        roles: ROLES,
        organization: ORGANIZATION,
        projection_surfaces: PROJECTION_SURFACES,
        review_state_file: REVIEW_STATE_FILE,
        event_taxonomy: EVENT_TAXONOMY,
        verdict_fields: VERDICT_FIELDS,
    }
}

pub fn canonical_role_for(value: &str) -> Option<&'static str> {
    let normalized = value.trim().to_ascii_lowercase();
    ROLES
        .iter()
        .find(|role| {
            role.canonical == normalized
                || role
                    .legacy_aliases
                    .iter()
                    .any(|alias| alias.to_ascii_lowercase() == normalized)
        })
        .map(|role| role.canonical)
}

const ROLES: &[RoleContract<'static>] = &[
    RoleContract {
        canonical: "operator",
        legacy_aliases: &["Operator", "orchestrator", "controller"],
        agent_facing: false,
    },
    RoleContract {
        canonical: "worker",
        legacy_aliases: &["Worker", "agent", "implementer"],
        agent_facing: true,
    },
    RoleContract {
        canonical: "reviewer",
        legacy_aliases: &["Reviewer", "review", "auditor"],
        agent_facing: true,
    },
    RoleContract {
        canonical: "builder",
        legacy_aliases: &["Builder", "build", "worktree-builder"],
        agent_facing: true,
    },
];

const ORGANIZATION: OrganizationContract<'static> = OrganizationContract {
    terms: ORGANIZATION_TERMS,
    manifest_fields: ORGANIZATION_MANIFEST_FIELDS,
};

const ORGANIZATION_TERMS: &[OrganizationTermContract<'static>] = &[
    OrganizationTermContract {
        name: "organization",
        description: "top-level control plane that groups agents, policies, and budget state",
    },
    OrganizationTermContract {
        name: "agent",
        description: "addressable worker or reviewer runtime with ownership and capabilities",
    },
    OrganizationTermContract {
        name: "slot",
        description: "allocatable runtime seat that can host one active agent",
    },
    OrganizationTermContract {
        name: "heartbeat",
        description: "periodic liveness, progress, and cost signal emitted by an agent",
    },
    OrganizationTermContract {
        name: "task_checkout",
        description: "exclusive claim for work that prevents duplicate execution",
    },
    OrganizationTermContract {
        name: "board_approval",
        description: "explicit operator or policy approval before a gated action proceeds",
    },
    OrganizationTermContract {
        name: "budget",
        description: "monthly cost allowance and alert thresholds for an agent or group",
    },
    OrganizationTermContract {
        name: "audit_trail",
        description: "append-only evidence that explains who acted and why",
    },
];

const ORGANIZATION_MANIFEST_FIELDS: &[ManifestFieldContract<'static>] = &[
    ManifestFieldContract {
        field: "agent_id",
        shape: "string",
        required: false,
    },
    ManifestFieldContract {
        field: "title",
        shape: "string",
        required: false,
    },
    ManifestFieldContract {
        field: "reports_to",
        shape: "string",
        required: false,
    },
    ManifestFieldContract {
        field: "capabilities",
        shape: "string array or JSON string array",
        required: false,
    },
    ManifestFieldContract {
        field: "budget_monthly_cents",
        shape: "u64 number or numeric string",
        required: false,
    },
    ManifestFieldContract {
        field: "spent_monthly_cents",
        shape: "u64 number or numeric string",
        required: false,
    },
    ManifestFieldContract {
        field: "cost_soft_limit_pct",
        shape: "u32 number or numeric string from 0 to 100",
        required: false,
    },
    ManifestFieldContract {
        field: "cost_hard_limit_pct",
        shape: "u32 number or numeric string from 0 to 100; greater than or equal to cost_soft_limit_pct when both are set",
        required: false,
    },
];

const PROJECTION_SURFACES: &[ProjectionSurfaceContract<'static>] = &[
    ProjectionSurfaceContract {
        name: "status",
        command: "status --json",
        shape: "session summary plus pane read models",
        rust_type: "LedgerStatusPayload",
    },
    ProjectionSurfaceContract {
        name: "board",
        command: "board --json",
        shape: "ordered pane board projection",
        rust_type: "LedgerBoardPayload",
    },
    ProjectionSurfaceContract {
        name: "inbox",
        command: "inbox --json",
        shape: "actionable inbox items",
        rust_type: "LedgerInboxPayload",
    },
    ProjectionSurfaceContract {
        name: "digest",
        command: "digest --json",
        shape: "run evidence digest",
        rust_type: "LedgerDigestPayload",
    },
    ProjectionSurfaceContract {
        name: "runs",
        command: "runs --json",
        shape: "run catalog projection",
        rust_type: "LedgerRunsPayload",
    },
    ProjectionSurfaceContract {
        name: "explain",
        command: "explain <run_id> --json",
        shape: "single run explanation with recent events",
        rust_type: "LedgerExplainPayload",
    },
    ProjectionSurfaceContract {
        name: "search-ledger",
        command: "search-ledger <search|timeline|detail> --json",
        shape: "SQLite FTS5 search, timeline, and detail projection over events.jsonl",
        rust_type: "SearchLedgerPayload",
    },
    ProjectionSurfaceContract {
        name: "poll-events",
        command: "poll-events --json",
        shape: "event stream items",
        rust_type: "PollEventsPayload",
    },
    ProjectionSurfaceContract {
        name: "dispatch-review",
        command: "dispatch-review --json",
        shape: "review request dispatch status",
        rust_type: "ReviewRequestDispatchPayload",
    },
    ProjectionSurfaceContract {
        name: "review-request",
        command: "review-request --json",
        shape: "pending review-state record",
        rust_type: "ReviewStateRecord",
    },
    ProjectionSurfaceContract {
        name: "review-approve",
        command: "review-approve --json",
        shape: "approved review-state record",
        rust_type: "ReviewStateRecord",
    },
    ProjectionSurfaceContract {
        name: "review-fail",
        command: "review-fail --json",
        shape: "failed review-state record",
        rust_type: "ReviewStateRecord",
    },
    ProjectionSurfaceContract {
        name: "review-reset",
        command: "review-reset --json",
        shape: "review-state cleanup status",
        rust_type: "ReviewResetPayload",
    },
];

const REVIEW_STATE_FILE: ReviewStateFileContract<'static> = ReviewStateFileContract {
    path: ".winsmux/review-state.json",
    version: 1,
    required_fields: &[
        "status",
        "branch",
        "head_sha",
        "request",
        "reviewer",
        "updatedAt",
    ],
    optional_fields: &["evidence"],
    states: &["PENDING", "PASS", "FAIL"],
};

const EVENT_TAXONOMY: &[EventTaxonomyGroup<'static>] = &[
    EventTaxonomyGroup {
        group: "pane_lifecycle",
        events: &[
            "approval_waiting",
            "monitor.status",
            "pane.started",
            "pane.idle",
            "pane.approval_waiting",
            "pane.completed",
            "pane.bootstrap_invalid",
            "pane.crashed",
            "pane.hung",
            "pane.stalled",
        ],
    },
    EventTaxonomyGroup {
        group: "operator_actions",
        events: &[
            "operator.review_requested",
            "operator.review_failed",
            "operator.blocked",
            "operator.commit_ready",
            "operator.followup",
            "operator.state_transition",
        ],
    },
    EventTaxonomyGroup {
        group: "consultation",
        events: &[
            "pane.consult_request",
            "pane.consult_result",
            "pane.consult_error",
        ],
    },
    EventTaxonomyGroup {
        group: "agent_heartbeat",
        events: &[
            "agent.heartbeat.started",
            "agent.heartbeat.completed",
            "agent.heartbeat.blocked",
            "agent.heartbeat.cost_recorded",
        ],
    },
    EventTaxonomyGroup {
        group: "task_checkout",
        events: &[
            "task.checked_out",
            "task.checkout_conflict",
            "task.released",
        ],
    },
    EventTaxonomyGroup {
        group: "board_approval",
        events: &[
            "board.approval.requested",
            "board.approval.granted",
            "board.approval.denied",
        ],
    },
    EventTaxonomyGroup {
        group: "verification",
        events: &[
            "pipeline.verify.pass",
            "pipeline.verify.fail",
            "pipeline.verify.partial",
        ],
    },
    EventTaxonomyGroup {
        group: "security",
        events: &[
            "pipeline.security.allowed",
            "pipeline.security.blocked",
            "security.policy.allowed",
            "security.policy.blocked",
        ],
    },
];

const VERDICT_FIELDS: &[VerdictFieldContract<'static>] = &[
    VerdictFieldContract {
        field: "review_state",
        allowed_values: &["PENDING", "PASS", "FAIL"],
    },
    VerdictFieldContract {
        field: "verification_result.outcome",
        allowed_values: &["PASS", "FAIL", "SKIP"],
    },
    VerdictFieldContract {
        field: "security_verdict",
        allowed_values: &["ALLOW", "BLOCK", "WARN"],
    },
    VerdictFieldContract {
        field: "verdict",
        allowed_values: &["ALLOW", "BLOCK", "PASS", "FAIL", "WARN"],
    },
];
