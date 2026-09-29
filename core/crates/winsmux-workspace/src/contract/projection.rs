//! Deterministic Draft 7 and TypeScript projections of the Rust declarations.
//!
//! A schema cannot detect duplicate JSON keys, number lexemes, UTF-8 byte/depth
//! limits, snapshot references, request correlation or live authorization/state.
//! Consumers must use the raw-byte contract functions for those checks.
use super::*;
use schemars::JsonSchema;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub fn schemas() -> BTreeMap<String, Value> {
    [
        ("request", schema::<Request>()),
        ("response", schema::<Response>()),
        ("snapshot", schema::<Snapshot>()),
    ]
    .into_iter()
    .map(|(name, value)| (name.into(), value))
    .collect()
}
fn schema<T: JsonSchema>() -> Value {
    let mut v = serde_json::to_value(schemars::schema_for!(T)).unwrap();
    refine(&mut v);
    v["description"]=json!("Structural projection of the Rust contract. Raw-byte validation additionally enforces duplicate keys, integer lexemes, byte/container-depth limits, cross-references, request correlation and runtime authorization/state. No runtime effects are implemented here.");
    v
}
fn refine(v: &mut Value) {
    if let Some(defs) = v.get_mut("definitions").and_then(Value::as_object_mut) {
        if let Some(error) = defs.get_mut("WireError") {
            error["oneOf"]=Value::Array(ErrorCode::ALL.iter().map(|code|json!({"properties":{
                "code":{"const":code},"retryable":{"const":code.retryable()},"message":{"const":code.message()},
                "target_id":if code.allows_target() {json!({})} else {json!({"type":"null"})}
            }})).collect());
        }
        if let Some(observation) = defs.get_mut("RunObservation") {
            let mut rows = Vec::new();
            for p in Process::ALL {
                for w in Work::ALL {
                    for e in Evidence::ALL {
                        for c in [None, Some(0), Some(1)] {
                            if super::validate::observation_allowed(*p, *w, *e, c) {
                                let code = match c {
                                    None => json!({"type":"null"}),
                                    Some(0) => json!({"const":0}),
                                    _ => json!({"type":"integer","not":{"const":0}}),
                                };
                                rows.push(json!({"properties":{"process":{"const":p},"work":{"const":w},"evidence":{"const":e},"exit_code":code}}));
                            }
                        }
                    }
                }
            }
            observation["oneOf"] = Value::Array(rows);
        }
        if let Some(s) = defs.get_mut("OperationStatus") {
            s["oneOf"] = json!([
                {"properties":{"phase":{"enum":["accepted","in_progress","unknown"]},"outcome":{"type":"null"},"error_code":{"type":"null"}}},
                {"properties":{"phase":{"const":"completed"},"outcome":{"const":"succeeded"},"error_code":{"type":"null"}}},
                {"properties":{"phase":{"const":"completed"},"outcome":{"const":"failed"},"error_code":{"$ref":"#/definitions/ErrorCode"}}}
            ]);
        }
        if let Some(s) = defs.get_mut("CleanupRunGetData") {
            s["if"] = json!({"properties":{"cleanup_complete":{"const":true}}});
            s["then"] = json!({"properties":{"run":{"properties":{
                "process":{"const":"exited"},"evidence":{"const":"process_exit"}
            }}}});
        }
        for name in ["ArtifactReadData", "ArtifactDiffData"] {
            if let Some(s) = defs.get_mut(name) {
                s["oneOf"] = json!([
                    {"properties":{"kind":{"const":"text"},"text":{"type":"string"}}},
                    {"properties":{"kind":{"const":"binary"},"text":{"type":"null"},"truncated":{"const":false}}}
                ]);
            }
        }
        if let Some(s) = defs.get_mut("ArtifactRef") {
            s["oneOf"] = json!([
                {"properties":{"run_id":{"type":"null"},"association":{"type":"null"}}},
                {"properties":{"run_id":{"$ref":"#/definitions/RunId"},"association":{"const":"caller_selected"}}}
            ]);
        }
        if let Some(s) = defs.get_mut("PaneSummary") {
            s["oneOf"] = json!([
                {"properties":{"current_run_id":{"type":"null"},"observation":{"type":"null"}}},
                {"properties":{"current_run_id":{"$ref":"#/definitions/RunId"},"observation":{"$ref":"#/definitions/RunObservation"}}}
            ]);
        }
        if let Some(s) = defs.get_mut("CapabilitiesData") {
            s["oneOf"] = json!([
                {"properties":{"providers":{"type":"null"},"shell_profile_ids":{"type":"null"}}},
                {"properties":{"providers":{"type":"array"},"shell_profile_ids":{"type":"array"}}}
            ]);
        }
        if let Some(s) = defs.get_mut("EventsWaitData") {
            s["oneOf"] = json!([
                {"properties":{"status":{"const":"events"},"events":{"minItems":1}}},
                {"properties":{"status":{"const":"no_change"},"events":{"maxItems":0}}},
                {"properties":{"status":{"const":"gap"}}}
            ]);
        }
        if let Some(s) = defs.get_mut("ConnectionDecideParams") {
            s["if"] = json!({"properties":{"decision":{"const":"deny"}}});
            s["then"] =
                json!({"properties":{"project_ids":{"maxItems":0},"scopes":{"maxItems":0}}});
        }
        if let Some(s) = defs.get_mut("ConnectionDecideData") {
            s["if"] = json!({"properties":{"state":{"const":"revoked"}}});
            s["then"] =
                json!({"properties":{"project_ids":{"maxItems":0},"scopes":{"maxItems":0}}});
        }
        if let Some(s) = defs.get_mut("ConnectionInfo") {
            s["oneOf"] = json!([
                {"properties":{"state":{"const":"authenticating"},"executable_name":{"type":"null"},"requested_project_ids":{"maxItems":0},"requested_scopes":{"maxItems":0},"granted_project_ids":{"maxItems":0},"granted_scopes":{"maxItems":0}}},
                {"properties":{"state":{"const":"unpaired"},"executable_name":{"$ref":"#/definitions/NonEmpty"},"requested_project_ids":{"maxItems":0},"requested_scopes":{"maxItems":0},"granted_project_ids":{"maxItems":0},"granted_scopes":{"maxItems":0}}},
                {"properties":{"state":{"const":"pending"},"executable_name":{"$ref":"#/definitions/NonEmpty"},"granted_project_ids":{"maxItems":0},"granted_scopes":{"maxItems":0}}},
                {"properties":{"state":{"const":"granted"},"executable_name":{"$ref":"#/definitions/NonEmpty"}}},
                {"properties":{"state":{"const":"closing"},"granted_project_ids":{"maxItems":0},"granted_scopes":{"maxItems":0}}},
                {"properties":{"state":{"const":"finished"},"granted_project_ids":{"maxItems":0},"granted_scopes":{"maxItems":0}}}
            ]);
        }
        if let Some(s) = defs.get_mut("Selection") {
            s["if"] = json!({"properties":{"selected_project_id":{"type":"null"}}});
            s["then"] = json!({"properties":{"selected_pane_id":{"type":"null"}}});
        }
    }
    let title = v
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if title == "Response" {
        v["oneOf"] = json!([
            {"properties":{"accepted":{"const":true},"result":{"$ref":"#/definitions/Success"},"error":{"type":"null"}}},
            {"properties":{"accepted":{"const":false},"result":{"type":"null"},"error":{"$ref":"#/definitions/WireError"}}}
        ]);
    }
    if title == "Request" {
        // Schemars projects flattened adjacently tagged variants as oneOf.
        // Add the conditional envelope constraints to each operation branch.
        let common = v["properties"].as_object().unwrap().clone();
        let required = v["required"].as_array().unwrap().clone();
        if let Some(branches) = v.get_mut("oneOf").and_then(Value::as_array_mut) {
            for branch in branches {
                for (k, s) in &common {
                    branch["properties"][k] = s.clone();
                }
                branch["required"]
                    .as_array_mut()
                    .unwrap()
                    .extend(required.clone());
                let op = branch["properties"]["operation"]["enum"][0]
                    .as_str()
                    .unwrap_or("");
                if let Ok(name) = serde_json::from_value::<OperationName>(json!(op)) {
                    branch["properties"]["expected_topology_revision"] =
                        if name.class() == OperationClass::T {
                            json!({"$ref":"#/definitions/U"})
                        } else {
                            json!({"type":"null"})
                        };
                    if !matches!(
                        name,
                        OperationName::CapabilitiesGet | OperationName::ConnectionRequest
                    ) {
                        branch["properties"]["instance_id"] =
                            json!({"$ref":"#/definitions/InstanceId"});
                    }
                }
            }
        }
        for key in ["properties", "required", "additionalProperties"] {
            v.as_object_mut().unwrap().remove(key);
        }
    }
}

/// Schema-driven emitter; no independently maintained TypeScript field inventory.
pub fn typescript(schemas: &BTreeMap<String, Value>) -> String {
    let mut types = BTreeMap::new();
    for schema in schemas.values() {
        check_ts_schema(schema);
        if let Some(defs) = schema["definitions"].as_object() {
            for (k, v) in defs {
                types.insert(k.clone(), v.clone());
            }
        }
        types.insert(schema["title"].as_str().unwrap().into(), schema.clone());
    }
    let mut out=String::from("// Generated by winsmux-workspace export_contract. Do not edit.\n// Integers require canonical decimal lexemes and the ranges in the JSON schemas.\n// Runtime callers must validate raw bytes, references and request correlation in Rust.\n");
    for (name, schema) in types {
        out.push_str(&format!("export type {name} = {};\n", ts(&schema)));
    }
    out
}

// This is a projection of our Draft 7 vocabulary, not a general schema compiler.
// Keep every intentional runtime-only keyword explicit; new vocabulary must not
// silently weaken a generated type. Validate even branches handled only in Rust.
fn check_ts_schema(v: &Value) {
    if v.is_boolean() {
        return;
    }
    let schema = v
        .as_object()
        .expect("TypeScript projection needs a schema object or boolean");
    if v["type"] == "object" && v["properties"].as_object().is_some_and(|p| !p.is_empty()) {
        assert_eq!(
            v["additionalProperties"], false,
            "typed property objects must be closed"
        );
    }
    for (key, value) in schema {
        match key.as_str() {
            "definitions" | "properties" => {
                for child in value.as_object().expect("expected a schema map").values() {
                    check_ts_schema(child);
                }
            }
            "oneOf" | "anyOf" => {
                for child in value.as_array().expect("expected schema branches") {
                    check_ts_schema(child);
                }
            }
            "items" | "if" | "then" | "not" => check_ts_schema(value),
            "additionalProperties" => assert!(
                value.is_boolean(),
                "schema-valued additionalProperties is unsupported"
            ),
            "type" => {
                let kinds: Vec<_> = if let Some(kinds) = value.as_array() {
                    assert!(!kinds.is_empty(), "schema type union cannot be empty");
                    kinds.iter().collect()
                } else {
                    vec![value]
                };
                for kind in kinds {
                    assert!(
                        matches!(
                            kind.as_str(),
                            Some(
                                "null"
                                    | "boolean"
                                    | "string"
                                    | "integer"
                                    | "number"
                                    | "array"
                                    | "object"
                            )
                        ),
                        "unsupported TypeScript projection type: {kind}"
                    );
                }
            }
            "$schema" | "title" | "description" | "$ref" | "const" | "enum" | "required" => {}
            // Bounds, string syntax, set uniqueness, negation and conditional
            // predicates remain schema/Rust checks, as documented in schema/README.
            "minimum" | "maximum" | "exclusiveMinimum" | "exclusiveMaximum" | "minLength"
            | "pattern" | "minItems" | "maxItems" | "uniqueItems" => {}
            _ => panic!("unsupported TypeScript projection keyword: {key}"),
        }
    }
}

fn ts_join(parts: Vec<String>, operator: &str, empty: &str) -> String {
    match parts.len() {
        0 => empty.into(),
        1 => parts.into_iter().next().unwrap(),
        _ => format!("({})", parts.join(operator)),
    }
}

fn ts(v: &Value) -> String {
    ts_in(v, &[])
}

fn ts_in(v: &Value, bases: &[&Value]) -> String {
    if v == &Value::Bool(true) {
        return "unknown".into();
    }
    if v == &Value::Bool(false) {
        return "never".into();
    }
    if let Some(r) = v["$ref"].as_str() {
        return r.rsplit('/').next().unwrap().into();
    }
    let mut factors = Vec::new();
    if let Some(c) = v.get("const") {
        factors.push(c.to_string());
    }
    if let Some(e) = v["enum"].as_array() {
        factors.push(ts_join(
            e.iter().map(Value::to_string).collect(),
            " | ",
            "never",
        ));
    }
    if let Some(types) = v["type"].as_array() {
        factors.push(ts_join(
            types
                .iter()
                .map(|t| ts_kind(t.as_str().expect("expected a schema type"), v, bases))
                .collect(),
            " | ",
            "never",
        ));
    } else if let Some(kind) = v["type"].as_str() {
        factors.push(ts_kind(kind, v, bases));
    } else if v.get("properties").is_some() {
        factors.push(ts_object(v, bases));
    }
    let mut branch_bases = bases.to_vec();
    branch_bases.push(v);
    for union in ["oneOf", "anyOf"] {
        if let Some(a) = v[union].as_array() {
            factors.push(ts_join(
                a.iter().map(|s| ts_in(s, &branch_bases)).collect(),
                " | ",
                "never",
            ));
        }
    }
    ts_join(factors, " & ", "unknown")
}

fn ts_kind(kind: &str, schema: &Value, bases: &[&Value]) -> String {
    match kind {
        "null" => "null".into(),
        "boolean" => "boolean".into(),
        "string" => "string".into(),
        "integer" | "number" => "number".into(),
        "array" => {
            // Carry the conjunctive base into every branch. Merely intersecting
            // Array<Known> with Array<unknown> loses fresh element extra-key
            // checks in TypeScript, even though reads still have the known type.
            let items = std::iter::once(schema)
                .chain(bases.iter().copied())
                .filter_map(|s| s.get("items"))
                .map(ts)
                .collect();
            format!("Array<{}>", ts_join(items, " & ", "unknown"))
        }
        "object" => ts_object(schema, bases),
        _ => panic!("unsupported TypeScript projection type: {kind}"),
    }
}
fn ts_object(v: &Value, bases: &[&Value]) -> String {
    let props = v["properties"].as_object();
    if props.is_none_or(|p| p.is_empty()) {
        return if v["additionalProperties"] == Value::Bool(false) {
            "Record<string, never>".into()
        } else {
            // Do not introduce an index signature into a closed union branch:
            // it would either erase its inhabitants or admit fresh extra keys.
            "object".into()
        };
    }
    let required = v["required"].as_array();
    // Constraint branches inherit required fields from the intersected base object.
    let fields = props
        .unwrap()
        .iter()
        .map(|(k, s)| {
            let field_bases: Vec<_> = bases
                .iter()
                .filter_map(|base| base.get("properties").and_then(|p| p.get(k)))
                .collect();
            format!(
                "{}{}: {}",
                serde_json::to_string(k).unwrap(),
                if required.is_some_and(|r| r.contains(&json!(k))) {
                    ""
                } else {
                    "?"
                },
                ts_in(s, &field_bases)
            )
        })
        .collect::<Vec<_>>();
    format!("{{ {} }}", fields.join("; "))
}

pub fn artifacts() -> BTreeMap<String, Vec<u8>> {
    artifacts_from_schemas(&schemas())
}

fn artifacts_from_schemas(schemas: &BTreeMap<String, Value>) -> BTreeMap<String, Vec<u8>> {
    // Export and --check both prepare the complete artifact set before callers
    // can publish anything. Unsupported input must fail before any output exists.
    let typescript = typescript(schemas);
    let mut files = BTreeMap::new();
    for (name, schema) in schemas {
        let mut bytes = serde_json::to_vec_pretty(schema).unwrap();
        bytes.push(b'\n');
        files.insert(
            format!("core/crates/winsmux-workspace/schema/{name}.schema.json"),
            bytes,
        );
    }
    files.insert(
        "winsmux-app/src/generated/workspace-contract.ts".into(),
        typescript.into_bytes(),
    );
    files
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_composition_has_no_artifacts_or_file_changes() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .unwrap();
        let before: BTreeMap<_, _> = artifacts()
            .keys()
            .map(|name| {
                let path = root.join(name);
                (
                    path.clone(),
                    (
                        std::fs::read(&path).unwrap(),
                        std::fs::metadata(&path).unwrap().modified().unwrap(),
                    ),
                )
            })
            .collect();
        assert_eq!(before.len(), 4);
        // These former exploratory positive cases are outside the supported
        // Rust schema vocabulary. They must reject, not silently lose structure.
        for shape in [
            json!({"type":["array","null"],"items":{"type":"string"},"allOf":[{"type":"array"}]}),
            json!({"type":["array","null"],"items":{"type":"object","additionalProperties":false,"properties":{"value":{"type":"string"}},"required":["value"]},"allOf":[{"allOf":[{"type":"array"}]}]}),
            json!({"allOf":[{"type":["string","null"]},{"anyOf":[{"const":"allowed"},{"type":"null"}]}]}),
            json!({"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string"},"optional":{"type":"boolean"}},"required":["kind"],"allOf":[{"properties":{"kind":{"enum":["a","b"]}}}]}),
        ] {
            let mut input = schemas();
            input.get_mut("request").unwrap()["definitions"]["Unsupported"] = shape.clone();
            let mut output = None;
            let rejected = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                output = Some(artifacts_from_schemas(&input));
            }));
            assert!(
                rejected.is_err(),
                "unsupported composition was accepted: {shape}"
            );
            assert!(output.is_none(), "a partial artifact set escaped");
            for (path, (bytes, modified)) in &before {
                assert_eq!(&std::fs::read(path).unwrap(), bytes);
                assert_eq!(
                    &std::fs::metadata(path).unwrap().modified().unwrap(),
                    modified
                );
            }
        }
    }
}

/// Nonmutating comparison, shared by the CLI and in-memory missing/different tests.
pub fn check_artifacts(mut read: impl FnMut(&str) -> Option<Vec<u8>>) -> Result<(), Vec<String>> {
    let different: Vec<_> = artifacts()
        .into_iter()
        .filter_map(|(name, expected)| {
            (read(&name).as_deref() != Some(expected.as_slice())).then_some(name)
        })
        .collect();
    if different.is_empty() {
        Ok(())
    } else {
        Err(different)
    }
}
