use serde_json::{json, Value};
use std::io::{BufReader, Cursor};
use winsmux_workspace::contract::{parse_response, ErrorCode, MAX_MESSAGE_BYTES};
use winsmux_workspace_mcp::stdio::{read_line, LineError};
use winsmux_workspace_mcp::{Effect, Session, MAX_MCP_MESSAGE_BYTES, PROTOCOL_VERSION, TOOL_NAME};

const INSTANCE: &str = "10000000-0000-4000-8000-000000000000";
const OPERATION: &str = "20000000-0000-4000-8000-000000000000";

fn request() -> Value {
    json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OPERATION,
        "expected_topology_revision":null,"operation":"capabilities.get","params":{}})
}

fn message(id: Value, method: &str, params: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})).unwrap()
}

fn notification(method: &str, params: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"jsonrpc":"2.0","method":method,"params":params})).unwrap()
}

fn reply(effect: Effect) -> Value {
    let Effect::Reply(line) = effect else {
        panic!("expected immediate JSON-RPC reply")
    };
    serde_json::from_slice(&line).unwrap()
}

fn first_difference(left: &Value, right: &Value, path: &str) -> Option<String> {
    if left == right {
        return None;
    }
    match (left, right) {
        (Value::Object(a), Value::Object(b)) => {
            for key in a.keys().chain(b.keys()) {
                if let Some(found) = first_difference(
                    a.get(key).unwrap_or(&Value::Null),
                    b.get(key).unwrap_or(&Value::Null),
                    &format!("{path}/{key}"),
                ) {
                    return Some(found);
                }
            }
            None
        }
        (Value::Array(a), Value::Array(b)) => {
            for index in 0..a.len().max(b.len()) {
                if let Some(found) = first_difference(
                    a.get(index).unwrap_or(&Value::Null),
                    b.get(index).unwrap_or(&Value::Null),
                    &format!("{path}/{index}"),
                ) {
                    return Some(found);
                }
            }
            None
        }
        _ => Some(format!("{path}: {left:?} != {right:?}")),
    }
}

fn initialized(session: &mut Session) {
    let result = reply(session.on_line(&message(
        json!(1),
        "initialize",
        json!({"protocolVersion":"2024-11-05","capabilities":{},
            "clientInfo":{"name":"test","version":"1"}}),
    )));
    assert_eq!(result["result"]["protocolVersion"], PROTOCOL_VERSION);
    assert!(matches!(
        session.on_line(&notification("notifications/initialized", json!({}))),
        Effect::None
    ));
}

fn call(session: &mut Session, id: Value) -> Effect {
    session.on_line(&message(
        id,
        "tools/call",
        json!({"name":TOOL_NAME,"arguments":request()}),
    ))
}

#[test]
fn initialization_gate_version_and_schema_projection() {
    let mut s = Session::new();
    assert_eq!(
        reply(s.on_line(&message(json!(1), "ping", json!({}))))["result"],
        json!({})
    );
    assert_eq!(reply(call(&mut s, json!(2)))["error"]["code"], -32600);
    assert_eq!(
        reply(s.on_line(&message(json!(3), "tools/list", json!({}))))["error"]["code"],
        -32600
    );
    assert!(matches!(
        s.on_line(&notification("notifications/initialized", json!({}))),
        Effect::None
    ));
    let bad = message(json!(4), "initialize", json!({"protocolVersion":17}));
    assert_eq!(reply(s.on_line(&bad))["error"]["code"], -32602);
    let init = reply(s.on_line(&message(
        json!(5),
        "initialize",
        json!({
        "protocolVersion":"future-version","capabilities":{},
        "clientInfo":{"name":"client","version":"1"}}),
    )));
    assert_eq!(init["result"]["protocolVersion"], PROTOCOL_VERSION);
    assert_eq!(
        reply(s.on_line(&message(json!(6), "tools/list", json!({}))))["error"]["code"],
        -32600
    );
    assert_eq!(
        reply(s.on_line(&message(json!(7), "initialize", json!({}))))["error"]["code"],
        -32600
    );
    assert!(matches!(
        s.on_line(&notification("notifications/initialized", json!({}))),
        Effect::None
    ));
    let list = reply(s.on_line(&message(json!(8), "tools/list", json!({}))));
    let tools = list["result"]["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0]["name"], TOOL_NAME);
    let schemas = winsmux_workspace::contract::projection::schemas();
    assert_eq!(
        first_difference(&tools[0]["inputSchema"], &schemas["request"], "input"),
        None
    );
    assert_eq!(
        first_difference(&tools[0]["outputSchema"], &schemas["response"], "output"),
        None
    );
}

#[test]
fn strict_arguments_and_envelopes_send_nothing() {
    let mut s = Session::new();
    initialized(&mut s);
    for line in [
        br#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":{"schema_version":1,"schema_version":1}}}"#.to_vec(),
        br#"{"jsonrpc":"2.0","id":2,"id":3,"method":"tools/call"}"#.to_vec(),
        b"{".to_vec(),
        vec![0xff, 0xfe],
        vec![b' '; MAX_MCP_MESSAGE_BYTES + 1],
    ] {
        assert!(matches!(s.on_line(&line), Effect::Reply(_)));
    }
    let mut extra = request();
    extra["actor"] = json!("owner");
    assert_eq!(
        reply(s.on_line(&message(
            json!(3),
            "tools/call",
            json!({
        "name":TOOL_NAME,"arguments":extra})
        )))["error"]["code"],
        -32602
    );
    let mut schema = request();
    schema["schema_version"] = json!(2);
    assert_eq!(
        reply(s.on_line(&message(
            json!(4),
            "tools/call",
            json!({
        "name":TOOL_NAME,"arguments":schema})
        )))["error"]["code"],
        -32602
    );
    assert_eq!(
        reply(s.on_line(&message(
            json!(5),
            "tools/call",
            json!({
        "name":"other","arguments":request()})
        )))["error"]["code"],
        -32602
    );
    assert_eq!(
        reply(s.on_line(&message(json!(6), "unsupported", json!({}))))["error"]["code"],
        -32601
    );
    assert!(matches!(call(&mut s, json!(7)), Effect::StartCall { .. }));
}

#[test]
fn one_active_busy_duplicate_id_and_reuse_after_write() {
    let mut s = Session::new();
    initialized(&mut s);
    let Effect::StartCall { request, canonical } = call(&mut s, json!("same")) else {
        panic!()
    };
    assert_eq!(
        winsmux_workspace::contract::parse_request(&canonical).unwrap(),
        request
    );
    assert_eq!(reply(call(&mut s, json!(2)))["error"]["code"], -32000);
    assert_eq!(
        reply(s.on_line(&message(json!(3), "ping", json!({}))))["result"],
        json!({})
    );
    assert!(s.begin_send());
    let response = json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OPERATION,
        "accepted":false,"topology_revision":0,"event_seq":0,"result":null,
        "error":ErrorCode::PermissionDenied.with_target(None).unwrap()});
    let response = parse_response(&request, &serde_json::to_vec(&response).unwrap()).unwrap();
    assert!(matches!(s.complete(&response), Effect::PublishCall));
    let published: Value = serde_json::from_slice(s.pending_reply().unwrap()).unwrap();
    assert_eq!(published["id"], "same");
    assert_eq!(
        published["result"]["structuredContent"]["error"]["code"],
        "permission_denied"
    );
    assert_eq!(published["result"]["isError"], true);
    let content: Value =
        serde_json::from_str(published["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(content, published["result"]["structuredContent"]);
    assert!(s.mark_written());
    assert!(matches!(
        call(&mut s, json!("same")),
        Effect::StartCall { .. }
    ));
    assert!(matches!(
        call(&mut s, json!("same")),
        Effect::Close { cancel_host: false }
    ));
    assert!(s.is_closed());
    assert!(!s.begin_send());
}

#[test]
fn cancellation_before_and_after_send_never_replies_or_retries() {
    let mut s = Session::new();
    initialized(&mut s);
    assert!(matches!(call(&mut s, json!(2)), Effect::StartCall { .. }));
    assert!(matches!(
        s.on_line(&notification(
            "notifications/cancelled",
            json!({"requestId":2})
        )),
        Effect::None
    ));
    assert!(!s.begin_send());
    assert!(s.pending_reply().is_none());
    assert!(matches!(call(&mut s, json!(3)), Effect::StartCall { .. }));
    assert!(s.begin_send());
    assert!(matches!(
        s.on_line(&notification(
            "notifications/cancelled",
            json!({"requestId":99})
        )),
        Effect::None
    ));
    assert!(matches!(
        s.on_line(&notification(
            "notifications/cancelled",
            json!({"requestId":3})
        )),
        Effect::CancelHost
    ));
    assert!(s.connection_unknown());
    assert!(s.pending_reply().is_none());
    assert_eq!(
        reply(call(&mut s, json!(4)))["error"]["message"],
        "transport_uncertain"
    );
    assert!(matches!(
        s.on_line(&notification(
            "notifications/cancelled",
            json!({"requestId":3})
        )),
        Effect::None
    ));
}

#[test]
fn cancellation_race_and_host_loss_have_one_terminal_outcome() {
    let mut s = Session::new();
    initialized(&mut s);
    let Effect::StartCall { request, .. } = call(&mut s, json!(2)) else {
        panic!()
    };
    assert!(s.begin_send());
    let response = json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OPERATION,
        "accepted":false,"topology_revision":0,"event_seq":0,"result":null,
        "error":ErrorCode::PermissionDenied.with_target(None).unwrap()});
    let response = parse_response(&request, &serde_json::to_vec(&response).unwrap()).unwrap();
    assert!(matches!(s.complete(&response), Effect::PublishCall));
    assert!(matches!(
        s.on_line(&notification(
            "notifications/cancelled",
            json!({"requestId":2})
        )),
        Effect::CancelHost
    ));
    assert!(s.pending_reply().is_none());
    assert!(matches!(s.complete(&response), Effect::None));

    let mut s = Session::new();
    initialized(&mut s);
    assert!(matches!(call(&mut s, json!(2)), Effect::StartCall { .. }));
    assert!(s.begin_send());
    assert!(matches!(s.transport_lost(), Effect::PublishCall));
    let value: Value = serde_json::from_slice(s.pending_reply().unwrap()).unwrap();
    assert_eq!(value["error"]["code"], -32603);
    assert_eq!(value["error"]["message"], "transport_uncertain");
    assert!(s.mark_written());
    assert!(matches!(s.transport_lost(), Effect::None));
    assert_eq!(reply(call(&mut s, json!(3)))["error"]["code"], -32603);
}

#[test]
fn accepted_host_response_is_preserved_and_written_once() {
    let mut s = Session::new();
    initialized(&mut s);
    let arguments = json!({"schema_version":1,"instance_id":null,"operation_id":OPERATION,
        "expected_topology_revision":null,"operation":"connection.request",
        "params":{"project_ids":["30000000-0000-4000-8000-000000000000"],
            "scopes":["metadata"]}});
    let Effect::StartCall { request, .. } = s.on_line(&message(
        json!("call"),
        "tools/call",
        json!({"name":TOOL_NAME,"arguments":arguments}),
    )) else {
        panic!()
    };
    assert!(s.begin_send());
    let original = json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OPERATION,
        "accepted":true,"topology_revision":7,"event_seq":9,
        "result":{"operation":"connection.request","data":{
            "connection_id":"60000000-0000-4000-8000-000000000000","state":"pending"}},
        "error":null});
    let response = parse_response(&request, &serde_json::to_vec(&original).unwrap()).unwrap();
    assert!(matches!(s.complete(&response), Effect::PublishCall));
    let line: Value = serde_json::from_slice(s.pending_reply().unwrap()).unwrap();
    assert_eq!(line["result"]["structuredContent"], original);
    assert_eq!(line["result"]["isError"], false);
    assert_eq!(
        serde_json::from_str::<Value>(line["result"]["content"][0]["text"].as_str().unwrap())
            .unwrap(),
        original
    );
    assert!(s.mark_written());
    assert!(!s.mark_written());
    assert!(matches!(
        s.on_line(&notification(
            "notifications/cancelled",
            json!({"requestId":"call"})
        )),
        Effect::None
    ));
    assert!(!s.connection_unknown());
}

fn maximum_request() -> Value {
    let mut value = request();
    value["operation"] = json!("input.write");
    value["params"] = json!({
        "pane_id":"40000000-0000-4000-8000-000000000000",
        "run_id":"50000000-0000-4000-8000-000000000000",
        "text":""
    });
    let base_len = serde_json::to_vec(&value).unwrap().len();
    value["params"]["text"] = json!("a".repeat(MAX_MESSAGE_BYTES - base_len));
    assert_eq!(serde_json::to_vec(&value).unwrap().len(), MAX_MESSAGE_BYTES);
    value
}

#[test]
fn exact_inner_limit_and_outer_plus_one_preserve_zero_send_boundary() {
    let mut s = Session::new();
    initialized(&mut s);
    let valid = maximum_request();
    let envelope = message(
        json!(2),
        "tools/call",
        json!({"name":TOOL_NAME,"arguments":valid.clone()}),
    );
    assert!(envelope.len() > MAX_MESSAGE_BYTES);
    assert!(envelope.len() <= MAX_MCP_MESSAGE_BYTES);
    let Effect::StartCall { request, canonical } = s.on_line(&envelope) else {
        panic!("valid limit request refused")
    };
    assert_eq!(canonical.len(), MAX_MESSAGE_BYTES);
    assert_eq!(
        winsmux_workspace::contract::parse_request(&canonical).unwrap(),
        request
    );
    assert!(s.begin_send());
    let refused = json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OPERATION,
        "accepted":false,"topology_revision":0,"event_seq":0,"result":null,
        "error":ErrorCode::PermissionDenied.with_target(None).unwrap()});
    let response = parse_response(&request, &serde_json::to_vec(&refused).unwrap()).unwrap();
    assert!(matches!(s.complete(&response), Effect::PublishCall));
    assert!(s.mark_written());

    let mut oversize_inner = valid;
    let extended = format!("{}a", oversize_inner["params"]["text"].as_str().unwrap());
    oversize_inner["params"]["text"] = json!(extended);
    assert_eq!(
        serde_json::to_vec(&oversize_inner).unwrap().len(),
        MAX_MESSAGE_BYTES + 1
    );
    assert_eq!(
        reply(s.on_line(&message(
            json!(3),
            "tools/call",
            json!({
        "name":TOOL_NAME,"arguments":oversize_inner})
        )))["error"]["code"],
        -32602
    );
    assert!(matches!(
        s.on_line(&vec![b' '; MAX_MCP_MESSAGE_BYTES + 1]),
        Effect::Reply(_)
    ));
    assert!(!s.connection_unknown());
}

#[test]
fn bounded_reader_keeps_split_japanese_utf8_and_rejects_bad_final_lines() {
    let mut argument = request();
    argument["operation"] = json!("input.write");
    argument["params"] = json!({"pane_id":"40000000-0000-4000-8000-000000000000",
        "run_id":"50000000-0000-4000-8000-000000000000","text":"日本語"});
    let envelope = message(
        json!(2),
        "tools/call",
        json!({"name":TOOL_NAME,"arguments":argument}),
    );
    let mut wire = envelope.clone();
    wire.extend_from_slice(b"\r\n");
    let mut reader = BufReader::with_capacity(1, Cursor::new(wire));
    let read = read_line(&mut reader).unwrap().unwrap();
    assert_eq!(read, envelope);
    assert_eq!(read_line(&mut reader).unwrap(), None);
    let mut s = Session::new();
    initialized(&mut s);
    let Effect::StartCall { request, canonical } = s.on_line(&read) else {
        panic!()
    };
    assert!(s.begin_send());
    let refused = json!({"schema_version":1,"instance_id":INSTANCE,"operation_id":OPERATION,
        "accepted":false,"topology_revision":0,"event_seq":0,"result":null,
        "error":ErrorCode::PermissionDenied.with_target(None).unwrap()});
    let response = parse_response(&request, &serde_json::to_vec(&refused).unwrap()).unwrap();
    assert!(matches!(s.complete(&response), Effect::PublishCall));
    assert_eq!(
        winsmux_workspace::contract::parse_request(&canonical).unwrap(),
        request
    );
    assert!(s.mark_written());

    for bytes in [vec![0xe6, 0x97, b'\n'], vec![0xff, b'\n']] {
        let mut bad = BufReader::with_capacity(1, Cursor::new(bytes));
        assert_eq!(read_line(&mut bad), Err(LineError::InvalidUtf8));
    }
    let mut incomplete = BufReader::with_capacity(1, Cursor::new(vec![0xe6, 0x97]));
    assert_eq!(read_line(&mut incomplete), Err(LineError::IncompleteLine));
    let mut too_large =
        BufReader::with_capacity(1024, Cursor::new(vec![b'a'; MAX_MCP_MESSAGE_BYTES + 1]));
    assert_eq!(read_line(&mut too_large), Err(LineError::TooLarge));
    let mut exact_wire = vec![b'a'; MAX_MCP_MESSAGE_BYTES];
    exact_wire.extend_from_slice(b"\r\n");
    let mut exact = BufReader::with_capacity(1024, Cursor::new(exact_wire));
    assert_eq!(
        read_line(&mut exact).unwrap().unwrap().len(),
        MAX_MCP_MESSAGE_BYTES
    );
}
