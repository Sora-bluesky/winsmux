use std::{
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU32, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::event_contract::{parse_event_jsonl, EventRecord};
use crate::ledger::{LedgerDigestItem, LedgerSnapshot};

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

pub fn run_desktop_summary_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux desktop-summary [--json] [--stream] [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_desktop_summary_options(args)?;

    if options.stream {
        return stream_desktop_summary(&options);
    }

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = desktop_summary_payload(&snapshot, &options.project_dir)?;
    if options.json {
        return write_json(&payload);
    }

    let board_count = payload["board"]["summary"]["pane_count"].as_u64().unwrap_or(0);
    let inbox_count = payload["inbox"]["summary"]["item_count"].as_u64().unwrap_or(0);
    let digest_count = payload["digest"]["summary"]["item_count"].as_u64().unwrap_or(0);
    let projection_count = payload["run_projections"]
        .as_array()
        .map(Vec::len)
        .unwrap_or(0);
    println!(
        "Desktop summary: {board_count} panes, {inbox_count} inbox items, {digest_count} digest items, {projection_count} projections"
    );
    Ok(())
}

pub fn run_provider_capabilities_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux provider-capabilities [provider] [--json] [--project-dir <path>]");
        return Ok(());
    }

    let options = parse_provider_capabilities_options(args)?;
    let registry_path = provider_capability_registry_path(&options.project_dir);
    let registry = read_provider_capability_registry(&registry_path)?;

    if let Some(provider_id) = options.provider_id.as_deref() {
        let Some(capabilities) = find_provider_capability(&registry, provider_id) else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("provider capability '{provider_id}' was not found."),
            ));
        };
        let payload = json!({
            "provider_id": provider_id,
            "capabilities": capabilities,
            "registry_path": registry_path.display().to_string(),
        });
        if options.json {
            return write_json(&payload);
        }

        println!("provider capability {provider_id}");
        if let Some(entries) = capabilities.as_object() {
            for (key, value) in entries {
                println!("  {key}: {}", provider_capability_value_text(value));
            }
        }
        return Ok(());
    }

    let payload = json!({
        "version": registry.version,
        "registry_path": registry_path.display().to_string(),
        "providers": registry.providers,
    });
    if options.json {
        return write_json(&payload);
    }

    if registry.providers.is_empty() {
        println!("provider capabilities: none");
        return Ok(());
    }

    println!("provider capabilities");
    for provider_id in registry.providers.keys() {
        println!("  {provider_id}");
    }
    Ok(())
}

pub fn run_signal_command(args: &[&String]) -> io::Result<()> {
    if args.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("signal"),
        ));
    }

    let channel = args[0].trim();
    if channel.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("signal"),
        ));
    }

    let signal_dir = signal_dir_path();
    fs::create_dir_all(&signal_dir)?;
    let signal_file = signal_file_path(channel);
    fs::write(signal_file, generated_at())?;
    println!("sent signal: {channel}");
    Ok(())
}

pub fn run_wait_command(args: &[&String]) -> io::Result<()> {
    if args.is_empty() || args.len() > 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("wait"),
        ));
    }

    let channel = args[0].trim();
    if channel.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("wait"),
        ));
    }

    let timeout_secs = match args.get(1) {
        Some(raw) => raw
            .parse::<u64>()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, usage_for("wait")))?,
        None => 120,
    };
    let signal_dir = signal_dir_path();
    fs::create_dir_all(&signal_dir)?;
    let signal_file = signal_file_path(channel);
    if signal_file.exists() {
        fs::remove_file(&signal_file)?;
        println!("received signal: {channel}");
        return Ok(());
    }

    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    while Instant::now() < deadline {
        thread::sleep(Duration::from_millis(100));
        if signal_file.exists() {
            fs::remove_file(&signal_file)?;
            println!("received signal: {channel}");
            return Ok(());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("timeout waiting for signal: {channel} ({timeout_secs}s)"),
    ))
}

fn signal_dir_path() -> PathBuf {
    env::var_os("TEMP")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join("winsmux")
        .join("signals")
}

fn signal_file_path(channel: &str) -> PathBuf {
    signal_dir_path().join(format!("{channel}.signal"))
}

#[derive(Debug)]
struct ProviderCapabilitiesOptions {
    project_dir: PathBuf,
    provider_id: Option<String>,
    json: bool,
}

#[derive(Debug)]
struct ProviderCapabilityRegistry {
    version: u64,
    providers: Map<String, Value>,
}

fn parse_provider_capabilities_options(args: &[&String]) -> io::Result<ProviderCapabilitiesOptions> {
    let mut project_dir = env::current_dir()?;
    let mut provider_id: Option<String> = None;
    let mut json = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        usage_for("provider-capabilities"),
                    ));
                };
                project_dir = PathBuf::from(value.as_str());
                index += 2;
            }
            value => {
                if provider_id.is_none() {
                    provider_id = Some(value.to_string());
                    index += 1;
                    continue;
                }
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    usage_for("provider-capabilities"),
                ));
            }
        }
    }

    Ok(ProviderCapabilitiesOptions {
        project_dir,
        provider_id,
        json,
    })
}

fn provider_capability_registry_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("provider-capabilities.json")
}

fn read_provider_capability_registry(path: &Path) -> io::Result<ProviderCapabilityRegistry> {
    if !path.exists() {
        return Ok(ProviderCapabilityRegistry {
            version: 1,
            providers: Map::new(),
        });
    }

    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(ProviderCapabilityRegistry {
            version: 1,
            providers: Map::new(),
        });
    }

    let parsed: Value = serde_json::from_str(&raw).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Invalid provider capability registry JSON at '{}'.",
                path.display()
            ),
        )
    })?;
    let Some(root) = parsed.as_object() else {
        return Err(invalid_provider_capability_registry(path));
    };

    let version = match root.get("version") {
        Some(Value::Number(number)) => number.as_u64().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Invalid provider capability registry version at '{}'.",
                    path.display()
                ),
            )
        })?,
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Invalid provider capability registry version at '{}'.",
                    path.display()
                ),
            ))
        }
        None => 1,
    };
    if version != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported provider capability registry version '{version}'. Supported versions: 1."
            ),
        ));
    }

    let raw_providers = match root.get("providers") {
        Some(Value::Object(providers)) => providers.clone(),
        Some(Value::Null) | None => Map::new(),
        Some(_) => return Err(invalid_provider_capability_registry(path)),
    };

    let mut providers = Map::new();
    for (provider_id, capabilities) in &raw_providers {
        if provider_id.trim().is_empty() {
            return Err(invalid_provider_capability_registry(path));
        }
        providers.insert(
            provider_id.clone(),
            normalize_provider_capability_entry(path, provider_id, capabilities)?,
        );
    }

    Ok(ProviderCapabilityRegistry { version, providers })
}

fn normalize_provider_capability_entry(
    path: &Path,
    provider_id: &str,
    value: &Value,
) -> io::Result<Value> {
    let Some(entry) = value.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Invalid provider capability entry '{provider_id}' at '{}'.",
                path.display()
            ),
        ));
    };
    if entry.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Invalid provider capability entry '{provider_id}' at '{}'.",
                path.display()
            ),
        ));
    }

    let mut normalized = Map::new();
    let string_fields = ["adapter", "display_name", "command"];
    let transport_fields = ["prompt_transports"];
    let string_array_fields = ["auth_modes", "local_interactive_oauth_modes"];
    let bool_fields = [
        "supports_parallel_runs",
        "supports_interrupt",
        "supports_structured_result",
        "supports_file_edit",
        "supports_subagents",
        "supports_verification",
        "supports_consultation",
    ];

    for (field, field_value) in entry {
        let name = field.as_str();
        if !string_fields.contains(&name)
            && !transport_fields.contains(&name)
            && !string_array_fields.contains(&name)
            && !bool_fields.contains(&name)
        {
            return Err(invalid_provider_capability_field(name));
        }

        if string_fields.contains(&name) {
            let Some(text) = field_value.as_str() else {
                return Err(invalid_provider_capability_field(name));
            };
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                normalized.insert(field.clone(), Value::String(trimmed.to_string()));
            }
            continue;
        }

        if transport_fields.contains(&name) {
            let Some(items) = field_value.as_array() else {
                return Err(invalid_provider_capability_field(name));
            };
            if items.is_empty() {
                return Err(invalid_provider_capability_field(name));
            }
            let mut normalized_items = Vec::new();
            for item in items {
                let Some(transport) = item.as_str() else {
                    return Err(invalid_provider_capability_field(name));
                };
                let normalized_transport = transport.trim().to_ascii_lowercase();
                if normalized_transport.is_empty()
                    || !matches!(normalized_transport.as_str(), "argv" | "file" | "stdin")
                {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Invalid provider capability prompt transport '{transport}'."),
                    ));
                }
                normalized_items.push(Value::String(normalized_transport));
            }
            normalized.insert(field.clone(), Value::Array(normalized_items));
            continue;
        }

        if string_array_fields.contains(&name) {
            let Some(items) = field_value.as_array() else {
                return Err(invalid_provider_capability_field(name));
            };
            let mut normalized_items = Vec::new();
            for item in items {
                let Some(text) = item.as_str() else {
                    return Err(invalid_provider_capability_field(name));
                };
                let normalized_text = text.trim().to_ascii_lowercase();
                if normalized_text.is_empty() {
                    return Err(invalid_provider_capability_field(name));
                }
                normalized_items.push(Value::String(normalized_text));
            }
            normalized.insert(field.clone(), Value::Array(normalized_items));
            continue;
        }

        if bool_fields.contains(&name) {
            if !field_value.is_boolean() {
                return Err(invalid_provider_capability_field(name));
            }
            normalized.insert(field.clone(), field_value.clone());
        }
    }

    for required in ["adapter", "command", "prompt_transports"] {
        if !normalized.contains_key(required) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Missing provider capability field '{required}'."),
            ));
        }
    }

    Ok(Value::Object(normalized))
}

fn invalid_provider_capability_field(field: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("Invalid provider capability field '{field}'."),
    )
}

fn invalid_provider_capability_registry(path: &Path) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "Invalid provider capability registry JSON at '{}'.",
            path.display()
        ),
    )
}

fn find_provider_capability<'a>(
    registry: &'a ProviderCapabilityRegistry,
    provider_id: &str,
) -> Option<&'a Value> {
    registry
        .providers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(provider_id))
        .map(|(_, value)| value)
}

fn provider_capability_value_text(value: &Value) -> String {
    match value {
        Value::Array(items) => items
            .iter()
            .map(provider_capability_value_text)
            .collect::<Vec<_>>()
            .join(","),
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number.to_string(),
        Value::Null => String::new(),
        Value::Object(_) => value.to_string(),
    }
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

pub fn run_conflict_preflight_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("conflict-preflight"));
        return Ok(());
    }

    run_conflict_preflight(args, false)
}

pub fn run_compare_preflight_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("compare-preflight"));
        return Ok(());
    }

    run_conflict_preflight(args, true)
}

fn run_conflict_preflight(args: &[&String], compare_alias: bool) -> io::Result<()> {
    let usage_key = if compare_alias {
        "compare-preflight"
    } else {
        "conflict-preflight"
    };
    let options = parse_conflict_preflight_options(args, usage_key)?;
    let mut payload =
        conflict_preflight_payload(&env::current_dir()?, &options.left_ref, &options.right_ref)?;
    if compare_alias {
        payload.command = "compare preflight".to_string();
        payload.next_action = payload.next_action.replace(
            "winsmux conflict-preflight",
            "winsmux compare preflight",
        );
    }
    if options.json {
        return write_json(&payload);
    }

    let label = if compare_alias {
        "compare preflight"
    } else {
        "conflict preflight"
    };
    println!("{label}: {}", payload.status);
    println!(
        "left: {} ({})",
        payload.left_ref,
        short_head_sha(&payload.left_sha)
    );
    println!(
        "right: {} ({})",
        payload.right_ref,
        short_head_sha(&payload.right_sha)
    );
    if !payload.merge_base.trim().is_empty() {
        println!("merge-base: {}", short_head_sha(&payload.merge_base));
    }
    println!("overlap paths: {}", payload.overlap_paths.len());
    for path in &payload.overlap_paths {
        println!("- {path}");
    }
    println!("next: {}", payload.next_action);
    Ok(())
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
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("run not found: {right_id}"),
        )
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
    let differences = payload["differences"]
        .as_array()
        .cloned()
        .unwrap_or_default();
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

pub fn run_promote_tactic_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("promote-tactic"));
        return Ok(());
    }
    let options = parse_promote_tactic_options(args)?;
    let run_id = options.positionals[0].clone();
    if !matches!(
        options.kind.as_str(),
        "playbook" | "prewarm" | "verification"
    ) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported promote kind: {}", options.kind),
        ));
    }

    let snapshot = load_snapshot(&options.project_dir)?;
    let projection = snapshot.explain_projection(&run_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {run_id}"))
    })?;
    if !run_recommendable(&projection.run) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("run is not promotable: {run_id}"),
        ));
    }

    let consultation_packet = read_artifact_json(
        &projection.run.experiment_packet.consultation_ref,
        &options.project_dir,
        &[".winsmux", "consultations"],
        &run_id,
    );
    let candidate = promote_tactic_candidate(&projection, &consultation_packet, &options);
    let artifact = write_playbook_candidate(&options.project_dir, &candidate)?;
    let result = json!({
        "generated_at": generated_at(),
        "run_id": run_id,
        "candidate_ref": artifact.reference,
        "candidate_path": artifact.path,
        "candidate": candidate,
    });

    if options.json {
        return write_json(&result);
    }
    println!(
        "promoted tactic from {} -> {}",
        result["run_id"].as_str().unwrap_or_default(),
        result["candidate_ref"].as_str().unwrap_or_default()
    );
    Ok(())
}

pub fn run_consult_result_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("consult-result"));
        return Ok(());
    }
    let options = parse_consult_result_options(args)?;
    assert_consult_role_permission("consult-result")?;

    let timestamp = generated_at();
    let context = consultation_command_context(&options.project_dir, &options.run_id)?;
    let packet = consultation_result_packet(&context, &options, &timestamp);
    let artifact = write_consultation_packet(&options.project_dir, "consult-result", &packet)?;
    let event = consultation_result_event(&context, &options, &artifact.reference, &timestamp);
    append_event_record(&options.project_dir, &event)?;
    let _ = mark_current_review_pane_last_event(&options.project_dir, "consult.result", &timestamp);

    if options.json {
        return write_json(&json!({
            "run_id": context.run_id,
            "task_id": context.task_id,
            "pane_id": context.pane_id,
            "slot": context.slot,
            "kind": "consult_result",
            "mode": options.mode,
            "target_slot": options.target_slot,
            "recommendation": options.message,
            "confidence": options.confidence,
            "next_test": options.next_test,
            "risks": options.risks,
            "consultation_ref": artifact.reference,
            "generated_at": timestamp,
        }));
    }

    println!("consult result recorded for {}", context.run_id);
    Ok(())
}

pub fn run_consult_request_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("consult-request"));
        return Ok(());
    }
    let options = parse_consult_request_options(args)?;
    assert_consult_role_permission("consult-request")?;

    let timestamp = generated_at();
    let context = consultation_command_context(&options.project_dir, "")?;
    let packet = consultation_request_packet(&context, &options, &timestamp);
    let artifact = write_consultation_packet(&options.project_dir, "consult-request", &packet)?;
    let event = consultation_request_event(&context, &options, &artifact.reference, &timestamp);
    append_event_record(&options.project_dir, &event)?;
    let _ = mark_current_review_pane_last_event(&options.project_dir, "consult.request", &timestamp);

    println!("consult request recorded for {}", context.run_id);
    Ok(())
}

pub fn run_consult_error_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("consult-error"));
        return Ok(());
    }
    let options = parse_consult_error_options(args)?;
    assert_consult_role_permission("consult-error")?;

    let timestamp = generated_at();
    let context = consultation_command_context(&options.project_dir, "")?;
    let packet = consultation_error_packet(&context, &options, &timestamp);
    let artifact = write_consultation_packet(&options.project_dir, "consult-error", &packet)?;
    let event = consultation_error_event(&context, &options, &artifact.reference, &timestamp);
    append_event_record(&options.project_dir, &event)?;
    let _ = mark_current_review_pane_last_event(&options.project_dir, "consult.error", &timestamp);

    println!("consult error recorded for {}", context.run_id);
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

struct DesktopSummaryOptions {
    json: bool,
    stream: bool,
    project_dir: PathBuf,
}

struct PromoteTacticOptions {
    json: bool,
    project_dir: PathBuf,
    positionals: Vec<String>,
    title: String,
    kind: String,
}

struct ConflictPreflightOptions {
    json: bool,
    left_ref: String,
    right_ref: String,
}

#[derive(Debug, Serialize)]
struct ConflictPreflightPayload {
    command: String,
    status: String,
    reason: String,
    project_dir: String,
    left_ref: String,
    right_ref: String,
    left_sha: String,
    right_sha: String,
    merge_base: String,
    merge_tree_exit_code: Option<i32>,
    conflict_detected: bool,
    overlap_paths: Vec<String>,
    left_only_paths: Vec<String>,
    right_only_paths: Vec<String>,
    next_action: String,
}

struct GitProbeResult {
    exit_code: i32,
    output: String,
}

struct ConsultResultOptions {
    json: bool,
    project_dir: PathBuf,
    mode: String,
    message: String,
    target_slot: String,
    confidence: Option<f64>,
    run_id: String,
    next_test: String,
    risks: Vec<String>,
}

struct ConsultRequestOptions {
    project_dir: PathBuf,
    mode: String,
    message: String,
    target_slot: String,
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

fn parse_desktop_summary_options(args: &[&String]) -> io::Result<DesktopSummaryOptions> {
    let mut json = false;
    let mut stream = false;
    let mut project_dir = None;
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--stream" => {
                stream = true;
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
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux desktop-summary: {value}"),
                ));
            }
        }
    }

    Ok(DesktopSummaryOptions {
        json,
        stream,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
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

fn parse_promote_tactic_options(args: &[&String]) -> io::Result<PromoteTacticOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut title = String::new();
    let mut kind = "playbook".to_string();
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
            "--title" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--title requires a value",
                    ));
                };
                title = value.to_string();
                index += 2;
            }
            "--kind" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--kind requires a value",
                    ));
                };
                kind = value.to_string();
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux promote-tactic: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("promote-tactic").to_string(),
        ));
    }

    Ok(PromoteTacticOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
        title,
        kind,
    })
}

fn parse_conflict_preflight_options(
    args: &[&String],
    usage_key: &'static str,
) -> io::Result<ConflictPreflightOptions> {
    let mut json = false;
    let mut refs = Vec::new();
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            value if !value.trim().is_empty() => {
                refs.push(value.to_string());
                index += 1;
            }
            _ => {
                index += 1;
            }
        }
    }

    if refs.len() != 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(usage_key).to_string(),
        ));
    }

    Ok(ConflictPreflightOptions {
        json,
        left_ref: refs[0].clone(),
        right_ref: refs[1].clone(),
    })
}

fn parse_consult_result_options(args: &[&String]) -> io::Result<ConsultResultOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut message = String::new();
    let mut message_parts = Vec::new();
    let mut target_slot = String::new();
    let mut confidence = None;
    let mut run_id = String::new();
    let mut next_test = String::new();
    let mut risks = Vec::new();
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
            "--message" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--message requires a value",
                    ));
                };
                message = value.to_string();
                index += 2;
            }
            "--target-slot" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--target-slot requires a value",
                    ));
                };
                target_slot = value.to_string();
                index += 2;
            }
            "--confidence" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--confidence requires a value",
                    ));
                };
                confidence = Some(value.parse::<f64>().map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("Invalid confidence value: {value}"),
                    )
                })?);
                index += 2;
            }
            "--run-id" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--run-id requires a value",
                    ));
                };
                run_id = value.to_string();
                index += 2;
            }
            "--next-test" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--next-test requires a value",
                    ));
                };
                next_test = value.to_string();
                index += 2;
            }
            "--risk" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--risk requires a value",
                    ));
                };
                if !value.trim().is_empty() {
                    risks.push(value.to_string());
                }
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux consult-result: {value}"),
                ));
            }
            value => {
                if positionals.is_empty() {
                    positionals.push(value.to_string());
                } else if !value.trim().is_empty() {
                    message_parts.push(value.to_string());
                }
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("consult-result"),
        ));
    }

    let mode = positionals[0].trim().to_ascii_lowercase();
    if !matches!(mode.as_str(), "early" | "stuck" | "reconcile" | "final") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported consult mode: {}", positionals[0]),
        ));
    }

    if message.trim().is_empty() && !message_parts.is_empty() {
        message = message_parts.join(" ");
    }
    if message.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "consult message is required",
        ));
    }

    Ok(ConsultResultOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        mode,
        message,
        target_slot,
        confidence,
        run_id,
        next_test,
        risks,
    })
}

fn parse_consult_request_options(args: &[&String]) -> io::Result<ConsultRequestOptions> {
    parse_consult_simple_options("consult-request", args)
}

fn parse_consult_error_options(args: &[&String]) -> io::Result<ConsultRequestOptions> {
    parse_consult_simple_options("consult-error", args)
}

fn parse_consult_simple_options(
    command: &str,
    args: &[&String],
) -> io::Result<ConsultRequestOptions> {
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut message = String::new();
    let mut message_parts = Vec::new();
    let mut target_slot = String::new();
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
            "--message" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--message requires a value",
                    ));
                };
                message = value.to_string();
                index += 2;
            }
            "--target-slot" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--target-slot requires a value",
                    ));
                };
                target_slot = value.to_string();
                index += 2;
            }
            "--run-id" => {
                let Some(_) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--run-id requires a value",
                    ));
                };
                index += 2;
            }
            "--confidence" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--confidence requires a value",
                    ));
                };
                value.parse::<f64>().map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("Invalid confidence value: {value}"),
                    )
                })?;
                index += 2;
            }
            "--next-test" => {
                let Some(_) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--next-test requires a value",
                    ));
                };
                index += 2;
            }
            "--risk" => {
                let Some(_) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--risk requires a value",
                    ));
                };
                index += 2;
            }
            "--json" => {
                index += 1;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux {command}: {value}"),
                ));
            }
            value => {
                if positionals.is_empty() {
                    positionals.push(value.to_string());
                } else if !value.trim().is_empty() {
                    message_parts.push(value.to_string());
                }
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command),
        ));
    }

    let mode = positionals[0].trim().to_ascii_lowercase();
    if !matches!(mode.as_str(), "early" | "stuck" | "reconcile" | "final") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported consult mode: {}", positionals[0]),
        ));
    }

    if message.trim().is_empty() && !message_parts.is_empty() {
        message = message_parts.join(" ");
    }
    if message.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "consult message is required",
        ));
    }

    Ok(ConsultRequestOptions {
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        mode,
        message,
        target_slot,
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
        "desktop-summary" => "usage: winsmux desktop-summary [--json] [--stream] [--project-dir <path>]",
        "provider-capabilities" => {
            "usage: winsmux provider-capabilities [provider] [--json] [--project-dir <path>]"
        }
        "signal" => "usage: winsmux signal <channel>",
        "wait" => "usage: winsmux wait <channel> [timeout_seconds]",
        "runs" => "usage: winsmux runs --json [--project-dir <path>]",
        "explain" => "usage: winsmux explain <run_id> --json [--project-dir <path>]",
        "compare-runs" => {
            "usage: winsmux compare-runs <left_run_id> <right_run_id> [--json] [--project-dir <path>]"
        }
        "conflict-preflight" => {
            "usage: winsmux conflict-preflight <left_ref> <right_ref> [--json]"
        }
        "compare-preflight" => {
            "usage: winsmux compare preflight <left_ref> <right_ref> [--json]"
        }
        "promote-tactic" => {
            "usage: winsmux promote-tactic <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json] [--project-dir <path>]"
        }
        "consult-request" => {
            "usage: winsmux consult-request <early|stuck|reconcile|final> [--message <text>] [--target-slot <slot>] [--project-dir <path>]"
        }
        "consult-result" => {
            "usage: winsmux consult-result <early|stuck|reconcile|final> [--message <text>] [--target-slot <slot>] [--confidence <0..1>] [--next-test <text>] [--risk <text>] [--run-id <run_id>] [--json] [--project-dir <path>]"
        }
        "consult-error" => {
            "usage: winsmux consult-error <early|stuck|reconcile|final> [--message <text>] [--target-slot <slot>] [--project-dir <path>]"
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

fn assert_consult_role_permission(command_name: &str) -> io::Result<()> {
    let role = current_canonical_role()?;
    if !matches!(
        role.as_str(),
        "Operator" | "Builder" | "Worker" | "Researcher" | "Reviewer"
    ) {
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
struct ConsultationContext {
    session_name: String,
    label: String,
    pane_id: String,
    role: String,
    task_id: String,
    branch: String,
    head_sha: String,
    run_id: String,
    slot: String,
    worktree: String,
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

fn consultation_command_context(
    project_dir: &Path,
    run_id_override: &str,
) -> io::Result<ConsultationContext> {
    if !run_id_override.trim().is_empty() {
        let snapshot = load_snapshot(project_dir)?;
        let projection = snapshot
            .explain_projection(run_id_override)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("run not found: {run_id_override}"),
                )
            })?;
        let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
        let manifest = load_manifest_yaml(&manifest_path)?;
        let session_name = manifest_session_name(&manifest).unwrap_or_default();
        return Ok(ConsultationContext {
            session_name,
            label: projection.run.primary_label.clone(),
            pane_id: projection.run.primary_pane_id.clone(),
            role: projection.run.primary_role.clone(),
            task_id: projection.run.task_id.clone(),
            branch: projection.run.branch.clone(),
            head_sha: projection.run.head_sha.clone(),
            run_id: projection.run.run_id.clone(),
            slot: projection.run.primary_label.clone(),
            worktree: projection.run.worktree.clone(),
        });
    }

    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = load_manifest_yaml(&manifest_path)?;
    let Some(context) = find_consultation_context(&manifest, &pane_id, project_dir) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("pane {pane_id} is not registered in .winsmux/manifest.yaml"),
        ));
    };
    Ok(context)
}

fn load_manifest_yaml(manifest_path: &Path) -> io::Result<serde_yaml::Value> {
    let raw = fs::read_to_string(manifest_path)?;
    serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })
}

fn find_consultation_context(
    manifest: &serde_yaml::Value,
    pane_id: &str,
    project_dir: &Path,
) -> Option<ConsultationContext> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            consultation_context_from_value(manifest, label, pane_id, pane, project_dir)
        }),
        serde_yaml::Value::Sequence(items) => items.iter().find_map(|pane| {
            consultation_context_from_value(manifest, "", pane_id, pane, project_dir)
        }),
        _ => None,
    }
}

fn consultation_context_from_value(
    manifest: &serde_yaml::Value,
    fallback_label: &str,
    pane_id: &str,
    pane: &serde_yaml::Value,
    project_dir: &Path,
) -> Option<ConsultationContext> {
    let map = pane.as_mapping()?;
    let actual = manifest_string(map, "pane_id");
    if actual != pane_id {
        return None;
    }
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    let role = canonical_manifest_role(&manifest_string(map, "role"), &label).unwrap_or_default();
    let task_id = manifest_string(map, "task_id");
    let mut run_id = manifest_string(map, "parent_run_id");
    if run_id.trim().is_empty() && !task_id.trim().is_empty() {
        run_id = format!("task:{task_id}");
    }
    if run_id.trim().is_empty() && task_id.trim().is_empty() {
        return None;
    }

    let branch = {
        let manifest_branch = manifest_string(map, "branch");
        if manifest_branch.trim().is_empty() {
            current_git_branch(project_dir).unwrap_or_default()
        } else {
            manifest_branch
        }
    };
    let head_sha = {
        let manifest_head = manifest_string(map, "head_sha");
        if manifest_head.trim().is_empty() {
            current_git_head(project_dir).unwrap_or_default()
        } else {
            manifest_head
        }
    };
    let worktree_path = first_non_empty(
        &first_non_empty(
            &first_non_empty(
                &manifest_string(map, "worktree_git_dir"),
                &manifest_string(map, "git_worktree_dir"),
            ),
            &manifest_string(map, "builder_worktree_path"),
        ),
        &manifest_string(map, "launch_dir"),
    );
    let worktree = if worktree_path.trim().is_empty() {
        String::new()
    } else {
        artifact_reference(project_dir, Path::new(&worktree_path))
    };

    Some(ConsultationContext {
        session_name: manifest_session_name(manifest).unwrap_or_default(),
        label: label.clone(),
        pane_id: actual,
        role,
        task_id,
        branch,
        head_sha,
        run_id,
        slot: label,
        worktree,
    })
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
    run_winsmux_command(&[
        "send-keys",
        "-t",
        &plan.pane_id,
        "-l",
        "--",
        &plan.launch_command,
    ])?;
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
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_string())
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
    Command::new(&winsmux_bin)
        .args(args)
        .output()
        .map_err(|err| {
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
            .map(|field| {
                matches!(
                    field,
                    "branch" | "worktree" | "env_fingerprint" | "command_hash" | "result"
                )
            })
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

fn conflict_preflight_payload(
    project_dir: &Path,
    left_ref: &str,
    right_ref: &str,
) -> io::Result<ConflictPreflightPayload> {
    let repo_root = resolve_conflict_preflight_repo_root(project_dir)?;
    let left_sha = resolve_conflict_commit(&repo_root, left_ref)?;
    let right_sha = resolve_conflict_commit(&repo_root, right_ref)?;
    let merge_base_result = git_probe(&repo_root, &["merge-base", left_ref, right_ref])?;
    if merge_base_result.exit_code != 0 || merge_base_result.output.trim().is_empty() {
        return Ok(ConflictPreflightPayload {
            command: "conflict-preflight".to_string(),
            status: "blocked".to_string(),
            reason: "no_merge_base".to_string(),
            project_dir: repo_root.display().to_string(),
            left_ref: left_ref.to_string(),
            right_ref: right_ref.to_string(),
            left_sha,
            right_sha,
            merge_base: String::new(),
            merge_tree_exit_code: None,
            conflict_detected: false,
            overlap_paths: Vec::new(),
            left_only_paths: Vec::new(),
            right_only_paths: Vec::new(),
            next_action:
                "Choose related refs with a shared merge base and rerun winsmux conflict-preflight."
                    .to_string(),
        });
    }

    let merge_base = merge_base_result.output;
    let left_paths = conflict_path_array(
        &git_probe(&repo_root, &["diff", "--name-only", &merge_base, left_ref])?.output,
    );
    let right_paths = conflict_path_array(
        &git_probe(&repo_root, &["diff", "--name-only", &merge_base, right_ref])?.output,
    );
    let overlap_paths: Vec<String> = left_paths
        .iter()
        .filter(|path| right_paths.contains(path))
        .cloned()
        .collect();
    let left_only_paths: Vec<String> = left_paths
        .iter()
        .filter(|path| !right_paths.contains(path))
        .cloned()
        .collect();
    let right_only_paths: Vec<String> = right_paths
        .iter()
        .filter(|path| !left_paths.contains(path))
        .cloned()
        .collect();
    let merge_tree_result = git_probe(
        &repo_root,
        &["merge-tree", "--write-tree", "--quiet", left_ref, right_ref],
    )?;
    let (status, reason, conflict_detected, next_action) = match merge_tree_result.exit_code {
        0 => (
            "clean",
            "",
            false,
            "Safe to continue to compare UI or follow-up review.",
        ),
        1 => (
            "conflict",
            "merge_conflict",
            true,
            "Inspect overlap paths before compare or merge.",
        ),
        _ => (
            "blocked",
            "merge_tree_failed",
            false,
            "Inspect git merge-tree output and rerun winsmux conflict-preflight.",
        ),
    };

    Ok(ConflictPreflightPayload {
        command: "conflict-preflight".to_string(),
        status: status.to_string(),
        reason: reason.to_string(),
        project_dir: repo_root.display().to_string(),
        left_ref: left_ref.to_string(),
        right_ref: right_ref.to_string(),
        left_sha,
        right_sha,
        merge_base,
        merge_tree_exit_code: Some(merge_tree_result.exit_code),
        conflict_detected,
        overlap_paths,
        left_only_paths,
        right_only_paths,
        next_action: next_action.to_string(),
    })
}

fn resolve_conflict_preflight_repo_root(project_dir: &Path) -> io::Result<PathBuf> {
    if !project_dir.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("project directory not found: {}", project_dir.display()),
        ));
    }
    let result = git_probe(project_dir, &["rev-parse", "--show-toplevel"])?;
    if result.exit_code != 0 || result.output.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "git repository root could not be resolved from: {}",
                project_dir.display()
            ),
        ));
    }
    Ok(PathBuf::from(result.output))
}

fn resolve_conflict_commit(project_dir: &Path, git_ref: &str) -> io::Result<String> {
    let rev = format!("{git_ref}^{{commit}}");
    let result = git_probe(project_dir, &["rev-parse", "--verify", &rev])?;
    if result.exit_code != 0 || result.output.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("git ref could not be resolved: {git_ref}"),
        ));
    }
    Ok(result.output)
}

fn git_probe(project_dir: &Path, args: &[&str]) -> io::Result<GitProbeResult> {
    let output = Command::new("git").args(args).current_dir(project_dir).output()?;
    let mut text = String::new();
    text.push_str(&String::from_utf8_lossy(&output.stdout));
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok(GitProbeResult {
        exit_code: output.status.code().unwrap_or(1),
        output: text.trim().to_string(),
    })
}

fn conflict_path_array(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
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

struct WrittenArtifact {
    path: String,
    reference: String,
}

fn promote_tactic_candidate(
    projection: &crate::ledger::LedgerExplainProjection,
    consultation_packet: &Value,
    options: &PromoteTacticOptions,
) -> Value {
    let run = &projection.run;
    let experiment = &run.experiment_packet;
    let recommendation = json_string_field(consultation_packet, "recommendation");
    let title = if !options.title.trim().is_empty() {
        options.title.clone()
    } else if !recommendation.trim().is_empty() {
        recommendation.clone()
    } else if !experiment.result.trim().is_empty() {
        experiment.result.clone()
    } else if !run.task.trim().is_empty() {
        run.task.clone()
    } else {
        format!("Tactic from {}", run.run_id)
    };
    let summary = if !recommendation.trim().is_empty() {
        recommendation
    } else {
        experiment.result.clone()
    };

    json!({
        "run_id": run.run_id,
        "task_id": run.task_id,
        "pane_id": run.primary_pane_id,
        "slot": experiment.slot,
        "kind": options.kind,
        "title": title,
        "summary": summary,
        "hypothesis": experiment.hypothesis,
        "next_action": projection.evidence_digest.next_action,
        "confidence": experiment.confidence,
        "branch": run.branch,
        "head_sha": run.head_sha,
        "worktree": experiment.worktree,
        "env_fingerprint": experiment.env_fingerprint,
        "command_hash": experiment.command_hash,
        "changed_files": projection.evidence_digest.changed_files,
        "observation_pack_ref": experiment.observation_pack_ref,
        "consultation_ref": experiment.consultation_ref,
        "verification_result": run.verification_result,
        "security_verdict": run.security_verdict,
        "action_item_count": run.action_items.len(),
        "action_item_kinds": action_item_kinds(&run.action_items),
        "reuse_conditions": reuse_conditions(run),
        "packet_type": "playbook_candidate",
        "generated_at": generated_at(),
    })
}

fn action_item_kinds(items: &[crate::ledger::LedgerExplainActionItem]) -> Vec<String> {
    let mut values = Vec::new();
    for item in items {
        if !item.kind.trim().is_empty() && !values.contains(&item.kind) {
            values.push(item.kind.clone());
        }
    }
    values
}

fn reuse_conditions(run: &crate::ledger::LedgerExplainRun) -> Vec<String> {
    let mut values = Vec::new();
    if !run.branch.trim().is_empty() {
        values.push(format!("branch={}", run.branch));
    }
    if !run.experiment_packet.env_fingerprint.trim().is_empty() {
        values.push(format!(
            "env_fingerprint={}",
            run.experiment_packet.env_fingerprint
        ));
    }
    if !run.experiment_packet.command_hash.trim().is_empty() {
        values.push(format!(
            "command_hash={}",
            run.experiment_packet.command_hash
        ));
    }
    values
}

fn write_playbook_candidate(project_dir: &Path, candidate: &Value) -> io::Result<WrittenArtifact> {
    let dir = project_dir.join(".winsmux").join("playbook-candidates");
    fs::create_dir_all(&dir)?;
    let file_name = format!("playbook-candidate-{}.json", unique_artifact_id());
    let path = dir.join(file_name);
    let content = serde_json::to_string_pretty(candidate).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize playbook candidate: {err}"),
        )
    })?;
    write_text_file_with_lock(&path, &content)?;
    Ok(WrittenArtifact {
        reference: artifact_reference(project_dir, &path),
        path: path.display().to_string(),
    })
}

fn consultation_result_packet(
    context: &ConsultationContext,
    options: &ConsultResultOptions,
    timestamp: &str,
) -> Value {
    let mut packet = Map::new();
    packet.insert("packet_type".to_string(), json!("consultation_packet"));
    packet.insert("generated_at".to_string(), json!(timestamp));
    packet.insert("run_id".to_string(), json!(context.run_id));
    packet.insert("task_id".to_string(), json!(context.task_id));
    packet.insert("pane_id".to_string(), json!(context.pane_id));
    packet.insert("slot".to_string(), json!(context.slot));
    packet.insert("kind".to_string(), json!("consult_result"));
    packet.insert("mode".to_string(), json!(options.mode));
    packet.insert("target_slot".to_string(), json!(options.target_slot));
    packet.insert("branch".to_string(), json!(context.branch));
    packet.insert("head_sha".to_string(), json!(context.head_sha));
    packet.insert("worktree".to_string(), json!(context.worktree));
    packet.insert("recommendation".to_string(), json!(options.message));
    packet.insert(
        "confidence".to_string(),
        json!(options.confidence.unwrap_or_default()),
    );
    packet.insert("next_test".to_string(), json!(options.next_test));
    packet.insert("risks".to_string(), json!(options.risks));
    Value::Object(packet)
}

fn consultation_request_packet(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    timestamp: &str,
) -> Value {
    let mut packet = Map::new();
    packet.insert("packet_type".to_string(), json!("consultation_packet"));
    packet.insert("generated_at".to_string(), json!(timestamp));
    packet.insert("run_id".to_string(), json!(context.run_id));
    packet.insert("task_id".to_string(), json!(context.task_id));
    packet.insert("pane_id".to_string(), json!(context.pane_id));
    packet.insert("slot".to_string(), json!(context.slot));
    packet.insert("kind".to_string(), json!("consult_request"));
    packet.insert("mode".to_string(), json!(options.mode));
    packet.insert("target_slot".to_string(), json!(options.target_slot));
    packet.insert("branch".to_string(), json!(context.branch));
    packet.insert("head_sha".to_string(), json!(context.head_sha));
    packet.insert("worktree".to_string(), json!(context.worktree));
    packet.insert("request".to_string(), json!(options.message));
    Value::Object(packet)
}

fn consultation_error_packet(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    timestamp: &str,
) -> Value {
    let mut packet = Map::new();
    packet.insert("packet_type".to_string(), json!("consultation_packet"));
    packet.insert("generated_at".to_string(), json!(timestamp));
    packet.insert("run_id".to_string(), json!(context.run_id));
    packet.insert("task_id".to_string(), json!(context.task_id));
    packet.insert("pane_id".to_string(), json!(context.pane_id));
    packet.insert("slot".to_string(), json!(context.slot));
    packet.insert("kind".to_string(), json!("consult_error"));
    packet.insert("mode".to_string(), json!(options.mode));
    packet.insert("target_slot".to_string(), json!(options.target_slot));
    packet.insert("branch".to_string(), json!(context.branch));
    packet.insert("head_sha".to_string(), json!(context.head_sha));
    packet.insert("worktree".to_string(), json!(context.worktree));
    packet.insert("error".to_string(), json!(options.message));
    Value::Object(packet)
}

fn consultation_result_event(
    context: &ConsultationContext,
    options: &ConsultResultOptions,
    consultation_ref: &str,
    timestamp: &str,
) -> Value {
    let mut data = Map::new();
    data.insert("task_id".to_string(), json!(context.task_id));
    data.insert("run_id".to_string(), json!(context.run_id));
    data.insert("slot".to_string(), json!(context.slot));
    data.insert("branch".to_string(), json!(context.branch));
    data.insert("worktree".to_string(), json!(context.worktree));
    data.insert("consultation_ref".to_string(), json!(consultation_ref));
    data.insert("result".to_string(), json!(options.message));
    if let Some(confidence) = options.confidence {
        data.insert("confidence".to_string(), json!(confidence));
    }
    if !options.next_test.trim().is_empty() {
        data.insert("next_action".to_string(), json!(options.next_test));
    }

    json!({
        "timestamp": timestamp,
        "session": context.session_name,
        "event": "pane.consult_result",
        "message": options.message,
        "label": context.label,
        "pane_id": context.pane_id,
        "role": context.role,
        "branch": context.branch,
        "head_sha": context.head_sha,
        "data": Value::Object(data),
    })
}

fn consultation_request_event(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    consultation_ref: &str,
    timestamp: &str,
) -> Value {
    let mut data = Map::new();
    data.insert("task_id".to_string(), json!(context.task_id));
    data.insert("run_id".to_string(), json!(context.run_id));
    data.insert("slot".to_string(), json!(context.slot));
    data.insert("branch".to_string(), json!(context.branch));
    data.insert("worktree".to_string(), json!(context.worktree));
    data.insert("consultation_ref".to_string(), json!(consultation_ref));

    json!({
        "timestamp": timestamp,
        "session": context.session_name,
        "event": "pane.consult_request",
        "message": options.message,
        "label": context.label,
        "pane_id": context.pane_id,
        "role": context.role,
        "branch": context.branch,
        "head_sha": context.head_sha,
        "data": Value::Object(data),
    })
}

fn consultation_error_event(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    consultation_ref: &str,
    timestamp: &str,
) -> Value {
    let mut data = Map::new();
    data.insert("task_id".to_string(), json!(context.task_id));
    data.insert("run_id".to_string(), json!(context.run_id));
    data.insert("slot".to_string(), json!(context.slot));
    data.insert("branch".to_string(), json!(context.branch));
    data.insert("worktree".to_string(), json!(context.worktree));
    data.insert("consultation_ref".to_string(), json!(consultation_ref));

    json!({
        "timestamp": timestamp,
        "session": context.session_name,
        "event": "pane.consult_error",
        "message": options.message,
        "label": context.label,
        "pane_id": context.pane_id,
        "role": context.role,
        "branch": context.branch,
        "head_sha": context.head_sha,
        "data": Value::Object(data),
    })
}

fn write_consultation_packet(
    project_dir: &Path,
    file_prefix: &str,
    packet: &Value,
) -> io::Result<WrittenArtifact> {
    let dir = project_dir.join(".winsmux").join("consultations");
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}-{}.json", file_prefix, unique_artifact_id()));
    let content = serde_json::to_string_pretty(packet).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize consultation packet: {err}"),
        )
    })?;
    write_text_file_with_lock(&path, &format!("{content}\n"))?;
    Ok(WrittenArtifact {
        reference: artifact_reference(project_dir, &path),
        path: path.display().to_string(),
    })
}

fn append_event_record(project_dir: &Path, event: &Value) -> io::Result<()> {
    let path = project_dir.join(".winsmux").join("events.jsonl");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let line = serde_json::to_string(event).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize event record: {err}"),
        )
    })?;
    with_file_lock(&path, || {
        let mut content = if path.exists() {
            fs::read_to_string(&path)?
        } else {
            String::new()
        };
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        content.push_str(&line);
        content.push('\n');
        write_text_file_locked(&path, &content)
    })
}

fn mark_current_review_pane_last_event(
    project_dir: &Path,
    last_event: &str,
    timestamp: &str,
) -> io::Result<bool> {
    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let updated = update_manifest_review_capable_pane_fields(
        &mut manifest,
        &pane_id,
        &[("last_event", last_event), ("last_event_at", timestamp)],
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

fn update_manifest_review_capable_pane_fields(
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

fn artifact_reference(project_dir: &Path, path: &Path) -> String {
    path.strip_prefix(project_dir)
        .ok()
        .map(|relative| relative.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| path.display().to_string().replace('\\', "/"))
}

fn unique_artifact_id() -> String {
    let counter = ATOMIC_WRITE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{nanos:x}{:08x}{counter:08x}", std::process::id())
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

fn desktop_summary_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> io::Result<Value> {
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
    let worktree = first_non_empty_owned([
        run_worktree,
        experiment_worktree,
        item.worktree.clone(),
    ]);
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

fn stream_desktop_summary(options: &DesktopSummaryOptions) -> io::Result<()> {
    let mut cursor = read_desktop_summary_events(&options.project_dir)?.len();
    loop {
        let events = read_desktop_summary_events(&options.project_dir)?;
        if events.len() < cursor {
            cursor = 0;
        }
        for event in events.iter().skip(cursor) {
            let Some(item) = desktop_summary_refresh_item(event) else {
                continue;
            };
            if options.json {
                write_json(&item)?;
            } else {
                println!("{}", desktop_summary_refresh_text(&item));
            }
        }
        cursor = events.len();
        thread::sleep(Duration::from_secs(2));
    }
}

fn read_desktop_summary_events(project_dir: &Path) -> io::Result<Vec<EventRecord>> {
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    if !events_path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(&events_path)?;
    parse_event_jsonl(&content).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to parse desktop-summary events: {err}"),
        )
    })
}

fn desktop_summary_refresh_item(event: &EventRecord) -> Option<Value> {
    let reason = first_non_empty_owned([event.event.clone(), event.status.clone()]);
    if reason.trim().is_empty() {
        return None;
    }

    let mut item = Map::new();
    item.insert("source".to_string(), json!("summary"));
    item.insert("reason".to_string(), json!(reason));
    if !event.timestamp.trim().is_empty() {
        item.insert("timestamp".to_string(), json!(event.timestamp));
    }
    if !event.pane_id.trim().is_empty() {
        item.insert("pane_id".to_string(), json!(event.pane_id));
    }
    let run_id = desktop_summary_refresh_run_id(event);
    if !run_id.trim().is_empty() {
        item.insert("run_id".to_string(), json!(run_id));
    }

    Some(Value::Object(item))
}

fn desktop_summary_refresh_run_id(event: &EventRecord) -> String {
    let run_id = json_field_string(&event.data, "run_id");
    if !run_id.trim().is_empty() {
        return run_id;
    }
    if !event.run_id.trim().is_empty() {
        return event.run_id.clone();
    }
    let task_id = json_field_string(&event.data, "task_id");
    if !task_id.trim().is_empty() {
        return format!("task:{task_id}");
    }
    if !event.task_id.trim().is_empty() {
        return format!("task:{}", event.task_id);
    }
    let branch = first_non_empty_owned([event.branch.clone(), json_field_string(&event.data, "branch")]);
    if !branch.trim().is_empty() {
        return format!("branch:{branch}");
    }
    String::new()
}

fn desktop_summary_refresh_text(item: &Value) -> String {
    let timestamp = item
        .get("timestamp")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(generated_at);
    let reason = item
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut details = Vec::new();
    if let Some(pane_id) = item.get("pane_id").and_then(Value::as_str) {
        details.push(format!("pane={pane_id}"));
    }
    if let Some(run_id) = item.get("run_id").and_then(Value::as_str) {
        details.push(format!("run={run_id}"));
    }
    if details.is_empty() {
        format!("[{timestamp}] summary {reason}")
    } else {
        format!("[{timestamp}] summary {reason} {}", details.join(" "))
    }
}

fn json_field_string(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
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
    let payload = enveloped_payload(project_dir, value)?;
    write_json(&payload)
}

fn enveloped_payload<T: Serialize>(project_dir: &Path, value: T) -> io::Result<Value> {
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
    Ok(strip_null_fields(payload))
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
