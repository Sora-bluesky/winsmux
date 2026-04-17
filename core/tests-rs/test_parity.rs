use crate::types::{AppState, ClientInfo};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;

mod rust_parity_support {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../tests/test_support/rust_parity.rs"
    ));
}

fn mock_app() -> AppState {
    let mut app = AppState::new("test_session".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn rust_parity_repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn read_rust_parity_fixture_typed<T: serde::de::DeserializeOwned>(name: &str) -> T {
    rust_parity_support::read_json_fixture_typed(&rust_parity_repo_root(), name)
}

#[derive(Deserialize)]
struct RustParityBoardFixture {
    generated_at: String,
    project_dir: String,
    summary: RustParityBoardSummary,
    panes: Vec<RustParityBoardPane>,
}

#[derive(Deserialize)]
struct RustParityBoardSummary {
    pane_count: usize,
    dirty_panes: usize,
    review_pending: usize,
    review_failed: usize,
    review_passed: usize,
    tasks_in_progress: usize,
    tasks_blocked: usize,
    by_state: HashMap<String, usize>,
    by_review: HashMap<String, usize>,
    by_task_state: HashMap<String, usize>,
}

#[derive(Deserialize)]
struct RustParityBoardPane {
    label: String,
    pane_id: String,
    task_state: String,
    changed_file_count: usize,
    last_event_at: String,
}

#[derive(Deserialize)]
struct RustParityInboxFixture {
    generated_at: String,
    project_dir: String,
    summary: RustParityInboxSummary,
    items: Vec<RustParityInboxItem>,
}

#[derive(Deserialize)]
struct RustParityInboxSummary {
    item_count: usize,
    by_kind: HashMap<String, usize>,
}

#[derive(Deserialize)]
struct RustParityInboxItem {
    kind: String,
    priority: usize,
    message: String,
    label: String,
    pane_id: String,
    role: String,
    task_id: String,
    task: String,
    task_state: String,
    review_state: String,
    branch: String,
    head_sha: String,
    changed_file_count: usize,
    event: String,
    timestamp: String,
    source: String,
}

#[derive(Deserialize)]
struct RustParityDigestFixture {
    generated_at: String,
    project_dir: String,
    summary: RustParityDigestSummary,
    items: Vec<RustParityDigestItem>,
}

#[derive(Deserialize)]
struct RustParityDigestSummary {
    item_count: usize,
    dirty_items: usize,
    actionable_items: usize,
    review_pending: usize,
    review_failed: usize,
}

#[derive(Deserialize)]
struct RustParityDigestItem {
    run_id: String,
    task: String,
    label: String,
    pane_id: String,
    task_state: String,
    review_state: String,
    next_action: String,
    branch: String,
    changed_file_count: usize,
    last_event_at: String,
}

#[derive(Deserialize)]
struct RustParityExplainFixture {
    generated_at: String,
    project_dir: String,
    run: RustParityExplainRun,
    consultation_summary: RustParityExplainConsultationSummary,
    evidence_digest: RustParityExplainEvidenceDigest,
}

#[derive(Deserialize)]
struct RustParityExplainRun {
    run_id: String,
    task_id: String,
    parent_run_id: String,
    goal: String,
    task: String,
    task_type: String,
    priority: String,
    blocking: bool,
    state: String,
    task_state: String,
    review_state: String,
    branch: String,
    head_sha: String,
    worktree: String,
    primary_label: String,
    primary_pane_id: String,
    primary_role: String,
    last_event: String,
    tokens_remaining: String,
    pane_count: usize,
    changed_file_count: usize,
    labels: Vec<String>,
    pane_ids: Vec<String>,
    roles: Vec<String>,
    provider_target: String,
    agent_role: String,
    write_scope: Vec<String>,
    read_scope: Vec<String>,
    constraints: Vec<String>,
    expected_output: String,
    verification_plan: Vec<String>,
    review_required: bool,
    timeout_policy: String,
    handoff_refs: Vec<String>,
    experiment_packet: RustParityExplainExperimentPacket,
    security_policy: Value,
    security_verdict: Value,
    verification_contract: Value,
    verification_result: Value,
    changed_files: Vec<String>,
    last_event_at: String,
    action_items: Vec<RustParityExplainActionItem>,
}

#[derive(Deserialize)]
struct RustParityExplainExperimentPacket {
    hypothesis: String,
    test_plan: Vec<String>,
    result: String,
    confidence: f64,
    next_action: String,
    observation_pack_ref: String,
    consultation_ref: String,
    run_id: String,
    slot: String,
    branch: String,
    worktree: String,
    env_fingerprint: String,
    command_hash: String,
}

#[derive(Deserialize)]
struct RustParityExplainActionItem {
    kind: String,
    message: String,
    event: String,
    timestamp: String,
    source: String,
}

#[derive(Deserialize)]
struct RustParityExplainConsultationSummary {
    kind: String,
    mode: String,
    target_slot: String,
    confidence: f64,
    next_test: String,
    risks: Vec<String>,
}

#[derive(Deserialize)]
struct RustParityExplainEvidenceDigest {
    next_action: String,
    changed_file_count: usize,
    consultation_ref: String,
}

#[test]
fn rust_parity_board_fixture_deserializes() {
    let fixture: RustParityBoardFixture = read_rust_parity_fixture_typed("board.json");
    assert_eq!(fixture.generated_at, "__GENERATED_AT__");
    assert_eq!(fixture.project_dir, "__PROJECT_DIR__");
    assert_eq!(fixture.summary.pane_count, 2);
    assert_eq!(fixture.summary.dirty_panes, 1);
    assert_eq!(fixture.summary.review_pending, 1);
    assert_eq!(fixture.summary.review_failed, 0);
    assert_eq!(fixture.summary.review_passed, 0);
    assert_eq!(fixture.summary.tasks_in_progress, 1);
    assert_eq!(fixture.summary.tasks_blocked, 0);
    assert_eq!(fixture.summary.by_state["idle"], 1);
    assert_eq!(fixture.summary.by_state["busy"], 1);
    assert_eq!(fixture.summary.by_review["PENDING"], 1);
    assert_eq!(fixture.summary.by_task_state["in_progress"], 1);
    assert!(
        !fixture.panes.is_empty(),
        "board fixture should contain at least one pane"
    );
    let builder_pane = fixture
        .panes
        .iter()
        .find(|pane| pane.label == "builder-1")
        .expect("board fixture should contain builder-1");
    assert_eq!(builder_pane.pane_id, "%2");
    assert_eq!(builder_pane.task_state, "in_progress");
    assert_eq!(builder_pane.changed_file_count, 2);
    assert_eq!(builder_pane.last_event_at, "__LAST_EVENT_AT__");
}

#[test]
fn rust_parity_inbox_fixture_deserializes() {
    let fixture: RustParityInboxFixture = read_rust_parity_fixture_typed("inbox.json");
    assert_eq!(fixture.generated_at, "__GENERATED_AT__");
    assert_eq!(fixture.project_dir, "__PROJECT_DIR__");
    assert_eq!(fixture.summary.item_count, 4);
    assert_eq!(fixture.summary.by_kind["task_blocked"], 1);
    assert_eq!(fixture.summary.by_kind["commit_ready"], 1);
    assert!(
        !fixture.items.is_empty(),
        "inbox fixture should contain at least one item"
    );
    let blocked_item = fixture
        .items
        .iter()
        .find(|item| item.kind == "task_blocked")
        .expect("inbox fixture should contain task_blocked");
    assert_eq!(blocked_item.priority, 0);
    assert_eq!(blocked_item.message, "worker-1 が blocked。");
    assert_eq!(blocked_item.label, "worker-1");
    assert_eq!(blocked_item.pane_id, "%6");
    assert_eq!(blocked_item.role, "Worker");
    assert_eq!(blocked_item.task_id, "task-999");
    assert_eq!(blocked_item.task, "Fix blocker");
    assert_eq!(blocked_item.task_state, "blocked");
    assert_eq!(blocked_item.review_state, "");
    assert_eq!(blocked_item.branch, "worktree-worker-1");
    assert_eq!(blocked_item.head_sha, "def5678abc1234");
    assert_eq!(blocked_item.changed_file_count, 0);
    assert_eq!(blocked_item.event, "commander.state_transition");
    assert_eq!(blocked_item.timestamp, "__TIMESTAMP__");
    assert_eq!(blocked_item.source, "manifest");
}

#[test]
fn rust_parity_digest_fixture_deserializes() {
    let fixture: RustParityDigestFixture = read_rust_parity_fixture_typed("digest.json");
    assert_eq!(fixture.generated_at, "__GENERATED_AT__");
    assert_eq!(fixture.project_dir, "__PROJECT_DIR__");
    assert_eq!(fixture.summary.item_count, 1);
    assert_eq!(fixture.summary.dirty_items, 1);
    assert_eq!(fixture.summary.actionable_items, 1);
    assert_eq!(fixture.summary.review_pending, 0);
    assert_eq!(fixture.summary.review_failed, 1);
    assert_eq!(
        fixture.items.len(),
        1,
        "digest fixture should keep the minimal single-run shape"
    );
    assert_eq!(fixture.items[0].run_id, "task:task-246");
    assert_eq!(fixture.items[0].task, "Build evidence digest");
    assert_eq!(fixture.items[0].label, "builder-1");
    assert_eq!(fixture.items[0].pane_id, "%2");
    assert_eq!(fixture.items[0].task_state, "blocked");
    assert_eq!(fixture.items[0].review_state, "FAIL");
    assert_eq!(fixture.items[0].next_action, "review_failed");
    assert_eq!(fixture.items[0].branch, "worktree-builder-1");
    assert_eq!(fixture.items[0].changed_file_count, 1);
    assert_eq!(fixture.items[0].last_event_at, "__LAST_EVENT_AT__");
}

#[test]
fn rust_parity_explain_fixture_deserializes() {
    let fixture: RustParityExplainFixture = read_rust_parity_fixture_typed("explain.json");
    assert_eq!(fixture.generated_at, "__GENERATED_AT__");
    assert_eq!(fixture.project_dir, "__PROJECT_DIR__");
    assert_eq!(fixture.run.run_id, "task:task-256");
    assert_eq!(fixture.run.task_id, "task-256");
    assert_eq!(fixture.run.parent_run_id, "operator:session-1");
    assert_eq!(fixture.run.goal, "Ship run contract primitives");
    assert_eq!(fixture.run.task, "Implement run ledger");
    assert_eq!(fixture.run.task_type, "implementation");
    assert_eq!(fixture.run.priority, "P0");
    assert!(fixture.run.blocking);
    assert_eq!(fixture.run.state, "idle");
    assert_eq!(fixture.run.task_state, "in_progress");
    assert_eq!(fixture.run.review_state, "PENDING");
    assert_eq!(fixture.run.branch, "worktree-builder-1");
    assert_eq!(fixture.run.head_sha, "abc1234def5678");
    assert_eq!(fixture.run.worktree, ".worktrees/builder-1");
    assert_eq!(fixture.run.primary_label, "builder-1");
    assert_eq!(fixture.run.primary_pane_id, "%2");
    assert_eq!(fixture.run.primary_role, "Builder");
    assert_eq!(fixture.run.last_event, "commander.review_requested");
    assert_eq!(fixture.run.tokens_remaining, "64% context left");
    assert_eq!(fixture.run.pane_count, 1);
    assert_eq!(fixture.run.changed_file_count, 1);
    assert_eq!(fixture.run.labels, vec!["builder-1".to_string()]);
    assert_eq!(fixture.run.pane_ids, vec!["%2".to_string()]);
    assert_eq!(fixture.run.roles, vec!["Builder".to_string()]);
    assert_eq!(fixture.run.provider_target, "codex:gpt-5.4");
    assert_eq!(fixture.run.agent_role, "worker");
    assert_eq!(
        fixture.run.write_scope,
        vec![
            "scripts/winsmux-core.ps1".to_string(),
            "tests/winsmux-bridge.Tests.ps1".to_string()
        ]
    );
    assert_eq!(
        fixture.run.read_scope,
        vec!["winsmux-core/scripts/pane-status.ps1".to_string()]
    );
    assert_eq!(
        fixture.run.constraints,
        vec!["preserve existing board schema".to_string()]
    );
    assert_eq!(fixture.run.expected_output, "Stable run_packet JSON");
    assert_eq!(
        fixture.run.verification_plan,
        vec![
            "Invoke-Pester tests/winsmux-bridge.Tests.ps1".to_string(),
            "verify explain --json contract".to_string()
        ]
    );
    assert!(fixture.run.review_required);
    assert_eq!(fixture.run.timeout_policy, "standard");
    assert_eq!(
        fixture.run.handoff_refs,
        vec!["docs/handoff.md".to_string()]
    );
    assert_eq!(fixture.run.experiment_packet.hypothesis, "");
    assert!(fixture.run.experiment_packet.test_plan.is_empty());
    assert_eq!(fixture.run.experiment_packet.result, "consult before work");
    assert_eq!(fixture.run.experiment_packet.confidence, 0.66);
    assert_eq!(
        fixture.run.experiment_packet.next_action,
        "approval_waiting"
    );
    assert_eq!(
        fixture.run.experiment_packet.observation_pack_ref,
        ".winsmux/observation-packs/observation-pack-__ID__.json"
    );
    assert_eq!(
        fixture.run.experiment_packet.consultation_ref,
        ".winsmux/consultations/consult-result-__ID__.json"
    );
    assert_eq!(fixture.run.experiment_packet.run_id, "");
    assert_eq!(fixture.run.experiment_packet.slot, "slot-builder-1");
    assert_eq!(fixture.run.experiment_packet.branch, "worktree-builder-1");
    assert_eq!(fixture.run.experiment_packet.worktree, "");
    assert_eq!(fixture.run.experiment_packet.env_fingerprint, "");
    assert_eq!(fixture.run.experiment_packet.command_hash, "");
    assert!(fixture.run.security_policy.is_null());
    assert!(fixture.run.security_verdict.is_null());
    assert!(fixture.run.verification_contract.is_null());
    assert!(fixture.run.verification_result.is_null());
    assert_eq!(fixture.run.changed_files, vec!["scripts/winsmux-core.ps1"]);
    assert_eq!(fixture.run.last_event_at, "__LAST_EVENT_AT__");
    assert!(
        !fixture.run.action_items.is_empty(),
        "explain fixture should contain at least one action item"
    );
    let review_pending = fixture
        .run
        .action_items
        .iter()
        .find(|item| item.kind == "review_pending")
        .expect("explain fixture should contain review_pending action item");
    assert_eq!(review_pending.message, "builder-1 が review 待機中。");
    assert_eq!(review_pending.event, "commander.review_requested");
    assert_eq!(review_pending.timestamp, "__TIMESTAMP__");
    assert_eq!(review_pending.source, "manifest");
    assert_eq!(fixture.consultation_summary.kind, "consult_result");
    assert_eq!(fixture.consultation_summary.mode, "early");
    assert_eq!(fixture.consultation_summary.target_slot, "slot-review-1");
    assert_eq!(fixture.consultation_summary.confidence, 0.66);
    assert_eq!(fixture.consultation_summary.next_test, "approval_waiting");
    assert_eq!(
        fixture.consultation_summary.risks,
        vec!["needs reviewer confirmation".to_string()]
    );
    assert_eq!(fixture.evidence_digest.next_action, "review_pending");
    assert_eq!(fixture.evidence_digest.changed_file_count, 1);
    assert!(fixture.evidence_digest.consultation_ref.contains("__ID__"));
}

// ════════════════════════════════════════════════════════════════════════════
//  Hook System Tests
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn hook_before_new_window_found_in_hooks_map() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g before-new-window 'display-message creating'",
    );
    assert!(app.hooks.contains_key("before-new-window"));
    assert_eq!(
        app.hooks["before-new-window"][0],
        "display-message creating"
    );
}

#[test]
fn hook_before_split_window_found_in_hooks_map() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g before-split-window 'display-message splitting'",
    );
    assert!(app.hooks.contains_key("before-split-window"));
    assert_eq!(
        app.hooks["before-split-window"][0],
        "display-message splitting"
    );
}

#[test]
fn hook_before_kill_pane_found_in_hooks_map() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g before-kill-pane 'display-message killing'",
    );
    assert!(app.hooks.contains_key("before-kill-pane"));
}

#[test]
fn hook_before_select_window_found_in_hooks_map() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g before-select-window 'display-message switching'",
    );
    assert!(app.hooks.contains_key("before-select-window"));
}

#[test]
fn hook_before_rename_window_found_in_hooks_map() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g before-rename-window 'display-message renaming'",
    );
    assert!(app.hooks.contains_key("before-rename-window"));
}

#[test]
fn hook_after_new_window_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-new-window 'display-message created'",
    );
    assert!(app.hooks.contains_key("after-new-window"));
    assert_eq!(app.hooks["after-new-window"][0], "display-message created");
}

#[test]
fn hook_after_split_window_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-split-window 'display-message split'",
    );
    assert!(app.hooks.contains_key("after-split-window"));
}

#[test]
fn hook_after_kill_pane_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-kill-pane 'display-message killed'",
    );
    assert!(app.hooks.contains_key("after-kill-pane"));
}

#[test]
fn hook_after_select_window_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-select-window 'display-message switched'",
    );
    assert!(app.hooks.contains_key("after-select-window"));
}

#[test]
fn hook_after_resize_pane_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-resize-pane 'display-message resized'",
    );
    assert!(app.hooks.contains_key("after-resize-pane"));
}

#[test]
fn hook_client_attached_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(&mut app, "set-hook -g client-attached 'display-message hi'");
    assert!(app.hooks.contains_key("client-attached"));
}

#[test]
fn hook_session_created_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g session-created 'display-message new'",
    );
    assert!(app.hooks.contains_key("session-created"));
}

#[test]
fn hook_pane_set_clipboard_still_works() {
    let mut app = mock_app();
    crate::config::parse_config_line(&mut app, "set-hook -g pane-set-clipboard 'run-shell clip'");
    assert!(app.hooks.contains_key("pane-set-clipboard"));
}

#[test]
fn hook_multiple_commands_via_append() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-new-window 'display-message first'",
    );
    crate::config::parse_config_line(
        &mut app,
        "set-hook -ga after-new-window 'display-message second'",
    );
    crate::config::parse_config_line(
        &mut app,
        "set-hook -ga after-new-window 'display-message third'",
    );
    let cmds = app.hooks.get("after-new-window").unwrap();
    assert_eq!(cmds.len(), 3);
    assert_eq!(cmds[0], "display-message first");
    assert_eq!(cmds[1], "display-message second");
    assert_eq!(cmds[2], "display-message third");
}

#[test]
fn hook_before_and_after_coexist() {
    let mut app = mock_app();
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g before-new-window 'display-message before'",
    );
    crate::config::parse_config_line(
        &mut app,
        "set-hook -g after-new-window 'display-message after'",
    );
    assert!(app.hooks.contains_key("before-new-window"));
    assert!(app.hooks.contains_key("after-new-window"));
    assert_eq!(app.hooks.len(), 2);
}

#[test]
fn hook_empty_hooks_map_by_default() {
    let app = mock_app();
    assert!(app.hooks.is_empty());
}

// ════════════════════════════════════════════════════════════════════════════
//  Client Registry Tests
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn client_info_creation() {
    let info = ClientInfo {
        id: 1,
        width: 120,
        height: 30,
        connected_at: std::time::Instant::now(),
        last_activity: std::time::Instant::now(),
        tty_name: "/dev/pts/0".to_string(),
        is_control: false,
    };
    assert_eq!(info.id, 1);
    assert_eq!(info.width, 120);
    assert_eq!(info.height, 30);
    assert_eq!(info.tty_name, "/dev/pts/0");
    assert!(!info.is_control);
}

#[test]
fn client_info_control_mode() {
    let info = ClientInfo {
        id: 5,
        width: 80,
        height: 24,
        connected_at: std::time::Instant::now(),
        last_activity: std::time::Instant::now(),
        tty_name: "/dev/pts/3".to_string(),
        is_control: true,
    };
    assert!(info.is_control);
}

#[test]
fn client_registry_empty_by_default() {
    let app = mock_app();
    assert!(app.client_registry.is_empty());
}

#[test]
fn client_registry_add_client() {
    let mut app = mock_app();
    let info = ClientInfo {
        id: 1,
        width: 120,
        height: 30,
        connected_at: std::time::Instant::now(),
        last_activity: std::time::Instant::now(),
        tty_name: "/dev/pts/0".to_string(),
        is_control: false,
    };
    app.client_registry.insert(1, info);
    assert_eq!(app.client_registry.len(), 1);
    assert!(app.client_registry.contains_key(&1));
}

#[test]
fn client_registry_add_multiple_clients() {
    let mut app = mock_app();
    for i in 0..5 {
        app.client_registry.insert(
            i,
            ClientInfo {
                id: i,
                width: 120,
                height: 30,
                connected_at: std::time::Instant::now(),
                last_activity: std::time::Instant::now(),
                tty_name: format!("/dev/pts/{}", i),
                is_control: false,
            },
        );
    }
    assert_eq!(app.client_registry.len(), 5);
}

#[test]
fn client_registry_remove_client() {
    let mut app = mock_app();
    app.client_registry.insert(
        1,
        ClientInfo {
            id: 1,
            width: 120,
            height: 30,
            connected_at: std::time::Instant::now(),
            last_activity: std::time::Instant::now(),
            tty_name: "/dev/pts/0".to_string(),
            is_control: false,
        },
    );
    app.client_registry.insert(
        2,
        ClientInfo {
            id: 2,
            width: 80,
            height: 24,
            connected_at: std::time::Instant::now(),
            last_activity: std::time::Instant::now(),
            tty_name: "/dev/pts/1".to_string(),
            is_control: false,
        },
    );
    assert_eq!(app.client_registry.len(), 2);
    app.client_registry.remove(&1);
    assert_eq!(app.client_registry.len(), 1);
    assert!(!app.client_registry.contains_key(&1));
    assert!(app.client_registry.contains_key(&2));
}

#[test]
fn attached_clients_initial_zero() {
    let app = mock_app();
    assert_eq!(app.attached_clients, 0);
}

#[test]
fn attached_clients_tracking() {
    let mut app = mock_app();
    app.attached_clients = 1;
    assert_eq!(app.attached_clients, 1);
    app.attached_clients += 1;
    assert_eq!(app.attached_clients, 2);
    app.attached_clients -= 1;
    assert_eq!(app.attached_clients, 1);
}

#[test]
fn client_sizes_tracks_per_client_dimensions() {
    let mut app = mock_app();
    app.client_sizes.insert(1, (120, 30));
    app.client_sizes.insert(2, (80, 24));
    assert_eq!(app.client_sizes[&1], (120, 30));
    assert_eq!(app.client_sizes[&2], (80, 24));
}

// ════════════════════════════════════════════════════════════════════════════
//  Option Catalog Tests
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn option_catalog_build_returns_entries() {
    let app = mock_app();
    let options = crate::server::option_catalog::build_option_list(&app);
    assert!(!options.is_empty(), "option catalog should return entries");
}

#[test]
fn option_catalog_contains_common_options() {
    let app = mock_app();
    let options = crate::server::option_catalog::build_option_list(&app);
    let names: Vec<&str> = options.iter().map(|(n, _, _)| n.as_str()).collect();
    assert!(
        names.contains(&"escape-time"),
        "catalog should contain escape-time"
    );
    assert!(names.contains(&"mouse"), "catalog should contain mouse");
    assert!(names.contains(&"prefix"), "catalog should contain prefix");
    assert!(names.contains(&"status"), "catalog should contain status");
    assert!(
        names.contains(&"base-index"),
        "catalog should contain base-index"
    );
    assert!(
        names.contains(&"mode-keys"),
        "catalog should contain mode-keys"
    );
}

#[test]
fn option_catalog_entries_have_scope() {
    let app = mock_app();
    let options = crate::server::option_catalog::build_option_list(&app);
    let scopes: Vec<&str> = options.iter().map(|(_, _, s)| s.as_str()).collect();
    assert!(
        scopes.contains(&"server"),
        "catalog should have server scope entries"
    );
    assert!(
        scopes.contains(&"session"),
        "catalog should have session scope entries"
    );
    assert!(
        scopes.contains(&"window"),
        "catalog should have window scope entries"
    );
}

#[test]
fn option_catalog_default_for_escape_time() {
    let def = crate::server::option_catalog::default_for("escape-time");
    assert_eq!(def, Some("500"));
}

#[test]
fn option_catalog_default_for_mouse() {
    let def = crate::server::option_catalog::default_for("mouse");
    assert_eq!(def, Some("off"));
}

#[test]
fn option_catalog_default_for_status() {
    let def = crate::server::option_catalog::default_for("status");
    assert_eq!(def, Some("on"));
}

#[test]
fn option_catalog_default_for_mode_keys() {
    let def = crate::server::option_catalog::default_for("mode-keys");
    assert_eq!(def, Some("emacs"));
}

#[test]
fn option_catalog_default_for_unknown_returns_none() {
    let def = crate::server::option_catalog::default_for("nonexistent-option");
    assert_eq!(def, None);
}

#[test]
fn option_catalog_all_entries_have_valid_types() {
    let valid_types = ["number", "boolean", "choice", "string"];
    for def in crate::server::option_catalog::OPTION_CATALOG {
        assert!(
            valid_types.contains(&def.option_type),
            "option '{}' has invalid type '{}' (expected one of {:?})",
            def.name,
            def.option_type,
            valid_types
        );
    }
}

#[test]
fn option_catalog_all_entries_have_valid_scopes() {
    let valid_scopes = ["server", "session", "window", "pane"];
    for def in crate::server::option_catalog::OPTION_CATALOG {
        assert!(
            valid_scopes.contains(&def.scope),
            "option '{}' has invalid scope '{}' (expected one of {:?})",
            def.name,
            def.scope,
            valid_scopes
        );
    }
}

#[test]
fn option_catalog_no_duplicate_names() {
    let mut seen = std::collections::HashSet::new();
    for def in crate::server::option_catalog::OPTION_CATALOG {
        assert!(
            seen.insert(def.name),
            "duplicate option name in catalog: '{}'",
            def.name
        );
    }
}

#[test]
fn option_catalog_default_for_base_index() {
    assert_eq!(
        crate::server::option_catalog::default_for("base-index"),
        Some("0")
    );
}

#[test]
fn option_catalog_default_for_history_limit() {
    assert_eq!(
        crate::server::option_catalog::default_for("history-limit"),
        Some("2000")
    );
}

#[test]
fn option_catalog_default_for_remain_on_exit() {
    assert_eq!(
        crate::server::option_catalog::default_for("remain-on-exit"),
        Some("off")
    );
}

// ════════════════════════════════════════════════════════════════════════════
//  Prompt History Tests
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn prompt_history_initially_empty() {
    let app = mock_app();
    assert!(app.command_history.is_empty());
    assert_eq!(app.command_history_idx, 0);
}

#[test]
fn prompt_history_add_entries() {
    let mut app = mock_app();
    app.command_history.push("split-window".to_string());
    app.command_history.push("new-window".to_string());
    assert_eq!(app.command_history.len(), 2);
    assert_eq!(app.command_history[0], "split-window");
    assert_eq!(app.command_history[1], "new-window");
}

#[test]
fn prompt_history_index_navigation() {
    let mut app = mock_app();
    app.command_history.push("cmd1".to_string());
    app.command_history.push("cmd2".to_string());
    app.command_history.push("cmd3".to_string());
    // Simulate navigating up (towards older entries)
    app.command_history_idx = app.command_history.len();
    // Go up once
    app.command_history_idx -= 1;
    assert_eq!(app.command_history[app.command_history_idx], "cmd3");
    // Go up again
    app.command_history_idx -= 1;
    assert_eq!(app.command_history[app.command_history_idx], "cmd2");
    // Go up again
    app.command_history_idx -= 1;
    assert_eq!(app.command_history[app.command_history_idx], "cmd1");
    // Go down
    app.command_history_idx += 1;
    assert_eq!(app.command_history[app.command_history_idx], "cmd2");
}

#[test]
fn prompt_history_capped_at_100() {
    let mut app = mock_app();
    for i in 0..150 {
        app.command_history.push(format!("command-{}", i));
        if app.command_history.len() > 100 {
            app.command_history.remove(0);
        }
    }
    assert_eq!(app.command_history.len(), 100);
    // Oldest surviving entry should be command-50
    assert_eq!(app.command_history[0], "command-50");
    assert_eq!(app.command_history[99], "command-149");
}

#[test]
fn prompt_history_vi_mode_default_insert() {
    let app = mock_app();
    assert!(
        !app.command_vi_normal,
        "command prompt should start in insert mode"
    );
}

// ════════════════════════════════════════════════════════════════════════════
//  Wrap-search Tests (copy mode search_next / search_prev)
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn search_next_wraps_by_default() {
    let mut app = mock_app();
    // Manually populate search state
    app.copy_search_matches = vec![(0, 5, 8), (1, 10, 13), (2, 0, 3)];
    app.copy_search_idx = 2; // at last match
    crate::copy_mode::search_next(&mut app);
    // Should wrap to index 0
    assert_eq!(app.copy_search_idx, 0);
    assert_eq!(app.copy_pos, Some((0, 5)));
}

#[test]
fn search_next_does_not_wrap_when_off() {
    let mut app = mock_app();
    app.user_options
        .insert("wrap-search".to_string(), "off".to_string());
    app.copy_search_matches = vec![(0, 5, 8), (1, 10, 13), (2, 0, 3)];
    app.copy_search_idx = 2; // at last match
    crate::copy_mode::search_next(&mut app);
    // Should NOT wrap; stays at index 2
    assert_eq!(app.copy_search_idx, 2);
}

#[test]
fn search_next_advances_normally() {
    let mut app = mock_app();
    app.copy_search_matches = vec![(0, 5, 8), (1, 10, 13), (2, 0, 3)];
    app.copy_search_idx = 0;
    crate::copy_mode::search_next(&mut app);
    assert_eq!(app.copy_search_idx, 1);
    assert_eq!(app.copy_pos, Some((1, 10)));
}

#[test]
fn search_prev_wraps_by_default() {
    let mut app = mock_app();
    app.copy_search_matches = vec![(0, 5, 8), (1, 10, 13), (2, 0, 3)];
    app.copy_search_idx = 0; // at first match
    crate::copy_mode::search_prev(&mut app);
    // Should wrap to last index
    assert_eq!(app.copy_search_idx, 2);
    assert_eq!(app.copy_pos, Some((2, 0)));
}

#[test]
fn search_prev_does_not_wrap_when_off() {
    let mut app = mock_app();
    app.user_options
        .insert("wrap-search".to_string(), "off".to_string());
    app.copy_search_matches = vec![(0, 5, 8), (1, 10, 13), (2, 0, 3)];
    app.copy_search_idx = 0; // at first match
    crate::copy_mode::search_prev(&mut app);
    // Should NOT wrap; stays at index 0
    assert_eq!(app.copy_search_idx, 0);
}

#[test]
fn search_prev_retreats_normally() {
    let mut app = mock_app();
    app.copy_search_matches = vec![(0, 5, 8), (1, 10, 13), (2, 0, 3)];
    app.copy_search_idx = 2;
    crate::copy_mode::search_prev(&mut app);
    assert_eq!(app.copy_search_idx, 1);
    assert_eq!(app.copy_pos, Some((1, 10)));
}

#[test]
fn search_next_no_op_on_empty_matches() {
    let mut app = mock_app();
    app.copy_search_matches = vec![];
    app.copy_search_idx = 0;
    crate::copy_mode::search_next(&mut app);
    assert_eq!(app.copy_search_idx, 0);
    assert_eq!(app.copy_pos, None);
}

#[test]
fn search_prev_no_op_on_empty_matches() {
    let mut app = mock_app();
    app.copy_search_matches = vec![];
    app.copy_search_idx = 0;
    crate::copy_mode::search_prev(&mut app);
    assert_eq!(app.copy_search_idx, 0);
    assert_eq!(app.copy_pos, None);
}

#[test]
fn search_next_single_match_wraps_to_self() {
    let mut app = mock_app();
    app.copy_search_matches = vec![(5, 10, 15)];
    app.copy_search_idx = 0;
    crate::copy_mode::search_next(&mut app);
    // Only one match, wraps to itself
    assert_eq!(app.copy_search_idx, 0);
    assert_eq!(app.copy_pos, Some((5, 10)));
}

#[test]
fn search_prev_single_match_wraps_to_self() {
    let mut app = mock_app();
    app.copy_search_matches = vec![(5, 10, 15)];
    app.copy_search_idx = 0;
    crate::copy_mode::search_prev(&mut app);
    // Only one match, wraps to itself (last index = 0)
    assert_eq!(app.copy_search_idx, 0);
    assert_eq!(app.copy_pos, Some((5, 10)));
}

// ════════════════════════════════════════════════════════════════════════════
//  Session Group State Tests
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn session_group_none_by_default() {
    let app = mock_app();
    assert!(app.session_group.is_none());
}

#[test]
fn session_group_can_be_set() {
    let mut app = mock_app();
    app.session_group = Some("work".to_string());
    assert_eq!(app.session_group.as_deref(), Some("work"));
}

// ════════════════════════════════════════════════════════════════════════════
//  Miscellaneous State Defaults Tests
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn session_id_is_unique() {
    let app1 = AppState::new("s1".to_string());
    let app2 = AppState::new("s2".to_string());
    assert_ne!(
        app1.session_id, app2.session_id,
        "each AppState should get a unique session_id"
    );
}

#[test]
fn paste_buffers_initially_empty() {
    let app = mock_app();
    assert!(app.paste_buffers.is_empty());
}

#[test]
fn named_registers_initially_empty() {
    let app = mock_app();
    assert!(app.named_registers.is_empty());
}

#[test]
fn wait_channels_initially_empty() {
    let app = mock_app();
    assert!(app.wait_channels.is_empty());
}

#[test]
fn pipe_panes_initially_empty() {
    let app = mock_app();
    assert!(app.pipe_panes.is_empty());
}

#[test]
fn environment_initially_empty() {
    let app = mock_app();
    assert!(app.environment.is_empty());
}

#[test]
fn user_options_initially_empty() {
    let app = mock_app();
    assert!(app.user_options.is_empty());
}

#[test]
fn command_aliases_initially_empty() {
    let app = mock_app();
    assert!(app.command_aliases.is_empty());
}

#[test]
fn control_clients_initially_empty() {
    let app = mock_app();
    assert!(app.control_clients.is_empty());
}

#[test]
fn port_file_base_without_socket_name() {
    let app = AppState::new("mysession".to_string());
    assert_eq!(app.port_file_base(), "mysession");
}

#[test]
fn port_file_base_with_socket_name() {
    let mut app = AppState::new("mysession".to_string());
    app.socket_name = Some("custom".to_string());
    assert_eq!(app.port_file_base(), "custom__mysession");
}
