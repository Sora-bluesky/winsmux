//! Length-prefixed protocol for `winsmux-remote-helper`.

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

#[cfg(target_os = "linux")]
mod agent_adapter;
#[cfg(target_os = "linux")]
pub mod session;

/// Payload-byte ceiling. Pinned by `measured_max_payloads` to the largest
/// production encoding at the frozen legal field maxima. No extra margin.
pub const MAX_FRAME_LEN: u32 = 13_915;
pub const PROTOCOL_VERSION: u16 = 1;
pub const PREFIX_LEN: usize = 4;
pub const MAX_CLIENT_VERSION_BYTES: usize = 64;
pub const NONCE_LEN: usize = 32;
pub const NONCE_HEX_LEN: usize = NONCE_LEN * 2;
pub const MAX_CAPABILITY_LEN: usize = 32;
pub const MAX_CAPABILITIES: usize = 8;
pub const MAX_REJECT_DETAIL_BYTES: usize = 128;
pub const MAX_EXECUTABLE_BYTES: usize = 256;
pub const MAX_ARGV_COUNT: usize = 8;
pub const MAX_ARGV_ELEM_BYTES: usize = 256;
pub const MAX_SESSION_ID_HEX: usize = 32;
pub const MAX_PTY_IO_CHUNK: usize = 256;
pub const MAX_PTY_COLS: u16 = 512;
pub const MAX_PTY_ROWS: u16 = 512;
pub const SUPPORTED_CAPABILITIES: [&str; 4] = [
    "frame-v1",
    "pty-v1",
    "agent-path-v1",
    "session-lifecycle-v1",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentResolution {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub absolute_path: Option<String>,
    pub user_candidates: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Message {
    Hello {
        protocol_version: u16,
        client_version: String,
        nonce: String,
        capabilities: Vec<String>,
        peer_frame_limit: u32,
    },
    Welcome {
        protocol_version: u16,
        nonce: String,
        capabilities: Vec<String>,
        peer_frame_limit: u32,
    },
    Reject {
        code: RejectCode,
        detail: String,
    },
    #[serde(rename = "pty-start")]
    PtyStart {
        executable: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        resolution: Option<AgentResolution>,
        argv: Vec<String>,
        cols: u16,
        rows: u16,
    },
    #[serde(rename = "pty-started")]
    PtyStarted {
        session_id: String,
        child_pid: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        resolved_executable: Option<String>,
    },
    #[serde(rename = "pty-start-ack")]
    PtyStartAck {
        session_id: String,
    },
    #[serde(rename = "pty-exited")]
    PtyExited {
        session_id: String,
    },
    #[serde(rename = "pty-attach")]
    PtyAttach {
        session_id: String,
    },
    #[serde(rename = "pty-attached")]
    PtyAttached {
        session_id: String,
        child_pid: u32,
    },
    #[serde(rename = "pty-detach")]
    PtyDetach,
    #[serde(rename = "pty-detached")]
    PtyDetached,
    #[serde(rename = "pty-stop")]
    PtyStop {
        session_id: String,
    },
    #[serde(rename = "pty-stopped")]
    PtyStopped,
    #[serde(rename = "pty-input")]
    PtyInput {
        data_b64: String,
    },
    #[serde(rename = "pty-output")]
    PtyOutput {
        data_b64: String,
    },
    #[serde(rename = "pty-resize")]
    PtyResize {
        cols: u16,
        rows: u16,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectCode {
    VersionMismatch,
    UnknownType,
    Malformed,
    Oversized,
    PeerLimit,
    Unsupported,
    SessionNotFound,
    ControllerBusy,
    NotController,
    SpawnFailed,
}

#[derive(Debug)]
pub struct ProtocolError(pub Message);

impl Message {
    pub fn reject(code: RejectCode, detail: impl Into<String>) -> Self {
        Message::Reject {
            code,
            detail: truncate_detail(detail.into()),
        }
    }
}

pub fn encode_payload(message: &Message) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(message)
}

pub fn encode_frame(message: &Message) -> io::Result<Vec<u8>> {
    let payload = encode_payload(message)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if payload.len() > MAX_FRAME_LEN as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "encoded payload exceeds MAX_FRAME_LEN",
        ));
    }
    let mut frame = Vec::with_capacity(PREFIX_LEN + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

pub fn write_frame<W: Write>(writer: &mut W, message: &Message) -> io::Result<()> {
    writer.write_all(&encode_frame(message)?)?;
    writer.flush()
}

/// Read one frame. Oversized prefixes reject without reading or allocating the payload.
pub fn read_frame<R: Read>(reader: &mut R) -> io::Result<Result<Vec<u8>, Message>> {
    let mut prefix = [0u8; PREFIX_LEN];
    match reader.read_exact(&mut prefix) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
            return Err(error);
        }
        Err(error) => return Err(error),
    }
    let declared = u32::from_be_bytes(prefix);
    if declared > MAX_FRAME_LEN {
        return Ok(Err(Message::reject(
            RejectCode::Oversized,
            "frame payload larger than MAX_FRAME_LEN",
        )));
    }
    if declared == 0 {
        return Ok(Err(Message::reject(
            RejectCode::Malformed,
            "frame payload length is zero",
        )));
    }
    let mut payload = vec![0u8; declared as usize];
    if let Err(error) = reader.read_exact(&mut payload) {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            return Ok(Err(Message::reject(
                RejectCode::Malformed,
                "truncated frame payload",
            )));
        }
        return Err(error);
    }
    Ok(Ok(payload))
}

pub fn decode_payload(payload: &[u8]) -> Result<Message, Message> {
    let value: serde_json::Value = serde_json::from_slice(payload)
        .map_err(|_| Message::reject(RejectCode::Malformed, "payload is not JSON"))?;
    let Some(kind) = value.get("type").and_then(serde_json::Value::as_str) else {
        return Err(Message::reject(
            RejectCode::Malformed,
            "payload type is missing",
        ));
    };
    match kind {
        "hello" | "welcome" | "reject" | "pty-start" | "pty-started" | "pty-start-ack"
        | "pty-exited" | "pty-attach" | "pty-attached" | "pty-detach" | "pty-detached"
        | "pty-stop" | "pty-stopped" | "pty-input" | "pty-output" | "pty-resize" => {}
        _ => {
            return Err(Message::reject(
                RejectCode::UnknownType,
                format!("unknown type '{kind}'"),
            ));
        }
    }
    let message: Message = serde_json::from_value(value)
        .map_err(|_| Message::reject(RejectCode::Malformed, "payload fields are invalid"))?;
    validate_message(&message).map_err(|detail| Message::reject(RejectCode::Malformed, detail))?;
    Ok(message)
}

pub fn negotiate(hello: &Message) -> Message {
    let Message::Hello {
        protocol_version,
        client_version,
        nonce,
        capabilities,
        peer_frame_limit,
    } = hello
    else {
        return Message::reject(RejectCode::UnknownType, "first frame must be hello");
    };
    if *protocol_version != PROTOCOL_VERSION {
        return Message::reject(
            RejectCode::VersionMismatch,
            format!("unsupported protocol_version {protocol_version}"),
        );
    }
    if !client_version_is_legal(client_version) {
        return Message::reject(RejectCode::Malformed, "client_version is illegal");
    }
    if !nonce_is_legal(nonce) {
        return Message::reject(RejectCode::Malformed, "nonce must be 32-byte hex");
    }
    if capabilities.len() > MAX_CAPABILITIES
        || capabilities.iter().any(|item| {
            item.is_empty() || item.len() > MAX_CAPABILITY_LEN || !capability_is_legal(item)
        })
    {
        return Message::reject(RejectCode::Malformed, "capabilities are illegal");
    }
    let selected: Vec<String> = SUPPORTED_CAPABILITIES
        .iter()
        .filter(|supported| capabilities.iter().any(|item| item == *supported))
        .map(|item| (*item).to_string())
        .collect();
    let welcome = Message::Welcome {
        protocol_version: PROTOCOL_VERSION,
        nonce: nonce.clone(),
        capabilities: selected,
        peer_frame_limit: MAX_FRAME_LEN,
    };
    let welcome_len = encode_payload(&welcome)
        .map(|payload| payload.len() as u32)
        .unwrap_or(u32::MAX);
    if *peer_frame_limit < welcome_len {
        return Message::reject(
            RejectCode::PeerLimit,
            "peer_frame_limit cannot carry Welcome",
        );
    }
    welcome
}

pub fn respond_after_negotiation(payload: &[u8]) -> Message {
    match decode_payload(payload) {
        Ok(Message::Hello { .. }) => Message::reject(
            RejectCode::UnknownType,
            "hello is not accepted after Welcome",
        ),
        Ok(Message::Welcome { .. }) => Message::reject(
            RejectCode::UnknownType,
            "welcome is not accepted from the peer",
        ),
        Ok(Message::Reject { .. }) => Message::reject(
            RejectCode::UnknownType,
            "reject is not an accepted follow-on type",
        ),
        Ok(
            Message::PtyStart { .. }
            | Message::PtyStartAck { .. }
            | Message::PtyAttach { .. }
            | Message::PtyDetach
            | Message::PtyStop { .. }
            | Message::PtyInput { .. }
            | Message::PtyResize { .. },
        ) => Message::reject(
            RejectCode::Unsupported,
            "pty-v1 is supported only by the Linux broker",
        ),
        Ok(
            Message::PtyStarted { .. }
            | Message::PtyExited { .. }
            | Message::PtyAttached { .. }
            | Message::PtyDetached
            | Message::PtyStopped
            | Message::PtyOutput { .. },
        ) => Message::reject(
            RejectCode::UnknownType,
            "server-only message is not accepted from the peer",
        ),
        Err(reject) => reject,
    }
}

pub fn serve_stdio<R: Read, W: Write>(mut reader: R, mut writer: W) -> io::Result<()> {
    let first = match read_frame(&mut reader)? {
        Ok(payload) => payload,
        Err(reject) => {
            write_frame(&mut writer, &reject)?;
            return Ok(());
        }
    };
    let reply = match decode_payload(&first) {
        Ok(message) => negotiate(&message),
        Err(reject) => reject,
    };
    write_frame(&mut writer, &reply)?;
    if !matches!(reply, Message::Welcome { .. }) {
        return Ok(());
    }
    loop {
        match read_frame(&mut reader) {
            Ok(Ok(payload)) => {
                write_frame(&mut writer, &respond_after_negotiation(&payload))?;
            }
            Ok(Err(reject)) => {
                write_frame(&mut writer, &reject)?;
                if matches!(
                    reject,
                    Message::Reject {
                        code: RejectCode::Oversized,
                        ..
                    }
                ) {
                    return Ok(());
                }
            }
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error),
        }
    }
}

pub fn max_legal_hello() -> Message {
    Message::Hello {
        protocol_version: PROTOCOL_VERSION,
        client_version: "c".repeat(MAX_CLIENT_VERSION_BYTES),
        nonce: "ab".repeat(NONCE_LEN),
        capabilities: (0..MAX_CAPABILITIES)
            .map(|index| format!("{:0width$}", index, width = MAX_CAPABILITY_LEN))
            .collect(),
        peer_frame_limit: u32::MAX,
    }
}

pub fn max_legal_welcome() -> Message {
    Message::Welcome {
        protocol_version: PROTOCOL_VERSION,
        nonce: "cd".repeat(NONCE_LEN),
        capabilities: SUPPORTED_CAPABILITIES
            .iter()
            .map(|item| (*item).to_string())
            .collect(),
        peer_frame_limit: MAX_FRAME_LEN,
    }
}

pub fn max_legal_reject() -> Message {
    // Reject detail is deliberately truncated by bytes but otherwise may carry
    // JSON control characters originating in malformed peer input.
    Message::reject(
        RejectCode::Malformed,
        "\u{0001}".repeat(MAX_REJECT_DETAIL_BYTES),
    )
}

pub(crate) fn decode_base64(value: &str) -> Option<Vec<u8>> {
    if value.is_empty() || value.len() % 4 != 0 {
        return None;
    }
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(value.len() / 4 * 3);
    for (index, chunk) in bytes.chunks_exact(4).enumerate() {
        let last = index + 1 == bytes.len() / 4;
        let a = base64_value(chunk[0])?;
        let b = base64_value(chunk[1])?;
        decoded.push((a << 2) | (b >> 4));
        if chunk[2] == b'=' {
            if !last || chunk[3] != b'=' || b & 0x0f != 0 {
                return None;
            }
            continue;
        }
        let c = base64_value(chunk[2])?;
        decoded.push((b << 4) | (c >> 2));
        if chunk[3] == b'=' {
            if !last || c & 0x03 != 0 {
                return None;
            }
            continue;
        }
        let d = base64_value(chunk[3])?;
        decoded.push((c << 6) | d);
    }
    (encode_base64(&decoded) == value).then_some(decoded)
}

pub(crate) fn encode_base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied();
        let c = chunk.get(2).copied();
        encoded.push(TABLE[(a >> 2) as usize] as char);
        encoded.push(TABLE[(((a & 0x03) << 4) | b.unwrap_or(0) >> 4) as usize] as char);
        match b {
            Some(b) => {
                encoded.push(TABLE[(((b & 0x0f) << 2) | c.unwrap_or(0) >> 6) as usize] as char)
            }
            None => encoded.push('='),
        }
        match c {
            Some(c) => encoded.push(TABLE[(c & 0x3f) as usize] as char),
            None => encoded.push('='),
        }
    }
    encoded
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn validate_message(message: &Message) -> Result<(), &'static str> {
    match message {
        Message::PtyStart {
            executable,
            resolution,
            argv,
            cols,
            rows,
        } => {
            if executable.is_empty()
                || executable.len() > MAX_EXECUTABLE_BYTES
                || executable.as_bytes().contains(&0)
            {
                return Err("executable is illegal");
            }
            if argv.len() > MAX_ARGV_COUNT
                || argv.iter().any(|argument| {
                    argument.len() > MAX_ARGV_ELEM_BYTES || argument.as_bytes().contains(&0)
                })
            {
                return Err("argv is illegal");
            }
            if let Some(resolution) = resolution {
                if !matches!(executable.as_str(), "claude" | "codex") {
                    return Err("resolution executable is illegal");
                }
                if resolution
                    .absolute_path
                    .as_deref()
                    .is_some_and(|path| !unix_absolute_path_is_legal(path))
                    || resolution
                        .user_candidates
                        .iter()
                        .any(|path| !unix_absolute_path_is_legal(path))
                {
                    return Err("resolution path is illegal");
                }
                let combined_limit = if resolution.absolute_path.is_some() {
                    MAX_ARGV_COUNT - 1
                } else {
                    MAX_ARGV_COUNT
                };
                if argv
                    .len()
                    .checked_add(resolution.user_candidates.len())
                    .is_none_or(|count| count > combined_limit)
                {
                    return Err("resolution argv and candidates are illegal");
                }
            }
            dimensions_are_legal(*cols, *rows)?;
        }
        Message::PtyStarted {
            session_id,
            child_pid,
            resolved_executable,
        } => {
            session_id_is_legal(session_id)?;
            if *child_pid == 0 {
                return Err("child_pid is illegal");
            }
            if resolved_executable
                .as_deref()
                .is_some_and(|path| !unix_absolute_path_is_legal(path))
            {
                return Err("resolved_executable is illegal");
            }
        }
        Message::PtyAttached {
            session_id,
            child_pid,
        } => {
            session_id_is_legal(session_id)?;
            if *child_pid == 0 {
                return Err("child_pid is illegal");
            }
        }
        Message::PtyStartAck { session_id }
        | Message::PtyExited { session_id }
        | Message::PtyAttach { session_id }
        | Message::PtyStop { session_id } => {
            session_id_is_legal(session_id)?;
        }
        Message::PtyInput { data_b64 } | Message::PtyOutput { data_b64 } => {
            let decoded = decode_base64(data_b64).ok_or("data_b64 is illegal")?;
            if decoded.is_empty() || decoded.len() > MAX_PTY_IO_CHUNK {
                return Err("data_b64 decoded length is illegal");
            }
        }
        Message::PtyResize { cols, rows } => dimensions_are_legal(*cols, *rows)?,
        Message::Reject { detail, .. } if detail.len() > MAX_REJECT_DETAIL_BYTES => {
            return Err("reject detail is illegal");
        }
        _ => {}
    }
    Ok(())
}

fn dimensions_are_legal(cols: u16, rows: u16) -> Result<(), &'static str> {
    if cols == 0 || cols > MAX_PTY_COLS || rows == 0 || rows > MAX_PTY_ROWS {
        return Err("PTY dimensions are illegal");
    }
    Ok(())
}

fn unix_absolute_path_is_legal(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= MAX_EXECUTABLE_BYTES
        && path.starts_with('/')
        && !path.as_bytes().contains(&0)
        && path
            .as_bytes()
            .split(|byte| *byte == b'/')
            .all(|component| component != b"." && component != b"..")
}

fn session_id_is_legal(session_id: &str) -> Result<(), &'static str> {
    if session_id.len() != MAX_SESSION_ID_HEX
        || !session_id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("session_id is illegal");
    }
    Ok(())
}

fn nonce_is_legal(nonce: &str) -> bool {
    nonce.len() == NONCE_HEX_LEN && nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn capability_is_legal(item: &str) -> bool {
    item.bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn client_version_is_legal(client_version: &str) -> bool {
    let len = client_version.len();
    len > 0
        && len <= MAX_CLIENT_VERSION_BYTES
        && client_version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn truncate_detail(detail: String) -> String {
    if detail.len() <= MAX_REJECT_DETAIL_BYTES {
        return detail;
    }
    let mut end = MAX_REJECT_DETAIL_BYTES;
    while end > 0 && !detail.is_char_boundary(end) {
        end -= 1;
    }
    detail[..end].to_string()
}

#[cfg(test)]
mod measure {
    use super::*;

    #[test]
    fn measured_max_payloads() {
        let hello = encode_payload(&max_legal_hello()).unwrap().len() as u32;
        let welcome = encode_payload(&max_legal_welcome()).unwrap().len() as u32;
        let reject = encode_payload(&max_legal_reject()).unwrap().len() as u32;
        // U+0001 is legal in executable and argv strings (only NUL is
        // rejected), and serde_json encodes every byte as \\u0001.
        let escaped = "\u{0001}".repeat(MAX_EXECUTABLE_BYTES);
        let escaped_path = format!("/{}", "\u{0001}".repeat(MAX_EXECUTABLE_BYTES - 1));
        let session_id = "f".repeat(MAX_SESSION_ID_HEX);
        let data_b64 = encode_base64(&vec![u8::MAX; MAX_PTY_IO_CHUNK]);
        let messages = [
            Message::PtyStart {
                executable: escaped,
                resolution: None,
                argv: vec!["\u{0001}".repeat(MAX_ARGV_ELEM_BYTES); MAX_ARGV_COUNT],
                cols: MAX_PTY_COLS,
                rows: MAX_PTY_ROWS,
            },
            Message::PtyStart {
                executable: "claude".to_string(),
                resolution: Some(AgentResolution {
                    absolute_path: Some(escaped_path.clone()),
                    user_candidates: Vec::new(),
                }),
                argv: vec!["\u{0001}".repeat(MAX_ARGV_ELEM_BYTES); MAX_ARGV_COUNT - 1],
                cols: MAX_PTY_COLS,
                rows: MAX_PTY_ROWS,
            },
            Message::PtyStarted {
                session_id: session_id.clone(),
                child_pid: u32::MAX,
                resolved_executable: None,
            },
            Message::PtyStarted {
                session_id: session_id.clone(),
                child_pid: u32::MAX,
                resolved_executable: Some(escaped_path),
            },
            Message::PtyStartAck {
                session_id: session_id.clone(),
            },
            Message::PtyExited {
                session_id: session_id.clone(),
            },
            Message::PtyAttach {
                session_id: session_id.clone(),
            },
            Message::PtyAttached {
                session_id: session_id.clone(),
                child_pid: u32::MAX,
            },
            Message::PtyDetach,
            Message::PtyDetached,
            Message::PtyStop {
                session_id: session_id.clone(),
            },
            Message::PtyStopped,
            Message::PtyInput {
                data_b64: data_b64.clone(),
            },
            Message::PtyOutput { data_b64 },
            Message::PtyResize {
                cols: MAX_PTY_COLS,
                rows: MAX_PTY_ROWS,
            },
        ];
        let measured = messages
            .iter()
            .map(|message| encode_payload(message).unwrap().len() as u32)
            .chain([hello, welcome, reject])
            .max()
            .unwrap();
        assert_eq!(
            (hello, welcome, reject, measured, MAX_FRAME_LEN),
            (hello, welcome, reject, measured, measured),
            "re-pin MAX_FRAME_LEN to the measured max payload"
        );
    }
}
