use crate::event_contract::{parse_event_jsonl, EventRecord};
use chrono::{SecondsFormat, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

const DEFAULT_LIMIT: usize = 20;
const MAX_LIMIT: usize = 500;

#[derive(Debug)]
pub struct SearchLedger {
    conn: Connection,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SearchLedgerEntrySummary {
    pub id: i64,
    pub ordinal: usize,
    pub timestamp: String,
    pub event: String,
    pub session: String,
    pub message: String,
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub status: String,
    pub source: String,
    pub branch: String,
    pub run_id: String,
    pub task_id: String,
    pub head_sha: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SearchLedgerHit {
    #[serde(flatten)]
    pub entry: SearchLedgerEntrySummary,
    pub snippet: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SearchLedgerTimelineItem {
    #[serde(flatten)]
    pub entry: SearchLedgerEntrySummary,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SearchLedgerDetail {
    #[serde(flatten)]
    pub entry: SearchLedgerEntrySummary,
    pub detail: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum SearchLedgerPayload {
    Search(SearchLedgerSearchPayload),
    Timeline(SearchLedgerTimelinePayload),
    Detail(SearchLedgerDetailPayload),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SearchLedgerSearchPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub sidecar_path: String,
    pub indexed_count: usize,
    pub query: String,
    pub hits: Vec<SearchLedgerHit>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SearchLedgerTimelinePayload {
    pub generated_at: String,
    pub project_dir: String,
    pub sidecar_path: String,
    pub indexed_count: usize,
    pub items: Vec<SearchLedgerTimelineItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SearchLedgerDetailPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub sidecar_path: String,
    pub indexed_count: usize,
    pub detail: Option<SearchLedgerDetail>,
}

#[derive(Debug, Clone, Default)]
pub struct SearchLedgerTimelineFilter {
    pub query: Option<String>,
    pub run_id: Option<String>,
    pub task_id: Option<String>,
    pub pane_id: Option<String>,
    pub limit: usize,
    pub descending: bool,
}

impl SearchLedger {
    pub fn open_in_memory() -> Result<Self, String> {
        let ledger = Self {
            conn: Connection::open_in_memory()
                .map_err(|err| format!("failed to open in-memory search ledger: {err}"))?,
        };
        ledger.initialize_schema()?;
        Ok(ledger)
    }

    pub fn open_sidecar(path: impl AsRef<Path>) -> Result<Self, String> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|err| {
                format!(
                    "failed to create search ledger directory '{}': {err}",
                    parent.display()
                )
            })?;
        }
        let ledger = Self {
            conn: Connection::open(path).map_err(|err| {
                format!("failed to open search ledger '{}': {err}", path.display())
            })?,
        };
        ledger.initialize_schema()?;
        Ok(ledger)
    }

    fn initialize_schema(&self) -> Result<(), String> {
        self.conn
            .execute_batch(
                r#"
                PRAGMA secure_delete = ON;
                CREATE TABLE IF NOT EXISTS ledger_entries (
                    id INTEGER PRIMARY KEY,
                    ordinal INTEGER NOT NULL,
                    timestamp TEXT NOT NULL,
                    event TEXT NOT NULL,
                    session TEXT NOT NULL,
                    message TEXT NOT NULL,
                    label TEXT NOT NULL,
                    pane_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    status TEXT NOT NULL,
                    source TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    run_id TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    head_sha TEXT NOT NULL,
                    detail_json TEXT NOT NULL,
                    body TEXT NOT NULL
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS ledger_entries_fts USING fts5(
                    event,
                    message,
                    label,
                    pane_id,
                    role,
                    status,
                    source,
                    branch,
                    run_id,
                    task_id,
                    head_sha,
                    body
                );
                "#,
            )
            .map_err(|err| format!("failed to initialize search ledger schema: {err}"))
    }

    pub fn rebuild_from_events_jsonl(&mut self, events_jsonl: &str) -> Result<usize, String> {
        let events = parse_event_jsonl(events_jsonl)?;
        let tx = self
            .conn
            .transaction()
            .map_err(|err| format!("failed to start search ledger rebuild: {err}"))?;
        tx.execute("DELETE FROM ledger_entries_fts", [])
            .map_err(|err| format!("failed to clear search ledger FTS table: {err}"))?;
        tx.execute("DELETE FROM ledger_entries", [])
            .map_err(|err| format!("failed to clear search ledger entries: {err}"))?;

        let mut indexed = 0usize;
        for (ordinal, event) in events.iter().enumerate() {
            if !should_index_event(event) {
                continue;
            }
            let branch = event_field_with_data_fallback(&event.branch, event, "branch");
            let run_id = event_field_with_data_fallback(&event.run_id, event, "run_id");
            let task_id = event_field_with_data_fallback(&event.task_id, event, "task_id");
            let head_sha = event_field_with_data_fallback(&event.head_sha, event, "head_sha");
            let message = redact_sensitive_text(&event.message);
            let detail = detail_json(event);
            let detail_json = serde_json::to_string(&detail)
                .map_err(|err| format!("failed to encode search ledger detail: {err}"))?;
            let body = searchable_body(event, &detail);
            tx.execute(
                r#"
                INSERT INTO ledger_entries (
                    ordinal, timestamp, event, session, message, label, pane_id, role, status,
                    source, branch, run_id, task_id, head_sha, detail_json, body
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                "#,
                params![
                    ordinal as i64,
                    event.timestamp,
                    event.event,
                    event.session,
                    message,
                    event.label,
                    event.pane_id,
                    event.role,
                    event.status,
                    event.source,
                    branch,
                    run_id,
                    task_id,
                    head_sha,
                    detail_json,
                    body,
                ],
            )
            .map_err(|err| format!("failed to insert search ledger entry: {err}"))?;
            let rowid = tx.last_insert_rowid();
            tx.execute(
                r#"
                INSERT INTO ledger_entries_fts (
                    rowid, event, message, label, pane_id, role, status, source, branch,
                    run_id, task_id, head_sha, body
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                "#,
                params![
                    rowid,
                    event.event,
                    message,
                    event.label,
                    event.pane_id,
                    event.role,
                    event.status,
                    event.source,
                    branch,
                    run_id,
                    task_id,
                    head_sha,
                    body,
                ],
            )
            .map_err(|err| format!("failed to insert search ledger FTS entry: {err}"))?;
            indexed += 1;
        }

        tx.commit()
            .map_err(|err| format!("failed to commit search ledger rebuild: {err}"))?;
        self.scrub_deleted_content()?;
        Ok(indexed)
    }

    fn scrub_deleted_content(&self) -> Result<(), String> {
        self.conn
            .execute_batch(
                r#"
                PRAGMA secure_delete = ON;
                VACUUM;
                "#,
            )
            .map_err(|err| format!("failed to scrub deleted search ledger content: {err}"))
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchLedgerHit>, String> {
        self.search_filtered(query, None, None, None, limit)
    }

    pub fn search_filtered(
        &self,
        query: &str,
        run_id: Option<&str>,
        task_id: Option<&str>,
        pane_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<SearchLedgerHit>, String> {
        let query = query.trim();
        if query.is_empty() {
            return Err("search query must be non-empty".to_string());
        }
        let limit = normalize_limit(limit);
        let fts_query = fts5_query(query);
        let run_id = run_id.unwrap_or_default();
        let task_id = task_id.unwrap_or_default();
        let pane_id = pane_id.unwrap_or_default();
        let mut stmt = self
            .conn
            .prepare(
                r#"
                SELECT
                    e.id, e.ordinal, e.timestamp, e.event, e.session, e.message, e.label,
                    e.pane_id, e.role, e.status, e.source, e.branch, e.run_id, e.task_id,
                    e.head_sha,
                    snippet(ledger_entries_fts, 11, '[', ']', '...', 24) AS snippet
                FROM ledger_entries_fts
                JOIN ledger_entries e ON e.id = ledger_entries_fts.rowid
                WHERE ledger_entries_fts MATCH ?1
                  AND (?2 = '' OR e.run_id = ?2)
                  AND (?3 = '' OR e.task_id = ?3)
                  AND (?4 = '' OR e.pane_id = ?4)
                ORDER BY e.timestamp DESC, e.ordinal DESC
                LIMIT ?5
                "#,
            )
            .map_err(|err| format!("failed to prepare search ledger query: {err}"))?;
        let rows = stmt
            .query_map(
                params![fts_query, run_id, task_id, pane_id, limit as i64],
                |row| {
                    Ok(SearchLedgerHit {
                        entry: row_to_summary(row)?,
                        snippet: row.get(15)?,
                    })
                },
            )
            .map_err(|err| format!("failed to run search ledger query: {err}"))?;
        collect_rows(rows)
    }

    pub fn timeline(
        &self,
        filter: SearchLedgerTimelineFilter,
    ) -> Result<Vec<SearchLedgerTimelineItem>, String> {
        let limit = normalize_limit(filter.limit);
        let run_id = filter.run_id.unwrap_or_default();
        let task_id = filter.task_id.unwrap_or_default();
        let pane_id = filter.pane_id.unwrap_or_default();
        let order = if filter.descending { "DESC" } else { "ASC" };

        if let Some(query) = filter
            .query
            .as_deref()
            .map(str::trim)
            .filter(|q| !q.is_empty())
        {
            let fts_query = fts5_query(query);
            let sql = format!(
                r#"
                SELECT
                    e.id, e.ordinal, e.timestamp, e.event, e.session, e.message, e.label,
                    e.pane_id, e.role, e.status, e.source, e.branch, e.run_id, e.task_id,
                    e.head_sha
                FROM ledger_entries_fts
                JOIN ledger_entries e ON e.id = ledger_entries_fts.rowid
                WHERE ledger_entries_fts MATCH ?1
                  AND (?2 = '' OR e.run_id = ?2)
                  AND (?3 = '' OR e.task_id = ?3)
                  AND (?4 = '' OR e.pane_id = ?4)
                ORDER BY e.timestamp {order}, e.ordinal {order}
                LIMIT ?5
                "#
            );
            let mut stmt = self
                .conn
                .prepare(&sql)
                .map_err(|err| format!("failed to prepare search ledger timeline: {err}"))?;
            let rows = stmt
                .query_map(
                    params![fts_query, run_id, task_id, pane_id, limit as i64],
                    |row| {
                        Ok(SearchLedgerTimelineItem {
                            entry: row_to_summary(row)?,
                        })
                    },
                )
                .map_err(|err| format!("failed to run search ledger timeline: {err}"))?;
            return collect_rows(rows);
        }

        let sql = format!(
            r#"
            SELECT
                id, ordinal, timestamp, event, session, message, label, pane_id, role, status,
                source, branch, run_id, task_id, head_sha
            FROM ledger_entries
            WHERE (?1 = '' OR run_id = ?1)
              AND (?2 = '' OR task_id = ?2)
              AND (?3 = '' OR pane_id = ?3)
            ORDER BY timestamp {order}, ordinal {order}
            LIMIT ?4
            "#
        );
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|err| format!("failed to prepare search ledger timeline: {err}"))?;
        let rows = stmt
            .query_map(params![run_id, task_id, pane_id, limit as i64], |row| {
                Ok(SearchLedgerTimelineItem {
                    entry: row_to_summary(row)?,
                })
            })
            .map_err(|err| format!("failed to run search ledger timeline: {err}"))?;
        collect_rows(rows)
    }

    pub fn detail(&self, id: i64) -> Result<Option<SearchLedgerDetail>, String> {
        let mut stmt = self
            .conn
            .prepare(
                r#"
                SELECT
                    id, ordinal, timestamp, event, session, message, label, pane_id, role, status,
                    source, branch, run_id, task_id, head_sha, detail_json
                FROM ledger_entries
                WHERE id = ?1
                "#,
            )
            .map_err(|err| format!("failed to prepare search ledger detail lookup: {err}"))?;
        stmt.query_row(params![id], |row| {
            let detail_json: String = row.get(15)?;
            let detail = serde_json::from_str(&detail_json).map_err(|err| {
                rusqlite::Error::FromSqlConversionFailure(
                    15,
                    rusqlite::types::Type::Text,
                    Box::new(err),
                )
            })?;
            Ok(SearchLedgerDetail {
                entry: row_to_summary(row)?,
                detail,
            })
        })
        .optional()
        .map_err(|err| format!("failed to load search ledger detail: {err}"))
    }
}

pub fn run_search_ledger_command(args: &[&String]) -> io::Result<()> {
    let options = SearchLedgerCliOptions::parse(args)?;
    if options.help {
        print_usage();
        return Ok(());
    }
    if !options.json {
        return Err(invalid_input(
            "search-ledger currently requires --json for stable output",
        ));
    }

    let mut ledger = SearchLedger::open_sidecar(&options.sidecar_path).map_err(other_error)?;
    let events_jsonl = read_events_jsonl(&options.project_dir)?;
    let indexed_count = ledger
        .rebuild_from_events_jsonl(&events_jsonl)
        .map_err(other_error)?;
    let generated_at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
    let project_dir = options.project_dir.to_string_lossy().to_string();
    let sidecar_path = options.sidecar_path.to_string_lossy().to_string();

    match options.mode {
        SearchLedgerMode::Search => {
            let query = options
                .query
                .ok_or_else(|| invalid_input("missing search query"))?;
            let hits = ledger
                .search_filtered(
                    &query,
                    options.run_id.as_deref(),
                    options.task_id.as_deref(),
                    options.pane_id.as_deref(),
                    options.limit,
                )
                .map_err(other_error)?;
            write_json(&SearchLedgerPayload::Search(SearchLedgerSearchPayload {
                generated_at,
                project_dir,
                sidecar_path,
                indexed_count,
                query,
                hits,
            }))
        }
        SearchLedgerMode::Timeline => {
            let items = ledger
                .timeline(SearchLedgerTimelineFilter {
                    query: options.query,
                    run_id: options.run_id,
                    task_id: options.task_id,
                    pane_id: options.pane_id,
                    limit: options.limit,
                    descending: options.descending,
                })
                .map_err(other_error)?;
            write_json(&SearchLedgerPayload::Timeline(
                SearchLedgerTimelinePayload {
                    generated_at,
                    project_dir,
                    sidecar_path,
                    indexed_count,
                    items,
                },
            ))
        }
        SearchLedgerMode::Detail => {
            let id = options
                .detail_id
                .ok_or_else(|| invalid_input("missing detail id"))?;
            let detail = ledger.detail(id).map_err(other_error)?;
            write_json(&SearchLedgerPayload::Detail(SearchLedgerDetailPayload {
                generated_at,
                project_dir,
                sidecar_path,
                indexed_count,
                detail,
            }))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SearchLedgerMode {
    Search,
    Timeline,
    Detail,
}

#[derive(Debug)]
struct SearchLedgerCliOptions {
    mode: SearchLedgerMode,
    project_dir: PathBuf,
    sidecar_path: PathBuf,
    query: Option<String>,
    run_id: Option<String>,
    task_id: Option<String>,
    pane_id: Option<String>,
    detail_id: Option<i64>,
    limit: usize,
    descending: bool,
    json: bool,
    help: bool,
}

impl SearchLedgerCliOptions {
    fn parse(args: &[&String]) -> io::Result<Self> {
        let mut mode: Option<SearchLedgerMode> = None;
        let mut project_dir: Option<PathBuf> = None;
        let mut sidecar_path: Option<PathBuf> = None;
        let mut query: Option<String> = None;
        let mut run_id: Option<String> = None;
        let mut task_id: Option<String> = None;
        let mut pane_id: Option<String> = None;
        let mut detail_id: Option<i64> = None;
        let mut limit = DEFAULT_LIMIT;
        let mut descending = false;
        let mut json = false;
        let mut help = false;
        let mut positional = Vec::new();
        let mut i = 0usize;

        while i < args.len() {
            match args[i].as_str() {
                "-h" | "--help" => {
                    help = true;
                    i += 1;
                }
                "--json" => {
                    json = true;
                    i += 1;
                }
                "--project-dir" => {
                    let value = required_value(args, i, "--project-dir")?;
                    project_dir = Some(PathBuf::from(value));
                    i += 2;
                }
                "--sidecar" => {
                    let value = required_value(args, i, "--sidecar")?;
                    sidecar_path = Some(PathBuf::from(value));
                    i += 2;
                }
                "--query" => {
                    query = Some(required_value(args, i, "--query")?.to_string());
                    i += 2;
                }
                "--run-id" => {
                    run_id = Some(required_value(args, i, "--run-id")?.to_string());
                    i += 2;
                }
                "--task-id" => {
                    task_id = Some(required_value(args, i, "--task-id")?.to_string());
                    i += 2;
                }
                "--pane-id" => {
                    pane_id = Some(required_value(args, i, "--pane-id")?.to_string());
                    i += 2;
                }
                "--limit" => {
                    let value = required_value(args, i, "--limit")?;
                    limit = value.parse::<usize>().map_err(|_| {
                        invalid_input(format!("--limit must be a positive integer: {value}"))
                    })?;
                    i += 2;
                }
                "--desc" => {
                    descending = true;
                    i += 1;
                }
                "search" if mode.is_none() => {
                    mode = Some(SearchLedgerMode::Search);
                    i += 1;
                }
                "timeline" if mode.is_none() => {
                    mode = Some(SearchLedgerMode::Timeline);
                    i += 1;
                }
                "detail" if mode.is_none() => {
                    mode = Some(SearchLedgerMode::Detail);
                    i += 1;
                }
                arg if arg.starts_with('-') => {
                    return Err(invalid_input(format!(
                        "unknown search-ledger option: {arg}"
                    )));
                }
                arg => {
                    positional.push(arg.to_string());
                    i += 1;
                }
            }
        }

        let mode = mode.unwrap_or(SearchLedgerMode::Search);
        match mode {
            SearchLedgerMode::Search => {
                if query.is_none() && !positional.is_empty() {
                    query = Some(positional.join(" "));
                }
                if !help && query.as_deref().unwrap_or("").trim().is_empty() {
                    return Err(invalid_input("missing search query"));
                }
            }
            SearchLedgerMode::Timeline => {
                if query.is_none() && !positional.is_empty() {
                    query = Some(positional.join(" "));
                }
            }
            SearchLedgerMode::Detail => {
                if !help {
                    if query.is_some()
                        || run_id.is_some()
                        || task_id.is_some()
                        || pane_id.is_some()
                        || descending
                    {
                        return Err(invalid_input(
                            "detail accepts only --json, --project-dir, --sidecar, and one id",
                        ));
                    }
                    let id = positional
                        .first()
                        .ok_or_else(|| invalid_input("missing detail id"))?;
                    detail_id = Some(id.parse::<i64>().map_err(|_| {
                        invalid_input(format!("detail id must be an integer: {id}"))
                    })?);
                    if positional.len() > 1 {
                        return Err(invalid_input("detail accepts exactly one id"));
                    }
                }
            }
        }

        let project_dir = match project_dir {
            Some(path) => path,
            None => std::env::current_dir().map_err(|err| {
                other_error(format!("failed to resolve current directory: {err}"))
            })?,
        };
        let sidecar_path = sidecar_path
            .unwrap_or_else(|| project_dir.join(".winsmux").join("search-ledger.sqlite"));

        Ok(Self {
            mode,
            project_dir,
            sidecar_path,
            query,
            run_id,
            task_id,
            pane_id,
            detail_id,
            limit,
            descending,
            json,
            help,
        })
    }
}

fn read_events_jsonl(project_dir: &Path) -> io::Result<String> {
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    match fs::read_to_string(&events_path) {
        Ok(content) => Ok(content),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(err) => Err(other_error(format!(
            "failed to read events '{}': {err}",
            events_path.display()
        ))),
    }
}

fn row_to_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<SearchLedgerEntrySummary> {
    Ok(SearchLedgerEntrySummary {
        id: row.get(0)?,
        ordinal: row.get::<_, i64>(1)? as usize,
        timestamp: row.get(2)?,
        event: row.get(3)?,
        session: row.get(4)?,
        message: row.get(5)?,
        label: row.get(6)?,
        pane_id: row.get(7)?,
        role: row.get(8)?,
        status: row.get(9)?,
        source: row.get(10)?,
        branch: row.get(11)?,
        run_id: row.get(12)?,
        task_id: row.get(13)?,
        head_sha: row.get(14)?,
    })
}

fn collect_rows<T>(
    rows: rusqlite::MappedRows<'_, impl FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<T>>,
) -> Result<Vec<T>, String> {
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|err| format!("failed to read search ledger row: {err}"))?);
    }
    Ok(values)
}

fn detail_json(event: &EventRecord) -> Value {
    json!({
        "timestamp": event.timestamp,
        "event": event.event,
        "session": event.session,
        "message": redact_sensitive_text(&event.message),
        "label": event.label,
        "pane_id": event.pane_id,
        "role": event.role,
        "status": event.status,
        "exit_reason": event.exit_reason,
        "source": event.source,
        "branch": event_field_with_data_fallback(&event.branch, event, "branch"),
        "run_id": event_field_with_data_fallback(&event.run_id, event, "run_id"),
        "task_id": event_field_with_data_fallback(&event.task_id, event, "task_id"),
        "head_sha": event_field_with_data_fallback(&event.head_sha, event, "head_sha"),
        "data": redact_sensitive_value("", &event.data),
    })
}

fn searchable_body(event: &EventRecord, detail: &Value) -> String {
    let mut parts = vec![
        event.timestamp.clone(),
        event.event.clone(),
        event.session.clone(),
        redact_sensitive_text(&event.message),
        event.label.clone(),
        event.pane_id.clone(),
        event.role.clone(),
        event.status.clone(),
        event.exit_reason.clone(),
        event.source.clone(),
        event.branch.clone(),
        event.run_id.clone(),
        event.task_id.clone(),
        event.head_sha.clone(),
    ];
    parts.push(detail.to_string());
    parts.join("\n")
}

fn should_index_event(event: &EventRecord) -> bool {
    let Some(data) = event.data.as_object() else {
        return true;
    };

    if bool_field(data, "suppress_search")
        || bool_field(data, "search_suppressed")
        || bool_field(data, "no_search")
    {
        return false;
    }

    if sensitive_marker(value_string(data.get("retention")).as_deref()) {
        return false;
    }

    for key in [
        "retention_tags",
        "search_retention_tags",
        "sensitivity_tags",
        "classification_tags",
    ] {
        if value_array_contains_sensitive_marker(data.get(key)) {
            return false;
        }
    }

    true
}

fn bool_field(data: &Map<String, Value>, key: &str) -> bool {
    data.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn value_string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(|value| value.to_string())
}

fn event_field_with_data_fallback(top_level: &str, event: &EventRecord, data_key: &str) -> String {
    if !top_level.trim().is_empty() {
        return top_level.to_string();
    }

    event_data_string(&event.data, data_key)
}

fn event_data_string(data: &Value, key: &str) -> String {
    data.as_object()
        .and_then(|map| map.get(key))
        .and_then(Value::as_str)
        .map(|value| value.to_string())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_default()
}

fn value_array_contains_sensitive_marker(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .any(|item| sensitive_marker(Some(item))),
        Some(Value::String(item)) => sensitive_marker(Some(item)),
        _ => false,
    }
}

fn sensitive_marker(value: Option<&str>) -> bool {
    let Some(value) = value else {
        return false;
    };
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "credential"
            | "credentials"
            | "secret"
            | "secrets"
            | "token"
            | "tokens"
            | "private"
            | "sensitive"
            | "no_search"
            | "search_suppressed"
            | "do_not_index"
    )
}

fn redact_sensitive_value(key: &str, value: &Value) -> Value {
    if is_sensitive_key(key) {
        return Value::String("[redacted]".to_string());
    }

    match value {
        Value::Object(map) => {
            let mut redacted = Map::new();
            for (child_key, child_value) in map {
                redacted.insert(
                    child_key.clone(),
                    redact_sensitive_value(child_key, child_value),
                );
            }
            Value::Object(redacted)
        }
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| redact_sensitive_value(key, item))
                .collect(),
        ),
        Value::String(text) if looks_sensitive_text(text) => {
            Value::String("[redacted]".to_string())
        }
        _ => value.clone(),
    }
}

fn is_sensitive_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase();
    let compact = normalized
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>();
    compact.contains("secret")
        || compact.contains("token")
        || compact.contains("password")
        || compact.contains("credential")
        || compact.contains("privatekey")
        || compact.contains("sshkey")
        || compact.contains("secretkey")
        || compact.contains("signingkey")
        || compact.contains("accesskey")
        || compact.contains("apikey")
        || compact.contains("authheader")
        || compact == "authorization"
        || compact == "bearer"
        || compact == "key"
}

fn redact_sensitive_text(text: &str) -> String {
    if looks_sensitive_text(text) {
        "[redacted]".to_string()
    } else {
        text.to_string()
    }
}

fn looks_sensitive_text(text: &str) -> bool {
    let compact = text
        .to_ascii_lowercase()
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>();
    compact.contains("secret")
        || compact.contains("token")
        || compact.contains("password")
        || compact.contains("credential")
        || compact.contains("privatekey")
        || compact.contains("sshkey")
        || compact.contains("apikey")
        || compact.contains("authheader")
        || compact.contains("bearer")
}

fn fts5_query(query: &str) -> String {
    query
        .split_whitespace()
        .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalize_limit(limit: usize) -> usize {
    match limit {
        0 => DEFAULT_LIMIT,
        value if value > MAX_LIMIT => MAX_LIMIT,
        value => value,
    }
}

fn required_value<'a>(args: &'a [&String], index: usize, flag: &str) -> io::Result<&'a str> {
    args.get(index + 1)
        .map(|value| value.as_str())
        .ok_or_else(|| invalid_input(format!("{flag} requires a value")))
}

fn print_usage() {
    println!(
        "usage: winsmux search-ledger <search|timeline|detail> --json [options]\n\
         search:   winsmux search-ledger search --json <query> [--project-dir <path>] [--limit <n>]\n\
         timeline: winsmux search-ledger timeline --json [--query <query>] [--run-id <id>] [--task-id <id>] [--pane-id <id>]\n\
         detail:   winsmux search-ledger detail --json <id> [--project-dir <path>]"
    );
}

fn write_json<T: Serialize>(value: &T) -> io::Result<()> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer_pretty(&mut handle, value).map_err(other_error)?;
    writeln!(handle)?;
    Ok(())
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn other_error(message: impl ToString) -> io::Error {
    io::Error::new(io::ErrorKind::Other, message.to_string())
}
