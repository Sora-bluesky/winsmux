use std::{
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
    thread,
    time::Duration,
};

use serde_json::{json, Map, Value};

use crate::event_contract::EventRecord;

const USAGE: &str = "usage: winsmux events [cursor] [--follow] [--json] [--project-dir <path>]";
const FOLLOW_POLL: Duration = Duration::from_millis(100);

struct EventsOptions {
    json: bool,
    follow: bool,
    project_dir: PathBuf,
    cursor: usize,
}

pub fn run_events_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("{USAGE}");
        return Ok(());
    }
    let options = parse_events_options(args)?;
    if !options.json {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE));
    }
    if !options.project_dir.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "project directory not found: {}",
                options.project_dir.display()
            ),
        ));
    }

    if options.follow {
        return follow_condensed_events(&options);
    }

    let lines = read_events_jsonl_lines(&options.project_dir, false)?;
    let mut events = Vec::new();
    for (index, line) in lines.iter().enumerate().skip(options.cursor) {
        if let Some(event) = map_complete_event_line(line, index)? {
            events.push(event);
        }
    }
    write_events_wrapper(lines.len(), events)
}

fn follow_condensed_events(options: &EventsOptions) -> io::Result<()> {
    let mut cursor = options.cursor;
    loop {
        let lines = read_events_jsonl_lines(&options.project_dir, true)?;
        if lines.len() < cursor {
            cursor = 0;
        }
        for (index, line) in lines.iter().enumerate().skip(cursor) {
            if let Some(event) = map_complete_event_line(line, index)? {
                write_events_wrapper(index + 1, vec![event])?;
            }
            cursor = index + 1;
        }
        thread::sleep(FOLLOW_POLL);
    }
}

fn write_events_wrapper(cursor: usize, events: Vec<Value>) -> io::Result<()> {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(
        &mut stdout,
        &json!({
            "cursor": cursor,
            "events": events,
        }),
    )
    .map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize condensed events: {err}"),
        )
    })?;
    writeln!(stdout)?;
    stdout.flush()
}

fn read_events_jsonl_lines(project_dir: &Path, drop_torn_tail: bool) -> io::Result<Vec<String>> {
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    if !events_path.is_file() {
        return Ok(Vec::new());
    }
    let raw = fs::read_to_string(&events_path).map_err(|err| {
        io::Error::new(err.kind(), format!("failed to read event log: {}", err))
    })?;
    let body = if drop_torn_tail && !raw.ends_with('\n') {
        match raw.rfind('\n') {
            Some(idx) => &raw[..=idx],
            None => return Ok(Vec::new()),
        }
    } else {
        raw.as_str()
    };
    Ok(body
        .lines()
        .enumerate()
        .filter_map(|(index, line)| {
            let line = if index == 0 {
                line.trim_start_matches('\u{feff}')
            } else {
                line
            };
            if line.trim().is_empty() {
                None
            } else {
                Some(line.to_string())
            }
        })
        .collect())
}

fn map_complete_event_line(line: &str, index: usize) -> io::Result<Option<Value>> {
    let line_number = index + 1;
    let record: EventRecord = serde_json::from_str(line).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to parse event line {line_number}: {err}"),
        )
    })?;
    record.validate().map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("event line {line_number}: {err}"),
        )
    })?;
    Ok(map_condensed_event(&record, index))
}

fn map_condensed_event(record: &EventRecord, cursor: usize) -> Option<Value> {
    let data = record.data.as_object();
    let data_status = event_data_string(data, "status");
    let status = first_non_empty(&record.status, &data_status);
    let pane_id = first_non_empty(&record.pane_id, &event_data_string(data, "pane_id"));
    let role = first_non_empty(&record.role, &event_data_string(data, "role"));
    let run_id = first_non_empty(&record.run_id, &event_data_string(data, "run_id"));
    let task_id = first_non_empty(&record.task_id, &event_data_string(data, "task_id"));
    let stop_reason = first_non_empty(&record.exit_reason, &record.status);

    match record.event.as_str() {
        "pane.started" => Some(json!({
            "type": "thread_created",
            "cursor": cursor,
            "pane_id": pane_id,
            "run_id": run_id,
            "role": role,
        })),
        "agent.heartbeat.started" => Some(json!({
            "type": "status_running",
            "cursor": cursor,
            "pane_id": pane_id,
            "run_id": run_id,
        })),
        "monitor.status" if status == "running" => Some(json!({
            "type": "status_running",
            "cursor": cursor,
            "pane_id": pane_id,
            "run_id": run_id,
        })),
        "pane.idle" | "pane.completed" | "agent.heartbeat.completed" => Some(json!({
            "type": "status_idle",
            "cursor": cursor,
            "stop_reason": stop_reason,
        })),
        "monitor.status" if matches!(status.as_str(), "idle" | "completed") => Some(json!({
            "type": "status_idle",
            "cursor": cursor,
            "stop_reason": stop_reason,
        })),
        "pane.consult_result" | "operator.commit_ready" => Some(json!({
            "type": "message_received",
            "cursor": cursor,
            "run_id": run_id,
            "task_id": task_id,
        })),
        "approval_waiting"
        | "pane.approval_waiting"
        | "board.approval.requested"
        | "operator.review_requested"
        | "operator.blocked"
        | "agent.heartbeat.blocked"
        | "pane.crashed"
        | "pane.hung"
        | "pane.stalled" => Some(json!({
            "type": "requires_action",
            "cursor": cursor,
            "pane_id": pane_id,
            "kind": record.event.as_str(),
        })),
        "monitor.status"
            if matches!(
                status.as_str(),
                "approval_waiting" | "blocked" | "crashed" | "hung" | "stalled"
            ) =>
        {
            Some(json!({
                "type": "requires_action",
                "cursor": cursor,
                "pane_id": pane_id,
                "kind": status,
            }))
        }
        _ => None,
    }
}

fn parse_events_options(args: &[&String]) -> io::Result<EventsOptions> {
    let mut json = false;
    let mut follow = false;
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
            "--follow" => {
                follow = true;
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
                return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() > 1 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE));
    }

    let mut cursor = 0usize;
    if let Some(raw_cursor) = positionals.first() {
        let parsed = raw_cursor
            .parse::<i32>()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, USAGE))?;
        if parsed > 0 {
            cursor = parsed as usize;
        }
    }

    Ok(EventsOptions {
        json,
        follow,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        cursor,
    })
}

fn first_non_empty(first: &str, second: &str) -> String {
    if first.trim().is_empty() {
        second.to_string()
    } else {
        first.to_string()
    }
}

fn event_data_string(data: Option<&Map<String, Value>>, key: &str) -> String {
    data.and_then(|map| map.get(key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}
