//! Strict, transport-independent half of the workspace MCP stdio adapter.
//!
//! The authenticated public client owns pipe identity, host proof, cancellation
//! and frame I/O. This module never grants authority or interprets host results.

use serde::de::{Error as _, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::value::RawValue;
use serde_json::{json, Map, Value};
use winsmux_workspace::contract::{
    canonical_request, parse_request, projection, serialize_response, Request, Response,
    MAX_MESSAGE_BYTES,
};

pub mod stdio;
pub mod runtime;
#[cfg(all(windows, debug_assertions))]
pub mod testing { pub use crate::runtime::testing::*; }

pub const PROTOCOL_VERSION: &str = "2025-11-25";
pub const TOOL_NAME: &str = "winsmux_workspace_request";
pub const MAX_MCP_MESSAGE_BYTES: usize = 2 * MAX_MESSAGE_BYTES;

/// A caller must serialize all state-machine calls and stdout writes on one
/// thread. `StartCall` is the only path permitted to send a host frame.
#[derive(Debug)]
pub enum Effect {
    Reply(Vec<u8>),
    StartCall {
        request: Request,
        canonical: Vec<u8>,
    },
    PublishCall,
    CancelHost,
    Close {
        cancel_host: bool,
    },
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    AwaitInitialize,
    AwaitInitialized,
    Operational,
}

#[derive(Debug)]
enum CallPhase {
    Validated,
    Sent,
    Correlated(Vec<u8>),
    Publishing(Vec<u8>),
}

#[derive(Debug, Clone)]
pub struct CallTicket(std::sync::Arc<()>);
impl PartialEq for CallTicket { fn eq(&self, other: &Self) -> bool { std::sync::Arc::ptr_eq(&self.0, &other.0) } }
impl Eq for CallTicket {}

#[derive(Debug, Clone)]
pub(crate) struct ReceiptState {
    ticket: Option<CallTicket>,
    publishing: bool,
    initialized_allowed: bool,
}

#[derive(Debug)]
struct Active {
    ticket: CallTicket,
    id: Value,
    request: Request,
    phase: CallPhase,
}

#[derive(Debug)]
pub struct Session {
    phase: Phase,
    active: Option<Active>,
    connection_unknown: bool,
    closed: bool,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            phase: Phase::AwaitInitialize,
            active: None,
            connection_unknown: false,
            closed: false,
        }
    }
}

impl Session {
    pub(crate) fn receipt_state(&self) -> ReceiptState {
        ReceiptState { ticket: self.active.as_ref().map(|a| a.ticket.clone()),
            publishing: self.active.as_ref().is_some_and(|a| matches!(a.phase, CallPhase::Publishing(_))),
            initialized_allowed: self.phase == Phase::AwaitInitialized }
    }

    pub(crate) fn on_receipt(&mut self, line: &[u8], receipt: ReceiptState) -> Effect {
        self.on_admitted_receipt(admit_input(line), receipt)
    }

    pub(crate) fn on_admitted_receipt(&mut self, input: ClassifiedInput, receipt: ReceiptState) -> Effect {
        if self.closed { return Effect::None; }
        let envelope = match input {
            ClassifiedInput::IgnoredCancellation => return Effect::None,
            ClassifiedInput::InvalidRequest => return Effect::Reply(error(Value::Null, -32600, "invalid_request")),
            ClassifiedInput::Cancellation { request_id } => {
                if receipt.publishing || receipt.ticket != self.active_ticket() { return Effect::None; }
                return self.cancel_call(&request_id);
            }
            ClassifiedInput::Envelope(envelope) => envelope,
        };
        if envelope.id.is_none() && envelope.method.as_deref() == Some("notifications/initialized")
            && !receipt.initialized_allowed { return Effect::None; }
        if envelope.id.is_some() && envelope.method.as_deref() == Some("tools/call")
            && receipt.ticket.is_some() && self.active.is_none() {
            return Effect::Reply(error(envelope.id.expect("present"), -32000, "busy"));
        }
        self.on_envelope(envelope)
    }

    pub fn active_ticket(&self) -> Option<CallTicket> { self.active.as_ref().map(|a| a.ticket.clone()) }
    pub(crate) fn accepts_outcome(&self,ticket:&CallTicket)->bool {
        !self.closed && self.active.as_ref().is_some_and(|a| &a.ticket==ticket && matches!(a.phase,CallPhase::Sent))
    }
    pub(crate) fn active_id(&self) -> Option<&Value> { self.active.as_ref().map(|a| &a.id) }
    pub fn begin_send_ticket(&mut self, ticket: &CallTicket) -> bool {
        self.active.as_ref().is_some_and(|a| &a.ticket == ticket) && self.begin_send()
    }
    pub fn complete_ticket(&mut self, ticket: &CallTicket, response: &Response) -> Effect {
        if !self.active.as_ref().is_some_and(|a| &a.ticket == ticket) { return Effect::None; }
        self.complete(response)
    }
    pub fn transport_lost_ticket(&mut self, ticket: &CallTicket) -> Effect {
        if !self.active.as_ref().is_some_and(|a| &a.ticket == ticket) { return Effect::None; }
        self.transport_lost()
    }
    pub fn protocol_failed_ticket(&mut self, ticket: &CallTicket) -> Effect {
        let Some(active) = self.active.as_mut().filter(|a| &a.ticket == ticket) else { return Effect::None; };
        active.phase = CallPhase::Correlated(error(active.id.clone(), -32603, "protocol_failed"));
        Effect::PublishCall
    }
    pub fn claim_reply(&mut self, ticket: &CallTicket) -> Option<Vec<u8>> {
        let active = self.active.as_mut().filter(|a| &a.ticket == ticket)?;
        let CallPhase::Correlated(line) = &active.phase else { return None; };
        let line = line.clone();
        active.phase = CallPhase::Publishing(line.clone());
        Some(line)
    }
    pub fn mark_written_ticket(&mut self, ticket: &CallTicket) -> bool {
        if !self.active.as_ref().is_some_and(|a| &a.ticket == ticket) { return false; }
        self.mark_written()
    }
    pub fn new() -> Self {
        Self::default()
    }

    pub fn connection_unknown(&self) -> bool {
        self.connection_unknown
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// Processes one complete newline-delimited JSON-RPC message. The caller
    /// strips CRLF and applies the outer byte cap while reading, before buffering
    /// another line. All returned replies are single JSON values without LF.
    pub fn on_line(&mut self, line: &[u8]) -> Effect {
        self.on_receipt(line, self.receipt_state())
    }

    fn on_envelope(&mut self, envelope: Envelope) -> Effect {
        let id = envelope.id;
        if let (Some(id), Some(active)) = (&id, &self.active) {
            if *id == active.id {
                let cancel_host = !matches!(active.phase, CallPhase::Validated);
                self.active = None;
                self.connection_unknown = true;
                self.closed = true;
                return Effect::Close { cancel_host };
            }
        }
        let Some(method) = envelope.method else {
            return Effect::Reply(error(id.unwrap_or(Value::Null), -32600, "invalid_request"));
        };
        if id.is_none() {
            return self.notification(&method, envelope.params.as_deref());
        }
        let id = id.expect("checked");
        match method.as_str() {
            "ping" => Effect::Reply(success(id, json!({}))),
            "initialize" => self.initialize(id, envelope.params.as_deref()),
            "tools/list" => {
                if self.phase != Phase::Operational {
                    return Effect::Reply(error(id, -32600, "not_initialized"));
                }
                let schemas = projection::schemas();
                Effect::Reply(success(
                    id,
                    json!({"tools":[{"name":TOOL_NAME,
                        "inputSchema":schemas["request"],
                        "outputSchema":schemas["response"]}]}),
                ))
            }
            "tools/call" => self.call(id, envelope.params.as_deref()),
            _ => Effect::Reply(error(id, -32601, "method_not_found")),
        }
    }

    fn notification(&mut self, method: &str, _params: Option<&RawValue>) -> Effect {
        match method {
            "notifications/initialized" => {
                if self.phase == Phase::AwaitInitialized {
                    self.phase = Phase::Operational;
                }
                Effect::None
            }
            _ => Effect::None,
        }
    }

    fn cancel_call(&mut self, id: &Value) -> Effect {
        if self.active.as_ref().map(|active| &active.id) != Some(id) { return Effect::None; }
        let active = self.active.take().expect("validated matching cancellation");
        match active.phase {
            CallPhase::Validated => Effect::None,
            CallPhase::Sent | CallPhase::Correlated(_) => {
                self.connection_unknown = true;
                Effect::CancelHost
            }
            CallPhase::Publishing(_) => { self.active = Some(active); Effect::None }
        }
    }

    fn initialize(&mut self, id: Value, params: Option<&RawValue>) -> Effect {
        if self.phase != Phase::AwaitInitialize {
            return Effect::Reply(error(id, -32600, "already_initialized"));
        }
        let valid = params
            .and_then(|p| serde_json::from_str::<Value>(p.get()).ok())
            .and_then(|p| {
                let obj = p.as_object()?;
                obj.get("protocolVersion")?.as_str()?;
                obj.get("capabilities")?.as_object()?;
                let info = obj.get("clientInfo")?.as_object()?;
                info.get("name")?.as_str()?;
                info.get("version")?.as_str()?;
                Some(())
            })
            .is_some();
        if !valid {
            return Effect::Reply(error(id, -32602, "invalid_params"));
        }
        self.phase = Phase::AwaitInitialized;
        Effect::Reply(success(
            id,
            json!({"protocolVersion":PROTOCOL_VERSION,
                "capabilities":{"tools":{}},
                "serverInfo":{"name":"winsmux-workspace-mcp","version":"0.38.0"}}),
        ))
    }

    fn call(&mut self, id: Value, params: Option<&RawValue>) -> Effect {
        if self.phase != Phase::Operational {
            return Effect::Reply(error(id, -32600, "not_initialized"));
        }
        if self.connection_unknown {
            return Effect::Reply(error(id, -32603, "transport_uncertain"));
        }
        if self.active.is_some() {
            return Effect::Reply(error(id, -32000, "busy"));
        }
        let Some(params) = params else {
            return Effect::Reply(error(id, -32602, "invalid_params"));
        };
        let Ok(params) = serde_json::from_str::<CallParams>(params.get()) else {
            return Effect::Reply(error(id, -32602, "invalid_params"));
        };
        if params.name != TOOL_NAME {
            return Effect::Reply(error(id, -32602, "unknown_tool"));
        }
        let request = match parse_request(params.arguments.get().as_bytes()) {
            Ok(request) => request,
            Err(_) => return Effect::Reply(error(id, -32602, "invalid_request_arguments")),
        };
        let canonical = match canonical_request(&request) {
            Ok(bytes) => bytes,
            Err(_) => return Effect::Reply(error(id, -32602, "invalid_request_arguments")),
        };
        self.active = Some(Active {
            ticket: CallTicket(std::sync::Arc::new(())),
            id,
            request: request.clone(),
            phase: CallPhase::Validated,
        });
        Effect::StartCall { request, canonical }
    }

    /// Called immediately before handing the canonical bytes to the public
    /// client. A false result forbids the send (the call was canceled).
    pub fn begin_send(&mut self) -> bool {
        let Some(active) = self.active.as_mut() else {
            return false;
        };
        if !matches!(active.phase, CallPhase::Validated) || self.connection_unknown {
            return false;
        }
        active.phase = CallPhase::Sent;
        true
    }

    /// The public client must already have correlated its response to the
    /// canonical request. This second check prevents adapter conversion from
    /// changing the host's response or accepting a mismatched response.
    pub fn complete(&mut self, response: &Response) -> Effect {
        let Some(active) = self.active.as_mut() else {
            return Effect::None;
        };
        if !matches!(active.phase, CallPhase::Sent) {
            return Effect::None;
        }
        let Ok(bytes) = serialize_response(&active.request, response) else {
            return self.transport_lost();
        };
        let Ok(structured): Result<Value, _> = serde_json::from_slice(&bytes) else {
            return self.transport_lost();
        };
        let line = success(
            active.id.clone(),
            json!({"structuredContent":structured,
                "content":[{"type":"text","text":String::from_utf8(bytes).expect("JSON UTF-8")}],
                "isError":!response.accepted}),
        );
        active.phase = CallPhase::Correlated(line);
        Effect::PublishCall
    }

    /// Host loss or uncertain frame I/O is terminal for this connection.
    pub fn transport_lost(&mut self) -> Effect {
        self.connection_unknown = true;
        let Some(active) = self.active.as_mut() else {
            return Effect::None;
        };
        if !matches!(active.phase, CallPhase::Sent) {
            return Effect::None;
        }
        active.phase =
            CallPhase::Correlated(error(active.id.clone(), -32603, "transport_uncertain"));
        Effect::PublishCall
    }

    /// The caller writes this line synchronously, then calls `mark_written` only
    /// after stdout reports success. Cancellation processed first clears it.
    pub fn pending_reply(&self) -> Option<&[u8]> {
        match self.active.as_ref().map(|a| &a.phase) {
            Some(CallPhase::Correlated(line) | CallPhase::Publishing(line)) => Some(line),
            _ => None,
        }
    }

    pub fn mark_written(&mut self) -> bool {
        if self.pending_reply().is_none() {
            return false;
        }
        self.active = None;
        true
    }

    pub fn close(&mut self) -> Effect {
        if self.closed {
            return Effect::None;
        }
        self.closed = true;
        let cancel_host = self
            .active
            .as_ref()
            .is_some_and(|a| !matches!(a.phase, CallPhase::Validated));
        self.active = None;
        Effect::Close { cancel_host }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CallParams {
    name: String,
    arguments: Box<RawValue>,
}

pub(crate) struct Envelope {
    id: Option<Value>,
    method: Option<String>,
    params: Option<Box<RawValue>>,
}

/// The only input admission used by direct sessions and native receipts.
/// Ignored cancellation never contains a request ID or a state-changing effect.
pub(crate) enum ClassifiedInput {
    Envelope(Envelope),
    Cancellation { request_id: Value },
    IgnoredCancellation,
    InvalidRequest,
}
impl ClassifiedInput {
    pub(crate) fn id(&self) -> Option<Value> {
        if let Self::Envelope(envelope) = self { envelope.id.clone() } else { None }
    }
    pub(crate) fn is_notification(&self) -> bool {
        match self {
            Self::Cancellation { .. } | Self::IgnoredCancellation => true,
            Self::Envelope(envelope) => envelope.id.is_none() && envelope.method.is_some(),
            Self::InvalidRequest => false,
        }
    }
}

// Inspect only routing provenance without losing duplicate field occurrences.
// This does not admit an envelope: strict recursive validation follows it.
#[derive(Default)]
struct RawRouting {
    jsonrpc_fields: usize,
    method_fields: usize,
    jsonrpc: Option<String>,
    method: Option<String>,
    id_fields: usize,
}
impl<'de> Deserialize<'de> for RawRouting {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct RoutingVisitor;
        impl<'de> Visitor<'de> for RoutingVisitor {
            type Value = RawRouting;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result { f.write_str("JSON-RPC object") }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<RawRouting, A::Error> {
                let mut routing = RawRouting::default();
                while let Some(key) = map.next_key::<String>()? {
                    let raw = map.next_value::<Box<RawValue>>()?;
                    match key.as_str() {
                        "jsonrpc" => {
                            routing.jsonrpc_fields += 1;
                            if routing.jsonrpc_fields == 1 { routing.jsonrpc = serde_json::from_str(raw.get()).ok(); }
                        }
                        "method" => {
                            routing.method_fields += 1;
                            if routing.method_fields == 1 { routing.method = serde_json::from_str(raw.get()).ok(); }
                        }
                        "id" => routing.id_fields += 1,
                        _ => (),
                    }
                }
                Ok(routing)
            }
        }
        deserializer.deserialize_map(RoutingVisitor)
    }
}

pub(crate) fn admit_input(line: &[u8]) -> ClassifiedInput {
    if line.len() > MAX_MCP_MESSAGE_BYTES || line.starts_with(&[0xef, 0xbb, 0xbf]) { return ClassifiedInput::InvalidRequest; }
    let mut decoder = serde_json::Deserializer::from_slice(line);
    let Ok(routing) = RawRouting::deserialize(&mut decoder) else { return ClassifiedInput::InvalidRequest; };
    if decoder.end().is_err() { return ClassifiedInput::InvalidRequest; }
    let known_cancellation = routing.id_fields == 0 && routing.jsonrpc_fields == 1 && routing.method_fields == 1
        && routing.jsonrpc.as_deref() == Some("2.0")
        && routing.method.as_deref() == Some("notifications/cancelled");
    let envelope = match decode_envelope(line) {
        Ok(envelope) => envelope,
        Err(()) => return if known_cancellation { ClassifiedInput::IgnoredCancellation } else { ClassifiedInput::InvalidRequest },
    };
    if !known_cancellation { return ClassifiedInput::Envelope(envelope); }
    let Some(raw) = envelope.params else { return ClassifiedInput::IgnoredCancellation; };
    // decode_envelope already rejected every nested duplicate before this Value.
    let Ok(Value::Object(params)) = serde_json::from_str::<Value>(raw.get()) else { return ClassifiedInput::IgnoredCancellation; };
    let Some(request_id) = params.get("requestId").filter(|id| valid_id(id)) else { return ClassifiedInput::IgnoredCancellation; };
    if params.get("reason").is_some_and(|reason| !reason.is_string())
        || params.get("_meta").is_some_and(|meta| !meta.is_object()) { return ClassifiedInput::IgnoredCancellation; }
    // Notification.params extensions are compatible and do not grant authority.
    ClassifiedInput::Cancellation { request_id: request_id.clone() }
}

#[derive(Deserialize)]
struct RawEnvelope {
    params: Option<Box<RawValue>>,
}

pub(crate) fn decode_envelope(line: &[u8]) -> Result<Envelope, ()> {
    if line.len() > MAX_MCP_MESSAGE_BYTES || line.starts_with(&[0xef, 0xbb, 0xbf]) {
        return Err(());
    }
    let mut deserializer = serde_json::Deserializer::from_slice(line);
    let Unique(value) = Unique::deserialize(&mut deserializer).map_err(|_| ())?;
    deserializer.end().map_err(|_| ())?;
    let object = value.as_object().ok_or(())?;
    if object.keys().any(|key| !matches!(key.as_str(), "jsonrpc" | "id" | "method" | "params")) { return Err(()); }
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Err(());
    }
    let id = object.get("id").cloned();
    if id.as_ref().is_some_and(|v| !valid_id(v)) {
        return Err(());
    }
    let method = object
        .get("method")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let raw: RawEnvelope = serde_json::from_slice(line).map_err(|_| ())?;
    Ok(Envelope {
        id,
        method,
        params: raw.params,
    })
}

/// Discovery is parsed without a lossy Value round trip so duplicate keys fail.
pub fn parse_discovery(bytes: &[u8]) -> Result<winsmux_workspace::host::Discovery, ()> {
    if bytes.len() > MAX_MCP_MESSAGE_BYTES || bytes.starts_with(&[0xef,0xbb,0xbf]) { return Err(()); }
    let mut decoder = serde_json::Deserializer::from_slice(bytes);
    Unique::deserialize(&mut decoder).map_err(|_| ())?;
    decoder.end().map_err(|_| ())?;
    serde_json::from_slice(bytes).map_err(|_| ())
}

fn valid_id(id: &Value) -> bool {
    id.is_string() || id.as_i64().is_some() || id.as_u64().is_some()
}

fn success(id: Value, result: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"result":result})).expect("JSON")
}

fn error(id: Value, code: i32, message: &'static str) -> Vec<u8> {
    serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,
        "error":{"code":code,"message":message}}))
    .expect("JSON")
}

// Reject every duplicate JSON key, including inside arguments and unrelated
// envelope extensions, before a lossy serde_json::Value map can hide it.
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct UniqueVisitor;
        impl<'de> Visitor<'de> for UniqueVisitor {
            type Value = Unique;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("JSON value")
            }
            fn visit_bool<E: serde::de::Error>(self, value: bool) -> Result<Unique, E> {
                Ok(Unique(Value::Bool(value)))
            }
            fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_f64<E: serde::de::Error>(self, value: f64) -> Result<Unique, E> {
                serde_json::Number::from_f64(value)
                    .map(|v| Unique(Value::Number(v)))
                    .ok_or_else(|| E::custom("invalid number"))
            }
            fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_string<E: serde::de::Error>(self, value: String) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(Unique(value)) = seq.next_element()? {
                    values.push(value);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Unique, A::Error> {
                let mut values = Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(A::Error::custom("duplicate key"));
                    }
                    values.insert(key, map.next_value::<Unique>()?.0);
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(UniqueVisitor)
    }
}

#[cfg(test)]
mod receipt_tests {
    use super::*;
    fn active(phase:CallPhase)->Active {
        let request=parse_request(br#"{"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":null,"operation":"capabilities.get","params":{}}"#).unwrap();
        Active{ticket:CallTicket(std::sync::Arc::new(())),id:json!(8),request,phase}
    }
    const CANCEL:&[u8]=br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8}}"#;
    #[test]
    fn captured_cancellation_obeys_every_call_phase() {
        for (phase,unknown,retained) in [(CallPhase::Validated,false,false),(CallPhase::Sent,true,false),
            (CallPhase::Correlated(vec![]),true,false),(CallPhase::Publishing(vec![]),false,true)] {
            let mut session=Session::new();session.phase=Phase::Operational;session.active=Some(active(phase));
            let receipt=session.receipt_state();session.on_receipt(CANCEL,receipt);
            assert_eq!(session.connection_unknown(),unknown);assert_eq!(session.active.is_some(),retained);
        }
    }
    #[test]
    fn captured_old_ticket_and_old_busy_receipt_cannot_admit_new_work() {
        let mut session=Session::new();session.phase=Phase::Operational;session.active=Some(active(CallPhase::Publishing(vec![])));
        let old=session.active_ticket().unwrap();let receipt=session.receipt_state();assert!(session.mark_written_ticket(&old));
        let call=br#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":{"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":null,"operation":"capabilities.get","params":{}}}}"#;
        let Effect::Reply(bytes)=session.on_receipt(call,receipt.clone()) else {panic!("captured Publishing call must stay busy")};
        let value:Value=serde_json::from_slice(&bytes).unwrap();assert_eq!(value["error"]["code"],-32000);assert!(session.active.is_none());
        session.active=Some(active(CallPhase::Validated));let new=session.active_ticket().unwrap();assert_ne!(old,new);
        session.on_receipt(CANCEL,receipt);assert_eq!(session.active_ticket(),Some(new.clone()));assert!(!session.connection_unknown());
        assert!(!session.begin_send_ticket(&old));assert!(!session.mark_written_ticket(&old));
        assert!(matches!(session.transport_lost_ticket(&old),Effect::None));assert!(matches!(session.protocol_failed_ticket(&old),Effect::None));
        assert_eq!(session.active_ticket(),Some(new.clone()));assert!(session.begin_send_ticket(&new));
    }
    #[test]
    fn initialized_receipt_requires_selected_negotiation_not_internal_write_marker() {
        let mut session=Session::new();let premature=session.receipt_state();session.phase=Phase::AwaitInitialized;
        let notification=br#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
        session.on_receipt(notification,premature);assert_eq!(session.phase,Phase::AwaitInitialized);
        let selected=session.receipt_state();session.on_receipt(notification,selected);assert_eq!(session.phase,Phase::Operational);
    }
}

#[cfg(test)]
mod notification_admission_tests {
    use super::*;

    fn active(phase: usize, id: Value) -> Active {
        let request = parse_request(br#"{"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":null,"operation":"capabilities.get","params":{}}"#).unwrap();
        let phase = match phase {
            0 => CallPhase::Validated, 1 => CallPhase::Sent,
            2 => CallPhase::Correlated(b"protected correlated bytes".to_vec()),
            3 => CallPhase::Publishing(b"protected publishing bytes".to_vec()), _ => unreachable!(),
        };
        Active { ticket: CallTicket(std::sync::Arc::new(())), id, request, phase }
    }
    fn session(phase: usize) -> Session {
        let mut session = Session::new(); session.phase = Phase::Operational;
        if phase < 4 { session.active = Some(active(phase, json!(8))); }
        if phase == 5 { session.closed = true; }
        session
    }
    fn cancellation(params: &str) -> Vec<u8> {
        format!(r#"{{"jsonrpc":"2.0","method":"notifications/cancelled","params":{params}}}"#).into_bytes()
    }
    pub(crate) fn malformed() -> Vec<Vec<u8>> {
        let mut rows = Vec::new();
        for reason in ["7", "true", "null", "[]", "{}"] {
            rows.push(cancellation(&format!(r#"{{"requestId":8,"reason":{reason}}}"#)));
        }
        for id in ["null", "true", "[]", "{}", "8.5"] {
            rows.push(cancellation(&format!(r#"{{"requestId":{id}}}"#)));
        }
        for params in ["null", "[]", "7", "true", r#""text""#, "{}"] { rows.push(cancellation(params)); }
        for meta in ["null", "[]", "7", "true", r#""text""#] {
            rows.push(cancellation(&format!(r#"{{"requestId":8,"_meta":{meta}}}"#)));
        }
        rows.push(br#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.to_vec());
        for params in [
            r#"{"requestId":8,"requestId":8}"#, r#"{"requestId":8,"reason":"a","reason":"b"}"#,
            r#"{"requestId":8,"_meta":{},"_meta":{}}"#, r#"{"requestId":8,"_meta":{"x":1,"x":2}}"#,
            r#"{"requestId":8,"extension":{"x":1,"x":2}}"#, r#"{"requestId":8,"extension":1,"extension":2}"#,
        ] { rows.push(cancellation(params)); }
        rows.push(br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8},"params":{"requestId":8}}"#.to_vec());
        rows.push(br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8},"extension":true}"#.to_vec());
        rows
    }
    pub(crate) fn legal() -> Vec<Vec<u8>> {
        [r#"{"requestId":8}"#, r#"{"requestId":8,"reason":""}"#,
            r#"{"requestId":8,"reason":"日本語"}"#, r#"{"requestId":8,"_meta":{}}"#,
            r#"{"requestId":8,"_meta":{"extension":[1,null,"value"]},"vendor-extension":{"nested":true}}"#,
        ].iter().map(|params| cancellation(params)).collect()
    }
    fn unchanged(session: &mut Session, line: &[u8], receipt: Option<ReceiptState>) {
        let before = format!("{session:?}"); let ticket = session.active_ticket();
        let pending = session.pending_reply().map(<[u8]>::to_vec);
        let effect = if let Some(receipt) = receipt { session.on_receipt(line, receipt) } else { session.on_line(line) };
        assert!(matches!(effect, Effect::None), "notification produced effect: {effect:?}; input={line:?}");
        assert_eq!(format!("{session:?}"), before); assert_eq!(session.active_ticket(), ticket);
        assert_eq!(session.pending_reply().map(<[u8]>::to_vec), pending);
    }
    #[test]
    fn malformed_cancellation_preserves_every_phase_and_receipt() {
        let rows = malformed(); assert_eq!(rows.len(), 30);
        for phase in 0..6 { for line in &rows { for origin in 0..4 {
            let mut target = session(phase);
            let receipt = match origin {
                0 => None,
                1 => Some(target.receipt_state()),
                2 => Some(session(1).receipt_state()),
                3 => Some(session(3).receipt_state()), _ => unreachable!(),
            };
            unchanged(&mut target, line, receipt);
            if phase == 0 { let ticket=target.active_ticket().unwrap(); assert!(target.begin_send_ticket(&ticket)); }
        } } }
        eprintln!("notification admission property: malformed30 x phases6 x raw/current/stale/publishing-receipt4 =720; exact session/ticket/permit/candidate preservation");
    }
    #[test]
    fn compatible_extensions_and_unknown_or_stale_cancellation_obey_ticket_ownership() {
        for phase in 0..6 {
            for params in [r#"{"requestId":9}"#, r#"{"requestId":"unknown","reason":"合法"}"#] {
                let mut target=session(phase); let receipt=target.receipt_state();
                unchanged(&mut target, &cancellation(params), Some(receipt));
            }
            for line in legal() {
                for origin in 0..3 {
                    let mut target=session(phase);
                    let receipt=match origin {0=>target.receipt_state(),1=>session(1).receipt_state(),2=>session(3).receipt_state(),_=>unreachable!()};
                    if origin!=0 || phase>=3 {unchanged(&mut target,&line,Some(receipt));continue;}
                    let effect=target.on_receipt(&line,receipt);
                    assert_eq!(target.active_ticket(),None);assert_eq!(target.connection_unknown(),phase!=0);
                    assert_eq!(matches!(effect,Effect::CancelHost),phase!=0);assert!(target.pending_reply().is_none());
                }
            }
        }
        let mut target=session(1);target.active.as_mut().unwrap().id=json!("call-string");
        let receipt=target.receipt_state();assert!(matches!(target.on_receipt(&cancellation(r#"{"requestId":"call-string","reason":"ok"}"#),receipt),Effect::CancelHost));
    }
    #[test]
    fn unclassifiable_routing_preserves_strict_request_errors_and_ordinary_siblings() {
        let invalid: &[&[u8]] = &[
            br#"{"method":"notifications/cancelled","params":{"requestId":8}}"#,
            br#"{"jsonrpc":"1.0","method":"notifications/cancelled","params":{"requestId":8}}"#,
            br#"{"jsonrpc":"2.0","jsonrpc":"2.0","method":"notifications/cancelled"}"#,
            br#"{"jsonrpc":"2.0","method":"notifications/cancelled","method":"notifications/cancelled"}"#,
            br#"{"jsonrpc":"2.0","method":"notifications/cancelled","method":"ping"}"#,
            br#"{"jsonrpc":"2.0","method":1,"params":"bar"}"#,
            br#"{"jsonrpc":"2.0","id":null,"method":"notifications/cancelled"}"#,
            br#"{"jsonrpc":"2.0","id":8,"id":8,"method":"notifications/cancelled"}"#,
            br#"{"jsonrpc":"2.0","method":"notifications/cancelled""#, b"[]", b"null",
        ];
        for phase in 0..5 { for line in invalid {
            let mut target=session(phase);let before=format!("{target:?}");let receipt=target.receipt_state();
            let Effect::Reply(reply)=target.on_receipt(line,receipt) else {panic!("unclassifiable routing must preserve error");};
            assert_eq!(serde_json::from_slice::<Value>(&reply).unwrap(),json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"invalid_request"}}));
            assert_eq!(format!("{target:?}"),before);
        } }
        let mut target=session(1);let before=format!("{target:?}");
        assert!(matches!(target.on_line(br#"{"jsonrpc":"2.0","method":"notifications/unknown"}"#),Effect::None));
        assert_eq!(format!("{target:?}"),before);
        let Effect::Reply(reply)=target.on_line(br#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#) else {panic!()};
        assert_eq!(serde_json::from_slice::<Value>(&reply).unwrap()["result"],json!({}));assert_eq!(format!("{target:?}"),before);
        let Effect::Reply(reply)=target.on_line(br#"{"jsonrpc":"2.0","id":9,"method":"notifications/cancelled","params":{"requestId":8}}"#) else {panic!()};
        assert_eq!(serde_json::from_slice::<Value>(&reply).unwrap()["error"]["code"],-32601);assert_eq!(format!("{target:?}"),before);
        assert!(matches!(target.on_line(br#"{"jsonrpc":"2.0","id":8,"method":"notifications/cancelled","params":{"requestId":8}}"#),Effect::Close{cancel_host:true}));
    }
}
