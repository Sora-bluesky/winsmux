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

#[test]
fn incoming_nsis_plan_uses_the_production_complete_current_authority() {
    use sha2::{Digest,Sha256};
    use winsmux_workspace::desktop_install::parse_install_plan;
    let source:serde_json::Value=serde_json::from_str(include_str!("../src/desktop_current_licenses_v0380.json")).unwrap();
    let mut rows:Vec<_>=source["files"].as_array().unwrap().iter().map(|tuple|{let mut row=tuple.clone();row["role"]="license".into();row}).collect();
    for (role,path) in [("gui","winsmux-app.exe"),("cli","winsmux.exe"),("mcp","winsmux-workspace-mcp.exe")] {rows.push(serde_json::json!({"role":role,"path":path,"bytes":1,"sha256":"01".repeat(32)}));}
    let plan=serde_json::json!({"schema":"winsmux-desktop-install-plan/v1","flavor":"nsis","version":"0.38.0","host":"x86_64-pc-windows-msvc","files":rows});
    let admits=|value:&serde_json::Value|{let bytes=serde_json::to_vec(value).unwrap();parse_install_plan(&bytes,Sha256::digest(&bytes).into(),"nsis","0.38.0").is_ok()};
    assert!(admits(&plan));
    let mut arm=plan.clone();arm["host"]="aarch64-pc-windows-msvc".into();assert!(!admits(&arm));
    for index in [0,rows.len()-4] {let mut subset=plan.clone();subset["files"].as_array_mut().unwrap().remove(index);assert!(!admits(&subset));}
}

#[test]
fn emitted_context_binary_flags_are_exact_for_both_actions() {
    for command in ["install", "uninstall"] {
        let action = if command == "install" { Action::Install } else { Action::Uninstall };
        let original = String::from_utf16(&context(command).chunks_exact(2).map(|p| u16::from_le_bytes([p[0],p[1]])).collect::<Vec<_>>()).unwrap();
        for bits in 0..8 {
            let text = original.replace("start_menu=0", &format!("start_menu={}",bits&1))
                .replace("desktop=1", &format!("desktop={}",(bits>>1)&1))
                .replace("update=0", &format!("update={}",(bits>>2)&1));
            let bytes:Vec<_> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
            let parsed = parse_context(&bytes,action).unwrap();
            assert_eq!(parsed.start_menu,bits&1!=0);assert_eq!(parsed.desktop,bits&2!=0);assert_eq!(parsed.update,bits&4!=0);
        }
        for (key,good) in [("start_menu","0"),("desktop","1"),("update","0")] {
            for bad in ["","2","true","01","-1"," 0","0 ","１"] {
                let text=original.replace(&format!("{key}={good}"),&format!("{key}={bad}"));
                let bytes:Vec<_>=text.encode_utf16().flat_map(u16::to_le_bytes).collect();
                assert!(parse_context(&bytes,action).is_err(),"{command} {key}={bad}");
            }
        }
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ActualFlagEmissions {
    schema:String,template_sha256:String,filefunc_sha256:String,
    baseline_roots:usize,sibling_roots:usize,initial_states:usize,cases:Vec<ActualFlagEmission>,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ActualFlagEmission {
    id:String,action:String,path:String,bytes:u64,sha256:String,
    start_menu:bool,desktop:bool,update:bool,
}
#[test]
#[ignore = "requires parent-owned pinned SDK emission manifest"]
fn actual_sdk_flag_emissions_use_the_production_context_parser() {
    use sha2::{Digest,Sha256};
    use winsmux_workspace::desktop_install::valid_member_path;
    let manifest_path=std::path::PathBuf::from(std::env::var_os("WINSMUX_NSIS_FLAG_EMISSIONS").expect("actual SDK emissions required"));
    let manifest:ActualFlagEmissions=serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    assert_eq!(manifest.schema,"winsmux-nsis-flag-emissions/v1");
    assert_eq!(manifest.template_sha256,"11eb0ec4a8735d47e5468e4be1e9ac0aa805b9b82120ad6541139e74599fa034");
    assert_eq!(manifest.filefunc_sha256,"476f33722ff773cfec60876c5f270f2aadb9529e9b73730fa8c41e9490f4b0d6");
    assert_eq!((manifest.baseline_roots,manifest.sibling_roots,manifest.initial_states),(24,6,6));
    assert_eq!(manifest.cases.len(),180);
    let mut ids=std::collections::HashSet::new();let mut paths=std::collections::HashSet::new();
    for row in &manifest.cases {
        assert!(ids.insert(row.id.clone()));assert!(paths.insert(row.path.to_lowercase()));
        assert!(row.path.starts_with("out/")&&valid_member_path(&row.path));
        let bytes=std::fs::read(manifest_path.parent().unwrap().join(&row.path)).unwrap();
        assert_eq!(bytes.len() as u64,row.bytes);assert_eq!(format!("{:x}",Sha256::digest(&bytes)),row.sha256);
        let action=match row.action.as_str(){"install"=>Action::Install,"uninstall"=>Action::Uninstall,_=>panic!("unknown emission action")};
        let parsed=parse_context(&bytes,action).unwrap();
        assert_eq!((parsed.start_menu,parsed.desktop,parsed.update),(row.start_menu,row.desktop,row.update),"{}",row.id);
    }
    for (action,width) in [("install",3),("uninstall",2)] {
        for silent in [false,true] {for bits in 0..(1<<width) {for state in 0..6 {
            let mode=if silent {"silent"}else{"interactive-init"};
            assert!(ids.contains(&format!("{action}-{mode}-{bits:0width$b}-state{state}")));
        }}}
    }
}
