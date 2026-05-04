mod control_pipe;
mod desktop_backend;
mod pty_backend;

use control_pipe::start_control_pipe_server;
use desktop_backend::{
    handle_desktop_json_rpc, load_desktop_run_explain, load_desktop_summary_snapshot,
    spawn_desktop_summary_refresh_stream, DesktopExplainPayload, DesktopJsonRpcRequest,
    DesktopJsonRpcResponse, DesktopStreamCommand, DesktopSummaryRefreshSignal,
    DesktopSummarySnapshot, PwshScriptTransport,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use pty_backend::{
    handle_pty_json_rpc, PtyCommand, PtyCommandTransport, PtyJsonRpcRequest, PtyJsonRpcResponse,
};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

const DESKTOP_SUMMARY_REFRESH_EVENT: &str = "desktop-summary-refresh";
const PTY_CAPTURE_LIMIT: usize = 64 * 1024;

struct SinglePty {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    child: Arc<Mutex<Box<dyn portable_pty::Child + Send>>>,
    output_history: Arc<Mutex<String>>,
    alive: Arc<AtomicBool>,
    generation: u64,
    cols: u16,
    rows: u16,
}

struct PtyManager {
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
    next_generation: AtomicU64,
}

struct DesktopSummaryStreamManager {
    started: AtomicBool,
    stop_requested: Arc<AtomicBool>,
}

struct TauriPtyTransport {
    app: AppHandle,
}

fn emit_desktop_summary_refresh(app: &AppHandle, signal: DesktopSummaryRefreshSignal) {
    let _ = app.emit(DESKTOP_SUMMARY_REFRESH_EVENT, signal);
}

fn start_desktop_summary_refresh_streams(app: &AppHandle) {
    let manager = app.state::<DesktopSummaryStreamManager>();
    if manager.started.swap(true, Ordering::SeqCst) {
        return;
    }

    let summary_app = app.clone();
    if let Err(err) = spawn_desktop_summary_refresh_stream(
        DesktopStreamCommand::Summary { project_dir: None },
        manager.stop_requested.clone(),
        move |signal| {
            emit_desktop_summary_refresh(&summary_app, signal);
        },
    ) {
        eprintln!("Failed to start desktop summary stream adapter: {}", err);
    }
}

#[tauri::command]
async fn desktop_summary_snapshot(
    project_dir: Option<String>,
) -> Result<DesktopSummarySnapshot, String> {
    let transport = PwshScriptTransport;
    load_desktop_summary_snapshot(&transport, project_dir)
}

#[tauri::command]
async fn desktop_run_explain(
    run_id: String,
    project_dir: Option<String>,
) -> Result<DesktopExplainPayload, String> {
    let transport = PwshScriptTransport;
    load_desktop_run_explain(&transport, run_id, project_dir)
}

#[tauri::command]
async fn desktop_json_rpc(
    request: DesktopJsonRpcRequest,
    project_dir: Option<String>,
) -> Result<DesktopJsonRpcResponse, String> {
    let transport = PwshScriptTransport;
    Ok(handle_desktop_json_rpc(&transport, request, project_dir))
}

#[tauri::command]
async fn pty_json_rpc(
    app: AppHandle,
    request: PtyJsonRpcRequest,
) -> Result<PtyJsonRpcResponse, String> {
    let transport = TauriPtyTransport { app };
    Ok(handle_pty_json_rpc(&transport, request))
}

#[tauri::command]
async fn pty_spawn(app: AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
    spawn_pty(&app, pane_id, cols, rows, None, "pty.spawn")
}

#[tauri::command]
async fn pty_write(app: AppHandle, pane_id: String, data: String) -> Result<(), String> {
    write_pty(&app, &pane_id, &data)
}

#[tauri::command]
async fn pty_resize(app: AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
    resize_pty(&app, &pane_id, cols, rows)
}

#[tauri::command]
async fn pty_capture(
    app: AppHandle,
    pane_id: String,
    lines: Option<u16>,
) -> Result<serde_json::Value, String> {
    capture_pty(&app, &pane_id, lines)
}

#[tauri::command]
async fn pty_respawn(app: AppHandle, pane_id: String) -> Result<(), String> {
    respawn_pty(&app, &pane_id)
}

#[tauri::command]
async fn pty_close(app: AppHandle, pane_id: String) -> Result<(), String> {
    close_pty(&app, &pane_id)
}

fn spawn_pty(
    app: &AppHandle,
    pane_id: String,
    cols: u16,
    rows: u16,
    startup_input: Option<String>,
    reason: &str,
) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    {
        let panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if panes.contains_key(&pane_id) {
            return Err(format!("Pane {} already exists", pane_id));
        }
    }

    let generation = manager.next_generation.fetch_add(1, Ordering::SeqCst);
    let (single, reader, output_history, alive) = create_single_pty(cols, rows, generation)?;

    {
        let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if panes.contains_key(&pane_id) {
            stop_single_pty(&single);
            return Err(format!("Pane {} already exists", pane_id));
        }
        panes.insert(pane_id.clone(), single);
    }

    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: reason.to_string(),
            pane_id: Some(pane_id.clone()),
            run_id: None,
        },
    );

    start_pty_reader(
        app,
        pane_id.clone(),
        reader,
        output_history,
        alive,
        generation,
        manager.panes.clone(),
    );
    if let Some(input) = startup_input {
        write_pty(app, &pane_id, &input)?;
    }
    Ok(())
}

type PtyReader = Box<dyn Read + Send>;
type SinglePtyParts = (SinglePty, PtyReader, Arc<Mutex<String>>, Arc<AtomicBool>);

fn create_single_pty(cols: u16, rows: u16, generation: u64) -> Result<SinglePtyParts, String> {
    let pty_system = native_pty_system();

    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("Failed to open PTY: {e}"))?;

    let mut cmd = CommandBuilder::new("pwsh");
    cmd.arg("-NoLogo");

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("Failed to spawn: {e}"))?;

    let writer = pair
        .master
        .take_writer()
        .map_err(|e| format!("Failed to get writer: {e}"))?;

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("Failed to get reader: {e}"))?;
    let output_history = Arc::new(Mutex::new(String::new()));
    let alive = Arc::new(AtomicBool::new(true));

    let single = SinglePty {
        writer: Arc::new(Mutex::new(writer)),
        master: Arc::new(Mutex::new(pair.master)),
        child: Arc::new(Mutex::new(child)),
        output_history: output_history.clone(),
        alive: alive.clone(),
        generation,
        cols,
        rows,
    };

    Ok((single, reader, output_history, alive))
}

fn start_pty_reader(
    app: &AppHandle,
    pane_id: String,
    mut reader: PtyReader,
    output_history: Arc<Mutex<String>>,
    alive: Arc<AtomicBool>,
    generation: u64,
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
) {
    let app_handle = app.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            if !alive.load(Ordering::SeqCst) {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buf[..n]).to_string();
                    let Ok(current_panes) = panes.lock() else {
                        break;
                    };
                    let is_current = current_panes
                        .get(&pane_id)
                        .map(|pty| pty.generation == generation && Arc::ptr_eq(&pty.alive, &alive))
                        .unwrap_or(false);
                    if !is_current || !alive.load(Ordering::SeqCst) {
                        break;
                    }
                    if let Ok(mut history) = output_history.lock() {
                        history.push_str(&data);
                        trim_pty_history(&mut history);
                    }
                    let _ = app_handle.emit(
                        "pty-output",
                        serde_json::json!({"pane_id": pane_id, "data": data}),
                    );
                }
                Err(_) => break,
            }
        }
    });
}

fn trim_pty_history(history: &mut String) {
    if history.len() <= PTY_CAPTURE_LIMIT {
        return;
    }

    let mut drain_to = history.len() - PTY_CAPTURE_LIMIT;
    while drain_to < history.len() && !history.is_char_boundary(drain_to) {
        drain_to += 1;
    }
    history.drain(..drain_to);
}

fn write_pty(app: &AppHandle, pane_id: &str, data: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    let mut writer = pty.writer.lock().map_err(|e| e.to_string())?;
    writer
        .write_all(data.as_bytes())
        .map_err(|e| format!("Write failed: {e}"))?;
    writer.flush().map_err(|e| format!("Flush failed: {e}"))?;
    Ok(())
}

fn resize_pty(app: &AppHandle, pane_id: &str, cols: u16, rows: u16) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get_mut(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    {
        let master = pty.master.lock().map_err(|e| e.to_string())?;
        master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("Resize failed: {e}"))?;
    }
    pty.cols = cols;
    pty.rows = rows;
    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.resize".to_string(),
            pane_id: Some(pane_id.to_string()),
            run_id: None,
        },
    );
    Ok(())
}

fn limit_pty_capture_output(output: &str, lines: Option<u16>) -> String {
    let Some(lines) = lines else {
        return output.to_string();
    };
    if lines == 0 {
        return String::new();
    }

    let mut tail = output
        .lines()
        .rev()
        .take(lines as usize)
        .collect::<Vec<_>>();
    tail.reverse();
    tail.join("\n")
}

fn capture_pty(
    app: &AppHandle,
    pane_id: &str,
    lines: Option<u16>,
) -> Result<serde_json::Value, String> {
    let manager = app.state::<PtyManager>();
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    let output = pty
        .output_history
        .lock()
        .map_err(|e| e.to_string())?
        .clone();
    let output = limit_pty_capture_output(&output, lines);
    Ok(serde_json::json!({
        "paneId": pane_id,
        "output": output
    }))
}

fn respawn_pty(app: &AppHandle, pane_id: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let (cols, rows) = {
        let panes = manager.panes.lock().map_err(|e| e.to_string())?;
        let entry = panes
            .get(pane_id)
            .ok_or_else(|| format!("Pane {} not found", pane_id))?;
        (entry.cols, entry.rows)
    };
    let generation = manager.next_generation.fetch_add(1, Ordering::SeqCst);
    let (single, reader, output_history, alive) = create_single_pty(cols, rows, generation)?;

    let old_entry = {
        let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if !panes.contains_key(pane_id) {
            stop_single_pty(&single);
            return Err(format!("Pane {} not found", pane_id));
        }
        panes
            .insert(pane_id.to_string(), single)
            .expect("pane existence was checked before replacement")
    };

    stop_single_pty(&old_entry);
    drop(old_entry);

    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.respawn".to_string(),
            pane_id: Some(pane_id.to_string()),
            run_id: None,
        },
    );

    start_pty_reader(
        app,
        pane_id.to_string(),
        reader,
        output_history,
        alive,
        generation,
        manager.panes.clone(),
    );
    Ok(())
}

fn stop_single_pty(entry: &SinglePty) {
    entry.alive.store(false, Ordering::SeqCst);
    if let Ok(mut child) = entry.child.lock() {
        let _ = child.kill();
    }
}

fn close_pty(app: &AppHandle, pane_id: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let entry = panes
        .remove(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    stop_single_pty(&entry);
    // Drop master to signal EOF to reader thread
    drop(entry.master);
    drop(entry.writer);
    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.close".to_string(),
            pane_id: Some(pane_id.to_string()),
            run_id: None,
        },
    );
    Ok(())
}

impl PtyCommandTransport for TauriPtyTransport {
    fn execute(&self, command: &PtyCommand) -> Result<serde_json::Value, String> {
        match command {
            PtyCommand::Spawn {
                pane_id,
                cols,
                rows,
                startup_input,
            } => {
                spawn_pty(
                    &self.app,
                    pane_id.clone(),
                    *cols,
                    *rows,
                    startup_input.clone(),
                    "pty.spawn",
                )?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Write { pane_id, data } => {
                write_pty(&self.app, pane_id, data)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Resize {
                pane_id,
                cols,
                rows,
            } => {
                resize_pty(&self.app, pane_id, *cols, *rows)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Capture { pane_id, lines } => capture_pty(&self.app, pane_id, *lines),
            PtyCommand::Respawn { pane_id } => {
                respawn_pty(&self.app, pane_id)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Close { pane_id } => {
                close_pty(&self.app, pane_id)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(PtyManager {
            panes: Arc::new(Mutex::new(HashMap::new())),
            next_generation: AtomicU64::new(1),
        })
        .manage(DesktopSummaryStreamManager {
            started: AtomicBool::new(false),
            stop_requested: Arc::new(AtomicBool::new(false)),
        })
        .setup(|app| {
            let app_handle = app.handle().clone();
            start_control_pipe_server(Arc::new(TauriPtyTransport {
                app: app_handle.clone(),
            }));
            start_desktop_summary_refresh_streams(&app_handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            desktop_summary_snapshot,
            desktop_run_explain,
            desktop_json_rpc,
            pty_json_rpc,
            pty_spawn,
            pty_write,
            pty_resize,
            pty_capture,
            pty_respawn,
            pty_close
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if matches!(
            event,
            tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
        ) {
            let manager = app_handle.state::<DesktopSummaryStreamManager>();
            manager.stop_requested.store(true, Ordering::SeqCst);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_pty_history_preserves_utf8_boundaries() {
        let mut history = "あ".repeat((PTY_CAPTURE_LIMIT / 3) + 2);

        trim_pty_history(&mut history);

        assert!(history.len() <= PTY_CAPTURE_LIMIT);
        assert!(history.is_char_boundary(0));
        assert!(history.ends_with('あ'));
    }

    #[test]
    fn limit_pty_capture_output_returns_recent_lines() {
        let output = limit_pty_capture_output("one\ntwo\nthree\nfour\n", Some(2));

        assert_eq!(output, "three\nfour");
    }
}
