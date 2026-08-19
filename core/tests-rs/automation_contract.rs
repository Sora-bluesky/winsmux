use std::process::Command;

fn winsmux_bin() -> &'static str {
    env!("CARGO_BIN_EXE_winsmux")
}

#[cfg(windows)]
#[test]
fn cli_rejects_undecodable_utf16_argv_without_panic() {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    let output = Command::new(winsmux_bin())
        .arg(OsString::from_wide(&[0xD800]))
        .output()
        .expect("spawn winsmux");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "undecodable argv must fail closed: {stderr}");
    assert!(
        stderr.contains("argument 1 is not valid Unicode"),
        "stderr must name the argument index, got {stderr}"
    );
    assert!(
        !stderr.to_lowercase().contains("panicked"),
        "stderr must not panic: {stderr}"
    );
}

#[cfg(windows)]
#[test]
fn cli_undecodable_argv_error_names_index_not_bytes() {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    let output = Command::new(winsmux_bin())
        .arg(OsString::from_wide(&[0xD800]))
        .output()
        .expect("spawn winsmux");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("argument 1 is not valid Unicode"));
    assert!(
        !stderr.contains('\u{FFFD}'),
        "error must not echo lossy bytes: {stderr}"
    );
    assert!(
        !stderr.to_lowercase().contains("u+0000") && !stderr.contains("NUL"),
        "error must not claim U+0000 was received: {stderr}"
    );
}

#[cfg(windows)]
#[test]
fn cli_valid_non_ascii_utf16_argv_parses_unchanged() {
    let output = Command::new(winsmux_bin())
        .args(["-t", "日本語セッション", "machine-contract", "--json"])
        .output()
        .expect("spawn winsmux");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !stderr.to_lowercase().contains("panicked"),
        "valid CJK argv must not panic: {stderr}"
    );
    assert!(
        output.status.success(),
        "valid CJK argv must still dispatch: status={:?} stderr={stderr}",
        output.status
    );
}

#[test]
fn automation_contract_fails_closed_when_pipe_absent() {
    let output = Command::new(winsmux_bin())
        .arg("automation-contract")
        .output()
        .expect("spawn winsmux");
    if output.status.success() {
        return;
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("desktop control pipe is not available"),
        "missing pipe must fail closed without pwsh: {stderr}"
    );
    assert!(!stderr.to_lowercase().contains("pwsh"));
}
