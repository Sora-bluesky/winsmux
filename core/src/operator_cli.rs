use std::{
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU32, Ordering},
};

use chrono::{SecondsFormat, Utc};
use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::ledger::LedgerSnapshot;

static REVIEW_REQUEST_COUNTER: AtomicU32 = AtomicU32::new(0);

pub fn is_operator_status_invocation(args: &[&String]) -> bool {
    args.iter()
        .any(|arg| matches!(arg.as_str(), "--json" | "-h" | "--help"))
}

pub fn run_status_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux status --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("status", args, 0)?;
    require_json("status", &options)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let status = json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(&options.project_dir),
        "session": {
            "name": snapshot.session_name(),
            "pane_count": snapshot.pane_count(),
            "event_count": snapshot.event_count(),
        },
        "summary": snapshot.board_summary(),
        "panes": snapshot.pane_read_models(),
    });
    write_json(&status)
}

pub fn run_board_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux board --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("board", args, 0)?;
    require_json("board", &options)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    write_enveloped_json(&options.project_dir, snapshot.board_projection())
}

pub fn run_inbox_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux inbox --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("inbox", args, 0)?;
    require_json("inbox", &options)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    write_enveloped_json(&options.project_dir, snapshot.inbox_projection())
}

pub fn run_digest_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux digest --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("digest", args, 0)?;
    require_json("digest", &options)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    write_enveloped_json(&options.project_dir, snapshot.digest_projection())
}

pub fn run_runs_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux runs --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("runs", args, 0)?;
    require_json("runs", &options)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = runs_payload(&snapshot, &options.project_dir);
    write_json(&payload)
}

pub fn run_explain_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux explain <run_id> --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("explain", args, 1)?;
    require_json("explain", &options)?;

    let run_id = options.positionals[0].clone();
    let snapshot = load_snapshot(&options.project_dir)?;
    let projection = snapshot.explain_projection(&run_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {run_id}"))
    })?;
    let observation_pack = read_artifact_json(
        &projection.run.experiment_packet.observation_pack_ref,
        &options.project_dir,
        &[".winsmux", "observation-packs"],
        &run_id,
    );
    let consultation_packet = read_artifact_json(
        &projection.run.experiment_packet.consultation_ref,
        &options.project_dir,
        &[".winsmux", "consultations"],
        &run_id,
    );
    let payload = json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(&options.project_dir),
        "run": projection.run,
        "observation_pack": observation_pack,
        "consultation_packet": consultation_packet,
        "evidence_digest": projection.evidence_digest,
        "explanation": projection.explanation,
        "review_state": Value::Null,
        "recent_events": projection.recent_events,
    });
    write_json(&payload)
}

pub fn run_review_reset_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux review-reset [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("review-reset", args, 0)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("review-reset"),
        ));
    }

    let branch = current_git_branch(&options.project_dir)?;
    clear_review_state_record(&options.project_dir, &branch)?;
    let _ = clear_current_pane_review_manifest_state(&options.project_dir);
    println!("review PASS cleared for {branch}");
    Ok(())
}

pub fn run_review_request_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux review-request [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("review-request", args, 0)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("review-request"),
        ));
    }
    assert_review_request_role_permission()?;

    let branch = current_git_branch(&options.project_dir)?;
    let head_sha = current_git_head(&options.project_dir)?;
    let context = current_review_pane_context(&options.project_dir)?;
    let timestamp = generated_at();
    let request = review_request_record(&branch, &head_sha, &context, &timestamp);
    let reviewer = json!({
        "pane_id": context.pane_id,
        "label": context.label,
        "role": context.role,
        "agent_name": env::var("WINSMUX_AGENT_NAME").unwrap_or_default(),
    });

    let mut state = load_review_state(&options.project_dir)?;
    state.insert(
        branch.clone(),
        json!({
            "status": "PENDING",
            "branch": branch,
            "head_sha": head_sha,
            "request": request,
            "reviewer": reviewer,
            "updatedAt": timestamp,
        }),
    );
    save_review_state(&options.project_dir, state)?;
    let _ = mark_current_pane_review_requested(&options.project_dir, &context, &branch, &head_sha);
    println!("review request recorded for {branch}");
    Ok(())
}

struct ParsedOptions {
    json: bool,
    project_dir: PathBuf,
    positionals: Vec<String>,
}

fn parse_options(
    command: &str,
    args: &[&String],
    expected_positionals: usize,
) -> io::Result<ParsedOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux {command}: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() != expected_positionals {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command).to_string(),
        ));
    }

    Ok(ParsedOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
    })
}

fn should_print_help(args: &[&String]) -> bool {
    args.iter().any(|arg| *arg == "-h" || *arg == "--help")
}

fn require_json(command: &str, options: &ParsedOptions) -> io::Result<()> {
    if options.json {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("winsmux {command} currently supports only --json in the Rust CLI"),
    ))
}

fn usage_for(command: &str) -> &'static str {
    match command {
        "status" => "usage: winsmux status --json [--project-dir <path>]",
        "board" => "usage: winsmux board --json [--project-dir <path>]",
        "inbox" => "usage: winsmux inbox --json [--project-dir <path>]",
        "digest" => "usage: winsmux digest --json [--project-dir <path>]",
        "runs" => "usage: winsmux runs --json [--project-dir <path>]",
        "explain" => "usage: winsmux explain <run_id> --json [--project-dir <path>]",
        "review-reset" => "usage: winsmux review-reset [--project-dir <path>]",
        "review-request" => "usage: winsmux review-request [--project-dir <path>]",
        _ => "usage: winsmux <command> --json [--project-dir <path>]",
    }
}

fn current_git_branch(project_dir: &Path) -> io::Result<String> {
    if let Some(branch) = git_output_line(project_dir, &["rev-parse", "--abbrev-ref", "HEAD"])? {
        if branch != "HEAD" {
            return Ok(branch);
        }
    }

    if let Some(branch) = git_output_line(project_dir, &["symbolic-ref", "--short", "HEAD"])? {
        return Ok(branch);
    }

    Err(io::Error::new(
        io::ErrorKind::Other,
        format!(
            "unable to determine current git branch in {}",
            project_dir.display()
        ),
    ))
}

fn git_output_line(project_dir: &Path, args: &[&str]) -> io::Result<Option<String>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(project_dir)
        .args(args)
        .output()
        .map_err(|err| {
            io::Error::new(
                io::ErrorKind::Other,
                format!(
                    "unable to determine current git branch in {}: {err}",
                    project_dir.display()
                ),
            )
        })?;

    if !output.status.success() {
        return Ok(None);
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok((!value.is_empty()).then_some(value))
}

fn current_git_head(project_dir: &Path) -> io::Result<String> {
    if let Some(head) = git_output_line(project_dir, &["rev-parse", "HEAD"])? {
        return Ok(head);
    }

    Err(io::Error::new(
        io::ErrorKind::Other,
        format!(
            "unable to determine current git HEAD in {}",
            project_dir.display()
        ),
    ))
}

fn clear_review_state_record(project_dir: &Path, branch: &str) -> io::Result<()> {
    let path = review_state_path(project_dir);
    if !path.exists() {
        return Ok(());
    }

    let mut state = load_review_state(project_dir)?;
    state.remove(branch);
    save_review_state(project_dir, state)
}

fn review_state_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("review-state.json")
}

fn load_review_state(project_dir: &Path) -> io::Result<Map<String, Value>> {
    let path = review_state_path(project_dir);
    if !path.exists() {
        return Ok(Map::new());
    }

    let raw = fs::read_to_string(&path)?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(Map::new());
    }

    serde_json::from_str::<Map<String, Value>>(trimmed).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid review state: {}", path.display()),
        )
    })
}

fn save_review_state(project_dir: &Path, state: Map<String, Value>) -> io::Result<()> {
    let path = review_state_path(project_dir);
    if state.is_empty() {
        if path.exists() {
            fs::remove_file(&path)?;
        }
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let content = serde_json::to_string_pretty(&state).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize review state: {err}"),
        )
    })?;
    fs::write(path, format!("{content}\n"))
}

fn assert_review_request_role_permission() -> io::Result<()> {
    let role = current_canonical_role()?;
    if !matches!(role.as_str(), "Reviewer" | "Worker") {
        return Err(review_request_permission_error());
    }

    let role_map = role_map_from_env()?;
    if role_map.is_empty() {
        return Ok(());
    }

    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let Some(mapped_role) = role_map
        .get(&pane_id)
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE_MAP missing entry for pane {pane_id}"),
        ));
    };
    if mapped_role != role {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE mismatch for pane {pane_id}: expected {mapped_role}, got {role}"),
        ));
    }
    Ok(())
}

fn current_canonical_role() -> io::Result<String> {
    let raw = env::var("WINSMUX_ROLE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_ROLE not set"))?;
    canonical_role(&raw).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid WINSMUX_ROLE: {raw}"),
        )
    })
}

fn role_map_from_env() -> io::Result<Map<String, Value>> {
    let raw = env::var("WINSMUX_ROLE_MAP").unwrap_or_default();
    if raw.trim().is_empty() {
        return Ok(Map::new());
    }
    let parsed = serde_json::from_str::<Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid WINSMUX_ROLE_MAP JSON: {err}"),
        )
    })?;
    let Some(raw_map) = parsed.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid WINSMUX_ROLE_MAP JSON: expected object",
        ));
    };

    let mut role_map = Map::new();
    for (pane_id, role) in raw_map {
        let Some(role_name) = role.as_str() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Invalid WINSMUX_ROLE_MAP role for pane {pane_id}: {role}"),
            ));
        };
        let Some(canonical) = canonical_role(role_name) else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Invalid WINSMUX_ROLE_MAP role for pane {pane_id}: {role_name}"),
            ));
        };
        role_map.insert(pane_id.clone(), Value::String(canonical));
    }
    Ok(role_map)
}

fn canonical_role(role: &str) -> Option<String> {
    match role.trim().to_ascii_lowercase().as_str() {
        "operator" => Some("Operator".to_string()),
        "worker" => Some("Worker".to_string()),
        "builder" => Some("Builder".to_string()),
        "researcher" => Some("Researcher".to_string()),
        "reviewer" => Some("Reviewer".to_string()),
        _ => None,
    }
}

fn review_request_permission_error() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "review-request is not permitted for the current role",
    )
}

#[derive(Clone)]
struct ReviewPaneContext {
    label: String,
    pane_id: String,
    role: String,
}

fn current_review_pane_context(project_dir: &Path) -> io::Result<ReviewPaneContext> {
    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let Some(context) = find_review_pane_context(&manifest, &pane_id) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "pane {pane_id} is not registered as a review-capable pane in .winsmux/manifest.yaml"
            ),
        ));
    };
    Ok(context)
}

fn find_review_pane_context(
    manifest: &serde_yaml::Value,
    pane_id: &str,
) -> Option<ReviewPaneContext> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            review_pane_context_from_value(label, pane_id, pane)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter()
            .filter_map(|pane| review_pane_context_from_value("", pane_id, pane))
            .next(),
        _ => None,
    }
}

fn review_pane_context_from_value(
    fallback_label: &str,
    pane_id: &str,
    pane: &serde_yaml::Value,
) -> Option<ReviewPaneContext> {
    let map = pane.as_mapping()?;
    let actual = manifest_string(map, "pane_id");
    if actual != pane_id {
        return None;
    }
    let role = manifest_string(map, "role");
    let canonical_role = canonical_manifest_role(&role, fallback_label);
    if !matches!(canonical_role.as_deref(), Some("Reviewer" | "Worker")) {
        return None;
    }
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    Some(ReviewPaneContext {
        label,
        pane_id: actual,
        role: canonical_role.unwrap_or_default(),
    })
}

fn canonical_manifest_role(role: &str, label: &str) -> Option<String> {
    let candidate = if role.trim().is_empty() {
        label.trim()
    } else {
        role.trim()
    };
    let lowered = candidate.to_ascii_lowercase();
    for (prefix, canonical) in [
        ("worker", "Worker"),
        ("builder", "Builder"),
        ("researcher", "Researcher"),
        ("reviewer", "Reviewer"),
        ("operator", "Operator"),
    ] {
        if lowered == prefix
            || lowered.starts_with(&format!("{prefix}-"))
            || lowered.starts_with(&format!("{prefix}_"))
            || lowered.starts_with(&format!("{prefix}:"))
            || lowered.starts_with(&format!("{prefix}/"))
            || lowered.starts_with(&format!("{prefix} "))
        {
            return Some(canonical.to_string());
        }
    }
    Some("Operator".to_string())
}

fn manifest_string(map: &serde_yaml::Mapping, key: &str) -> String {
    map.get(serde_yaml::Value::String(key.to_string()))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn first_non_empty(first: &str, second: &str) -> String {
    if first.trim().is_empty() {
        second.to_string()
    } else {
        first.to_string()
    }
}

fn review_request_record(
    branch: &str,
    head_sha: &str,
    context: &ReviewPaneContext,
    timestamp: &str,
) -> Value {
    json!({
        "id": review_request_id(),
        "branch": branch,
        "head_sha": head_sha,
        "target_review_pane_id": context.pane_id,
        "target_review_label": context.label,
        "target_review_role": context.role,
        "target_reviewer_pane_id": context.pane_id,
        "target_reviewer_label": context.label,
        "target_reviewer_role": context.role,
        "review_contract": review_contract_record(),
        "dispatched_at": timestamp,
    })
}

fn review_request_id() -> String {
    let now = Utc::now();
    format!(
        "review-{}-{}",
        now.format("%Y%m%d%H%M%S"),
        review_request_suffix(now)
    )
}

fn review_request_suffix(now: chrono::DateTime<Utc>) -> String {
    let nanos = now.timestamp_nanos_opt().unwrap_or_default() as u64;
    let counter = REVIEW_REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed) as u64;
    let mixed = nanos ^ ((std::process::id() as u64) << 16) ^ counter;
    format!("{:08x}", mixed & 0xffff_ffff)
}

fn review_contract_record() -> Value {
    json!({
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
            "design_impact",
            "replacement_coverage",
            "orphaned_artifacts"
        ],
        "checklist_labels": [
            "design impact",
            "replacement coverage",
            "orphaned artifacts"
        ],
        "rationale": "Review requests must audit downstream design impact, replacement coverage, and orphaned artifacts as part of the runtime contract."
    })
}

fn mark_current_pane_review_requested(
    project_dir: &Path,
    context: &ReviewPaneContext,
    branch: &str,
    head_sha: &str,
) -> io::Result<bool> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let timestamp = generated_at();
    let updated = update_manifest_pane_fields(
        &mut manifest,
        &context.pane_id,
        &[
            ("review_state", "pending"),
            ("task_owner", &context.role),
            ("branch", branch),
            ("head_sha", head_sha),
            ("last_event", "review.requested"),
            ("last_event_at", &timestamp),
        ],
    );
    if !updated {
        return Ok(false);
    }
    let content = serde_yaml::to_string(&manifest).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize manifest: {err}"),
        )
    })?;
    fs::write(manifest_path, content)?;
    Ok(true)
}

fn update_manifest_pane_fields(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map.iter_mut().any(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            update_manifest_pane_if_matches(label, pane, pane_id, fields)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| update_manifest_pane_if_matches("", pane, pane_id, fields)),
        _ => false,
    }
}

fn update_manifest_pane_if_matches(
    label: &str,
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    let actual = manifest_string(map, "pane_id");
    if actual != pane_id {
        return false;
    }
    let role = manifest_string(map, "role");
    let canonical_role = canonical_manifest_role(&role, label);
    if !matches!(canonical_role.as_deref(), Some("Reviewer" | "Worker")) {
        return false;
    }
    for (name, value) in fields {
        map.insert(
            serde_yaml::Value::String((*name).to_string()),
            serde_yaml::Value::String((*value).to_string()),
        );
    }
    true
}

fn clear_current_pane_review_manifest_state(project_dir: &Path) -> io::Result<bool> {
    let pane_id = match env::var("WINSMUX_PANE_ID") {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return Ok(false),
    };
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;

    let timestamp = generated_at();
    let updated = update_manifest_pane_review_state(&mut manifest, &pane_id, &timestamp);
    if !updated {
        return Ok(false);
    }

    let content = serde_yaml::to_string(&manifest).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize manifest: {err}"),
        )
    })?;
    fs::write(manifest_path, content)?;
    Ok(true)
}

fn update_manifest_pane_review_state(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    timestamp: &str,
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map
            .values_mut()
            .any(|pane| clear_manifest_pane_if_matches(pane, pane_id, timestamp)),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| clear_manifest_pane_if_matches(pane, pane_id, timestamp)),
        _ => false,
    }
}

fn clear_manifest_pane_if_matches(
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    timestamp: &str,
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    let key = serde_yaml::Value::String("pane_id".to_string());
    let actual = map
        .get(&key)
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default();
    if actual != pane_id {
        return false;
    }
    let role = map
        .get(serde_yaml::Value::String("role".to_string()))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default();
    if !matches!(role, "Reviewer" | "Worker") {
        return false;
    }

    for name in ["review_state", "branch", "head_sha"] {
        map.insert(
            serde_yaml::Value::String(name.to_string()),
            serde_yaml::Value::String(String::new()),
        );
    }
    map.insert(
        serde_yaml::Value::String("last_event".to_string()),
        serde_yaml::Value::String("review.reset".to_string()),
    );
    map.insert(
        serde_yaml::Value::String("last_event_at".to_string()),
        serde_yaml::Value::String(timestamp.to_string()),
    );
    true
}

fn load_snapshot(project_dir: &Path) -> io::Result<LedgerSnapshot> {
    LedgerSnapshot::from_project_dir(project_dir).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to load winsmux ledger: {err}"),
        )
    })
}

fn runs_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> Value {
    let runs: Vec<Value> = snapshot
        .digest_projection()
        .items
        .into_iter()
        .map(|item| {
            let explain = snapshot.explain_projection(&item.run_id);
            let run = explain.as_ref().map(|projection| &projection.run);
            let action_items = run
                .map(|run| json!(run.action_items))
                .unwrap_or_else(|| json!([]));
            let experiment_packet = run
                .map(|run| json!(run.experiment_packet))
                .unwrap_or(Value::Null);
            let security_policy = run
                .map(|run| run.security_policy.clone())
                .unwrap_or(Value::Null);
            let security_verdict = run
                .map(|run| run.security_verdict.clone())
                .unwrap_or(Value::Null);
            let verification_contract = run
                .map(|run| run.verification_contract.clone())
                .unwrap_or(Value::Null);
            let verification_result = run
                .map(|run| run.verification_result.clone())
                .unwrap_or(Value::Null);
            let run_packet = run
                .map(|run| {
                    json!({
                        "run_id": run.run_id,
                        "task_id": run.task_id,
                        "parent_run_id": run.parent_run_id,
                        "goal": run.goal,
                        "task": run.task,
                        "task_type": run.task_type,
                        "priority": run.priority,
                        "blocking": run.blocking,
                        "write_scope": run.write_scope,
                        "read_scope": run.read_scope,
                        "constraints": run.constraints,
                        "expected_output": run.expected_output,
                        "verification_plan": run.verification_plan,
                        "review_required": run.review_required,
                        "provider_target": run.provider_target,
                        "agent_role": run.agent_role,
                        "timeout_policy": run.timeout_policy,
                        "handoff_refs": run.handoff_refs,
                        "branch": run.branch,
                        "head_sha": run.head_sha,
                        "primary_label": run.primary_label,
                        "primary_pane_id": run.primary_pane_id,
                        "primary_role": run.primary_role,
                        "labels": run.labels,
                        "pane_ids": run.pane_ids,
                        "roles": run.roles,
                        "changed_files": run.changed_files,
                        "security_policy": run.security_policy,
                        "security_verdict": run.security_verdict,
                        "verification_contract": run.verification_contract,
                        "verification_result": run.verification_result,
                        "last_event": run.last_event,
                        "last_event_at": run.last_event_at,
                    })
                })
                .unwrap_or(Value::Null);

            let mut value = Map::new();
            value.insert("run_id".into(), json!(item.run_id));
            value.insert("task_id".into(), json!(item.task_id));
            value.insert("task".into(), json!(item.task));
            value.insert("task_state".into(), json!(item.task_state));
            value.insert("review_state".into(), json!(item.review_state));
            value.insert("branch".into(), json!(item.branch));
            value.insert("worktree".into(), json!(item.worktree));
            value.insert("head_sha".into(), json!(item.head_sha));
            value.insert("primary_label".into(), json!(item.label));
            value.insert("primary_pane_id".into(), json!(item.pane_id));
            value.insert("primary_role".into(), json!(item.role));
            value.insert(
                "state".into(),
                json!(run.map(|run| run.state.clone()).unwrap_or_default()),
            );
            value.insert(
                "tokens_remaining".into(),
                json!(run
                    .map(|run| run.tokens_remaining.clone())
                    .unwrap_or_default()),
            );
            value.insert("last_event".into(), json!(item.last_event));
            value.insert("last_event_at".into(), json!(item.last_event_at));
            value.insert(
                "pane_count".into(),
                json!(run.map(|run| run.pane_count).unwrap_or(1)),
            );
            value.insert("changed_file_count".into(), json!(item.changed_file_count));
            value.insert(
                "labels".into(),
                run.map(|run| json!(run.labels))
                    .unwrap_or_else(|| json!([item.label])),
            );
            value.insert(
                "pane_ids".into(),
                run.map(|run| json!(run.pane_ids))
                    .unwrap_or_else(|| json!([item.pane_id])),
            );
            value.insert(
                "roles".into(),
                run.map(|run| json!(run.roles))
                    .unwrap_or_else(|| json!([item.role])),
            );
            value.insert("changed_files".into(), json!(item.changed_files));
            value.insert("action_items".into(), action_items);
            value.insert(
                "parent_run_id".into(),
                json!(run.map(|run| run.parent_run_id.clone()).unwrap_or_default()),
            );
            value.insert(
                "goal".into(),
                json!(run.map(|run| run.goal.clone()).unwrap_or_default()),
            );
            value.insert(
                "task_type".into(),
                json!(run.map(|run| run.task_type.clone()).unwrap_or_default()),
            );
            value.insert(
                "priority".into(),
                json!(run.map(|run| run.priority.clone()).unwrap_or_default()),
            );
            value.insert(
                "blocking".into(),
                json!(run.map(|run| run.blocking).unwrap_or(false)),
            );
            value.insert(
                "write_scope".into(),
                run.map(|run| json!(run.write_scope))
                    .unwrap_or_else(|| json!([])),
            );
            value.insert(
                "read_scope".into(),
                run.map(|run| json!(run.read_scope))
                    .unwrap_or_else(|| json!([])),
            );
            value.insert(
                "constraints".into(),
                run.map(|run| json!(run.constraints))
                    .unwrap_or_else(|| json!([])),
            );
            value.insert(
                "expected_output".into(),
                json!(run
                    .map(|run| run.expected_output.clone())
                    .unwrap_or_default()),
            );
            value.insert(
                "verification_plan".into(),
                run.map(|run| json!(run.verification_plan))
                    .unwrap_or_else(|| json!([])),
            );
            value.insert(
                "review_required".into(),
                json!(run.map(|run| run.review_required).unwrap_or(false)),
            );
            value.insert("provider_target".into(), json!(item.provider_target));
            value.insert(
                "agent_role".into(),
                json!(run.map(|run| run.agent_role.clone()).unwrap_or(item.role)),
            );
            value.insert(
                "timeout_policy".into(),
                json!(run
                    .map(|run| run.timeout_policy.clone())
                    .unwrap_or_default()),
            );
            value.insert(
                "handoff_refs".into(),
                run.map(|run| json!(run.handoff_refs))
                    .unwrap_or_else(|| json!([])),
            );
            value.insert("experiment_packet".into(), experiment_packet);
            value.insert("security_policy".into(), security_policy);
            value.insert("security_verdict".into(), security_verdict);
            value.insert("verification_contract".into(), verification_contract);
            value.insert("verification_result".into(), verification_result);
            value.insert("run_packet".into(), run_packet);
            Value::Object(value)
        })
        .collect();

    json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "summary": {
            "run_count": runs.len(),
            "blocked_runs": runs.iter().filter(|run| json_string_eq(run, "task_state", "blocked")).count(),
            "review_pending": runs.iter().filter(|run| json_string_eq(run, "review_state", "pending")).count(),
            "dirty_runs": runs.iter().filter(|run| run["changed_file_count"].as_u64().unwrap_or(0) > 0).count(),
            "action_item_count": runs
                .iter()
                .map(|run| run["action_items"].as_array().map(|items| items.len()).unwrap_or(0))
                .sum::<usize>(),
        },
        "runs": runs,
    })
}

fn json_string_eq(value: &Value, key: &str, expected: &str) -> bool {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(|actual| actual.eq_ignore_ascii_case(expected))
        .unwrap_or(false)
}

fn read_artifact_json(
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

fn write_enveloped_json<T: Serialize>(project_dir: &Path, value: T) -> io::Result<()> {
    let value = serde_json::to_value(value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize Rust operator projection: {err}"),
        )
    })?;
    let payload = json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "summary": value.get("summary").cloned().unwrap_or(Value::Null),
        "panes": value.get("panes").cloned().unwrap_or(Value::Null),
        "items": value.get("items").cloned().unwrap_or(Value::Null),
    });
    write_json(&strip_null_fields(payload))
}

fn strip_null_fields(value: Value) -> Value {
    let Value::Object(mut map) = value else {
        return value;
    };
    map.retain(|_, value| !value.is_null());
    Value::Object(map)
}

fn generated_at() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn project_dir_string(project_dir: &Path) -> String {
    project_dir.display().to_string()
}

fn write_json<T: Serialize>(value: &T) -> io::Result<()> {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize Rust operator projection: {err}"),
        )
    })?;
    writeln!(stdout)?;
    Ok(())
}
