use std::{collections::HashMap, fs, io, path::Path};

use serde_json::{Map, Value};

pub(crate) fn read_runtime_role_preferences(project_dir: &Path) -> io::Result<Option<Value>> {
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
    Ok(Some(root))
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
