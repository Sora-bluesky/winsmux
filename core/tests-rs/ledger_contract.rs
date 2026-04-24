#[path = "../src/manifest_contract.rs"]
mod manifest_contract;

#[path = "../src/event_contract.rs"]
mod event_contract;

#[path = "../src/ledger.rs"]
mod ledger;

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const MANIFEST_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/manifest.yaml");
const EVENTS_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/events.jsonl");

#[test]
fn ledger_contract_loads_frozen_manifest_and_events() {
    let snapshot =
        ledger::LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE)
            .expect("ledger snapshot should load frozen fixtures");

    assert_eq!(snapshot.session_name(), "winsmux-orchestra");
    assert_eq!(snapshot.pane_count(), 2);
    assert_eq!(
        snapshot.pane_labels(),
        vec!["builder-1".to_string(), "reviewer-1".to_string()]
    );
    assert_eq!(snapshot.event_count(), 5);
    assert_eq!(snapshot.events_for_pane("%2").len(), 2);
    assert_eq!(
        snapshot.unknown_event_pane_ids(),
        vec!["%7".to_string(), "%9".to_string()]
    );
}

#[test]
fn ledger_contract_exposes_ordered_pane_read_models() {
    let snapshot =
        ledger::LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE)
            .expect("ledger snapshot should load frozen fixtures");

    let panes = snapshot.pane_read_models();

    assert_eq!(panes.len(), 2);
    assert_eq!(panes[0].label, "builder-1");
    assert_eq!(panes[0].pane_id, "%2");
    assert_eq!(panes[0].role, "Builder");
    assert_eq!(panes[0].state, "idle");
    assert_eq!(panes[0].task_id, "task-256");
    assert_eq!(panes[0].task_state, "in_progress");
    assert_eq!(panes[0].review_state, "PENDING");
    assert_eq!(panes[0].priority, "P0");
    assert_eq!(panes[0].branch, "worktree-builder-1");
    assert_eq!(panes[0].head_sha, "abc1234def5678");
    assert_eq!(panes[0].changed_file_count, 1);
    assert_eq!(panes[0].last_event, "operator.review_requested");
    assert_eq!(panes[0].event_count, 2);
    assert_eq!(panes[1].label, "reviewer-1");
    assert_eq!(panes[1].event_count, 0);
}

#[test]
fn ledger_contract_derives_board_summary_from_manifest_panes() {
    let snapshot =
        ledger::LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE)
            .expect("ledger snapshot should load frozen fixtures");

    let summary = snapshot.board_summary();

    assert_eq!(summary.pane_count, 2);
    assert_eq!(summary.dirty_panes, 1);
    assert_eq!(summary.review_pending, 1);
    assert_eq!(summary.review_failed, 0);
    assert_eq!(summary.review_passed, 0);
    assert_eq!(summary.tasks_in_progress, 1);
    assert_eq!(summary.tasks_blocked, 0);
    assert_eq!(summary.by_state["idle"], 2);
    assert_eq!(summary.by_review["PENDING"], 1);
    assert_eq!(summary.by_review["unknown"], 1);
    assert_eq!(summary.by_task_state["in_progress"], 1);
    assert_eq!(summary.by_task_state["backlog"], 1);
}

#[test]
fn ledger_contract_exposes_board_projection_in_manifest_order() {
    let snapshot =
        ledger::LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE)
            .expect("ledger snapshot should load frozen fixtures");

    let board = snapshot.board_projection();

    assert_eq!(board.summary.pane_count, 2);
    assert_eq!(board.summary.review_pending, 1);
    assert_eq!(board.summary.tasks_in_progress, 1);
    assert_eq!(board.panes.len(), 2);
    assert_eq!(board.panes[0].label, "builder-1");
    assert_eq!(board.panes[0].pane_id, "%2");
    assert_eq!(board.panes[0].role, "Builder");
    assert_eq!(board.panes[0].state, "idle");
    assert_eq!(board.panes[0].task_id, "task-256");
    assert_eq!(board.panes[0].task, "Implement run ledger");
    assert_eq!(board.panes[0].task_state, "in_progress");
    assert_eq!(board.panes[0].review_state, "PENDING");
    assert_eq!(board.panes[0].branch, "worktree-builder-1");
    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
    assert_eq!(board.panes[0].head_sha, "abc1234def5678");
    assert_eq!(board.panes[0].changed_file_count, 1);
    assert_eq!(board.panes[0].last_event_at, "__LAST_EVENT_AT__");
    assert_eq!(board.panes[1].label, "reviewer-1");
}

#[test]
fn ledger_contract_exposes_inbox_projection_from_manifest_and_events() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-23T12:00:00+09:00
  worker-1:
    pane_id: "%6"
    role: Worker
    state: idle
    task_id: task-999
    task: Fix blocker
    task_state: blocked
    branch: worktree-worker-1
    head_sha: def5678abc1234
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"approval prompt detected","label":"builder-1","pane_id":"%2","role":"Builder","status":"approval_waiting","data":{"task_id":"task-245"}}
{"timestamp":"2026-04-23T12:00:02+09:00","session":"winsmux-orchestra","event":"operator.commit_ready","message":"ready to commit","label":"","pane_id":"","role":"Operator","status":"commit_ready","head_sha":"abc1234def5678","data":{}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load inbox inputs");

    let inbox = snapshot.inbox_projection();

    assert_eq!(inbox.summary.item_count, 4);
    assert_eq!(inbox.summary.by_kind["task_blocked"], 1);
    assert_eq!(inbox.summary.by_kind["review_pending"], 1);
    assert_eq!(inbox.summary.by_kind["approval_waiting"], 1);
    assert_eq!(inbox.summary.by_kind["commit_ready"], 1);
    assert_eq!(inbox.items[0].kind, "task_blocked");
    assert_eq!(inbox.items[0].priority, 0);
    assert_eq!(inbox.items[0].label, "worker-1");
    assert_eq!(inbox.items[0].pane_id, "%6");
    assert_eq!(inbox.items[0].role, "Worker");
    assert_eq!(inbox.items[0].task_id, "task-999");
    assert_eq!(inbox.items[0].task, "Fix blocker");
    assert_eq!(inbox.items[0].source, "manifest");
    assert_eq!(inbox.items[1].kind, "approval_waiting");
    assert_eq!(inbox.items[1].event, "approval_waiting");
    assert_eq!(inbox.items[1].task_id, "task-245");
    assert_eq!(inbox.items[1].source, "events");
    assert_eq!(inbox.items[2].kind, "review_pending");
    assert_eq!(inbox.items[2].event, "review.requested");
    assert_eq!(inbox.items[3].kind, "commit_ready");
    assert_eq!(inbox.items[3].head_sha, "abc1234def5678");
}

#[test]
fn ledger_contract_uses_latest_event_per_inbox_entity() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"old approval","label":"builder-1","pane_id":"%2","role":"Builder","status":"approval_waiting","data":{"task_id":"task-old"}}
{"timestamp":"2026-04-23T12:00:02+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"new approval","label":"builder-1","pane_id":"%2","role":"Builder","status":"approval_waiting","data":{"task_id":"task-new"}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load repeated inbox events");

    let inbox = snapshot.inbox_projection();

    assert_eq!(inbox.summary.item_count, 1);
    assert_eq!(inbox.items[0].message, "new approval");
    assert_eq!(inbox.items[0].task_id, "task-new");
}

#[test]
fn ledger_contract_classifies_inbox_actionable_event_taxonomy() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
  builder-2:
    pane_id: "%3"
    role: Builder
  builder-3:
    pane_id: "%4"
    role: Builder
  builder-4:
    pane_id: "%5"
    role: Builder
  builder-5:
    pane_id: "%6"
    role: Builder
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pane.idle","message":"idle","label":"builder-1","pane_id":"%2","role":"Builder","data":{}}
{"timestamp":"2026-04-23T12:00:02+09:00","session":"winsmux-orchestra","event":"pane.completed","message":"completed","label":"builder-2","pane_id":"%3","role":"Builder","data":{}}
{"timestamp":"2026-04-23T12:00:03+09:00","session":"winsmux-orchestra","event":"pane.crashed","message":"crashed","label":"builder-3","pane_id":"%4","role":"Builder","data":{}}
{"timestamp":"2026-04-23T12:00:04+09:00","session":"winsmux-orchestra","event":"pane.hung","message":"hung","label":"builder-4","pane_id":"%5","role":"Builder","data":{}}
{"timestamp":"2026-04-23T12:00:05+09:00","session":"winsmux-orchestra","event":"operator.state_transition","message":"blocked","label":"","pane_id":"","role":"Operator","status":"blocked_no_review_target","data":{}}
{"timestamp":"2026-04-23T12:00:06+09:00","session":"winsmux-orchestra","event":"pane.stalled","message":"stalled","label":"builder-5","pane_id":"%6","role":"Builder","data":{}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load inbox taxonomy events");

    let inbox = snapshot.inbox_projection();

    assert_eq!(inbox.summary.by_kind["dispatch_needed"], 1);
    assert_eq!(inbox.summary.by_kind["task_completed"], 1);
    assert_eq!(inbox.summary.by_kind["crashed"], 1);
    assert_eq!(inbox.summary.by_kind["hung"], 1);
    assert_eq!(inbox.summary.by_kind["blocked"], 1);
    assert_eq!(inbox.summary.by_kind["stalled"], 1);
}

#[test]
fn ledger_contract_filters_inbox_after_latest_event_deduplication() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"old approval","label":"builder-1","pane_id":"%2","role":"Builder","status":"approval_waiting","data":{"task_id":"task-old"}}
{"timestamp":"2026-04-23T12:00:02+09:00","session":"winsmux-orchestra","event":"pane.output","message":"normal output","label":"builder-1","pane_id":"%2","role":"Builder","data":{}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load deduplication events");

    let inbox = snapshot.inbox_projection();

    assert_eq!(inbox.summary.item_count, 0);
    assert!(inbox.items.is_empty());
}

#[test]
fn ledger_contract_exposes_digest_projection_from_manifest_and_inbox_items() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    task_id: task-246
    task: Build evidence digest
    task_state: blocked
    review_state: FAIL
    provider_target: codex:gpt-5.4
    branch: worktree-builder-1
    launch_dir: .worktrees/builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_failed
    last_event_at: 2026-04-23T12:00:00+09:00
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"approval prompt detected","label":"builder-1","pane_id":"%2","role":"Builder","status":"approval_waiting","data":{"task_id":"task-246"}}
{"timestamp":"2026-04-23T12:00:02+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"verification passed","data":{"task_id":"task-246","hypothesis":"result summary should appear in digest","confidence":0.88,"observation_pack_ref":"observations/task-246.json","consultation_ref":"consultations/task-246.json","verification_result":{"outcome":"PASS"}}}
{"timestamp":"2026-04-23T12:00:03+09:00","session":"winsmux-orchestra","event":"pipeline.security.allowed","message":"security allowed","data":{"task_id":"task-246","verdict":"ALLOW"}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load digest inputs");

    let digest = snapshot.digest_projection();

    assert_eq!(digest.summary.item_count, 1);
    assert_eq!(digest.summary.dirty_items, 1);
    assert_eq!(digest.summary.review_failed, 1);
    assert_eq!(digest.summary.actionable_items, 1);
    assert_eq!(digest.items[0].run_id, "task:task-246");
    assert_eq!(digest.items[0].task_id, "task-246");
    assert_eq!(digest.items[0].task, "Build evidence digest");
    assert_eq!(digest.items[0].label, "builder-1");
    assert_eq!(digest.items[0].pane_id, "%2");
    assert_eq!(digest.items[0].role, "Builder");
    assert_eq!(digest.items[0].provider_target, "codex:gpt-5.4");
    assert_eq!(digest.items[0].task_state, "blocked");
    assert_eq!(digest.items[0].review_state, "FAIL");
    assert_eq!(digest.items[0].next_action, "approval_waiting");
    assert_eq!(digest.items[0].branch, "worktree-builder-1");
    assert_eq!(digest.items[0].worktree, ".worktrees/builder-1");
    assert_eq!(digest.items[0].head_short, "abc1234");
    assert_eq!(digest.items[0].changed_file_count, 1);
    assert_eq!(
        digest.items[0].changed_files,
        vec!["scripts/winsmux-core.ps1".to_string()]
    );
    assert_eq!(digest.items[0].action_item_count, 3);
    assert_eq!(digest.items[0].last_event, "operator.review_failed");
    assert_eq!(digest.items[0].verification_outcome, "PASS");
    assert_eq!(digest.items[0].security_blocked, "ALLOW");
    assert_eq!(
        digest.items[0].hypothesis,
        "result summary should appear in digest"
    );
    assert_eq!(digest.items[0].confidence, Some(0.88));
    assert_eq!(
        digest.items[0].observation_pack_ref,
        "observations/task-246.json"
    );
    assert_eq!(
        digest.items[0].consultation_ref,
        "consultations/task-246.json"
    );
}

#[test]
fn ledger_contract_exposes_explain_projection_from_digest_and_events() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    tokens_remaining: 64% context left
    task_id: task-256
    parent_run_id: operator:session-1
    goal: Ship run contract primitives
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    review_state: PENDING
    priority: P0
    blocking: true
    branch: worktree-builder-1
    security_policy: '{"mode":"blocklist","allow_patterns":["Invoke-Pester"],"block_patterns":["git reset --hard"]}'
    launch_dir: .worktrees/builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    write_scope: '["scripts/winsmux-core.ps1"]'
    read_scope: '["tests/winsmux-bridge.Tests.ps1"]'
    constraints: '["avoid destructive git"]'
    expected_output: Ledger projection
    verification_plan: '["cargo test --test ledger_contract"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: builder
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: pane.started
    last_event_at: 2026-04-23T12:00:00+09:00
  reviewer-1:
    pane_id: "%3"
    role: Reviewer
    state: idle
    task_id: task-256
    task: Review run ledger
    task_state: in_progress
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"approval prompt detected","label":"builder-1","pane_id":"%2","role":"Builder","status":"approval_waiting","data":{"task_id":"task-256"}}
{"timestamp":"2026-04-23T12:00:02+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"verification passed","data":{"task_id":"task-256","verification_contract":{"command":"cargo test"},"verification_result":{"outcome":"PASS"}}}
{"timestamp":"2026-04-23T12:00:03+09:00","session":"winsmux-orchestra","event":"pipeline.security.allowed","message":"security allowed","data":{"task_id":"task-256","verdict":"ALLOW"}}
{"timestamp":"2026-04-23T12:00:04+09:00","session":"winsmux-orchestra","event":"pane.consult_result","message":"experiment result","label":"builder-1","pane_id":"%2","role":"Builder","data":{"task_id":"task-256","hypothesis":"projection can explain the run","test_plan":["load manifest","match events"],"result":"explain payload built","confidence":0.66,"next_action":"approval_waiting","observation_pack_ref":"observations/task-256.json","consultation_ref":"consultations/task-256.json","run_id":"task:task-256","slot":"builder-1","worktree":".worktrees/builder-1","env_fingerprint":"env-123","command_hash":"cmd-456","observation_pack":{"summary":"ok"},"consultation_packet":{"review":"ok"}}}
{"timestamp":"2026-04-23T12:00:05+09:00","session":"winsmux-orchestra","event":"pane.consult_request","message":"new action only","label":"builder-1","pane_id":"%2","role":"Builder","data":{"task_id":"task-256","next_action":"review_requested"}}
{"timestamp":"2026-04-23T12:00:06+09:00","session":"winsmux-orchestra","event":"pane.completed","message":"reviewer finished","label":"reviewer-1","pane_id":"%3","role":"Reviewer","data":{}}
{"timestamp":"2026-04-23T12:00:07+09:00","session":"winsmux-orchestra","event":"pipeline.verify.fail","message":"other task failed","data":{"task_id":"task-other","branch":"worktree-builder-1","verification_result":{"outcome":"FAIL"}}}
{"timestamp":"2026-04-23T12:00:08+09:00","session":"winsmux-orchestra","event":"operator.commit_ready","message":"other task ready","data":{"task_id":"task-other","branch":"worktree-builder-1"}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load explain inputs");

    let explain = snapshot
        .explain_projection("task:task-256")
        .expect("ledger explain projection should exist");

    assert_eq!(explain.run.run_id, "task:task-256");
    assert_eq!(explain.run.goal, "Ship run contract primitives");
    assert_eq!(explain.run.tokens_remaining, "64% context left");
    assert!(explain.run.blocking);
    assert!(explain.run.review_required);
    assert_eq!(explain.run.write_scope, vec!["scripts/winsmux-core.ps1"]);
    assert_eq!(explain.run.pane_count, 2);
    assert_eq!(explain.run.labels, vec!["builder-1", "reviewer-1"]);
    assert_eq!(explain.run.experiment_packet.confidence, Some(0.66));
    assert_eq!(
        explain.run.experiment_packet.next_action,
        "review_requested"
    );
    assert_eq!(
        explain.run.experiment_packet.result,
        "explain payload built"
    );
    assert!(explain
        .run
        .action_items
        .iter()
        .any(|item| item.kind == "task_completed" && item.source == "events"));
    assert!(!explain
        .run
        .action_items
        .iter()
        .any(|item| item.message == "other task ready"));
    assert_eq!(explain.run.experiment_packet.branch, "worktree-builder-1");
    assert_eq!(explain.evidence_digest.verification_outcome, "PASS");
    assert_eq!(explain.evidence_digest.security_blocked, "ALLOW");
    assert_eq!(explain.explanation.summary, "Ship run contract primitives");
    assert_eq!(explain.explanation.next_action, "review_requested");
    assert!(explain
        .explanation
        .reasons
        .iter()
        .any(|reason| reason == "last_event=pane.started"));
    assert_eq!(explain.recent_events[0].label, "reviewer-1");
    assert!(!explain
        .recent_events
        .iter()
        .any(|event| event.task_id == "task-other"));
    assert_eq!(
        explain.run.security_policy["block_patterns"][0],
        "git reset --hard"
    );
    assert_eq!(explain.run.verification_result["outcome"], "PASS");
    assert_eq!(explain.run.security_verdict, "ALLOW");
}

#[test]
fn ledger_contract_returns_none_for_unknown_explain_run() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    task_id: task-known
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load minimal explain inputs");

    assert!(snapshot.explain_projection("task:missing").is_none());
}

#[test]
fn ledger_contract_sorts_digest_projection_by_latest_event_time() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  older:
    pane_id: "%2"
    role: Builder
    task_id: task-older
    task_state: in_progress
    last_event_at: 2026-04-23T12:00:00+09:00
  newer:
    pane_id: "%3"
    role: Builder
    task_id: task-newer
    task_state: in_progress
    last_event_at: 2026-04-23T12:00:02+09:00
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load digest ordering inputs");

    let digest = snapshot.digest_projection();

    assert_eq!(digest.items[0].run_id, "task:task-newer");
    assert_eq!(digest.items[1].run_id, "task:task-older");
}

#[test]
fn ledger_contract_groups_digest_projection_by_run() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    label: builder-1
    task_id: task-shared
    task: Shared run
    task_state: in_progress
    branch: worktree-shared
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event_at: 2026-04-23T12:00:01+09:00
  reviewer-1:
    pane_id: "%3"
    role: Reviewer
    label: reviewer-1
    task_id: task-shared
    task: Shared run
    task_state: in_progress
    branch: worktree-shared
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["core/src/ledger.rs","scripts/winsmux-core.ps1"]'
    last_event_at: 2026-04-23T12:00:02+09:00
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:03+09:00","session":"winsmux-orchestra","event":"operator.commit_ready","message":"commit is ready","branch":"worktree-shared","data":{}}
{"timestamp":"2026-04-23T12:00:04+09:00","session":"winsmux-orchestra","event":"pane.approval_waiting","message":"approval prompt detected","head_sha":"abc1234def5678","status":"approval_waiting","data":{}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load grouped digest inputs");

    let digest = snapshot.digest_projection();

    assert_eq!(digest.summary.item_count, 1);
    assert_eq!(digest.items[0].run_id, "task:task-shared");
    assert_eq!(digest.items[0].changed_file_count, 3);
    assert_eq!(
        digest.items[0].changed_files,
        vec![
            "scripts/winsmux-core.ps1".to_string(),
            "core/src/ledger.rs".to_string()
        ]
    );
    assert_eq!(digest.items[0].action_item_count, 2);
    assert_eq!(digest.items[0].next_action, "approval_waiting");
}

#[test]
fn ledger_contract_gates_digest_verification_and_security_events_by_kind() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    task_id: task-guarded
    task_state: in_progress
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"operator.review_requested","message":"review requested","data":{"task_id":"task-guarded","verification_result":{"outcome":"FAIL"},"verdict":"BLOCK"}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load gated digest inputs");

    let digest = snapshot.digest_projection();

    assert_eq!(digest.items[0].verification_outcome, "");
    assert_eq!(digest.items[0].security_blocked, "");
}

#[test]
fn ledger_contract_applies_digest_events_by_timestamp_and_overrides_worktree() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    task_id: task-sorted
    task_state: in_progress
    launch_dir: .worktrees/stale
"#;
    let events = r#"{"timestamp":"2026-04-23T12:00:03+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"new verification","data":{"task_id":"task-sorted","worktree":".worktrees/fresh","verification_result":{"outcome":"PASS"}}}
{"timestamp":"2026-04-23T12:00:01+09:00","session":"winsmux-orchestra","event":"pipeline.verify.fail","message":"old verification","data":{"task_id":"task-sorted","worktree":".worktrees/old","verification_result":{"outcome":"FAIL"}}}
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, events)
        .expect("ledger snapshot should load timestamped digest inputs");

    let digest = snapshot.digest_projection();

    assert_eq!(digest.items[0].worktree, ".worktrees/fresh");
    assert_eq!(digest.items[0].verification_outcome, "PASS");
}

#[test]
fn ledger_contract_derives_board_worktree_from_legacy_path_fields() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    builder_worktree_path: C:\repo\.worktrees\builder-1
    launch_dir: C:\repo
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load legacy path fields");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
}

#[test]
fn ledger_contract_prefers_rebound_launch_dir_for_board_worktree() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    builder_worktree_path: C:\repo\.worktrees\builder-1
    launch_dir: C:\repo\.worktrees\builder-2
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load rebound launch_dir");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-2");
}

#[test]
fn ledger_contract_derives_board_worktree_from_branch_label_fallback() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    branch: worktree-builder-1
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load branch label fallback");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
}

#[test]
fn ledger_contract_uses_live_project_dir_when_manifest_omits_project_dir() {
    let fixture = TempProject::new("project-dir-fallback");
    let root = fixture.path_string();
    let manifest = format!(
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    launch_dir: {root}
    builder_worktree_path: {root}/.worktrees/builder-1
"#
    );
    fixture.write_winsmux_file("manifest.yaml", &manifest);
    fs::create_dir_all(fixture.path().join(".worktrees").join("builder-1"))
        .expect("temp builder worktree dir should be created");

    let snapshot = ledger::LedgerSnapshot::from_project_dir(fixture.path())
        .expect("ledger snapshot should use live project dir fallback");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
}

#[test]
fn ledger_contract_does_not_assign_branch_label_worktree_to_reviewer() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  reviewer-1:
    pane_id: "%2"
    role: Reviewer
    state: idle
    branch: worktree-reviewer-1
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load reviewer branch");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, "");
}

#[test]
fn ledger_contract_ignores_stale_worker_paths_on_reviewer() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  reviewer-1:
    pane_id: "%2"
    role: Reviewer
    state: idle
    launch_dir: C:\repo\.worktrees\worker-1
    builder_worktree_path: C:\repo\.worktrees\worker-1
    branch: worktree-worker-1
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should ignore stale reviewer paths");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, "");
}

#[test]
fn ledger_contract_ignores_stale_explicit_worktree_on_reviewer() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  reviewer-1:
    pane_id: "%2"
    role: Reviewer
    state: idle
    worktree: .worktrees\worker-1
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should ignore stale explicit reviewer worktree");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, "");
}

#[test]
fn ledger_contract_uses_status_as_state_fallback() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    status: ready
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should use status as state fallback");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].state, "ready");
    assert_eq!(board.summary.by_state["ready"], 1);
}

#[test]
fn ledger_contract_prefers_current_paths_over_stale_explicit_worktree() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    worktree: .worktrees\builder-1
    launch_dir: C:\repo\.worktrees\builder-9
    builder_worktree_path: C:\repo\.worktrees\builder-9
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should prefer current path fields");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-9");
}

#[test]
fn ledger_contract_counts_lowercase_review_states() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  pending:
    pane_id: "%2"
    role: Builder
    review_state: pending
    branch: worktree-builder-1
    head_sha: abc1234def5678
  pass:
    pane_id: "%3"
    role: Reviewer
    review_state: pass
    branch: worktree-reviewer-1
    head_sha: def5678abc1234
  fail:
    pane_id: "%4"
    role: Reviewer
    review_state: fail
    branch: worktree-reviewer-2
    head_sha: 1234def5678abc
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should load lowercase review states");

    let summary = snapshot.board_summary();

    assert_eq!(summary.review_pending, 1);
    assert_eq!(summary.review_passed, 1);
    assert_eq!(summary.review_failed, 1);
}

#[test]
fn ledger_contract_rejects_duplicate_manifest_pane_id() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
  reviewer-1:
    pane_id: "%2"
    role: Reviewer
"#;

    let err = ledger::LedgerSnapshot::from_manifest_and_events(manifest, EVENTS_FIXTURE)
        .expect_err("duplicate manifest pane_id must be rejected");

    assert!(err.contains("duplicate manifest pane_id '%2'"));
}

#[test]
fn ledger_contract_loads_live_winsmux_files() {
    let fixture = TempProject::new("live-files");
    fixture.write_winsmux_file("manifest.yaml", MANIFEST_FIXTURE);
    fixture.write_winsmux_file("events.jsonl", EVENTS_FIXTURE);

    let snapshot = ledger::LedgerSnapshot::from_project_dir(fixture.path())
        .expect("ledger snapshot should load live .winsmux files");

    assert_eq!(snapshot.session_name(), "winsmux-orchestra");
    assert_eq!(snapshot.pane_count(), 2);
    assert_eq!(snapshot.event_count(), 5);
}

#[test]
fn ledger_contract_allows_missing_live_events_file() {
    let fixture = TempProject::new("missing-events");
    fixture.write_winsmux_file("manifest.yaml", MANIFEST_FIXTURE);

    let snapshot = ledger::LedgerSnapshot::from_project_dir(fixture.path())
        .expect("missing events.jsonl should be treated as an empty event stream");

    assert_eq!(snapshot.session_name(), "winsmux-orchestra");
    assert_eq!(snapshot.event_count(), 0);
}

#[test]
fn ledger_contract_relativizes_live_paths_loaded_from_relative_manifest_path() {
    let fixture = TempProject::new_under_current("relative-manifest");
    let root = fixture.path_string();
    let manifest = format!(
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    launch_dir: {root}
    builder_worktree_path: {root}/.worktrees/builder-1
"#
    );
    fixture.write_winsmux_file("manifest.yaml", &manifest);
    fixture.write_winsmux_file("events.jsonl", "");

    let current_dir = std::env::current_dir().expect("current dir should be available");
    let manifest_path = fixture
        .root
        .join(".winsmux")
        .join("manifest.yaml")
        .strip_prefix(&current_dir)
        .expect("fixture should be under current dir")
        .to_path_buf();
    let events_path = fixture
        .root
        .join(".winsmux")
        .join("events.jsonl")
        .strip_prefix(&current_dir)
        .expect("fixture should be under current dir")
        .to_path_buf();

    let snapshot = ledger::LedgerSnapshot::from_paths(manifest_path, events_path)
        .expect("ledger snapshot should load relative manifest path");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
}

#[test]
fn ledger_contract_relativizes_extended_windows_paths() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: \\?\C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    launch_dir: \\?\C:\repo\.worktrees\builder-1
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should relativize extended paths");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
}

#[test]
fn ledger_contract_relativizes_drive_root_project_paths() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: idle
    launch_dir: C:\.worktrees\builder-1
"#;

    let snapshot = ledger::LedgerSnapshot::from_manifest_and_events(manifest, "")
        .expect("ledger snapshot should relativize drive root paths");

    let board = snapshot.board_projection();

    assert_eq!(board.panes[0].worktree, ".worktrees/builder-1");
}

struct TempProject {
    root: PathBuf,
}

impl TempProject {
    fn new(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "winsmux-ledger-contract-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(root.join(".winsmux")).expect("temp .winsmux dir should be created");
        Self { root }
    }

    fn new_under_current(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos();
        let root = std::env::current_dir()
            .expect("current dir should be available")
            .join("target")
            .join("ledger-contract")
            .join(format!("{label}-{}-{unique}", std::process::id()));
        fs::create_dir_all(root.join(".winsmux")).expect("temp .winsmux dir should be created");
        Self { root }
    }

    fn path(&self) -> &std::path::Path {
        &self.root
    }

    fn path_string(&self) -> String {
        self.root.to_string_lossy().replace('\\', "/")
    }

    fn write_winsmux_file(&self, name: &str, content: &str) {
        fs::write(self.root.join(".winsmux").join(name), content)
            .expect("temp winsmux file should be written");
    }
}

impl Drop for TempProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
