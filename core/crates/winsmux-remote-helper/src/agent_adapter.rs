//! Linux-only bounded executable resolution for supported Agent providers.

use crate::{AgentResolution, MAX_EXECUTABLE_BYTES};
use std::env;
use std::ffi::CString;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

pub(crate) fn resolve_agent(executable: &str, resolution: &AgentResolution) -> io::Result<String> {
    if let Some(path) = resolution.absolute_path.as_deref() {
        if candidate_is_selectable(path) {
            return Ok(path.to_string());
        }
    }

    if let Some(path) = env::var_os("PATH") {
        for entry in path.as_os_str().as_bytes().split(|byte| *byte == b':') {
            let Ok(entry) = std::str::from_utf8(entry) else {
                continue;
            };
            if !path_entry_is_legal(entry) {
                continue;
            }
            let separator = usize::from(!entry.ends_with('/'));
            let Some(candidate_len) = entry
                .len()
                .checked_add(separator)
                .and_then(|len| len.checked_add(executable.len()))
            else {
                continue;
            };
            if candidate_len > MAX_EXECUTABLE_BYTES {
                continue;
            }
            let candidate = if separator == 0 {
                format!("{entry}{executable}")
            } else {
                format!("{entry}/{executable}")
            };
            if candidate_is_selectable(&candidate) {
                return Ok(candidate);
            }
        }
    }

    for path in &resolution.user_candidates {
        if candidate_is_selectable(path) {
            return Ok(path.clone());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "no executable candidate found",
    ))
}

fn path_entry_is_legal(path: &str) -> bool {
    !path.is_empty()
        && path.starts_with('/')
        && !path.as_bytes().contains(&0)
        && path
            .as_bytes()
            .split(|byte| *byte == b'/')
            .all(|component| component != b"." && component != b"..")
}

fn candidate_is_selectable(path: &str) -> bool {
    if path.len() > MAX_EXECUTABLE_BYTES || !path_entry_is_legal(path) {
        return false;
    }
    if !fs::metadata(Path::new(path)).is_ok_and(|metadata| metadata.is_file()) {
        return false;
    }
    helper_can_execute(path)
}

fn helper_can_execute(path: &str) -> bool {
    let Ok(c_path) = CString::new(path) else {
        return false;
    };
    // SAFETY: `c_path` is a valid C string for the duration of this call.
    // AT_EACCESS uses the helper's effective credentials, matching `execve`.
    unsafe {
        libc::faccessat(
            libc::AT_FDCWD,
            c_path.as_ptr(),
            libc::X_OK,
            libc::AT_EACCESS,
        ) == 0
    }
}
