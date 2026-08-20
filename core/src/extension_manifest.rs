use std::{
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

use serde_json::{json, Map, Value};

pub(crate) const USAGE: &str =
    "usage: winsmux extension-manifest [--json] [--project-dir <path>]";

const SURFACE_VOCABULARY: &[&str] = &["layout", "workflow", "status"];
const PERMISSION_VOCABULARY: &[&str] = &[
    "read:summary",
    "read:provider-capabilities",
    "read:skills",
];
const NON_EXTENDABLE: &[&str] = &[
    "pane-io",
    "token-auth",
    "state-stores",
    "provider-adapters",
    "pipe-methods",
    "marketplace",
];
const ROOT_FIELDS: &[&str] = &["version", "extensions"];
const ENTRY_FIELDS: &[&str] = &["display_name", "surface", "permissions"];

#[derive(Debug)]
struct ExtensionManifestRegistry {
    version: u64,
    extensions: Map<String, Value>,
}

pub(crate) fn run_extension_manifest_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("{USAGE}");
        return Ok(());
    }

    let (project_dir, json) = parse_options(args)?;
    let registry = read_extension_manifest_registry(&registry_path(&project_dir))?;
    let payload = payload_for(&registry);

    if json {
        return write_json(&payload);
    }

    println!("extension-manifest");
    println!("  enforcement: declaration_only");
    println!("  hookable_surfaces: none");
    if registry.extensions.is_empty() {
        println!("  extensions: none");
        return Ok(());
    }
    println!("  extensions");
    for extension_id in registry.extensions.keys() {
        println!("    {extension_id}");
    }
    Ok(())
}

fn parse_options(args: &[&String]) -> io::Result<(PathBuf, bool)> {
    let mut project_dir = env::current_dir()?;
    let mut json = false;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(invalid_input(USAGE));
                };
                project_dir = PathBuf::from(value.as_str());
                index += 2;
            }
            _ => return Err(invalid_input(USAGE)),
        }
    }
    Ok((project_dir, json))
}

fn registry_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("extension-manifest.json")
}

fn read_extension_manifest_registry(path: &Path) -> io::Result<ExtensionManifestRegistry> {
    if !path.exists() {
        return Ok(empty_registry());
    }

    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(empty_registry());
    }

    let parsed: Value = serde_json::from_str(&raw).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid extension-manifest JSON.",
        )
    })?;
    parse_registry(&parsed)
}

fn empty_registry() -> ExtensionManifestRegistry {
    ExtensionManifestRegistry {
        version: 1,
        extensions: Map::new(),
    }
}

fn parse_registry(parsed: &Value) -> io::Result<ExtensionManifestRegistry> {
    let Some(root) = parsed.as_object() else {
        return Err(invalid_manifest("extension-manifest root must be an object."));
    };

    for key in root.keys() {
        if !ROOT_FIELDS.contains(&key.as_str()) {
            return Err(invalid_manifest(&format!(
                "Invalid extension-manifest field '{key}'."
            )));
        }
    }

    let version = match root.get("version") {
        Some(Value::Number(number)) => number.as_u64().ok_or_else(|| {
            invalid_manifest("Invalid extension-manifest version.")
        })?,
        Some(_) => return Err(invalid_manifest("Invalid extension-manifest version.")),
        None => return Err(invalid_manifest("Missing extension-manifest field 'version'.")),
    };
    if version != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported extension-manifest version '{version}'. Supported versions: 1."
            ),
        ));
    }

    let raw_extensions = match root.get("extensions") {
        Some(Value::Object(extensions)) => extensions,
        Some(Value::Null) | None => {
            return Ok(ExtensionManifestRegistry {
                version: 1,
                extensions: Map::new(),
            })
        }
        Some(_) => {
            return Err(invalid_manifest(
                "Invalid extension-manifest field 'extensions'.",
            ))
        }
    };

    let mut extensions = Map::new();
    for (extension_id, entry) in raw_extensions {
        if extension_id.trim().is_empty() {
            return Err(invalid_manifest("Invalid extension-manifest id."));
        }
        reject_absolute_path(extension_id, "id")?;
        extensions.insert(
            extension_id.clone(),
            normalize_entry(extension_id, entry)?,
        );
    }

    Ok(ExtensionManifestRegistry {
        version: 1,
        extensions,
    })
}

fn normalize_entry(extension_id: &str, entry: &Value) -> io::Result<Value> {
    let Some(object) = entry.as_object() else {
        return Err(invalid_manifest(&format!(
            "Invalid extension-manifest entry '{extension_id}'."
        )));
    };

    for key in object.keys() {
        if !ENTRY_FIELDS.contains(&key.as_str()) {
            return Err(invalid_manifest(&format!(
                "Invalid extension-manifest field '{key}'."
            )));
        }
    }

    let display_name = required_string(object, "display_name")?;
    let surface = required_string(object, "surface")?;
    if !SURFACE_VOCABULARY.contains(&surface.as_str()) {
        return Err(invalid_manifest(&format!(
            "Invalid extension-manifest surface '{surface}'."
        )));
    }

    let permissions = match object.get("permissions") {
        Some(Value::Array(values)) => {
            let mut grants = Vec::new();
            for value in values {
                let Some(grant) = value.as_str() else {
                    return Err(invalid_manifest(
                        "Invalid extension-manifest field 'permissions'.",
                    ));
                };
                let grant = grant.trim();
                if grant.is_empty() {
                    return Err(invalid_manifest(
                        "Invalid extension-manifest field 'permissions'.",
                    ));
                }
                if !PERMISSION_VOCABULARY.contains(&grant) {
                    return Err(invalid_manifest(&format!(
                        "Invalid extension-manifest permission '{grant}'."
                    )));
                }
                grants.push(Value::String(grant.to_string()));
            }
            grants
        }
        Some(_) => {
            return Err(invalid_manifest(
                "Invalid extension-manifest field 'permissions'.",
            ))
        }
        None => {
            return Err(invalid_manifest(
                "Missing extension-manifest field 'permissions'.",
            ))
        }
    };

    Ok(json!({
        "display_name": display_name,
        "surface": surface,
        "permissions": permissions,
    }))
}

fn required_string(object: &Map<String, Value>, field: &str) -> io::Result<String> {
    match object.get(field) {
        Some(Value::String(value)) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                return Err(invalid_manifest(&format!(
                    "Missing extension-manifest field '{field}'."
                )));
            }
            reject_absolute_path(trimmed, field)?;
            Ok(trimmed.to_string())
        }
        Some(_) => Err(invalid_manifest(&format!(
            "Invalid extension-manifest field '{field}'."
        ))),
        None => Err(invalid_manifest(&format!(
            "Missing extension-manifest field '{field}'."
        ))),
    }
}

fn reject_absolute_path(value: &str, field: &str) -> io::Result<()> {
    if looks_like_absolute_path(value) {
        return Err(invalid_manifest(&format!(
            "Invalid extension-manifest field '{field}'."
        )));
    }
    Ok(())
}

fn looks_like_absolute_path(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.starts_with('/')
        || trimmed.starts_with('\\')
        || (trimmed.len() >= 3
            && trimmed.as_bytes()[0].is_ascii_alphabetic()
            && trimmed.as_bytes()[1] == b':'
            && (trimmed.as_bytes()[2] == b'\\' || trimmed.as_bytes()[2] == b'/'))
}

fn payload_for(registry: &ExtensionManifestRegistry) -> Value {
    json!({
        "version": registry.version,
        "extensions": registry.extensions,
        "hookable_surfaces": [],
        "non_extendable": NON_EXTENDABLE,
        "surface_vocabulary": SURFACE_VOCABULARY,
        "enforcement": "declaration_only",
    })
}

fn write_json(value: &Value) -> io::Result<()> {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize extension-manifest: {err}"),
        )
    })?;
    writeln!(stdout)?;
    Ok(())
}

fn invalid_input(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.to_string())
}

fn invalid_manifest(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_and_missing_are_deterministic() {
        let empty = payload_for(&empty_registry());
        assert_eq!(empty["version"], 1);
        assert_eq!(empty["hookable_surfaces"], json!([]));
        assert_eq!(empty["enforcement"], "declaration_only");
        assert_eq!(empty["extensions"], json!({}));
        assert!(empty.get("registry_path").is_none());
    }

    #[test]
    fn accepted_surface_is_vocabulary_not_hookable() {
        let parsed = parse_registry(&json!({
            "version": 1,
            "extensions": {
                "sample": {
                    "display_name": "Sample",
                    "surface": "layout",
                    "permissions": ["read:summary"]
                }
            }
        }))
        .expect("valid layout vocabulary should parse");
        let payload = payload_for(&parsed);
        assert_eq!(payload["extensions"]["sample"]["surface"], "layout");
        assert_eq!(payload["hookable_surfaces"], json!([]));
    }

    #[test]
    fn unknown_surface_and_grant_fail() {
        assert!(parse_registry(&json!({
            "version": 1,
            "extensions": {
                "sample": {
                    "display_name": "Sample",
                    "surface": "pane",
                    "permissions": ["read:summary"]
                }
            }
        }))
        .is_err());
        assert!(parse_registry(&json!({
            "version": 1,
            "extensions": {
                "sample": {
                    "display_name": "Sample",
                    "surface": "layout",
                    "permissions": ["read:runs"]
                }
            }
        }))
        .is_err());
    }

    #[test]
    fn drive_letter_is_rejected() {
        assert!(looks_like_absolute_path(r"C:\secret"));
        assert!(!looks_like_absolute_path("read:summary"));
        assert!(!looks_like_absolute_path("Sample layout pack"));
    }
}
