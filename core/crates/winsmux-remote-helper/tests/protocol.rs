use std::io::{Cursor, Read};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use winsmux_remote_helper::{
    decode_payload, encode_frame, encode_payload, max_legal_hello, max_legal_reject,
    max_legal_welcome, read_frame, respond_after_negotiation, serve_stdio, Message, RejectCode,
    MAX_ARGV_COUNT, MAX_ARGV_ELEM_BYTES, MAX_EXECUTABLE_BYTES, MAX_FRAME_LEN, MAX_PTY_COLS,
    MAX_PTY_IO_CHUNK, MAX_PTY_ROWS, PREFIX_LEN, PROTOCOL_VERSION,
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
    hello_with_caps(
        vec!["frame-v1".to_string(), "pty-v1".to_string()],
        peer_frame_limit,
    )
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
    if let Message::Hello { client_version, .. } = &mut hello {
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
            assert_eq!(
                capabilities,
                vec!["frame-v1".to_string(), "pty-v1".to_string()]
            );
        }
        other => panic!("expected Welcome, got {other:?}"),
    }
}

#[test]
fn welcome_negotiates_agent_path_v1_in_server_order() {
    let mut output = Vec::new();
    serve_stdio(
        Cursor::new(
            encode_frame(&hello_with_caps(
                vec![
                    "agent-path-v1".to_string(),
                    "pty-v1".to_string(),
                    "frame-v1".to_string(),
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
        Message::Welcome { capabilities, .. } => assert_eq!(
            capabilities,
            vec![
                "frame-v1".to_string(),
                "pty-v1".to_string(),
                "agent-path-v1".to_string(),
            ]
        ),
        other => panic!("expected Welcome, got {other:?}"),
    }
}

#[test]
fn welcome_negotiates_session_lifecycle_v1_in_server_order() {
    let mut output = Vec::new();
    serve_stdio(
        Cursor::new(
            encode_frame(&hello_with_caps(
                vec![
                    "session-lifecycle-v1".to_string(),
                    "pty-v1".to_string(),
                    "frame-v1".to_string(),
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
        Message::Welcome { capabilities, .. } => assert_eq!(
            capabilities,
            vec![
                "frame-v1".to_string(),
                "pty-v1".to_string(),
                "session-lifecycle-v1".to_string(),
            ]
        ),
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
            assert_eq!(
                capabilities,
                vec!["frame-v1".to_string(), "pty-v1".to_string()]
            );
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
    let json = br#"{"type":"exec","protocol_version":1}"#;
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
        let result = read_frame(&mut Cursor::new(frame_with_declared_len(
            declared, &payload,
        )))
        .unwrap();
        assert!(
            result.is_ok(),
            "declared {declared} must pass the size gate"
        );
    }
}

#[test]
fn size_gate_rejects_n_plus_one_without_reading_payload() {
    let declared = MAX_FRAME_LEN + 1;
    let junk = vec![0u8; 64];
    let mut reader = CountingReader::new(frame_with_declared_len(declared, &junk));
    let result = read_frame(&mut reader).unwrap();
    assert!(matches!(
        result,
        Err(Message::Reject {
            code: RejectCode::Oversized,
            ..
        })
    ));
    assert_eq!(reader.payload_bytes_read.load(Ordering::SeqCst), 0);
}

#[test]
fn golden_max_payload_lengths() {
    let hello = encode_payload(&max_legal_hello()).unwrap().len() as u32;
    let welcome = encode_payload(&max_legal_welcome()).unwrap().len() as u32;
    let reject = encode_payload(&max_legal_reject()).unwrap().len() as u32;
    assert_eq!(hello, 523);
    assert_eq!(welcome, 215);
    assert_eq!(reject, 816);

    // U+0001 is legal (only NUL is forbidden) and serde_json emits it as
    // `\\u0001`, making it the worst-case one-byte string specimen.
    let escaped = "\u{0001}".repeat(MAX_EXECUTABLE_BYTES);
    let pty_start = Message::PtyStart {
        executable: escaped.clone(),
        resolution: None,
        argv: vec!["\u{0001}".repeat(MAX_ARGV_ELEM_BYTES); MAX_ARGV_COUNT],
        cols: MAX_PTY_COLS,
        rows: MAX_PTY_ROWS,
    };
    const MAX_LEGAL_PTY_START_PAYLOAD: usize = 13_915;
    assert_eq!(
        encode_payload(&pty_start).unwrap().len(),
        MAX_LEGAL_PTY_START_PAYLOAD,
        "golden worst-case legal pty-start payload"
    );
    assert_eq!(MAX_FRAME_LEN as usize, MAX_LEGAL_PTY_START_PAYLOAD);
    assert_eq!(
        encode_frame(&pty_start).unwrap().len(),
        PREFIX_LEN + MAX_LEGAL_PTY_START_PAYLOAD
    );
}

#[test]
fn pty_message_wire_names_are_hyphenated() {
    let message = Message::PtyStart {
        executable: "/bin/cat".to_string(),
        resolution: None,
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    };
    let payload = encode_payload(&message).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&payload).unwrap()["type"],
        "pty-start"
    );
    assert_eq!(decode_payload(&payload).unwrap(), message);
}

#[test]
fn legacy_pty_start_and_started_json_remain_byte_compatible() {
    let start = Message::PtyStart {
        executable: "/bin/cat".to_string(),
        resolution: None,
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    };
    assert_eq!(
        encode_payload(&start).unwrap(),
        br#"{"type":"pty-start","executable":"/bin/cat","argv":[],"cols":80,"rows":24}"#
    );

    let started = Message::PtyStarted {
        session_id: "f".repeat(32),
        child_pid: 42,
        resolved_executable: None,
    };
    assert_eq!(
        encode_payload(&started).unwrap(),
        br#"{"type":"pty-started","session_id":"ffffffffffffffffffffffffffffffff","child_pid":42}"#
    );
}

#[test]
fn lifecycle_message_wire_names_and_session_ids_roundtrip() {
    let session_id = "f".repeat(32);
    let cases = [
        (
            Message::PtyStartAck {
                session_id: session_id.clone(),
            },
            br#"{"type":"pty-start-ack","session_id":"ffffffffffffffffffffffffffffffff"}"#
                .as_slice(),
        ),
        (
            Message::PtyExited { session_id },
            br#"{"type":"pty-exited","session_id":"ffffffffffffffffffffffffffffffff"}"#.as_slice(),
        ),
    ];

    for (message, expected) in cases {
        let payload = encode_payload(&message).unwrap();
        assert_eq!(payload, expected);
        assert_eq!(decode_payload(&payload).unwrap(), message);
    }
}

#[test]
fn lifecycle_message_directions_are_frozen() {
    let session_id = "f".repeat(32);
    let ack = encode_payload(&Message::PtyStartAck {
        session_id: session_id.clone(),
    })
    .unwrap();
    assert!(matches!(
        respond_after_negotiation(&ack),
        Message::Reject {
            code: RejectCode::Unsupported,
            ..
        }
    ));

    let exited = encode_payload(&Message::PtyExited { session_id }).unwrap();
    assert!(matches!(
        respond_after_negotiation(&exited),
        Message::Reject {
            code: RejectCode::UnknownType,
            ..
        }
    ));
}

#[test]
fn resolution_envelope_roundtrips_with_optional_absolute_path() {
    let payload = br#"{"type":"pty-start","executable":"claude","resolution":{"absolute_path":"/opt/agents/claude","user_candidates":["/usr/local/bin/claude"]},"argv":["--version"],"cols":80,"rows":24}"#;
    let message = decode_payload(payload).expect("valid resolution envelope");
    match &message {
        Message::PtyStart {
            executable,
            resolution: Some(resolution),
            argv,
            cols,
            rows,
        } => {
            assert_eq!(executable, "claude");
            assert_eq!(
                resolution.absolute_path.as_deref(),
                Some("/opt/agents/claude")
            );
            assert_eq!(resolution.user_candidates, ["/usr/local/bin/claude"]);
            assert_eq!(argv, &vec!["--version".to_string()]);
            assert_eq!((*cols, *rows), (80, 24));
        }
        other => panic!("expected resolution pty-start, got {other:?}"),
    }
    assert_eq!(encode_payload(&message).unwrap(), payload);

    let without_absolute = br#"{"type":"pty-start","executable":"codex","resolution":{"user_candidates":[]},"argv":[],"cols":80,"rows":24}"#;
    let message = decode_payload(without_absolute).expect("optional absolute_path");
    assert_eq!(encode_payload(&message).unwrap(), without_absolute);
}

#[test]
fn resolution_envelope_enforces_provider_paths_and_combined_count() {
    let cases = [
        serde_json::json!({
            "type": "pty-start",
            "executable": "agent",
            "resolution": {"user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"absolute_path": "relative/claude", "user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"absolute_path": "/opt/../bin/claude", "user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"absolute_path": "/opt/\0claude", "user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "codex",
            "resolution": {"absolute_path": format!("/{}", "x".repeat(MAX_EXECUTABLE_BYTES)), "user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "codex",
            "resolution": {"absolute_path": format!("/{}", "é".repeat(128)), "user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"user_candidates": ["/opt/./claude"]},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"user_candidates": [""]},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"path": "/caller/supplied", "user_candidates": []},
            "argv": [], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "claude",
            "resolution": {"absolute_path": "/opt/claude", "user_candidates": vec!["/bin/claude"; 4]},
            "argv": vec!["x"; 4], "cols": 80, "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "codex",
            "resolution": {"user_candidates": vec!["/bin/codex"; 4]},
            "argv": vec!["x"; 5], "cols": 80, "rows": 24
        }),
    ];
    for value in cases {
        assert!(matches!(
            decode_payload(&serde_json::to_vec(&value).unwrap()),
            Err(Message::Reject {
                code: RejectCode::Malformed,
                ..
            })
        ));
    }
}

#[test]
fn resolution_request_and_success_response_maxima_fit_frozen_frame_ceiling() {
    let escaped_argument = "\u{0001}".repeat(MAX_ARGV_ELEM_BYTES);
    let escaped_path = format!("/{}", "\u{0001}".repeat(MAX_EXECUTABLE_BYTES - 1));
    let mut measured_request_max = 0;
    for has_absolute in [false, true] {
        let combined_limit = if has_absolute { 7 } else { 8 };
        for candidate_count in 0..=combined_limit {
            let argv_count = combined_limit - candidate_count;
            let mut resolution = serde_json::json!({
                "user_candidates": vec![escaped_path.clone(); candidate_count]
            });
            if has_absolute {
                resolution["absolute_path"] = serde_json::Value::String(escaped_path.clone());
            }
            let value = serde_json::json!({
                "type": "pty-start",
                "executable": "claude",
                "resolution": resolution,
                "argv": vec![escaped_argument.clone(); argv_count],
                "cols": MAX_PTY_COLS,
                "rows": MAX_PTY_ROWS
            });
            let message = decode_payload(&serde_json::to_vec(&value).unwrap())
                .expect("legal maximum resolution request");
            let encoded_len = encode_payload(&message).unwrap().len();
            measured_request_max = measured_request_max.max(encoded_len);
            assert!(encoded_len < MAX_FRAME_LEN as usize);
        }
    }
    assert_eq!(measured_request_max, 12_432);

    let started = serde_json::json!({
        "type": "pty-started",
        "session_id": "f".repeat(32),
        "child_pid": u32::MAX,
        "resolved_executable": escaped_path
    });
    let started =
        decode_payload(&serde_json::to_vec(&started).unwrap()).expect("legal maximum pty-started");
    assert_eq!(encode_payload(&started).unwrap().len(), 1_649);
    assert!(encode_frame(&started).is_ok());
    assert_eq!(MAX_FRAME_LEN, 13_915);
}

#[test]
fn oversized_pty_start_fields_are_malformed_before_spawn() {
    let cases = [
        serde_json::json!({
            "type": "pty-start",
            "executable": "x".repeat(MAX_EXECUTABLE_BYTES + 1),
            "argv": [],
            "cols": 80,
            "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "/bin/cat",
            "argv": vec!["x"; MAX_ARGV_COUNT + 1],
            "cols": 80,
            "rows": 24
        }),
        serde_json::json!({
            "type": "pty-start",
            "executable": "/bin/cat",
            "argv": ["x".repeat(MAX_ARGV_ELEM_BYTES + 1)],
            "cols": 80,
            "rows": 24
        }),
    ];
    for value in cases {
        match decode_payload(&serde_json::to_vec(&value).unwrap()) {
            Err(Message::Reject { code, .. }) => assert_eq!(code, RejectCode::Malformed),
            other => panic!("expected Malformed, got {other:?}"),
        }
    }
}

#[test]
fn pty_input_requires_canonical_base64_for_one_to_256_bytes() {
    for data_b64 in ["".to_string(), "***".to_string(), "A".repeat(348)] {
        let payload = serde_json::to_vec(&serde_json::json!({
            "type": "pty-input",
            "data_b64": data_b64
        }))
        .unwrap();
        match decode_payload(&payload) {
            Err(Message::Reject { code, .. }) => assert_eq!(code, RejectCode::Malformed),
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    let legal = Message::PtyInput {
        data_b64: "AA==".to_string(),
    };
    assert_eq!(
        decode_payload(&encode_payload(&legal).unwrap()).unwrap(),
        legal
    );
    assert_eq!(MAX_PTY_IO_CHUNK, 256);
}

#[test]
fn pty_resize_enforces_nonzero_frozen_bounds() {
    for (cols, rows) in [
        (0, 24),
        (80, 0),
        (MAX_PTY_COLS + 1, 24),
        (80, MAX_PTY_ROWS + 1),
    ] {
        let payload = serde_json::to_vec(&serde_json::json!({
            "type": "pty-resize",
            "cols": cols,
            "rows": rows
        }))
        .unwrap();
        assert!(matches!(
            decode_payload(&payload),
            Err(Message::Reject {
                code: RejectCode::Malformed,
                ..
            })
        ));
    }
}

#[cfg(not(target_os = "linux"))]
#[test]
fn pty_start_is_known_but_unsupported_after_welcome() {
    let message = Message::PtyStart {
        executable: "agent".to_string(),
        resolution: None,
        argv: Vec::new(),
        cols: 80,
        rows: 24,
    };
    let mut input = encode_frame(&hello(MAX_FRAME_LEN)).unwrap();
    input.extend_from_slice(&encode_frame(&message).unwrap());
    let mut output = Vec::new();
    serve_stdio(Cursor::new(input), &mut output).unwrap();
    let mut output = Cursor::new(output);
    let welcome = read_frame(&mut output).unwrap().expect("welcome");
    assert!(matches!(
        decode_payload(&welcome).unwrap(),
        Message::Welcome { .. }
    ));
    let reject = read_frame(&mut output).unwrap().expect("unsupported");
    match decode_payload(&reject).unwrap() {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::Unsupported),
        other => panic!("expected Unsupported, got {other:?}"),
    }
}

#[test]
fn session_ids_are_exact_lowercase_hex() {
    for kind in ["pty-attach", "pty-start-ack", "pty-exited"] {
        for session_id in [
            "a".repeat(31),
            "a".repeat(33),
            "A".repeat(32),
            "g".repeat(32),
        ] {
            let payload = serde_json::to_vec(&serde_json::json!({
                "type": kind,
                "session_id": session_id
            }))
            .unwrap();
            assert!(matches!(
                decode_payload(&payload),
                Err(Message::Reject {
                    code: RejectCode::Malformed,
                    ..
                })
            ));
        }
    }
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
    let mut command = Command::new(helper_bin());
    command
        .args(["serve", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(target_os = "linux")]
    let runtime = LinuxRuntimeDir::new("protocol-black-box");
    #[cfg(target_os = "linux")]
    command.env("XDG_RUNTIME_DIR", &runtime.0);
    let mut child = command.spawn().expect("spawn helper");
    {
        let mut stdin = child.stdin.take().expect("stdin");
        use std::io::Write;
        stdin
            .write_all(&encode_frame(&hello(MAX_FRAME_LEN)).unwrap())
            .unwrap();
    }
    let output = child.wait_with_output().expect("wait helper");
    assert!(output.status.success());
    #[cfg(target_os = "linux")]
    runtime.wait_for_broker_exit();
    let payload = read_frame(&mut Cursor::new(output.stdout))
        .unwrap()
        .expect("welcome");
    assert!(matches!(
        decode_payload(&payload).unwrap(),
        Message::Welcome { .. }
    ));
}

#[cfg(target_os = "linux")]
struct LinuxRuntimeDir(PathBuf);

#[cfg(target_os = "linux")]
impl LinuxRuntimeDir {
    fn new(label: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;
        use std::time::{SystemTime, UNIX_EPOCH};
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("winsmux-{label}-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }

    fn wait_for_broker_exit(&self) {
        let socket = self
            .0
            .join("winsmux")
            .join("remote-helper")
            .join("broker.sock");
        loop {
            match std::fs::symlink_metadata(&socket) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
                Err(error) => panic!("lstat broker.sock failed: {error}"),
                Ok(_) => std::thread::yield_now(),
            }
        }
    }
}

#[cfg(target_os = "linux")]
impl Drop for LinuxRuntimeDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn respond_after_negotiation_rejects_second_hello() {
    let payload = encode_payload(&hello(MAX_FRAME_LEN)).unwrap();
    match respond_after_negotiation(&payload) {
        Message::Reject { code, .. } => assert_eq!(code, RejectCode::UnknownType),
        other => panic!("expected Reject, got {other:?}"),
    }
}
