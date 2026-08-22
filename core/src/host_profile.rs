//! HostProfile: OpenSSH alias resolution and a separate non-secret trust record.
//!
//! TASK-771 first PR. Does not spawn an SSH session, allocate a PTY, write
//! OpenSSH files, or store secrets.

use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

pub(crate) const USAGE: &str = "usage: winsmux host-profile <check|register|status> <alias> [--json]";

const SECRET_FIELD_NAMES: [&str; 6] = [
    "password",
    "passphrase",
    "private_key",
    "privatekey",
    "identityfile",
    "identity_file",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum TrustState {
    Pending,
    Registered,
    Blocked,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct HostProfileRecord {
    alias: String,
    hostname: String,
    port: u16,
    user: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    proxyjump: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    confirmed_fingerprint: Option<String>,
    state: TrustState,
}

struct ResolvedHost {
    hostname: String,
    port: u16,
    user: String,
    proxyjump: Option<String>,
}

enum PresentedFingerprint {
    None,
    Unique(String),
    Ambiguous,
    Revoked,
}

pub(crate) fn run_host_profile_command(args: &[&String]) -> io::Result<()> {
    if args.is_empty() || should_print_help(args) {
        println!("{USAGE}");
        return Ok(());
    }

    let action = args[0].as_str();
    if !matches!(action, "check" | "register" | "status") {
        return Err(io::Error::new(ErrorKind::InvalidInput, USAGE.to_string()));
    }

    let rest = &args[1..];
    let json_out = rest.iter().any(|arg| arg.as_str() == "--json");
    let positional: Vec<&str> = rest
        .iter()
        .map(|arg| arg.as_str())
        .filter(|arg| *arg != "--json")
        .collect();
    let alias = positional
        .first()
        .copied()
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, USAGE.to_string()))?;
    validate_alias(alias)?;

    let payload = match action {
        "check" => check_alias(alias)?,
        "register" => register_alias(alias)?,
        "status" => status_alias(alias)?,
        _ => unreachable!(),
    };

    if json_out {
        writeln!(
            io::stdout(),
            "{}",
            serde_json::to_string(&payload)
                .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?
        )?;
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&payload)
                .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?
        );
    }
    Ok(())
}

fn should_print_help(args: &[&String]) -> bool {
    args.iter()
        .any(|arg| matches!(arg.as_str(), "-h" | "--help" | "help"))
}

fn validate_alias(alias: &str) -> io::Result<()> {
    let mut chars = alias.chars();
    let Some(first) = chars.next() else {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "host-profile alias is empty",
        ));
    };
    if !first.is_ascii_alphanumeric() {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "host-profile alias must start with an ASCII letter or digit",
        ));
    }
    if !chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-')) {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "host-profile alias may contain only ASCII letters, digits, '.', '_', and '-'",
        ));
    }
    Ok(())
}

fn check_alias(alias: &str) -> io::Result<serde_json::Value> {
    let resolved = resolve_ssh_g(alias)?;
    let path = record_path(alias)?;
    let mut record = load_record(&path)?.unwrap_or_else(|| HostProfileRecord {
        alias: alias.to_string(),
        hostname: resolved.hostname.clone(),
        port: resolved.port,
        user: resolved.user.clone(),
        proxyjump: resolved.proxyjump.clone(),
        confirmed_fingerprint: None,
        state: TrustState::Pending,
    });
    let presented = known_hosts_fingerprint(&resolved, record.confirmed_fingerprint.as_deref())?;
    if record.confirmed_fingerprint.is_some()
        && (record.hostname != resolved.hostname || record.port != resolved.port)
    {
        record.state = TrustState::Blocked;
        save_record(&path, &record)?;
        return Ok(json!({
            "ok": true,
            "action": "check",
            "alias": alias,
            "hostname": record.hostname,
            "port": record.port,
            "user": record.user,
            "proxyjump": record.proxyjump,
            "state": record.state,
            "presented_fingerprint": json!(null),
            "confirmed_fingerprint": record.confirmed_fingerprint,
        }));
    }
    record.hostname = resolved.hostname.clone();
    record.port = resolved.port;
    record.user = resolved.user.clone();
    record.proxyjump = resolved.proxyjump.clone();
    record.state = next_state(&record, &presented);
    save_record(&path, &record)?;
    let presented_json = match &presented {
        PresentedFingerprint::Unique(fingerprint) => json!(fingerprint),
        PresentedFingerprint::None
        | PresentedFingerprint::Ambiguous
        | PresentedFingerprint::Revoked => json!(null),
    };
    Ok(json!({
        "ok": true,
        "action": "check",
        "alias": alias,
        "hostname": record.hostname,
        "port": record.port,
        "user": record.user,
        "proxyjump": record.proxyjump,
        "state": record.state,
        "presented_fingerprint": presented_json,
        "confirmed_fingerprint": record.confirmed_fingerprint,
    }))
}

fn register_alias(alias: &str) -> io::Result<serde_json::Value> {
    let resolved = resolve_ssh_g(alias)?;
    let path = record_path(alias)?;
    let mut record = load_record(&path)?.ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "host-profile register requires a pending record; run check first",
        )
    })?;
    if record.confirmed_fingerprint.is_some()
        && (record.hostname != resolved.hostname || record.port != resolved.port)
    {
        record.state = TrustState::Blocked;
        save_record(&path, &record)?;
        return Err(io::Error::new(
            ErrorKind::PermissionDenied,
            "host-profile resolved endpoint changed; register is not allowed",
        ));
    }
    let presented = known_hosts_fingerprint(&resolved, record.confirmed_fingerprint.as_deref())?;
    match presented {
        PresentedFingerprint::Ambiguous | PresentedFingerprint::Revoked => {
            if record.confirmed_fingerprint.is_some() {
                record.state = TrustState::Blocked;
                save_record(&path, &record)?;
            }
            return Err(io::Error::new(
                ErrorKind::PermissionDenied,
                "host-profile known_hosts is ambiguous or revoked; register is not allowed",
            ));
        }
        PresentedFingerprint::None => {
            return Err(io::Error::new(
                ErrorKind::NotFound,
                "host-profile register requires a plaintext known_hosts key; none was found",
            ));
        }
        PresentedFingerprint::Unique(presented) => {
            if next_state(&record, &PresentedFingerprint::Unique(presented.clone()))
                == TrustState::Blocked
                || (record.confirmed_fingerprint.is_some()
                    && record.confirmed_fingerprint.as_deref() != Some(presented.as_str()))
            {
                record.state = TrustState::Blocked;
                save_record(&path, &record)?;
                return Err(io::Error::new(
                    ErrorKind::PermissionDenied,
                    "host-profile fingerprint changed; register is not allowed",
                ));
            }
            if record.state == TrustState::Registered
                && record.confirmed_fingerprint.as_deref() == Some(presented.as_str())
            {
                return Ok(json!({
                    "ok": true,
                    "action": "register",
                    "alias": alias,
                    "state": record.state,
                    "confirmed_fingerprint": record.confirmed_fingerprint,
                }));
            }
            record.hostname = resolved.hostname;
            record.port = resolved.port;
            record.user = resolved.user;
            record.proxyjump = resolved.proxyjump;
            record.confirmed_fingerprint = Some(presented);
            record.state = TrustState::Registered;
            save_record(&path, &record)?;
            Ok(json!({
                "ok": true,
                "action": "register",
                "alias": alias,
                "state": record.state,
                "confirmed_fingerprint": record.confirmed_fingerprint,
            }))
        }
    }
}

fn status_alias(alias: &str) -> io::Result<serde_json::Value> {
    let path = record_path(alias)?;
    let Some(record) = load_record(&path)? else {
        return Err(io::Error::new(
            ErrorKind::NotFound,
            format!("host-profile '{alias}' has no local record"),
        ));
    };
    Ok(json!({
        "ok": true,
        "action": "status",
        "alias": alias,
        "hostname": record.hostname,
        "port": record.port,
        "user": record.user,
        "proxyjump": record.proxyjump,
        "state": record.state,
        "confirmed_fingerprint": record.confirmed_fingerprint,
    }))
}

fn next_state(record: &HostProfileRecord, presented: &PresentedFingerprint) -> TrustState {
    match (
        &record.state,
        record.confirmed_fingerprint.as_deref(),
        presented,
    ) {
        (_, _, PresentedFingerprint::Revoked) => TrustState::Blocked,
        (_, Some(_), PresentedFingerprint::Ambiguous) => TrustState::Blocked,
        (_, Some(confirmed), PresentedFingerprint::Unique(presented))
            if confirmed != presented =>
        {
            TrustState::Blocked
        }
        (TrustState::Blocked, _, _) => TrustState::Blocked,
        (TrustState::Registered, Some(confirmed), PresentedFingerprint::Unique(presented))
            if confirmed == presented =>
        {
            TrustState::Registered
        }
        (TrustState::Registered, Some(_), PresentedFingerprint::None) => TrustState::Registered,
        _ => TrustState::Pending,
    }
}

fn resolve_ssh_g(alias: &str) -> io::Result<ResolvedHost> {
    let ssh = env_nonempty("WINSMUX_HOST_PROFILE_SSH").unwrap_or_else(|| "ssh".to_string());
    let output = Command::new(&ssh)
        .args(["-G", "--", alias])
        .output()
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("host-profile failed to exec ssh -G: {error}"),
            )
        })?;
    if !output.status.success() {
        return Err(io::Error::new(
            ErrorKind::NotFound,
            format!("OpenSSH alias '{alias}' did not resolve; winsmux will not invent a host"),
        ));
    }
    let stdout = String::from_utf8(output.stdout)
        .map_err(|_| io::Error::new(ErrorKind::InvalidData, "ssh -G output was not UTF-8"))?;
    let resolved = parse_ssh_g(&stdout)?;
    if resolved.hostname.eq_ignore_ascii_case(alias) {
        return Err(io::Error::new(
            ErrorKind::NotFound,
            format!(
                "OpenSSH alias '{alias}' did not rewrite HostName; winsmux will not invent a host"
            ),
        ));
    }
    Ok(resolved)
}

fn parse_ssh_g(text: &str) -> io::Result<ResolvedHost> {
    let mut hostname = None;
    let mut user = None;
    let mut port = 22u16;
    let mut proxyjump = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.splitn(2, |ch: char| ch.is_ascii_whitespace());
        let key = parts.next().unwrap_or("").to_ascii_lowercase();
        let value = parts.next().unwrap_or("").trim();
        match key.as_str() {
            "hostname" => hostname = Some(value.to_string()),
            "user" => user = Some(value.to_string()),
            "port" => {
                port = value.parse().map_err(|_| {
                    io::Error::new(ErrorKind::InvalidData, "ssh -G port is not a u16")
                })?;
            }
            "proxyjump" if !value.is_empty() => proxyjump = Some(value.to_string()),
            _ => {}
        }
    }
    let hostname = hostname.ok_or_else(|| {
        io::Error::new(ErrorKind::InvalidData, "ssh -G did not report hostname")
    })?;
    if hostname.is_empty() {
        return Err(io::Error::new(
            ErrorKind::NotFound,
            "OpenSSH alias did not resolve a hostname; winsmux will not invent a host",
        ));
    }
    Ok(ResolvedHost {
        hostname,
        port,
        user: user.unwrap_or_default(),
        proxyjump,
    })
}

fn known_hosts_fingerprint(
    host: &ResolvedHost,
    confirmed: Option<&str>,
) -> io::Result<PresentedFingerprint> {
    let Some(path) = known_hosts_path()? else {
        return Ok(PresentedFingerprint::None);
    };
    if !path.is_file() {
        return Ok(PresentedFingerprint::None);
    }
    let text = fs::read_to_string(&path)?;
    let mut revoked = Vec::new();
    let mut found: Option<String> = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with("|1|") {
            continue;
        }
        if let Some(rest) = line.strip_prefix("@revoked") {
            let rest = rest.trim();
            let mut parts = rest.split_whitespace();
            let names = parts.next().unwrap_or("");
            let key_type = parts.next().unwrap_or("");
            let blob = parts.next().unwrap_or("");
            if key_type.is_empty() || blob.is_empty() {
                continue;
            }
            if names == "*" || host_names_match(names, host) {
                revoked.push(fingerprint_blob(blob));
            }
            continue;
        }
        if line.starts_with('@') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let names = parts.next().unwrap_or("");
        let key_type = parts.next().unwrap_or("");
        let blob = parts.next().unwrap_or("");
        if key_type.is_empty() || blob.is_empty() {
            continue;
        }
        if !host_names_match(names, host) {
            continue;
        }
        let fingerprint = fingerprint_blob(blob);
        match &found {
            Some(existing) if existing != &fingerprint => {
                if confirmed.is_some_and(|confirmed| revoked.iter().any(|item| item == confirmed)) {
                    return Ok(PresentedFingerprint::Revoked);
                }
                return Ok(PresentedFingerprint::Ambiguous);
            }
            None => found = Some(fingerprint),
            Some(_) => {}
        }
    }
    if confirmed.is_some_and(|confirmed| revoked.iter().any(|item| item == confirmed)) {
        return Ok(PresentedFingerprint::Revoked);
    }
    match found {
        Some(fingerprint) if revoked.iter().any(|item| item == &fingerprint) => {
            Ok(PresentedFingerprint::Revoked)
        }
        Some(fingerprint) => Ok(PresentedFingerprint::Unique(fingerprint)),
        None => Ok(PresentedFingerprint::None),
    }
}

fn host_names_match(names: &str, host: &ResolvedHost) -> bool {
    let bracketed = format!("[{}]:{}", host.hostname, host.port);
    names.split(',').any(|name| {
        let name = name.trim();
        if name == bracketed {
            return true;
        }
        host.port == 22 && name == host.hostname
    })
}

fn fingerprint_blob(blob: &str) -> String {
    format!("sha256:{:x}", Sha256::digest(blob.as_bytes()))
}

fn record_path(alias: &str) -> io::Result<PathBuf> {
    Ok(profile_dir()?.join(format!("{alias}.json")))
}

fn profile_dir() -> io::Result<PathBuf> {
    if let Some(dir) = env_nonempty("WINSMUX_HOST_PROFILE_DIR") {
        return Ok(PathBuf::from(dir));
    }
    let local = env_nonempty("LOCALAPPDATA")
        .ok_or_else(|| io::Error::new(ErrorKind::NotFound, "LOCALAPPDATA is not set"))?;
    Ok(PathBuf::from(local).join("winsmux").join("host-profiles"))
}

fn known_hosts_path() -> io::Result<Option<PathBuf>> {
    if let Some(path) = env_nonempty("WINSMUX_HOST_PROFILE_KNOWN_HOSTS") {
        return Ok(Some(PathBuf::from(path)));
    }
    let home = env_nonempty("USERPROFILE").or_else(|| env_nonempty("HOME"));
    Ok(home.map(|home| Path::new(&home).join(".ssh").join("known_hosts")))
}

fn load_record(path: &Path) -> io::Result<Option<HostProfileRecord>> {
    if !path.is_file() {
        return Ok(None);
    }
    let text = fs::read_to_string(path)?;
    reject_secret_fields(&text)?;
    let record: HostProfileRecord = serde_json::from_str(&text)
        .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
    Ok(Some(record))
}

fn save_record(path: &Path, record: &HostProfileRecord) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let payload = serde_json::to_vec_pretty(record)
        .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
    fs::write(path, payload)
}

fn reject_secret_fields(text: &str) -> io::Result<()> {
    let value: serde_json::Value = serde_json::from_str(text)
        .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
    let Some(object) = value.as_object() else {
        return Err(io::Error::new(
            ErrorKind::InvalidData,
            "host-profile record must be an object",
        ));
    };
    for key in object.keys() {
        let lowered = key.to_ascii_lowercase();
        if SECRET_FIELD_NAMES.contains(&lowered.as_str()) {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                format!("host-profile record must not contain secret field '{key}'"),
            ));
        }
    }
    Ok(())
}

fn env_nonempty(name: &str) -> Option<String> {
    match std::env::var(name) {
        Ok(value) if !value.trim().is_empty() => Some(value),
        _ => None,
    }
}
