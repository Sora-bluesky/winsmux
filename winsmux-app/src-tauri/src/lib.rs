use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

struct SinglePty {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    child: Arc<Mutex<Box<dyn portable_pty::Child + Send>>>,
}

struct PtyManager {
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
}

#[tauri::command]
async fn pty_spawn(app: AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
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
                    let _ = app_handle.emit("pty-output", serde_json::json!({"pane_id": pane_id_clone, "data": data}));
                }
                Err(_) => break,
            }
        }
    });

    Ok(())
}

#[tauri::command]
async fn pty_write(app: AppHandle, pane_id: String, data: String) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes.get(&pane_id).ok_or_else(|| format!("Pane {} not found", pane_id))?;
    let mut writer = pty.writer.lock().map_err(|e| e.to_string())?;
    writer
        .write_all(data.as_bytes())
        .map_err(|e| format!("Write failed: {e}"))?;
    writer.flush().map_err(|e| format!("Flush failed: {e}"))?;
    Ok(())
}

#[tauri::command]
async fn pty_resize(app: AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes.get(&pane_id).ok_or_else(|| format!("Pane {} not found", pane_id))?;
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

#[tauri::command]
async fn pty_close(app: AppHandle, pane_id: String) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let entry = panes.remove(&pane_id).ok_or_else(|| format!("Pane {} not found", pane_id))?;
    // Kill child process
    if let Ok(mut child) = entry.child.lock() {
        let _ = child.kill();
    }
    // Drop master to signal EOF to reader thread
    drop(entry.master);
    drop(entry.writer);
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(PtyManager {
            panes: Arc::new(Mutex::new(HashMap::new())),
        })
        .invoke_handler(tauri::generate_handler![pty_spawn, pty_write, pty_resize, pty_close])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
