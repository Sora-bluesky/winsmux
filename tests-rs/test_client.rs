#[cfg(windows)]
use super::*;

#[cfg(windows)]
#[test]
fn ime_detection_ascii_only() {
    // Pure ASCII text should NOT be detected as IME input
    assert!(!paste_buffer_has_non_ascii("abc"));
    assert!(!paste_buffer_has_non_ascii("hello world"));
    assert!(!paste_buffer_has_non_ascii("12345"));
    assert!(!paste_buffer_has_non_ascii(""));
}

#[cfg(windows)]
#[test]
fn ime_detection_japanese() {
    // Japanese IME input should be detected as non-ASCII
    assert!(paste_buffer_has_non_ascii("日本語"));
    assert!(paste_buffer_has_non_ascii("にほんご"));
    assert!(paste_buffer_has_non_ascii("abc日本語"));
}

#[cfg(windows)]
#[test]
fn ime_detection_chinese() {
    assert!(paste_buffer_has_non_ascii("中文"));
    assert!(paste_buffer_has_non_ascii("你好世界"));
}

#[cfg(windows)]
#[test]
fn ime_detection_korean() {
    assert!(paste_buffer_has_non_ascii("한국어"));
}

#[cfg(windows)]
#[test]
fn ime_detection_mixed() {
    // Mixed ASCII + CJK should be detected as non-ASCII
    assert!(paste_buffer_has_non_ascii("hello世界"));
    assert!(paste_buffer_has_non_ascii("a日b"));
}

#[cfg(windows)]
#[test]
fn flush_paste_pend_ascii_sends_as_paste() {
    // ASCII buffer with ≥3 chars should send as send-paste (paste detection intact)
    let mut buf = String::from("abcdef");
    let mut start: Option<std::time::Instant> = Some(std::time::Instant::now());
    let mut stage2 = true;
    let mut cmds: Vec<String> = Vec::new();
    flush_paste_pend_as_text(&mut buf, &mut start, &mut stage2, &mut cmds);
    assert_eq!(cmds.len(), 1);
    assert!(cmds[0].starts_with("send-paste "));
}

#[cfg(windows)]
#[test]
fn flush_paste_pend_cjk_sends_as_text() {
    // Non-ASCII buffer should NEVER send as send-paste, even with ≥3 chars.
    // This is the core fix for issue #91.
    let mut buf = String::from("日本語テスト");
    let mut start: Option<std::time::Instant> = Some(std::time::Instant::now());
    let mut stage2 = false;
    let mut cmds: Vec<String> = Vec::new();
    flush_paste_pend_as_text(&mut buf, &mut start, &mut stage2, &mut cmds);
    // Each character should be sent as individual send-text
    assert!(cmds.len() > 1, "CJK should be sent as individual send-text commands");
    for cmd in &cmds {
        assert!(cmd.starts_with("send-text "), "CJK char should be send-text, got: {}", cmd);
    }
}

#[cfg(windows)]
#[test]
fn flush_paste_pend_short_ascii_sends_as_text() {
    // <3 ASCII chars should be sent as individual keystrokes
    let mut buf = String::from("ab");
    let mut start: Option<std::time::Instant> = Some(std::time::Instant::now());
    let mut stage2 = false;
    let mut cmds: Vec<String> = Vec::new();
    flush_paste_pend_as_text(&mut buf, &mut start, &mut stage2, &mut cmds);
    assert_eq!(cmds.len(), 2);
    assert!(cmds[0].starts_with("send-text "));
    assert!(cmds[1].starts_with("send-text "));
}

// ── Issue #164: status-format[] must parse inline styles end-to-end ──

/// Verify that status_format strings from JSON deserialization flow through
/// parse_inline_styles correctly and produce styled (not literal) output.
#[cfg(windows)]
#[test]
fn status_format_inline_styles_end_to_end() {
    use ratatui::style::{Color, Style};
    use unicode_width::UnicodeWidthStr;

    // Simulate what the server sends: status_format with style directives
    let status_format: Vec<String> = vec![
        "#[align=left]Custom Line 1".to_string(),
        "#[fg=red]Custom Line 2".to_string(),
    ];

    let sb_base = Style::default().fg(Color::White).bg(Color::Black);

    // Test line 0 (status_format[0]) rendering path
    {
        let use_status_format_0 = !status_format.is_empty() && !status_format[0].is_empty();
        assert!(use_status_format_0, "status_format[0] should be detected as set");

        let fmt0_spans = crate::style::parse_inline_styles(&status_format[0], sb_base);
        assert_eq!(fmt0_spans.len(), 1, "Line 0 should produce 1 span, got {}", fmt0_spans.len());
        assert_eq!(fmt0_spans[0].content.as_ref(), "Custom Line 1",
            "Line 0 should NOT contain literal #[align=left], got: {:?}", fmt0_spans[0].content);
        // align=left is silently consumed, style stays at base
        assert_eq!(fmt0_spans[0].style.fg, Some(Color::White));
        assert_eq!(fmt0_spans[0].style.bg, Some(Color::Black));
    }

    // Test line 1 (status_format[1]) rendering path
    {
        let text = &status_format[1];
        let parsed_spans = crate::style::parse_inline_styles(text, sb_base);
        assert_eq!(parsed_spans.len(), 1, "Line 1 should produce 1 span, got {}", parsed_spans.len());
        assert_eq!(parsed_spans[0].content.as_ref(), "Custom Line 2",
            "Line 1 should NOT contain literal #[fg=red], got: {:?}", parsed_spans[0].content);
        assert_eq!(parsed_spans[0].style.fg, Some(Color::Red),
            "Line 1 fg should be Red (parsed from #[fg=red]), got {:?}", parsed_spans[0].style.fg);
        assert_eq!(parsed_spans[0].style.bg, Some(Color::Black),
            "Line 1 bg should remain Black from base, got {:?}", parsed_spans[0].style.bg);

        // Also verify padding uses visible width, not raw text length
        let visible_w: usize = parsed_spans.iter()
            .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
            .sum();
        assert_eq!(visible_w, 13, "Visible width should be 13 (Custom Line 2), got {}", visible_w);
        // The raw status_format[1] is 23 chars (#[fg=red]Custom Line 2)
        // but visible is only 13 chars — padding must use 13, not 23
        assert!(text.len() > visible_w,
            "Raw text ({}) should be longer than visible width ({}) due to style directives",
            text.len(), visible_w);
    }
}

/// Verify that the JSON server payload correctly round-trips status_format
/// through serde deserialization without mangling style directives.
#[cfg(windows)]
#[test]
fn status_format_json_roundtrip_preserves_styles() {
    // Simulate the JSON fragment the server sends
    let json_fragment = r##"{"status_format":["","#[fg=red]Hello","#[fg=green,bg=blue]World"]}"##;

    #[derive(serde::Deserialize)]
    struct Partial {
        #[serde(default)]
        status_format: Vec<String>,
    }
    let parsed: Partial = serde_json::from_str(json_fragment).unwrap();
    assert_eq!(parsed.status_format.len(), 3);
    assert_eq!(parsed.status_format[0], "");
    assert_eq!(parsed.status_format[1], "#[fg=red]Hello",
        "Style directives must survive JSON roundtrip");
    assert_eq!(parsed.status_format[2], "#[fg=green,bg=blue]World",
        "Multi-directive styles must survive JSON roundtrip");

    // Now verify parse_inline_styles produces correct output from deserialized data
    use ratatui::style::{Color, Style};
    let base = Style::default();

    let spans1 = crate::style::parse_inline_styles(&parsed.status_format[1], base);
    assert_eq!(spans1.len(), 1);
    assert_eq!(spans1[0].content.as_ref(), "Hello");
    assert_eq!(spans1[0].style.fg, Some(Color::Red));

    let spans2 = crate::style::parse_inline_styles(&parsed.status_format[2], base);
    assert_eq!(spans2.len(), 1);
    assert_eq!(spans2[0].content.as_ref(), "World");
    assert_eq!(spans2[0].style.fg, Some(Color::Green));
    assert_eq!(spans2[0].style.bg, Some(Color::Blue));
}
