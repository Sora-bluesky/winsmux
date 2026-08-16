use std::fs;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

fn architecture_combined_yaml() -> String {
    let doc = include_str!("../../docs/project/v03629-declarative-workspace-architecture.md");
    extract(doc, "TASK659-RUNNABLE-WORKFLOW-V1") + "\n" + &extract(doc, "TASK660-RUNNABLE-CONTEXT-PACK-V1")
}

fn extract(text: &str, marker: &str) -> String {
    let start = format!("<!-- {marker}:START -->");
    let end = format!("<!-- {marker}:END -->");
    let after = text.split_once(&start).expect("start").1;
    let block = after.split_once(&end).expect("end").0.trim();
    let yaml = block
        .strip_prefix("```yaml\r\n")
        .or_else(|| block.strip_prefix("```yaml\n"))
        .expect("fence");
    yaml.strip_suffix("\r\n```")
        .or_else(|| yaml.strip_suffix("\n```"))
        .expect("close")
        .to_string()
}

#[test]
fn workflow_gate_accepts_combined_lane_a_and_team_profile_without_publication() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), architecture_combined_yaml()).unwrap();
    let output = bin()
        .args(["workflow-gate", "--json", "--project-dir"])
        .arg(dir.path())
        .output()
        .expect("workflow-gate");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stderr={} stdout={}", String::from_utf8_lossy(&output.stderr), stdout);
    assert!(stdout.contains("\"in_repo_merge_ready\":true") || stdout.contains("\"in_repo_merge_ready\": true"));
    assert!(stdout.contains("\"combined_release\""));
    assert!(stdout.contains("\"status\":\"blocked\"") || stdout.contains("\"status\": \"blocked\""));
    assert!(stdout.contains("\"github_release\":false") || stdout.contains("\"github_release\": false"));
    assert!(stdout.contains("task_785_artifact") || stdout.contains("output-file-and-exit-code"));
    assert!(stdout.contains("worker-1"));
    assert!(stdout.contains("worker-4"));
}

#[test]
fn workflow_gate_legacy_path_does_not_fail_closed_on_missing_recipes() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(".winsmux.yaml"),
        "agent-slots:\n  - slot-id: worker-1\n    agent: codex\n",
    )
    .unwrap();
    let output = bin()
        .args(["workflow-gate", "--json", "--project-dir"])
        .arg(dir.path())
        .output()
        .expect("workflow-gate legacy");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stdout={stdout}");
    assert!(stdout.contains("legacy_no_lane_a") || stdout.contains("not_applicable"));
    assert!(
        !stdout.contains("\"combined_release\":{\"status\":\"pass\"")
            && !stdout.contains("\"status\":\"pass\",\"reason\":\"TASK-718 Windows")
    );
}
