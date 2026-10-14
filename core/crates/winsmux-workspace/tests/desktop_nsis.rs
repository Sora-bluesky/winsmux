use winsmux_workspace::desktop_nsis::*;
fn context(command: &str) -> Vec<u8> {
    format!("schema=winsmux-nsis-context/v1\r\ncommand={command}\r\nroot=C:\\owned 日本語 & =data\\winsmux\r\nsource=C:\\owned\\source\r\nplan_sha256={}\r\nversion=0.38.0\r\nlanguage=1041\r\nstart_menu=0\r\ndesktop=1\r\nupdate=0\r\n","a".repeat(64)).encode_utf16().flat_map(u16::to_le_bytes).collect()
}
#[test]
fn context_strict_utf16_and_fixed_order() {
    let good = context("install");
    let c = parse_context(&good, Action::Install).unwrap();
    assert!(c.root.to_str().unwrap().contains("=data"));
    assert_eq!(c.language, 1041);
    assert!(c.desktop);
    assert!(parse_context(&good, Action::Uninstall).is_err());
    let mut bom = vec![0xff, 0xfe];
    bom.extend(&good);
    assert!(parse_context(&bom, Action::Install).is_ok());
    let mut odd = good.clone();
    odd.push(0);
    assert!(parse_context(&odd, Action::Install).is_err());
    for bad in [vec![0x00, 0xd8], vec![0, 0], vec![0xfe, 0xff]] {
        assert!(parse_context(&bad, Action::Install).is_err());
    }
    let text = String::from_utf16(
        &good
            .chunks_exact(2)
            .map(|p| u16::from_le_bytes([p[0], p[1]]))
            .collect::<Vec<_>>(),
    )
    .unwrap();
    let english: Vec<_> = text
        .replace("language=1041", "language=1033")
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    assert_eq!(
        parse_context(&english, Action::Install).unwrap().language,
        1033
    );
    for mutation in [
        text.replace("language=1041", "language=1042"),
        text.replace("language=1041", "language=null"),
        text.replace("language=1041", "language="),
        text.replace("language=1041\r\n", ""),
        text.replace("desktop=1", "desktop=true"),
        text.replace("root=C:", "root=\\\\foreign\\C:"),
        text.replace("update=0", "unknown=0"),
        text.replace("source=", "root="),
        format!("{text}extra=x\r\n"),
        text.replace("=data", "=\u{0}data"),
    ] {
        let bytes: Vec<_> = mutation.encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert!(parse_context(&bytes, Action::Install).is_err());
    }
}
#[test]
fn cli_exact_verbs_and_one_context_pair() {
    for verb in ["nsis-install", "nsis-uninstall"] {
        assert!(
            parse_arguments(&[verb.into(), "--context".into(), "C:\\owned\\ctx".into()]).is_ok()
        );
    }
    for args in [
        vec!["msi-verify".into(), "--context".into(), "x".into()],
        vec!["nsis-install".into(), "--root".into(), "x".into()],
        vec![
            "nsis-install".into(),
            "--context".into(),
            "x".into(),
            "extra".into(),
        ],
    ] {
        assert!(parse_arguments(&args).is_err());
    }
}
#[test]
fn nullable_raw_slot_class_all_phases() {
    let absent = None;
    let empty = Some(RawValue {
        kind: 1,
        data: vec![0, 0],
    });
    let binary_empty = Some(RawValue {
        kind: 3,
        data: vec![],
    });
    let old = Some(RawValue {
        kind: 1,
        data: vec![65, 0, 0, 0],
    });
    let new = Some(RawValue {
        kind: 4,
        data: vec![1, 0, 0, 0],
    });
    let foreign = Some(RawValue {
        kind: 7,
        data: vec![90, 0, 0, 0],
    });
    let values = [absent, empty, binary_empty, old, new, foreign];
    for prior in &values {
        for desired in &values {
            for current in &values {
                let mut row = Slot {
                    id: 0,
                    prior: prior.clone(),
                    desired: desired.clone(),
                    phase: SlotPhase::Prepared,
                };
                let expect = if current != prior {
                    SlotDecision::Pending
                } else if prior == desired {
                    SlotDecision::Keep
                } else {
                    SlotDecision::WriteDesired
                };
                assert_eq!(slot_publish(&row, current), expect);
                for phase in [
                    SlotPhase::Prepared,
                    SlotPhase::WriteIntent,
                    SlotPhase::PublishedConfirmed,
                    SlotPhase::RestoreIntent,
                    SlotPhase::Restored,
                ] {
                    row.phase = phase;
                    let d = slot_restore(&row, current);
                    if phase == SlotPhase::WriteIntent {
                        assert_eq!(d, SlotDecision::Pending);
                    } else if current == prior {
                        assert_eq!(d, SlotDecision::Keep);
                    } else if current == desired
                        && matches!(
                            phase,
                            SlotPhase::PublishedConfirmed | SlotPhase::RestoreIntent
                        )
                    {
                        assert_eq!(d, SlotDecision::WritePrior);
                    } else {
                        assert_eq!(d, SlotDecision::Pending);
                    }
                }
            }
        }
    }
}
#[test]
fn measured_legacy_capture_is_complete_and_joined() {
    legacy_admission_complete().unwrap();
}
