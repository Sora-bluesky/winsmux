use std::{
    fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
};

use serde_json::{json, Value as JsonValue};

pub(crate) const USAGE: &str = "usage: winsmux worker-artifact --action judge --json --output <path> --exit-code <code> [--pty-capture <path>]";

pub(crate) fn run_worker_artifact_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("{USAGE}");
        return Ok(());
    }
    let mut action = None;
    let mut json = false;
    let mut output = None;
    let mut exit_code = None;
    let mut pty_capture = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--action" => {
                action = Some(required(args, index, "--action")?);
                index += 2;
            }
            "--output" | "-o" => {
                output = Some(PathBuf::from(required(args, index, "--output")?));
                index += 2;
            }
            "--exit-code" => {
                exit_code = Some(required(args, index, "--exit-code")?);
                index += 2;
            }
            "--pty-capture" => {
                pty_capture = Some(PathBuf::from(required(args, index, "--pty-capture")?));
                index += 2;
            }
            "--json" => {
                json = true;
                index += 1;
            }
            _ => return Err(invalid_input("unknown worker-artifact argument.")),
        }
    }
    if !json {
        return Err(invalid_input("worker-artifact requires --json."));
    }
    if action.as_deref() != Some("judge") {
        return Err(invalid_input("worker-artifact --action must be judge."));
    }
    let output = output.ok_or_else(|| invalid_input("worker-artifact requires --output."))?;
    let exit_code = exit_code
        .ok_or_else(|| invalid_input("worker-artifact requires --exit-code."))?
        .parse::<i32>()
        .map_err(|_| invalid_input("worker-artifact --exit-code must be an integer."))?;
    let payload = judge_completion(&output, exit_code, pty_capture.as_deref());
    println!("{payload}");
    if payload["status"] != "complete" {
        return Err(io::Error::new(
            ErrorKind::InvalidData,
            "worker artifact is incomplete or failed.",
        ));
    }
    Ok(())
}

pub(crate) fn default_result_path(run_dir: &Path) -> PathBuf {
    run_dir.join("result.md")
}

pub(crate) fn judge_completion(
    output: &Path,
    exit_code: i32,
    pty_capture: Option<&Path>,
) -> JsonValue {
    let artifact = inspect_file(output);
    let pty = pty_capture.map(inspect_file);
    let present = artifact["present"] == true && artifact["empty"] == false;
    let status = if !present {
        "incomplete"
    } else if exit_code == 0 {
        "complete"
    } else {
        "failed"
    };
    json!({
        "schema_version": 1,
        "action": "worker-artifact-judge",
        "status": status,
        "exit_code": exit_code,
        "output": artifact,
        "pty_capture": pty,
        "pty_capture_is_auxiliary": true,
        "completion_authority": "output-file-and-exit-code"
    })
}

fn inspect_file(path: &Path) -> JsonValue {
    match fs::metadata(path) {
        Ok(meta) if meta.is_file() => json!({
            "path": path.to_string_lossy(),
            "present": true,
            "empty": meta.len() == 0,
            "bytes": meta.len(),
        }),
        Ok(_) => json!({
            "path": path.to_string_lossy(),
            "present": false,
            "empty": true,
            "bytes": 0,
            "reason_code": "not_a_file"
        }),
        Err(_) => json!({
            "path": path.to_string_lossy(),
            "present": false,
            "empty": true,
            "bytes": 0,
            "reason_code": "missing_artifact"
        }),
    }
}

fn required(args: &[&String], index: usize, flag: &str) -> io::Result<String> {
    args.get(index + 1)
        .map(|value| (*value).clone())
        .ok_or_else(|| invalid_input(format!("{flag} requires a value.")))
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(ErrorKind::InvalidInput, message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn missing_artifact_is_incomplete_even_when_exit_code_is_zero() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("result.md");
        let pty = dir.path().join("pty.txt");
        fs::write(&pty, "PTY captured the worker talking").unwrap();
        let payload = judge_completion(&output, 0, Some(&pty));
        assert_eq!(payload["status"], "incomplete");
        assert_eq!(payload["pty_capture_is_auxiliary"], true);
        assert_eq!(payload["pty_capture"]["present"], true);
        assert_eq!(payload["output"]["reason_code"], "missing_artifact");
    }

    #[test]
    fn empty_artifact_is_incomplete() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("result.md");
        fs::write(&output, "").unwrap();
        let payload = judge_completion(&output, 0, None);
        assert_eq!(payload["status"], "incomplete");
        assert_eq!(payload["output"]["empty"], true);
    }

    #[test]
    fn present_artifact_and_zero_exit_is_complete() {
        let dir = tempfile::tempdir().unwrap();
        let output = default_result_path(dir.path());
        fs::write(&output, "# result\nworker finished\n").unwrap();
        let payload = judge_completion(&output, 0, None);
        assert_eq!(payload["status"], "complete");
        assert_eq!(payload["completion_authority"], "output-file-and-exit-code");
    }

    #[test]
    fn present_artifact_and_nonzero_exit_is_failed() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("result.md");
        fs::write(&output, "partial").unwrap();
        let payload = judge_completion(&output, 2, None);
        assert_eq!(payload["status"], "failed");
    }
}
