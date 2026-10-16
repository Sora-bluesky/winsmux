use sha2::{Digest, Sha256};
use winsmux_workspace::desktop_install::{
    parse_install_plan, parse_msi_arguments, valid_member_path, verify_desktop_startup,
    DesktopInstallError, StartupProbeContext, StartupVerifyRequest,
};
fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
fn plan() -> serde_json::Value {
    serde_json::json!({"schema":"winsmux-desktop-install-plan/v1","flavor":"msi","version":"0.38.0","host":"x86_64-pc-windows-msvc","files":[
    {"role":"gui","path":"winsmux-app.exe","bytes":1,"sha256":"01".repeat(32)},
    {"role":"cli","path":"winsmux.exe","bytes":1,"sha256":"01".repeat(32)},
    {"role":"mcp","path":"winsmux-workspace-mcp.exe","bytes":1,"sha256":"01".repeat(32)},
    {"role":"app_lib","path":"winsmux_app_lib.dll","bytes":1,"sha256":"01".repeat(32)},
    {"role":"license","path":"licenses/winsmux/LICENSE","bytes":1,"sha256":"01".repeat(32)}]})
}
fn accepts(value: &serde_json::Value) -> bool {
    let bytes = serde_json::to_vec(value).unwrap();
    parse_install_plan(&bytes, digest(&bytes), "msi", "0.38.0").is_ok()
}
#[test]
fn strict_plan_accepts_exact_roles_and_rejects_missing_extra_wrong_flavor_or_version() {
    let good = plan();
    assert!(accepts(&good));
    for key in ["schema", "flavor", "version", "host"] {
        let mut bad = good.clone();
        bad[key] = "wrong".into();
        assert!(!accepts(&bad));
    }
    let mut missing = good.clone();
    missing["files"].as_array_mut().unwrap().remove(0);
    assert!(!accepts(&missing));
    let mut duplicate = good.clone();
    let row = duplicate["files"][0].clone();
    duplicate["files"].as_array_mut().unwrap().push(row);
    assert!(!accepts(&duplicate));
    let mut extra = good.clone();
    extra["untrusted"] = true.into();
    assert!(!accepts(&extra));
    let mut extra_row = good.clone();
    extra_row["files"][0]["untrusted"] = true.into();
    assert!(!accepts(&extra_row));
    let mut empty = good.clone();
    empty["files"][0]["bytes"] = 0.into();
    assert!(!accepts(&empty));
}
#[test]
fn duplicate_keys_utf8_and_compiled_hash_are_enforced() {
    let good = serde_json::to_string(&plan()).unwrap();
    let duplicate = good.replacen("\"schema\":", "\"schema\":\"wrong\",\"schema\":", 1);
    assert!(parse_install_plan(
        duplicate.as_bytes(),
        digest(duplicate.as_bytes()),
        "msi",
        "0.38.0"
    )
    .is_err());
    let nested = good.replacen("\"role\":", "\"role\":\"wrong\",\"role\":", 1);
    assert!(parse_install_plan(
        nested.as_bytes(),
        digest(nested.as_bytes()),
        "msi",
        "0.38.0"
    )
    .is_err());
    assert!(parse_install_plan(good.as_bytes(), [0; 32], "msi", "0.38.0").is_err());
    assert!(parse_install_plan(&[0xff], digest(&[0xff]), "msi", "0.38.0").is_err());
}
#[test]
fn paths_reject_traversal_aliases_ads_reserved_names_and_case_collision() {
    for path in [
        "",
        "/root",
        "../x",
        "licenses/../x",
        "licenses/./x",
        "C:/x",
        "licenses/a:b",
        "licenses/a\\b",
        "licenses/NUL.txt",
        "licenses/COM1",
        "licenses/FOO~1",
        "licenses/a.",
        "licenses/a ",
        "licenses//x",
        "licenses/x\0y",
    ] {
        assert!(!valid_member_path(path), "{path}");
    }
    let mut collision = plan();
    let mut row = collision["files"][4].clone();
    row["path"] = "licenses/winsmux/license".into();
    collision["files"].as_array_mut().unwrap().push(row);
    assert!(!accepts(&collision));
    let mut misplaced = plan();
    misplaced["files"][4]["path"] = "LICENSE".into();
    assert!(!accepts(&misplaced));
}
#[test]
fn internal_cli_has_no_missing_duplicate_unknown_or_positional_fallback() {
    let args: Vec<String> = [
        "msi-verify",
        "--root",
        "C:/installed",
        "--version",
        "0.38.0",
        "--plan-sha256",
        &"01".repeat(32),
        "--user-sid",
        "S-1-5-21-1",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    assert!(parse_msi_arguments(&args).is_ok());
    assert!(parse_msi_arguments(&args[..8]).is_err());
    for (index, value) in [
        (1, "--unknown"),
        (7, "--root"),
        (8, "arbitrary"),
        (6, "01"),
        (0, "nsis-install"),
    ] {
        let mut bad = args.clone();
        bad[index] = value.into();
        assert!(parse_msi_arguments(&bad).is_err());
    }
}
#[test]
fn probe_context_requires_one_uuid_pipe_and_owned_project() {
    let id = uuid::Uuid::new_v4().to_string();
    let project = std::env::temp_dir()
        .join(format!("winsmux-installer-{id}"))
        .join("project");
    let args = vec![
        "--project-dir".into(),
        project.to_str().unwrap().into(),
        "--winsmux-installer-probe".into(),
        id.clone(),
        "--winsmux-installer-pipe".into(),
        format!(r"\\.\pipe\winsmux-installer-{id}"),
    ];
    assert!(StartupProbeContext::parse(&args).unwrap().is_some());
    assert!(
        StartupProbeContext::parse(&["--project-dir".into(), "C:/ordinary".into()])
            .unwrap()
            .is_none()
    );
    for (index, value) in [
        (0, "--workspace"),
        (1, "C:/unrelated"),
        (3, "00000000-0000-0000-0000-000000000000"),
        (5, r"\\.\pipe\foreign"),
    ] {
        let mut bad = args.clone();
        bad[index] = value.into();
        assert!(StartupProbeContext::parse(&bad).is_err());
    }
    let mut duplicate = args.clone();
    duplicate.extend(["--winsmux-installer-probe".into(), id]);
    assert!(StartupProbeContext::parse(&duplicate).is_err());
}
#[cfg(windows)]
#[test]
fn wrong_actor_or_image_hash_cannot_launch_or_succeed() {
    let request = StartupVerifyRequest {
        gui_path: std::env::current_exe().unwrap(),
        expected_gui_sha256: [0; 32],
        expected_version: "0.38.0".into(),
        expected_actor_sid: "S-1-5-18".into(),
    };
    assert!(matches!(
        verify_desktop_startup(request),
        Err(DesktopInstallError::Actor) | Err(DesktopInstallError::Member)
    ));
}
