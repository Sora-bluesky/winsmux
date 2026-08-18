use std::path::PathBuf;
use std::process::Command;

use crate::desktop_backend::{
    apply_desktop_winsmux_child_env, hide_subprocess_window, resolve_companion_winsmux_cli,
};

pub(crate) fn build_companion_events_argv(project_dir: &str, cursor: u64) -> Vec<String> {
    let mut args = vec!["events".to_string()];
    if cursor > 0 {
        args.push(cursor.to_string());
    }
    args.push("--json".to_string());
    args.push("--project-dir".to_string());
    args.push(project_dir.to_string());
    args
}

pub fn load_desktop_events_json(project_dir: String, cursor: u64) -> Result<String, String> {
    let companion = resolve_companion_winsmux_cli()
        .ok_or_else(|| "companion winsmux CLI was not found".to_string())?;
    let project_path = PathBuf::from(&project_dir);
    if !project_path.is_dir() {
        return Err(format!("project directory not found: {project_dir}"));
    }

    let args = build_companion_events_argv(&project_dir, cursor);
    let mut command = Command::new(&companion);
    command.args(&args).current_dir(&project_path);
    apply_desktop_winsmux_child_env(&mut command, Some(companion.as_path()), std::process::id());
    hide_subprocess_window(&mut command);

    let output = command
        .output()
        .map_err(|err| format!("Failed to start companion winsmux: {err}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if !output.status.success() {
        let detail = if !stderr.trim().is_empty() {
            stderr
        } else {
            stdout
        };
        return Err(format!("winsmux events failed: {}", detail.trim()));
    }
    Ok(stdout)
}

#[cfg(test)]
mod tests {
    use super::build_companion_events_argv;

    #[test]
    fn companion_events_argv_matches_public_cli() {
        assert_eq!(
            build_companion_events_argv(r"C:\proj", 0),
            vec!["events", "--json", "--project-dir", r"C:\proj"]
        );
        assert_eq!(
            build_companion_events_argv("/tmp/proj", 3),
            vec!["events", "3", "--json", "--project-dir", "/tmp/proj"]
        );
    }
}
