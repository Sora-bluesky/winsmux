use chrono::{DateTime, NaiveDate, SecondsFormat, TimeZone, Utc};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    env, fs, io,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU32, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

static DOGFOOD_ID_COUNTER: AtomicU32 = AtomicU32::new(0);

const VALID_INPUT_SOURCES: &[&str] = &["voice", "keyboard", "shortcut", "paste"];
const VALID_ACTION_TYPES: &[&str] = &[
    "command",
    "approval",
    "cancel",
    "retry",
    "completion",
    "input",
];
const VALID_RUN_MODES: &[&str] = &["codex_direct", "winsmux_desktop"];

#[derive(Debug, Clone, Default, Deserialize)]
struct DogfoodEventInput {
    #[serde(default, alias = "eventId")]
    event_id: Option<String>,
    #[serde(default)]
    timestamp: Option<i64>,
    #[serde(default, alias = "runId")]
    run_id: Option<String>,
    #[serde(default, alias = "sessionId")]
    session_id: Option<String>,
    #[serde(default, alias = "paneId")]
    pane_id: Option<String>,
    #[serde(default, alias = "inputSource")]
    input_source: Option<String>,
    #[serde(default, alias = "actionType")]
    action_type: Option<String>,
    #[serde(default, alias = "taskRef")]
    task_ref: Option<String>,
    #[serde(default, alias = "durationMs")]
    duration_ms: Option<i64>,
    #[serde(default, alias = "payloadHash")]
    payload_hash: Option<String>,
    #[serde(default, alias = "payloadText")]
    payload_text: Option<String>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default, alias = "taskClass")]
    task_class: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default, alias = "reasoningEffort")]
    reasoning_effort: Option<String>,
}

#[derive(Debug, Clone)]
struct NormalizedDogfoodEvent {
    event_id: String,
    timestamp: i64,
    run_id: String,
    session_id: String,
    pane_id: String,
    input_source: String,
    action_type: String,
    task_ref: String,
    duration_ms: Option<i64>,
    payload_hash: String,
    mode: String,
    task_class: String,
    model: String,
    reasoning_effort: String,
}

#[derive(Debug, Clone)]
struct RunStartInput {
    run_id: String,
    mode: String,
    task_ref: String,
    task_class: String,
    started_at: i64,
    model: String,
    reasoning_effort: String,
    notes_hash: String,
}

#[derive(Debug, Clone)]
struct RunFinishInput {
    run_id: String,
    ended_at: i64,
    outcome: String,
    local_gate_failures: i64,
    ci_failures: i64,
    review_fix_loops: i64,
    rework_commits: i64,
}

#[derive(Debug)]
struct StoredEvent {
    timestamp: i64,
    run_id: String,
    session_id: String,
    input_source: String,
    action_type: String,
    task_ref: String,
}

#[derive(Debug)]
struct StoredRun {
    run_id: String,
    mode: String,
    task_ref: String,
    task_class: String,
    started_at: i64,
    ended_at: Option<i64>,
    outcome: String,
    local_gate_failures: i64,
    ci_failures: i64,
    review_fix_loops: i64,
    rework_commits: i64,
}

#[derive(Debug, Serialize)]
struct ShareCount {
    count: usize,
    share: f64,
}

pub fn run_dogfood_command(args: &[&String]) -> io::Result<()> {
    if args.is_empty() || should_print_help(args) {
        println!("{}", dogfood_usage());
        return Ok(());
    }

    match args[0].as_str() {
        "event" | "record-event" => run_event_command(&args[1..]),
        "run-start" => run_run_start_command(&args[1..]),
        "run-finish" => run_run_finish_command(&args[1..]),
        "stats" => run_stats_command(&args[1..]),
        value => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("unknown winsmux dogfood command: {value}"),
        )),
    }
}

fn dogfood_usage() -> &'static str {
    "usage:
  winsmux dogfood event --event-json <json> [--db <path>] [--json]
  winsmux dogfood run-start --run-id <id> --mode <codex_direct|winsmux_desktop> [--task-ref <ref>] [--task-class <class>] [--json]
  winsmux dogfood run-finish --run-id <id> --outcome <outcome> [--json]
  winsmux dogfood stats --since <date|epoch_ms> [--db <path>] [--json]"
}

fn should_print_help(args: &[&String]) -> bool {
    args.iter()
        .any(|arg| matches!(arg.as_str(), "-h" | "--help" | "help"))
}

fn run_event_command(args: &[&String]) -> io::Result<()> {
    let (db_path, json_output, input) = parse_event_options(args)?;
    let event = normalize_event(input)?;
    let connection = open_database(&db_path)?;
    record_event(&connection, &event)?;
    let payload = json!({
        "status": "recorded",
        "event_id": event.event_id,
        "run_id": event.run_id,
        "db_path": db_path.display().to_string(),
        "raw_payload_stored": false,
        "payload_hash_only": true,
    });
    if json_output {
        write_json(&payload)
    } else {
        println!(
            "dogfood event recorded: {}",
            payload["event_id"].as_str().unwrap_or_default()
        );
        Ok(())
    }
}

fn run_run_start_command(args: &[&String]) -> io::Result<()> {
    let (db_path, json_output, input) = parse_run_start_options(args)?;
    let connection = open_database(&db_path)?;
    upsert_run(&connection, &input)?;
    let payload = json!({
        "status": "recorded",
        "run_id": input.run_id,
        "mode": input.mode,
        "db_path": db_path.display().to_string(),
    });
    if json_output {
        write_json(&payload)
    } else {
        println!(
            "dogfood run started: {}",
            payload["run_id"].as_str().unwrap_or_default()
        );
        Ok(())
    }
}

fn run_run_finish_command(args: &[&String]) -> io::Result<()> {
    let (db_path, json_output, input) = parse_run_finish_options(args)?;
    let connection = open_database(&db_path)?;
    finish_run(&connection, &input)?;
    let payload = json!({
        "status": "recorded",
        "run_id": input.run_id,
        "outcome": input.outcome,
        "db_path": db_path.display().to_string(),
    });
    if json_output {
        write_json(&payload)
    } else {
        println!(
            "dogfood run finished: {}",
            payload["run_id"].as_str().unwrap_or_default()
        );
        Ok(())
    }
}

fn run_stats_command(args: &[&String]) -> io::Result<()> {
    let (db_path, since_ms, since_label, json_output) = parse_stats_options(args)?;
    let connection = open_database(&db_path)?;
    let mut payload = build_stats_payload(&connection, &db_path, since_ms, &since_label)?;
    if json_output {
        let export_path = default_dogfood_export_path()?;
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "export_path".to_string(),
                json!(export_path.display().to_string()),
            );
        }
        write_json_file(&export_path, &payload)?;
        write_json(&payload)
    } else {
        let summary = &payload["summary"];
        println!(
            "Dogfood stats since {since_label}: {} events, {} runs, {} comparable pairs",
            summary["event_count"].as_u64().unwrap_or_default(),
            summary["run_count"].as_u64().unwrap_or_default(),
            summary["comparison_ready_pairs"]
                .as_u64()
                .unwrap_or_default()
        );
        Ok(())
    }
}

fn parse_event_options(args: &[&String]) -> io::Result<(PathBuf, bool, DogfoodEventInput)> {
    let mut db_path = None;
    let mut json_output = false;
    let mut input = DogfoodEventInput::default();
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json_output = true;
                index += 1;
            }
            "--db" => {
                db_path = Some(PathBuf::from(required_option_value(args, index, "--db")?));
                index += 2;
            }
            "--event-json" => {
                input = serde_json::from_str(&required_option_value(args, index, "--event-json")?)
                    .map_err(|err| {
                        io::Error::new(
                            io::ErrorKind::InvalidInput,
                            format!("invalid --event-json payload: {err}"),
                        )
                    })?;
                index += 2;
            }
            "--event-id" => {
                input.event_id = Some(required_option_value(args, index, "--event-id")?);
                index += 2;
            }
            "--timestamp" => {
                input.timestamp = Some(parse_i64_option(args, index, "--timestamp")?);
                index += 2;
            }
            "--run-id" => {
                input.run_id = Some(required_option_value(args, index, "--run-id")?);
                index += 2;
            }
            "--session-id" => {
                input.session_id = Some(required_option_value(args, index, "--session-id")?);
                index += 2;
            }
            "--pane-id" => {
                input.pane_id = Some(required_option_value(args, index, "--pane-id")?);
                index += 2;
            }
            "--input-source" => {
                input.input_source = Some(required_option_value(args, index, "--input-source")?);
                index += 2;
            }
            "--action-type" => {
                input.action_type = Some(required_option_value(args, index, "--action-type")?);
                index += 2;
            }
            "--task-ref" => {
                input.task_ref = Some(required_option_value(args, index, "--task-ref")?);
                index += 2;
            }
            "--duration-ms" => {
                input.duration_ms = Some(parse_i64_option(args, index, "--duration-ms")?);
                index += 2;
            }
            "--payload-hash" => {
                input.payload_hash = Some(required_option_value(args, index, "--payload-hash")?);
                index += 2;
            }
            "--payload-text" => {
                input.payload_text = Some(required_option_value(args, index, "--payload-text")?);
                index += 2;
            }
            "--mode" => {
                input.mode = Some(required_option_value(args, index, "--mode")?);
                index += 2;
            }
            "--task-class" => {
                input.task_class = Some(required_option_value(args, index, "--task-class")?);
                index += 2;
            }
            "--model" => {
                input.model = Some(required_option_value(args, index, "--model")?);
                index += 2;
            }
            "--reasoning-effort" => {
                input.reasoning_effort =
                    Some(required_option_value(args, index, "--reasoning-effort")?);
                index += 2;
            }
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux dogfood event: {value}"),
                ));
            }
        }
    }

    Ok((
        db_path.unwrap_or(default_dogfood_db_path()?),
        json_output,
        input,
    ))
}

fn parse_run_start_options(args: &[&String]) -> io::Result<(PathBuf, bool, RunStartInput)> {
    let mut db_path = None;
    let mut json_output = false;
    let mut run_id = None;
    let mut mode = None;
    let mut task_ref = String::new();
    let mut task_class = String::new();
    let mut started_at = epoch_millis_now();
    let mut model = String::new();
    let mut reasoning_effort = String::new();
    let mut notes_hash = String::new();
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json_output = true;
                index += 1;
            }
            "--db" => {
                db_path = Some(PathBuf::from(required_option_value(args, index, "--db")?));
                index += 2;
            }
            "--run-id" => {
                run_id = Some(required_option_value(args, index, "--run-id")?);
                index += 2;
            }
            "--mode" => {
                mode = Some(required_option_value(args, index, "--mode")?);
                index += 2;
            }
            "--task-ref" => {
                task_ref = required_option_value(args, index, "--task-ref")?;
                index += 2;
            }
            "--task-class" => {
                task_class = required_option_value(args, index, "--task-class")?;
                index += 2;
            }
            "--started-at" => {
                started_at = parse_i64_option(args, index, "--started-at")?;
                index += 2;
            }
            "--model" => {
                model = required_option_value(args, index, "--model")?;
                index += 2;
            }
            "--reasoning-effort" => {
                reasoning_effort = required_option_value(args, index, "--reasoning-effort")?;
                index += 2;
            }
            "--notes-hash" => {
                notes_hash = required_option_value(args, index, "--notes-hash")?;
                index += 2;
            }
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux dogfood run-start: {value}"),
                ));
            }
        }
    }

    let mode = required_field(mode, "--mode")?;
    validate_one("mode", &mode, VALID_RUN_MODES)?;
    Ok((
        db_path.unwrap_or(default_dogfood_db_path()?),
        json_output,
        RunStartInput {
            run_id: required_field(run_id, "--run-id")?,
            mode,
            task_ref,
            task_class,
            started_at,
            model,
            reasoning_effort,
            notes_hash,
        },
    ))
}

fn parse_run_finish_options(args: &[&String]) -> io::Result<(PathBuf, bool, RunFinishInput)> {
    let mut db_path = None;
    let mut json_output = false;
    let mut run_id = None;
    let mut ended_at = epoch_millis_now();
    let mut outcome = None;
    let mut local_gate_failures = 0;
    let mut ci_failures = 0;
    let mut review_fix_loops = 0;
    let mut rework_commits = 0;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json_output = true;
                index += 1;
            }
            "--db" => {
                db_path = Some(PathBuf::from(required_option_value(args, index, "--db")?));
                index += 2;
            }
            "--run-id" => {
                run_id = Some(required_option_value(args, index, "--run-id")?);
                index += 2;
            }
            "--ended-at" => {
                ended_at = parse_i64_option(args, index, "--ended-at")?;
                index += 2;
            }
            "--outcome" => {
                outcome = Some(required_option_value(args, index, "--outcome")?);
                index += 2;
            }
            "--local-gate-failures" => {
                local_gate_failures = parse_i64_option(args, index, "--local-gate-failures")?;
                index += 2;
            }
            "--ci-failures" => {
                ci_failures = parse_i64_option(args, index, "--ci-failures")?;
                index += 2;
            }
            "--review-fix-loops" => {
                review_fix_loops = parse_i64_option(args, index, "--review-fix-loops")?;
                index += 2;
            }
            "--rework-commits" => {
                rework_commits = parse_i64_option(args, index, "--rework-commits")?;
                index += 2;
            }
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux dogfood run-finish: {value}"),
                ));
            }
        }
    }

    Ok((
        db_path.unwrap_or(default_dogfood_db_path()?),
        json_output,
        RunFinishInput {
            run_id: required_field(run_id, "--run-id")?,
            ended_at,
            outcome: required_field(outcome, "--outcome")?,
            local_gate_failures,
            ci_failures,
            review_fix_loops,
            rework_commits,
        },
    ))
}

fn parse_stats_options(args: &[&String]) -> io::Result<(PathBuf, i64, String, bool)> {
    let mut db_path = None;
    let mut json_output = false;
    let mut since = None;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json_output = true;
                index += 1;
            }
            "--db" => {
                db_path = Some(PathBuf::from(required_option_value(args, index, "--db")?));
                index += 2;
            }
            "--since" => {
                since = Some(required_option_value(args, index, "--since")?);
                index += 2;
            }
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux dogfood stats: {value}"),
                ));
            }
        }
    }

    let since_label = since.unwrap_or_else(|| "1970-01-01".to_string());
    Ok((
        db_path.unwrap_or(default_dogfood_db_path()?),
        parse_since_millis(&since_label)?,
        since_label,
        json_output,
    ))
}

fn normalize_event(input: DogfoodEventInput) -> io::Result<NormalizedDogfoodEvent> {
    let input_source = required_field(input.input_source, "input_source")?;
    validate_one("input_source", &input_source, VALID_INPUT_SOURCES)?;
    let action_type = required_field(input.action_type, "action_type")?;
    validate_one("action_type", &action_type, VALID_ACTION_TYPES)?;
    let mode = input.mode.unwrap_or_default();
    if !mode.trim().is_empty() {
        validate_one("mode", &mode, VALID_RUN_MODES)?;
    }
    let payload_hash = match (input.payload_hash, input.payload_text) {
        (Some(value), _) if !value.trim().is_empty() => value,
        (_, Some(value)) if !value.is_empty() => hash_payload(&value),
        _ => String::new(),
    };

    Ok(NormalizedDogfoodEvent {
        event_id: input
            .event_id
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(unique_event_id),
        timestamp: input.timestamp.unwrap_or_else(epoch_millis_now),
        run_id: input.run_id.unwrap_or_default(),
        session_id: required_field(input.session_id, "session_id")?,
        pane_id: required_field(input.pane_id, "pane_id")?,
        input_source,
        action_type,
        task_ref: input.task_ref.unwrap_or_default(),
        duration_ms: input.duration_ms,
        payload_hash,
        mode,
        task_class: input.task_class.unwrap_or_default(),
        model: input.model.unwrap_or_default(),
        reasoning_effort: input.reasoning_effort.unwrap_or_default(),
    })
}

fn open_database(path: &Path) -> io::Result<Connection> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let connection = Connection::open(path).map_err(sql_err)?;
    create_schema(&connection)?;
    Ok(connection)
}

fn create_schema(connection: &Connection) -> io::Result<()> {
    connection
        .execute_batch(
            "
            CREATE TABLE IF NOT EXISTS dogfood_runs (
                run_id TEXT PRIMARY KEY,
                mode TEXT NOT NULL,
                task_ref TEXT NOT NULL DEFAULT '',
                task_class TEXT NOT NULL DEFAULT '',
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                outcome TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                reasoning_effort TEXT NOT NULL DEFAULT '',
                local_gate_failures INTEGER NOT NULL DEFAULT 0,
                ci_failures INTEGER NOT NULL DEFAULT 0,
                review_fix_loops INTEGER NOT NULL DEFAULT 0,
                rework_commits INTEGER NOT NULL DEFAULT 0,
                notes_hash TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS dogfood_events (
                event_id TEXT PRIMARY KEY,
                timestamp INTEGER NOT NULL,
                run_id TEXT NOT NULL DEFAULT '',
                session_id TEXT NOT NULL,
                pane_id TEXT NOT NULL,
                input_source TEXT NOT NULL,
                action_type TEXT NOT NULL,
                task_ref TEXT NOT NULL DEFAULT '',
                duration_ms INTEGER,
                payload_hash TEXT NOT NULL DEFAULT '',
                created_at_utc TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_dogfood_events_timestamp
                ON dogfood_events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_dogfood_events_run_id
                ON dogfood_events(run_id);
            CREATE INDEX IF NOT EXISTS idx_dogfood_runs_mode_task
                ON dogfood_runs(mode, task_ref, task_class);
            ",
        )
        .map_err(sql_err)
}

fn record_event(connection: &Connection, event: &NormalizedDogfoodEvent) -> io::Result<()> {
    connection
        .execute(
            "
            INSERT INTO dogfood_events (
                event_id,
                timestamp,
                run_id,
                session_id,
                pane_id,
                input_source,
                action_type,
                task_ref,
                duration_ms,
                payload_hash,
                created_at_utc
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ",
            params![
                &event.event_id,
                event.timestamp,
                &event.run_id,
                &event.session_id,
                &event.pane_id,
                &event.input_source,
                &event.action_type,
                &event.task_ref,
                event.duration_ms,
                &event.payload_hash,
                generated_at(),
            ],
        )
        .map_err(sql_err)?;
    Ok(())
}

fn upsert_run(connection: &Connection, input: &RunStartInput) -> io::Result<()> {
    connection
        .execute(
            "
            INSERT INTO dogfood_runs (
                run_id,
                mode,
                task_ref,
                task_class,
                started_at,
                model,
                reasoning_effort,
                notes_hash
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(run_id) DO UPDATE SET
                mode = excluded.mode,
                task_ref = CASE WHEN excluded.task_ref <> '' THEN excluded.task_ref ELSE dogfood_runs.task_ref END,
                task_class = CASE WHEN excluded.task_class <> '' THEN excluded.task_class ELSE dogfood_runs.task_class END,
                started_at = MIN(dogfood_runs.started_at, excluded.started_at),
                model = CASE WHEN excluded.model <> '' THEN excluded.model ELSE dogfood_runs.model END,
                reasoning_effort = CASE WHEN excluded.reasoning_effort <> '' THEN excluded.reasoning_effort ELSE dogfood_runs.reasoning_effort END,
                notes_hash = CASE WHEN excluded.notes_hash <> '' THEN excluded.notes_hash ELSE dogfood_runs.notes_hash END
            ",
            params![
                &input.run_id,
                &input.mode,
                &input.task_ref,
                &input.task_class,
                input.started_at,
                &input.model,
                &input.reasoning_effort,
                &input.notes_hash,
            ],
        )
        .map_err(sql_err)?;
    Ok(())
}

fn finish_run(connection: &Connection, input: &RunFinishInput) -> io::Result<()> {
    let updated = connection
        .execute(
            "
            UPDATE dogfood_runs
            SET ended_at = ?2,
                outcome = ?3,
                local_gate_failures = ?4,
                ci_failures = ?5,
                review_fix_loops = ?6,
                rework_commits = ?7
            WHERE run_id = ?1
            ",
            params![
                &input.run_id,
                input.ended_at,
                &input.outcome,
                input.local_gate_failures,
                input.ci_failures,
                input.review_fix_loops,
                input.rework_commits,
            ],
        )
        .map_err(sql_err)?;
    if updated == 0 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("dogfood run '{}' was not found", input.run_id),
        ));
    }
    Ok(())
}

fn build_stats_payload(
    connection: &Connection,
    db_path: &Path,
    since_ms: i64,
    since_label: &str,
) -> io::Result<Value> {
    let events = load_events_since(connection, since_ms)?;
    let runs = load_runs_since(connection, since_ms)?;
    let input_sources = counted_share_map(
        events
            .iter()
            .map(|event| event.input_source.as_str())
            .collect::<Vec<_>>(),
    );
    let action_types = counted_share_map(
        events
            .iter()
            .map(|event| event.action_type.as_str())
            .collect::<Vec<_>>(),
    );
    let task_refs = task_ref_counts(&events);
    let run_modes = counted_share_map(runs.iter().map(|run| run.mode.as_str()).collect::<Vec<_>>());
    let comparison_ready_pairs = comparison_ready_pairs(&runs);
    let fallback = voice_keyboard_fallback(&events);
    let durations = run_duration_stats(&runs);
    let quality = quality_totals(&runs);
    let daily_command_counts = daily_command_counts(&events);

    Ok(json!({
        "generated_at": generated_at(),
        "db_path": db_path.display().to_string(),
        "since": since_label,
        "since_epoch_ms": since_ms,
        "summary": {
            "event_count": events.len(),
            "run_count": runs.len(),
            "command_count": events.iter().filter(|event| event.action_type == "command").count(),
            "completion_count": events.iter().filter(|event| event.action_type == "completion").count(),
            "comparison_ready_pairs": comparison_ready_pairs.len(),
            "raw_payload_stored": false,
            "payload_hash_only": true,
        },
        "input_sources": input_sources,
        "action_types": action_types,
        "task_refs": task_refs,
        "daily_command_counts": daily_command_counts,
        "runs": {
            "by_mode": run_modes,
            "duration_ms_by_mode": durations,
            "comparison_ready_pairs": comparison_ready_pairs,
        },
        "quality": quality,
        "voice_to_keyboard_fallback": fallback,
    }))
}

fn load_events_since(connection: &Connection, since_ms: i64) -> io::Result<Vec<StoredEvent>> {
    let mut statement = connection
        .prepare(
            "
            SELECT timestamp, run_id, session_id, input_source, action_type, task_ref
            FROM dogfood_events
            WHERE timestamp >= ?1
            ORDER BY timestamp ASC
            ",
        )
        .map_err(sql_err)?;
    let rows = statement
        .query_map(params![since_ms], |row| {
            Ok(StoredEvent {
                timestamp: row.get(0)?,
                run_id: row.get(1)?,
                session_id: row.get(2)?,
                input_source: row.get(3)?,
                action_type: row.get(4)?,
                task_ref: row.get(5)?,
            })
        })
        .map_err(sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(sql_err)
}

fn load_runs_since(connection: &Connection, since_ms: i64) -> io::Result<Vec<StoredRun>> {
    let mut statement = connection
        .prepare(
            "
            SELECT
                run_id,
                mode,
                task_ref,
                task_class,
                started_at,
                ended_at,
                outcome,
                local_gate_failures,
                ci_failures,
                review_fix_loops,
                rework_commits
            FROM dogfood_runs
            WHERE started_at >= ?1 OR (ended_at IS NOT NULL AND ended_at >= ?1)
            ORDER BY started_at ASC
            ",
        )
        .map_err(sql_err)?;
    let rows = statement
        .query_map(params![since_ms], |row| {
            Ok(StoredRun {
                run_id: row.get(0)?,
                mode: row.get(1)?,
                task_ref: row.get(2)?,
                task_class: row.get(3)?,
                started_at: row.get(4)?,
                ended_at: row.get(5)?,
                outcome: row.get(6)?,
                local_gate_failures: row.get(7)?,
                ci_failures: row.get(8)?,
                review_fix_loops: row.get(9)?,
                rework_commits: row.get(10)?,
            })
        })
        .map_err(sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(sql_err)
}

fn counted_share_map(values: Vec<&str>) -> BTreeMap<String, ShareCount> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for value in values.iter().filter(|value| !value.trim().is_empty()) {
        *counts.entry((*value).to_string()).or_default() += 1;
    }
    let total = values.len().max(1) as f64;
    counts
        .into_iter()
        .map(|(key, count)| {
            (
                key,
                ShareCount {
                    count,
                    share: ((count as f64 / total) * 1000.0).round() / 1000.0,
                },
            )
        })
        .collect()
}

fn daily_command_counts(events: &[StoredEvent]) -> Vec<Value> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for event in events.iter().filter(|event| event.action_type == "command") {
        *counts.entry(day_label(event.timestamp)).or_default() += 1;
    }
    counts
        .into_iter()
        .map(|(date, command_count)| json!({ "date": date, "command_count": command_count }))
        .collect()
}

fn task_ref_counts(events: &[StoredEvent]) -> Vec<Value> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for event in events
        .iter()
        .filter(|event| !event.task_ref.trim().is_empty())
    {
        *counts.entry(event.task_ref.clone()).or_default() += 1;
    }
    counts
        .into_iter()
        .map(|(task_ref, count)| json!({ "task_ref": task_ref, "event_count": count }))
        .collect()
}

fn comparison_ready_pairs(runs: &[StoredRun]) -> Vec<Value> {
    let mut groups: BTreeMap<(String, String), BTreeMap<String, Vec<&StoredRun>>> = BTreeMap::new();
    for run in runs.iter().filter(|run| !run.task_ref.trim().is_empty()) {
        groups
            .entry((run.task_ref.clone(), run.task_class.clone()))
            .or_default()
            .entry(run.mode.clone())
            .or_default()
            .push(run);
    }

    groups
        .into_iter()
        .filter_map(|((task_ref, task_class), by_mode)| {
            let codex = by_mode.get("codex_direct")?;
            let winsmux = by_mode.get("winsmux_desktop")?;
            Some(json!({
                "task_ref": task_ref,
                "task_class": task_class,
                "codex_direct_runs": codex.iter().map(|run| run.run_id.as_str()).collect::<Vec<_>>(),
                "winsmux_desktop_runs": winsmux.iter().map(|run| run.run_id.as_str()).collect::<Vec<_>>(),
            }))
        })
        .collect()
}

fn voice_keyboard_fallback(events: &[StoredEvent]) -> Value {
    let mut groups: BTreeMap<String, Vec<&StoredEvent>> = BTreeMap::new();
    for event in events
        .iter()
        .filter(|event| matches!(event.action_type.as_str(), "command" | "input"))
    {
        let key = if !event.run_id.trim().is_empty() {
            format!("run:{}", event.run_id)
        } else if !event.task_ref.trim().is_empty() {
            format!("task:{}", event.task_ref)
        } else {
            continue;
        };
        groups.entry(key).or_default().push(event);
    }

    let mut voice_group_count = 0usize;
    let mut fallback_group_count = 0usize;
    for group_events in groups.values_mut() {
        group_events.sort_by_key(|event| event.timestamp);
        let Some(first_voice_at) = group_events
            .iter()
            .find(|event| event.input_source == "voice")
            .map(|event| event.timestamp)
        else {
            continue;
        };
        voice_group_count += 1;
        if group_events
            .iter()
            .any(|event| event.input_source == "keyboard" && event.timestamp > first_voice_at)
        {
            fallback_group_count += 1;
        }
    }

    json!({
        "voice_group_count": voice_group_count,
        "fallback_group_count": fallback_group_count,
        "rate": if voice_group_count == 0 {
            0.0
        } else {
            ((fallback_group_count as f64 / voice_group_count as f64) * 1000.0).round() / 1000.0
        },
    })
}

fn run_duration_stats(runs: &[StoredRun]) -> Value {
    let mut by_mode: BTreeMap<String, Vec<i64>> = BTreeMap::new();
    for run in runs {
        if let Some(ended_at) = run.ended_at {
            if ended_at >= run.started_at {
                by_mode
                    .entry(run.mode.clone())
                    .or_default()
                    .push(ended_at - run.started_at);
            }
        }
    }

    let mut result = serde_json::Map::new();
    for (mode, mut durations) in by_mode {
        durations.sort_unstable();
        let count = durations.len();
        let median = median_i64(&durations);
        result.insert(
            mode,
            json!({
                "count": count,
                "median": median,
                "min": durations.first().copied(),
                "max": durations.last().copied(),
            }),
        );
    }
    Value::Object(result)
}

fn quality_totals(runs: &[StoredRun]) -> Value {
    let completed_outcomes = runs
        .iter()
        .filter(|run| !run.outcome.trim().is_empty())
        .map(|run| run.outcome.as_str())
        .collect::<HashSet<_>>();
    json!({
        "local_gate_failures": runs.iter().map(|run| run.local_gate_failures).sum::<i64>(),
        "ci_failures": runs.iter().map(|run| run.ci_failures).sum::<i64>(),
        "review_fix_loops": runs.iter().map(|run| run.review_fix_loops).sum::<i64>(),
        "rework_commits": runs.iter().map(|run| run.rework_commits).sum::<i64>(),
        "outcomes": completed_outcomes.into_iter().collect::<BTreeSet<_>>(),
    })
}

fn median_i64(values: &[i64]) -> Option<i64> {
    if values.is_empty() {
        return None;
    }
    Some(values[values.len() / 2])
}

fn parse_since_millis(value: &str) -> io::Result<i64> {
    if let Ok(epoch_ms) = value.parse::<i64>() {
        return Ok(epoch_ms);
    }
    if let Ok(date_time) = DateTime::parse_from_rfc3339(value) {
        return Ok(date_time.timestamp_millis());
    }
    if let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") {
        let Some(date_time) = date.and_hms_opt(0, 0, 0) else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid --since date: {value}"),
            ));
        };
        return Ok(Utc.from_utc_datetime(&date_time).timestamp_millis());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("invalid --since value: {value}"),
    ))
}

fn default_dogfood_db_path() -> io::Result<PathBuf> {
    if let Ok(path) = env::var("WINSMUX_DOGFOOD_DB") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            return Ok(PathBuf::from(trimmed));
        }
    }

    Ok(default_dogfood_root_path()?.join("events.db"))
}

fn default_dogfood_export_path() -> io::Result<PathBuf> {
    Ok(default_dogfood_root_path()?
        .join("exports")
        .join(format!("dogfood-stats-{}.json", file_timestamp())))
}

fn default_dogfood_root_path() -> io::Result<PathBuf> {
    let root = if let Ok(path) = env::var("WINSMUX_DOGFOOD_ROOT") {
        PathBuf::from(path)
    } else if let Ok(appdata) = env::var("APPDATA") {
        PathBuf::from(appdata).join("winsmux").join("dogfood")
    } else {
        home_dir()?.join(".winsmux").join("dogfood")
    };
    Ok(root)
}

fn home_dir() -> io::Result<PathBuf> {
    env::var("USERPROFILE")
        .or_else(|_| env::var("HOME"))
        .map(PathBuf::from)
        .map_err(|_| io::Error::new(io::ErrorKind::NotFound, "could not resolve user home"))
}

fn generated_at() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn file_timestamp() -> String {
    generated_at()
        .chars()
        .map(|ch| match ch {
            '0'..='9' | 'A'..='Z' | 'a'..='z' => ch,
            _ => '-',
        })
        .collect()
}

fn epoch_millis_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

fn day_label(timestamp: i64) -> String {
    Utc.timestamp_millis_opt(timestamp)
        .single()
        .map(|date_time| date_time.date_naive().format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "invalid".to_string())
}

fn unique_event_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let counter = DOGFOOD_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut hasher = Sha256::new();
    hasher.update(nanos.to_le_bytes());
    hasher.update(std::process::id().to_le_bytes());
    hasher.update(counter.to_le_bytes());
    let digest = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

fn hash_payload(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn required_option_value(args: &[&String], index: usize, name: &str) -> io::Result<String> {
    args.get(index + 1)
        .map(|value| value.to_string())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("missing value after {name}"),
            )
        })
}

fn parse_i64_option(args: &[&String], index: usize, name: &str) -> io::Result<i64> {
    let value = required_option_value(args, index, name)?;
    value.parse::<i64>().map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid {name} value '{value}': {err}"),
        )
    })
}

fn required_field(value: Option<String>, name: &str) -> io::Result<String> {
    let value = value.unwrap_or_default();
    if value.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("missing required dogfood field: {name}"),
        ));
    }
    Ok(value)
}

fn validate_one(name: &str, value: &str, allowed: &[&str]) -> io::Result<()> {
    if allowed.iter().any(|candidate| *candidate == value) {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!(
            "invalid dogfood {name}: {value}; expected one of {}",
            allowed.join(", ")
        ),
    ))
}

fn sql_err(err: rusqlite::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err)
}

fn write_json<T: Serialize>(value: &T) -> io::Result<()> {
    serde_json::to_writer(io::stdout().lock(), value)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    println!();
    Ok(())
}

fn write_json_file<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    fs::write(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db(name: &str) -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after epoch")
            .as_nanos();
        env::temp_dir().join(format!(
            "winsmux-dogfood-{name}-{}-{suffix}.db",
            std::process::id()
        ))
    }

    fn sample_event(run_id: &str, source: &str, timestamp: i64) -> NormalizedDogfoodEvent {
        normalize_event(DogfoodEventInput {
            event_id: None,
            timestamp: Some(timestamp),
            run_id: Some(run_id.to_string()),
            session_id: Some("session-1".to_string()),
            pane_id: Some("operator".to_string()),
            input_source: Some(source.to_string()),
            action_type: Some("command".to_string()),
            task_ref: Some("TASK-500".to_string()),
            duration_ms: Some(1200),
            payload_hash: None,
            payload_text: Some("do not store this raw command".to_string()),
            mode: Some("winsmux_desktop".to_string()),
            task_class: Some("ui".to_string()),
            model: Some("model-a".to_string()),
            reasoning_effort: Some("high".to_string()),
        })
        .expect("sample event should normalize")
    }

    #[test]
    fn event_hashes_payload_text_without_storing_raw_text() {
        let db_path = temp_db("privacy");
        let connection = open_database(&db_path).expect("database should open");
        let event = sample_event("run-1", "voice", 1_700_000_000_000);

        record_event(&connection, &event).expect("event should record");

        let stored_hash: String = connection
            .query_row(
                "SELECT payload_hash FROM dogfood_events WHERE event_id = ?1",
                params![&event.event_id],
                |row| row.get(0),
            )
            .expect("stored event should exist");
        let raw_text_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM dogfood_events WHERE payload_hash = 'do not store this raw command'",
                [],
                |row| row.get(0),
            )
            .expect("privacy query should run");

        assert_eq!(stored_hash, hash_payload("do not store this raw command"));
        assert_eq!(raw_text_count, 0);
        let _ = fs::remove_file(db_path);
    }

    #[test]
    fn stats_reports_pairs_and_voice_fallback() {
        let db_path = temp_db("stats");
        let connection = open_database(&db_path).expect("database should open");
        record_event(
            &connection,
            &sample_event("winsmux-run", "voice", 1_700_000_000_000),
        )
        .expect("voice event should record");
        record_event(
            &connection,
            &sample_event("winsmux-run", "keyboard", 1_700_000_000_100),
        )
        .expect("keyboard event should record");
        upsert_run(
            &connection,
            &RunStartInput {
                run_id: "winsmux-run".to_string(),
                mode: "winsmux_desktop".to_string(),
                task_ref: "TASK-500".to_string(),
                task_class: "ui".to_string(),
                started_at: 1_700_000_000_000,
                model: "model-a".to_string(),
                reasoning_effort: "high".to_string(),
                notes_hash: String::new(),
            },
        )
        .expect("winsmux run should record");
        upsert_run(
            &connection,
            &RunStartInput {
                run_id: "codex-run".to_string(),
                mode: "codex_direct".to_string(),
                task_ref: "TASK-500".to_string(),
                task_class: "ui".to_string(),
                started_at: 1_700_000_000_000,
                model: "model-a".to_string(),
                reasoning_effort: "high".to_string(),
                notes_hash: String::new(),
            },
        )
        .expect("codex run should record");

        let payload = build_stats_payload(&connection, &db_path, 1_600_000_000_000, "2020-09-13")
            .expect("stats should build");

        assert_eq!(payload["summary"]["event_count"], 2);
        assert_eq!(payload["summary"]["comparison_ready_pairs"], 1);
        assert_eq!(
            payload["voice_to_keyboard_fallback"]["fallback_group_count"],
            1
        );
        assert_eq!(payload["input_sources"]["voice"]["count"], 1);
        assert_eq!(payload["daily_command_counts"][0]["date"], "2023-11-14");
        assert_eq!(
            payload["daily_command_counts"][0]["command_count"],
            serde_json::json!(2)
        );
        let _ = fs::remove_file(db_path);
    }

    #[test]
    fn event_with_run_id_does_not_create_run_row() {
        let db_path = temp_db("event-run-boundary");
        let connection = open_database(&db_path).expect("database should open");
        let event = normalize_event(DogfoodEventInput {
            event_id: None,
            timestamp: Some(1_700_000_000_000),
            run_id: Some("existing-run".to_string()),
            session_id: Some("session-1".to_string()),
            pane_id: Some("operator".to_string()),
            input_source: Some("shortcut".to_string()),
            action_type: Some("approval".to_string()),
            task_ref: Some("TASK-500".to_string()),
            duration_ms: Some(50),
            payload_hash: Some(hash_payload("button click")),
            payload_text: None,
            mode: Some("winsmux_desktop".to_string()),
            task_class: Some("details-promote".to_string()),
            model: Some("model-a".to_string()),
            reasoning_effort: Some("high".to_string()),
        })
        .expect("event should normalize");

        record_event(&connection, &event).expect("event should record");

        let run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM dogfood_runs", [], |row| row.get(0))
            .expect("run count query should work");

        assert_eq!(run_count, 0);
        let _ = fs::remove_file(db_path);
    }

    #[test]
    fn fallback_ignores_unkeyed_session_history() {
        let events = vec![
            StoredEvent {
                timestamp: 1,
                run_id: String::new(),
                session_id: "session-1".to_string(),
                input_source: "voice".to_string(),
                action_type: "command".to_string(),
                task_ref: String::new(),
            },
            StoredEvent {
                timestamp: 2,
                run_id: String::new(),
                session_id: "session-1".to_string(),
                input_source: "keyboard".to_string(),
                action_type: "command".to_string(),
                task_ref: String::new(),
            },
        ];

        let payload = voice_keyboard_fallback(&events);

        assert_eq!(payload["voice_group_count"], 0);
        assert_eq!(payload["fallback_group_count"], 0);
    }

    #[test]
    fn fallback_counts_keyed_input_transition() {
        let events = vec![
            StoredEvent {
                timestamp: 1,
                run_id: String::new(),
                session_id: "session-1".to_string(),
                input_source: "voice".to_string(),
                action_type: "input".to_string(),
                task_ref: "desktop-command-1".to_string(),
            },
            StoredEvent {
                timestamp: 2,
                run_id: String::new(),
                session_id: "session-1".to_string(),
                input_source: "keyboard".to_string(),
                action_type: "input".to_string(),
                task_ref: "desktop-command-1".to_string(),
            },
            StoredEvent {
                timestamp: 3,
                run_id: String::new(),
                session_id: "session-1".to_string(),
                input_source: "keyboard".to_string(),
                action_type: "command".to_string(),
                task_ref: "desktop-command-1".to_string(),
            },
        ];

        let payload = voice_keyboard_fallback(&events);

        assert_eq!(payload["voice_group_count"], 1);
        assert_eq!(payload["fallback_group_count"], 1);
    }

    #[test]
    fn generated_event_id_uses_uuid_shape() {
        let event = sample_event("run-uuid", "keyboard", 1_700_000_000_000);
        assert_eq!(event.event_id.len(), 36);
        assert_eq!(event.event_id.as_bytes()[14], b'4');
        assert_eq!(event.event_id.matches('-').count(), 4);
    }

    #[test]
    fn parse_since_accepts_yyyy_mm_dd() {
        assert_eq!(parse_since_millis("1970-01-02").unwrap(), 86_400_000);
    }

    #[test]
    fn invalid_input_source_is_rejected() {
        let result = normalize_event(DogfoodEventInput {
            session_id: Some("session-1".to_string()),
            pane_id: Some("operator".to_string()),
            input_source: Some("mouse".to_string()),
            action_type: Some("command".to_string()),
            ..DogfoodEventInput::default()
        });

        assert!(result.is_err());
    }
}
