use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const SOURCE_HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const CONTENT_A: &str = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const CONTENT_B: &str = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const CONTENT_C: &str = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const CONTEXT_REJECTION: &str = "winsmux: context pack rejected.\n";
const ARCHITECTURE_DOC: &str =
    include_str!("../../docs/project/v03629-declarative-workspace-architecture.md");
const RUNNABLE_CONTEXT_PACK_V1_START: &str = "<!-- TASK660-RUNNABLE-CONTEXT-PACK-V1:START -->";
const RUNNABLE_CONTEXT_PACK_V1_END: &str = "<!-- TASK660-RUNNABLE-CONTEXT-PACK-V1:END -->";

fn base_yaml() -> String {
    include_str!("../../tests/fixtures/workspace-recipes/valid-v1.yaml").to_string()
}

fn documented_context_pack_policy_v1() -> &'static str {
    assert_eq!(
        ARCHITECTURE_DOC
            .matches(RUNNABLE_CONTEXT_PACK_V1_START)
            .count(),
        1,
        "architecture doc must contain exactly one runnable context-pack v1 start marker"
    );
    assert_eq!(
        ARCHITECTURE_DOC
            .matches(RUNNABLE_CONTEXT_PACK_V1_END)
            .count(),
        1,
        "architecture doc must contain exactly one runnable context-pack v1 end marker"
    );
    let (_, after_start) = ARCHITECTURE_DOC
        .split_once(RUNNABLE_CONTEXT_PACK_V1_START)
        .expect("architecture doc must contain the runnable context-pack v1 start marker");
    let (marked_block, _) = after_start
        .split_once(RUNNABLE_CONTEXT_PACK_V1_END)
        .expect("architecture doc must contain the runnable context-pack v1 end marker");
    let fenced_block = marked_block.trim();
    let yaml = fenced_block
        .strip_prefix("```yaml\r\n")
        .or_else(|| fenced_block.strip_prefix("```yaml\n"))
        .expect("runnable context-pack v1 must start with a YAML fence");
    yaml.strip_suffix("\r\n```")
        .or_else(|| yaml.strip_suffix("\n```"))
        .expect("runnable context-pack v1 must end with a YAML fence")
}

fn context_pack_policy(max_files: usize, max_bytes: usize, max_evidence_refs: usize) -> String {
    context_pack_policy_for_id("review-pack", max_files, max_bytes, max_evidence_refs)
}

fn context_pack_policy_for_id(
    pack_id: &str,
    max_files: usize,
    max_bytes: usize,
    max_evidence_refs: usize,
) -> String {
    format!(
        r#"
context-packs:
  {pack_id}:
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
    workspace_plan_args_with_pack_id(project, "review-pack")
}

fn workspace_plan_args_with_pack_id(project: &Path, pack_id: &str) -> Vec<String> {
    vec![
        "workspace-plan".into(),
        "--recipe-id".into(),
        "bugfix-two-slot".into(),
        "--workflow-id".into(),
        "bugfix".into(),
        "--context-pack-id".into(),
        pack_id.into(),
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

fn run_binary_holding_stdin(args: &[String]) -> (Output, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run winsmux binary with held stdin");
    let held_stdin = child.stdin.take().expect("hold child stdin open");
    let deadline = Instant::now() + Duration::from_secs(2);
    let exited_while_stdin_open = loop {
        if child
            .try_wait()
            .expect("poll winsmux binary with held stdin")
            .is_some()
        {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        thread::sleep(Duration::from_millis(20));
    };
    drop(held_stdin);
    if !exited_while_stdin_open {
        let _ = child.kill();
    }
    (
        child
            .wait_with_output()
            .expect("collect winsmux output with held stdin"),
        exited_while_stdin_open,
    )
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

    let mut pack_id_boundary_violations = Vec::new();
    let bot_example_args = vec![
        "workspace-plan".into(),
        "--context-pack-id".into(),
        "--json".into(),
        "--context-pack-input".into(),
        "-".into(),
    ];
    let bot_example = run_binary(&bot_example_args, b"");
    if bot_example.status.success()
        || !bot_example.stdout.is_empty()
        || String::from_utf8_lossy(&bot_example.stderr) != CONTEXT_REJECTION
        || snapshot_tree(fixture.path()) != before
    {
        pack_id_boundary_violations.push(format!(
            "option-token pack ID reached legacy outcome: status={:?}, stderr={:?}",
            bot_example.status,
            String::from_utf8_lossy(&bot_example.stderr)
        ));
    }

    let mut held_stdin_args = workspace_plan_args(fixture.path());
    let held_pack_id_index = held_stdin_args
        .iter()
        .position(|arg| arg == "--context-pack-id")
        .expect("public entry must carry the held-stdin pack ID")
        + 1;
    held_stdin_args[held_pack_id_index] = "--json".into();
    let (held_stdin_output, exited_while_stdin_open) = run_binary_holding_stdin(&held_stdin_args);
    if !exited_while_stdin_open
        || held_stdin_output.status.success()
        || !held_stdin_output.stdout.is_empty()
        || String::from_utf8_lossy(&held_stdin_output.stderr) != CONTEXT_REJECTION
        || snapshot_tree(fixture.path()) != before
    {
        pack_id_boundary_violations.push(format!(
            "invalid pack ID reached snapshot or stdin: exited_while_stdin_open={exited_while_stdin_open}, status={:?}, stderr={:?}",
            held_stdin_output.status,
            String::from_utf8_lossy(&held_stdin_output.stderr)
        ));
    }

    let poisoned_project = tempfile::tempdir().expect("create poisoned project boundary");
    let poisoned_before = snapshot_tree(poisoned_project.path());
    let mut poisoned_args = workspace_plan_args(poisoned_project.path());
    let poisoned_pack_id_index = poisoned_args
        .iter()
        .position(|arg| arg == "--context-pack-id")
        .expect("public entry must carry the poisoned-project pack ID")
        + 1;
    poisoned_args[poisoned_pack_id_index] = "review/pack".into();
    let poisoned_output = run_binary(
        &poisoned_args,
        serde_json::to_vec(&sample_input())
            .expect("serialize poisoned-project pack input")
            .as_slice(),
    );
    if poisoned_output.status.success()
        || !poisoned_output.stdout.is_empty()
        || String::from_utf8_lossy(&poisoned_output.stderr) != CONTEXT_REJECTION
        || snapshot_tree(poisoned_project.path()) != poisoned_before
    {
        pack_id_boundary_violations.push(format!(
            "invalid pack ID reached poisoned project snapshot: status={:?}, stderr={:?}",
            poisoned_output.status,
            String::from_utf8_lossy(&poisoned_output.stderr)
        ));
    }
    assert!(
        pack_id_boundary_violations.is_empty(),
        "pack ID grammar must reject before legacy parsing, project snapshot, stdin, and write_json; violations={pack_id_boundary_violations:?}"
    );

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

#[test]
fn cp22_rust_manifest_context_pack_persistence_is_unsupported() {
    let manifest_fixture = make_project("");
    let manifest_path = manifest_fixture
        .path()
        .join(".winsmux")
        .join("manifest.yaml");
    let status_args = vec![
        "status".into(),
        "--json".into(),
        "--project-dir".into(),
        manifest_fixture.path().display().to_string(),
    ];
    let removed_section = ["context_", "packs"].concat();
    let manifest_yaml = format!(
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
  recipe_id: review-workspace
  resolved_bindings: {{}}
  {removed_section}:
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
"#
    );
    fs::write(&manifest_path, &manifest_yaml).expect("write removed-surface manifest");
    let manifest_before = fs::read(&manifest_path).expect("read removed-surface manifest");
    let output = run_binary(&status_args, b"");
    let mut violations = Vec::new();
    if output.status.success() {
        violations.push("hand-authored context-pack persistence reached public read".to_string());
    }
    if !output.stdout.is_empty() {
        violations.push(format!(
            "removed manifest surface emitted {} stdout bytes",
            output.stdout.len()
        ));
    }
    if fs::read(&manifest_path).unwrap() != manifest_before {
        violations.push("manifest bytes changed during removed-surface rejection".to_string());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains(CONTENT_B) || stderr.contains("context-packs/review-pack.json") {
        violations.push("removed manifest metadata was reflected by rejection".to_string());
    }
    assert!(
        violations.is_empty(),
        "hand-authored context-pack persistence must reject before public read output; \
         manifest bytes must remain unchanged; violations={violations:?}"
    );
}

#[test]
#[cfg(windows)]
fn cp23_powershell_context_pack_persistence_is_unsupported() {
    let producer = make_project(&context_pack_policy(100, 262_144, 50));
    let producer_before = snapshot_tree(producer.path());
    let producer_plan = parse_success(&run_pack(producer.path(), &sample_input()));
    assert_eq!(
        snapshot_tree(producer.path()),
        producer_before,
        "public producer must preserve project and runtime bytes"
    );
    let mut fabricated_plan = producer_plan.clone();
    fabricated_plan["context_pack"]
        .as_object_mut()
        .expect("context_pack object")
        .remove("canonical_json");
    fabricated_plan["context_pack"]
        .as_object_mut()
        .expect("context_pack object")
        .remove("digest");
    fabricated_plan["context_pack"]
        .as_object_mut()
        .expect("context_pack object")
        .remove("byte_count");

    let cases = [
        ("producer-payload", producer_plan),
        ("fabricated-projection-only", fabricated_plan),
    ];
    let mut violations = Vec::new();
    for (case_name, plan) in cases {
        let fixture = make_project("");
        let (output, before, after) = render_manifest_process_with_refs_and_state(
            fixture.path(),
            &plan,
            "",
            "context-packs/review-pack.json",
        );
        if output.status.success() || !output.stdout.is_empty() {
            violations.push(format!(
                "{case_name} reached projection output: status={:?}, stdout_bytes={}",
                output.status,
                output.stdout.len()
            ));
        }
        if before != after {
            violations.push(format!(
                "{case_name} changed runtime bytes before old-path rejection"
            ));
        }
    }
    assert!(
        violations.is_empty(),
        "old PowerShell context-pack persistence entry must reject before projection, YAML, or save; \
         runtime bytes must remain unchanged; violations={violations:?}"
    );
}

#[test]
fn cp24_public_context_pack_envelope_is_canonical_only() {
    let fixture = make_project(&context_pack_policy(100, 262_144, 50));
    let before = snapshot_tree(fixture.path());
    let payload = parse_success(&run_pack(fixture.path(), &sample_input()));
    let pack = payload["context_pack"]
        .as_object()
        .expect("public context_pack must be an object");
    let mut actual_keys = pack.keys().cloned().collect::<Vec<_>>();
    actual_keys.sort();
    let expected_keys = vec![
        "byte_count".to_string(),
        "canonical_json".to_string(),
        "digest".to_string(),
    ];
    let canonical = pack["canonical_json"]
        .as_str()
        .expect("canonical_json must be a UTF-8 string");
    let mut violations = Vec::new();
    if actual_keys != expected_keys {
        violations.push(format!(
            "public context-pack key set is {actual_keys:?}, expected {expected_keys:?}"
        ));
    }
    if pack["digest"] != serde_json::json!(sha256(canonical.as_bytes())) {
        violations.push("digest is not derived from exact canonical UTF-8 bytes".to_string());
    }
    if pack["byte_count"] != serde_json::json!(canonical.len()) {
        violations.push("byte_count is not the exact canonical UTF-8 byte length".to_string());
    }
    if snapshot_tree(fixture.path()) != before {
        violations.push("public preview changed project or runtime bytes".to_string());
    }
    assert!(
        violations.is_empty(),
        "public context-pack envelope must contain only canonical_json, digest, and byte_count; \
         rejection emits no public output; rejection preserves durable state bytes; \
         project and runtime bytes must remain unchanged; violations={violations:?}"
    );
}

#[test]
fn cp25_documented_task660_contract_matches_public_preview_and_excludes_persistence() {
    let documented_policy = documented_context_pack_policy_v1();
    let fixture = make_project(documented_policy);
    let before = snapshot_tree(fixture.path());
    let payload = parse_success(&run_pack(fixture.path(), &sample_input()));
    let pack = payload["context_pack"]
        .as_object()
        .expect("documented public context_pack must be an object");
    let mut actual_keys = pack.keys().cloned().collect::<Vec<_>>();
    actual_keys.sort();
    let expected_keys = vec![
        "byte_count".to_string(),
        "canonical_json".to_string(),
        "digest".to_string(),
    ];
    let canonical = pack["canonical_json"]
        .as_str()
        .expect("documented canonical_json must be a UTF-8 string");
    let stale_claims = [
        "The manifest stores only pack ID",
        "metadata-only PowerShell/Rust manifest projection",
        "context-pack metadata round-trips",
        "TASK-662 owns any future verified cross-runtime persistence contract",
    ];
    let workflow_context_ref_claim = ["context", "_pack_", "refs: [context-pack:...]"].concat();
    let task660_section = ARCHITECTURE_DOC
        .split_once("### 6.3 TASK-660: repository context package")
        .expect("architecture doc must contain the TASK-660 section")
        .1
        .split_once("### 6.4 TASK-661: templates, gallery, and migration path")
        .expect("TASK-660 section must end before TASK-661")
        .0;
    let task662_section = ARCHITECTURE_DOC
        .split_once("### 6.5 TASK-662: workflow pre-release gate")
        .expect("architecture doc must contain the TASK-662 section")
        .1;

    let mut violations = Vec::new();
    if actual_keys != expected_keys {
        violations.push(format!(
            "documented public context-pack key set is {actual_keys:?}, expected {expected_keys:?}"
        ));
    }
    if pack["digest"] != serde_json::json!(sha256(canonical.as_bytes())) {
        violations
            .push("documented digest is not derived from exact canonical UTF-8 bytes".to_string());
    }
    if pack["byte_count"] != serde_json::json!(canonical.len()) {
        violations
            .push("documented byte_count is not the exact canonical UTF-8 byte length".to_string());
    }
    for stale_claim in stale_claims {
        if ARCHITECTURE_DOC.contains(stale_claim) {
            violations.push(format!(
                "architecture doc retains stale persistence claim: {stale_claim}"
            ));
        }
    }
    if ARCHITECTURE_DOC.contains(&workflow_context_ref_claim) {
        violations.push("current workflow manifest example retains a context-pack ref".to_string());
    }
    for required_claim in [
        "read-only context-pack preview",
        "does not persist the context-pack result",
        "canonical_json",
        "byte_count",
    ] {
        if !task660_section.contains(required_claim) {
            violations.push(format!(
                "TASK-660 section is missing current contract claim: {required_claim}"
            ));
        }
    }
    if !task662_section.contains("does not implement context-pack persistence") {
        violations.push(
            "TASK-662 section does not exclude context-pack persistence implementation".to_string(),
        );
    }
    if !ARCHITECTURE_DOC
        .contains("Existing ledger context-pack references are a separate pre-existing mechanism")
    {
        violations.push(
            "architecture doc does not distinguish the existing ledger reference mechanism"
                .to_string(),
        );
    }
    if snapshot_tree(fixture.path()) != before {
        violations.push("documented preview changed project or runtime bytes".to_string());
    }
    assert!(
        violations.is_empty(),
        "documented TASK-660 contract must run through the public context-pack entry, \
         expose only canonical_json, digest, and byte_count, exclude persistence ownership, \
         and keep project and runtime bytes unchanged; violations={violations:?}"
    );
}

#[cfg(windows)]
fn render_manifest_process_with_refs_and_state(
    project: &Path,
    plan: &serde_json::Value,
    dry_run_ref: &str,
    durable_ref: &str,
) -> (Output, Vec<(String, Vec<u8>)>, Vec<(String, Vec<u8>)>) {
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
    let removed_parameter = ["-Context", "PackRef"].concat();
    let script = format!(
        r#"[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. '{}'
$plan = Get-Content -Raw -LiteralPath '{}' | ConvertFrom-Json
$projection = New-WinsmuxDeclarativeWorkspaceProjection -Plan $plan -DryRunPlanRef '{}' {} '{}'
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
        removed_parameter,
        durable_ref.replace('\'', "''"),
    );
    fs::write(&script_path, script).expect("write PowerShell fixture");
    let before = snapshot_tree(project);
    let output = Command::new("pwsh")
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run PowerShell manifest projection");
    let after = snapshot_tree(project);
    (output, before, after)
}
