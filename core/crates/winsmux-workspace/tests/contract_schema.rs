use serde_json::{json, Value};
use winsmux_workspace::contract::*;
const INSTANCE: &str = "10000000-0000-4000-8000-000000000000";
const OP: &str = "20000000-0000-4000-8000-000000000000";
const PROJECT: &str = "30000000-0000-4000-8000-000000000000";
const PANE: &str = "40000000-0000-4000-8000-000000000000";
const RUN: &str = "50000000-0000-4000-8000-000000000000";
const CONNECTION: &str = "60000000-0000-4000-8000-000000000000";
const ARTIFACT: &str = "70000000-0000-4000-8000-000000000000";
const OTHER: &str = "80000000-0000-4000-8000-000000000000";
const TIME: &str = "2026-09-07T12:34:56.123Z";
fn bytes(v: &Value) -> Vec<u8> {
    serde_json::to_vec(v).unwrap()
}
fn request(operation: &str, params: Value) -> Value {
    let topology = matches!(
        operation,
        "project.open"
            | "project.select"
            | "project.forget"
            | "pane.create"
            | "pane.split"
            | "pane.select"
            | "pane.close"
            | "layout.restore"
    );
    json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OP,"expected_topology_revision":if topology {json!(1)} else {Value::Null},"operation":operation,"params":params})
}
fn response(operation: &str, data: Value) -> Value {
    json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OP,"accepted":true,"topology_revision":1,"event_seq":1,"result":{"operation":operation,"data":data},"error":null})
}
#[test]
fn smoke_request_boundary() {
    let v = request("capabilities.get", json!({}));
    assert!(
        parse_request(&bytes(&v)).is_ok(),
        "{:?}",
        parse_request(&bytes(&v))
    );
    for key in v.as_object().unwrap().keys() {
        let mut m = v.clone();
        m.as_object_mut().unwrap().remove(key);
        assert_eq!(
            parse_request(&bytes(&m)),
            Err(ContractError::InvalidShape),
            "{key}"
        );
    }
}

#[test]
fn close_current_guard_is_a_closed_union_and_preserves_legacy_bytes() {
    let legacy = request("pane.close", json!({"pane_id": PANE}));
    let legacy_request = parse_request(&bytes(&legacy)).unwrap();
    let legacy_bytes = canonical_request(&legacy_request).unwrap();
    assert!(String::from_utf8(legacy_bytes.clone()).unwrap().contains(&format!("\"params\":{{\"pane_id\":\"{PANE}\"}}")));
    let mut canonicals = vec![legacy_bytes];
    for expected in [Value::Null, json!(RUN)] {
        let input = request("pane.close", json!({"pane_id":PANE,"expected_current_run_id":expected}));
        let parsed = parse_request(&bytes(&input)).unwrap();
        let Action::PaneClose(params) = &parsed.action else { panic!("close variant") };
        assert!(params.expected_current_run_id.is_some());
        let canonical = canonical_request(&parsed).unwrap();
        assert_eq!(parse_request(&canonical).unwrap(), parsed);
        assert_eq!(serde_json::to_value(&params.expected_current_run_id.as_ref().unwrap()).unwrap(), expected);
        assert!(canonicals.iter().all(|previous| previous != &canonical));
        canonicals.push(canonical);
    }
    for params in [
        json!({"expected_current_run_id":null}),
        json!({"pane_id":PANE,"expected_current_run_id":"invalid"}),
        json!({"pane_id":PANE,"expected_current_run_id":false}),
        json!({"pane_id":PANE,"expected_current_run_id":{}}),
        json!({"pane_id":PANE,"expected_current_run_id":null,"unknown":true}),
        json!({"pane_id":PANE,"unknown":true}),
    ] {
        assert!(parse_request(&bytes(&request("pane.close", params.clone()))).is_err(), "{params}");
    }
    let Action::PaneClose(params) = legacy_request.action else { panic!("legacy close") };
    assert!(params.expected_current_run_id.is_none());
    assert_eq!(serde_json::to_value(params).unwrap(), json!({"pane_id":PANE}));
}

#[test]
fn close_guard_projection_preserves_response_and_snapshot() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap();
    let output = root.join(".evidence/rebuild/v0.38.0/TASK-871/controller/projection");
    std::fs::create_dir_all(&output).unwrap();
    for (name, generated) in projection::artifacts() {
        match name.as_str() {
            "core/crates/winsmux-workspace/schema/request.schema.json" => std::fs::write(output.join("request.schema.json"), generated).unwrap(),
            "winsmux-app/src/generated/workspace-contract.ts" => std::fs::write(output.join("workspace-contract.ts"), generated).unwrap(),
            _ => assert_eq!(std::fs::read(root.join(&name)).unwrap(), generated, "unchanged artifact {name}"),
        }
    }
}

#[test]
fn close_guard_schema_and_strict_codec_agree() {
    let params = [
        (json!({"pane_id":PANE}), true),
        (json!({"pane_id":PANE,"expected_current_run_id":null}), true),
        (json!({"pane_id":PANE,"expected_current_run_id":RUN}), true),
        (json!({"expected_current_run_id":null}), false),
        (json!({"pane_id":PANE,"expected_current_run_id":false}), false),
        (json!({"pane_id":PANE,"expected_current_run_id":"invalid"}), false),
        (json!({"pane_id":PANE,"expected_current_run_id":null,"unknown":true}), false),
        (json!({"pane_id":PANE,"unknown":true}), false),
    ];
    let cases = params.iter().enumerate().map(|(index,(params,valid))| {
        let value = request("pane.close", params.clone());
        assert_eq!(parse_request(&bytes(&value)).is_ok(), *valid);
        json!({"name":format!("guard-{index}"),"kind":"request","value":value,"valid":valid})
    }).collect::<Vec<_>>();
    let result = python(SCHEMA_CHECK, &json!({"schemas":projection::schemas(),"cases":cases}));
    assert_eq!(result["checked"], 8);
    assert_eq!(result["failures"], json!([]), "{result}");
}

fn observation() -> Value {
    json!({"run_id":RUN,"pane_id":PANE,"process":"running","work":"unknown","evidence":"unavailable","observed_at":TIME,"current":true,"exit_code":null})
}
fn status() -> Value {
    json!({"operation_id":OP,"phase":"accepted","outcome":null,"error_code":null})
}
fn artifact() -> Value {
    json!({"artifact_id":ARTIFACT,"project_id":PROJECT,"relative_path":"docs/result.txt","run_id":RUN,"association":"caller_selected"})
}
fn event(kind: &str) -> Value {
    let data = match kind {
        "topology_changed" => {
            json!({"kind":kind,"topology_revision":1,"project_id":PROJECT,"pane_id":PANE})
        }
        "run_state_changed" => json!({"kind":kind,"run":observation()}),
        "operation_state_changed" => json!({"kind":kind,"operation":status()}),
        "connection_state_changed" => {
            json!({"kind":kind,"connection_id":CONNECTION,"state":"granted"})
        }
        _ => panic!("unknown fixture"),
    };
    json!({"event_seq":1,"observed_at":TIME,"data":data})
}
fn fixture(op: &str) -> (Value, Value) {
    let (p, d) = match op {
        "capabilities.get" => (
            json!({}),
            json!({"schema_version":1,"operations":OperationName::ALL,"max_message_bytes":1048576,"providers":[{"provider":"codex","version":"1"},{"provider":"claude","version":"1"}],"replay_capacity":{"retained_bytes":134217728,"active_bytes":268435456},"shell_profile_ids":["pwsh"]}),
        ),
        "connection.request" => (
            json!({"project_ids":[PROJECT],"scopes":["metadata","control"]}),
            json!({"connection_id":CONNECTION,"state":"pending"}),
        ),
        "connection.list" => (
            json!({}),
            json!({"connections":[{"connection_id":CONNECTION,"executable_name":"client.exe","requested_project_ids":[PROJECT],"requested_scopes":["metadata","control"],"granted_project_ids":[PROJECT],"granted_scopes":["metadata"],"state":"granted"}]}),
        ),
        "connection.decide" => (
            json!({"connection_id":CONNECTION,"decision":"allow","project_ids":[PROJECT],"scopes":["metadata"]}),
            json!({"connection_id":CONNECTION,"state":"granted","project_ids":[PROJECT],"scopes":["metadata"]}),
        ),
        "connection.revoke" => (
            json!({"connection_id":CONNECTION}),
            json!({"connection_id":CONNECTION,"state":"revoked"}),
        ),
        "host.stop" => (
            json!({}),
            json!({"stopped":true,"saved_generation":0,"saved_topology_revision":1}),
        ),
        "project.list" => (
            json!({}),
            json!({"projects":[{"project_id":PROJECT,"root_state":"verified","display_name":"日本語","path":"C:/workspace"}],"selected_project_id":PROJECT}),
        ),
        "project.open" => (
            json!({"path":"C:/workspace"}),
            json!({"project_id":PROJECT,"created":true}),
        ),
        "project.select" => (
            json!({"project_id":PROJECT}),
            json!({"selected_project_id":PROJECT,"selected_pane_id":null}),
        ),
        "project.forget" => (
            json!({"project_id":PROJECT}),
            json!({"project_id":PROJECT,"removed":true}),
        ),
        "pane.list" => (
            json!({"project_id":PROJECT}),
            json!({"project_id":PROJECT,"panes":[{"pane_id":PANE,"project_id":PROJECT,"current_run_id":RUN,"observation":observation(),"display_name":"端末","path":"C:/workspace"}],"root":{"kind":"leaf","pane_id":PANE},"selected_pane_id":PANE}),
        ),
        "pane.create" => (
            json!({"project_id":PROJECT,"shell_profile_id":"pwsh"}),
            json!({"pane_id":PANE,"run_id":RUN}),
        ),
        "pane.split" => (
            json!({"pane_id":PANE,"axis":"horizontal"}),
            json!({"pane_id":OTHER,"run_id":RUN}),
        ),
        "pane.select" => (
            json!({"pane_id":PANE}),
            json!({"selected_project_id":PROJECT,"selected_pane_id":PANE}),
        ),
        "pane.close" => (
            json!({"pane_id":PANE}),
            json!({"pane_id":PANE,"closed":true,"selected_pane_id":null}),
        ),
        "pane.resize" => {
            let v = json!({"pane_id":PANE,"run_id":RUN,"cols":80,"rows":24});
            (v.clone(), v)
        }
        "shell.launch" => (
            json!({"pane_id":PANE,"shell_profile_id":"pwsh"}),
            json!({"pane_id":PANE,"run_id":RUN,"phase":"accepted"}),
        ),
        "agent.launch" => (
            json!({"pane_id":PANE,"provider":"codex","model":"model","effort":"high"}),
            json!({"pane_id":PANE,"run_id":RUN,"phase":"accepted"}),
        ),
        "input.write" => (
            json!({"pane_id":PANE,"run_id":RUN,"text":"日本語\r\n"}),
            json!({"pane_id":PANE,"run_id":RUN,"input_seq":1,"written_bytes":11}),
        ),
        "input.key" => (
            json!({"pane_id":PANE,"run_id":RUN,"key":"enter"}),
            json!({"pane_id":PANE,"run_id":RUN,"input_seq":1,"key":"enter","sent":true,"written_bytes":1}),
        ),
        "run.get" => (json!({"run_id":RUN}), json!({"run":observation()})),
        "run.interrupt" => (
            json!({"run_id":RUN}),
            json!({"run_id":RUN,"phase":"accepted"}),
        ),
        "operation.get" => (json!({"operation_id":OP}), json!({"operation":status()})),
        "output.read" => (
            json!({"run_id":RUN,"cursor":"cursor","max_bytes":100}),
            json!({"run_id":RUN,"text":"日本語","next_cursor":"next","gap":false,"truncated":false}),
        ),
        "events.wait" => (
            json!({"after_event_seq":0,"wait_ms":0}),
            json!({"status":"events","events":[event("topology_changed")],"next_event_seq":1}),
        ),
        "layout.save" => (
            json!({}),
            json!({"generation":0,"saved_topology_revision":1}),
        ),
        "layout.restore" => (json!({}), json!({"restored":true,"generation":0})),
        "artifact.register" => (
            json!({"project_id":PROJECT,"relative_path":"docs/result.txt","run_id":RUN}),
            json!({"artifact":artifact()}),
        ),
        "artifact.list" => (
            json!({"project_id":PROJECT}),
            json!({"registered":[artifact()],"git_candidates":["docs/result.txt"]}),
        ),
        "artifact.read" => (
            json!({"artifact_id":ARTIFACT,"max_bytes":100}),
            json!({"artifact_id":ARTIFACT,"kind":"text","size_bytes":9,"text":"日本語","truncated":false}),
        ),
        "artifact.diff" => (
            json!({"artifact_id":ARTIFACT,"max_bytes":100}),
            json!({"artifact_id":ARTIFACT,"kind":"text","text":"+日本語","truncated":false}),
        ),
        "artifact.choose" => (
            json!({"project_id":PROJECT,"left_artifact_id":ARTIFACT,"right_artifact_id":OTHER,"kept_artifact_id":ARTIFACT}),
            json!({"left_artifact_id":ARTIFACT,"right_artifact_id":OTHER,"kept_artifact_id":ARTIFACT}),
        ),
        "artifact.choice.list" => (
            json!({"project_id":PROJECT}),
            json!({"choices":[{"left_artifact_id":ARTIFACT,"right_artifact_id":OTHER,"kept_artifact_id":ARTIFACT}]}),
        ),
        "diagnostics.get" => (
            json!({}),
            json!({"product_version":"0.38.0","protocol_version":1,"capabilities":OperationName::ALL,"connection_state":"granted","failure_codes":ErrorCode::ALL}),
        ),
        _ => panic!("missing fixture {op}"),
    };
    (request(op, p), response(op, d))
}
fn operation_strings() -> Vec<String> {
    OperationName::ALL
        .iter()
        .map(|o| {
            serde_json::to_value(o)
                .unwrap()
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect()
}
fn shape_mutants(v: &Value, path: &str) -> Vec<(String, Value)> {
    let object = v.pointer(path).unwrap().as_object().unwrap();
    let mut result = Vec::new();
    let mut unknown = v.clone();
    unknown.pointer_mut(path).unwrap()["unexpected"] = json!("synthetic marker");
    result.push((format!("{path}:unknown"), unknown));
    for (key, value) in object {
        let mut missing = v.clone();
        missing
            .pointer_mut(path)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove(key);
        result.push((format!("{path}/{key}:missing"), missing));
        let mut wrong = v.clone();
        wrong.pointer_mut(path).unwrap()[key] = if value.is_object() {
            json!([])
        } else {
            json!({"wrong":true})
        };
        result.push((format!("{path}/{key}:type"), wrong));
    }
    result
}
fn check_request(op: &str) {
    let (v, _) = fixture(op);
    let parsed = parse_request(&bytes(&v)).unwrap_or_else(|e| panic!("{op}: {e}"));
    let canonical = canonical_request(&parsed).unwrap();
    assert_eq!(
        canonical_request(&parse_request(&canonical).unwrap()).unwrap(),
        canonical
    );
    for (name, m) in shape_mutants(&v, "/params")
        .into_iter()
        .chain(shape_mutants(&v, ""))
    {
        assert!(parse_request(&bytes(&m)).is_err(), "{op} {name}");
    }
    let mut wrong = v.clone();
    wrong["operation"] = json!("unknown.operation");
    assert_eq!(
        parse_request(&bytes(&wrong)),
        Err(ContractError::InvalidShape)
    );
    wrong = v.clone();
    wrong["expected_topology_revision"] = if v["expected_topology_revision"].is_null() {
        json!(0)
    } else {
        Value::Null
    };
    assert_eq!(
        parse_request(&bytes(&wrong)),
        Err(ContractError::InvariantViolation)
    );
    wrong = v.clone();
    wrong["instance_id"] = Value::Null;
    assert_eq!(
        parse_request(&bytes(&wrong)).is_ok(),
        matches!(op, "capabilities.get" | "connection.request")
    );
}
fn check_success(op: &str) {
    let (q, v) = fixture(op);
    let q = parse_request(&bytes(&q)).unwrap();
    let r = parse_response(&q, &bytes(&v)).unwrap_or_else(|e| panic!("{op}: {e}"));
    let canonical = serialize_response(&q, &r).unwrap();
    assert_eq!(
        serialize_response(&q, &parse_response(&q, &canonical).unwrap()).unwrap(),
        canonical
    );
    for (name, m) in shape_mutants(&v, "/result/data")
        .into_iter()
        .chain(shape_mutants(&v, "/result"))
        .chain(shape_mutants(&v, ""))
    {
        assert!(parse_response(&q, &bytes(&m)).is_err(), "{op} {name}");
    }
    let different = if op == "capabilities.get" {
        "host.stop"
    } else {
        "capabilities.get"
    };
    let mut m = fixture(different).1;
    m["operation_id"] = v["operation_id"].clone();
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::ResponseCorrelation)
    );
    for field in ["operation_id", "instance_id"] {
        let mut m = v.clone();
        m[field] = json!(OTHER);
        assert_eq!(
            parse_response(&q, &bytes(&m)),
            Err(ContractError::ResponseCorrelation)
        );
    }
}
macro_rules! fixture_tests {
    ($($request:ident,$success:ident,$op:literal);+ $(;)?)=>{$(
        #[test]fn $request(){check_request($op)}
        #[test]fn $success(){check_success($op)}
    )+};
}
fixture_tests! {
 request_capabilities_get,success_capabilities_get,"capabilities.get";
 request_connection_request,success_connection_request,"connection.request";
 request_connection_list,success_connection_list,"connection.list";
 request_connection_decide,success_connection_decide,"connection.decide";
 request_connection_revoke,success_connection_revoke,"connection.revoke";
 request_host_stop,success_host_stop,"host.stop";
 request_project_list,success_project_list,"project.list";
 request_project_open,success_project_open,"project.open";
 request_project_select,success_project_select,"project.select";
 request_project_forget,success_project_forget,"project.forget";
 request_pane_list,success_pane_list,"pane.list";
 request_pane_create,success_pane_create,"pane.create";
 request_pane_split,success_pane_split,"pane.split";
 request_pane_select,success_pane_select,"pane.select";
 request_pane_close,success_pane_close,"pane.close";
 request_pane_resize,success_pane_resize,"pane.resize";
 request_shell_launch,success_shell_launch,"shell.launch";
 request_agent_launch,success_agent_launch,"agent.launch";
 request_input_write,success_input_write,"input.write";
 request_input_key,success_input_key,"input.key";
 request_run_get,success_run_get,"run.get";
 request_run_interrupt,success_run_interrupt,"run.interrupt";
 request_operation_get,success_operation_get,"operation.get";
 request_output_read,success_output_read,"output.read";
 request_events_wait,success_events_wait,"events.wait";
 request_layout_save,success_layout_save,"layout.save";
 request_layout_restore,success_layout_restore,"layout.restore";
 request_artifact_register,success_artifact_register,"artifact.register";
 request_artifact_list,success_artifact_list,"artifact.list";
 request_artifact_read,success_artifact_read,"artifact.read";
 request_artifact_diff,success_artifact_diff,"artifact.diff";
 request_artifact_choose,success_artifact_choose,"artifact.choose";
 request_artifact_choice_list,success_artifact_choice_list,"artifact.choice.list";
 request_diagnostics_get,success_diagnostics_get,"diagnostics.get";
}

fn failure(code: ErrorCode, target: Option<TargetId>) -> Value {
    let mut r = response("capabilities.get", json!({}));
    r["accepted"] = json!(false);
    r["result"] = Value::Null;
    r["error"] = serde_json::to_value(code.with_target(target).unwrap()).unwrap();
    r
}
fn check_error(code: ErrorCode) {
    let q = parse_request(&bytes(&fixture("capabilities.get").0)).unwrap();
    let r = failure(code, None);
    assert!(parse_response(&q, &bytes(&r)).is_ok());
    for (name, m) in shape_mutants(&r, "/error") {
        assert!(parse_response(&q, &bytes(&m)).is_err(), "{name}");
    }
    for field in ["message", "retryable", "target_id"] {
        let mut m = r.clone();
        m["error"][field] = match field {
            "message" => json!("SYNTHETIC_SECRET_MARKER"),
            "retryable" => json!(!code.retryable()),
            _ => json!("invalid id"),
        };
        assert!(parse_response(&q, &bytes(&m)).is_err());
    }
    let mut m = r.clone();
    m["error"]["target_id"] = json!(OTHER);
    assert_eq!(parse_response(&q, &bytes(&m)).is_ok(), code.allows_target());
    assert_eq!(
        code.with_target(Some(TargetId::new(OTHER).unwrap()))
            .is_ok(),
        code.allows_target()
    );
    let mut m = r.clone();
    m["error"] = json!([code, code.retryable(), code.message(), null]);
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::InvalidShape)
    );
    m = r.clone();
    m["accepted"] = json!(true);
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::InvariantViolation)
    );
    m = r.clone();
    m["result"] = fixture("capabilities.get").1["result"].clone();
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::InvariantViolation)
    );
    m = r.clone();
    m["error"] = Value::Null;
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::InvariantViolation)
    );
}
macro_rules! error_tests {($($name:ident,$code:ident);+$(;)?)=>{$(#[test]fn $name(){check_error(ErrorCode::$code)})+};}
error_tests! {
 error_invalid_request,InvalidRequest;error_unsupported_version,UnsupportedVersion;
 error_permission_denied,PermissionDenied;error_target_not_found,TargetNotFound;
 error_stale_topology,StaleTopology;error_operation_conflict,OperationConflict;
 error_in_progress,InProgress;error_not_running,NotRunning;error_already_running,AlreadyRunning;
 error_unsupported_capability,UnsupportedCapability;error_output_gap,OutputGap;
 error_persistence_failed,PersistenceFailed;error_runtime_failed,RuntimeFailed;
 error_state_unknown,StateUnknown;error_resource_exhausted,ResourceExhausted;
 error_root_changed,RootChanged;error_unsupported_file,UnsupportedFile;error_not_a_repository,NotARepository;
}
fn check_event(kind: &str) {
    let (q, mut r) = fixture("events.wait");
    r["result"]["data"]["events"][0] = event(kind);
    let q = parse_request(&bytes(&q)).unwrap();
    assert!(parse_response(&q, &bytes(&r)).is_ok());
    for (name, m) in shape_mutants(&r, "/result/data/events/0")
        .into_iter()
        .chain(shape_mutants(&r, "/result/data/events/0/data"))
    {
        assert!(parse_response(&q, &bytes(&m)).is_err(), "{kind} {name}");
    }
    for key in ["text", "path", "argv", "env"] {
        let mut m = r.clone();
        m["result"]["data"]["events"][0]["data"][key] = json!("marker");
        assert_eq!(
            parse_response(&q, &bytes(&m)),
            Err(ContractError::InvalidShape)
        );
    }
    let mut m = r.clone();
    m["result"]["data"]["events"][0]["data"]["kind"] = json!("unknown");
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::InvalidShape)
    );
    m = r.clone();
    m["result"]["data"]["events"][0]["event_seq"] = json!(0);
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::ResponseCorrelation)
    );
    m = r.clone();
    m["result"]["data"]["status"] = json!("no_change");
    assert_eq!(
        parse_response(&q, &bytes(&m)),
        Err(ContractError::InvariantViolation)
    );
}
#[test]
fn event_topology_changed() {
    check_event("topology_changed")
}
#[test]
fn event_run_state_changed() {
    check_event("run_state_changed")
}
#[test]
fn event_operation_state_changed() {
    check_event("operation_state_changed")
}
#[test]
fn event_connection_state_changed() {
    check_event("connection_state_changed")
}

#[test]
fn boundary_integer_lexemes() {
    let source = String::from_utf8(bytes(&request(
        "events.wait",
        json!({"after_event_seq":0,"wait_ms":71}),
    )))
    .unwrap();
    for literal in ["0", "1", "9007199254740991"] {
        assert!(
            parse_request(source.replace("71", literal).as_bytes()).is_ok(),
            "{literal}"
        );
    }
    for literal in [
        "1.0",
        "1e0",
        "-0",
        "-1",
        "9007199254740992",
        "18446744073709551616",
        "1e400",
    ] {
        assert_eq!(
            parse_request(source.replace("71", literal).as_bytes()),
            Err(ContractError::InvalidScalar),
            "{literal}"
        );
    }
    for literal in ["true", "false", "null", "\"1\"", "[]"] {
        assert_eq!(
            parse_request(source.replace("71", literal).as_bytes()),
            Err(ContractError::InvalidShape),
            "{literal}"
        );
    }
    for literal in ["01", "+1", "NaN", "Infinity"] {
        assert_eq!(
            parse_request(source.replace("71", literal).as_bytes()),
            Err(ContractError::InvalidJson),
            "{literal}"
        );
    }
    let (q, r) = fixture("input.write");
    let q = parse_request(&bytes(&q)).unwrap();
    for n in [0, 1, MAX_SAFE_INTEGER, MAX_SAFE_INTEGER + 1] {
        let mut r = r.clone();
        r["result"]["data"]["input_seq"] = json!(n);
        assert_eq!(
            parse_response(&q, &bytes(&r)).is_ok(),
            n > 0 && n <= MAX_SAFE_INTEGER
        );
    }
    let (q, r) = fixture("input.key");
    let q = parse_request(&bytes(&q)).unwrap();
    for n in [0, 1, MAX_SAFE_INTEGER, MAX_SAFE_INTEGER + 1] {
        let mut r = r.clone();
        r["result"]["data"]["input_seq"] = json!(n);
        assert_eq!(
            parse_response(&q, &bytes(&r)).is_ok(),
            n > 0 && n <= MAX_SAFE_INTEGER
        );
    }
    let (q, mut r) = fixture("run.get");
    r["result"]["data"]["run"]["process"] = json!("exited");
    r["result"]["data"]["run"]["work"] = json!("interrupted");
    r["result"]["data"]["run"]["evidence"] = json!("process_exit");
    r["result"]["data"]["run"]["exit_code"] = json!(71);
    let q = parse_request(&bytes(&q)).unwrap();
    let source = String::from_utf8(bytes(&r)).unwrap();
    for literal in ["-2147483648", "2147483647", "0", "-1"] {
        assert!(
            parse_response(&q, source.replace("71", literal).as_bytes()).is_ok(),
            "{literal}"
        );
    }
    for literal in ["-2147483649", "2147483648", "1.0", "1e0", "-0"] {
        assert_eq!(
            parse_response(&q, source.replace("71", literal).as_bytes()),
            Err(ContractError::InvalidScalar),
            "{literal}"
        );
    }
}
#[test]
fn boundary_uuid_domains() {
    macro_rules! ids {($($ty:ty),+)=>{$(assert!(<$ty>::new(PROJECT).is_ok());for id in ["00000000-0000-0000-0000-000000000000","30000000-0000-5000-8000-000000000000","30000000-0000-4000-7000-000000000000","30000000-0000-4000-C000-000000000000"," 30000000-0000-4000-8000-000000000000","{30000000-0000-4000-8000-000000000000}","30000000000040008000000000000000"] {assert_eq!(<$ty>::new(id),Err(ContractError::InvalidScalar));})+};}
    ids!(
        ProjectId,
        PaneId,
        RunId,
        OperationId,
        InstanceId,
        ConnectionId,
        ArtifactId,
        TargetId
    );
    for op in operation_strings() {
        let (q, r) = fixture(&op);
        for (path, _) in scalar_paths(&q)
            .into_iter()
            .filter(|(_, v)| v.as_str().is_some_and(|s| s.len() == 36))
        {
            let mut m = q.clone();
            *m.pointer_mut(&path).unwrap() = json!("bad uuid");
            assert_eq!(
                parse_request(&bytes(&m)),
                Err(ContractError::InvalidScalar),
                "{op} {path}"
            );
        }
        let request = parse_request(&bytes(&q)).unwrap();
        for (path, _) in scalar_paths(&r)
            .into_iter()
            .filter(|(_, v)| v.as_str().is_some_and(|s| s.len() == 36))
        {
            let mut m = r.clone();
            *m.pointer_mut(&path).unwrap() = json!("bad uuid");
            assert_eq!(
                parse_response(&request, &bytes(&m)),
                Err(ContractError::InvalidScalar),
                "{op} {path}"
            );
        }
    }
}
fn scalar_paths(v: &Value) -> Vec<(String, Value)> {
    fn walk(v: &Value, p: String, out: &mut Vec<(String, Value)>) {
        match v {
            Value::Object(m) => {
                for (k, v) in m {
                    walk(
                        v,
                        format!("{p}/{}", k.replace('~', "~0").replace('/', "~1")),
                        out,
                    )
                }
            }
            Value::Array(a) => {
                for (i, v) in a.iter().enumerate() {
                    walk(v, format!("{p}/{i}"), out)
                }
            }
            _ => out.push((p, v.clone())),
        }
    }
    let mut out = Vec::new();
    walk(v, String::new(), &mut out);
    out
}
#[test]
fn boundary_utf8_and_duplicate_keys() {
    let v = bytes(&fixture("capabilities.get").0);
    assert_eq!(parse_request(&[255]), Err(ContractError::InvalidUtf8));
    assert_eq!(
        parse_request(&[b"\xef\xbb\xbf".as_slice(), &v].concat()),
        Err(ContractError::BomForbidden)
    );
    assert_eq!(
        parse_request(&[v.as_slice(), b" {}"].concat()),
        Err(ContractError::InvalidJson)
    );
    for s in [
        r#"{"a":1,"a":2}"#,
        r#"{"a":1,"\u0061":2}"#,
        r#"{"params":{"text":"a","text":"b"}}"#,
        r#"{"layouts":[{"root":{"kind":"leaf","kind":"split"}}]}"#,
    ] {
        assert_eq!(
            parse_request(s.as_bytes()),
            Err(ContractError::DuplicateKey)
        );
        assert_eq!(
            parse_snapshot(s.as_bytes()),
            Err(ContractError::DuplicateKey)
        );
        let q = parse_request(&v).unwrap();
        assert_eq!(
            parse_response(&q, s.as_bytes()),
            Err(ContractError::DuplicateKey)
        );
    }
}
#[test]
fn boundary_message_bytes() {
    let mut v = fixture("input.write").0;
    v["params"]["text"] = json!("");
    let base = bytes(&v).len();
    v["params"]["text"] = json!("x".repeat(MAX_MESSAGE_BYTES - base));
    let exact = bytes(&v);
    assert_eq!(exact.len(), MAX_MESSAGE_BYTES);
    assert!(parse_request(&exact).is_ok());
    v["params"]["text"] = json!("x".repeat(MAX_MESSAGE_BYTES - base + 1));
    assert_eq!(
        parse_request(&bytes(&v)),
        Err(ContractError::MessageTooLarge)
    );
    let mut typed = parse_request(&fixture_bytes("input.write")).unwrap();
    if let Action::InputWrite(p) = &mut typed.action {
        p.text = "x".repeat(MAX_MESSAGE_BYTES);
    }
    assert_eq!(
        canonical_request(&typed),
        Err(ContractError::MessageTooLarge)
    );
    let q = parse_request(&fixture_bytes("project.list")).unwrap();
    let mut r = parse_response(&q, &bytes(&fixture("project.list").1)).unwrap();
    if let Some(Success::ProjectList(d)) = &mut r.result.0 {
        d.projects[0].display_name = Nullable(Some("x".repeat(MAX_MESSAGE_BYTES)));
    }
    assert_eq!(
        serialize_response(&q, &r),
        Err(ContractError::MessageTooLarge)
    );
    let mut s = parse_snapshot(&bytes(&snapshot())).unwrap();
    s.projects[0].display_name = "x".repeat(MAX_MESSAGE_BYTES);
    assert_eq!(serialize_snapshot(&s), Err(ContractError::MessageTooLarge));
}
fn fixture_bytes(op: &str) -> Vec<u8> {
    bytes(&fixture(op).0)
}
fn snapshot() -> Value {
    let identity =
        json!({"volume_serial":"0123456789abcdef","file_id":"0123456789abcdef0123456789abcdef"});
    json!({"schema_version":1,"generation":0,"topology_revision":1,
        "projects":[{"project_id":PROJECT,"path":"C:/workspace","display_name":"日本語","root_identity":identity}],
        "panes":[{"pane_id":PANE,"project_id":PROJECT,"shell_profile_id":"pwsh","provider_profile":{"provider":"claude","model":"model","effort":"high"}},{"pane_id":OTHER,"project_id":PROJECT,"shell_profile_id":"pwsh","provider_profile":null}],
        "layouts":[{"project_id":PROJECT,"root":{"kind":"split","axis":"vertical","ratio":0.5,"first":{"kind":"leaf","pane_id":PANE},"second":{"kind":"leaf","pane_id":OTHER}}}],
        "selected_project_id":PROJECT,"selected_pane_id":PANE})
}
fn empty_snapshot() -> Value {
    json!({"schema_version":1,"generation":0,"topology_revision":0,"projects":[],"panes":[],"layouts":[],"selected_project_id":null,"selected_pane_id":null})
}
#[test]
fn snapshot_reference_closure() {
    for v in [snapshot(), empty_snapshot()] {
        let s = parse_snapshot(&bytes(&v)).unwrap();
        assert_eq!(parse_snapshot(&serialize_snapshot(&s).unwrap()).unwrap(), s);
    }
    let s = snapshot();
    let mut cases = Vec::new();
    let mut m = s.clone();
    let p = m["projects"][0].clone();
    m["projects"].as_array_mut().unwrap().push(p);
    cases.push(m);
    m = s.clone();
    m["panes"][1]["pane_id"] = json!(PANE);
    cases.push(m);
    m = s.clone();
    m["panes"][1]["project_id"] = json!(OTHER);
    cases.push(m);
    m = s.clone();
    m["layouts"] = json!([]);
    cases.push(m);
    m = s.clone();
    let l = m["layouts"][0].clone();
    m["layouts"].as_array_mut().unwrap().push(l);
    cases.push(m);
    m = s.clone();
    m["layouts"][0]["project_id"] = json!(OTHER);
    cases.push(m);
    m = s.clone();
    m["layouts"][0]["root"] = Value::Null;
    cases.push(m);
    m = s.clone();
    m["layouts"][0]["root"]["second"]["pane_id"] = json!(PANE);
    cases.push(m);
    m = s.clone();
    m["selected_project_id"] = Value::Null;
    cases.push(m);
    m = s.clone();
    m["selected_project_id"] = json!(OTHER);
    cases.push(m);
    m = s.clone();
    m["selected_pane_id"] = json!(RUN);
    cases.push(m);
    for (i, m) in cases.iter().enumerate() {
        assert_eq!(
            parse_snapshot(&bytes(m)),
            Err(ContractError::InvariantViolation),
            "case {i}"
        );
    }
    for forbidden in [
        "run_id",
        "pid",
        "input",
        "output",
        "credentials",
        "resume",
        "layout_path",
    ] {
        for path in [
            "",
            "/projects/0",
            "/panes/0",
            "/layouts/0",
            "/layouts/0/root",
        ] {
            let mut m = s.clone();
            m.pointer_mut(path).unwrap()[forbidden] = json!("marker");
            assert_eq!(parse_snapshot(&bytes(&m)), Err(ContractError::InvalidShape));
        }
    }
    for ratio in [json!(0), json!(1), json!(-0.5), json!(1.1)] {
        let mut m = s.clone();
        m["layouts"][0]["root"]["ratio"] = ratio;
        assert_eq!(
            parse_snapshot(&bytes(&m)),
            Err(ContractError::InvalidScalar)
        );
    }
    assert!(Ratio::new(f64::NAN).is_err());
    assert!(Ratio::new(f64::INFINITY).is_err());
    let mut multi = s.clone();
    let mut p = multi["projects"][0].clone();
    p["project_id"] = json!(OTHER);
    multi["projects"].as_array_mut().unwrap().push(p);
    multi["layouts"]
        .as_array_mut()
        .unwrap()
        .push(json!({"project_id":OTHER,"root":null}));
    assert!(parse_snapshot(&bytes(&multi)).is_ok());
    multi["panes"][1]["project_id"] = json!(OTHER);
    assert_eq!(
        parse_snapshot(&bytes(&multi)),
        Err(ContractError::InvariantViolation)
    );
}

#[test]
fn observation_state_cube() {
    // Independent table expansion: not a call to the production predicate.
    let mut legal = std::collections::HashSet::new();
    for p in Process::ALL {
        legal.insert((*p, Work::Unknown, Evidence::Unavailable, None));
    }
    for w in [
        Work::Unknown,
        Work::Running,
        Work::AwaitingInput,
        Work::Succeeded,
        Work::Failed,
    ] {
        legal.insert((Process::Running, w, Evidence::ProviderEvent, None));
    }
    for w in [
        Work::Unknown,
        Work::Succeeded,
        Work::Failed,
        Work::Interrupted,
    ] {
        for c in [None, Some(0)] {
            legal.insert((Process::Exited, w, Evidence::ProviderEvent, c));
        }
    }
    for c in [Some(-1), Some(1), Some(i32::MIN), Some(i32::MAX)] {
        for w in [Work::Failed, Work::Interrupted] {
            legal.insert((Process::Exited, w, Evidence::ProviderEvent, c));
        }
    }
    for c in [None, Some(0)] {
        legal.insert((Process::Exited, Work::Unknown, Evidence::ProcessExit, c));
    }
    legal.insert((
        Process::Exited,
        Work::Succeeded,
        Evidence::ProcessExit,
        Some(0),
    ));
    for c in [Some(-1), Some(1), Some(i32::MIN), Some(i32::MAX)] {
        legal.insert((Process::Exited, Work::Failed, Evidence::ProcessExit, c));
    }
    for c in [
        None,
        Some(0),
        Some(-1),
        Some(1),
        Some(i32::MIN),
        Some(i32::MAX),
    ] {
        legal.insert((Process::Exited, Work::Interrupted, Evidence::ProcessExit, c));
    }
    let mut checked = 0;
    for p in Process::ALL {
        for w in Work::ALL {
            for e in Evidence::ALL {
                for c in [
                    None,
                    Some(0),
                    Some(-1),
                    Some(1),
                    Some(i32::MIN),
                    Some(i32::MAX),
                ] {
                    let expected = legal.contains(&(*p, *w, *e, c));
                    for (op, path) in [
                        ("run.get", "/result/data/run"),
                        ("pane.list", "/result/data/panes/0/observation"),
                        ("events.wait", "/result/data/events/0/data/run"),
                    ] {
                        let (q, mut r) = fixture(op);
                        if op == "events.wait" {
                            r["result"]["data"]["events"][0] = event("run_state_changed");
                        }
                        let o = r.pointer_mut(path).unwrap();
                        o["process"] = json!(p);
                        o["work"] = json!(w);
                        o["evidence"] = json!(e);
                        o["exit_code"] = json!(c);
                        let q = parse_request(&bytes(&q)).unwrap();
                        let parsed = parse_response(&q, &bytes(&r));
                        assert_eq!(parsed.is_ok(), expected, "{op} {p:?}/{w:?}/{e:?}/{c:?}");
                        if !expected {
                            assert_eq!(parsed, Err(ContractError::InvariantViolation));
                        }
                        let constructed: Response = serde_json::from_value(r).unwrap();
                        assert_eq!(serialize_response(&q, &constructed).is_ok(), expected);
                        checked += 1;
                    }
                }
            }
        }
    }
    assert_eq!(checked, 4 * 6 * 3 * 6 * 3);
}

#[test]
fn canonical_equivalence_and_distinction() {
    let a = parse_request(&fixture_bytes("input.write")).unwrap();
    let canonical = canonical_request(&a).unwrap();
    let pretty = serde_json::to_vec_pretty(&fixture("input.write").0).unwrap();
    assert_eq!(
        canonical_request(&parse_request(&pretty).unwrap()).unwrap(),
        canonical
    );
    let v = fixture("input.write").0;
    let reversed = v
        .as_object()
        .unwrap()
        .iter()
        .rev()
        .map(|(k, v)| format!("{}: {}", json!(k), v))
        .collect::<Vec<_>>()
        .join(", ");
    assert_eq!(
        canonical_request(&parse_request(format!("{{ {reversed} }}").as_bytes()).unwrap()).unwrap(),
        canonical
    );
    for text in ["", "日本語\n", "日本語\r\n ", "é", "e\u{301}", " "] {
        let mut v = fixture("input.write").0;
        v["params"]["text"] = json!(text);
        let got = canonical_request(&parse_request(&bytes(&v)).unwrap()).unwrap();
        assert_ne!(got, canonical);
        let value: Value = serde_json::from_slice(&got).unwrap();
        assert_eq!(value["params"]["text"], json!(text));
    }
    let mut v = fixture("input.write").0;
    v["params"]["run_id"] = json!(OTHER);
    assert_ne!(
        canonical_request(&parse_request(&bytes(&v)).unwrap()).unwrap(),
        canonical
    );
    let (mut v, _) = fixture("project.open");
    let a = canonical_request(&parse_request(&bytes(&v)).unwrap()).unwrap();
    v["expected_topology_revision"] = json!(2);
    assert_ne!(
        canonical_request(&parse_request(&bytes(&v)).unwrap()).unwrap(),
        a
    );
    let (mut v, _) = fixture("connection.request");
    v["params"]["project_ids"] = json!([OTHER, PROJECT]);
    let a = canonical_request(&parse_request(&bytes(&v)).unwrap()).unwrap();
    v["params"]["project_ids"] = json!([PROJECT, OTHER]);
    v["params"]["scopes"] = json!(["control", "metadata"]);
    assert_eq!(
        canonical_request(&parse_request(&bytes(&v)).unwrap()).unwrap(),
        a
    );
    v["params"]["scopes"] = json!(["control", "control"]);
    assert_eq!(
        parse_request(&bytes(&v)),
        Err(ContractError::InvariantViolation)
    );
    let mut s = snapshot();
    let a = serialize_snapshot(&parse_snapshot(&bytes(&s)).unwrap()).unwrap();
    s["panes"].as_array_mut().unwrap().reverse();
    assert_eq!(
        serialize_snapshot(&parse_snapshot(&bytes(&s)).unwrap()).unwrap(),
        a
    );
    s["layouts"][0]["root"]["first"]["pane_id"] = json!(OTHER);
    s["layouts"][0]["root"]["second"]["pane_id"] = json!(PANE);
    assert_ne!(
        serialize_snapshot(&parse_snapshot(&bytes(&s)).unwrap()).unwrap(),
        a
    );
}

#[test]
fn serialize_rejects_invalid_constructed_values() {
    let mut q = parse_request(&fixture_bytes("input.write")).unwrap();
    q.expected_topology_revision = Nullable(Some(U::new(0).unwrap()));
    assert_eq!(
        canonical_request(&q),
        Err(ContractError::InvariantViolation)
    );
    let mut s = parse_snapshot(&bytes(&snapshot())).unwrap();
    s.selected_project_id = Nullable(None);
    assert_eq!(
        serialize_snapshot(&s),
        Err(ContractError::InvariantViolation)
    );
    let q = parse_request(&fixture_bytes("input.write")).unwrap();
    let mut r = parse_response(&q, &bytes(&fixture("input.write").1)).unwrap();
    if let Some(Success::InputWrite(d)) = &mut r.result.0 {
        d.written_bytes = U::new(0).unwrap();
    }
    assert_eq!(
        serialize_response(&q, &r),
        Err(ContractError::ResponseCorrelation)
    );
    let mut r = parse_response(&q, &bytes(&fixture("input.write").1)).unwrap();
    r.accepted = false;
    assert_eq!(
        serialize_response(&q, &r),
        Err(ContractError::InvariantViolation)
    );
}

#[test]
fn boundary_depth() {
    if std::env::var_os("WINSMUX_CONTRACT_DEPTH_CHILD").is_some() {
        for text in [
            format!("{}0{}", "[".repeat(200), "]".repeat(200)),
            format!("{}0{}", "{\"a\":".repeat(200), "}".repeat(200)),
        ] {
            assert!(text.len() < MAX_MESSAGE_BYTES);
            assert_eq!(
                parse_request(text.as_bytes()),
                Err(ContractError::NestingLimit)
            );
            assert_eq!(
                parse_snapshot(text.as_bytes()),
                Err(ContractError::NestingLimit)
            );
            let q = parse_request(&fixture_bytes("capabilities.get")).unwrap();
            assert_eq!(
                parse_response(&q, text.as_bytes()),
                Err(ContractError::NestingLimit)
            );
        }
        let mut tree = format!("{{\"kind\":\"leaf\",\"pane_id\":\"{PANE}\"}}");
        for _ in 0..160 {
            tree=format!("{{\"kind\":\"split\",\"axis\":\"vertical\",\"ratio\":0.5,\"first\":{tree},\"second\":{{\"kind\":\"leaf\",\"pane_id\":\"{OTHER}\"}}}}");
        }
        assert_eq!(
            parse_snapshot(format!("{{\"root\":{tree}}}").as_bytes()),
            Err(ContractError::NestingLimit)
        );
        let mut tree = LayoutNode::leaf(PaneId::new(PANE).unwrap());
        let mut accepted = 1;
        loop {
            match LayoutNode::split(
                Axis::Vertical,
                Ratio::new(0.5).unwrap(),
                tree,
                LayoutNode::leaf(PaneId::new(OTHER).unwrap()),
            ) {
                Ok(next) => {
                    tree = next;
                    accepted += 1;
                }
                Err(e) => {
                    assert_eq!(e, ContractError::NestingLimit);
                    break;
                }
            }
        }
        assert_eq!(accepted, 127);
        for depth in [123, 124, 125, 126, 127] {
            let mut s = snapshot();
            let mut root = json!({"kind":"leaf","pane_id":PANE});
            let mut panes = vec![s["panes"][0].clone()];
            for i in 1..depth {
                let id = format!("{i:08}-0000-4000-8000-000000000000");
                let mut pane = s["panes"][0].clone();
                pane["pane_id"] = json!(id);
                panes.push(pane);
                root = json!({"kind":"split","axis":"vertical","ratio":0.5,"first":root,"second":{"kind":"leaf","pane_id":id}});
            }
            s["panes"] = json!(panes);
            s["layouts"][0]["root"] = root;
            let input = bytes(&s);
            let parsed = parse_snapshot(&input);
            assert_eq!(
                parsed.is_ok(),
                depth <= 124,
                "container depth {}",
                depth + 3
            );
            let constructed: Snapshot = serde_json::from_value(s).unwrap();
            assert_eq!(serialize_snapshot(&constructed).is_ok(), depth <= 124);
            drop(constructed);
        }
        return;
    }
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "boundary_depth", "--nocapture"])
        .env("WINSMUX_CONTRACT_DEPTH_CHILD", "1")
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn request_target_and_result_correlations() {
    for (op, paths) in [
        ("connection.decide", vec!["/result/data/connection_id"]),
        ("connection.revoke", vec!["/result/data/connection_id"]),
        ("project.select", vec!["/result/data/selected_project_id"]),
        ("project.forget", vec!["/result/data/project_id"]),
        (
            "pane.resize",
            vec!["/result/data/pane_id", "/result/data/run_id"],
        ),
        ("shell.launch", vec!["/result/data/pane_id"]),
        ("agent.launch", vec!["/result/data/pane_id"]),
        (
            "input.write",
            vec!["/result/data/pane_id", "/result/data/run_id"],
        ),
        (
            "input.key",
            vec!["/result/data/pane_id", "/result/data/run_id"],
        ),
        ("run.get", vec!["/result/data/run/run_id"]),
        ("run.interrupt", vec!["/result/data/run_id"]),
        ("operation.get", vec!["/result/data/operation/operation_id"]),
        ("output.read", vec!["/result/data/run_id"]),
        (
            "artifact.register",
            vec![
                "/result/data/artifact/project_id",
                "/result/data/artifact/run_id",
            ],
        ),
        ("artifact.read", vec!["/result/data/artifact_id"]),
        ("artifact.diff", vec!["/result/data/artifact_id"]),
    ] {
        let (q, r) = fixture(op);
        let q = parse_request(&bytes(&q)).unwrap();
        for path in paths {
            let mut m = r.clone();
            *m.pointer_mut(path).unwrap() = json!(OTHER);
            assert_eq!(
                parse_response(&q, &bytes(&m)),
                Err(ContractError::ResponseCorrelation),
                "{op} {path}"
            );
        }
    }
    for (op, key, value) in [
        ("input.write", "written_bytes", json!(0)),
        ("input.key", "key", json!("escape")),
        ("pane.resize", "rows", json!(30)),
        ("pane.resize", "cols", json!(30)),
        ("pane.split", "pane_id", json!(PANE)),
        ("pane.close", "selected_pane_id", json!(PANE)),
        ("artifact.register", "relative_path", json!("other.txt")),
    ] {
        let (q, mut r) = fixture(op);
        let q = parse_request(&bytes(&q)).unwrap();
        if op == "artifact.register" {
            r["result"]["data"]["artifact"][key] = value;
        } else {
            r["result"]["data"][key] = value;
        }
        assert_eq!(
            parse_response(&q, &bytes(&r)),
            Err(ContractError::ResponseCorrelation),
            "{op} {key}"
        );
    }
    for op in ["output.read", "artifact.read", "artifact.diff"] {
        let (mut q, r) = fixture(op);
        q["params"]["max_bytes"] = json!(1);
        let q = parse_request(&bytes(&q)).unwrap();
        assert_eq!(
            parse_response(&q, &bytes(&r)),
            Err(ContractError::ResponseCorrelation)
        );
    }
    for key in InputKey::ALL {
        let (mut q, mut r) = fixture("input.key");
        q["params"]["key"] = json!(key);
        r["result"]["data"]["key"] = json!(key);
        let q = parse_request(&bytes(&q)).unwrap();
        assert!(parse_response(&q, &bytes(&r)).is_ok());
        r["result"]["data"]["written_bytes"] = json!(2);
        assert_eq!(
            parse_response(&q, &bytes(&r)),
            Err(ContractError::InvalidScalar)
        );
    }
    let (mut q, mut r) = fixture("input.write");
    q["params"]["text"] = json!("");
    r["result"]["data"]["written_bytes"] = json!(0);
    let q = parse_request(&bytes(&q)).unwrap();
    assert!(parse_response(&q, &bytes(&r)).is_ok());
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Expectation {
    Accepted,
    RejectedShape,
    RejectedCorrelation,
}
impl Expectation {
    fn shape_valid(self) -> bool {
        self != Self::RejectedShape
    }
    fn codec_valid(self) -> bool {
        self == Self::Accepted
    }
}

#[derive(Clone)]
struct Case {
    name: String,
    kind: &'static str,
    request: Option<Value>,
    value: Value,
    expectation: Expectation,
}
fn positive_cases() -> Vec<Case> {
    let mut cases = Vec::new();
    for refresh in [false,true] {
        cases.push(Case { name:format!("request_provider_refresh_{refresh}"),kind:"request",request:None,
            value:request("capabilities.get",json!({"refresh":refresh})),expectation:Expectation::Accepted });
    }
    let cleanup_request = request("run.get", json!({"run_id":RUN,"include_cleanup":true}));
    cases.push(Case {
        name: "request_cleanup_run_get".into(),
        kind: "request",
        request: None,
        value: cleanup_request.clone(),
        expectation: Expectation::Accepted,
    });
    for (cleanup, current) in [(false, true), (true, true), (true, false)] {
        let mut run = observation();
        run["current"] = json!(current);
        if cleanup {
            run["process"] = json!("exited");
            run["work"] = json!("succeeded");
            run["evidence"] = json!("process_exit");
            run["exit_code"] = json!(0);
        }
        cases.push(Case {
            name: format!("success_cleanup_run_get_{cleanup}_{current}"),
            kind: "response",
            request: Some(cleanup_request.clone()),
            value: response("run.get", json!({"run":run,"cleanup_complete":cleanup})),
            expectation: Expectation::Accepted,
        });
    }
    for expected in [Value::Null, json!(RUN)] {
        cases.push(Case { name: format!("request_guarded_close_{expected}"), kind: "request", request: None, value: request("pane.close", json!({"pane_id":PANE,"expected_current_run_id":expected})), expectation: Expectation::Accepted });
    }
    for (operation, params) in [
        ("shell.launch", json!({"pane_id":PANE,"shell_profile_id":"pwsh"})),
        ("agent.launch", json!({"pane_id":PANE,"provider":"codex","model":null,"effort":null})),
        ("agent.launch", json!({"pane_id":PANE,"provider":"claude","model":null,"effort":null})),
    ] {
        for expected in [Value::Null, json!(RUN)] {
            let mut params = params.clone();
            params["expected_current_run_id"] = expected;
            cases.push(Case {
                name: format!("request_guarded_launch_{}", cases.len()),
                kind: "request",
                request: None,
                value: request(operation, params),
                expectation: Expectation::Accepted,
            });
        }
    }
    for op in operation_strings() {
        let (q, r) = fixture(&op);
        cases.push(Case {
            name: format!("request_{op}"),
            kind: "request",
            request: None,
            value: q.clone(),
            expectation: Expectation::Accepted,
        });
        cases.push(Case {
            name: format!("success_{op}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    for code in ErrorCode::ALL {
        cases.push(Case {
            name: format!("error_{code:?}"),
            kind: "response",
            request: Some(fixture("capabilities.get").0),
            value: failure(*code, None),
            expectation: Expectation::Accepted,
        });
        if code.allows_target() {
            cases.push(Case {
                name: format!("target_{code:?}"),
                kind: "response",
                request: Some(fixture("capabilities.get").0),
                value: failure(*code, Some(TargetId::new(OTHER).unwrap())),
                expectation: Expectation::Accepted,
            });
        }
    }
    for kind in [
        "topology_changed",
        "run_state_changed",
        "operation_state_changed",
        "connection_state_changed",
    ] {
        let (q, mut r) = fixture("events.wait");
        r["result"]["data"]["events"][0] = event(kind);
        cases.push(Case {
            name: format!("event_{kind}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    cases.push(Case {
        name: "snapshot".into(),
        kind: "snapshot",
        request: None,
        value: snapshot(),
        expectation: Expectation::Accepted,
    });
    cases.push(Case {
        name: "empty_snapshot".into(),
        kind: "snapshot",
        request: None,
        value: empty_snapshot(),
        expectation: Expectation::Accepted,
    });
    // Required-null alternatives are complete legal messages, including coupled
    // fields whose individual null mutation would violate another invariant.
    for op in [
        "capabilities.get",
        "connection.request",
        "project.select",
        "pane.select",
        "agent.launch",
        "output.read",
        "artifact.register",
        "artifact.list",
        "artifact.read",
        "artifact.diff",
        "project.list",
        "pane.list",
        "run.get",
        "operation.get",
        "events.wait",
    ] {
        let (mut q, mut r) = fixture(op);
        match op {
            "capabilities.get" => {
                q["instance_id"] = Value::Null;
                r["result"]["data"]["providers"] = Value::Null;
                r["result"]["data"]["shell_profile_ids"] = Value::Null;
            }
            "connection.request" => q["instance_id"] = Value::Null,
            "project.select" => {
                q["params"]["project_id"] = Value::Null;
                r["result"]["data"]["selected_project_id"] = Value::Null;
            }
            "pane.select" => {
                q["params"]["pane_id"] = Value::Null;
                r["result"]["data"]["selected_pane_id"] = Value::Null;
                r["result"]["data"]["selected_project_id"] = Value::Null;
            }
            "agent.launch" => {
                q["params"]["model"] = Value::Null;
                q["params"]["effort"] = Value::Null;
            }
            "output.read" => q["params"]["cursor"] = Value::Null,
            "artifact.register" => {
                q["params"]["run_id"] = Value::Null;
                r["result"]["data"]["artifact"]["run_id"] = Value::Null;
                r["result"]["data"]["artifact"]["association"] = Value::Null;
            }
            "artifact.list" => {
                r["result"]["data"]["registered"][0]["run_id"] = Value::Null;
                r["result"]["data"]["registered"][0]["association"] = Value::Null;
            }
            "artifact.read" | "artifact.diff" => {
                r["result"]["data"]["kind"] = json!("binary");
                r["result"]["data"]["text"] = Value::Null;
            }
            "project.list" => {
                r["result"]["data"]["projects"][0]["display_name"] = Value::Null;
                r["result"]["data"]["projects"][0]["path"] = Value::Null;
                r["result"]["data"]["selected_project_id"] = Value::Null;
            }
            "pane.list" => {
                let d = &mut r["result"]["data"];
                for key in ["current_run_id", "observation", "display_name", "path"] {
                    d["panes"][0][key] = Value::Null;
                }
                d["selected_pane_id"] = Value::Null;
            }
            "run.get" => {
                let o = &mut r["result"]["data"]["run"];
                o["process"] = json!("exited");
                o["work"] = json!("succeeded");
                o["evidence"] = json!("process_exit");
                o["exit_code"] = json!(0);
            }
            "operation.get" => {
                r["result"]["data"]["operation"]["phase"] = json!("completed");
                r["result"]["data"]["operation"]["outcome"] = json!("failed");
                r["result"]["data"]["operation"]["error_code"] = json!("state_unknown");
            }
            "events.wait" => {
                r["result"]["data"]["events"][0]["data"]["project_id"] = Value::Null;
                r["result"]["data"]["events"][0]["data"]["pane_id"] = Value::Null;
            }
            _ => unreachable!(),
        }
        cases.push(Case {
            name: format!("nullable_request_{op}"),
            kind: "request",
            request: None,
            value: q.clone(),
            expectation: Expectation::Accepted,
        });
        cases.push(Case {
            name: format!("nullable_success_{op}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    let (q, mut r) = fixture("pane.list");
    r["result"]["data"]["panes"] = json!([]);
    r["result"]["data"]["root"] = Value::Null;
    r["result"]["data"]["selected_pane_id"] = Value::Null;
    cases.push(Case {
        name: "empty_panes".into(),
        kind: "response",
        request: Some(q),
        value: r,
        expectation: Expectation::Accepted,
    });
    let mut s = snapshot();
    s["panes"][0]["provider_profile"]["model"] = Value::Null;
    s["panes"][0]["provider_profile"]["effort"] = Value::Null;
    s["selected_pane_id"] = Value::Null;
    cases.push(Case {
        name: "nullable_profile".into(),
        kind: "snapshot",
        request: None,
        value: s,
        expectation: Expectation::Accepted,
    });
    let mut s = snapshot();
    s["panes"] = json!([]);
    s["layouts"][0]["root"] = Value::Null;
    s["selected_pane_id"] = Value::Null;
    s["selected_project_id"] = Value::Null;
    cases.push(Case {
        name: "empty_project".into(),
        kind: "snapshot",
        request: None,
        value: s,
        expectation: Expectation::Accepted,
    });
    for state in RootState::ALL {
        let (q, mut r) = fixture("project.list");
        r["result"]["data"]["projects"][0]["root_state"] = json!(state);
        cases.push(Case {
            name: format!("root_state_{state:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    for state in ConnectionState::ALL {
        let (q, mut r) = fixture("diagnostics.get");
        r["result"]["data"]["connection_state"] = json!(state);
        cases.push(Case {
            name: format!("connection_state_{state:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    for phase in OperationPhase::ALL {
        for outcome in Outcome::ALL {
            let (q, mut r) = fixture("operation.get");
            let d = &mut r["result"]["data"]["operation"];
            d["phase"] = json!(phase);
            if *phase == OperationPhase::Completed {
                d["outcome"] = json!(outcome);
                if *outcome == Outcome::Failed {
                    d["error_code"] = json!("state_unknown");
                }
            }
            cases.push(Case {
                name: format!("operation_{phase:?}_{outcome:?}"),
                kind: "response",
                request: Some(q),
                value: r,
                expectation: Expectation::Accepted,
            });
        }
    }
    for state in WaitStatus::ALL {
        let (q, mut r) = fixture("events.wait");
        r["result"]["data"]["status"] = json!(state);
        if *state == WaitStatus::NoChange {
            r["result"]["data"]["events"] = json!([]);
        }
        cases.push(Case {
            name: format!("wait_{state:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    let (mut q, mut r) = fixture("connection.decide");
    q["params"]["decision"] = json!("deny");
    q["params"]["project_ids"] = json!([]);
    q["params"]["scopes"] = json!([]);
    r["result"]["data"]["state"] = json!("revoked");
    r["result"]["data"]["project_ids"] = json!([]);
    r["result"]["data"]["scopes"] = json!([]);
    cases.push(Case {
        name: "deny_request".into(),
        kind: "request",
        request: None,
        value: q.clone(),
        expectation: Expectation::Accepted,
    });
    cases.push(Case {
        name: "deny_success".into(),
        kind: "response",
        request: Some(q),
        value: r,
        expectation: Expectation::Accepted,
    });
    for state in LiveConnectionState::ALL {
        let (q, mut r) = fixture("connection.list");
        let connection = &mut r["result"]["data"]["connections"][0];
        connection["state"] = json!(state);
        match state {
            LiveConnectionState::Authenticating => {
                connection["executable_name"] = Value::Null;
                connection["requested_project_ids"] = json!([]);
                connection["requested_scopes"] = json!([]);
                connection["granted_project_ids"] = json!([]);
                connection["granted_scopes"] = json!([]);
            }
            LiveConnectionState::Unpaired => {
                connection["requested_project_ids"] = json!([]);
                connection["requested_scopes"] = json!([]);
                connection["granted_project_ids"] = json!([]);
                connection["granted_scopes"] = json!([]);
            }
            LiveConnectionState::Pending
            | LiveConnectionState::Closing
            | LiveConnectionState::Finished => {
                connection["granted_project_ids"] = json!([]);
                connection["granted_scopes"] = json!([]);
            }
            LiveConnectionState::Granted => {}
        }
        cases.push(Case {
            name: format!("live_connection_{state:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    for axis in Axis::ALL {
        let (mut q, _) = fixture("pane.split");
        q["params"]["axis"] = json!(axis);
        cases.push(Case {
            name: format!("axis_{axis:?}"),
            kind: "request",
            request: None,
            value: q,
            expectation: Expectation::Accepted,
        });
    }
    for scope in Scope::ALL {
        let (mut q, _) = fixture("connection.request");
        q["params"]["scopes"] = json!([scope]);
        cases.push(Case {
            name: format!("scope_{scope:?}"),
            kind: "request",
            request: None,
            value: q,
            expectation: Expectation::Accepted,
        });
    }
    for key in InputKey::ALL {
        let (mut q, mut r) = fixture("input.key");
        q["params"]["key"] = json!(key);
        r["result"]["data"]["key"] = json!(key);
        cases.push(Case {
            name: format!("key_request_{key:?}"),
            kind: "request",
            request: None,
            value: q.clone(),
            expectation: Expectation::Accepted,
        });
        cases.push(Case {
            name: format!("key_success_{key:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    for process in Process::ALL {
        let (q, mut r) = fixture("run.get");
        r["result"]["data"]["run"]["process"] = json!(process);
        cases.push(Case {
            name: format!("process_{process:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    for work in Work::ALL {
        let (q, mut r) = fixture("run.get");
        let o = &mut r["result"]["data"]["run"];
        o["evidence"] = json!("provider_event");
        o["work"] = json!(work);
        if *work == Work::Interrupted {
            o["process"] = json!("exited");
        }
        cases.push(Case {
            name: format!("work_{work:?}"),
            kind: "response",
            request: Some(q),
            value: r,
            expectation: Expectation::Accepted,
        });
    }
    cases
}
fn parse_case(c: &Case) -> bool {
    match c.kind {
        "request" => parse_request(&bytes(&c.value)).is_ok(),
        "snapshot" => parse_snapshot(&bytes(&c.value)).is_ok(),
        "response" => {
            let q = parse_request(&bytes(c.request.as_ref().unwrap())).unwrap();
            parse_response(&q, &bytes(&c.value)).is_ok()
        }
        _ => unreachable!(),
    }
}
fn object_paths(v: &Value) -> Vec<String> {
    fn walk(v: &Value, p: String, o: &mut Vec<String>) {
        match v {
            Value::Object(m) => {
                o.push(p.clone());
                for (k, v) in m {
                    walk(v, format!("{p}/{k}"), o)
                }
            }
            Value::Array(a) => {
                for (i, v) in a.iter().enumerate() {
                    walk(v, format!("{p}/{i}"), o)
                }
            }
            _ => {}
        }
    }
    let mut o = Vec::new();
    walk(v, String::new(), &mut o);
    o
}
// Stand-alone wire shape and correlation with the original request are
// separate guarantees. Exact discriminator removal selects a legal legacy
// branch; it never makes another field/type mutation legal.
fn structural_expectation(c: &Case, path: &str, mutant: &Value) -> Expectation {
    let field = match (
        c.kind,
        path,
        c.value["operation"].as_str(),
        c.value["result"]["operation"].as_str(),
    ) {
        ("request", "/params", Some("pane.close" | "shell.launch" | "agent.launch"), _) =>
            "expected_current_run_id",
        ("request", "/params", Some("run.get"), _) => "include_cleanup",
        ("request", "/params", Some("capabilities.get"), _) => "refresh",
        ("response", "/result/data", _, Some("run.get")) => "cleanup_complete",
        _ => return Expectation::RejectedShape,
    };
    let mut legacy = c.value.clone();
    let removed = legacy.pointer_mut(path)
        .and_then(Value::as_object_mut)
        .and_then(|object| object.remove(field));
    if removed.is_none() || mutant != &legacy {
        return Expectation::RejectedShape;
    }
    if c.kind == "response" {
        // The original opt-in request still requires the cleanup response
        // branch. The stand-alone legacy response remains a legal type.
        assert_eq!(c.request.as_ref().unwrap()["params"]["include_cleanup"], json!(true));
        Expectation::RejectedCorrelation
    } else {
        Expectation::Accepted
    }
}
fn structural_cases() -> Vec<Case> {
    let positives = positive_cases();
    let mut all = positives.clone();
    for c in positives {
        for path in object_paths(&c.value) {
            for (name, m) in shape_mutants(&c.value, &path) {
                all.push(Case {
                    name: format!("{}:{name}", c.name),
                    expectation: structural_expectation(&c, &path, &m),
                    value: m,
                    ..c.clone()
                });
            }
            let mut m = c.value.clone();
            *m.pointer_mut(&path).unwrap() = json!([]);
            all.push(Case {
                name: format!("{}:{path}:array_for_object", c.name),
                expectation: structural_expectation(&c, &path, &m),
                value: m,
                ..c.clone()
            });
        }
    }
    all
}
fn python(script: &str, input: &Value) -> Value {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut child = Command::new("python")
        .args(["-c", script])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("existing Python with jsonschema is required");
    let mut stdin = child.stdin.take().unwrap();
    let data = bytes(input);
    let writer = std::thread::spawn(move || stdin.write_all(&data).unwrap());
    let result = child.wait_with_output().unwrap();
    writer.join().unwrap();
    assert!(
        result.status.success(),
        "schema checker failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    serde_json::from_slice(&result.stdout).unwrap()
}
const SCHEMA_CHECK: &str = r#"
import sys,json
for stream in (sys.stdin,sys.stdout,sys.stderr): stream.reconfigure(encoding='utf-8')
from jsonschema import Draft7Validator,FormatChecker
data=json.load(sys.stdin)
validators={name:Draft7Validator(s,format_checker=FormatChecker()) for name,s in data['schemas'].items()}
for s in data['schemas'].values(): Draft7Validator.check_schema(s)
failures=[]
for c in data['cases']:
    errors=list(validators[c['kind']].iter_errors(c['value']))
    if (len(errors)==0)!=c['valid']:
        failures.append({'name':c['name'],'expected':c['valid'],'actual':len(errors)==0,'schema_path':list(errors[0].absolute_schema_path) if errors else []})
print(json.dumps({'checked':len(data['cases']),'failures':failures[:20]}))
"#;
#[test]
fn schema_projection_agreement() {
    let cases = structural_cases();
    for c in &cases {
        assert_eq!(parse_case(c), c.expectation.codec_valid(), "{}", c.name);
    }
    let input = json!({"schemas":projection::schemas(),"cases":cases.iter().map(|c|json!({"name":c.name,"kind":c.kind,"value":c.value,"valid":c.expectation.shape_valid()})).collect::<Vec<_>>()});
    let result = python(SCHEMA_CHECK, &input);
    assert_eq!(result["checked"], json!(cases.len()));
    assert_eq!(result["failures"], json!([]), "{result}");
}

#[test]
fn boundary_paths_and_timestamps() {
    let valid_paths = [
        "a",
        "a/b.txt",
        "日本語/成果.md",
        " a/ file",
        "CONSOLE",
        "com10.txt",
        "a...b",
        "a/auxiliary",
    ];
    let invalid_paths = [
        "",
        "/a",
        "a/",
        "a//b",
        ".",
        "..",
        "a/../b",
        "a/./b",
        "C:/a",
        "C:a",
        "a\\b",
        "\\\\host\\a",
        "//host/a",
        "a:b",
        "a.",
        "a ",
        "a/b.",
        "con",
        "Con.txt",
        "a/COM1.md",
        "LPT9",
        "com¹.txt",
        "conin$",
        "a/\u{7f}b",
        "a/\u{85}b",
        "a\nb",
        "a/aux.txt",
    ];
    let valid_times = [
        TIME,
        "2024-02-29T00:00:00Z",
        "2000-02-29T23:59:59.000000001Z",
    ];
    let invalid_times = [
        "2023-02-29T00:00:00Z",
        "1900-02-29T00:00:00Z",
        "2026-13-01T00:00:00Z",
        "2026-09-07T24:00:00Z",
        "2026-09-07T00:60:00Z",
        "2026-09-07T00:00:61Z",
        "2016-12-31T23:59:60Z",
        "2026-09-07T12:34Z",
        "2026-09-07T12:34:56+00:00",
        "2026-09-07t12:34:56z",
        "2026-09-07T12:34:56.Z",
        "2026-09-07T12:34:56Z\n",
    ];
    let mut cases = Vec::new();
    for (paths, valid) in [(&valid_paths[..], true), (&invalid_paths[..], false)] {
        for path in paths {
            let (mut q, _) = fixture("artifact.register");
            q["params"]["relative_path"] = json!(path);
            assert_eq!(parse_request(&bytes(&q)).is_ok(), valid, "{path:?}");
            cases.push(json!({"name":format!("relative_path:{path:?}"),"kind":"request","value":q,"valid":valid}));
        }
    }
    for (times, valid) in [(&valid_times[..], true), (&invalid_times[..], false)] {
        for time in times {
            let (q, mut r) = fixture("run.get");
            r["result"]["data"]["run"]["observed_at"] = json!(time);
            let q = parse_request(&bytes(&q)).unwrap();
            assert_eq!(parse_response(&q, &bytes(&r)).is_ok(), valid, "{time}");
            cases.push(
                json!({"name":format!("time:{time}"),"kind":"response","value":r,"valid":valid}),
            );
        }
    }
    let result = python(
        SCHEMA_CHECK,
        &json!({"schemas":projection::schemas(),"cases":cases}),
    );
    assert_eq!(result["failures"], json!([]), "{result}");
}

const INVENTORY_CHECK: &str = r#"
import sys,json
for stream in (sys.stdin,sys.stdout,sys.stderr): stream.reconfigure(encoding='utf-8')
from jsonschema import Draft7Validator,FormatChecker
data=json.load(sys.stdin)
expected_fields=set(); expected_null=set(); expected_enum=set()
seen_fields=set(); seen_null=set(); seen_enum=set()
def collect(s,label,validator):
    if not isinstance(s,dict): return
    for field,p in s.get('properties',{}).items():
        name=label+'.'+field
        expected_fields.add(name)
        if field in s.get('required',[]) and validator.evolve(schema=p).is_valid(None): expected_null.add(name)
        collect(p,name,validator)
    for value in s.get('enum',[]): expected_enum.add(label+'='+json.dumps(value))
    for k in ['oneOf','anyOf','allOf']:
        for p in s.get(k,[]): collect(p,label,validator)
    if isinstance(s.get('items'),dict): collect(s['items'],label+'[]',validator)
def walk(s,value,label,root,validator):
    if not isinstance(s,dict): return
    if '$ref' in s:
        name=s['$ref'].split('/')[-1]
        walk(root['definitions'][name],value,name,root,validator)
        return
    if 'enum' in s and value in s['enum']: seen_enum.add(label+'='+json.dumps(value))
    if isinstance(value,dict):
        for field,p in s.get('properties',{}).items():
            if field in value:
                name=label+'.'+field; seen_fields.add(name)
                if value[field] is None: seen_null.add(name)
                walk(p,value[field],name,root,validator)
    if isinstance(value,list) and isinstance(s.get('items'),dict):
        for v in value: walk(s['items'],v,label+'[]',root,validator)
    for k in ['oneOf','anyOf','allOf']:
        for p in s.get(k,[]):
            if validator.evolve(schema=p).is_valid(value): walk(p,value,label,root,validator)
for root in data['schemas'].values():
    validator=Draft7Validator(root,format_checker=FormatChecker())
    collect(root,root['title'],validator)
    for name,s in root.get('definitions',{}).items(): collect(s,name,validator)
for c in data['cases']:
    root=data['schemas'][c['kind']]; validator=Draft7Validator(root,format_checker=FormatChecker())
    assert validator.is_valid(c['value']),c['name']
    walk(root,c['value'],root['title'],root,validator)
print(json.dumps({'fields':len(expected_fields),'fields_checked':len(expected_fields&seen_fields),'nullable':len(expected_null),'nullable_checked':len(expected_null&seen_null),'enum_values':len(expected_enum),'enum_checked':len(expected_enum&seen_enum),'missing_fields':sorted(expected_fields-seen_fields),'missing_null':sorted(expected_null-seen_null),'missing_enum':sorted(expected_enum-seen_enum)}))
"#;
#[test]
fn every_field_enum_and_nullable_inventory() {
    let cases = positive_cases();
    for c in &cases {
        assert!(parse_case(c), "{}", c.name);
    }
    let result = python(
        INVENTORY_CHECK,
        &json!({"schemas":projection::schemas(),"cases":cases.iter().map(|c|json!({"name":c.name,"kind":c.kind,"value":c.value})).collect::<Vec<_>>() }),
    );
    assert_eq!(result["missing_fields"], json!([]), "{result}");
    assert_eq!(result["missing_null"], json!([]), "{result}");
    assert_eq!(result["missing_enum"], json!([]), "{result}");
    assert_eq!(result["fields"], result["fields_checked"]);
    assert_eq!(result["nullable"], result["nullable_checked"]);
    assert_eq!(result["enum_values"], result["enum_checked"]);
    println!("field coverage {result}");
    // All required nullable fields are also individually removed in structural_cases;
    // there are no fallback values or exceptions for an empty object or array.
}

#[test]
fn local_invariant_schema_matrix() {
    let mut cases = Vec::new();
    for p in Process::ALL {
        for w in Work::ALL {
            for e in Evidence::ALL {
                for c in [
                    None,
                    Some(0),
                    Some(-1),
                    Some(1),
                    Some(i32::MIN),
                    Some(i32::MAX),
                ] {
                    let (q, mut r) = fixture("run.get");
                    let o = &mut r["result"]["data"]["run"];
                    o["process"] = json!(p);
                    o["work"] = json!(w);
                    o["evidence"] = json!(e);
                    o["exit_code"] = json!(c);
                    let q = parse_request(&bytes(&q)).unwrap();
                    let valid = parse_response(&q, &bytes(&r)).is_ok();
                    // observation_state_cube independently proves the predicate; here its
                    // exhaustive results must agree with the generated structural projection.
                    cases.push(json!({"name":format!("observation_{p:?}_{w:?}_{e:?}_{c:?}"),"kind":"response","value":r,"valid":valid}));
                }
            }
        }
    }
    for phase in OperationPhase::ALL {
        for outcome in [Value::Null, json!("succeeded"), json!("failed")] {
            for error in [Value::Null, json!("state_unknown")] {
                let (q, mut r) = fixture("operation.get");
                let o = &mut r["result"]["data"]["operation"];
                o["phase"] = json!(phase);
                o["outcome"] = outcome.clone();
                o["error_code"] = error.clone();
                let q = parse_request(&bytes(&q)).unwrap();
                let valid = if *phase == OperationPhase::Completed {
                    (outcome == json!("succeeded") && error.is_null())
                        || (outcome == json!("failed") && !error.is_null())
                } else {
                    outcome.is_null() && error.is_null()
                };
                assert_eq!(parse_response(&q, &bytes(&r)).is_ok(), valid);
                cases.push(json!({"name":format!("operation_status_{phase:?}_{outcome}_{error}"),"kind":"response","value":r,"valid":valid}));
            }
        }
    }
    for code in ErrorCode::ALL {
        for field in ["message", "retryable", "target_id"] {
            let mut r = failure(*code, None);
            r["error"][field] = match field {
                "message" => json!("SYNTHETIC_SECRET_MARKER"),
                "retryable" => json!(!code.retryable()),
                _ => json!(OTHER),
            };
            cases.push(json!({"name":format!("error_{code:?}_{field}"),"kind":"response","value":r,"valid":field=="target_id" && code.allows_target()}));
        }
    }
    for kind in ["text", "binary"] {
        for text in [json!(""), Value::Null] {
            for truncated in [true, false] {
                for op in ["artifact.read", "artifact.diff"] {
                    let (q, mut r) = fixture(op);
                    r["result"]["data"]["kind"] = json!(kind);
                    r["result"]["data"]["text"] = text.clone();
                    r["result"]["data"]["truncated"] = json!(truncated);
                    let q = parse_request(&bytes(&q)).unwrap();
                    let valid = if kind == "text" {
                        !text.is_null()
                    } else {
                        text.is_null() && !truncated
                    };
                    assert_eq!(parse_response(&q, &bytes(&r)).is_ok(), valid);
                    cases.push(json!({"name":format!("{op}_{kind}_{text}_{truncated}"),"kind":"response","value":r,"valid":valid}));
                }
            }
        }
    }
    for value in [
        json!(0),
        json!(1),
        json!(MAX_SAFE_INTEGER),
        json!(MAX_SAFE_INTEGER + 1),
        json!(-1),
        json!(true),
        json!("1"),
    ] {
        let mut q = fixture("pane.resize").0;
        q["params"]["rows"] = value.clone();
        let valid = value
            .as_u64()
            .is_some_and(|v| v > 0 && v <= MAX_SAFE_INTEGER);
        assert_eq!(parse_request(&bytes(&q)).is_ok(), valid);
        cases.push(
            json!({"name":format!("integer_{value}"),"kind":"request","value":q,"valid":valid}),
        );
    }
    for op in operation_strings() {
        let (mut q, _) = fixture(&op);
        q["expected_topology_revision"] = if q["expected_topology_revision"].is_null() {
            json!(0)
        } else {
            Value::Null
        };
        cases.push(
            json!({"name":format!("revision_{op}"),"kind":"request","value":q,"valid":false}),
        );
    }
    let result = python(
        SCHEMA_CHECK,
        &json!({"schemas":projection::schemas(),"cases":cases}),
    );
    assert_eq!(result["failures"], json!([]), "{result}");
}

fn repo_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .to_path_buf()
}
fn find_existing_tool(relative: &str) -> std::path::PathBuf {
    if let Some(root) = std::env::var_os("WINSMUX_CONTRACT_TOOL_ROOT") {
        let root = std::path::PathBuf::from(root);
        assert!(root.is_absolute(), "existing dependency root must be absolute");
        let path = root.join(relative);
        assert!(path.is_file(), "configured existing tool missing");
        return path;
    }
    for root in std::path::Path::new(env!("CARGO_MANIFEST_DIR")).ancestors() {
        let path = root.join(relative);
        if path.is_file() {
            return path;
        }
    }
    panic!("required existing tool missing: {relative}")
}

fn typescript_contract_usage() -> String {
    let mut source = String::from("import type * as Contract from './workspace-contract';\n");
    let mut positive = 0;
    let mut negative = 0;
    for (i, c) in structural_cases().iter().enumerate() {
        let target = match c.kind {
            "request" => "Request",
            "response" => "Response",
            "snapshot" => "Snapshot",
            _ => unreachable!(),
        };
        assert_eq!(parse_case(c), c.expectation.codec_valid(), "{}", c.name);
        if c.expectation.shape_valid() {
            positive += 1;
        } else {
            negative += 1;
            source.push_str("// @ts-expect-error invalid structural fixture\n");
        }
        source.push_str(&format!(
            "const fixture_{i}: Contract.{target} = {}; // {}\n",
            c.value, c.name
        ));
        if c.expectation.shape_valid() && c.kind == "response" {
            let (field, target) = if c.value["accepted"] == json!(true) {
                ("result", "Success")
            } else {
                ("error", "WireError")
            };
            source.push_str(&format!(
                "const payload_{i}: Contract.{target} = {};\n",
                c.value[field]
            ));
        }
    }
    for (i, kind) in [
        "topology_changed",
        "run_state_changed",
        "operation_state_changed",
        "connection_state_changed",
    ]
    .iter()
    .enumerate()
    {
        let e = event(kind);
        source.push_str(&format!(
            "const event_{i}: Contract.MetadataEvent = {e};\nconst event_data_{i}: Contract.EventData = {};\n",
            e["data"]
        ));
    }
    source.push_str(
        r#"
function useCapabilities(value: Contract.CapabilitiesData) {
    if (value.providers !== null) {
        const provider: Contract.ProviderCapability = value.providers[0];
        const name: Contract.Provider = value.providers[0].provider;
        const version: string = value.providers[0].version;
        // @ts-expect-error a known element cannot be used as a number
        const wrong: number = value.providers[0];
    }
}
"#,
    );
    source.push_str(&format!(
        "useCapabilities({});\n",
        fixture("capabilities.get").1["result"]["data"]
    ));
    for (i, op) in operation_strings().iter().enumerate() {
        let (mut q, mut r) = fixture(op);
        q["operation"] = json!("unknown.operation");
        r["result"]["operation"] = json!("unknown.operation");
        source.push_str(&format!(
            "// @ts-expect-error unknown request operation\nconst wrong_request_{i}: Contract.Request = {q};\n// @ts-expect-error unknown success operation\nconst wrong_success_{i}: Contract.Success = {};\n",
            r["result"]
        ));
    }
    for (i, code) in ErrorCode::ALL.iter().enumerate() {
        let mut r = failure(*code, None);
        r["error"]["retryable"] = json!(!code.retryable());
        source.push_str(&format!(
            "// @ts-expect-error error code determines retryability\nconst wrong_error_{i}: Contract.WireError = {};\n",
            r["error"]
        ));
    }
    for (index, (operation, params)) in [
        ("shell.launch", json!({"pane_id":PANE,"shell_profile_id":"pwsh"})),
        ("agent.launch", json!({"pane_id":PANE,"provider":"codex","model":null,"effort":null})),
        ("agent.launch", json!({"pane_id":PANE,"provider":"claude","model":"test-model","effort":"test-effort"})),
    ].into_iter().enumerate() {
        for (form, guard) in [None, Some(Value::Null), Some(json!(RUN))].into_iter().enumerate() {
            let mut p=params.clone();
            if let Some(guard)=guard {p["expected_current_run_id"]=guard;}
            let input=request(operation,p.clone());
            assert!(parse_request(&bytes(&input)).is_ok());
            source.push_str(&format!("const launch_guard_{index}_{form}: Contract.Request = {input};\n"));
            positive+=1;
            let mut negatives=vec![];
            let mut unknown=p.clone();unknown["unknown"]=json!(true);negatives.push(unknown);
            let mut guard_type=p.clone();guard_type["expected_current_run_id"]=json!(false);negatives.push(guard_type);
            for key in params.as_object().unwrap().keys() {
                let mut missing=p.clone();missing.as_object_mut().unwrap().remove(key);negatives.push(missing);
            }
            for (bad, params) in negatives.into_iter().enumerate() {
                let input=request(operation,params);
                assert!(parse_request(&bytes(&input)).is_err());
                source.push_str(&format!("// @ts-expect-error closed launch shape\nconst launch_guard_bad_{index}_{form}_{bad}: Contract.Request = {input};\n"));
                negative+=1;
            }
        }
    }
    println!("TypeScript literal fixtures: {positive} positive, {negative} negative; all response payloads and 4 events");
    source
}

#[test]
fn typescript_rejects_unsupported_schema_vocabulary() {
    for shape in [
        json!({"type":"imaginary"}),
        json!({"type":"array","items":[{"type":"string"}]}),
        json!({"type":"object","additionalProperties":{"type":"string"}}),
        json!({"type":"object","properties":{"value":{"type":"string"}}}),
        json!({"type":"object","patternProperties":{"^x":{"type":"string"}}}),
        json!({"type":"array","items":{"unevaluatedProperties":false}}),
        json!({"if":{"properties":{"nested":{"unknownConstraint":true}}},"then":{"type":"null"}}),
    ] {
        let mut root = shape.clone();
        root["title"] = json!("Unsupported");
        let schemas = std::collections::BTreeMap::from([("unsupported".into(), root)]);
        assert!(
            std::panic::catch_unwind(|| projection::typescript(&schemas)).is_err(),
            "unsupported schema was silently projected: {shape}"
        );
    }
}

fn typescript_schema_shape_usage() -> String {
    let shapes = [
        (
            "EdgeEmpty",
            json!({"type":"object","additionalProperties":false}),
        ),
        (
            "EdgeOpenUnion",
            json!({"type":"object","oneOf":[
                {"type":"object","additionalProperties":false,"required":["kind","value"],"properties":{"kind":{"const":"value"},"value":{"type":"string"}}},
                {"type":"object","additionalProperties":false,"required":["kind"],"properties":{"kind":{"const":"empty"}}}
            ]}),
        ),
        (
            "EdgeNullable",
            json!({"type":["array","null"],"items":{"type":"string"}}),
        ),
        (
            "EdgeIntersection",
            json!({"type":["string","null"],"anyOf":[{"const":"allowed"},{"type":"null"}]}),
        ),
        (
            "EdgeOptional",
            json!({"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string"},"optional":{"type":"boolean"}},"required":["kind"],"oneOf":[{"properties":{"kind":{"enum":["a","b"]}}}]}),
        ),
        ("EdgeTrue", json!(true)),
        ("EdgeFalse", json!(false)),
        ("EdgeUnknown", json!({})),
        (
            "EdgeRef",
            json!({"anyOf":[{"$ref":"#/definitions/EdgeNullable"},{"type":"null"}]}),
        ),
    ];
    let mut definitions = serde_json::Map::new();
    for (name, shape) in shapes {
        definitions.insert(name.into(), shape);
    }
    let schemas = std::collections::BTreeMap::from([(
        "shapes".into(),
        json!({"title":"EdgeRoot","definitions":definitions,"type":"null"}),
    )]);
    let mut source = projection::typescript(&schemas);
    source.push_str(
        r#"
const edgeEmpty: EdgeEmpty = {};
// @ts-expect-error a closed empty object has no extra keys
const edgeEmptyExtra: EdgeEmpty = {extra: true};
const edgeValue: EdgeOpenUnion = {kind: 'value', value: 'ok'};
const edgeOther: EdgeOpenUnion = {kind: 'empty'};
// @ts-expect-error the union branch still requires its value
const edgeMissing: EdgeOpenUnion = {kind: 'value'};
// @ts-expect-error the closed branch rejects fresh extra keys
const edgeExtra: EdgeOpenUnion = {kind: 'empty', extra: true};
const edgeArray: EdgeNullable = ['ok'];
const edgeNull: EdgeNullable = null;
// @ts-expect-error nullable array preserves its item type
const edgeWrongArray: EdgeNullable = [1];
const edgeIntersection: EdgeIntersection = 'allowed';
const edgeIntersectionNull: EdgeIntersection = null;
// @ts-expect-error union factors cannot escape the intersection
const edgeIntersectionWrong: EdgeIntersection = 'other';
const edgeOptional: EdgeOptional = {kind: 'a'};
const edgeOptionalPresent: EdgeOptional = {kind: 'b', optional: true};
// @ts-expect-error the base required field remains required
const edgeOptionalMissing: EdgeOptional = {};
// @ts-expect-error a properties-only constraint restricts the base field
const edgeOptionalWrong: EdgeOptional = {kind: 'c'};
const edgeTrue: EdgeTrue = {arbitrary: ['value']};
const edgeUnknown: EdgeUnknown = 12;
// @ts-expect-error unconstrained is unknown, not any
const edgeUnknownNumber: number = edgeUnknown;
// @ts-expect-error false schema has no inhabitants
const edgeFalse: EdgeFalse = null;
const edgeRef: EdgeRef = ['ok'];
const edgeRefNull: EdgeRef = null;
// @ts-expect-error references preserve the known element type
const edgeRefWrong: EdgeRef = [false];
"#,
    );
    source
}
#[test]
fn typescript_projection() {
    let tsc = find_existing_tool("winsmux-app/node_modules/typescript/lib/tsc.js");
    let generated = repo_root().join("winsmux-app/src/generated/workspace-contract.ts");
    let result = std::process::Command::new("node")
        .arg(&tsc)
        .args([
            "--noEmit",
            "--strict",
            "--skipLibCheck",
            "--target",
            "ES2022",
            "--module",
            "ESNext",
        ])
        .arg(&generated)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stdout)
    );
    let expected = projection::artifacts();
    assert_eq!(
        std::fs::read(&generated).unwrap(),
        expected["winsmux-app/src/generated/workspace-contract.ts"]
    );
    // In-memory compiler assertions prove discriminants and required-null fields,
    // without creating a second hand-maintained generated type list.
    let script = r#"
const fs=require('node:fs');const path=require('node:path');
const ts=require(process.argv[1]);const generated=process.argv[2];
const virtual=path.join(path.dirname(generated),'contract-usage.ts');
const source=`import type {Request,Response,Success,InputWriteData} from './workspace-contract';
declare const request: Request;
if(request.operation==='input.write'){const s:string=request.params.text;}
declare const response: Response;
if(response.accepted){const n:null=response.error;const s:Success=response.result;}
else {const n:null=response.result;const c:string=response.error.code;}
// @ts-expect-error success data is correlated with its operation
const mismatch:Success={operation:'input.write',data:{stopped:true,saved_generation:0,saved_topology_revision:0}};
// @ts-expect-error all request envelope fields are required
const missing:Request={operation:'capabilities.get',params:{}};
// @ts-expect-error input_seq is a required field
const oldInput:InputWriteData={pane_id:'id',run_id:'id',written_bytes:0};
` + fs.readFileSync(0, 'utf8');
const options={strict:true,noEmit:true,skipLibCheck:true,target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,moduleResolution:ts.ModuleResolutionKind.Node10};
const host=ts.createCompilerHost(options);const originalRead=host.readFile,originalExists=host.fileExists;
host.readFile=p=>path.resolve(p)===virtual?source:originalRead(p);
host.fileExists=p=>path.resolve(p)===virtual||originalExists(p);
const program=ts.createProgram([virtual,generated],options,host);
const errors=ts.getPreEmitDiagnostics(program);
for(const e of errors){const location=e.file&&e.start!==undefined?e.file.getLineAndCharacterOfPosition(e.start):null;console.log(`${location?location.line+1:'?'}: ${ts.flattenDiagnosticMessageText(e.messageText,'\n')}`);if(location)console.log(e.file.text.split('\n').slice(location.line,location.line+2).join('\n'));}
process.exitCode=errors.length?1:0;
"#;
    let ts_module = tsc.parent().unwrap().join("typescript.js");
    let mut child = std::process::Command::new("node")
        .args(["-e", script])
        .arg(ts_module)
        .arg(generated)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let source = typescript_contract_usage() + &typescript_schema_shape_usage();
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(source.as_bytes())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "{} {}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}
#[test]
fn export_check_no_write() {
    let artifacts = projection::artifacts();
    let before = artifacts.clone();
    assert!(projection::check_artifacts(|name| artifacts.get(name).cloned()).is_ok());
    let missing = projection::check_artifacts(|_| None).unwrap_err();
    assert_eq!(missing.len(), 4);
    let different = projection::check_artifacts(|_| Some(b"different\n".to_vec())).unwrap_err();
    assert_eq!(different.len(), 4);
    assert_eq!(artifacts, before);
    for (name, bytes) in artifacts {
        let path = repo_root().join(name);
        let before = std::fs::read(&path).unwrap();
        let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(before, bytes);
        assert!(!bytes.starts_with(b"\xef\xbb\xbf"));
        assert!(!bytes.contains(&b'\r'));
        assert!(bytes.ends_with(b"\n"));
        assert!(!bytes.ends_with(b"\n\n"));
        assert!(
            projection::check_artifacts(|name| std::fs::read(repo_root().join(name)).ok()).is_ok()
        );
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(
            std::fs::metadata(&path).unwrap().modified().unwrap(),
            modified
        );
    }
}

#[test]
fn fixed_error_boundary_inventory() {
    let q = parse_request(&fixture_bytes("capabilities.get")).unwrap();
    let cases = [
        (
            vec![b' '; MAX_MESSAGE_BYTES + 1],
            ContractError::MessageTooLarge,
        ),
        (vec![255], ContractError::InvalidUtf8),
        (b"\xef\xbb\xbf{}".to_vec(), ContractError::BomForbidden),
        (b"{} {}".to_vec(), ContractError::InvalidJson),
        (b"{\"a\":1,\"a\":2}".to_vec(), ContractError::DuplicateKey),
        (
            format!("{}0{}", "[".repeat(200), "]".repeat(200)).into_bytes(),
            ContractError::NestingLimit,
        ),
        (
            b"{\"schema_version\":2}".to_vec(),
            ContractError::UnsupportedSchema,
        ),
        (b"{}".to_vec(), ContractError::InvalidShape),
    ];
    let mut codes = std::collections::BTreeSet::new();
    for (input, error) in cases {
        assert_eq!(parse_request(&input), Err(error));
        assert_eq!(parse_response(&q, &input), Err(error));
        assert_eq!(parse_snapshot(&input), Err(error));
        codes.insert(format!("{error:?}"));
    }
    let mut input = fixture("capabilities.get").0;
    input["operation_id"] = json!("bad uuid");
    assert_eq!(
        parse_request(&bytes(&input)),
        Err(ContractError::InvalidScalar)
    );
    codes.insert("InvalidScalar".into());
    let mut input = fixture("capabilities.get").0;
    input["expected_topology_revision"] = json!(0);
    assert_eq!(
        parse_request(&bytes(&input)),
        Err(ContractError::InvariantViolation)
    );
    codes.insert("InvariantViolation".into());
    let mut response = fixture("capabilities.get").1;
    response["operation_id"] = json!(OTHER);
    assert_eq!(
        parse_response(&q, &bytes(&response)),
        Err(ContractError::ResponseCorrelation)
    );
    codes.insert("ResponseCorrelation".into());
    assert_eq!(codes.len(), 11);
    for marker in ["__scalar", "__invariant", "__duplicate"] {
        let mut input = fixture("capabilities.get").0;
        input["params"][marker] = json!(true);
        assert_eq!(
            parse_request(&bytes(&input)),
            Err(ContractError::InvalidShape)
        );
        let mut output = fixture("capabilities.get").1;
        output[marker] = json!(true);
        assert_eq!(
            parse_response(&q, &bytes(&output)),
            Err(ContractError::InvalidShape)
        );
        let mut saved = snapshot();
        saved[marker] = json!(true);
        assert_eq!(
            parse_snapshot(&bytes(&saved)),
            Err(ContractError::InvalidShape)
        );
    }
    assert_eq!(ErrorCode::ALL.iter().filter(|c| c.is_reserved()).count(), 1);
    assert_eq!(
        ErrorCode::ALL.iter().filter(|c| !c.is_reserved()).count(),
        17
    );
    // Protocol rejection never extracts an ID or manufactures a Response.
    let _: Result<Request, ContractError> = parse_request(b"{\"operation_id\":\"untrusted\"}");
}


#[test]
fn launch_guard_schema_and_strict_codec_agree() {
    let mut cases = Vec::new();
    for (operation, params) in [
        (
            "shell.launch",
            json!({"pane_id":PANE,"shell_profile_id":"pwsh"}),
        ),
        (
            "agent.launch",
            json!({"pane_id":PANE,"provider":"codex","model":null,"effort":null}),
        ),
        (
            "agent.launch",
            json!({"pane_id":PANE,"provider":"claude","model":"test-model","effort":"test-effort"}),
        ),
    ] {
        let mut variations = vec![(params.clone(), true)];
        for guard in [Value::Null, json!(RUN)] {
            let mut p = params.clone();
            p["expected_current_run_id"] = guard;
            variations.push((p, true));
        }
        for guard in [
            json!(false),
            json!(0),
            json!([]),
            json!({}),
            json!("invalid"),
            json!("50000000-0000-1000-8000-000000000000"),
            json!("50000000-0000-4000-7000-000000000000"),
        ] {
            let mut p = params.clone();
            p["expected_current_run_id"] = guard;
            variations.push((p, false));
        }
        for key in params.as_object().unwrap().keys() {
            for guard in [None, Some(Value::Null), Some(json!(RUN))] {
                let mut p = params.clone();
                p.as_object_mut().unwrap().remove(key);
                if let Some(guard) = guard {
                    p["expected_current_run_id"] = guard;
                }
                variations.push((p, false));
            }
        }
        for guard in [None, Some(Value::Null), Some(json!(RUN))] {
            let mut p = params.clone();
            p["unknown"] = json!(true);
            if let Some(guard) = guard {
                p["expected_current_run_id"] = guard;
            }
            variations.push((p, false));
        }
        for (params, valid) in variations {
            let input = request(operation, params);
            assert_eq!(parse_request(&bytes(&input)).is_ok(), valid, "{input}");
            cases.push(json!({"name":format!("launch-guard-{}",cases.len()),"kind":"request","value":input,"valid":valid}));
        }
    }
    let result = python(
        SCHEMA_CHECK,
        &json!({"schemas":projection::schemas(),"cases":cases}),
    );
    assert_eq!(result["checked"], cases.len());
    assert_eq!(result["failures"], json!([]), "{result}");
}

#[test]
fn cleanup_read_closed_shapes_and_response_correlation() {
    let mut cases = Vec::new();
    for params in [json!({"run_id":RUN}), json!({"include_cleanup":true,"run_id":RUN})] {
        let wire = request("run.get", params);
        let typed = parse_request(&bytes(&wire)).unwrap();
        let canonical = canonical_request(&typed).unwrap();
        assert_eq!(canonical_request(&parse_request(&canonical).unwrap()).unwrap(), canonical);
        cases.push(json!({"name":format!("cleanup-request-{}",cases.len()),"kind":"request","value":wire,"valid":true}));
        for cleanup in [None, Some(false), Some(true)] {
            let mut run = observation();
            if cleanup == Some(true) {
                run["process"] = json!("exited"); run["evidence"] = json!("process_exit");
                run["work"] = json!("succeeded"); run["exit_code"] = json!(0);
            }
            let mut data = json!({"run":run});
            if let Some(value) = cleanup { data["cleanup_complete"] = json!(value); }
            let value = response("run.get", data);
            let matches = wire["params"].get("include_cleanup").is_some() == cleanup.is_some();
            assert_eq!(parse_response(&typed, &bytes(&value)).is_ok(), matches, "shape correlation: {value}");
            cases.push(json!({"name":format!("cleanup-response-{}",cases.len()),"kind":"response","value":value,"valid":true}));
        }
    }
    for flag in [Value::Null,json!(false),json!(0),json!("true"),json!([]),json!({})] {
        let value = request("run.get",json!({"run_id":RUN,"include_cleanup":flag}));
        assert!(parse_request(&bytes(&value)).is_err());
        cases.push(json!({"name":format!("cleanup-invalid-{}",cases.len()),"kind":"request","value":value,"valid":false}));
    }
    let new = parse_request(&bytes(&request("run.get",json!({"run_id":RUN,"include_cleanup":true})))).unwrap();
    for flag in [Value::Null,json!(0),json!("true"),json!([]),json!({}),json!(true)] {
        let value = response("run.get",json!({"run":observation(),"cleanup_complete":flag}));
        assert!(parse_response(&new,&bytes(&value)).is_err());
        cases.push(json!({"name":format!("cleanup-invalid-response-{}",cases.len()),"kind":"response","value":value,"valid":false}));
    }
    let good = request("run.get",json!({"run_id":RUN,"include_cleanup":true}));
    let raw = String::from_utf8(bytes(&good)).unwrap().replace("\"include_cleanup\":true", "\"include_cleanup\":true,\"include_cleanup\":true");
    assert!(parse_request(raw.as_bytes()).is_err());
    let good = response("run.get",json!({"run":observation(),"cleanup_complete":false}));
    let raw = String::from_utf8(bytes(&good)).unwrap().replace("\"cleanup_complete\":false", "\"cleanup_complete\":false,\"cleanup_complete\":false");
    assert!(parse_response(&new,raw.as_bytes()).is_err());
    let mut foreign = good.clone(); foreign["result"]["data"]["run"]["run_id"] = json!(OTHER);
    assert!(parse_response(&new,&bytes(&foreign)).is_err());
    for field in ["unknown","include_cleanup"] {
        let mut value = good.clone(); value["result"]["data"][field] = json!(true);
        assert!(parse_response(&new,&bytes(&value)).is_err());
    }
    let result = python(SCHEMA_CHECK, &json!({"schemas":projection::schemas(),"cases":cases}));
    assert_eq!(result["checked"],cases.len());
    assert_eq!(result["failures"],json!([]),"{result}");
}
