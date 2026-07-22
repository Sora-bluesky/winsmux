use std::{collections::HashMap, fs, io, path::Path};

use serde_json::{Map, Value};

pub(crate) fn read_runtime_role_preferences(
    project_dir: &Path,
    mut validate_role: impl FnMut(&Value) -> io::Result<()>,
) -> io::Result<Option<Value>> {
    let path = project_dir
        .join(".winsmux")
        .join("runtime-role-preferences.json");
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path)?;
    if raw.trim().is_empty() {
        return Ok(None);
    }
    let root = serde_json::from_str::<Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "invalid runtime role preferences: {}: {err}",
                path.display()
            ),
        )
    })?;
    match root.get("version") {
        Some(Value::Number(number)) if number.is_u64() && number.as_u64() == Some(1) => {}
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Unsupported runtime role preferences version. Supported versions: 1.",
            ))
        }
        None => {}
    }
    let (roles, legacy_root) = match root.get("roles") {
        Some(roles) => (roles, false),
        None => (&root, true),
    };
    let roles = canonical_runtime_roles(roles, legacy_root, &mut validate_role)?;
    if legacy_root {
        Ok(Some(roles))
    } else {
        Ok(Some(Value::Object(Map::from_iter([(
            "roles".to_string(),
            roles,
        )]))))
    }
}

fn canonical_runtime_roles(
    roles: &Value,
    legacy_root: bool,
    validate_role: &mut impl FnMut(&Value) -> io::Result<()>,
) -> io::Result<Value> {
    let mut role_identities = HashMap::new();
    if let Some(map) = roles.as_object() {
        let mut canonical = Map::new();
        for (role_id, role) in map {
            if legacy_root && role_id == "version" {
                continue;
            }
            let role = canonical_runtime_role(role)?;
            validate_role(&role)?;
            register_runtime_role_identity(&mut role_identities, role_id)?;
            canonical.insert(role_id.clone(), role);
        }
        return Ok(Value::Object(canonical));
    }
    if let Some(items) = roles.as_array() {
        let mut canonical = Vec::with_capacity(items.len());
        for role in items {
            let role = canonical_runtime_role(role)?;
            validate_role(&role)?;
            let role_id = role
                .get("role_id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            register_runtime_role_identity(&mut role_identities, role_id)?;
            canonical.push(role);
        }
        return Ok(Value::Array(canonical));
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "Invalid runtime role preferences roles.",
    ))
}

fn register_runtime_role_identity(
    identities: &mut HashMap<String, ()>,
    role_id: &str,
) -> io::Result<()> {
    let normalized = role_id.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return Ok(());
    }
    if identities.insert(normalized, ()).is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Duplicate runtime role preference identity.",
        ));
    }
    Ok(())
}

fn canonical_runtime_role(role: &Value) -> io::Result<Value> {
    let Some(source) = role.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid runtime role preference.",
        ));
    };
    let mut canonical = Map::new();
    for (source_key, value) in source {
        let Some(key) = canonical_runtime_role_field(source_key) else {
            continue;
        };
        let value = match value {
            Value::Null => Value::Null,
            Value::String(value) => Value::String(value.clone()),
            Value::Bool(_) | Value::Number(_) => Value::String(value.to_string()),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("Invalid runtime role preference field '{key}'."),
                ))
            }
        };
        if canonical.insert(key.to_string(), value).is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Duplicate runtime role preference field '{key}'."),
            ));
        }
    }
    Ok(Value::Object(canonical))
}

fn canonical_runtime_role_field(source: &str) -> Option<&'static str> {
    let key = source.to_ascii_lowercase().replace('-', "_");
    match key.as_str() {
        "agent" | "provider" => Some("agent"),
        "model" => Some("model"),
        "model_source" | "modelsource" => Some("model_source"),
        "reasoning_effort" | "reasoningeffort" => Some("reasoning_effort"),
        "prompt_transport" | "prompttransport" => Some("prompt_transport"),
        "auth_mode" => Some("auth_mode"),
        "role_id" | "roleid" | "runtime_role" | "runtimerole" => Some("role_id"),
        _ => None,
    }
}

pub(crate) fn reject_retired_commander_options(
    snapshot: &[(&str, Option<String>)],
    is_failure_text: impl Fn(&str) -> bool,
) -> io::Result<()> {
    for (name, raw) in snapshot {
        if !matches!(*name, "@bridge-external-commander" | "@bridge-commanders") {
            continue;
        }
        let Some(raw) = raw else { continue };
        let value = raw.trim();
        if value.is_empty() || is_failure_text(value) {
            continue;
        }
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Retired workspace commander options are not supported.",
        ));
    }
    Ok(())
}

pub(crate) fn read_provider_registry(
    path: &Path,
    mut validate_entry: impl FnMut(&str, &Value, &Path) -> io::Result<()>,
) -> io::Result<Map<String, Value>> {
    if !path.exists() {
        return Ok(default_provider_registry());
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(default_provider_registry());
    }
    let parsed: Value = serde_json::from_str(&raw).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid provider registry JSON at '{}'.", path.display()),
        )
    })?;
    let Some(root) = parsed.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid provider registry JSON at '{}'.", path.display()),
        ));
    };
    match root.get("version") {
        Some(Value::Number(number)) if number.is_u64() && number.as_u64() == Some(1) => {}
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Unsupported provider registry version. Supported versions: 1.",
            ))
        }
        None => {}
    }
    if let Some(slots) = root.get("slots") {
        if slots.is_null() {
            return Ok(root.clone());
        }
        let Some(slots) = slots.as_object() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid provider registry slots.",
            ));
        };
        let mut seen_slot_ids = HashMap::new();
        for (slot_id, entry) in slots {
            let normalized_slot_id = slot_id.trim().to_ascii_lowercase();
            if normalized_slot_id.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("Invalid provider registry slot id at '{}'.", path.display()),
                ));
            }
            if seen_slot_ids.insert(normalized_slot_id, slot_id).is_some() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "Duplicate provider registry slot id '{}' at '{}'.",
                        slot_id,
                        path.display()
                    ),
                ));
            }
            validate_entry(slot_id, entry, path)?;
        }
    }
    Ok(root.clone())
}

fn default_provider_registry() -> Map<String, Value> {
    let mut root = Map::new();
    root.insert("version".to_string(), Value::from(1));
    root.insert("slots".to_string(), Value::Object(Map::new()));
    root
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retired_commander_options_use_one_secret_free_decision_table() {
        for name in ["@bridge-external-commander", "@bridge-commanders"] {
            let snapshot = [
                ("@bridge-external-commander", None),
                ("@bridge-commanders", None),
                (name, Some("secret-marker-value".to_string())),
            ];
            let error = reject_retired_commander_options(&snapshot, |_| false)
                .expect_err("nonblank retired option must be rejected");
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
            assert!(!error.to_string().contains("secret-marker"));
        }

        let controls = [
            ("@bridge-external-commander", Some("  ".to_string())),
            ("@bridge-commanders", None),
        ];
        reject_retired_commander_options(&controls, |_| false)
            .expect("blank and missing controls remain accepted");
        let failures = [
            (
                "@bridge-external-commander",
                Some("unknown option".to_string()),
            ),
            ("@bridge-commanders", Some("failed to connect".to_string())),
        ];
        reject_retired_commander_options(&failures, |value| {
            value.contains("unknown") || value.contains("failed to connect")
        })
        .expect("failure text controls remain accepted");
    }
}
