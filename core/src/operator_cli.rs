use std::{
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU32, Ordering},
    thread,
    time::{Duration, Instant},
};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::ledger::LedgerSnapshot;

static REVIEW_REQUEST_COUNTER: AtomicU32 = AtomicU32::new(0);
static ATOMIC_WRITE_COUNTER: AtomicU32 = AtomicU32::new(0);

const FILE_LOCK_TIMEOUT: Duration = Duration::from_millis(120_000);
const FILE_LOCK_STALE_AFTER: Duration = Duration::from_secs(60);
const FILE_LOCK_RETRY_DELAY: Duration = Duration::from_millis(50);

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

pub fn run_compare_runs_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("compare-runs"));
        return Ok(());
    }
    let options = parse_options("compare-runs", args, 2)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let left_id = options.positionals[0].clone();
    let right_id = options.positionals[1].clone();
    let left = snapshot.explain_projection(&left_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {left_id}"))
    })?;
    let right = snapshot.explain_projection(&right_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {right_id}"))
    })?;
    let payload = compare_runs_payload(&left, &right);
    if options.json {
        return write_json(&payload);
    }

    println!(
        "Compare: {} vs {}",
        payload["left"]["run_id"].as_str().unwrap_or_default(),
        payload["right"]["run_id"].as_str().unwrap_or_default()
    );
    println!(
        "Shared changed files: {}",
        payload["shared_changed_files"]
            .as_array()
            .map(|items| items.len())
            .unwrap_or(0)
    );
    if !payload["confidence_delta"].is_null() {
        println!("Confidence delta: {}", payload["confidence_delta"]);
    }
    if let Some(winner) = payload["recommend"]["winning_run_id"].as_str() {
        if !winner.is_empty() {
            println!("Winning run: {winner}");
        }
    }
    println!(
        "Next action: {}",
        payload["recommend"]["next_action"]
            .as_str()
            .unwrap_or_default()
    );
    let differences = payload["differences"].as_array().cloned().unwrap_or_default();
    if differences.is_empty() {
        println!("Differences: (none)");
    } else {
        println!("Differences:");
        for difference in differences {
            println!(
                "- {}: left={} right={}",
                difference["field"].as_str().unwrap_or_default(),
                compare_display_value(&difference["left"]),
                compare_display_value(&difference["right"])
            );
        }
    }
    Ok(())
}

pub fn run_poll_events_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("poll-events"));
        return Ok(());
    }
    let options = parse_poll_events_options(args)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("poll-events"),
        ));
    }

    let mut cursor = 0usize;
    if let Some(raw_cursor) = options.positionals.first() {
        let parsed = raw_cursor
            .parse::<i32>()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, usage_for("poll-events")))?;
        if parsed > 0 {
            cursor = parsed as usize;
        }
    }

    let events_path = options.project_dir.join(".winsmux").join("events.jsonl");
    let mut response = json!({
        "cursor": 0,
        "events": [],
    });
    if !events_path.is_file() {
        return write_json(&response);
    }

    let raw = fs::read_to_string(&events_path)
        .map_err(|err| io::Error::new(err.kind(), format!("failed to read event log: {}", err)))?;
    let lines: Vec<&str> = raw.lines().filter(|line| !line.trim().is_empty()).collect();
    if cursor > lines.len() {
        cursor = lines.len();
    }

    let mut events = Vec::new();
    for (index, line) in lines.iter().enumerate().skip(cursor) {
        let event = serde_json::from_str::<Value>(line).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to parse event log line {}: {}", index + 1, err),
            )
        })?;
        events.push(event);
    }

    response["cursor"] = json!(lines.len());
    response["events"] = Value::Array(events);
    write_json(&response)
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
    assert_review_role_permission("review-request")?;

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

pub fn run_review_approve_command(args: &[&String]) -> io::Result<()> {
    record_review_result(
        args,
        "review-approve",
        "PASS",
        "approved_at",
        "approved_via",
        "pass",
    )
}

pub fn run_review_fail_command(args: &[&String]) -> io::Result<()> {
    record_review_result(
        args,
        "review-fail",
        "FAIL",
        "failed_at",
        "failed_via",
        "fail",
    )
}

pub fn run_restart_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("restart"));
        return Ok(());
    }
    let options = parse_options("restart", args, 1)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("restart"),
        ));
    }

    let target = options.positionals[0].clone();
    let plan = build_restart_plan(&options.project_dir, &target)?;
    invoke_restart_plan(&plan)?;
    let _ = update_restart_manifest_metadata(&options.project_dir, &plan);
    println!("restarted {} ({})", plan.pane_id, plan.label);
    Ok(())
}

pub fn run_rebind_worktree_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("rebind-worktree"));
        return Ok(());
    }
    let options = parse_rebind_worktree_options(args)?;
    let target = options.positionals[0].clone();
    let new_worktree_path = options.positionals[1..].join(" ").trim().to_string();
    if new_worktree_path.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "new worktree path must not be empty",
        ));
    }

    let requested_path = PathBuf::from(&new_worktree_path);
    if !requested_path.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("worktree path not found: {new_worktree_path}"),
        ));
    }

    let resolved_worktree_path = resolved_display_path(&requested_path)?;
    let manifest_path = options.project_dir.join(".winsmux").join("manifest.yaml");
    let context =
        update_rebind_manifest_with_lock(&manifest_path, &target, &resolved_worktree_path)?;
    println!(
        "rebound {} ({}) to {}",
        context.pane_id, context.label, resolved_worktree_path
    );
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

fn parse_poll_events_options(args: &[&String]) -> io::Result<ParsedOptions> {
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
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() > 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("poll-events"),
        ));
    }

    Ok(ParsedOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
    })
}

fn parse_rebind_worktree_options(args: &[&String]) -> io::Result<ParsedOptions> {
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
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
            "--json" => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    usage_for("rebind-worktree"),
                ));
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux rebind-worktree: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() < 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("rebind-worktree"),
        ));
    }

    Ok(ParsedOptions {
        json: false,
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
        "compare-runs" => {
            "usage: winsmux compare-runs <left_run_id> <right_run_id> [--json] [--project-dir <path>]"
        }
        "poll-events" => "usage: winsmux poll-events [cursor] [--project-dir <path>]",
        "review-reset" => "usage: winsmux review-reset [--project-dir <path>]",
        "review-request" => "usage: winsmux review-request [--project-dir <path>]",
        "review-approve" => "usage: winsmux review-approve [--project-dir <path>]",
        "review-fail" => "usage: winsmux review-fail [--project-dir <path>]",
        "restart" => "usage: winsmux restart <target> [--project-dir <path>]",
        "rebind-worktree" => {
            "usage: winsmux rebind-worktree <target> <new-worktree-path> [--project-dir <path>]"
        }
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

fn assert_review_role_permission(command_name: &str) -> io::Result<()> {
    let role = current_canonical_role()?;
    if !matches!(role.as_str(), "Reviewer" | "Worker") {
        return Err(review_permission_error(command_name));
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

fn review_permission_error(command_name: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("{command_name} is not permitted for the current role"),
    )
}

#[derive(Clone)]
struct ReviewPaneContext {
    label: String,
    pane_id: String,
    role: String,
}

#[derive(Clone)]
struct RebindManifestContext {
    label: String,
    pane_id: String,
    role: String,
}

#[derive(Clone)]
struct RestartPlan {
    label: String,
    pane_id: String,
    role: String,
    session_name: String,
    launch_dir: String,
    git_worktree_dir: String,
    agent: String,
    model: String,
    capability_adapter: String,
    launch_command: String,
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

fn resolve_rebind_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
    manifest_path: &Path,
) -> io::Result<RebindManifestContext> {
    let Some(context) = find_rebind_manifest_context(manifest, target) else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "Pane {target} was not found in manifest: {}",
                manifest_path.display()
            ),
        ));
    };
    Ok(context)
}

fn update_rebind_manifest_with_lock(
    manifest_path: &Path,
    target: &str,
    resolved_worktree_path: &str,
) -> io::Result<RebindManifestContext> {
    with_file_lock(manifest_path, || {
        let raw = fs::read_to_string(manifest_path)?;
        let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid manifest: {}: {err}", manifest_path.display()),
            )
        })?;
        let session_name = manifest_session_name(&manifest)?;
        let context = resolve_rebind_manifest_context(&manifest, target, manifest_path)?;
        if !matches!(context.role.as_str(), "Builder" | "Worker") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "rebind-worktree is only supported for Builder/Worker panes: {} ({})",
                    context.pane_id, context.label
                ),
            ));
        }
        ensure_live_pane_target(&session_name, &context.pane_id)?;

        if !update_manifest_pane_paths(
            &mut manifest,
            &context.pane_id,
            resolved_worktree_path,
            resolved_worktree_path,
        ) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "Pane {} was not found in manifest: {}",
                    context.pane_id,
                    manifest_path.display()
                ),
            ));
        }

        let content = serde_yaml::to_string(&manifest).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to serialize manifest: {err}"),
            )
        })?;
        write_text_file_locked(manifest_path, &content)?;
        Ok(context)
    })
}

fn find_rebind_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
) -> Option<RebindManifestContext> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            rebind_context_from_value(label, target, pane)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter()
            .filter_map(|pane| rebind_context_from_value("", target, pane))
            .next(),
        _ => None,
    }
}

fn rebind_context_from_value(
    fallback_label: &str,
    target: &str,
    pane: &serde_yaml::Value,
) -> Option<RebindManifestContext> {
    let map = pane.as_mapping()?;
    let pane_id = manifest_string(map, "pane_id");
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    if pane_id != target && label != target {
        return None;
    }
    let role = manifest_string(map, "role");
    Some(RebindManifestContext {
        label,
        pane_id,
        role: canonical_manifest_role(&role, fallback_label).unwrap_or_default(),
    })
}

fn resolved_display_path(path: &Path) -> io::Result<String> {
    let resolved = fs::canonicalize(path)?;
    let display = resolved.to_string_lossy().to_string();
    Ok(strip_windows_extended_path_prefix(&display))
}

fn manifest_session_name(manifest: &serde_yaml::Value) -> io::Result<String> {
    let session_name = manifest
        .get("session")
        .and_then(|session| session.get("name"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if session_name.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "manifest session.name must not be empty",
        ));
    }
    Ok(session_name)
}

fn build_restart_plan(project_dir: &Path, target: &str) -> io::Result<RestartPlan> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let session_name = manifest_session_name(&manifest)?;
    let project_root = manifest_project_dir(&manifest).unwrap_or_else(|| project_dir.to_path_buf());
    let session_git_worktree_dir = manifest_session_git_worktree_dir(&manifest);
    let context = resolve_restart_manifest_context(
        &manifest,
        target,
        &manifest_path,
        &project_root,
        session_git_worktree_dir.as_deref(),
    )?;
    ensure_live_pane_target(&session_name, &context.pane_id)?;

    let (agent, model, capability_adapter) = resolve_restart_provider(project_dir, &context);
    let launch_command = build_provider_launch_command(
        &agent,
        &model,
        &capability_adapter,
        &context.launch_dir,
        &context.git_worktree_dir,
    )?;
    Ok(RestartPlan {
        label: context.label,
        pane_id: context.pane_id,
        role: context.role,
        session_name,
        launch_dir: context.launch_dir,
        git_worktree_dir: context.git_worktree_dir,
        agent,
        model,
        capability_adapter,
        launch_command,
    })
}

fn manifest_project_dir(manifest: &serde_yaml::Value) -> Option<PathBuf> {
    manifest
        .get("session")
        .and_then(|session| session.get("project_dir"))
        .and_then(serde_yaml::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
}

fn manifest_session_git_worktree_dir(manifest: &serde_yaml::Value) -> Option<String> {
    manifest
        .get("session")
        .and_then(|session| session.get("git_worktree_dir"))
        .and_then(serde_yaml::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

fn resolve_restart_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
    manifest_path: &Path,
    project_root: &Path,
    session_git_worktree_dir: Option<&str>,
) -> io::Result<RestartPlan> {
    let Some(context) =
        find_restart_manifest_context(manifest, target, project_root, session_git_worktree_dir)
    else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "Pane {target} was not found in manifest: {}",
                manifest_path.display()
            ),
        ));
    };
    Ok(context)
}

fn find_restart_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
    project_root: &Path,
    session_git_worktree_dir: Option<&str>,
) -> Option<RestartPlan> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            restart_context_from_value(label, target, pane, project_root, session_git_worktree_dir)
        }),
        serde_yaml::Value::Sequence(items) => items.iter().find_map(|pane| {
            restart_context_from_value("", target, pane, project_root, session_git_worktree_dir)
        }),
        _ => None,
    }
}

fn restart_context_from_value(
    fallback_label: &str,
    target: &str,
    pane: &serde_yaml::Value,
    project_root: &Path,
    session_git_worktree_dir: Option<&str>,
) -> Option<RestartPlan> {
    let map = pane.as_mapping()?;
    let pane_id = manifest_string(map, "pane_id");
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    if pane_id != target && label != target {
        return None;
    }
    let role = canonical_manifest_role(&manifest_string(map, "role"), &label)?;
    let uses_worktree = matches!(role.as_str(), "Builder" | "Worker");
    let builder_worktree_path = if uses_worktree {
        manifest_string(map, "builder_worktree_path")
    } else {
        String::new()
    };
    let mut launch_dir = manifest_string(map, "launch_dir");
    if launch_dir.trim().is_empty() && !builder_worktree_path.trim().is_empty() {
        launch_dir = builder_worktree_path;
    }
    if launch_dir.trim().is_empty() {
        launch_dir = project_root.to_string_lossy().to_string();
    }

    let mut git_worktree_dir = if uses_worktree {
        manifest_string(map, "worktree_git_dir")
    } else {
        String::new()
    };
    if git_worktree_dir.trim().is_empty() {
        git_worktree_dir = session_git_worktree_dir.unwrap_or_default().to_string();
    }
    if uses_worktree || git_worktree_dir.trim().is_empty() {
        git_worktree_dir = pane_git_worktree_dir(Path::new(&launch_dir));
    }

    Some(RestartPlan {
        label,
        pane_id,
        role,
        session_name: String::new(),
        launch_dir,
        git_worktree_dir,
        agent: String::new(),
        model: String::new(),
        capability_adapter: String::new(),
        launch_command: String::new(),
    })
}

fn pane_git_worktree_dir(project_dir: &Path) -> String {
    let dot_git = project_dir.join(".git");
    if dot_git.is_file() {
        if let Ok(raw) = fs::read_to_string(&dot_git) {
            if let Some(rest) = raw.trim().strip_prefix("gitdir:") {
                let value = rest.trim();
                let path = PathBuf::from(value);
                return if path.is_absolute() {
                    path.to_string_lossy().to_string()
                } else {
                    project_dir.join(path).to_string_lossy().to_string()
                };
            }
        }
    }
    if dot_git.is_dir() {
        return dot_git.to_string_lossy().to_string();
    }
    project_dir.to_string_lossy().to_string()
}

fn resolve_restart_provider(project_dir: &Path, context: &RestartPlan) -> (String, String, String) {
    if let Some((agent, model, adapter)) = provider_registry_entry(project_dir, &context.label) {
        return (agent, model, adapter);
    }
    let (agent, model) =
        split_provider_target(&manifest_provider_target(project_dir, &context.pane_id));
    let agent = if agent.trim().is_empty() {
        "codex".to_string()
    } else {
        agent
    };
    let model = if model.trim().is_empty() {
        "gpt-5.4".to_string()
    } else {
        model
    };
    let adapter = manifest_capability_adapter(project_dir, &context.pane_id)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| provider_adapter_from_agent(&agent));
    (agent, model, adapter)
}

fn provider_registry_entry(project_dir: &Path, label: &str) -> Option<(String, String, String)> {
    let path = project_dir.join(".winsmux").join("provider-registry.json");
    let raw = fs::read_to_string(path).ok()?;
    let registry = serde_json::from_str::<Value>(&raw).ok()?;
    let entry = registry.get("slots")?.get(label)?;
    let agent = entry.get("agent").and_then(Value::as_str)?.to_string();
    let model = entry
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("gpt-5.4")
        .to_string();
    let adapter = provider_adapter_from_agent(&agent);
    Some((agent, model, adapter))
}

fn manifest_provider_target(project_dir: &Path, pane_id: &str) -> String {
    manifest_pane_field(project_dir, pane_id, "provider_target").unwrap_or_default()
}

fn manifest_capability_adapter(project_dir: &Path, pane_id: &str) -> Option<String> {
    manifest_pane_field(project_dir, pane_id, "capability_adapter")
}

fn manifest_pane_field(project_dir: &Path, pane_id: &str, field: &str) -> Option<String> {
    let path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(path).ok()?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).ok()?;
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.values().find_map(|pane| {
            let map = pane.as_mapping()?;
            (manifest_string(map, "pane_id") == pane_id)
                .then(|| manifest_string(map, field))
                .filter(|value| !value.trim().is_empty())
        }),
        serde_yaml::Value::Sequence(items) => items.iter().find_map(|pane| {
            let map = pane.as_mapping()?;
            (manifest_string(map, "pane_id") == pane_id)
                .then(|| manifest_string(map, field))
                .filter(|value| !value.trim().is_empty())
        }),
        _ => None,
    }
}

fn split_provider_target(provider_target: &str) -> (String, String) {
    let trimmed = provider_target.trim();
    if let Some((agent, model)) = trimmed.split_once(':') {
        return (agent.trim().to_string(), model.trim().to_string());
    }
    (trimmed.to_string(), String::new())
}

fn provider_adapter_from_agent(agent: &str) -> String {
    let lowered = agent.trim().to_ascii_lowercase();
    if lowered.starts_with("claude") {
        "claude".to_string()
    } else {
        "codex".to_string()
    }
}

fn build_provider_launch_command(
    agent: &str,
    model: &str,
    capability_adapter: &str,
    launch_dir: &str,
    git_worktree_dir: &str,
) -> io::Result<String> {
    match capability_adapter.trim().to_ascii_lowercase().as_str() {
        "codex" | "" => Ok(format!(
            "{} -c {} --sandbox danger-full-access -C {} --add-dir {}",
            shell_literal(agent),
            shell_literal(&format!("model={model}")),
            shell_literal(launch_dir),
            shell_literal(git_worktree_dir)
        )),
        "claude" => {
            let mut parts = vec![shell_literal(agent)];
            if !model.trim().is_empty() {
                parts.push("--model".to_string());
                parts.push(shell_literal(model));
            }
            parts.push("--permission-mode".to_string());
            parts.push("bypassPermissions".to_string());
            Ok(parts.join(" "))
        }
        adapter => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported provider adapter '{adapter}' for restart"),
        )),
    }
}

fn shell_literal(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | ':' | '/' | '\\'))
    {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "''"))
}

fn provider_target_with_model(agent: &str, model: &str) -> String {
    if model.trim().is_empty() {
        agent.to_string()
    } else {
        format!("{}:{}", agent.trim(), model.trim())
    }
}

fn invoke_restart_plan(plan: &RestartPlan) -> io::Result<()> {
    run_winsmux_command(&[
        "respawn-pane",
        "-k",
        "-t",
        &plan.pane_id,
        "-c",
        &plan.launch_dir,
    ])?;
    wait_for_shell_prompt(&plan.pane_id)?;
    run_winsmux_command(&["send-keys", "-t", &plan.pane_id, "-l", "--", &plan.launch_command])?;
    run_winsmux_command(&["send-keys", "-t", &plan.pane_id, "Enter"])?;
    wait_for_agent_prompt(&plan.pane_id, &restart_readiness_agent(plan))?;
    Ok(())
}

fn restart_readiness_agent(plan: &RestartPlan) -> String {
    let adapter = readiness_agent_name(&plan.capability_adapter);
    if !adapter.is_empty() {
        return adapter;
    }
    let agent = readiness_agent_name(&plan.agent);
    if agent.is_empty() {
        "codex".to_string()
    } else {
        agent
    }
}

fn readiness_agent_name(value: &str) -> String {
    let lowered = value.trim().to_ascii_lowercase();
    for name in ["codex", "claude", "gemini"] {
        if lowered == name
            || lowered.starts_with(&format!("{name}:"))
            || lowered.starts_with(&format!("{name}-"))
            || lowered.starts_with(&format!("{name}_"))
            || lowered.starts_with(&format!("{name}/"))
        {
            return name.to_string();
        }
    }
    String::new()
}

fn wait_for_shell_prompt(pane_id: &str) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        let text = capture_pane_tail(pane_id)?;
        if text.lines().any(|line| line.trim().starts_with("PS ")) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(500));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("timed out waiting for shell prompt in {pane_id}"),
    ))
}

fn wait_for_agent_prompt(pane_id: &str, agent: &str) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        let text = capture_pane_tail(pane_id)?;
        if agent_ready_prompt(&text, agent) {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(2));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("timed out waiting for {agent} prompt after restart in {pane_id}"),
    ))
}

fn capture_pane_tail(pane_id: &str) -> io::Result<String> {
    let output = winsmux_command_output(&["capture-pane", "-t", pane_id, "-p", "-J", "-S", "-50"])?;
    Ok(String::from_utf8_lossy(&output.stdout).trim_end().to_string())
}

fn agent_ready_prompt(text: &str, agent: &str) -> bool {
    let recent: Vec<&str> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .rev()
        .take(8)
        .collect();
    recent.into_iter().any(|line| {
        let line = line.trim();
        match agent {
            "claude" => {
                line.eq_ignore_ascii_case("Welcome to Claude Code!")
                    || line.eq_ignore_ascii_case("Welcome to Claude Code")
                    || line.starts_with("/help for help, /status for your current setup")
                    || line.starts_with("?  for shortcuts")
            }
            "gemini" => {
                line.to_ascii_lowercase().starts_with("type your message")
                    || line.to_ascii_lowercase().starts_with("using:")
                    || line.to_ascii_lowercase().starts_with("gemini-")
            }
            _ => line == ">" || line == "›" || line == "▌" || line == "❯" || line.starts_with('>'),
        }
    })
}

fn run_winsmux_command(args: &[&str]) -> io::Result<()> {
    let output = winsmux_command_output(args)?;
    if !output.status.success() {
        return Err(winsmux_command_error(args, &output));
    }
    Ok(())
}

fn winsmux_command_output(args: &[&str]) -> io::Result<std::process::Output> {
    let winsmux_bin = winsmux_bin_path();
    Command::new(&winsmux_bin).args(args).output().map_err(|err| {
        io::Error::new(
            io::ErrorKind::Other,
            format!("failed to run {}: {err}", winsmux_bin.display()),
        )
    })
}

fn winsmux_command_error(args: &[&str], output: &std::process::Output) -> io::Error {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let detail = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        output.status.to_string()
    };
    io::Error::new(
        io::ErrorKind::Other,
        format!("winsmux {} failed: {detail}", args.join(" ")),
    )
}

fn winsmux_bin_path() -> PathBuf {
    env::var_os("WINSMUX_BIN")
        .map(PathBuf::from)
        .or_else(|| env::current_exe().ok())
        .unwrap_or_else(|| PathBuf::from("winsmux"))
}

fn update_restart_manifest_metadata(project_dir: &Path, plan: &RestartPlan) -> io::Result<bool> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    with_file_lock(&manifest_path, || {
        let raw = fs::read_to_string(&manifest_path)?;
        let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid manifest: {}: {err}", manifest_path.display()),
            )
        })?;
        let provider_target = provider_target_with_model(&plan.agent, &plan.model);
        let updated = update_manifest_pane_restart_fields(
            &mut manifest,
            &plan.pane_id,
            &[
                ("provider_target", provider_target.as_str()),
                ("capability_adapter", plan.capability_adapter.as_str()),
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
        write_text_file_locked(&manifest_path, &content)?;
        Ok(true)
    })
}

fn ensure_live_pane_target(session_name: &str, pane_id: &str) -> io::Result<()> {
    let winsmux_bin = winsmux_bin_path();
    let output = Command::new(&winsmux_bin)
        .args(["-t", session_name, "list-panes", "-a", "-F", "#{pane_id}"])
        .output()
        .map_err(|err| {
            io::Error::new(
                io::ErrorKind::Other,
                format!(
                    "failed to validate live panes with {}: {err}",
                    winsmux_bin.display()
                ),
            )
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let detail = if stderr.is_empty() {
            output.status.to_string()
        } else {
            stderr
        };
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("failed to validate live panes: {detail}"),
        ));
    }
    let found = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .any(|line| line == pane_id);
    if !found {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid target: {pane_id}"),
        ));
    }
    Ok(())
}

struct FileLock {
    path: PathBuf,
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn write_text_file_with_lock(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    with_file_lock(path, || write_text_file_locked(path, content))
}

fn with_file_lock<T>(path: &Path, action: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
    let _lock = acquire_file_lock(path)?;
    action()
}

fn write_text_file_locked(path: &Path, content: &str) -> io::Result<()> {
    let tmp_path = temp_write_path(path);
    fs::write(&tmp_path, content)?;
    match replace_file_with_temp(&tmp_path, path) {
        Ok(()) => Ok(()),
        Err(err) => {
            let _ = fs::remove_file(&tmp_path);
            Err(err)
        }
    }
}

#[cfg(windows)]
fn replace_file_with_temp(tmp_path: &Path, path: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    fn wide(value: &Path) -> Vec<u16> {
        value
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    let tmp = wide(tmp_path);
    let target = wide(path);
    let result = unsafe {
        MoveFileExW(
            tmp.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_file_with_temp(tmp_path: &Path, path: &Path) -> io::Result<()> {
    fs::rename(tmp_path, path)
}

fn acquire_file_lock(path: &Path) -> io::Result<FileLock> {
    let lock_path = lock_path_for(path);
    let start = Instant::now();
    loop {
        match fs::create_dir(&lock_path) {
            Ok(()) => {
                let owner = json!({
                    "pid": std::process::id(),
                    "started_at": generated_at(),
                    "path": path.display().to_string(),
                });
                let mut owner = owner;
                if let Some(process_started_at) = current_process_started_at() {
                    owner["process_started_at"] = json!(process_started_at);
                }
                let owner_json = serde_json::to_string_pretty(&owner).unwrap_or_default();
                let _ = fs::write(lock_path.join("owner.json"), owner_json);
                return Ok(FileLock { path: lock_path });
            }
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
                remove_stale_lock(&lock_path);
                if start.elapsed() >= FILE_LOCK_TIMEOUT {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("timed out waiting for file lock: {}", lock_path.display()),
                    ));
                }
                thread::sleep(FILE_LOCK_RETRY_DELAY);
            }
            Err(err) => return Err(err),
        }
    }
}

#[cfg(windows)]
fn current_process_started_at() -> Option<String> {
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    let handle = unsafe { GetCurrentProcess() };
    process_started_at_for_handle(handle)
}

#[cfg(not(windows))]
fn current_process_started_at() -> Option<String> {
    None
}

#[cfg(windows)]
fn process_started_at_for_pid(pid: u32) -> Option<String> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};

    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() {
        return None;
    }
    let started_at = process_started_at_for_handle(handle);
    unsafe {
        let _ = CloseHandle(handle);
    }
    started_at
}

#[cfg(windows)]
fn process_started_at_for_handle(handle: windows_sys::Win32::Foundation::HANDLE) -> Option<String> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::GetProcessTimes;

    let mut created = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut exited = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut kernel = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut user = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let ok = unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) };
    if ok == 0 {
        return None;
    }
    filetime_to_rfc3339(created)
}

#[cfg(windows)]
fn filetime_to_rfc3339(value: windows_sys::Win32::Foundation::FILETIME) -> Option<String> {
    let ticks = ((value.dwHighDateTime as u64) << 32) | (value.dwLowDateTime as u64);
    let unix_ticks = ticks.checked_sub(116_444_736_000_000_000)?;
    let secs = (unix_ticks / 10_000_000) as i64;
    let nanos = ((unix_ticks % 10_000_000) * 100) as u32;
    DateTime::<Utc>::from_timestamp(secs, nanos)
        .map(|timestamp| timestamp.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn remove_stale_lock(lock_path: &Path) {
    let owner_path = lock_path.join("owner.json");
    if owner_path.is_file() {
        match fs::read_to_string(&owner_path)
            .ok()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        {
            Some(owner) => {
                if let Some(pid) = owner.get("pid").and_then(Value::as_u64) {
                    let expected = owner
                        .get("process_started_at")
                        .and_then(Value::as_str)
                        .filter(|value| !value.trim().is_empty());
                    if process_lock_is_stale(pid as u32, expected) {
                        let _ = fs::remove_dir_all(lock_path);
                    }
                    return;
                }
                if owner.get("started_at").and_then(Value::as_str).is_some() {
                    return;
                }
                let _ = fs::remove_dir_all(lock_path);
                return;
            }
            None => {}
        }
    }

    let Ok(metadata) = fs::metadata(lock_path) else {
        return;
    };
    let Ok(modified) = metadata.modified() else {
        return;
    };
    let Ok(age) = modified.elapsed() else {
        return;
    };
    if age >= FILE_LOCK_STALE_AFTER {
        let _ = fs::remove_dir_all(lock_path);
    }
}

#[cfg(windows)]
fn process_lock_is_stale(pid: u32, expected_started_at: Option<&str>) -> bool {
    let Some(actual_started_at) = process_started_at_for_pid(pid) else {
        return true;
    };
    let Some(expected_started_at) = expected_started_at else {
        return false;
    };
    let Ok(expected) = DateTime::parse_from_rfc3339(expected_started_at) else {
        return true;
    };
    let Ok(actual) = DateTime::parse_from_rfc3339(&actual_started_at) else {
        return true;
    };
    (actual - expected).num_seconds().abs() > 1
}

#[cfg(not(windows))]
fn process_lock_is_stale(_pid: u32, _expected_started_at: Option<&str>) -> bool {
    false
}

fn lock_path_for(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".lock");
    PathBuf::from(value)
}

fn temp_write_path(path: &Path) -> PathBuf {
    let counter = ATOMIC_WRITE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut value = path.as_os_str().to_os_string();
    value.push(format!(".tmp-{}-{counter}", std::process::id()));
    PathBuf::from(value)
}

fn strip_windows_extended_path_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{rest}");
    }
    if let Some(rest) = path.strip_prefix(r"\\?\") {
        return rest.to_string();
    }
    path.to_string()
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

fn record_review_result(
    args: &[&String],
    command_name: &str,
    status: &str,
    timestamp_key: &str,
    via_key: &str,
    manifest_state: &str,
) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for(command_name));
        return Ok(());
    }
    let options = parse_options(command_name, args, 0)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command_name),
        ));
    }
    assert_review_role_permission(command_name)?;

    let branch = current_git_branch(&options.project_dir)?;
    let head_sha = current_git_head(&options.project_dir)?;
    let context = current_review_pane_context(&options.project_dir)?;
    let mut state = load_review_state(&options.project_dir)?;
    let request = pending_review_request(&state, &branch, &head_sha, &context)?;
    let timestamp = generated_at();
    let reviewer = review_result_reviewer(&context);
    let evidence =
        review_result_evidence(&request, timestamp_key, via_key, command_name, &timestamp);
    let request_branch = request_string(&request, "branch");
    let request_head_sha = request_string(&request, "head_sha");

    state.insert(
        branch.clone(),
        json!({
            "status": status,
            "branch": request_branch,
            "head_sha": request_head_sha,
            "request": request,
            "reviewer": reviewer,
            "updatedAt": timestamp,
            "evidence": evidence,
        }),
    );
    save_review_state(&options.project_dir, state)?;
    let _ = mark_current_pane_review_result(
        &options.project_dir,
        &context,
        &branch,
        &head_sha,
        manifest_state,
    );
    println!("review {status} recorded for {branch}");
    Ok(())
}

fn pending_review_request(
    state: &Map<String, Value>,
    branch: &str,
    head_sha: &str,
    context: &ReviewPaneContext,
) -> io::Result<Value> {
    let Some(entry) = state.get(branch) else {
        return Err(pending_review_request_missing(branch));
    };
    let status = entry
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let Some(request) = entry.get("request").cloned() else {
        return Err(pending_review_request_missing(branch));
    };
    if status != "PENDING" || !request.is_object() {
        return Err(pending_review_request_missing(branch));
    }
    if !review_contract_present(&request) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("pending review request for {branch} is missing review_contract. Re-run: winsmux review-request"),
        ));
    }

    let request_pane_id = review_request_target_value(&request, "pane_id");
    if request_pane_id != context.pane_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "pending review request for {branch} is assigned to {request_pane_id}, not {}",
                context.pane_id
            ),
        ));
    }

    let request_branch = request_string(&request, "branch");
    if request_branch != branch {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "pending review request branch mismatch: expected {request_branch}, got {branch}"
            ),
        ));
    }

    let request_head_sha = request_string(&request, "head_sha");
    if request_head_sha != head_sha {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "pending review request head mismatch: expected {request_head_sha}, got {head_sha}"
            ),
        ));
    }

    Ok(request)
}

fn pending_review_request_missing(branch: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        format!("review request pending for {branch} was not found. Run: winsmux review-request"),
    )
}

fn review_contract_present(request: &Value) -> bool {
    let Some(contract) = request.get("review_contract").and_then(Value::as_object) else {
        return false;
    };
    match contract.get("required_scope") {
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::String(value)) => !value.trim().is_empty(),
        Some(Value::Null) | None => false,
        Some(_) => true,
    }
}

fn review_request_target_value(request: &Value, name: &str) -> String {
    let primary = format!("target_review_{name}");
    let legacy = format!("target_reviewer_{name}");
    let primary_value = request_string(request, &primary);
    if primary_value.trim().is_empty() {
        request_string(request, &legacy)
    } else {
        primary_value
    }
}

fn request_string(request: &Value, name: &str) -> String {
    request
        .get(name)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn review_result_reviewer(context: &ReviewPaneContext) -> Value {
    json!({
        "pane_id": context.pane_id,
        "label": context.label,
        "role": context.role,
        "agent_name": env::var("WINSMUX_AGENT_NAME").unwrap_or_default(),
    })
}

fn review_result_evidence(
    request: &Value,
    timestamp_key: &str,
    via_key: &str,
    command_name: &str,
    timestamp: &str,
) -> Value {
    let mut evidence = Map::new();
    evidence.insert(timestamp_key.to_string(), json!(timestamp));
    evidence.insert(
        via_key.to_string(),
        json!(format!("winsmux {command_name}")),
    );
    evidence.insert(
        "review_contract_snapshot".to_string(),
        request
            .get("review_contract")
            .cloned()
            .unwrap_or(Value::Null),
    );
    Value::Object(evidence)
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
    write_text_file_with_lock(&manifest_path, &content)?;
    Ok(true)
}

fn mark_current_pane_review_result(
    project_dir: &Path,
    context: &ReviewPaneContext,
    branch: &str,
    head_sha: &str,
    review_state: &str,
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
    let last_event = format!("review.{review_state}");
    let updated = update_manifest_pane_fields(
        &mut manifest,
        &context.pane_id,
        &[
            ("review_state", review_state),
            ("task_owner", "Operator"),
            ("branch", branch),
            ("head_sha", head_sha),
            ("last_event", &last_event),
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
    write_text_file_with_lock(&manifest_path, &content)?;
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

fn update_manifest_pane_restart_fields(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map
            .values_mut()
            .any(|pane| update_manifest_pane_by_id(pane, pane_id, fields)),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| update_manifest_pane_by_id(pane, pane_id, fields)),
        _ => false,
    }
}

fn update_manifest_pane_by_id(
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    if manifest_string(map, "pane_id") != pane_id {
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

fn update_manifest_pane_paths(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    launch_dir: &str,
    builder_worktree_path: &str,
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map.iter_mut().any(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            update_manifest_pane_paths_if_matches(
                label,
                pane,
                pane_id,
                launch_dir,
                builder_worktree_path,
            )
        }),
        serde_yaml::Value::Sequence(items) => items.iter_mut().any(|pane| {
            update_manifest_pane_paths_if_matches(
                "",
                pane,
                pane_id,
                launch_dir,
                builder_worktree_path,
            )
        }),
        _ => false,
    }
}

fn update_manifest_pane_paths_if_matches(
    label: &str,
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    launch_dir: &str,
    builder_worktree_path: &str,
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
    if !matches!(canonical_role.as_deref(), Some("Builder" | "Worker")) {
        return false;
    }
    for (name, value) in [
        ("launch_dir", launch_dir),
        ("builder_worktree_path", builder_worktree_path),
    ] {
        map.insert(
            serde_yaml::Value::String(name.to_string()),
            serde_yaml::Value::String(value.to_string()),
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
    write_text_file_with_lock(&manifest_path, &content)?;
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

fn compare_runs_payload(
    left: &crate::ledger::LedgerExplainProjection,
    right: &crate::ledger::LedgerExplainProjection,
) -> Value {
    let left_changed = left.evidence_digest.changed_files.clone();
    let right_changed = right.evidence_digest.changed_files.clone();
    let shared_changed: Vec<String> = left_changed
        .iter()
        .filter(|path| right_changed.contains(path))
        .cloned()
        .collect();
    let left_only: Vec<String> = left_changed
        .iter()
        .filter(|path| !right_changed.contains(path))
        .cloned()
        .collect();
    let right_only: Vec<String> = right_changed
        .iter()
        .filter(|path| !left_changed.contains(path))
        .cloned()
        .collect();

    let confidence_delta = match (
        left.run.experiment_packet.confidence,
        right.run.experiment_packet.confidence,
    ) {
        (Some(left_confidence), Some(right_confidence)) => {
            Some(round_half_to_even(left_confidence - right_confidence, 4))
        }
        _ => None,
    };

    let mut differences = Vec::new();
    for (field, left_value, right_value) in [
        ("branch", left.run.branch.clone(), right.run.branch.clone()),
        (
            "worktree",
            left.run.experiment_packet.worktree.clone(),
            right.run.experiment_packet.worktree.clone(),
        ),
        (
            "slot",
            left.run.experiment_packet.slot.clone(),
            right.run.experiment_packet.slot.clone(),
        ),
        (
            "task_state",
            left.run.task_state.clone(),
            right.run.task_state.clone(),
        ),
        (
            "review_state",
            left.run.review_state.clone(),
            right.run.review_state.clone(),
        ),
        ("state", left.run.state.clone(), right.run.state.clone()),
        (
            "next_action",
            left.evidence_digest.next_action.clone(),
            right.evidence_digest.next_action.clone(),
        ),
        (
            "hypothesis",
            left.run.experiment_packet.hypothesis.clone(),
            right.run.experiment_packet.hypothesis.clone(),
        ),
        (
            "result",
            left.run.experiment_packet.result.clone(),
            right.run.experiment_packet.result.clone(),
        ),
        (
            "env_fingerprint",
            left.run.experiment_packet.env_fingerprint.clone(),
            right.run.experiment_packet.env_fingerprint.clone(),
        ),
        (
            "command_hash",
            left.run.experiment_packet.command_hash.clone(),
            right.run.experiment_packet.command_hash.clone(),
        ),
    ] {
        if left_value != right_value {
            differences.push(json!({
                "field": field,
                "left": left_value,
                "right": right_value,
            }));
        }
    }
    if !left_only.is_empty() || !right_only.is_empty() {
        differences.push(json!({
            "field": "changed_files",
            "left": left_changed,
            "right": right_changed,
        }));
    }
    if let Some(delta) = confidence_delta {
        if delta != 0.0 {
            differences.push(json!({
                "field": "confidence",
                "left": left.run.experiment_packet.confidence,
                "right": right.run.experiment_packet.confidence,
            }));
        }
    }

    let left_recommendable = run_recommendable(&left.run);
    let right_recommendable = run_recommendable(&right.run);
    let winning_run_id = if left_recommendable && right_recommendable {
        match confidence_delta {
            Some(delta) if delta > 0.0 => left.run.run_id.clone(),
            Some(delta) if delta < 0.0 => right.run.run_id.clone(),
            _ => String::new(),
        }
    } else {
        String::new()
    };
    let reconcile_consult = differences.iter().any(|difference| {
        difference["field"]
            .as_str()
            .map(|field| matches!(field, "branch" | "worktree" | "env_fingerprint" | "command_hash" | "result"))
            .unwrap_or(false)
    }) || !(left_recommendable && right_recommendable);
    let next_action = if left.evidence_digest.next_action == right.evidence_digest.next_action {
        left.evidence_digest.next_action.clone()
    } else {
        "reconcile_consult".to_string()
    };

    json!({
        "generated_at": generated_at(),
        "left": compare_run_side(left, left_recommendable),
        "right": compare_run_side(right, right_recommendable),
        "shared_changed_files": shared_changed,
        "left_only_changed_files": left_only,
        "right_only_changed_files": right_only,
        "confidence_delta": confidence_delta,
        "differences": differences,
        "recommend": {
            "winning_run_id": winning_run_id,
            "reconcile_consult": reconcile_consult,
            "next_action": next_action,
        },
    })
}

fn compare_run_side(
    projection: &crate::ledger::LedgerExplainProjection,
    recommendable: bool,
) -> Value {
    json!({
        "run_id": projection.run.run_id,
        "label": projection.run.primary_label,
        "branch": projection.run.branch,
        "task_state": projection.run.task_state,
        "review_state": projection.run.review_state,
        "state": projection.run.state,
        "next_action": projection.evidence_digest.next_action,
        "confidence": projection.run.experiment_packet.confidence,
        "changed_files": projection.evidence_digest.changed_files,
        "observation_pack_ref": projection.run.experiment_packet.observation_pack_ref,
        "consultation_ref": projection.run.experiment_packet.consultation_ref,
        "recommendable": recommendable,
    })
}

fn run_recommendable(run: &crate::ledger::LedgerExplainRun) -> bool {
    if !matches!(
        run.task_state.as_str(),
        "completed" | "task_completed" | "commit_ready" | "done"
    ) {
        return false;
    }
    if !run.review_state.trim().is_empty() && !run.review_state.eq_ignore_ascii_case("PASS") {
        return false;
    }
    if json_string_field(&run.verification_result, "outcome").to_ascii_uppercase() != "PASS" {
        return false;
    }
    matches!(
        json_string_or_field(&run.security_verdict, "verdict")
            .to_ascii_uppercase()
            .as_str(),
        "ALLOW" | "PASS"
    )
}

fn json_string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn json_string_or_field(value: &Value, key: &str) -> String {
    value
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| json_string_field(value, key))
}

fn round_half_to_even(value: f64, digits: i32) -> f64 {
    let factor = 10_f64.powi(digits);
    let scaled = value * factor;
    let truncated = scaled.trunc();
    let fraction = scaled - truncated;
    let rounded = if fraction.abs() == 0.5 {
        if (truncated as i64).abs() % 2 == 0 {
            truncated
        } else {
            truncated + fraction.signum()
        }
    } else {
        scaled.round()
    };
    rounded / factor
}

fn compare_display_value(value: &Value) -> String {
    if let Some(values) = value.as_array() {
        return values
            .iter()
            .map(compare_display_value)
            .collect::<Vec<_>>()
            .join(", ");
    }
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    value.to_string()
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
