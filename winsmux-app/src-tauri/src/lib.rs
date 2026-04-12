use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
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

#[derive(serde::Serialize)]
struct DesktopSummarySnapshot {
    generated_at: String,
    project_dir: String,
    board: serde_json::Value,
    inbox: serde_json::Value,
    digest: serde_json::Value,
}

fn looks_like_repo_root(path: &Path) -> bool {
    path.join("scripts").join("winsmux-core.ps1").exists()
}

fn resolve_repo_root() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();

    if let Ok(current_dir) = std::env::current_dir() {
        candidates.push(current_dir);
    }
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            candidates.push(parent.to_path_buf());
        }
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")));

    for candidate in candidates {
        for ancestor in candidate.ancestors() {
            if looks_like_repo_root(ancestor) {
                return Ok(ancestor.to_path_buf());
            }
        }
    }

    Err("Could not locate winsmux repo root from the Tauri runtime".to_string())
}

fn run_winsmux_json(project_dir: Option<String>, args: &[String]) -> Result<serde_json::Value, String> {
    let repo_root = resolve_repo_root()?;
    let effective_project_dir = match project_dir {
        Some(path) if !path.trim().is_empty() => PathBuf::from(path),
        _ => repo_root.clone(),
    };
    let script_path = repo_root.join("scripts").join("winsmux-core.ps1");
    let script_literal = script_path.to_string_lossy().replace('\'', "''");
    let args_literal = args
        .iter()
        .map(|item| format!("'{}'", item.replace('\'', "''")))
        .collect::<Vec<_>>()
        .join(" ");
    let command_text = format!("& {{ & '{}' {} }}", script_literal, args_literal);

    let output = Command::new("pwsh")
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(command_text)
        .current_dir(&effective_project_dir)
        .output()
        .map_err(|err| format!("Failed to start winsmux-core.ps1: {err}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let detail = if !stderr.is_empty() { stderr } else { stdout };
        return Err(format!("winsmux-core.ps1 failed: {}", detail));
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if stdout.is_empty() {
        return Err("winsmux-core.ps1 returned empty JSON output".to_string());
    }

    serde_json::from_str(&stdout).map_err(|err| format!("Failed to parse winsmux JSON payload: {err}"))
}

#[tauri::command]
async fn desktop_summary_snapshot(project_dir: Option<String>) -> Result<DesktopSummarySnapshot, String> {
    let board = run_winsmux_json(project_dir.clone(), &["board".to_string(), "--json".to_string()])?;
    let inbox = run_winsmux_json(project_dir.clone(), &["inbox".to_string(), "--json".to_string()])?;
    let digest = run_winsmux_json(project_dir.clone(), &["digest".to_string(), "--json".to_string()])?;

    let effective_project_dir = match project_dir {
        Some(path) if !path.trim().is_empty() => path,
        _ => resolve_repo_root()?.to_string_lossy().to_string(),
    };

    Ok(DesktopSummarySnapshot {
        generated_at: chrono::Utc::now().to_rfc3339(),
        project_dir: effective_project_dir,
        board,
        inbox,
        digest,
    })
}

#[tauri::command]
async fn desktop_run_explain(run_id: String, project_dir: Option<String>) -> Result<serde_json::Value, String> {
    run_winsmux_json(
        project_dir,
        &["explain".to_string(), run_id, "--json".to_string()],
    )
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
        .invoke_handler(tauri::generate_handler![
            desktop_summary_snapshot,
            desktop_run_explain,
            pty_spawn,
            pty_write,
            pty_resize,
            pty_close
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
