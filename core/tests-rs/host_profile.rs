use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

fn ssh_g_text() -> &'static str {
    "user ubuntu\nhostname 192.0.2.10\nport 22\nidentityfile C:\\secret\\id_ed25519\n"
}

fn fingerprint_blob(blob: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("sha256:{:x}", Sha256::digest(blob.as_bytes()))
}

fn write_known_hosts(dir: &Path, blob: &str) -> PathBuf {
    let path = dir.join("known_hosts");
    fs::write(&path, format!("192.0.2.10 ssh-ed25519 {blob}\n")).unwrap();
    path
}

fn install_fake_ssh(dir: &Path, g_text: &str) -> PathBuf {
    fs::write(dir.join("g-text.txt"), g_text.replace('\n', "\r\n")).unwrap();
    fs::write(
        dir.join("ssh.cmd"),
        "@echo off\r\n\
         setlocal EnableExtensions\r\n\
         >\"%~dp0ssh-argv.txt\" echo %*\r\n\
         if /I not \"%~1\"==\"-G\" exit /b 2\r\n\
         if not \"%~2\"==\"--\" exit /b 2\r\n\
         if \"%~3\"==\"\" exit /b 2\r\n\
         if not \"%~4\"==\"\" exit /b 2\r\n\
         type \"%~dp0g-text.txt\"\r\n\
         exit /b 0\r\n",
    )
    .unwrap();
    dir.join("ssh.cmd")
}

fn run_host_profile(
    dir: &Path,
    known_hosts: &Path,
    ssh: &Path,
    args: &[&str],
) -> (bool, String, String) {
    let output = bin()
        .args(args)
        .env("WINSMUX_HOST_PROFILE_DIR", dir)
        .env("WINSMUX_HOST_PROFILE_KNOWN_HOSTS", known_hosts)
        .env("WINSMUX_HOST_PROFILE_SSH", ssh)
        .env_remove("WINSMUX_HOST_PROFILE_SSH_G_TEXT")
        .output()
        .expect("run host-profile");
    (
        output.status.success(),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

fn fake_ssh_argv(dir: &Path) -> String {
    fs::read_to_string(dir.join("ssh-argv.txt")).unwrap_or_default()
}

#[test]
fn check_creates_pending_without_known_hosts() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let known_hosts = dir.path().join("empty_known_hosts");
    fs::write(&known_hosts, "").unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let value: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(value["ok"], true);
    assert_eq!(value["state"], "pending");
    assert_eq!(value["hostname"], "192.0.2.10");
    assert!(value["identityfile"].is_null());
    let record = fs::read_to_string(dir.path().join("lab.json")).unwrap();
    assert!(!record.to_ascii_lowercase().contains("identityfile"));
    assert!(!record.to_ascii_lowercase().contains("password"));
    let argv = fake_ssh_argv(dir.path());
    assert!(
        argv.contains("-G -- lab") || argv.contains("-G  --  lab"),
        "argv={argv}"
    );
}

#[test]
fn alias_failure_does_not_invent_a_host() {
    let dir = tempfile::tempdir().unwrap();
    let known_hosts = dir.path().join("known_hosts");
    fs::write(&known_hosts, "").unwrap();
    let output = bin()
        .args(["host-profile", "check", "missing", "--json"])
        .env("WINSMUX_HOST_PROFILE_DIR", dir.path())
        .env("WINSMUX_HOST_PROFILE_KNOWN_HOSTS", &known_hosts)
        .env_remove("WINSMUX_HOST_PROFILE_SSH_G_TEXT")
        .env("WINSMUX_HOST_PROFILE_SSH", "ssh-binary-that-does-not-exist")
        .output()
        .expect("run host-profile");
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("did not resolve") || stderr.contains("failed to exec ssh -G"),
        "stderr={stderr}"
    );
    assert!(!dir.path().join("missing.json").exists());
}

#[test]
fn unconfigured_name_is_not_treated_as_an_alias() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(
        dir.path(),
        "user ubuntu\nhostname lab\nport 22\n",
    );
    let known_hosts = dir.path().join("known_hosts");
    fs::write(&known_hosts, "").unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(!ok, "stdout={stdout}");
    assert!(
        stderr.contains("did not rewrite HostName") || stderr.contains("will not invent a host"),
        "stderr={stderr}"
    );
    assert!(!dir.path().join("lab.json").exists());
}

#[test]
fn rejected_alias_does_not_reach_ssh() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let known_hosts = dir.path().join("known_hosts");
    fs::write(&known_hosts, "").unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "-oProxyJump=evil", "--json"],
    );
    assert!(!ok, "stdout={stdout}");
    assert!(
        stderr.contains("alias") || stderr.contains("usage:"),
        "stderr={stderr}"
    );
    assert!(!dir.path().join("ssh-argv.txt").exists());
}

#[test]
fn register_promotes_pending_and_change_blocks() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let check: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(check["state"], "pending");

    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let registered: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(registered["state"], "registered");
    assert_eq!(
        registered["confirmed_fingerprint"],
        fingerprint_blob(blob)
    );

    fs::write(
        &known_hosts,
        "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChangedKeyBlobForHostProfile\n",
    )
    .unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok, "stdout={stdout}");
    assert!(
        stderr.contains("fingerprint changed"),
        "stderr={stderr}"
    );
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let blocked: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(blocked["state"], "blocked");
    let record: Value =
        serde_json::from_str(&fs::read_to_string(dir.path().join("lab.json")).unwrap()).unwrap();
    assert_eq!(record["confirmed_fingerprint"], fingerprint_blob(blob));
}

#[test]
fn ambiguous_known_hosts_after_register_blocks() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");

    fs::write(
        &known_hosts,
        "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChangedKeyBlobForHostProfile\n\
         192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIThirdKeyBlobForHostProfile\n",
    )
    .unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let blocked: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(blocked["state"], "blocked");
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok);
    assert!(
        stderr.contains("ambiguous") || stderr.contains("register is not allowed"),
        "stderr={stderr}"
    );
}

#[test]
fn nonstandard_port_ignores_bare_hostname_key() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(
        dir.path(),
        "user ubuntu\nhostname 192.0.2.10\nport 2222\n",
    );
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let check: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(check["port"], 2222);
    assert!(check["presented_fingerprint"].is_null());
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok);
    assert!(
        stderr.contains("plaintext known_hosts"),
        "stderr={stderr}"
    );

    fs::write(
        &known_hosts,
        format!("[192.0.2.10]:2222 ssh-ed25519 {blob}\n"),
    )
    .unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let registered: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(registered["state"], "registered");
}

#[test]
fn status_and_secret_record_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let known_hosts = dir.path().join("known_hosts");
    fs::write(&known_hosts, "").unwrap();
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "status", "lab", "--json"],
    );
    assert!(!ok);
    assert!(stderr.contains("no local record"), "stderr={stderr}");

    fs::write(
        dir.path().join("lab.json"),
        r#"{"alias":"lab","hostname":"192.0.2.10","port":22,"user":"ubuntu","state":"pending","password":"secret"}"#,
    )
    .unwrap();
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "status", "lab", "--json"],
    );
    assert!(!ok);
    assert!(stderr.contains("secret field"), "stderr={stderr}");
}

#[test]
fn known_hosts_file_is_not_written() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let before = fs::read(&known_hosts).unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    assert_eq!(fs::read(&known_hosts).unwrap(), before);
}

#[test]
fn multiple_plaintext_fingerprints_cannot_register() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let known_hosts = dir.path().join("known_hosts");
    fs::write(
        &known_hosts,
        "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne\n\
         192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChangedKeyBlobForHostProfile\n",
    )
    .unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let check: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(check["state"], "pending");
    assert!(check["presented_fingerprint"].is_null());
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok);
    assert!(
        stderr.contains("plaintext known_hosts") || stderr.contains("ambiguous"),
        "stderr={stderr}"
    );
}

#[test]
fn hashed_known_hosts_is_not_a_register_source() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let known_hosts = dir.path().join("known_hosts");
    fs::write(&known_hosts, "|1|abc|def ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHashed\n").unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok);
    assert!(
        stderr.contains("plaintext known_hosts"),
        "stderr={stderr}"
    );
}

#[test]
fn retargeted_alias_does_not_keep_the_old_registration() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");

    fs::write(
        dir.path().join("g-text.txt"),
        "user ubuntu\r\nhostname 192.0.2.11\r\nport 22\r\n",
    )
    .unwrap();
    fs::write(&known_hosts, "").unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok, "stdout={stdout}");
    assert!(
        stderr.contains("endpoint changed") || stderr.contains("register is not allowed"),
        "stderr={stderr}"
    );
    let record: Value =
        serde_json::from_str(&fs::read_to_string(dir.path().join("lab.json")).unwrap()).unwrap();
    assert_eq!(record["hostname"], "192.0.2.10");
    assert_eq!(record["state"], "blocked");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let blocked: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(blocked["state"], "blocked");
    assert_eq!(blocked["hostname"], "192.0.2.10");
}

#[test]
fn revoked_known_hosts_entry_blocks_even_with_plaintext_copy() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");

    fs::write(
        &known_hosts,
        format!(
            "@revoked 192.0.2.10 ssh-ed25519 {blob}\n192.0.2.10 ssh-ed25519 {blob}\n"
        ),
    )
    .unwrap();
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let blocked: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(blocked["state"], "blocked");
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok);
    assert!(
        stderr.contains("revoked")
            || stderr.contains("ambiguous")
            || stderr.contains("register is not allowed"),
        "stderr={stderr}"
    );
}

#[test]
fn revoked_only_known_hosts_blocks_register_without_plaintext_copy() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = install_fake_ssh(dir.path(), ssh_g_text());
    let blob = "AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlobForHostProfileOne";
    let known_hosts = write_known_hosts(dir.path(), blob);
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "check", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    let (ok, stdout, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(ok, "stderr={stderr} stdout={stdout}");
    fs::write(
        &known_hosts,
        format!("@revoked 192.0.2.10 ssh-ed25519 {blob}\n"),
    )
    .unwrap();
    let (ok, _, stderr) = run_host_profile(
        dir.path(),
        &known_hosts,
        &ssh,
        &["host-profile", "register", "lab", "--json"],
    );
    assert!(!ok);
    assert!(
        stderr.contains("revoked") || stderr.contains("register is not allowed"),
        "stderr={stderr}"
    );
    let record: Value =
        serde_json::from_str(&fs::read_to_string(dir.path().join("lab.json")).unwrap()).unwrap();
    assert_eq!(record["state"], "blocked");
}
