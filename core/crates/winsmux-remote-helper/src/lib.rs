//! Length-prefixed stdio protocol for `winsmux-remote-helper`.
//!
//! TASK-772 first PR. No SSH, PTY, filesystem, network, or host mutation.

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

/// Payload-byte ceiling. Pinned by `measured_max_payloads` to the largest
/// production encoding of a legal Hello, Welcome, or Reject. No extra margin.
pub const MAX_FRAME_LEN: u32 = 523;
pub const PROTOCOL_VERSION: u16 = 1;
pub const PREFIX_LEN: usize = 4;
pub const MAX_CLIENT_VERSION_BYTES: usize = 64;
pub const NONCE_LEN: usize = 32;
pub const NONCE_HEX_LEN: usize = NONCE_LEN * 2;
pub const MAX_CAPABILITY_LEN: usize = 32;
pub const MAX_CAPABILITIES: usize = 8;
pub const MAX_REJECT_DETAIL_BYTES: usize = 128;
pub const SUPPORTED_CAPABILITIES: [&str; 1] = ["frame-v1"];

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
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectCode {
    VersionMismatch,
    UnknownType,
    Malformed,
    Oversized,
    PeerLimit,
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
    let payload = encode_payload(message).map_err(|error| {
        io::Error::new(io::ErrorKind::InvalidData, error)
    })?;
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
    let value: serde_json::Value = serde_json::from_slice(payload).map_err(|_| {
        Message::reject(RejectCode::Malformed, "payload is not JSON")
    })?;
    let Some(kind) = value.get("type").and_then(serde_json::Value::as_str) else {
        return Err(Message::reject(
            RejectCode::Malformed,
            "payload type is missing",
        ));
    };
    match kind {
        "hello" | "welcome" | "reject" => {}
        _ => {
            return Err(Message::reject(
                RejectCode::UnknownType,
                format!("unknown type '{kind}'"),
            ));
        }
    }
    serde_json::from_value(value).map_err(|_| {
        Message::reject(RejectCode::Malformed, "payload fields are invalid")
    })
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
        || capabilities
            .iter()
            .any(|item| item.is_empty() || item.len() > MAX_CAPABILITY_LEN || !capability_is_legal(item))
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
        Ok(Message::Hello { .. }) => {
            Message::reject(RejectCode::UnknownType, "hello is not accepted after Welcome")
        }
        Ok(Message::Welcome { .. }) => {
            Message::reject(RejectCode::UnknownType, "welcome is not accepted from the peer")
        }
        Ok(Message::Reject { .. }) => Message::reject(
            RejectCode::UnknownType,
            "reject is not an accepted follow-on type",
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
    Message::reject(RejectCode::Malformed, "d".repeat(MAX_REJECT_DETAIL_BYTES))
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
        let measured = hello.max(welcome).max(reject);
        assert_eq!(
            (hello, welcome, reject, measured, MAX_FRAME_LEN),
            (hello, welcome, reject, measured, measured),
            "re-pin MAX_FRAME_LEN to the measured max payload"
        );
    }
}
