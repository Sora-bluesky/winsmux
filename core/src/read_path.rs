use std::{
    fs, io,
    path::{Path, PathBuf},
};

use chrono::{SecondsFormat, Utc};
use serde::Serialize;
use serde_json::{json, Value};

use crate::ledger::{
    LedgerBoardPayload, LedgerDigestItem, LedgerDigestPayload, LedgerExplainPayload,
    LedgerExplainProjection, LedgerInboxPayload, LedgerRunsPayload, LedgerSnapshot,
    LedgerStatusPayload,
};

pub fn load_snapshot(project_dir: &Path) -> io::Result<LedgerSnapshot> {
    LedgerSnapshot::from_project_dir(project_dir).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to load winsmux ledger: {err}"),
        )
    })
}

pub fn payload_to_value<T: Serialize>(value: &T) -> io::Result<Value> {
    serde_json::to_value(value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize Rust operator projection: {err}"),
        )
    })
}

pub fn enveloped_payload<T: Serialize>(project_dir: &Path, value: T) -> io::Result<Value> {
    let value = payload_to_value(&value)?;
    let payload = json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "summary": value.get("summary").cloned().unwrap_or(Value::Null),
        "panes": value.get("panes").cloned().unwrap_or(Value::Null),
        "items": value.get("items").cloned().unwrap_or(Value::Null),
    });
    Ok(strip_null_fields(payload))
}

pub fn desktop_summary_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> io::Result<Value> {
    let board = desktop_board_payload(snapshot, project_dir);
    let inbox = enveloped_payload(project_dir, snapshot.inbox_projection())?;
    let digest = snapshot.digest_projection();
    let run_projections: Vec<_> = digest
        .items
        .iter()
        .map(|item| desktop_run_projection(snapshot, item))
        .collect();
    let digest = enveloped_payload(project_dir, digest)?;

    Ok(json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "board": board,
        "inbox": inbox,
        "digest": digest,
        "run_projections": run_projections,
    }))
}

pub fn status_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> LedgerStatusPayload {
    LedgerStatusPayload::from_snapshot(generated_at(), project_dir_string(project_dir), snapshot)
}

pub fn board_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> LedgerBoardPayload {
    LedgerBoardPayload::from_projection(
        generated_at(),
        project_dir_string(project_dir),
        snapshot.board_projection(),
    )
}

pub fn inbox_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> LedgerInboxPayload {
    LedgerInboxPayload::from_projection(
        generated_at(),
        project_dir_string(project_dir),
        snapshot.inbox_projection(),
    )
}

pub fn digest_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> LedgerDigestPayload {
    LedgerDigestPayload::from_projection(
        generated_at(),
        project_dir_string(project_dir),
        snapshot.digest_projection(),
    )
}

pub fn runs_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> LedgerRunsPayload {
    LedgerRunsPayload::from_snapshot(generated_at(), project_dir_string(project_dir), snapshot)
}

pub fn explain_payload(
    snapshot: &LedgerSnapshot,
    project_dir: &Path,
    run_id: &str,
) -> io::Result<LedgerExplainPayload> {
    let projection = snapshot.explain_projection(run_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {run_id}"))
    })?;
    let observation_pack = read_artifact_json(
        &projection.run.experiment_packet.observation_pack_ref,
        project_dir,
        &[".winsmux", "observation-packs"],
        run_id,
    );
    let consultation_packet = read_artifact_json(
        &projection.run.experiment_packet.consultation_ref,
        project_dir,
        &[".winsmux", "consultations"],
        run_id,
    );
    Ok(LedgerExplainPayload::from_projection(
        generated_at(),
        project_dir_string(project_dir),
        projection,
        observation_pack,
        consultation_packet,
        Value::Null,
    ))
}

pub fn compare_run_projections(
    snapshot: &LedgerSnapshot,
    left_id: &str,
    right_id: &str,
) -> io::Result<(LedgerExplainProjection, LedgerExplainProjection)> {
    let left = snapshot.explain_projection(left_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {left_id}"))
    })?;
    let right = snapshot.explain_projection(right_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("run not found: {right_id}"),
        )
    })?;
    Ok((left, right))
}

pub fn read_artifact_json(
    reference: &str,
    project_dir: &Path,
    expected_segments: &[&str],
    expected_run_id: &str,
) -> Value {
    if reference.trim().is_empty() {
        return Value::Null;
    }

    let mut expected_dir = project_dir.to_path_buf();
    for segment in expected_segments {
        expected_dir.push(segment);
    }

    let path = {
        let normalized = reference.replace('/', std::path::MAIN_SEPARATOR_STR);
        let candidate = PathBuf::from(&normalized);
        if candidate.is_absolute() {
            candidate
        } else {
            project_dir.join(candidate)
        }
    };

    let Ok(full_path) = fs::canonicalize(&path) else {
        return Value::Null;
    };
    let Ok(expected_dir) = fs::canonicalize(expected_dir) else {
        return Value::Null;
    };
    if !full_path.starts_with(&expected_dir) {
        return Value::Null;
    }

    let Ok(content) = fs::read_to_string(&full_path) else {
        return Value::Null;
    };
    let Ok(mut parsed) = serde_json::from_str::<Value>(&content) else {
        return Value::Null;
    };

    if let Some(run_id) = parsed.get("run_id").and_then(Value::as_str) {
        if !run_id.is_empty() && run_id != expected_run_id {
            return Value::Null;
        }
    }
    if let Value::Object(map) = &mut parsed {
        map.remove("packet_type");
    }
    parsed
}

pub fn generated_at() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn project_dir_string(project_dir: &Path) -> String {
    project_dir.display().to_string()
}

fn desktop_board_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> Value {
    let mut panes = snapshot.pane_read_models();
    panes.sort_by(|left, right| left.label.cmp(&right.label));
    let panes: Vec<_> = panes
        .into_iter()
        .map(|pane| {
            json!({
                "label": pane.label,
                "role": pane.role,
                "pane_id": pane.pane_id,
                "state": pane.state,
                "tokens_remaining": pane.tokens_remaining,
                "task_id": pane.task_id,
                "task": pane.task,
                "task_state": pane.task_state,
                "task_owner": pane.task_owner,
                "review_state": pane.review_state,
                "branch": pane.branch,
                "worktree": pane.worktree,
                "head_sha": pane.head_sha,
                "changed_file_count": pane.changed_file_count,
                "changed_files": pane.changed_files,
                "last_event": pane.last_event,
                "last_event_at": pane.last_event_at,
                "parent_run_id": pane.parent_run_id,
                "goal": pane.goal,
                "task_type": pane.task_type,
                "priority": pane.priority,
                "blocking": pane.blocking,
                "write_scope": pane.write_scope,
                "read_scope": pane.read_scope,
                "constraints": pane.constraints,
                "expected_output": pane.expected_output,
                "verification_plan": pane.verification_plan,
                "review_required": pane.review_required,
                "provider_target": pane.provider_target,
                "agent_role": pane.agent_role,
                "timeout_policy": pane.timeout_policy,
                "handoff_refs": pane.handoff_refs,
                "security_policy": pane.security_policy,
            })
        })
        .collect();

    json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "summary": snapshot.board_summary(),
        "panes": panes,
    })
}

fn desktop_run_projection(snapshot: &LedgerSnapshot, item: &LedgerDigestItem) -> Value {
    let explain = snapshot.explain_projection(&item.run_id);
    let run = explain.as_ref().map(|projection| &projection.run);
    let explanation = explain.as_ref().map(|projection| &projection.explanation);
    let evidence_digest = explain
        .as_ref()
        .map(|projection| &projection.evidence_digest);

    let branch = run
        .filter(|run| !run.branch.trim().is_empty())
        .map(|run| run.branch.clone())
        .unwrap_or_else(|| item.branch.clone());
    let run_worktree = run.map(|run| run.worktree.clone()).unwrap_or_default();
    let experiment_worktree = run
        .map(|run| run.experiment_packet.worktree.clone())
        .unwrap_or_default();
    let worktree =
        first_non_empty_owned([run_worktree, experiment_worktree, item.worktree.clone()]);
    let head_sha = run
        .filter(|run| !run.head_sha.trim().is_empty())
        .map(|run| run.head_sha.clone())
        .unwrap_or_else(|| item.head_sha.clone());
    let head_short = if !head_sha.trim().is_empty() {
        short_head_sha(&head_sha)
    } else {
        item.head_short.clone()
    };
    let changed_files = evidence_digest
        .filter(|digest| !digest.changed_files.is_empty())
        .map(|digest| digest.changed_files.clone())
        .unwrap_or_else(|| item.changed_files.clone());
    let summary = explanation
        .filter(|explanation| !explanation.summary.trim().is_empty())
        .map(|explanation| explanation.summary.clone())
        .unwrap_or_else(|| {
            first_non_empty_owned([
                item.task.clone(),
                format!("Projected from {}", item.run_id),
                "Projected run".to_string(),
            ])
        });

    json!({
        "run_id": item.run_id,
        "pane_id": item.pane_id,
        "label": item.label,
        "branch": branch,
        "worktree": worktree,
        "head_sha": head_sha,
        "head_short": head_short,
        "provider_target": item.provider_target,
        "task": item.task,
        "task_state": run
            .filter(|run| !run.task_state.trim().is_empty())
            .map(|run| run.task_state.clone())
            .unwrap_or_else(|| item.task_state.clone()),
        "review_state": run
            .filter(|run| !run.review_state.trim().is_empty())
            .map(|run| run.review_state.clone())
            .unwrap_or_else(|| item.review_state.clone()),
        "verification_outcome": evidence_digest
            .filter(|digest| !digest.verification_outcome.trim().is_empty())
            .map(|digest| digest.verification_outcome.clone())
            .unwrap_or_else(|| item.verification_outcome.clone()),
        "security_blocked": evidence_digest
            .filter(|digest| !digest.security_blocked.trim().is_empty())
            .map(|digest| digest.security_blocked.clone())
            .unwrap_or_else(|| item.security_blocked.clone()),
        "changed_files": changed_files,
        "next_action": explanation
            .filter(|explanation| !explanation.next_action.trim().is_empty())
            .map(|explanation| explanation.next_action.clone())
            .unwrap_or_else(|| item.next_action.clone()),
        "summary": summary,
        "reasons": explanation
            .map(|explanation| explanation.reasons.clone())
            .unwrap_or_default(),
        "hypothesis": item.hypothesis,
        "confidence": item.confidence,
        "observation_pack_ref": item.observation_pack_ref,
        "consultation_ref": item.consultation_ref,
    })
}

fn strip_null_fields(value: Value) -> Value {
    let Value::Object(mut map) = value else {
        return value;
    };
    map.retain(|_, value| !value.is_null());
    Value::Object(map)
}

fn first_non_empty_owned<const N: usize>(values: [String; N]) -> String {
    values
        .into_iter()
        .find(|value| !value.trim().is_empty())
        .unwrap_or_default()
}

fn short_head_sha(head_sha: &str) -> String {
    if head_sha.chars().count() <= 7 {
        head_sha.to_string()
    } else {
        head_sha.chars().take(7).collect()
    }
}
