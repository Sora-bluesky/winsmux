use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const SOURCE_HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const CONTENT_A: &str = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const CONTENT_B: &str = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const CONTENT_C: &str = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const CONTEXT_REJECTION: &str = "winsmux: context pack rejected.\n";

fn base_yaml() -> String {
    include_str!("../../tests/fixtures/workspace-recipes/valid-v1.yaml").to_string()
}

fn context_pack_policy(max_files: usize, max_bytes: usize, max_evidence_refs: usize) -> String {
    format!(
        r#"
context-packs:
  review-pack:
    schema-version: 1
    include: [code-map, changed-files, tests, evidence-refs]
    limits:
      max-files: {max_files}
      max-bytes: {max_bytes}
      max-evidence-refs: {max_evidence_refs}
    privacy:
      raw-transcript: false
      prompt-bodies: false
      secrets: false
      private-local-paths: false
"#
    )
}

fn make_project(yaml_suffix: &str) -> tempfile::TempDir {
    let fixture = tempfile::tempdir().expect("create context-pack fixture");
    fs::write(
        fixture.path().join(".winsmux.yaml"),
        format!("{}{}", base_yaml(), yaml_suffix),
    )
    .expect("write workspace config");
    let runtime = fixture.path().join(".winsmux");
    fs::create_dir_all(&runtime).expect("create runtime fixture");
    fs::write(
        runtime.join("provider-capabilities.json"),
        include_str!("../../tests/fixtures/workspace-recipes/valid-v1.provider-capabilities.json"),
    )
    .expect("write provider capabilities");
    fixture
}

fn sample_input() -> serde_json::Value {
    serde_json::json!({
        "schema_version": 1,
        "source_head": SOURCE_HEAD,
        "code_map": [
            {"path": "core/src/workflow.rs", "content_sha256": CONTENT_A},
            {"path": "core/src/operator_cli.rs", "content_sha256": CONTENT_B}
        ],
        "changed_files": [
            {"path": "core/src/context_pack.rs", "status": "added", "content_sha256": CONTENT_C}
        ],
        "tests": [
            {"test_id": "context-pack-contract", "outcome": "passed", "evidence_ref": "evidence:task660/tests"}
        ],
        "evidence_refs": [
            "evidence:task660/preedit",
            "context:task660/source-map"
        ]
    })
}

fn permuted_input() -> serde_json::Value {
    serde_json::json!({
        "evidence_refs": [
            "context:task660/source-map",
            "evidence:task660/preedit"
        ],
        "tests": [
            {"evidence_ref": "evidence:task660/tests", "outcome": "passed", "test_id": "context-pack-contract"}
        ],
        "changed_files": [
            {"content_sha256": CONTENT_C, "status": "added", "path": "core/src/context_pack.rs"}
        ],
        "code_map": [
            {"content_sha256": CONTENT_B, "path": "core/src/operator_cli.rs"},
            {"content_sha256": CONTENT_A, "path": "core/src/workflow.rs"}
        ],
        "source_head": SOURCE_HEAD,
        "schema_version": 1
    })
}

fn workspace_plan_args(project: &Path) -> Vec<String> {
    vec![
        "workspace-plan".into(),
        "--recipe-id".into(),
        "bugfix-two-slot".into(),
        "--workflow-id".into(),
        "bugfix".into(),
        "--context-pack-id".into(),
        "review-pack".into(),
        "--context-pack-input".into(),
        "-".into(),
        "--json".into(),
        "--project-dir".into(),
        project.display().to_string(),
    ]
}

fn run_binary(args: &[String], stdin_bytes: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run winsmux binary");
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(stdin_bytes);
    }
    child.wait_with_output().expect("collect winsmux output")
}

fn run_pack(project: &Path, input: &serde_json::Value) -> Output {
    run_binary(
        &workspace_plan_args(project),
        serde_json::to_vec(input)
            .expect("serialize context input")
            .as_slice(),
    )
}

fn parse_success(output: &Output) -> serde_json::Value {
    assert!(
        output.status.success(),
        "workspace-plan public entry must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stderr.is_empty(),
        "accepted outcome must have empty stderr"
    );
    serde_json::from_slice(&output.stdout).expect("write_json must emit one JSON document")
}

fn sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("sha256:{:x}", hasher.finalize())
}

fn snapshot_tree(root: &Path) -> Vec<(String, Vec<u8>)> {
    fn collect(root: &Path, current: &Path, files: &mut Vec<(String, Vec<u8>)>) {
        let mut entries = fs::read_dir(current)
            .expect("read fixture tree")
            .map(|entry| entry.expect("read fixture entry"))
            .collect::<Vec<_>>();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let path = entry.path();
            if path.is_dir() {
                collect(root, &path, files);
            } else {
                let relative = path
                    .strip_prefix(root)
                    .expect("fixture path is beneath root")
                    .to_string_lossy()
                    .replace('\\', "/");
                files.push((relative, fs::read(path).expect("read fixture file")));
            }
        }
    }

    let mut files = Vec::new();
    collect(root, root, &mut files);
    files
}

fn assert_rejected(output: &Output, before: &[(String, Vec<u8>)], project: &Path) {
    assert!(!output.status.success(), "invalid context pack must reject");
    assert!(
        output.stdout.is_empty(),
        "rejected outcome must not reach write_json"
    );
    assert_eq!(
        String::from_utf8(output.stderr.clone()).expect("stderr must be UTF-8"),
        CONTEXT_REJECTION,
        "outcome_semantics must be one non-reflective typed rejection"
    );
    assert_eq!(
        snapshot_tree(project),
        before,
        "protected_sinks and durable_source bytes must remain unchanged"
    );
}

#[test]
fn cp01_public_preview_is_deterministic_and_side_effect_free() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let first = parse_success(&run_pack(fixture.path(), &sample_input()));
    let second = parse_success(&run_pack(fixture.path(), &permuted_input()));
    let first_pack = &first["context_pack"];
    let second_pack = &second["context_pack"];
    assert_eq!(
        first_pack["canonical_json"], second_pack["canonical_json"],
        "content_identity must ignore input ordering"
    );
    assert_eq!(
        first_pack["digest"], second_pack["digest"],
        "authority_producer must derive one digest from canonical bytes"
    );
    let canonical = first_pack["canonical_json"]
        .as_str()
        .expect("canonical_json must be a string");
    assert_eq!(
        first_pack["byte_count"],
        canonical.as_bytes().len(),
        "consumer must report exact UTF-8 byte length"
    );
    assert_eq!(
        first_pack["digest"],
        sha256(canonical.as_bytes()),
        "digest must bind exact canonical bytes"
    );
    assert_eq!(
        snapshot_tree(fixture.path()),
        before,
        "transport_liveness preview must not mutate project or runtime state"
    );
}

#[test]
fn cp02_count_limits_report_exact_group_omissions() {
    let fixture = make_project(&context_pack_policy(2, 262_144, 2));
    let mut input = sample_input();
    input["changed_files"] = serde_json::json!([
        {"path": "core/src/a.rs", "status": "modified", "content_sha256": CONTENT_A},
        {"path": "core/src/b.rs", "status": "modified", "content_sha256": CONTENT_B}
    ]);
    input["tests"] = serde_json::json!([
        {"test_id": "alpha-test", "outcome": "passed", "evidence_ref": "evidence:task660/alpha"},
        {"test_id": "beta-test", "outcome": "passed", "evidence_ref": "evidence:task660/beta"}
    ]);
    let before = snapshot_tree(fixture.path());
    let payload = parse_success(&run_pack(fixture.path(), &input));
    let canonical: serde_json::Value = serde_json::from_str(
        payload["context_pack"]["canonical_json"]
            .as_str()
            .expect("canonical body"),
    )
    .expect("canonical body JSON");
    assert_eq!(
        canonical["groups"]["code_map"]
            .as_array()
            .expect("code_map group")
            .len()
            + canonical["groups"]["changed_files"]
                .as_array()
                .expect("changed_files group")
                .len(),
        2,
        "max_files must count both path-bearing groups"
    );
    assert_eq!(
        canonical["omissions"]["changed_files"], 2,
        "postcondition must identify omitted changed files"
    );
    assert_eq!(
        canonical["omissions"]["evidence_refs"], 2,
        "postcondition must identify omitted top-level refs"
    );
    assert_eq!(
        canonical["omissions"]["omitted_by_bytes"], 0,
        "count-only overflow must not be attributed to byte pressure"
    );
    assert_eq!(
        snapshot_tree(fixture.path()),
        before,
        "count bounding leaves unrelated_state unchanged"
    );
}

#[test]
fn cp03_byte_limit_uses_deterministic_reverse_group_reduction() {
    let fixture = make_project(&context_pack_policy(100, 900, 50));
    let mut input = sample_input();
    input["evidence_refs"] = serde_json::json!([
        "evidence:task660/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "evidence:task660/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "evidence:task660/cccccccccccccccccccccccccccccccccccccccc"
    ]);
    let first = parse_success(&run_pack(fixture.path(), &input));
    let second = parse_success(&run_pack(fixture.path(), &input));
    let pack = &first["context_pack"];
    let canonical: serde_json::Value =
        serde_json::from_str(pack["canonical_json"].as_str().expect("canonical body"))
            .expect("canonical JSON");
    assert!(
        pack["byte_count"].as_u64().expect("byte count") <= 900,
        "max_bytes must bound emitted canonical bytes"
    );
    assert!(
        canonical["omissions"]["omitted_by_bytes"]
            .as_u64()
            .expect("byte omission count")
            > 0,
        "byte pressure must be explicit"
    );
    assert_eq!(
        first["context_pack"], second["context_pack"],
        "reverse group reduction must be deterministic"
    );
    assert_eq!(
        pack["digest"],
        sha256(pack["canonical_json"].as_str().unwrap().as_bytes()),
        "protected sink digest must match reduced body"
    );
}

#[test]
#[cfg(windows)]
fn cp04_metadata_only_manifest_round_trips_across_powershell_and_rust() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let payload = parse_success(&run_pack(fixture.path(), &sample_input()));
    let yaml =
        render_manifest_with_powershell(fixture.path(), &payload, "context-packs/review-pack.json");
    assert!(
        !yaml.contains("canonical_json")
            && !yaml.contains("core/src/workflow.rs")
            && !yaml.contains("prompt")
            && !yaml.contains("transcript"),
        "manifest protected sink must contain metadata only"
    );
    assert!(
        yaml.contains("context_packs:") && yaml.contains("durable_ref:"),
        "New-WinsmuxDeclarativeWorkspaceProjection must materialize bounded metadata"
    );
    fs::write(fixture.path().join(".winsmux").join("manifest.yaml"), yaml)
        .expect("write generated manifest fixture");
    let args = vec![
        "status".into(),
        "--json".into(),
        "--project-dir".into(),
        fixture.path().display().to_string(),
    ];
    let output = run_binary(&args, b"");
    assert!(
        output.status.success(),
        "WinsmuxManifest::from_yaml and LedgerSnapshot must consume metadata: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice::<serde_json::Value>(&output.stdout)
        .expect("Rust public status output must remain valid JSON");
}

#[test]
fn cp05_unselected_or_absent_context_pack_preserves_legacy_bytes() {
    let legacy = make_project("");
    let configured = make_project(&context_pack_policy(100, 262_144, 50));
    let legacy_args = |project: &Path| {
        vec![
            "workspace-plan".into(),
            "--recipe-id".into(),
            "bugfix-two-slot".into(),
            "--workflow-id".into(),
            "bugfix".into(),
            "--json".into(),
            "--project-dir".into(),
            project.display().to_string(),
        ]
    };
    let before = snapshot_tree(configured.path());
    let baseline = run_binary(&legacy_args(legacy.path()), b"");
    let unselected = run_binary(
        &legacy_args(configured.path()),
        br#"{"raw_transcript":"must-not-be-read"}"#,
    );
    assert!(baseline.status.success() && unselected.status.success());
    assert_eq!(
        baseline.stdout, unselected.stdout,
        "no explicit selector must preserve legacy write_json bytes"
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&unselected.stdout).expect("legacy output JSON");
    assert!(
        payload.get("context_pack").is_none(),
        "unselected policy must remain inert"
    );
    assert_eq!(
        snapshot_tree(configured.path()),
        before,
        "legacy path must preserve all project/runtime bytes"
    );
    let help = run_binary(&["workspace-plan".into(), "--help".into()], b"");
    let help_text = String::from_utf8(help.stdout).expect("workspace-plan help must be UTF-8");
    assert!(
        help.status.success()
            && help_text.contains("--context-pack-id <id>")
            && help_text.contains("--context-pack-input -"),
        "new opt-in public flags must be discoverable without changing legacy JSON"
    );
}

#[test]
fn cp06_cli_envelope_rejects_unpaired_duplicate_nonstdin_and_oversized_input() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let project = fixture.path().display().to_string();
    let cases = [
        vec![
            "workspace-plan".into(),
            "--recipe-id".into(),
            "bugfix-two-slot".into(),
            "--context-pack-id".into(),
            "review-pack".into(),
            "--json".into(),
            "--project-dir".into(),
            project.clone(),
        ],
        vec![
            "workspace-plan".into(),
            "--recipe-id".into(),
            "bugfix-two-slot".into(),
            "--context-pack-input".into(),
            "-".into(),
            "--json".into(),
            "--project-dir".into(),
            project.clone(),
        ],
        vec![
            "workspace-plan".into(),
            "--recipe-id".into(),
            "bugfix-two-slot".into(),
            "--context-pack-id".into(),
            "review-pack".into(),
            "--context-pack-id".into(),
            "review-pack".into(),
            "--context-pack-input".into(),
            "-".into(),
            "--json".into(),
            "--project-dir".into(),
            project.clone(),
        ],
        vec![
            "workspace-plan".into(),
            "--recipe-id".into(),
            "bugfix-two-slot".into(),
            "--context-pack-id".into(),
            "review-pack".into(),
            "--context-pack-input".into(),
            "input.json".into(),
            "--json".into(),
            "--project-dir".into(),
            project,
        ],
    ];
    for args in cases {
        assert_rejected(&run_binary(&args, b"{}"), &before, fixture.path());
    }
    let oversized = vec![b'x'; 4 * 1024 * 1024 + 1];
    assert_rejected(
        &run_binary(&workspace_plan_args(fixture.path()), &oversized),
        &before,
        fixture.path(),
    );
}

#[test]
fn cp07_policy_schema_and_privacy_fail_closed_without_reflection() {
    let cases = [
        "    schema-version: 2\n    include: [code-map]\n",
        "    schema-version: 1\n    include: [code-map, code-map]\n",
        "    schema-version: 1\n    include: [code-map]\n    limits:\n      max-files: 0\n",
        "    schema-version: 1\n    include: [code-map]\n    limits:\n      max-bytes: 1048577\n",
        "    schema-version: 1\n    include: [code-map]\n    privacy:\n      secrets: true\n",
        "    schema-version: 1\n    include: [code-map]\n    private-marker: secret-marker\n",
        "    schema-version: 1\n    include: [code-map]\n    privacy:\n      secret-marker: false\n",
    ];
    for body in cases {
        let suffix = format!("\ncontext-packs:\n  review-pack:\n{body}");
        let fixture = make_project(&suffix);
        let before = snapshot_tree(fixture.path());
        let output = run_pack(fixture.path(), &sample_input());
        assert_rejected(&output, &before, fixture.path());
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("secret-marker"),
            "policy rejection must not reflect private input"
        );
    }
}

#[test]
fn cp08_closed_input_schema_rejects_raw_or_oversized_fields() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let cases = [
        (
            "raw_transcript",
            serde_json::json!("secret-marker-transcript"),
        ),
        ("prompt_body", serde_json::json!("secret-marker-prompt")),
        ("secret", serde_json::json!("secret-marker-value")),
        ("provider_metadata", serde_json::json!({"hidden": true})),
        ("body", serde_json::json!("secret-marker-body")),
    ];
    for (key, value) in cases {
        let mut input = sample_input();
        input
            .as_object_mut()
            .expect("sample input object")
            .insert(key.into(), value);
        let output = run_pack(fixture.path(), &input);
        assert_rejected(&output, &before, fixture.path());
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("secret-marker"),
            "closed schema must not reflect rejected values"
        );
    }
    let mut unsupported = sample_input();
    unsupported["schema_version"] = serde_json::json!(2);
    assert_rejected(
        &run_pack(fixture.path(), &unsupported),
        &before,
        fixture.path(),
    );
    let mut oversized = sample_input();
    oversized["tests"][0]["test_id"] = serde_json::json!("x".repeat(257));
    assert_rejected(
        &run_pack(fixture.path(), &oversized),
        &before,
        fixture.path(),
    );
}

#[test]
fn cp09_private_or_escaping_paths_never_reach_output() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let paths = [
        "C:/Users/private/file.rs",
        "C:\\Users\\private\\file.rs",
        "/home/private/file.rs",
        "../private/file.rs",
        "core/../private/file.rs",
        ".git/config",
        ".winsmux/private.json",
        "//server/share/file.rs",
        "core/src/\nprivate.rs",
    ];
    for path in paths {
        let mut input = sample_input();
        input["code_map"][0]["path"] = serde_json::json!(path);
        let output = run_pack(fixture.path(), &input);
        assert_rejected(&output, &before, fixture.path());
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("private"),
            "private path must not be reflected"
        );
    }
}

#[test]
fn cp10_unattributed_or_invalid_identity_fields_fail_closed() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let mut cases = Vec::new();
    let mut input = sample_input();
    input["source_head"] = serde_json::json!("ABC");
    cases.push(input);
    let mut input = sample_input();
    input["code_map"][0]["content_sha256"] = serde_json::json!("sha256:ABC");
    cases.push(input);
    let mut input = sample_input();
    input["changed_files"][0]["status"] = serde_json::json!("copied");
    cases.push(input);
    let mut input = sample_input();
    input["tests"][0]["outcome"] = serde_json::json!("success");
    cases.push(input);
    let mut input = sample_input();
    input["tests"][0]["test_id"] = serde_json::json!("Invalid Test");
    cases.push(input);
    let mut input = sample_input();
    input["evidence_refs"][0] = serde_json::json!("file:C:/private");
    cases.push(input);
    let mut input = sample_input();
    input["tests"][0]
        .as_object_mut()
        .expect("test entry")
        .remove("evidence_ref");
    cases.push(input);
    for input in cases {
        assert_rejected(&run_pack(fixture.path(), &input), &before, fixture.path());
    }
}

#[test]
fn cp11_duplicate_canonical_identities_are_rejected_not_deduplicated() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let mut cases = Vec::new();
    let mut input = sample_input();
    let duplicate = input["code_map"][0].clone();
    input["code_map"].as_array_mut().unwrap().push(duplicate);
    cases.push(("exact code_map identity must reject", input));
    let mut input = sample_input();
    let duplicate = input["changed_files"][0].clone();
    input["changed_files"]
        .as_array_mut()
        .unwrap()
        .push(duplicate);
    cases.push(("exact changed_files identity must reject", input));
    let mut input = sample_input();
    let duplicate = input["tests"][0].clone();
    input["tests"].as_array_mut().unwrap().push(duplicate);
    cases.push(("exact test identity must reject", input));
    let mut input = sample_input();
    let duplicate = input["evidence_refs"][0].clone();
    input["evidence_refs"]
        .as_array_mut()
        .unwrap()
        .push(duplicate);
    cases.push(("exact evidence identity must reject", input));
    let mut input = sample_input();
    input["code_map"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "path": "Core/src/workflow.rs",
            "content_sha256": CONTENT_C
        }));
    cases.push(("case-folded code_map identity must reject", input));
    let mut input = sample_input();
    input["changed_files"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "path": "Core/src/context_pack.rs",
            "status": "deleted",
            "content_sha256": CONTENT_B
        }));
    cases.push(("case-folded changed_files identity must reject", input));
    for (identity_invariant, input) in cases {
        let output = run_pack(fixture.path(), &input);
        assert!(
            !output.status.success(),
            "{identity_invariant}: one Win32 identity cannot carry conflicting metadata"
        );
        assert_rejected(&output, &before, fixture.path());
    }
}

#[test]
fn cp12_metadata_only_body_that_cannot_fit_rejects_without_partial_output() {
    let fixture = make_project(&context_pack_policy(100, 1, 50));
    let before = snapshot_tree(fixture.path());
    let output = run_pack(fixture.path(), &sample_input());
    assert_rejected(&output, &before, fixture.path());
}

#[test]
#[cfg(windows)]
fn cp13_manifest_rejects_raw_fields_in_both_runtime_owners() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let mut plan = serde_json::json!({
        "config_fingerprint": CONTENT_A,
        "recipe_id": "bugfix-two-slot",
        "resolved_bindings": {},
        "context_pack": {
            "manifest_projection": {
                "pack_id": "review-pack",
                "schema_version": 1,
                "digest": CONTENT_B,
                "byte_count": 100,
                "source_head": SOURCE_HEAD,
                "policy_fingerprint": CONTENT_C,
                "limits": {"max_files": 100, "max_bytes": 262144, "max_evidence_refs": 50},
                "omissions": {"code_map": 0, "changed_files": 0, "tests": 0, "evidence_refs": 0, "omitted_by_bytes": 0},
                "privacy_result": "pass"
            }
        }
    });
    plan["context_pack"]["manifest_projection"]["canonical_json"] =
        serde_json::json!("secret-marker-body");
    let output = render_manifest_process(fixture.path(), &plan, "context-packs/review-pack.json");
    assert!(
        !output.status.success(),
        "PowerShell authority must reject unknown raw metadata"
    );
    assert!(
        output.stdout.is_empty(),
        "Save-WinsmuxManifest must not run"
    );
    assert!(
        !String::from_utf8_lossy(&output.stderr).contains("secret-marker"),
        "PowerShell rejection must not reflect raw body"
    );

    let invalid_yaml = format!(
        r#"version: 1
session:
  name: test
  project_dir: ''
  started: ''
  ended: ''
panes: {{}}
declarative_workspace:
  schema_version: 1
  config_fingerprint: {CONTENT_A}
  recipe_id: bugfix-two-slot
  resolved_bindings: {{}}
  context_packs:
    review-pack:
      schema_version: 1
      digest: {CONTENT_B}
      byte_count: 100
      source_head: {SOURCE_HEAD}
      policy_fingerprint: {CONTENT_C}
      limits:
        max_files: 100
        max_bytes: 262144
        max_evidence_refs: 50
      omissions:
        code_map: 0
        changed_files: 0
        tests: 0
        evidence_refs: 0
        omitted_by_bytes: 0
      privacy_result: pass
      durable_ref: context-packs/review-pack.json
      raw_transcript: secret-marker-transcript
"#
    );
    fs::write(
        fixture.path().join(".winsmux").join("manifest.yaml"),
        invalid_yaml,
    )
    .expect("write invalid manifest");
    let before = fs::read(fixture.path().join(".winsmux").join("manifest.yaml"))
        .expect("read invalid manifest");
    let args = vec![
        "status".into(),
        "--json".into(),
        "--project-dir".into(),
        fixture.path().display().to_string(),
    ];
    let status = run_binary(&args, b"");
    assert!(
        !status.status.success(),
        "Rust manifest consumer must reject"
    );
    assert!(
        status.stdout.is_empty(),
        "invalid manifest must not produce partial status"
    );
    assert!(
        !String::from_utf8_lossy(&status.stderr).contains("secret-marker"),
        "Rust manifest rejection must not reflect raw value"
    );
    assert_eq!(
        fs::read(fixture.path().join(".winsmux").join("manifest.yaml")).unwrap(),
        before,
        "preexisting manifest bytes remain unchanged"
    );
}

#[test]
fn cp14_win32_repository_path_aliases_fail_closed() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let cases = [
        ("code_map", "core/.git./config"),
        ("changed_files", "core/.winsmux./secret"),
        ("code_map", "core/NUL.txt"),
        ("changed_files", "reports/COM1.log"),
        ("code_map", "reports/public."),
    ];
    for (group, path) in cases {
        let mut input = sample_input();
        input[group][0]["path"] = serde_json::json!(path);
        assert_rejected(&run_pack(fixture.path(), &input), &before, fixture.path());
    }
    assert_eq!(
        snapshot_tree(fixture.path()),
        before,
        "Win32 repository path rejection must preserve project and runtime bytes"
    );
}

#[test]
fn cp15_win32_evidence_ref_aliases_fail_closed() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let cases = [
        ("test", "evidence:core/.git./config"),
        ("test", "context:core/.winsmux./secret"),
        ("top", "context-packs/nul.txt"),
        ("top", "evidence:reports/lpt1.log"),
        ("top", "context:reports/public."),
    ];
    for (field, evidence_ref) in cases {
        let mut input = sample_input();
        if field == "test" {
            input["tests"][0]["evidence_ref"] = serde_json::json!(evidence_ref);
        } else {
            input["evidence_refs"][0] = serde_json::json!(evidence_ref);
        }
        assert_rejected(&run_pack(fixture.path(), &input), &before, fixture.path());
    }
    assert_eq!(
        snapshot_tree(fixture.path()),
        before,
        "Win32 evidence ref rejection must preserve project and runtime bytes"
    );
}

#[test]
#[cfg(windows)]
fn cp16_powershell_public_refs_share_one_segment_identity_authority() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let plan = serde_json::json!({
        "config_fingerprint": CONTENT_A,
        "recipe_id": "bugfix-two-slot",
        "resolved_bindings": {},
        "context_pack": {
            "manifest_projection": {
                "pack_id": "review-pack",
                "schema_version": 1,
                "digest": CONTENT_B,
                "byte_count": 100,
                "source_head": SOURCE_HEAD,
                "policy_fingerprint": CONTENT_C,
                "limits": {"max_files": 100, "max_bytes": 262144, "max_evidence_refs": 50},
                "omissions": {"code_map": 0, "changed_files": 0, "tests": 0, "evidence_refs": 0, "omitted_by_bytes": 0},
                "privacy_result": "pass"
            }
        }
    });
    let runtime = fixture.path().join(".winsmux");
    let before = snapshot_tree(&runtime);
    let cases = [
        (
            "PowerShell DryRunPlanRef private alias must reject",
            "evidence:review/.winsmux./secret",
            "context-packs/review-pack.json",
        ),
        (
            "PowerShell DryRunPlanRef dot segment must reject",
            "evidence:review/./plan.json",
            "context-packs/review-pack.json",
        ),
        (
            "PowerShell DryRunPlanRef empty segment must reject",
            "evidence:review//plan.json",
            "context-packs/review-pack.json",
        ),
        (
            "PowerShell DryRunPlanRef reserved device must reject",
            "evidence:review/nul.txt",
            "context-packs/review-pack.json",
        ),
        (
            "PowerShell DryRunPlanRef trailing period must reject",
            "evidence:review/public.",
            "context-packs/review-pack.json",
        ),
        (
            "PowerShell ContextPackRef private alias must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/.winsmux./secret",
        ),
        (
            "PowerShell ContextPackRef dot segment must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/./plan.json",
        ),
        (
            "PowerShell ContextPackRef empty segment must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack//plan.json",
        ),
        (
            "PowerShell ContextPackRef reserved device must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/lpt1.log",
        ),
        (
            "PowerShell ContextPackRef trailing period must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/public.",
        ),
    ];
    for (segment_invariant, dry_run_ref, durable_ref) in cases {
        let output =
            render_manifest_process_with_refs(fixture.path(), &plan, dry_run_ref, durable_ref);
        assert!(!output.status.success(), "{segment_invariant}");
        assert!(
            output.stdout.is_empty(),
            "rejection must occur before projection or manifest serialization"
        );
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains(dry_run_ref)
                && !String::from_utf8_lossy(&output.stderr).contains(durable_ref),
            "PowerShell public reference rejection must not reflect an unsafe value"
        );
        assert_eq!(
            snapshot_tree(&runtime),
            before,
            "PowerShell rejection must preserve runtime bytes"
        );
    }
}

#[test]
#[cfg(windows)]
fn cp17_rust_manifest_public_refs_share_one_segment_identity_authority() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let manifest_path = fixture.path().join(".winsmux").join("manifest.yaml");
    let args = vec![
        "status".into(),
        "--json".into(),
        "--project-dir".into(),
        fixture.path().display().to_string(),
    ];
    let cases = [
        (
            "Rust dry_run_plan_ref private alias must reject",
            "evidence:review/.winsmux./secret",
            "context-packs/review-pack.json",
        ),
        (
            "Rust dry_run_plan_ref dot segment must reject",
            "evidence:review/./plan.json",
            "context-packs/review-pack.json",
        ),
        (
            "Rust dry_run_plan_ref empty segment must reject",
            "evidence:review//plan.json",
            "context-packs/review-pack.json",
        ),
        (
            "Rust dry_run_plan_ref reserved device must reject",
            "evidence:review/nul.txt",
            "context-packs/review-pack.json",
        ),
        (
            "Rust dry_run_plan_ref trailing period must reject",
            "evidence:review/public.",
            "context-packs/review-pack.json",
        ),
        (
            "Rust durable_ref private alias must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/.winsmux./secret",
        ),
        (
            "Rust durable_ref dot segment must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/./plan.json",
        ),
        (
            "Rust durable_ref empty segment must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack//plan.json",
        ),
        (
            "Rust durable_ref reserved device must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/lpt1.log",
        ),
        (
            "Rust durable_ref trailing period must reject",
            "evidence:workspace-plan.json",
            "context-packs/review-pack/public.",
        ),
    ];
    for (segment_invariant, dry_run_ref, durable_ref) in cases {
        let yaml = format!(
            r#"version: 1
session:
  name: test
  project_dir: ''
  started: ''
  ended: ''
panes: {{}}
declarative_workspace:
  schema_version: 1
  config_fingerprint: {CONTENT_A}
  recipe_id: bugfix-two-slot
  resolved_bindings: {{}}
  dry_run_plan_ref: {dry_run_ref}
  context_packs:
    review-pack:
      schema_version: 1
      digest: {CONTENT_B}
      byte_count: 100
      source_head: {SOURCE_HEAD}
      policy_fingerprint: {CONTENT_C}
      limits:
        max_files: 100
        max_bytes: 262144
        max_evidence_refs: 50
      omissions:
        code_map: 0
        changed_files: 0
        tests: 0
        evidence_refs: 0
        omitted_by_bytes: 0
      privacy_result: pass
      durable_ref: {durable_ref}
"#
        );
        fs::write(&manifest_path, yaml).expect("write Win32 alias manifest");
        let before = fs::read(&manifest_path).expect("read Win32 alias manifest");
        let output = run_binary(&args, b"");
        assert!(!output.status.success(), "{segment_invariant}");
        assert!(
            output.stdout.is_empty(),
            "invalid durable ref must not produce a public read payload"
        );
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains(dry_run_ref)
                && !String::from_utf8_lossy(&output.stderr).contains(durable_ref),
            "Rust public reference rejection must not reflect an unsafe value"
        );
        assert_eq!(
            fs::read(&manifest_path).unwrap(),
            before,
            "Rust manifest rejection must preserve durable bytes"
        );
    }
}

#[test]
#[cfg(windows)]
fn cp18_rust_context_pack_path_fields_enforce_exact_total_and_component_byte_edges() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());

    let repo_edge = "a".repeat(240);
    let repo_over = "a".repeat(241);
    assert_eq!(
        repo_edge.as_bytes().len(),
        240,
        "PF01/PF02 exact total and component byte edge must be 240"
    );
    for field in ["code_map", "changed_files"] {
        let mut input = sample_input();
        input[field][0]["path"] = serde_json::json!(repo_edge);
        parse_success(&run_pack(fixture.path(), &input));
        assert_eq!(
            snapshot_tree(fixture.path()),
            before,
            "PF01/PF02 exact path edge must preserve state"
        );

        let mut input = sample_input();
        input[field][0]["path"] = serde_json::json!(repo_over);
        let output = run_pack(fixture.path(), &input);
        assert!(
            !output.status.success(),
            "PF01/PF02 total and component byte edge+1 must reject"
        );
        assert_rejected(&output, &before, fixture.path());
    }

    let evidence_component_edge = format!("evidence:{}", "a".repeat(240));
    let evidence_component_over = format!("evidence:{}", "a".repeat(241));
    let evidence_total_edge = format!("evidence:{}/{}", "a".repeat(240), "b".repeat(6));
    let evidence_total_over = format!("evidence:{}/{}", "a".repeat(240), "b".repeat(7));
    assert_eq!(
        evidence_total_edge.as_bytes().len(),
        256,
        "PF03/PF04 exact total byte edge must be 256"
    );
    assert_eq!(
        evidence_component_edge
            .strip_prefix("evidence:")
            .unwrap()
            .split('/')
            .map(str::len)
            .max(),
        Some(240),
        "PF03/PF04 exact component byte edge must be 240"
    );
    let evidence_cases = [
        (
            &evidence_component_edge,
            true,
            "PF03/PF04 exact component byte edge must accept",
        ),
        (
            &evidence_component_over,
            false,
            "PF03/PF04 component byte edge+1 must reject",
        ),
        (
            &evidence_total_edge,
            true,
            "PF03/PF04 exact total byte edge must accept",
        ),
        (
            &evidence_total_over,
            false,
            "PF03/PF04 total byte edge+1 must reject",
        ),
    ];
    for field in ["test", "top"] {
        for (evidence_ref, should_accept, boundary_invariant) in evidence_cases {
            let mut input = sample_input();
            if field == "test" {
                input["tests"][0]["evidence_ref"] = serde_json::json!(evidence_ref);
            } else {
                input["evidence_refs"][0] = serde_json::json!(evidence_ref);
            }
            let output = run_pack(fixture.path(), &input);
            if should_accept {
                parse_success(&output);
                assert_eq!(
                    snapshot_tree(fixture.path()),
                    before,
                    "{boundary_invariant}: accepted preview must preserve state"
                );
            } else {
                assert!(!output.status.success(), "{boundary_invariant}");
                assert_rejected(&output, &before, fixture.path());
            }
        }
    }
}

#[test]
#[cfg(windows)]
fn cp19_powershell_public_refs_enforce_exact_total_and_component_byte_edges() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let evidence_component_edge = format!("evidence:{}", "a".repeat(240));
    let evidence_component_over = format!("evidence:{}", "a".repeat(241));
    let evidence_total_edge = format!("evidence:{}/{}", "a".repeat(240), "b".repeat(6));
    let evidence_total_over = format!("evidence:{}/{}", "a".repeat(240), "b".repeat(7));
    let plan = serde_json::json!({
        "config_fingerprint": CONTENT_A,
        "recipe_id": "bugfix-two-slot",
        "resolved_bindings": {},
        "context_pack": {
            "manifest_projection": {
                "pack_id": "review-pack",
                "schema_version": 1,
                "digest": CONTENT_B,
                "byte_count": 100,
                "source_head": SOURCE_HEAD,
                "policy_fingerprint": CONTENT_C,
                "limits": {"max_files": 100, "max_bytes": 262144, "max_evidence_refs": 50},
                "omissions": {"code_map": 0, "changed_files": 0, "tests": 0, "evidence_refs": 0, "omitted_by_bytes": 0},
                "privacy_result": "pass"
            }
        }
    });
    let context_component_edge = format!("context-packs/{}", "a".repeat(240));
    let context_component_over = format!("context-packs/{}", "a".repeat(241));
    let context_total_edge = format!("context-packs/{}/b", "a".repeat(240));
    let context_total_over = format!("context-packs/{}/bb", "a".repeat(240));
    assert_eq!(
        context_total_edge.as_bytes().len(),
        256,
        "PF06 exact total byte edge must be 256"
    );
    assert_eq!(
        context_component_edge
            .strip_prefix("context-packs/")
            .unwrap()
            .split('/')
            .map(str::len)
            .max(),
        Some(240),
        "PF06 exact component byte edge must be 240"
    );
    let powershell_cases = [
        (
            evidence_component_edge.as_str(),
            "context-packs/review-pack.json",
            true,
            "PF05 exact component byte edge must accept",
        ),
        (
            evidence_component_over.as_str(),
            "context-packs/review-pack.json",
            false,
            "PF05 component byte edge+1 must reject",
        ),
        (
            evidence_total_edge.as_str(),
            "context-packs/review-pack.json",
            true,
            "PF05 exact total byte edge must accept",
        ),
        (
            evidence_total_over.as_str(),
            "context-packs/review-pack.json",
            false,
            "PF05 total byte edge+1 must reject",
        ),
        (
            "evidence:workspace-plan.json",
            context_component_edge.as_str(),
            true,
            "PF06 exact component byte edge must accept",
        ),
        (
            "evidence:workspace-plan.json",
            context_component_over.as_str(),
            false,
            "PF06 component byte edge+1 must reject",
        ),
        (
            "evidence:workspace-plan.json",
            context_total_edge.as_str(),
            true,
            "PF06 exact total byte edge must accept",
        ),
        (
            "evidence:workspace-plan.json",
            context_total_over.as_str(),
            false,
            "PF06 total byte edge+1 must reject",
        ),
    ];
    let runtime_before = snapshot_tree(&fixture.path().join(".winsmux"));
    for (dry_run_ref, durable_ref, should_accept, boundary_invariant) in powershell_cases {
        let output =
            render_manifest_process_with_refs(fixture.path(), &plan, dry_run_ref, durable_ref);
        assert_eq!(
            snapshot_tree(&fixture.path().join(".winsmux")),
            runtime_before,
            "{boundary_invariant}: PowerShell boundary must preserve runtime bytes"
        );
        if should_accept {
            assert!(output.status.success(), "{boundary_invariant}");
            assert!(
                !output.stdout.is_empty(),
                "{boundary_invariant}: accepted projection must be complete"
            );
        } else {
            assert!(!output.status.success(), "{boundary_invariant}");
            assert!(
                output.stdout.is_empty(),
                "{boundary_invariant}: rejected projection must emit no YAML"
            );
        }
    }
}

#[test]
#[cfg(windows)]
fn cp20_rust_manifest_public_refs_enforce_exact_total_and_component_byte_edges() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let evidence_component_edge = format!("evidence:{}", "a".repeat(240));
    let evidence_component_over = format!("evidence:{}", "a".repeat(241));
    let evidence_total_edge = format!("evidence:{}/{}", "a".repeat(240), "b".repeat(6));
    let evidence_total_over = format!("evidence:{}/{}", "a".repeat(240), "b".repeat(7));
    let context_component_edge = format!("context-packs/{}", "a".repeat(240));
    let context_component_over = format!("context-packs/{}", "a".repeat(241));
    let context_total_edge = format!("context-packs/{}/b", "a".repeat(240));
    let context_total_over = format!("context-packs/{}/bb", "a".repeat(240));
    assert_eq!(
        evidence_total_edge.as_bytes().len(),
        256,
        "PF07 exact total byte edge must be 256"
    );
    assert_eq!(
        context_total_edge.as_bytes().len(),
        256,
        "PF08 exact total byte edge must be 256"
    );
    let manifest_path = fixture.path().join(".winsmux").join("manifest.yaml");
    let status_args = vec![
        "status".into(),
        "--json".into(),
        "--project-dir".into(),
        fixture.path().display().to_string(),
    ];
    let manifest_cases = [
        (
            evidence_component_edge.as_str(),
            "context-packs/review-pack.json",
            true,
            "PF07 exact component byte edge must accept",
        ),
        (
            evidence_component_over.as_str(),
            "context-packs/review-pack.json",
            false,
            "PF07 component byte edge+1 must reject",
        ),
        (
            evidence_total_edge.as_str(),
            "context-packs/review-pack.json",
            true,
            "PF07 exact total byte edge must accept",
        ),
        (
            evidence_total_over.as_str(),
            "context-packs/review-pack.json",
            false,
            "PF07 total byte edge+1 must reject",
        ),
        (
            "evidence:workspace-plan.json",
            context_component_edge.as_str(),
            true,
            "PF08 exact component byte edge must accept",
        ),
        (
            "evidence:workspace-plan.json",
            context_component_over.as_str(),
            false,
            "PF08 component byte edge+1 must reject",
        ),
        (
            "evidence:workspace-plan.json",
            context_total_edge.as_str(),
            true,
            "PF08 exact total byte edge must accept",
        ),
        (
            "evidence:workspace-plan.json",
            context_total_over.as_str(),
            false,
            "PF08 total byte edge+1 must reject",
        ),
    ];
    for (dry_run_ref, durable_ref, should_accept, boundary_invariant) in manifest_cases {
        let yaml = format!(
            r#"version: 1
session:
  name: test
  project_dir: ''
  started: ''
  ended: ''
panes: {{}}
declarative_workspace:
  schema_version: 1
  config_fingerprint: {CONTENT_A}
  recipe_id: bugfix-two-slot
  resolved_bindings: {{}}
  dry_run_plan_ref: {dry_run_ref}
  context_packs:
    review-pack:
      schema_version: 1
      digest: {CONTENT_B}
      byte_count: 100
      source_head: {SOURCE_HEAD}
      policy_fingerprint: {CONTENT_C}
      limits:
        max_files: 100
        max_bytes: 262144
        max_evidence_refs: 50
      omissions:
        code_map: 0
        changed_files: 0
        tests: 0
        evidence_refs: 0
        omitted_by_bytes: 0
      privacy_result: pass
      durable_ref: {durable_ref}
"#
        );
        fs::write(&manifest_path, yaml).expect("write boundary manifest");
        let manifest_before = fs::read(&manifest_path).expect("read boundary manifest");
        let output = run_binary(&status_args, b"");
        assert_eq!(
            fs::read(&manifest_path).unwrap(),
            manifest_before,
            "{boundary_invariant}: Rust manifest read must preserve durable bytes"
        );
        if should_accept {
            assert!(output.status.success(), "{boundary_invariant}");
            assert!(
                !output.stdout.is_empty(),
                "{boundary_invariant}: accepted manifest read must emit one payload"
            );
        } else {
            assert!(!output.status.success(), "{boundary_invariant}");
            assert!(
                output.stdout.is_empty(),
                "{boundary_invariant}: rejected manifest read must emit no payload"
            );
        }
    }
}

#[test]
fn cp21_public_string_grammars_reject_path_shapes_before_output() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let unsafe_test_ids = [
        "c:/users/alice/private-test",
        "c:users-private-test",
        "suite/../../private-test",
        "suite/.winsmux/private-test",
        "module:case",
        "module::::case",
        "module::.winsmux",
        "module::case/child",
    ];
    let mut admitted_path_shapes = Vec::new();

    for test_id in unsafe_test_ids {
        let mut input = sample_input();
        input["tests"][0]["test_id"] = serde_json::json!(test_id);
        let output = run_pack(fixture.path(), &input);
        if output.status.success() {
            assert!(
                output.stderr.is_empty(),
                "an admitted path-shaped test ID must not produce a mixed outcome"
            );
            let payload: serde_json::Value =
                serde_json::from_slice(&output.stdout).expect("accepted output must be JSON");
            let canonical_json = payload["context_pack"]["canonical_json"]
                .as_str()
                .expect("accepted output must include canonical_json");
            let canonical: serde_json::Value =
                serde_json::from_str(canonical_json).expect("canonical_json must parse");
            assert_eq!(
                canonical["groups"]["tests"][0]["test_id"],
                serde_json::json!(test_id),
                "an admitted path-shaped test ID must be observed at the protected output sink"
            );
            assert_eq!(
                canonical["privacy_result"],
                serde_json::json!("pass"),
                "privacy_result must expose the false privacy claim for RED evidence"
            );
            assert_eq!(
                snapshot_tree(fixture.path()),
                before,
                "project_runtime_bytes must remain unchanged while collecting RED cases"
            );
            admitted_path_shapes.push(test_id.to_string());
        } else {
            assert_rejected(&output, &before, fixture.path());
        }
    }

    let mut invalid_pack_args = workspace_plan_args(fixture.path());
    let pack_id_index = invalid_pack_args
        .iter()
        .position(|arg| arg == "--context-pack-id")
        .expect("public entry must carry the pack ID")
        + 1;
    invalid_pack_args[pack_id_index] = "review/pack".into();
    assert_rejected(
        &run_binary(
            &invalid_pack_args,
            serde_json::to_vec(&sample_input())
                .expect("serialize invalid pack input")
                .as_slice(),
        ),
        &before,
        fixture.path(),
    );
    assert!(
        snapshot_tree(fixture.path()) == before,
        "pack ID path shape must reject before write_json"
    );

    let mut invalid_changed_digest = sample_input();
    invalid_changed_digest["changed_files"][0]["content_sha256"] = serde_json::json!("sha256:ABC");
    assert_rejected(
        &run_pack(fixture.path(), &invalid_changed_digest),
        &before,
        fixture.path(),
    );
    assert!(
        snapshot_tree(fixture.path()) == before,
        "changed-file content identity must reject before write_json"
    );

    let mut valid = sample_input();
    valid["tests"][0]["test_id"] = serde_json::json!("module.name::case_1");
    let first = parse_success(&run_pack(fixture.path(), &valid));
    let second = parse_success(&run_pack(fixture.path(), &valid));
    let first_canonical: serde_json::Value = serde_json::from_str(
        first["context_pack"]["canonical_json"]
            .as_str()
            .expect("valid logical namespace must include canonical_json"),
    )
    .expect("valid logical namespace canonical_json must parse");
    assert_eq!(
        first_canonical["groups"]["tests"][0]["test_id"],
        serde_json::json!("module.name::case_1"),
        "valid logical namespace must remain accepted"
    );
    assert_eq!(
        first["context_pack"]["canonical_json"], second["context_pack"]["canonical_json"],
        "valid logical namespace must preserve deterministic bytes"
    );
    assert_eq!(
        first["context_pack"]["digest"], second["context_pack"]["digest"],
        "valid logical namespace must preserve deterministic digest"
    );
    assert_eq!(
        snapshot_tree(fixture.path()),
        before,
        "project_runtime_bytes must remain unchanged for valid logical IDs"
    );

    assert!(
        admitted_path_shapes.is_empty(),
        "public string grammar must reject every path-shaped value before write_json; admitted={admitted_path_shapes:?}"
    );
}

#[cfg(windows)]
fn render_manifest_with_powershell(
    project: &Path,
    plan: &serde_json::Value,
    durable_ref: &str,
) -> String {
    let output = render_manifest_process(project, plan, durable_ref);
    assert!(
        output.status.success(),
        "PowerShell manifest projection failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("manifest YAML must be UTF-8")
}

#[cfg(windows)]
fn render_manifest_process(project: &Path, plan: &serde_json::Value, durable_ref: &str) -> Output {
    render_manifest_process_with_refs(project, plan, "", durable_ref)
}

#[cfg(windows)]
fn render_manifest_process_with_refs(
    project: &Path,
    plan: &serde_json::Value,
    dry_run_ref: &str,
    durable_ref: &str,
) -> Output {
    let plan_path = project.join("task660-plan.json");
    let script_path = project.join("task660-render.ps1");
    fs::write(
        &plan_path,
        serde_json::to_vec(plan).expect("serialize plan fixture"),
    )
    .expect("write plan fixture");
    let manifest_script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core has repository parent")
        .join("winsmux-core")
        .join("scripts")
        .join("manifest.ps1");
    let script = format!(
        r#"[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. '{}'
$plan = Get-Content -Raw -LiteralPath '{}' | ConvertFrom-Json
$projection = New-WinsmuxDeclarativeWorkspaceProjection -Plan $plan -DryRunPlanRef '{}' -ContextPackRef '{}'
$manifest = [ordered]@{{
  version = 1
  saved_at = '2026-07-26T00:00:00Z'
  session = [ordered]@{{ name = 'test'; project_dir = ''; started = ''; ended = '' }}
  panes = [ordered]@{{}}
  tasks = [ordered]@{{ queued = @(); in_progress = @(); completed = @() }}
  worktrees = [ordered]@{{}}
  declarative_workspace = $projection
}}
[Console]::Out.Write((ConvertTo-ManifestYaml -Manifest $manifest))
"#,
        manifest_script.display().to_string().replace('\'', "''"),
        plan_path.display().to_string().replace('\'', "''"),
        dry_run_ref.replace('\'', "''"),
        durable_ref.replace('\'', "''"),
    );
    fs::write(&script_path, script).expect("write PowerShell fixture");
    Command::new("pwsh")
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run PowerShell manifest projection")
}
