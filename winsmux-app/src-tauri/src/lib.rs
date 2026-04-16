mod desktop_backend;
mod pty_backend;

use desktop_backend::{
    handle_desktop_json_rpc, load_desktop_run_explain, load_desktop_summary_snapshot,
    spawn_desktop_summary_refresh_stream, DesktopJsonRpcRequest, DesktopJsonRpcResponse,
    DesktopStreamCommand, DesktopSummaryRefreshSignal, DesktopSummarySnapshot, PwshScriptTransport,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use pty_backend::{
    handle_pty_json_rpc, PtyCommand, PtyCommandTransport, PtyJsonRpcRequest, PtyJsonRpcResponse,
};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

const DESKTOP_SUMMARY_REFRESH_EVENT: &str = "desktop-summary-refresh";

struct SinglePty {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    child: Arc<Mutex<Box<dyn portable_pty::Child + Send>>>,
}

struct PtyManager {
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
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

    let inbox_app = app.clone();
    if let Err(err) = spawn_desktop_summary_refresh_stream(
        DesktopStreamCommand::Inbox { project_dir: None },
        manager.stop_requested.clone(),
        move |signal| {
            emit_desktop_summary_refresh(&inbox_app, signal);
        },
    ) {
        eprintln!("Failed to start inbox summary stream adapter: {}", err);
    }

    let digest_app = app.clone();
    if let Err(err) = spawn_desktop_summary_refresh_stream(
        DesktopStreamCommand::Digest { project_dir: None },
        manager.stop_requested.clone(),
        move |signal| {
            emit_desktop_summary_refresh(&digest_app, signal);
        },
    ) {
        eprintln!("Failed to start digest summary stream adapter: {}", err);
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
) -> Result<serde_json::Value, String> {
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
    spawn_pty(&app, pane_id, cols, rows)
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
async fn pty_close(app: AppHandle, pane_id: String) -> Result<(), String> {
    close_pty(&app, &pane_id)
}

fn spawn_pty(app: &AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
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

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("Failed to get reader: {e}"))?;

    let single = SinglePty {
        writer: Arc::new(Mutex::new(writer)),
        master: Arc::new(Mutex::new(pair.master)),
        child: Arc::new(Mutex::new(child)),
    };

    let manager = app.state::<PtyManager>();
    {
        let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if panes.contains_key(&pane_id) {
            return Err(format!("Pane {} already exists", pane_id));
        }
        panes.insert(pane_id.clone(), single);
    }

    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.spawn".to_string(),
            pane_id: Some(pane_id.clone()),
            run_id: None,
        },
    );

    // Read PTY output in background thread
    let app_handle = app.clone();
    let pane_id_clone = pane_id.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buf[..n]).to_string();
                    let _ = app_handle.emit(
                        "pty-output",
                        serde_json::json!({"pane_id": pane_id_clone, "data": data}),
                    );
                }
                Err(_) => break,
            }
        }
    });

    Ok(())
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
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    let master = pty.master.lock().map_err(|e| e.to_string())?;
    master
        .resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("Resize failed: {e}"))?;
    Ok(())
}

fn close_pty(app: &AppHandle, pane_id: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let entry = panes
        .remove(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    // Kill child process
    if let Ok(mut child) = entry.child.lock() {
        let _ = child.kill();
    }
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
            } => {
                spawn_pty(&self.app, pane_id.clone(), *cols, *rows)?;
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
        })
        .manage(DesktopSummaryStreamManager {
            started: AtomicBool::new(false),
            stop_requested: Arc::new(AtomicBool::new(false)),
        })
        .setup(|app| {
            start_desktop_summary_refresh_streams(&app.handle().clone());
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
