use std::io::{Cursor, Read};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use winsmux_remote_helper::{
    decode_payload, encode_frame, encode_payload, max_legal_hello, max_legal_reject,
    max_legal_welcome, read_frame, respond_after_negotiation, serve_stdio, Message, RejectCode,
    MAX_FRAME_LEN, PREFIX_LEN, PROTOCOL_VERSION,
};

struct CountingReader {
    inner: Cursor<Vec<u8>>,
    payload_bytes_read: AtomicUsize,
}

impl CountingReader {
    fn new(bytes: Vec<u8>) -> Self {
        Self {
            inner: Cursor::new(bytes),
            payload_bytes_read: AtomicUsize::new(0),
        }
    }
}

impl Read for CountingReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        if self.inner.position() > PREFIX_LEN as u64 {
            self.payload_bytes_read.fetch_add(n, Ordering::SeqCst);
        }
        Ok(n)
    }
}

fn helper_bin() -> PathBuf {
    env!("CARGO_BIN_EXE_winsmux-remote-helper").into()
}

fn nonce() -> String {
    "aa".repeat(32)
}

fn hello_with_caps(capabilities: Vec<String>, peer_frame_limit: u32) -> Message {
    Message::Hello {
        protocol_version: PROTOCOL_VERSION,
        client_version: "winsmux-test".to_string(),
        nonce: nonce(),
        capabilities,
        peer_frame_limit,
    }
}

fn hello(peer_frame_limit: u32) -> Message {
    hello_with_caps(vec!["frame-v1".to_string()], peer_frame_limit)
}

fn frame_with_declared_len(declared: u32, payload: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::from(declared.to_be_bytes());
    bytes.extend_from_slice(payload);
    bytes
}

#[test]
fn oversized_after_welcome_stops_without_reading_payload_as_frames() {
    let mut stream = encode_frame(&hello(MAX_FRAME_LEN)).unwrap();
    let declared = MAX_FRAME_LEN + 1;
    stream.extend_from_slice(&declared.to_be_bytes());
    stream.extend_from_slice(&vec![0u8; declared as usize]);
    let mut output = Vec::new();
    serve_stdio(Cursor::new(stream), &mut output).unwrap();
    let mut cursor = Cursor::new(output);
    let welcome = read_frame(&mut cursor).unwrap().expect("welcome");
    assert!(matches!(
        decode_payload(&welcome).unwrap(),
        Message::Welcome { .. }
    ));
    let reject = read_frame(&mut cursor).unwrap().expect("oversized");
    match decode_payload(&reject).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::Oversized),
        other => panic!("expected Oversized, got {other:?}"),
    }
    let eof = read_frame(&mut cursor);
    assert!(eof.is_err(), "server must stop after Oversized");
}

#[test]
fn unknown_type_detail_does_not_panic_on_multibyte_truncate() {
    let kind = format!("{}é", "a".repeat(113));
    let json = format!(r#"{{"type":"{kind}","protocol_version":1}}"#);
    let mut frame = (json.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(json.as_bytes());
    let mut output = Vec::new();
    serve_stdio(Cursor::new(frame), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject frame");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, detail } => {
            assert_eq!(code, RejectCode::UnknownType);
            assert!(detail.len() <= 128);
        }
        other => panic!("expected Reject, got {other:?}"),
    }
}

#[test]
fn nul_client_version_is_malformed_not_a_larger_hello() {
    let mut hello = hello(MAX_FRAME_LEN);
    if let Message::Hello {
        client_version, ..
    } = &mut hello
    {
        *client_version = "win\0mux".to_string();
    }
    let mut output = Vec::new();
    serve_stdio(Cursor::new(encode_frame(&hello).unwrap()), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::Malformed),
        other => panic!("expected Malformed, got {other:?}"),
    }
}

#[test]
fn argv_without_serve_stdio_exits_2() {
    let status = Command::new(helper_bin())
        .arg("serve")
        .status()
        .expect("spawn helper");
    assert_eq!(status.code(), Some(2));
}

#[test]
fn argv_extra_token_exits_2() {
    let status = Command::new(helper_bin())
        .args(["serve", "--stdio", "extra"])
        .status()
        .expect("spawn helper");
    assert_eq!(status.code(), Some(2));
}

#[test]
fn capability_intersection_drops_unknown_tokens() {
    let mut output = Vec::new();
    serve_stdio(
        Cursor::new(
            encode_frame(&hello_with_caps(
                vec![
                    "pty-v1".to_string(),
                    "frame-v1".to_string(),
                    "scroll-v1".to_string(),
                ],
                MAX_FRAME_LEN,
            ))
            .unwrap(),
        ),
        &mut output,
    )
    .unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("welcome frame");
    match decode_payload(&payload).unwrap() {
        Message::Welcome { capabilities, .. } => {
            assert_eq!(capabilities, vec!["frame-v1".to_string()]);
        }
        other => panic!("expected Welcome, got {other:?}"),
    }
}

#[test]
fn legal_hello_roundtrip_welcome() {
    let mut output = Vec::new();
    serve_stdio(
        Cursor::new(encode_frame(&hello(MAX_FRAME_LEN)).unwrap()),
        &mut output,
    )
    .unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("welcome frame");
    match decode_payload(&payload).unwrap() {
        Message::Welcome {
            protocol_version,
            nonce: echoed,
            capabilities,
            peer_frame_limit,
        } => {
            assert_eq!(protocol_version, PROTOCOL_VERSION);
            assert_eq!(echoed, nonce());
            assert_eq!(capabilities, vec!["frame-v1".to_string()]);
            assert_eq!(peer_frame_limit, MAX_FRAME_LEN);
        }
        other => panic!("expected Welcome, got {other:?}"),
    }
}

#[test]
fn version_mismatch_rejects() {
    let mut hello = hello(MAX_FRAME_LEN);
    if let Message::Hello {
        protocol_version, ..
    } = &mut hello
    {
        *protocol_version = 2;
    }
    let mut output = Vec::new();
    serve_stdio(Cursor::new(encode_frame(&hello).unwrap()), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject frame");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::VersionMismatch),
        other => panic!("expected Reject, got {other:?}"),
    }
}

#[test]
fn unknown_type_rejects() {
    let json = br#"{"type":"pty-start","protocol_version":1}"#;
    let mut frame = (json.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(json);
    let mut output = Vec::new();
    serve_stdio(Cursor::new(frame), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject frame");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::UnknownType),
        other => panic!("expected Reject, got {other:?}"),
    }
}

#[test]
fn malformed_json_rejects() {
    let json = b"{not-json";
    let mut frame = (json.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(json);
    let mut output = Vec::new();
    serve_stdio(Cursor::new(frame), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject frame");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::Malformed),
        other => panic!("expected Reject, got {other:?}"),
    }
}

#[test]
fn truncated_payload_rejects_malformed() {
    let mut frame = 16u32.to_be_bytes().to_vec();
    frame.extend_from_slice(b"short");
    let mut output = Vec::new();
    serve_stdio(Cursor::new(frame), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject frame");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::Malformed),
        other => panic!("expected Reject, got {other:?}"),
    }
}

#[test]
fn oversized_prefix_does_not_read_payload() {
    let declared = MAX_FRAME_LEN + 1;
    let junk = vec![0u8; 64];
    let mut reader = CountingReader::new(frame_with_declared_len(declared, &junk));
    let result = read_frame(&mut reader).unwrap();
    match result {
        Err(Message::Reject {
            code: RejectCode::Oversized,
            ..
        }) => {}
        other => panic!("expected Oversized, got {other:?}"),
    }
    assert_eq!(reader.payload_bytes_read.load(Ordering::SeqCst), 0);
}

#[test]
fn size_gate_allows_n_minus_one_and_n() {
    for declared in [MAX_FRAME_LEN - 1, MAX_FRAME_LEN] {
        let payload = vec![b'x'; declared as usize];
        let result = read_frame(&mut Cursor::new(frame_with_declared_len(declared, &payload)))
            .unwrap();
        assert!(result.is_ok(), "declared {declared} must pass the size gate");
    }
}

#[test]
fn golden_max_payload_lengths() {
    let hello = encode_payload(&max_legal_hello()).unwrap().len() as u32;
    let welcome = encode_payload(&max_legal_welcome()).unwrap().len() as u32;
    let reject = encode_payload(&max_legal_reject()).unwrap().len() as u32;
    assert_eq!(hello, 523);
    assert_eq!(welcome, 165);
    assert_eq!(reject, 176);
    assert_eq!(hello.max(welcome).max(reject), MAX_FRAME_LEN);
}

#[test]
fn follow_on_unknown_type_rejects_after_welcome() {
    let mut stream = encode_frame(&hello(MAX_FRAME_LEN)).unwrap();
    let junk = br#"{"type":"exec","cmd":"id"}"#;
    stream.extend_from_slice(&(junk.len() as u32).to_be_bytes());
    stream.extend_from_slice(junk);
    let mut output = Vec::new();
    serve_stdio(Cursor::new(stream), &mut output).unwrap();
    let mut cursor = Cursor::new(output);
    let welcome = read_frame(&mut cursor).unwrap().expect("welcome");
    assert!(matches!(
        decode_payload(&welcome).unwrap(),
        Message::Welcome { .. }
    ));
    let reject = read_frame(&mut cursor).unwrap().expect("reject");
    match decode_payload(&reject).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::UnknownType),
        other => panic!("expected Reject, got {other:?}"),
    }
}

#[test]
fn peer_limit_too_small_rejects_welcome() {
    let mut output = Vec::new();
    serve_stdio(Cursor::new(encode_frame(&hello(1)).unwrap()), &mut output).unwrap();
    let payload = read_frame(&mut Cursor::new(output))
        .unwrap()
        .expect("reject");
    match decode_payload(&payload).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::PeerLimit),
        other => panic!("expected PeerLimit, got {other:?}"),
    }
}

#[test]
fn black_box_binary_hello_welcome() {
    let mut child = Command::new(helper_bin())
        .args(["serve", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn helper");
    {
        let mut stdin = child.stdin.take().expect("stdin");
        use std::io::Write;
        stdin
            .write_all(&encode_frame(&hello(MAX_FRAME_LEN)).unwrap())
            .unwrap();
    }
    let output = child.wait_with_output().expect("wait helper");
    assert!(output.status.success());
    let payload = read_frame(&mut Cursor::new(output.stdout))
        .unwrap()
        .expect("welcome");
    assert!(matches!(
        decode_payload(&payload).unwrap(),
        Message::Welcome { .. }
    ));
}

#[test]
fn respond_after_negotiation_rejects_second_hello() {
    let payload = encode_payload(&hello(MAX_FRAME_LEN)).unwrap();
    match respond_after_negotiation(&payload) {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::UnknownType),
        other => panic!("expected Reject, got {other:?}"),
    }
}
