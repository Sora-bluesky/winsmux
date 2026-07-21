use std::fs;
use std::io::Write as _;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[allow(dead_code)]
#[rustfmt::skip]
#[path = "../src/workspace_project_settings.rs"]
mod canonical_project_settings_reader;

#[allow(dead_code)]
#[path = "../src/workspace_recipe.rs"]
mod workspace_recipe;

fn run_project_settings_render(input: &[u8], extra_args: &[&str]) -> std::process::Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_winsmux"));
    command
        .arg("project-settings-render")
        .args(extra_args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn project settings renderer");
    child
        .stdin
        .take()
        .expect("renderer stdin")
        .write_all(input)
        .expect("write renderer input");
    child.wait_with_output().expect("wait for renderer")
}

fn render_payload(original_yaml: &str, desired_yaml: &str, owned_keys: &[&str]) -> Vec<u8> {
    let desired_settings = serde_yaml::from_str::<serde_json::Value>(desired_yaml)
        .expect("desired renderer settings should parse as typed JSON-compatible YAML");
    serde_json::to_vec(&serde_json::json!({
        "original_yaml": original_yaml,
        "desired_settings": desired_settings,
        "owned_keys": owned_keys,
        "nested_contract": {
            "agent_slots": {
                "identity_key": "slot_id",
                "owned_keys": [
                    "slot_id", "runtime_role", "agent", "model", "model_source",
                    "reasoning_effort", "prompt_transport", "mcp_mode", "auth_mode",
                    "worktree_mode", "worker_backend", "execution_profile", "worker_role",
                    "pane_title", "fallback_model"
                ],
                "aliases": { "backend": "worker_backend", "role": "worker_role" }
            },
            "roles": {
                "owned_keys": [
                    "agent", "model", "model_source", "reasoning_effort",
                    "prompt_transport", "auth_mode"
                ]
            }
        }
    }))
    .expect("serialize renderer payload")
}

fn legacy_render_payload(original_yaml: &str, desired_yaml: &str, owned_keys: &[&str]) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "original_yaml": original_yaml,
        "desired_yaml": desired_yaml,
        "owned_keys": owned_keys,
        "nested_contract": {
            "agent_slots": {
                "identity_key": "slot_id",
                "owned_keys": ["slot_id"],
                "aliases": {}
            },
            "roles": { "owned_keys": [] }
        }
    }))
    .expect("serialize legacy renderer payload")
}

fn yaml_mapping(yaml: &[u8]) -> serde_yaml::Mapping {
    serde_yaml::from_slice::<serde_yaml::Value>(yaml)
        .expect("renderer output should parse")
        .as_mapping()
        .expect("renderer output should be a mapping")
        .clone()
}

#[test]
fn project_settings_render_preserves_block_comments_and_unknown_fields() {
    let original = "# heading\n'unknown-key': 'keep' # keep-comment\nworkspace-recipes:\n  old: value\ndrop-me: true\n";
    let desired = "workspace_recipes:\n  new: value\nconfig_version: 1\n";
    let input = render_payload(
        original,
        desired,
        &["workspace-recipes", "config-version", "drop-me"],
    );
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.starts_with("# heading\n'unknown-key': 'keep' # keep-comment\n"));
    assert!(text.contains("workspace-recipes:"));
    assert!(!text.contains("old: value"));
    assert!(!text.contains("drop-me:"));

    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(
        mapping.get(serde_yaml::Value::String("unknown-key".into())),
        Some(&serde_yaml::Value::String("keep".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("config_version".into())),
        Some(&serde_yaml::Value::Number(1.into()))
    );
    assert_eq!(
        mapping
            .get(serde_yaml::Value::String("workspace-recipes".into()))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|workspace| { workspace.get(serde_yaml::Value::String("new".into())) }),
        Some(&serde_yaml::Value::String("value".into()))
    );
}

#[test]
fn project_settings_render_mutates_single_line_flow_without_using_cst_insert() {
    let original = "{unknown: keep, owned-old: 1, drop-me: true} # tail\n";
    let desired = "{owned_old: 2, added_key: [x, 3]}\n";
    let input = render_payload(original, desired, &["owned-old", "drop-me", "added-key"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.trim_end().ends_with("} # tail"));
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(
        mapping.get(serde_yaml::Value::String("unknown".into())),
        Some(&serde_yaml::Value::String("keep".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("owned-old".into())),
        Some(&serde_yaml::Value::Number(2.into()))
    );
    assert!(!mapping.contains_key(serde_yaml::Value::String("drop-me".into())));
    assert_eq!(
        mapping.get(serde_yaml::Value::String("added_key".into())),
        Some(&serde_yaml::Value::Sequence(vec![
            serde_yaml::Value::String("x".into()),
            serde_yaml::Value::Number(3.into()),
        ]))
    );
}

#[test]
fn project_settings_render_preserves_separator_comment_after_deleted_flow_head() {
    let original = "{model: old, # separator-comment\n future-owner: keep}\n";
    let input = render_payload(original, "agent: codex\n", &["agent", "model"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("# separator-comment"));
    assert!(!text.contains("model: old"));
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(
        mapping.get(serde_yaml::Value::String("future-owner".into())),
        Some(&serde_yaml::Value::String("keep".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("codex".into()))
    );
}

#[test]
fn project_settings_render_preserves_separator_comment_after_deleted_flow_middle() {
    let original = "{agent: old, model: old, # separator-comment\n future-owner: keep}\n";
    let input = render_payload(original, "agent: new\n", &["agent", "model"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("# separator-comment"));
    assert!(!text.contains("model: old"));
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(
        mapping.get(serde_yaml::Value::String("future-owner".into())),
        Some(&serde_yaml::Value::String("keep".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("new".into()))
    );
}

#[test]
fn project_settings_render_coalesces_two_owned_deletions_at_flow_tail() {
    let original = "{unknown: keep, model: old, reasoning_effort: high}\n";
    let input = render_payload(
        original,
        "agent: codex\n",
        &["agent", "model", "reasoning_effort"],
    );
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.stdout, b"{unknown: keep, \"agent\": \"codex\"}\n");
    let mapping = yaml_mapping(&output.stdout);
    assert_eq!(mapping.len(), 2);
    assert_eq!(
        mapping.get(serde_yaml::Value::String("unknown".into())),
        Some(&serde_yaml::Value::String("keep".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("codex".into()))
    );
}

#[test]
fn project_settings_render_coalesces_all_owned_flow_deletions() {
    let original = "{owned-a: 1, owned-b: 2}\n";
    let input = render_payload(original, "{}\n", &["owned-a", "owned-b"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(yaml_mapping(&output.stdout).is_empty());
}

#[test]
fn project_settings_render_preserves_flow_separator_comment_when_deleting_tail() {
    let original =
        "{workspace-recipes: {review: {schema-version: 1}}, # recipe comment\n reasoning_effort: high}\n";
    let input = render_payload(original, "{}\n", &["reasoning_effort"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains(", # recipe comment"));
    assert!(!text.contains("reasoning_effort"));
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(mapping.len(), 1);
    assert_eq!(
        mapping
            .get(serde_yaml::Value::String("workspace-recipes".into()))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|workspace| workspace.get(serde_yaml::Value::String("review".into())))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|review| { review.get(serde_yaml::Value::String("schema-version".into())) }),
        Some(&serde_yaml::Value::Number(1.into()))
    );
}

#[test]
fn project_settings_render_reuses_flow_separator_comment_when_replacing_tail() {
    let original =
        "{workspace-recipes: {review: {schema-version: 1}}, # recipe comment\n reasoning_effort: high}\n";
    let input = render_payload(original, "agent: codex\n", &["agent", "reasoning_effort"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains(", # recipe comment"));
    assert!(!text.contains("reasoning_effort"));
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(mapping.len(), 2);
    assert_eq!(
        mapping
            .get(serde_yaml::Value::String("workspace-recipes".into()))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|workspace| workspace.get(serde_yaml::Value::String("review".into())))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|review| { review.get(serde_yaml::Value::String("schema-version".into())) }),
        Some(&serde_yaml::Value::Number(1.into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("codex".into()))
    );
}

#[test]
fn project_settings_render_preserves_unknown_alias_and_tagged_values() {
    let cases = [
        (
            "defaults: &d\n  enabled: true\nfuture-owner: *d\nagent: old\n",
            "future-owner: *d",
        ),
        (
            "future-owner: !future keep\nagent: old\n",
            "future-owner: !future keep",
        ),
    ];

    for (original, preserved) in cases {
        let input = render_payload(original, "agent: codex\n", &["agent"]);
        let output = run_project_settings_render(&input, &[]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
        assert!(text.contains(preserved));
        assert_eq!(
            yaml_mapping(text.as_bytes()).get(serde_yaml::Value::String("agent".into())),
            Some(&serde_yaml::Value::String("codex".into()))
        );
    }
}

#[test]
fn project_settings_render_replaces_owned_alias_and_tagged_values() {
    let cases = ["defaults: &d codex\nagent: *d\n", "agent: !legacy old\n"];

    for original in cases {
        let input = render_payload(original, "agent: codex\n", &["agent"]);
        let output = run_project_settings_render(&input, &[]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            yaml_mapping(&output.stdout).get(serde_yaml::Value::String("agent".into())),
            Some(&serde_yaml::Value::String("codex".into()))
        );
    }
}

#[test]
fn project_settings_render_recursively_preserves_unknown_owned_descendants() {
    let original = "defaults: &classes [implementation, review]\nagent_slots:\n  - slot_id: worker-1\n    model: old\n    backend: local\n    fallback_model: legacy\n    task_classes: *classes # keep-slot-extension\nroles:\n  builder:\n    model: old\n    auth_mode: local\n    task_classes: !future [implementation] # keep-role-extension\n  researcher:\n    model: old\n    task_classes: [research]\n";
    let desired = "agent_slots:\n  - slot_id: worker-1\n    model: new\n    model_source: operator-override\n    worker_backend: codex\nroles:\n  builder:\n    model: new\n    model_source: operator-override\n  reviewer:\n    model: review-model\n";
    let input = render_payload(original, desired, &["agent_slots", "roles"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("task_classes: *classes # keep-slot-extension"));
    assert!(text.contains("task_classes: !future [implementation] # keep-role-extension"));
    assert!(!text.contains("fallback_model:"));
    assert!(!text.contains("auth_mode:"));
    assert!(!text.contains("researcher:"));

    let mapping = yaml_mapping(text.as_bytes());
    let slot = mapping
        .get(serde_yaml::Value::String("agent_slots".into()))
        .and_then(serde_yaml::Value::as_sequence)
        .and_then(|slots| slots.first())
        .and_then(serde_yaml::Value::as_mapping)
        .expect("one slot mapping");
    assert_eq!(
        slot.get(serde_yaml::Value::String("model".into())),
        Some(&serde_yaml::Value::String("new".into()))
    );
    assert_eq!(
        slot.get(serde_yaml::Value::String("model_source".into())),
        Some(&serde_yaml::Value::String("operator-override".into()))
    );
    assert_eq!(
        slot.get(serde_yaml::Value::String("backend".into())),
        Some(&serde_yaml::Value::String("codex".into()))
    );
    assert!(slot.contains_key(serde_yaml::Value::String("task_classes".into())));

    let role = mapping
        .get(serde_yaml::Value::String("roles".into()))
        .and_then(serde_yaml::Value::as_mapping)
        .and_then(|roles| roles.get(serde_yaml::Value::String("builder".into())))
        .and_then(serde_yaml::Value::as_mapping)
        .expect("builder role mapping");
    assert_eq!(
        role.get(serde_yaml::Value::String("model".into())),
        Some(&serde_yaml::Value::String("new".into()))
    );
    assert!(role.contains_key(serde_yaml::Value::String("task_classes".into())));
    assert!(mapping
        .get(serde_yaml::Value::String("roles".into()))
        .and_then(serde_yaml::Value::as_mapping)
        .is_some_and(|roles| roles.contains_key(serde_yaml::Value::String("reviewer".into()))));
}

#[test]
fn project_settings_render_combines_nested_edits_with_top_level_additions() {
    let original = "defaults: &classes [implementation, review]\nagent_slots:\n  - slot_id: worker-1\n    model: old\n    backend: local\n    fallback_model: legacy\n    task_classes: *classes # keep-slot-extension\nroles:\n  builder:\n    model: old\n    auth_mode: local\n    task_classes: !future [implementation] # keep-role-extension\n";
    let desired = "agent: codex\r\nmodel: gpt-5.6-terra\r\nagent_slots:\r\n  - slot_id: worker-1\r\n    runtime_role: worker\r\n    model: gpt-5.6-terra\r\n    model_source: operator-override\r\n    worker_backend: codex\r\n    worktree_mode: managed\r\nroles:\r\n  builder:\r\n    model: gpt-5.6-terra\r\n    model_source: operator-override\r\n";
    let input = render_payload(
        original,
        desired,
        &["agent", "model", "agent_slots", "roles"],
    );
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("codex".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("model".into())),
        Some(&serde_yaml::Value::String("gpt-5.6-terra".into()))
    );
    assert!(text.contains("task_classes: *classes # keep-slot-extension"));
    assert!(text.contains("task_classes: !future [implementation] # keep-role-extension"));
    assert!(!text.contains("fallback_model:"));
    assert!(!text.contains("auth_mode:"));
}

#[test]
fn project_settings_render_recursively_preserves_unknown_owned_flow_descendants() {
    let original = "agent_slots: [{slot_id: worker-1, model: old, fallback_model: legacy, task_classes: !future keep} # slot-extension\n]\nroles: {builder: {model: old, auth_mode: local, task_classes: !future keep}}\n";
    let desired = "agent_slots:\n  - slot_id: worker-1\n    model: new\n    model_source: operator-override\nroles:\n  builder:\n    model: new\n    model_source: operator-override\n";
    let input = render_payload(original, desired, &["agent_slots", "roles"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("task_classes: !future keep"));
    assert!(text.contains("# slot-extension"));
    assert!(!text.contains("fallback_model:"));
    assert!(!text.contains("auth_mode:"));
    let mapping = yaml_mapping(text.as_bytes());
    assert_eq!(
        mapping
            .get(serde_yaml::Value::String("agent_slots".into()))
            .and_then(serde_yaml::Value::as_sequence)
            .and_then(|slots| slots.first())
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|slot| slot.get(serde_yaml::Value::String("model_source".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("operator-override")
    );
}

#[test]
fn project_settings_render_rejects_ambiguous_unknown_slot_topology() {
    let original = "agent_slots:\n  - slot_id: worker-1\n    model: old\n    task_classes: [implementation]\n  - slot_id: worker-2\n    model: old\n";
    let cases = [
        "agent_slots:\n  - slot_id: worker-2\n    model: new\n  - slot_id: worker-1\n    model: new\n",
        "agent_slots:\n  - slot_id: worker-1\n    model: new\n",
        "agent_slots:\n  - slot_id: worker-1\n    model: new\n  - slot_id: worker-2\n    model: new\n  - slot_id: worker-3\n    model: new\n",
        "agent_slots:\n  - slot_id: worker-1\n    model: new\n  - slot_id: worker-1\n    model: duplicate\n",
    ];

    for desired in cases {
        let input = render_payload(original, desired, &["agent_slots"]);
        let output = run_project_settings_render(&input, &[]);
        assert!(!output.status.success(), "unexpected output: {desired}");
        assert!(output.stdout.is_empty());
        assert_eq!(
            String::from_utf8(output.stderr).expect("UTF-8 generic error"),
            "winsmux: project settings render failed.\n"
        );
    }

    let duplicate_original = "agent_slots:\n  - slot_id: worker-1\n    task_classes: [implementation]\n  - slot_id: worker-1\n    model: old\n";
    let input = render_payload(
        duplicate_original,
        "agent_slots:\n  - slot_id: worker-1\n    model: new\n",
        &["agent_slots"],
    );
    let output = run_project_settings_render(&input, &[]);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
}

#[test]
fn project_settings_render_matches_slot_identity_ascii_case_insensitively() {
    let original = "agent_slots:\n  - slot_id: Worker-1 # identity-comment\n    model: old\n    task_classes: [implementation] # extension-comment\n";
    let desired = "agent_slots:\n  - slot_id: worker-1\n    model: new\n    model_source: operator-override\n";
    let input = render_payload(original, desired, &["agent_slots"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("slot_id: \"Worker-1\" # identity-comment"));
    assert!(text.contains("task_classes: [implementation] # extension-comment"));
    assert!(text.contains("model: \"new\""));

    let mapping = yaml_mapping(text.as_bytes());
    let slot = mapping
        .get(serde_yaml::Value::String("agent_slots".into()))
        .and_then(serde_yaml::Value::as_sequence)
        .and_then(|slots| slots.first())
        .and_then(serde_yaml::Value::as_mapping)
        .expect("one slot mapping");
    assert_eq!(
        slot.get(serde_yaml::Value::String("slot_id".into()))
            .and_then(serde_yaml::Value::as_str),
        Some("Worker-1")
    );
    assert_eq!(
        slot.get(serde_yaml::Value::String("model_source".into()))
            .and_then(serde_yaml::Value::as_str),
        Some("operator-override")
    );
}

#[test]
fn project_settings_render_rejects_case_variant_original_slot_duplicates() {
    let original = "agent_slots:\n  - slot_id: Worker-1\n    model: old\n  - slot_id: worker-1\n    model: duplicate\n";
    let desired = "agent_slots:\n  - slot_id: worker-1\n    model: new\n";
    let input = render_payload(original, desired, &["agent_slots"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert_eq!(
        String::from_utf8(output.stderr).expect("UTF-8 generic error"),
        "winsmux: project settings render failed.\n"
    );
}

#[test]
fn project_settings_render_rejects_case_variant_desired_slot_duplicates() {
    let original = "agent_slots:\n  - slot_id: worker-1\n    model: old\n";
    let desired = "agent_slots:\n  - slot_id: Worker-1\n    model: new\n  - slot_id: worker-1\n    model: duplicate\n";
    let input = render_payload(original, desired, &["agent_slots"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert_eq!(
        String::from_utf8(output.stderr).expect("UTF-8 generic error"),
        "winsmux: project settings render failed.\n"
    );
}

#[test]
fn project_settings_render_still_allows_distinct_new_slot_identity() {
    let original = "agent_slots:\n  - slot_id: Worker-1\n    model: old\n";
    let desired = "agent_slots:\n  - slot_id: worker-2\n    model: added\n";
    let input = render_payload(original, desired, &["agent_slots"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mapping = yaml_mapping(&output.stdout);
    let slots = mapping
        .get(serde_yaml::Value::String("agent_slots".into()))
        .and_then(serde_yaml::Value::as_sequence)
        .expect("agent_slots sequence");
    assert_eq!(slots.len(), 1);
    assert_eq!(
        slots[0]
            .as_mapping()
            .and_then(|slot| slot.get(serde_yaml::Value::String("slot_id".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("worker-2")
    );
}

#[test]
fn project_settings_render_r48_matches_trimmed_slot_and_role_identities_in_block_yaml() {
    let original = "agent_slots:\n  - slot_id: ' Worker-1 ' # slot-id-comment\n    model: old\n    task_classes: [implementation] # slot-extension\nroles:\n  ' Builder ': # role-name-comment\n    model: old\n    task_classes: [implementation] # role-extension\n";
    let desired = "agent_slots:\n  - slot_id: worker-1\n    model: new\nroles:\n  builder:\n    model: new-role\n";
    let input = render_payload(original, desired, &["agent_slots", "roles"]);
    let first = run_project_settings_render(&input, &[]);

    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let first_text = String::from_utf8(first.stdout).expect("UTF-8 YAML output");
    assert!(first_text.contains("slot_id: \" Worker-1 \" # slot-id-comment"));
    assert!(first_text.contains("task_classes: [implementation] # slot-extension"));
    assert!(first_text.contains("' Builder ': # role-name-comment"));
    assert!(first_text.contains("task_classes: [implementation] # role-extension"));
    assert!(first_text.contains("model: \"new\""));
    assert!(first_text.contains("model: \"new-role\""));

    let second_input = render_payload(&first_text, desired, &["agent_slots", "roles"]);
    let second = run_project_settings_render(&second_input, &[]);
    assert!(second.status.success());
    assert_eq!(second.stdout, first_text.as_bytes());
}

#[test]
fn project_settings_render_r48_matches_trimmed_slot_and_role_identities_in_flow_yaml() {
    let original = "{agent_slots: [{slot_id: ' Worker-1 ', model: old, future_slot: keep} # slot-comment\n], roles: {' Reviewer ': {model: old, future_role: keep} # role-comment\n}} # root-comment\n";
    let desired = "agent_slots:\n  - slot_id: worker-1\n    model: new\nroles:\n  reviewer:\n    model: new-role\n";
    let input = render_payload(original, desired, &["agent_slots", "roles"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("slot_id: \" Worker-1 \""));
    assert!(text.contains("future_slot: keep"));
    assert!(text.contains("' Reviewer ':"));
    assert!(text.contains("future_role: keep"));
    assert!(text.contains("# slot-comment"));
    assert!(text.contains("# role-comment"));
    assert!(text.contains("# root-comment"));
}

#[test]
fn project_settings_render_r48_rejects_trimmed_identity_duplicates_on_both_sides() {
    let cases = [
        (
            "agent_slots:\n  - slot_id: ' Worker-1 '\n  - slot_id: worker-1\n",
            "agent_slots:\n  - slot_id: worker-1\n",
            &["agent_slots"][..],
        ),
        (
            "agent_slots:\n  - slot_id: worker-1\n",
            "agent_slots:\n  - slot_id: ' Worker-1 '\n  - slot_id: worker-1\n",
            &["agent_slots"][..],
        ),
        (
            "roles:\n  ' Builder ': {}\n  builder: {}\n",
            "roles:\n  builder: {}\n",
            &["roles"][..],
        ),
        (
            "roles:\n  builder: {}\n",
            "roles:\n  ' Builder ': {}\n  builder: {}\n",
            &["roles"][..],
        ),
    ];

    for (original, desired, owned) in cases {
        let output = run_project_settings_render(&render_payload(original, desired, owned), &[]);
        assert!(
            !output.status.success(),
            "unexpected output for {original:?}"
        );
        assert!(output.stdout.is_empty());
        assert_eq!(
            String::from_utf8(output.stderr).expect("UTF-8 generic error"),
            "winsmux: project settings render failed.\n"
        );
    }
}

#[test]
fn project_settings_render_r48_keeps_add_remove_and_owned_omission_controls() {
    let original = "agent_slots:\n  - slot_id: Worker-1\n    model: old\n  - slot_id: removed-slot\n    model: old\nroles:\n  Builder:\n    model: old\n  removed-role:\n    model: old\n";
    let desired = "agent_slots:\n  - slot_id: ' worker-1 '\n    reasoning_effort: high\n  - slot_id: worker-3\n    model: \"slot # \\\"added\"\nroles:\n  ' builder ': {}\n  reviewer:\n    model: added-role\n  \"review # \\\"lead\":\n    model: \"role # \\\"added\"\n";
    let output = run_project_settings_render(
        &render_payload(original, desired, &["agent_slots", "roles"]),
        &[],
    );

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mapping = yaml_mapping(&output.stdout);
    let slots = mapping
        .get(serde_yaml::Value::String("agent_slots".into()))
        .and_then(serde_yaml::Value::as_sequence)
        .expect("agent_slots sequence");
    assert_eq!(slots.len(), 2);
    assert_eq!(
        slots[0]
            .as_mapping()
            .and_then(|slot| slot.get(serde_yaml::Value::String("slot_id".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("Worker-1")
    );
    assert!(slots[0]
        .as_mapping()
        .is_some_and(|slot| !slot.contains_key(serde_yaml::Value::String("model".into()))));
    assert_eq!(
        slots[0]
            .as_mapping()
            .and_then(|slot| slot.get(serde_yaml::Value::String("reasoning_effort".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("high")
    );
    let block_text = String::from_utf8(output.stdout.clone()).expect("UTF-8 block YAML output");
    assert!(block_text.contains("agent_slots:\n  - reasoning_effort: \"high\""));
    assert!(block_text.contains("    slot_id: \"Worker-1\""));
    assert!(block_text.contains("roles:\n  Builder:\n    {}"));
    assert!(block_text.contains("  reviewer:\n    model: \"added-role\""));
    assert!(block_text.contains("  \"review # \\\"lead\":\n    model: \"role # \\\"added\""));
    assert!(!block_text.contains("[{"));
    assert!(!block_text.contains("{\\\"model\\\""));
    let roles = mapping
        .get(serde_yaml::Value::String("roles".into()))
        .and_then(serde_yaml::Value::as_mapping)
        .expect("roles mapping");
    assert_eq!(roles.len(), 3);
    assert!(roles
        .get(serde_yaml::Value::String("Builder".into()))
        .is_some_and(|role| role.as_mapping().is_some_and(serde_yaml::Mapping::is_empty)));
    assert!(roles.contains_key(serde_yaml::Value::String("reviewer".into())));
    assert_eq!(
        roles
            .get(serde_yaml::Value::String("review # \"lead".into()))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|role| role.get(serde_yaml::Value::String("model".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("role # \"added")
    );

    let second = run_project_settings_render(
        &render_payload(&block_text, desired, &["agent_slots", "roles"]),
        &[],
    );
    assert!(second.status.success());
    assert_eq!(second.stdout, block_text.as_bytes());

    let replace_only_original = "roles:\n  Builder:\n    model: old\n";
    let replace_only_desired = "roles:\n  Reviewer:\n    model: new\n";
    let replace_only = run_project_settings_render(
        &render_payload(replace_only_original, replace_only_desired, &["roles"]),
        &[],
    );
    assert!(
        replace_only.status.success(),
        "{}",
        String::from_utf8_lossy(&replace_only.stderr)
    );
    let replace_only_text =
        String::from_utf8(replace_only.stdout).expect("UTF-8 replaced roles YAML");
    assert_eq!(
        replace_only_text,
        "roles:\n  Reviewer:\n    model: \"new\"\n"
    );
    let replace_only_second = run_project_settings_render(
        &render_payload(&replace_only_text, replace_only_desired, &["roles"]),
        &[],
    );
    assert!(replace_only_second.status.success());
    assert_eq!(replace_only_second.stdout, replace_only_text.as_bytes());

    let flow_original = "{roles: {' Builder ': {model: old} # builder-comment\n, removed-role: {model: old}}, untouched: keep} # root-comment\n";
    let flow_desired = "roles:\n  ' builder ': {}\n  reviewer:\n    model: added-role\n";
    let flow_input = render_payload(flow_original, flow_desired, &["roles"]);
    let flow_first = run_project_settings_render(&flow_input, &[]);
    assert!(
        flow_first.status.success(),
        "{}",
        String::from_utf8_lossy(&flow_first.stderr)
    );
    let flow_text = String::from_utf8(flow_first.stdout).expect("UTF-8 flow YAML output");
    assert!(flow_text.contains("' Builder ': {} # builder-comment"));
    assert!(flow_text.contains("\"reviewer\": {\"model\":\"added-role\"}"));
    assert!(!flow_text.contains("removed-role"));
    assert!(flow_text.contains("untouched: keep"));
    assert!(flow_text.contains("# root-comment"));

    let flow_second_input = render_payload(&flow_text, flow_desired, &["roles"]);
    let flow_second = run_project_settings_render(&flow_second_input, &[]);
    assert!(flow_second.status.success());
    assert_eq!(flow_second.stdout, flow_text.as_bytes());
}

#[test]
fn project_settings_render_r52_adds_missing_structured_roots_as_canonical_block_yaml() {
    let original = "worker_count: 1 # keep-root-comment\n";
    let desired = "worker_count: 1\nagent_slots:\n  - slot_id: worker-1\n    model: slot-added\nroles:\n  reviewer:\n    model: role-added\n";
    let owned = &["worker_count", "agent_slots", "roles"];
    let first = run_project_settings_render(&render_payload(original, desired, owned), &[]);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let text = String::from_utf8(first.stdout).expect("UTF-8 block YAML output");
    assert!(text.contains("worker_count: 1 # keep-root-comment"));
    assert!(text.contains("agent_slots:\n  - model: \"slot-added\"\n    slot_id: \"worker-1\""));
    assert!(text.contains("roles:\n  reviewer:\n    model: \"role-added\""));
    assert!(!text.contains("agent_slots: ["));
    assert!(!text.contains("roles: {"));

    let second = run_project_settings_render(&render_payload(&text, desired, owned), &[]);
    assert!(second.status.success());
    assert_eq!(second.stdout, text.as_bytes());
}

#[test]
fn project_settings_render_allows_owned_slot_topology_changes_without_extensions() {
    let original = "agent_slots:\n  - slot_id: worker-1\n    model: old\n  - slot_id: worker-2\n    model: old\n    backend: local\n";
    let desired = "agent_slots:\n  - slot_id: worker-2\n    model: new\n    worker_backend: codex\n  - slot_id: worker-3\n    model: added\n";
    let input = render_payload(original, desired, &["agent_slots"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mapping = yaml_mapping(&output.stdout);
    let slots = mapping
        .get(serde_yaml::Value::String("agent_slots".into()))
        .and_then(serde_yaml::Value::as_sequence)
        .expect("agent_slots sequence");
    assert_eq!(slots.len(), 2);
    assert_eq!(
        slots[0]
            .as_mapping()
            .and_then(|slot| slot.get(serde_yaml::Value::String("slot_id".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("worker-2")
    );
    assert_eq!(
        slots[1]
            .as_mapping()
            .and_then(|slot| slot.get(serde_yaml::Value::String("slot_id".into())))
            .and_then(serde_yaml::Value::as_str),
        Some("worker-3")
    );

    let flow_original = "agent_slots: [{slot_id: worker-1, model: old}, {slot_id: removed-slot, model: old}] # slot-flow-comment\nuntouched: keep\n";
    let flow_first = run_project_settings_render(
        &render_payload(flow_original, desired, &["agent_slots"]),
        &[],
    );
    assert!(
        flow_first.status.success(),
        "{}",
        String::from_utf8_lossy(&flow_first.stderr)
    );
    let flow_text = String::from_utf8(flow_first.stdout).expect("UTF-8 flow YAML output");
    assert!(flow_text.contains("agent_slots: [{"));
    assert!(flow_text.contains("# slot-flow-comment"));
    assert!(flow_text.contains("untouched: keep"));

    let flow_second =
        run_project_settings_render(&render_payload(&flow_text, desired, &["agent_slots"]), &[]);
    assert!(flow_second.status.success());
    assert_eq!(flow_second.stdout, flow_text.as_bytes());
}

#[test]
fn project_settings_render_preserves_multiline_flow_comments_and_is_idempotent() {
    let original = "{\n  unknown: 'keep', # unknown-comment\n  owned: old # owned-comment\n}\n";
    let desired = "{owned: new, added: {nested: true}}\n";
    let first_input = render_payload(original, desired, &["owned", "added"]);
    let first = run_project_settings_render(&first_input, &[]);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let first_text = String::from_utf8(first.stdout).expect("UTF-8 YAML output");
    assert!(first_text.contains("unknown: 'keep', # unknown-comment"));
    assert!(first_text.contains("owned: \"new\" # owned-comment"));

    let second_input = render_payload(&first_text, desired, &["owned", "added"]);
    let second = run_project_settings_render(&second_input, &[]);
    assert!(
        second.status.success(),
        "{}",
        String::from_utf8_lossy(&second.stderr)
    );
    assert_eq!(second.stdout, first_text.as_bytes());
}

#[test]
fn project_settings_render_creates_canonical_block_yaml_from_empty_source() {
    for original in ["", " \r\n\t"] {
        let input = render_payload(original, "worker_count: 2\n", &["worker_count"]);
        let output = run_project_settings_render(&input, &[]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8(output.stdout.clone()).expect("UTF-8 YAML output"),
            "worker_count: 2\n",
            "new settings must use a block-style root"
        );
        assert_eq!(
            yaml_mapping(&output.stdout).get(serde_yaml::Value::String("worker_count".into())),
            Some(&serde_yaml::Value::Number(2.into()))
        );
    }

    let nested = serde_json::json!({
        "worker_count": 2,
        "agent_slots": [{
            "slot_id": "worker-1",
            "agent": "codex",
            "model": "provider-default"
        }],
        "roles": {
            "worker": {
                "model": "gpt-5.6-terra",
                "prompt_transport": "stdin"
            }
        },
        "vault_keys": []
    });
    let input = serde_json::to_vec(&serde_json::json!({
        "original_yaml": "",
        "desired_settings": nested,
        "owned_keys": ["worker_count", "agent_slots", "roles", "vault_keys"],
        "nested_contract": {
            "agent_slots": {
                "identity_key": "slot_id",
                "owned_keys": ["slot_id", "agent", "model"],
                "aliases": {}
            },
            "roles": { "owned_keys": ["model", "prompt_transport"] }
        }
    }))
    .expect("serialize nested block-style renderer payload");
    let output = run_project_settings_render(&input, &[]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout.clone()).expect("UTF-8 YAML output");
    assert_eq!(
        text,
        concat!(
            "agent_slots:\n",
            "  - agent: \"codex\"\n",
            "    model: \"provider-default\"\n",
            "    slot_id: \"worker-1\"\n",
            "roles:\n",
            "  worker:\n",
            "    model: \"gpt-5.6-terra\"\n",
            "    prompt_transport: \"stdin\"\n",
            "vault_keys:\n",
            "  []\n",
            "worker_count: 2\n"
        ),
        "new nested settings must use the manual fallback's block indentation"
    );
    let mapping = yaml_mapping(&output.stdout);
    assert_eq!(
        mapping
            .get(serde_yaml::Value::String("agent_slots".into()))
            .and_then(serde_yaml::Value::as_sequence)
            .map(Vec::len),
        Some(1)
    );
    assert!(mapping
        .get(serde_yaml::Value::String("roles".into()))
        .is_some_and(serde_yaml::Value::is_mapping));
    assert!(mapping
        .get(serde_yaml::Value::String("vault_keys".into()))
        .is_some_and(serde_yaml::Value::is_sequence));

    let empty_containers = render_payload(
        "",
        "agent_slots: []\nroles: {}\nvault_keys: []\n",
        &["agent_slots", "roles", "vault_keys"],
    );
    let output = run_project_settings_render(&empty_containers, &[]);
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).expect("UTF-8 YAML output"),
        "agent_slots:\n  []\nroles:\n  {}\nvault_keys:\n  []\n"
    );
}

#[test]
fn project_settings_render_r50_materializes_semantic_empty_roots_and_preserves_envelope() {
    let cases = [
        ("{}\n", &[][..]),
        (
            "# heading\n{} # inline-comment\n# trailing\n",
            &["# heading", "# inline-comment", "# trailing"][..],
        ),
        ("--- {}\n...\n", &["---", "..."][..]),
        (
            "# heading\n---\n{}\n...\n# trailing\n",
            &["# heading", "---", "...", "# trailing"][..],
        ),
    ];

    for (original, preserved) in cases {
        let desired = "agent: codex\n";
        let first =
            run_project_settings_render(&render_payload(original, desired, &["agent"]), &[]);
        assert!(
            first.status.success(),
            "{original:?}: {}",
            String::from_utf8_lossy(&first.stderr)
        );
        let first_text = String::from_utf8(first.stdout).expect("UTF-8 YAML output");
        assert!(first_text.lines().any(|line| line == "agent: \"codex\""));
        assert!(!first_text.contains("--- agent:"));
        for marker in preserved {
            assert!(
                first_text.contains(marker),
                "missing {marker:?} in {first_text:?}"
            );
        }
        assert_eq!(
            yaml_mapping(first_text.as_bytes())
                .get(serde_yaml::Value::String("agent".into()))
                .and_then(serde_yaml::Value::as_str),
            Some("codex")
        );

        let second =
            run_project_settings_render(&render_payload(&first_text, desired, &["agent"]), &[]);
        assert!(second.status.success());
        assert_eq!(second.stdout, first_text.as_bytes());
    }
}

#[test]
fn project_settings_render_r50_uses_manual_fallback_block_shape_for_empty_mapping() {
    let desired = "agent_slots:\n  - slot_id: worker-1\n    runtime_role: worker\n    worktree_mode: managed\nroles: {}\nvault_keys: []\n";
    let owned = &["agent_slots", "roles", "vault_keys"];
    let first = run_project_settings_render(&render_payload("{}\n", desired, owned), &[]);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let first_text = String::from_utf8(first.stdout).expect("UTF-8 YAML output");
    assert!(first_text.contains("agent_slots:\n  - runtime_role: \"worker\""));
    assert!(first_text.contains("    slot_id: \"worker-1\""));
    assert!(first_text.contains("    worktree_mode: \"managed\""));
    assert!(first_text.contains("roles:\n  {}\n"));
    assert!(first_text.contains("vault_keys:\n  []\n"));
    assert!(!first_text.contains("[{"));

    let second = run_project_settings_render(&render_payload(&first_text, desired, owned), &[]);
    assert!(second.status.success());
    assert_eq!(second.stdout, first_text.as_bytes());
}

#[test]
fn project_settings_render_r50_emits_explicit_empty_mapping_after_delete_all() {
    for original in ["agent: old\n", "{agent: old}\n"] {
        let desired = "{}\n";
        let first =
            run_project_settings_render(&render_payload(original, desired, &["agent"]), &[]);
        assert!(
            first.status.success(),
            "{original:?}: {}",
            String::from_utf8_lossy(&first.stderr)
        );
        assert_eq!(first.stdout, b"{}\n");

        let second = run_project_settings_render(&render_payload("{}\n", desired, &["agent"]), &[]);
        assert!(second.status.success());
        assert_eq!(second.stdout, first.stdout);
    }

    let commented_cases = [
        (
            "# heading\nagent: old # keep-inline\n# trailing\n",
            &["# heading", "# keep-inline", "# trailing"][..],
        ),
        (
            "agent: old # keep-agent\nworker_count: 2 # keep-worker\n# trailing\n",
            &["# keep-agent", "# keep-worker", "# trailing"][..],
        ),
        (
            "{agent: old} # keep-flow\n# trailing\n",
            &["# keep-flow", "# trailing"][..],
        ),
    ];
    for (original, comments) in commented_cases {
        let owned = if original.contains("worker_count") {
            &["agent", "worker_count"][..]
        } else {
            &["agent"][..]
        };
        let first = run_project_settings_render(&render_payload(original, "{}\n", owned), &[]);
        assert!(
            first.status.success(),
            "{original:?}: {}",
            String::from_utf8_lossy(&first.stderr)
        );
        let first_text = String::from_utf8(first.stdout).expect("UTF-8 delete-all YAML");
        assert!(
            yaml_mapping(first_text.as_bytes()).is_empty(),
            "{first_text:?}"
        );
        assert!(first_text.contains("{}"), "{first_text:?}");
        for comment in comments {
            assert!(
                first_text.contains(comment),
                "missing {comment:?} in {first_text:?}"
            );
        }
        let second = run_project_settings_render(&render_payload(&first_text, "{}\n", owned), &[]);
        assert!(second.status.success());
        assert_eq!(second.stdout, first_text.as_bytes());
    }
}

#[test]
fn project_settings_render_r50_rejects_unsupported_root_states() {
    let cases = [
        "# comment only\n",
        "---\n",
        "...\n",
        "null\n",
        "scalar\n",
        "- item\n",
        "agent: [\n",
        "agent: one\nagent: two\n",
        "---\nagent: one\n---\nagent: two\n",
    ];
    for original in cases {
        let output = run_project_settings_render(
            &render_payload(original, "agent: codex\n", &["agent"]),
            &[],
        );
        assert!(
            !output.status.success(),
            "unexpected output for {original:?}"
        );
        assert!(output.stdout.is_empty());
        assert_eq!(
            String::from_utf8(output.stderr).expect("UTF-8 generic error"),
            "winsmux: project settings render failed.\n"
        );
    }
}

#[test]
fn project_settings_render_uses_reader_canonicalization_for_mixed_case_owned_keys() {
    let original = "Agent: claude # top-comment\nagent_slots:\n  - Slot-ID: worker-1\n    Model-Source: legacy\n    Future-Slot: keep # slot-comment\nroles:\n  worker:\n    Model-Source: legacy-role\n    Future-Role: keep # role-comment\n";
    let desired = serde_json::json!({
        "agent": "codex",
        "agent_slots": [{
            "slot_id": "worker-1",
            "model_source": "operator-override"
        }],
        "roles": {
            "worker": {
                "model_source": "provider-default"
            }
        }
    });
    let input = serde_json::to_vec(&serde_json::json!({
        "original_yaml": original,
        "desired_settings": desired,
        "owned_keys": ["agent", "agent_slots", "roles"],
        "nested_contract": {
            "agent_slots": {
                "identity_key": "slot_id",
                "owned_keys": ["slot_id", "model_source"],
                "aliases": {}
            },
            "roles": { "owned_keys": ["model_source"] }
        }
    }))
    .expect("serialize mixed-case renderer payload");
    let output = run_project_settings_render(&input, &[]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).expect("UTF-8 YAML output");
    assert!(text.contains("Agent: \"codex\" # top-comment"));
    assert!(text.contains("Slot-ID: \"worker-1\""));
    assert!(text.contains("Model-Source: \"operator-override\""));
    assert!(text.contains("Future-Slot: keep # slot-comment"));
    assert!(text.contains("Model-Source: \"provider-default\""));
    assert!(text.contains("Future-Role: keep # role-comment"));
    assert!(!text.lines().any(|line| line.starts_with("agent:")));
    assert!(!text
        .lines()
        .any(|line| line.trim_start().starts_with("slot_id:")));
    assert!(!text
        .lines()
        .any(|line| line.trim_start().starts_with("model_source:")));

    let project = tempfile::tempdir().expect("create canonical reader fixture");
    fs::write(project.path().join(".winsmux.yaml"), &text)
        .expect("write rendered project settings");
    let settings = canonical_project_settings_reader::read(project.path())
        .expect("canonical reader must accept the rendered aliases without conflicts");
    assert_eq!(settings.agent.as_deref(), Some("codex"));
    assert_eq!(settings.agent_slots.len(), 1);
    assert_eq!(settings.agent_slots[0].slot_id, "worker-1");
    assert_eq!(
        settings.agent_slots[0].model_source.as_deref(),
        Some("operator-override")
    );
    assert_eq!(
        settings.worker_role.model_source.as_deref(),
        Some("provider-default")
    );
}

#[test]
fn project_settings_render_preserves_unknown_only_flow_when_adding_owned_keys() {
    let original =
        "{workspace-recipes: {review: {schema-version: 1}}, future-owner: {enabled: true}}\n";
    let desired = "agent: codex\nmodel: gpt-5.6-sol\n";
    let input = render_payload(original, desired, &["agent", "model"]);
    let output = run_project_settings_render(&input, &[]);

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mapping = yaml_mapping(&output.stdout);
    assert!(mapping.contains_key(serde_yaml::Value::String("workspace-recipes".into())));
    assert!(mapping.contains_key(serde_yaml::Value::String("future-owner".into())));
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("codex".into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("model".into())),
        Some(&serde_yaml::Value::String("gpt-5.6-sol".into()))
    );
}

#[test]
fn project_settings_render_rejects_invalid_contracts_without_reflection() {
    let secret = "sk-proj-synthetic-secret-value";
    let duplicate_original = format!("owned: one\nowned: {secret}\n");
    let cases = vec![
        b"not-json".to_vec(),
        render_payload(secret, "owned: ok\n", &["owned"]),
        render_payload(
            "---\nowned: one\n---\nowned: two\n",
            "owned: ok\n",
            &["owned"],
        ),
        render_payload("[one, two]\n", "owned: ok\n", &["owned"]),
        render_payload(&duplicate_original, "owned: ok\n", &["owned"]),
        render_payload("unknown: keep\n", "unknown: changed\n", &["owned"]),
        render_payload("owned: old\n", "owned: new\nunknown: leaked\n", &["owned"]),
        render_payload("owned: old\n", "owned: new\n", &["owned", "owned"]),
        render_payload(
            "owned-key: old\n",
            "owned_key: new\n",
            &["owned-key", "owned_key"],
        ),
    ];

    for input in cases {
        let output = run_project_settings_render(&input, &[]);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8(output.stderr).expect("UTF-8 generic error");
        assert_eq!(stderr, "winsmux: project settings render failed.\n");
        assert!(!stderr.contains(secret));
    }
}

#[test]
fn project_settings_render_rejects_arguments_and_oversized_stdin() {
    let input = render_payload("", "owned: ok\n", &["owned"]);
    let with_arg = run_project_settings_render(&input, &["unexpected-private-value"]);
    assert!(!with_arg.status.success());
    assert!(with_arg.stdout.is_empty());
    assert_eq!(
        String::from_utf8(with_arg.stderr).unwrap(),
        "winsmux: project settings render failed.\n"
    );

    let oversized = vec![b'x'; 4 * 1024 * 1024 + 1];
    let output = run_project_settings_render(&oversized, &[]);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert_eq!(
        String::from_utf8(output.stderr).unwrap(),
        "winsmux: project settings render failed.\n"
    );
}

#[test]
fn project_settings_render_requires_typed_settings_and_preserves_json_value_kinds() {
    let desired = serde_json::json!({
        "agent_slots": [],
        "roles": {},
        "external_operator": false,
        "worker_count": 0,
        "agent": "false"
    });
    let input = serde_json::to_vec(&serde_json::json!({
        "original_yaml": "agent_slots:\n  - slot_id: worker-1\nroles:\n  worker:\n    model: old\nexternal_operator: true\nworker_count: 6\nagent: codex\n",
        "desired_settings": desired,
        "owned_keys": ["agent_slots", "roles", "external_operator", "worker_count", "agent"],
        "nested_contract": {
            "agent_slots": {
                "identity_key": "slot_id",
                "owned_keys": ["slot_id"],
                "aliases": {}
            },
            "roles": { "owned_keys": ["model"] }
        }
    }))
    .expect("serialize typed renderer payload");
    let output = run_project_settings_render(&input, &[]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mapping = yaml_mapping(&output.stdout);
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent_slots".into())),
        Some(&serde_yaml::Value::Sequence(Vec::new()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("roles".into())),
        Some(&serde_yaml::Value::Mapping(serde_yaml::Mapping::new()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("external_operator".into())),
        Some(&serde_yaml::Value::Bool(false))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("worker_count".into())),
        Some(&serde_yaml::Value::Number(0.into()))
    );
    assert_eq!(
        mapping.get(serde_yaml::Value::String("agent".into())),
        Some(&serde_yaml::Value::String("false".into()))
    );

    let legacy = legacy_render_payload("agent: old\n", "agent: new\n", &["agent"]);
    let rejected = run_project_settings_render(&legacy, &[]);
    assert!(!rejected.status.success());
    assert!(rejected.stdout.is_empty());
    assert_eq!(
        String::from_utf8(rejected.stderr).expect("UTF-8 generic error"),
        "winsmux: project settings render failed.\n"
    );
}

#[test]
#[cfg(windows)]
fn operator_cli_workspace_plan_preserves_stale_startup_state() {
    let fixture = tempfile::tempdir().expect("create isolated workspace-plan fixture");
    let project_dir = fixture.path().join("project");
    let runtime_dir = project_dir.join(".winsmux");
    let home_dir = fixture.path().join("home");
    let psmux_dir = home_dir.join(".psmux");
    fs::create_dir_all(&runtime_dir).expect("create project runtime directory");
    fs::create_dir_all(&psmux_dir).expect("create isolated psmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        include_str!("../../tests/fixtures/workspace-recipes/valid-v1.yaml"),
    )
    .expect("write workspace recipe fixture");
    fs::write(
        runtime_dir.join("provider-capabilities.json"),
        include_str!("../../tests/fixtures/workspace-recipes/valid-v1.provider-capabilities.json"),
    )
    .expect("write provider capabilities fixture");

    let binary = env!("CARGO_BIN_EXE_winsmux");
    let normalized_binary = binary.replace('\\', "/").to_ascii_lowercase();
    let stale_paths = [
        (psmux_dir.join("dead.port"), b"not-a-port".to_vec()),
        (psmux_dir.join("dead.key"), b"synthetic-key".to_vec()),
        (
            psmux_dir.join("dead.registry.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "protocol_version": 1,
                "session": "dead",
                "namespace": null,
                "server_pid": u32::MAX,
                "process_started_at": 1,
                "server_exe": normalized_binary,
                "instance_nonce": "stale-preview-fixture",
                "port": 42124,
                "state": "ready",
                "owner": "normal",
                "created_at": 1,
                "ready_at": 2
            }))
            .expect("serialize stale registry fixture"),
        ),
    ];
    for (path, bytes) in &stale_paths {
        fs::write(path, bytes).expect("write stale startup state");
    }

    for prefix in [
        Vec::<&str>::new(),
        vec!["-u"],
        vec!["--unknown"],
        vec!["-L", "ops"],
        vec!["-S", "socket-name"],
        vec!["-f", "config"],
        vec!["-t", "target"],
        vec!["-C"],
        vec!["-CC"],
        vec!["-L", "ops", "-u"],
    ] {
        let output = Command::new(binary)
            .args(&prefix)
            .args([
                "workspace-plan",
                "--recipe-id",
                "bugfix-two-slot",
                "--workflow-id",
                "issue-1204",
                "--json",
                "--project-dir",
            ])
            .arg(&project_dir)
            .env("USERPROFILE", &home_dir)
            .env("HOME", &home_dir)
            .env_remove("PSMUX_TARGET_SESSION")
            .env_remove("PSMUX_TARGET_FULL")
            .env_remove("TMUX")
            .output()
            .expect("run workspace-plan preview");

        assert!(
            output.status.success(),
            "workspace-plan {prefix:?} stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .expect("workspace-plan should emit JSON");
        for (path, expected) in &stale_paths {
            assert_eq!(
                fs::read(path).expect("preview must preserve stale startup state"),
                *expected,
                "workspace-plan {prefix:?} changed {}",
                path.display()
            );
        }
    }

    let ordinary = Command::new(binary)
        .arg("version")
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .env_remove("PSMUX_TARGET_SESSION")
        .env_remove("PSMUX_TARGET_FULL")
        .env_remove("TMUX")
        .output()
        .expect("run ordinary startup route");
    assert!(ordinary.status.success(), "version command should succeed");
    for (path, _) in &stale_paths {
        assert!(
            !path.exists(),
            "ordinary startup cleanup should remove {}",
            path.display()
        );
    }
}

fn workspace_plan_builtin_provider_yaml(
    provider: &str,
    model: &str,
    model_source: &str,
    prompt_transport: &str,
    auth_mode: &str,
) -> String {
    format!(
        r#"config-version: 1
agent-slots:
  - slot-id: reviewer-1
    agent: {provider}
    model: {model}
    model-source: {model_source}
    reasoning-effort: provider-default
    prompt-transport: {prompt_transport}
    auth-mode: {auth_mode}
workspace-recipes:
  review-one-slot:
    schema-version: 1
    panes:
      - pane-key: verify
        workflow-role: verifier
        slot-ref: reviewer-1
        requires-capabilities: [review]
        region: main
        worktree:
          mode: read-only-reference
    startup-actions:
      - action-id: start-verify-slot
        kind: ensure-slot-ready
        pane-ref: verify
"#
    )
}

fn run_workspace_plan(project_dir: &std::path::Path, recipe_id: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-plan",
            "--recipe-id",
            recipe_id,
            "--workflow-id",
            "task-658",
            "--json",
            "--project-dir",
        ])
        .arg(project_dir)
        .output()
        .expect("run workspace-plan")
}

#[test]
fn operator_cli_workspace_plan_uses_builtin_provider_capabilities_for_registry_gaps() {
    let cases = [
        (
            "missing",
            "openrouter",
            "sakana/fugu-ultra",
            "provider-api",
            "file",
            "api-key-env",
        ),
        (
            "empty",
            "antigravity",
            "'Gemini 3.5 Flash (High)'",
            "cli-discovery",
            "file",
            "antigravity-official-cli",
        ),
        (
            "unrelated",
            "grok-build",
            "grok-build",
            "cli-discovery",
            "file",
            "grok-build-local",
        ),
    ];

    for (registry_case, provider, model, model_source, transport, auth_mode) in cases {
        let project_dir = make_temp_project_dir(&format!(
            "workspace-plan-builtin-{provider}-{registry_case}"
        ));
        fs::write(
            project_dir.join(".winsmux.yaml"),
            workspace_plan_builtin_provider_yaml(
                provider,
                model,
                model_source,
                transport,
                auth_mode,
            ),
        )
        .expect("write workspace plan fixture");

        if registry_case != "missing" {
            let runtime_dir = project_dir.join(".winsmux");
            fs::create_dir_all(&runtime_dir).expect("create runtime fixture directory");
            let registry = if registry_case == "empty" {
                String::new()
            } else {
                r#"{"version":1,"providers":{"unrelated":{"adapter":"unrelated","command":"unrelated","prompt_transports":["argv"]}}}"#.to_string()
            };
            fs::write(runtime_dir.join("provider-capabilities.json"), registry)
                .expect("write capability registry fixture");
        }

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(
            output.status.success(),
            "{provider} with {registry_case} registry failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let plan: serde_json::Value =
            serde_json::from_slice(&output.stdout).expect("workspace plan should be JSON");
        assert_eq!(plan["resolved_bindings"]["verify"], "reviewer-1");
    }
}

#[test]
#[cfg(windows)]
fn operator_cli_builtin_provider_mirror_matches_powershell_runtime_contract() {
    let project_dir = make_temp_project_dir("builtin-provider-runtime-parity");
    let settings_script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core should have a repository parent")
        .join("winsmux-core")
        .join("scripts")
        .join("settings.ps1");
    let fields = [
        "adapter",
        "command",
        "model_options",
        "model_sources",
        "reasoning_efforts",
        "local_access_note",
        "harness_availability",
        "credential_requirements",
        "execution_backend",
        "runtime_requirements",
        "analysis_posture",
        "prompt_transports",
        "auth_modes",
        "local_interactive_oauth_modes",
        "supports_parallel_runs",
        "supports_interrupt",
        "supports_structured_result",
        "supports_file_edit",
        "supports_subagents",
        "supports_verification",
        "supports_consultation",
        "supports_context_reset",
    ];
    let quoted_fields = fields
        .iter()
        .map(|field| format!("'{field}'"))
        .collect::<Vec<_>>()
        .join(", ");

    for provider in ["openrouter", "antigravity", "grok-build"] {
        let cli_output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args(["provider-capabilities", provider, "--json", "--project-dir"])
            .arg(&project_dir)
            .output()
            .expect("run Rust provider capability resolver");
        assert!(
            cli_output.status.success(),
            "Rust resolver failed for {provider}: {}",
            String::from_utf8_lossy(&cli_output.stderr)
        );
        let cli_json: serde_json::Value =
            serde_json::from_slice(&cli_output.stdout).expect("Rust capability output is JSON");

        let parity_script = project_dir.join(format!("provider-parity-{provider}.ps1"));
        let escaped_settings = settings_script.to_string_lossy().replace('\'', "''");
        fs::write(
            &parity_script,
            format!(
                ". '{escaped_settings}'\n$cap = Get-BridgeBuiltinProviderCapability -ProviderId '{provider}'\n$fields = @({quoted_fields})\n$result = [ordered]@{{}}\nforeach ($field in $fields) {{ if ($cap.Contains($field)) {{ $result[$field] = $cap[$field] }} }}\n$result | ConvertTo-Json -Depth 16 -Compress\n"
            ),
        )
        .expect("write PowerShell parity probe");
        let runtime_output = Command::new("pwsh")
            .args(["-NoLogo", "-NoProfile", "-File"])
            .arg(&parity_script)
            .output()
            .expect("run PowerShell capability source of truth");
        assert!(
            runtime_output.status.success(),
            "PowerShell resolver failed for {provider}: {}",
            String::from_utf8_lossy(&runtime_output.stderr)
        );
        let runtime_json: serde_json::Value = serde_json::from_slice(&runtime_output.stdout)
            .expect("PowerShell capability output is JSON");

        assert_eq!(
            cli_json["capabilities"], runtime_json,
            "Rust builtin mirror diverged from settings.ps1 for {provider}"
        );
    }
}

#[test]
fn operator_cli_workspace_plan_rejects_exact_duplicate_yaml_keys_before_interpretation() {
    let valid = workspace_plan_builtin_provider_yaml(
        "openrouter",
        "sakana/fugu-ultra",
        "provider-api",
        "file",
        "api-key-env",
    );
    let duplicate_cases = [
        (
            "runtime-root",
            valid.replacen(
                "config-version: 1",
                "config-version: 1\nworker-count: 1\nworker-count: 2",
                1,
            ),
        ),
        (
            "selected-recipe-id",
            valid.replace(
                "  review-one-slot:\n    schema-version: 1",
                "  review-one-slot:\n    schema-version: 1\n    panes: []\n    startup-actions: []\n  review-one-slot:\n    schema-version: 1",
            ),
        ),
        (
            "nested-settings",
            valid.replace(
                "    model-source: provider-api",
                "    model-source: provider-api\n    model-source: provider-default",
            ),
        ),
        (
            "nested-recipe",
            valid.replace("        region: main", "        region: main\n        region: side"),
        ),
    ];

    for (case_name, yaml) in duplicate_cases {
        let project_dir = make_temp_project_dir(&format!("workspace-plan-duplicate-{case_name}"));
        fs::write(project_dir.join(".winsmux.yaml"), yaml).expect("write duplicate YAML fixture");
        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(!output.status.success(), "{case_name} must fail closed");
        assert!(output.stdout.is_empty(), "{case_name} must not emit a plan");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("duplicate YAML mapping key"),
            "{case_name} stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn canonical_project_settings_reader_uses_shared_duplicate_key_gate() {
    let error = canonical_project_settings_reader::parse_str("worker-count: 1\nworker-count: 2\n")
        .err()
        .expect("direct settings reads must not collapse duplicate runtime-owned keys");
    assert_eq!(error.to_string(), "duplicate YAML mapping key.");
}

#[test]
fn operator_cli_workspace_plan_keeps_distinct_yaml_keys_valid() {
    let project_dir = make_temp_project_dir("workspace-plan-distinct-yaml-keys");
    let yaml = workspace_plan_builtin_provider_yaml(
        "openrouter",
        "sakana/fugu-ultra",
        "provider-api",
        "file",
        "api-key-env",
    )
    .replacen(
        "config-version: 1",
        "config-version: 1\nfuture-one: preserve\nfuture-two: preserve",
        1,
    );
    fs::write(project_dir.join(".winsmux.yaml"), yaml).expect("write distinct-key fixture");

    let output = run_workspace_plan(&project_dir, "review-one-slot");
    assert!(
        output.status.success(),
        "distinct keys must remain valid: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write_workspace_overlay_fixture(project_dir: &std::path::Path) {
    fs::write(
        project_dir.join(".winsmux.yaml"),
        workspace_plan_builtin_provider_yaml(
            "openrouter",
            "sakana/fugu-ultra",
            "provider-api",
            "file",
            "api-key-env",
        ),
    )
    .expect("write workspace overlay fixture");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("create workspace overlay directory");
}

#[test]
fn operator_cli_workspace_plan_validates_entire_provider_registry_envelope() {
    let rejected = [
        ("slots-array", r#"{"version":1,"slots":[]}"#),
        ("slots-string", r#"{"version":1,"slots":"worker-1"}"#),
        (
            "unselected-malformed",
            r#"{"version":1,"slots":{"reviewer-1":{"agent":"openrouter"},"worker-99":{"agent":true}}}"#,
        ),
        (
            "blank-slot-id",
            r#"{"version":1,"slots":{"   ":{"agent":"codex"}}}"#,
        ),
        (
            "case-duplicate-slot-id",
            r#"{"version":1,"slots":{"worker-99":{"agent":"codex"},"WORKER-99":{"agent":"codex"}}}"#,
        ),
    ];

    for (case_name, registry) in rejected {
        let project_dir = make_temp_project_dir(&format!("workspace-provider-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        fs::write(
            project_dir.join(".winsmux").join("provider-registry.json"),
            registry,
        )
        .expect("write provider registry case");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(!output.status.success(), "{case_name} must fail closed");
        assert!(
            output.stdout.is_empty(),
            "{case_name} must not emit a partial workspace plan"
        );
    }

    let accepted = [
        ("missing-slots", r#"{"version":1,"future":"keep"}"#),
        ("null-slots", r#"{"version":1,"slots":null}"#),
        (
            "valid-unrelated",
            r#"{"version":1,"future":{"keep":true},"slots":{"worker-99":{"agent":"codex","future":"keep"}}}"#,
        ),
    ];

    for (case_name, registry) in accepted {
        let project_dir = make_temp_project_dir(&format!("workspace-provider-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        fs::write(
            project_dir.join(".winsmux").join("provider-registry.json"),
            registry,
        )
        .expect("write provider registry control");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(
            output.status.success(),
            "{case_name} must remain accepted: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .expect("accepted workspace plan should be JSON");
    }
}

#[test]
fn operator_cli_workspace_plan_canonicalizes_provider_registry_entry_fields() {
    let project_dir = make_temp_project_dir("workspace-provider-canonical-fields");
    write_workspace_overlay_fixture(&project_dir);
    let settings_path = project_dir.join(".winsmux.yaml");
    let settings = fs::read_to_string(&settings_path)
        .expect("read workspace overlay fixture")
        .replace("prompt-transport: file", "prompt-transport: argv");
    fs::write(&settings_path, settings).expect("write lower-precedence argv fixture");
    fs::write(
        project_dir.join(".winsmux").join("provider-registry.json"),
        r#"{
  "version": 1,
  "slots": {
    "reviewer-1": {
      "Agent": "openrouter",
      "Model": "sakana/fugu-ultra",
      "Model-Source": "provider-api",
      "Reasoning-Effort": "provider-default",
      "Prompt-Transport": "file",
      "Auth-Mode": "api-key-env",
      "Updated-At-UTC": "2026-07-22T00:00:00Z",
      "Reason": "canonical alias control",
      "Future-Field": {"keep": true}
    }
  }
}"#,
    )
    .expect("write canonical provider registry fixture");

    let output = run_workspace_plan(&project_dir, "review-one-slot");
    assert!(
        output.status.success(),
        "Prompt-Transport must override lower-precedence argv: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let collisions = [
        ("agent", r#"{"agent":"openrouter","AGENT":"openrouter"}"#),
        ("model", r#"{"model":"one","MODEL":"two"}"#),
        (
            "model-source",
            r#"{"model_source":"provider-api","MODEL-SOURCE":"provider-api"}"#,
        ),
        (
            "reasoning-effort",
            r#"{"reasoning_effort":"provider-default","REASONING-EFFORT":"provider-default"}"#,
        ),
        (
            "prompt-transport",
            r#"{"prompt_transport":"file","PROMPT-TRANSPORT":"file"}"#,
        ),
        (
            "auth-mode",
            r#"{"auth_mode":"api-key-env","AUTH-MODE":"api-key-env"}"#,
        ),
        (
            "updated-at-utc",
            r#"{"updated_at_utc":"one","UPDATED-AT-UTC":"two"}"#,
        ),
        ("reason", r#"{"reason":"one","REASON":"two"}"#),
    ];

    for (case_name, entry) in collisions {
        let project_dir = make_temp_project_dir(&format!("workspace-provider-alias-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        let registry = format!(r#"{{"version":1,"slots":{{"reviewer-1":{entry}}}}}"#);
        fs::write(
            project_dir.join(".winsmux").join("provider-registry.json"),
            registry,
        )
        .expect("write provider registry collision fixture");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(!output.status.success(), "{case_name} collision must fail");
        assert!(
            output.stdout.is_empty(),
            "{case_name} collision must not emit a partial plan"
        );
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("failed to resolve the effective slot catalog"),
            "{case_name} collision must use the existing public error: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn operator_cli_workspace_plan_requires_canonical_runtime_role_version() {
    let accepted = [
        ("missing", r#"{"roles":{}}"#),
        ("numeric-one", r#"{"version":1,"roles":{}}"#),
    ];
    for (case_name, preferences) in accepted {
        let project_dir = make_temp_project_dir(&format!("workspace-role-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        fs::write(
            project_dir
                .join(".winsmux")
                .join("runtime-role-preferences.json"),
            preferences,
        )
        .expect("write runtime role preferences control");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(
            output.status.success(),
            "{case_name} must remain accepted: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let rejected = [
        ("numeric-two", r#"{"version":2,"roles":{}}"#),
        (
            "string-secret-marker",
            r#"{"version":"secret-marker-version","roles":{}}"#,
        ),
        ("string-two", r#"{"version":"2","roles":{}}"#),
        ("boolean", r#"{"version":true,"roles":{}}"#),
        ("null", r#"{"version":null,"roles":{}}"#),
        ("float", r#"{"version":1.0,"roles":{}}"#),
        ("object", r#"{"version":{"value":1},"roles":{}}"#),
        ("array", r#"{"version":[1],"roles":{}}"#),
    ];
    for (case_name, preferences) in rejected {
        let project_dir = make_temp_project_dir(&format!("workspace-role-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        fs::write(
            project_dir
                .join(".winsmux")
                .join("runtime-role-preferences.json"),
            preferences,
        )
        .expect("write runtime role preferences case");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(!output.status.success(), "{case_name} must fail closed");
        assert!(
            output.stdout.is_empty(),
            "{case_name} must not emit a partial workspace plan"
        );
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("secret-marker"),
            "{case_name} must not reflect the rejected version"
        );
    }
}

#[test]
fn operator_cli_workspace_plan_validates_all_runtime_roles_before_selection() {
    let rejected = [
        (
            "unselected-domain",
            r#"{"version":1,"roles":{"worker":{},"reviewer":{"reasoning_effort":"secret-marker-effort"}}}"#,
        ),
        (
            "unselected-nonscalar",
            r#"{"version":1,"roles":{"worker":{},"reviewer":{"model":{"secret-marker":"value"}}}}"#,
        ),
        (
            "object-alias-collision",
            r#"{"version":1,"roles":{"worker":{},"reviewer":{"agent":"codex","provider":"openrouter"}}}"#,
        ),
        (
            "array-identity-collision",
            r#"{"version":1,"roles":[{"runtimeRole":"worker"},{"role_id":"reviewer","runtime_role":"reviewer"}]}"#,
        ),
        (
            "unselected-transport-domain",
            r#"{"version":1,"roles":{"worker":{},"reviewer":{"promptTransport":"socket"}}}"#,
        ),
        (
            "object-identity-duplicate",
            r#"{"version":1,"roles":{" secret-marker-reviewer ":{},"SECRET-MARKER-REVIEWER":{}}}"#,
        ),
        (
            "array-identity-alias-duplicate",
            r#"{"version":1,"roles":[{"roleId":"reviewer"},{"runtime_role":" REVIEWER "}]}"#,
        ),
        (
            "missing-identity-still-validates",
            r#"{"version":1,"roles":[{"reasoningEffort":"secret-marker-effort"},{"roleId":"worker"}]}"#,
        ),
    ];
    for (case_name, preferences) in rejected {
        let project_dir = make_temp_project_dir(&format!("workspace-role-all-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        fs::write(
            project_dir
                .join(".winsmux")
                .join("runtime-role-preferences.json"),
            preferences,
        )
        .expect("write invalid unselected runtime role");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(!output.status.success(), "{case_name} must fail closed");
        assert!(
            output.stdout.is_empty(),
            "{case_name} must not emit a partial plan"
        );
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("secret-marker"),
            "{case_name} must not reflect a rejected value"
        );
    }

    let accepted = [
        (
            "object-aliases",
            r#"{"version":1,"roles":{"worker":{"provider":"openrouter","modelSource":"provider-api","reasoning-effort":"provider-default","promptTransport":"file","auth-mode":"api-key-env","future":{"keep":true}}}}"#,
        ),
        (
            "array-aliases",
            r#"{"version":1,"roles":[{"runtimeRole":"worker","provider":"openrouter","model-source":"provider-api","reasoningEffort":"provider-default","prompt-transport":"file","auth_mode":"api-key-env"}]}"#,
        ),
        (
            "legacy-root-version",
            r#"{"version":1,"worker":{"provider":"openrouter","promptTransport":"file"}}"#,
        ),
        (
            "distinct-object-identities",
            r#"{"version":1,"roles":{"worker":{"promptTransport":"file"},"reviewer":{}}}"#,
        ),
        (
            "missing-and-blank-array-identities",
            r#"{"version":1,"roles":[{"model":"unselected"},{"roleId":"  ","promptTransport":"file"},{"runtimeRole":"worker","promptTransport":"file"}]}"#,
        ),
    ];
    for (case_name, preferences) in accepted {
        let project_dir = make_temp_project_dir(&format!("workspace-role-control-{case_name}"));
        write_workspace_overlay_fixture(&project_dir);
        let settings_path = project_dir.join(".winsmux.yaml");
        let settings = fs::read_to_string(&settings_path)
            .expect("read workspace role fixture")
            .replace("    prompt-transport: file\n", "");
        fs::write(&settings_path, settings).expect("remove slot prompt transport");
        fs::write(
            project_dir
                .join(".winsmux")
                .join("runtime-role-preferences.json"),
            preferences,
        )
        .expect("write canonical runtime role control");

        let output = run_workspace_plan(&project_dir, "review-one-slot");
        assert!(
            output.status.success(),
            "{case_name} must remain accepted: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

struct ChildKillGuard(Child);

impl Drop for ChildKillGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn wait_for_stream_line(
    receiver: &mpsc::Receiver<String>,
    mut append_event: impl FnMut(usize),
) -> String {
    for attempt in 0..20 {
        append_event(attempt);
        if let Ok(line) = receiver.recv_timeout(Duration::from_millis(250)) {
            return line;
        }
    }
    panic!("stream should emit one refresh item");
}

#[test]
fn operator_cli_status_json_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("status-json");
    write_manifest(&project_dir);

    let json = run_json(&project_dir, &["status", "--json"]);

    assert_eq!(json["session"]["name"], "winsmux-orchestra");
    assert_eq!(json["session"]["pane_count"], 2);
    assert_eq!(json["session"]["event_count"], 2);
    assert!(json["generated_at"].as_str().is_some());
    assert_eq!(
        json["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(json["summary"]["review_pending"], 1);
    assert_eq!(json["panes"][0]["label"], "builder-1");
    assert_eq!(json["panes"][0]["changed_files"][0], "core/src/main.rs");
}

#[test]
fn operator_cli_board_json_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("board-json");
    write_manifest(&project_dir);

    let json = run_json(&project_dir, &["board", "--json"]);

    assert_eq!(json["summary"]["pane_count"], 2);
    assert!(json["generated_at"].as_str().is_some());
    assert_eq!(
        json["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(json["summary"]["dirty_panes"], 1);
    assert_eq!(json["summary"]["by_state"]["running"], 1);
    assert_eq!(json["summary"]["by_task_state"]["in_progress"], 1);
    assert_eq!(json["panes"][0]["task_id"], "TASK-266");
    assert_eq!(json["panes"][1]["role"], "Reviewer");
}

#[test]
#[cfg(windows)]
fn operator_cli_delegates_wrapper_commands_to_winsmux_core_script() {
    let project_dir = make_temp_project_dir("winsmux-core-bridge");
    let script_path = project_dir.join("winsmux-core-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("list")
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("bridge:list"),
        "unexpected stdout: {stdout}"
    );
}

#[test]
#[cfg(windows)]
fn operator_cli_forwards_namespace_flags_to_winsmux_core_script() {
    let project_dir = make_temp_project_dir("winsmux-core-namespace-bridge");
    let script_path = project_dir.join("winsmux-core-namespace-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:L=$env:WINSMUX_BRIDGE_NAMESPACE_L;S=$env:WINSMUX_BRIDGE_SOCKET_S;N=$env:WINSMUX_BRIDGE_SESSION_NAMESPACE;args=" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["-L", "ops", "-S", "socket-name", "list"])
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("bridge:L=ops;S=socket-name;N=socket-name;args=list"),
        "unexpected stdout: {stdout}"
    );
}

#[test]
#[cfg(windows)]
fn operator_cli_resolves_relative_socket_path_before_bridge_delegation() {
    let project_dir = make_temp_project_dir("winsmux-core-relative-socket-bridge");
    let script_path = project_dir.join("winsmux-core-relative-socket-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:S=$env:WINSMUX_BRIDGE_SOCKET_S;N=$env:WINSMUX_BRIDGE_SESSION_NAMESPACE;args=" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["-S", "mux.sock", "list"])
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let expected_socket = project_dir
        .join("mux.sock")
        .to_string_lossy()
        .replace('\\', "/")
        .to_lowercase();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(&format!("bridge:S={expected_socket};N=socket-")),
        "unexpected stdout: {stdout}"
    );
    assert!(stdout.contains(";args=list"), "unexpected stdout: {stdout}");
}

#[test]
#[cfg(windows)]
fn operator_cli_uses_socket_path_for_native_target_resolution() {
    let project_dir = make_temp_project_dir("winsmux-core-socket-target");
    let home_dir = project_dir.join("home");
    let psmux_dir = home_dir.join(".psmux");
    fs::create_dir_all(&psmux_dir).expect("test should create psmux dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "-L",
            "ops",
            "-S",
            "socket-name",
            "display-message",
            "-t",
            "winsmux-orchestra",
            "-p",
            "probe",
        ])
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .env_remove("PSMUX_TARGET_SESSION")
        .env_remove("PSMUX_TARGET_FULL")
        .env_remove("TMUX")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        !output.status.success(),
        "winsmux command should fail because the test only checks target resolution"
    );
    assert!(
        stderr.contains("socket-name__winsmux-orchestra"),
        "expected -S to select the socket namespace, got stderr={stderr}"
    );
    assert!(
        !stderr.contains("ops__winsmux-orchestra"),
        "expected -S to take precedence over -L, got stderr={stderr}"
    );
}

#[test]
fn operator_cli_keeps_native_operator_commands_in_rust_binary() {
    let project_dir = make_temp_project_dir("winsmux-core-native");
    write_manifest(&project_dir);
    let script_path = project_dir.join("winsmux-core-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["board", "--json"])
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !stdout.contains("bridge:"),
        "native command unexpectedly delegated: {stdout}"
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("board output should be JSON");
    assert_eq!(json["summary"]["pane_count"], 2);
}

#[test]
fn operator_cli_operator_jobs_catalog_reports_maintenance_contract() {
    let project_dir = make_temp_project_dir("operator-jobs-catalog");

    let json = run_json(&project_dir, &["operator-jobs", "catalog", "--json"]);

    assert_eq!(json["packet_type"], "operator_job_catalog");
    assert_eq!(json["public_state_ref"], ".winsmux/operator-jobs.json");
    assert_eq!(
        json["approval_contract"]["destructive_changes_require_explicit_approval"],
        true
    );
    assert_eq!(json["schedule_contract"]["supported_types"][0], "one-time");
    assert!(json["supported_jobs"]
        .as_array()
        .expect("supported jobs should be an array")
        .iter()
        .any(|job| job["kind"] == "repository-hygiene"));
}

#[test]
fn operator_cli_operator_jobs_create_and_run_records_fresh_approval_pending() {
    let project_dir = make_temp_project_dir("operator-jobs-run");

    let created = run_json(
        &project_dir,
        &[
            "operator-jobs",
            "create",
            "deps-weekly",
            "--kind",
            "dependency-check",
            "--schedule",
            "recurring",
            "--every",
            "weekly",
            "--destructive",
            "--json",
        ],
    );
    assert_eq!(created["job"]["job_id"], "deps-weekly");
    assert_eq!(
        created["job"]["command_plan"]["side_effect_policy"],
        "record_pending_approval_only"
    );

    let first_run = run_json(
        &project_dir,
        &[
            "operator-jobs",
            "run",
            "deps-weekly",
            "--evidence",
            "dependency report collected",
            "--json",
        ],
    );
    assert_eq!(first_run["run"]["run_number"], 1);
    assert_eq!(first_run["run"]["fresh_record"], true);
    assert_eq!(first_run["run"]["status"], "approval_pending");
    assert_eq!(first_run["run"]["approval_gate"]["required"], true);
    assert_eq!(
        first_run["run"]["approval_gate"]["state"],
        "pending_operator_approval"
    );
    assert_eq!(
        first_run["run"]["evidence"][0]["reference"],
        ".winsmux/operator-jobs.json"
    );

    let second_run = run_json(
        &project_dir,
        &["operator-jobs", "run", "deps-weekly", "--json"],
    );
    assert_eq!(second_run["run"]["run_number"], 2);
    assert_ne!(first_run["run"]["run_id"], second_run["run"]["run_id"]);

    let state_path = project_dir.join(".winsmux").join("operator-jobs.json");
    let state = read_json_file(&state_path);
    assert_eq!(state["jobs"][0]["runs"].as_array().unwrap().len(), 2);
    let raw_state = fs::read_to_string(state_path).expect("test should read operator jobs state");
    assert!(
        !raw_state.contains(project_dir.to_str().expect("temp path should be utf-8")),
        "operator jobs state should not store local absolute paths"
    );
}

#[test]
fn operator_cli_operator_jobs_run_reads_state_under_the_write_lock() {
    let project_dir = make_temp_project_dir("operator-jobs-run-lock");

    run_json(
        &project_dir,
        &[
            "operator-jobs",
            "create",
            "deps-weekly",
            "--kind",
            "dependency-check",
            "--schedule",
            "recurring",
            "--every",
            "weekly",
            "--json",
        ],
    );

    let state_path = project_dir.join(".winsmux").join("operator-jobs.json");
    let mut lock_os = state_path.as_os_str().to_os_string();
    lock_os.push(".lock");
    let lock_path = std::path::PathBuf::from(lock_os);
    fs::create_dir_all(&lock_path).expect("test should hold operator jobs lock");
    fs::write(
        lock_path.join("owner.json"),
        format!(
            r#"{{"pid":{},"started_at":"2026-01-01T00:00:00Z"}}"#,
            std::process::id()
        ),
    )
    .expect("test should write lock owner");

    let child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["operator-jobs", "run", "deps-weekly", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("winsmux command should start while lock is held");

    std::thread::sleep(Duration::from_millis(250));

    let mut state = read_json_file(&state_path);
    state["jobs"][0]["runs"]
        .as_array_mut()
        .expect("runs should be an array")
        .push(serde_json::json!({
            "run_id": "operator-job:deps-weekly:1",
            "run_number": 1,
            "status": "evidence_recorded",
            "started_at": "2026-01-01T00:00:01Z",
            "fresh_record": true,
            "evidence": [],
            "approval_gate": {
                "required": false,
                "state": "not_required",
                "destructive_change": false,
                "approved_by": null,
                "approved_at": null,
                "reason": "manual concurrent state update"
            }
        }));
    fs::write(
        &state_path,
        format!(
            "{}\n",
            serde_json::to_string_pretty(&state).expect("state should serialize")
        ),
    )
    .expect("test should update operator jobs state while lock is held");
    fs::remove_dir_all(&lock_path).expect("test should release operator jobs lock");

    let output = child
        .wait_with_output()
        .expect("winsmux command should finish");
    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let run: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert_eq!(run["run"]["run_number"], 2);

    let state = read_json_file(&state_path);
    let runs = state["jobs"][0]["runs"]
        .as_array()
        .expect("runs should be an array");
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0]["run_number"], 1);
    assert_eq!(runs[1]["run_number"], 2);
}

#[test]
fn operator_cli_operator_jobs_pause_update_delete_keeps_destructive_delete_pending() {
    let project_dir = make_temp_project_dir("operator-jobs-update-delete");

    run_json(
        &project_dir,
        &[
            "operator-jobs",
            "create",
            "docs-refresh",
            "--kind",
            "documentation-refresh",
            "--schedule",
            "one-time",
            "--json",
        ],
    );

    let paused = run_json(
        &project_dir,
        &["operator-jobs", "pause", "docs-refresh", "--json"],
    );
    assert_eq!(paused["job"]["status"], "paused");

    let updated = run_json(
        &project_dir,
        &[
            "operator-jobs",
            "update",
            "docs-refresh",
            "--title",
            "Public docs refresh",
            "--json",
        ],
    );
    assert_eq!(updated["job"]["title"], "Public docs refresh");
    assert_eq!(updated["job"]["pending_update"], serde_json::Value::Null);

    let deleted = run_json(
        &project_dir,
        &[
            "operator-jobs",
            "delete",
            "docs-refresh",
            "--reason",
            "replace with monthly docs job",
            "--json",
        ],
    );
    assert_eq!(deleted["job"]["status"], "delete_pending_approval");
    assert_eq!(
        deleted["job"]["pending_update"]["approval_gate"]["required"],
        true
    );
    assert_eq!(
        deleted["job"]["pending_update"]["approval_gate"]["state"],
        "pending_operator_approval"
    );

    let listed = run_json(&project_dir, &["operator-jobs", "list", "--json"]);
    assert_eq!(listed["jobs"][0]["job_id"], "docs-refresh");
    assert_eq!(listed["jobs"][0]["status"], "delete_pending_approval");
}

#[test]
fn operator_cli_board_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("board-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("board")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Label"));
    assert!(stdout.contains("TaskState"));
    assert!(stdout.contains("builder-1"));
    assert!(stdout.contains("reviewer-1"));
    assert!(stdout.contains("in_progress"));
    assert!(stdout.contains("pending"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_runs_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("runs-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("runs")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("RunId"));
    assert!(stdout.contains("ActionItems"));
    assert!(stdout.contains("task:TASK-266"));
    assert!(stdout.contains("builder-1"));
    assert!(stdout.contains("Add Rust operator read models"));
    assert!(stdout.contains("pending"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_meta_plan_json_writes_plan_artifacts_and_audit_log() {
    let project_dir = make_temp_project_dir("meta-plan-json");
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "日本語IME対応を含むメタ計画を作る",
            "--json",
        ],
    );

    assert_eq!(json["command"], "meta-plan");
    assert_eq!(json["contract_version"], 1);
    assert_eq!(
        json["roles"]
            .as_array()
            .expect("roles should be an array")
            .len(),
        2
    );
    assert_eq!(json["roles"][0]["role_id"], "investigator");
    assert_eq!(json["roles"][0]["model_source"], "provider-default");
    assert_eq!(json["roles"][0]["reasoning_effort"], "provider-default");
    assert_eq!(json["roles"][0]["launch_contract"]["model_override"], false);
    assert_eq!(
        json["roles"][0]["launch_contract"]["args"][0],
        "--permission-mode"
    );
    assert_eq!(json["roles"][0]["launch_contract"]["args"][1], "plan");
    assert_eq!(json["roles"][1]["role_id"], "verifier");
    assert_eq!(json["roles"][1]["launch_contract"]["args"][2], "read-only");
    assert_eq!(json["approval_gate"]["single_user_approval"], true);
    assert_eq!(json["approval_gate"]["worker_execution_allowed"], false);
    assert_eq!(json["review_rounds"], 1);

    let plan_ref = json["integrated_plan_ref"]
        .as_str()
        .expect("integrated plan ref should be present");
    let plan_path = project_dir.join(plan_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let plan = fs::read_to_string(plan_path).expect("test should read integrated plan");
    assert!(plan.contains("Task hash:"));
    assert!(!plan.contains("日本語IME対応を含むメタ計画を作る"));
    assert!(plan.contains("## Safety And Approval Gates"));
    assert!(plan.contains("Private task and role prompt bodies are not retained"));

    let draft_ref = json["roles"][0]["draft_ref"]
        .as_str()
        .expect("draft ref should be present");
    let draft_path = project_dir.join(draft_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let draft = fs::read_to_string(draft_path).expect("test should read draft");
    assert!(draft.contains("Task hash:"));
    assert!(draft.contains("Role prompt hash:"));
    assert!(!draft.contains("日本語IME対応を含むメタ計画を作る"));
    assert!(!draft.contains("Gather facts, constraints, and unknowns. Do not edit files."));
    assert_eq!(
        json["roles"][0]["prompt_hash"]
            .as_str()
            .expect("prompt hash should be present")
            .len(),
        64
    );

    let audit_ref = json["audit_log_ref"]
        .as_str()
        .expect("audit log ref should be present");
    let audit_path = project_dir.join(audit_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let audit_raw = fs::read_to_string(audit_path).expect("test should read audit log");
    let events: Vec<serde_json::Value> = audit_raw
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("audit line should be JSON"))
        .collect();
    let event_names: Vec<&str> = events
        .iter()
        .filter_map(|event| event["event"].as_str())
        .collect();
    for expected in [
        "meta_plan_init",
        "role_assigned",
        "plan_drafted",
        "cross_review",
        "plan_merged",
        "exit_plan_mode",
    ] {
        assert!(
            event_names.contains(&expected),
            "missing audit event {expected}: {event_names:?}"
        );
    }
    let role_assigned = events
        .iter()
        .filter(|event| event["event"] == "role_assigned")
        .count();
    assert_eq!(role_assigned, 2);
    assert!(events.iter().any(|event| {
        event["event"] == "meta_plan_init"
            && event["data"]["shield_harness"]["private_prompt_bodies_in_artifacts"] == false
    }));
    assert!(events
        .iter()
        .filter(|event| event["event"] == "role_assigned")
        .all(|event| event["data"]["read_only"] == true));
    assert!(events
        .iter()
        .filter(|event| event["event"] == "role_assigned")
        .all(|event| event["data"]["prompt_hash"]
            .as_str()
            .map(|value| value.len() == 64)
            .unwrap_or(false)));
}

#[test]
fn operator_cli_meta_plan_roles_yaml_preserves_japanese_and_two_review_rounds() {
    let project_dir = make_temp_project_dir("meta-plan-roles-yaml");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    review_rounds: 2
    capabilities: [facts, constraints]
    prompt: |
      日本語コメントを壊さず、事実と制約を集める。
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    review_rounds: 2
    capabilities: [risk, tests]
    prompt: |
      回帰リスクと不足テストを確認する。
  - role_id: advocate
    label: "利用者代弁役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    review_rounds: 2
    capabilities: [acceptance]
    prompt: |
      利用者の受け入れ条件を整理する。
"#,
    )
    .expect("test should write role YAML");

    let role_file_text = role_file.to_string_lossy().to_string();
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "日本語IME対応のロール計画",
            "--roles",
            &role_file_text,
            "--review-rounds",
            "2",
            "--json",
        ],
    );

    assert_eq!(
        json["roles"]
            .as_array()
            .expect("roles should be an array")
            .len(),
        3
    );
    assert_eq!(json["roles"][0]["label"], "調査役");
    assert_eq!(json["roles"][2]["label"], "利用者代弁役");
    assert_eq!(json["review_rounds"], 2);
    assert!(json["role_source"]
        .as_str()
        .unwrap_or_default()
        .starts_with("yaml:roles.yaml:sha256:"));
    assert_eq!(
        json["cross_reviews"]
            .as_array()
            .expect("cross reviews should be an array")
            .len(),
        12
    );

    let draft_ref = json["roles"][0]["draft_ref"]
        .as_str()
        .expect("draft ref should be present");
    let draft_path = project_dir.join(draft_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let draft = fs::read_to_string(draft_path).expect("test should read draft");
    assert!(draft.contains("Role prompt hash:"));
    assert!(!draft.contains("日本語コメントを壊さず、事実と制約を集める。"));
    assert_eq!(
        json["roles"][0]["prompt_hash"]
            .as_str()
            .expect("prompt hash should be present")
            .len(),
        64
    );

    let audit_ref = json["audit_log_ref"]
        .as_str()
        .expect("audit log ref should be present");
    let audit_path = project_dir.join(audit_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let audit_raw = fs::read_to_string(audit_path).expect("test should read audit log");
    assert_eq!(
        audit_raw
            .lines()
            .filter(|line| line.contains("\"event\":\"cross_review\""))
            .count(),
        12
    );
}

#[test]
fn operator_cli_meta_plan_roles_yaml_accepts_capability_registry_provider() {
    let project_dir = make_temp_project_dir("meta-plan-capability-provider");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "local-research": {
      "adapter": "gemini",
      "command": "gemini-cli",
      "prompt_transports": ["file"],
      "supports_file_edit": false,
      "supports_verification": true
    }
  }
}"#,
    )
    .expect("test should write provider capabilities");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    capabilities: [facts]
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [tests]
  - role_id: domain
    label: "領域専門役"
    provider: local-research
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [domain_research]
"#,
    )
    .expect("test should write role YAML");

    let role_file_text = role_file.to_string_lossy().to_string();
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "capability-driven role plan",
            "--roles",
            &role_file_text,
            "--json",
        ],
    );

    assert_eq!(
        json["roles"]
            .as_array()
            .expect("roles should be an array")
            .len(),
        3
    );
    assert_eq!(json["roles"][2]["provider"], "local-research");
    assert_eq!(json["roles"][2]["provider_adapter"], "gemini");
    assert_eq!(
        json["roles"][2]["launch_contract"]["provider_adapter"],
        "gemini"
    );
    assert_eq!(json["roles"][2]["launch_contract"]["command"], "gemini-cli");
    assert_eq!(
        json["roles"][2]["launch_contract"]["args"][0],
        "--approval-mode=plan"
    );
    assert_eq!(json["roles"][2]["launch_contract"]["model_override"], false);
    assert_eq!(
        json["roles"][2]["launch_contract"]["read_only_equivalent"],
        true
    );
}

#[test]
fn operator_cli_meta_plan_roles_yaml_uses_capability_registry_for_builtin_provider() {
    let project_dir = make_temp_project_dir("meta-plan-builtin-capability-provider");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv"],
      "supports_file_edit": true,
      "supports_verification": true
    }
  }
}"#,
    )
    .expect("test should write provider capabilities");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    capabilities: [facts]
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [tests]
  - role_id: advocate
    label: "利用者代弁役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [acceptance]
"#,
    )
    .expect("test should write role YAML");

    let role_file_text = role_file.to_string_lossy().to_string();
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "capability registry should override builtin command",
            "--roles",
            &role_file_text,
            "--json",
        ],
    );

    assert_eq!(json["roles"][0]["launch_contract"]["command"], "claude");
    assert_eq!(
        json["roles"][1]["launch_contract"]["command"],
        "codex-nightly"
    );
    assert_eq!(
        json["roles"][2]["launch_contract"]["command"],
        "codex-nightly"
    );
}

#[test]
fn operator_cli_meta_plan_roles_yaml_rejects_mutating_roles() {
    let project_dir = make_temp_project_dir("meta-plan-roles-yaml-reject");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: false
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
  - role_id: advocate
    label: "利用者代弁役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
"#,
    )
    .expect("test should write role YAML");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "meta-plan",
            "--task",
            "reject mutating role",
            "--roles",
            role_file.to_str().expect("path should be utf-8"),
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        !output.status.success(),
        "meta-plan should reject mutating roles"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("must set read_only: true"), "{stderr}");
}

#[test]
fn operator_cli_explain_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("explain-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "task:TASK-266"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Run: task:TASK-266"));
    assert!(stdout.contains("Task: Add Rust operator read models"));
    assert!(stdout.contains("Primary: builder-1 (%2)"));
    assert!(stdout.contains("Next: commit_ready"));
    assert!(stdout.contains("Changed files:"));
    assert!(stdout.contains("- core/src/main.rs"));
    assert!(stdout.contains("Recent events:"));
    assert!(stdout.contains("operator.commit_ready"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_explain_follow_reports_matching_events() {
    let project_dir = make_temp_project_dir("explain-follow");
    write_manifest(&project_dir);

    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "task:TASK-266", "--follow", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("winsmux follow command should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let _child = ChildKillGuard(child);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else {
                break;
            };
            let _ = sender.send(line);
        }
    });

    let initial_line = receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("follow should print the initial explain payload");
    let initial: serde_json::Value =
        serde_json::from_str(initial_line.trim()).expect("initial output should be json");
    assert_eq!(initial["run"]["run_id"], "task:TASK-266");

    let line = wait_for_stream_line(&receiver, |attempt| {
        let mut events = fs::OpenOptions::new()
            .append(true)
            .open(project_dir.join(".winsmux").join("events.jsonl"))
            .expect("test should open events file");
        use std::io::Write as _;
        writeln!(
            events,
            r#"{{"timestamp":"2026-04-24T12:10:{:02}+09:00","session":"winsmux-orchestra","event":"operator.followup","message":"new evidence arrived","role":"Builder","branch":"codex/task266-rust-operator-readmodels-20260424","data":{{"next_action":"review","test_plan":"run focused test | inspect logs"}}}}"#,
            attempt + 1
        )
        .expect("test should append follow event");
        events.flush().expect("test should flush events");
    });
    let item: serde_json::Value =
        serde_json::from_str(line.trim()).expect("follow output should be json");

    assert_eq!(item["event"], "operator.followup");
    assert_eq!(item["message"], "new evidence arrived");
    assert_eq!(
        item["branch"],
        "codex/task266-rust-operator-readmodels-20260424"
    );
    assert_eq!(item["test_plan"][0], "run focused test");
    assert_eq!(item["test_plan"][1], "inspect logs");
    assert_eq!(item["next_action"], "review");
}

#[test]
fn operator_cli_explain_follow_usage_includes_follow_flag() {
    let project_dir = make_temp_project_dir("explain-follow-usage");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("usage: winsmux explain <run_id> [--json] [--follow]"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("explain")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("usage: winsmux explain <run_id> [--json] [--follow]"));
}

#[test]
fn operator_cli_inbox_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("inbox-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("inbox")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Kind"));
    assert!(stdout.contains("Message"));
    assert!(stdout.contains("review_pending"));
    assert!(stdout.contains("builder-1"));
    assert!(stdout.contains("pending"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_digest_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("digest-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("digest")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Run: task:TASK-266"));
    assert!(stdout.contains("Primary: builder-1 (%2)"));
    assert!(stdout.contains("Task: Add Rust operator read models"));
    assert!(stdout.contains("State: in_progress / pending"));
    assert!(stdout.contains("Next: commit_ready"));
    assert!(stdout.contains("Git: codex/task266-rust-operator-readmodels-20260424 @ abc123"));
    assert!(stdout.contains("Changed files (2):"));
    assert!(stdout.contains("- core/src/operator_cli.rs"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_inbox_digest_runs_and_explain_use_ledger_projections() {
    let project_dir = make_temp_project_dir("read-models");
    write_manifest(&project_dir);

    let inbox = run_json(&project_dir, &["inbox", "--json"]);
    assert!(inbox["generated_at"].as_str().is_some());
    assert_eq!(
        inbox["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(inbox["summary"]["by_kind"]["review_pending"], 1);
    assert_eq!(inbox["items"][0]["kind"], "review_pending");

    let digest = run_json(&project_dir, &["digest", "--json"]);
    assert!(digest["generated_at"].as_str().is_some());
    assert_eq!(digest["items"][0]["run_id"], "task:TASK-266");
    assert_eq!(digest["items"][0]["review_state"], "pending");

    let desktop_summary = run_json(&project_dir, &["desktop-summary", "--json"]);
    assert!(desktop_summary["generated_at"].as_str().is_some());
    assert!(desktop_summary["board"]["generated_at"].as_str().is_some());
    assert!(desktop_summary["inbox"]["project_dir"].as_str().is_some());
    assert!(desktop_summary["digest"]["generated_at"].as_str().is_some());
    assert_eq!(desktop_summary["board"]["summary"]["pane_count"], 2);
    assert!(desktop_summary["board"]["panes"][0]
        .get("tokens_remaining")
        .is_some());
    assert!(desktop_summary["board"]["panes"][0]
        .get("task_owner")
        .is_some());
    assert!(desktop_summary["board"]["panes"][0]
        .get("event_count")
        .is_none());
    assert_eq!(desktop_summary["inbox"]["summary"]["item_count"], 2);
    assert_eq!(desktop_summary["digest"]["summary"]["item_count"], 2);
    assert_eq!(
        desktop_summary["run_projections"][0]["run_id"],
        "task:TASK-266"
    );
    assert_eq!(
        desktop_summary["run_projections"][0]["summary"],
        "Add Rust operator read models"
    );
    assert_eq!(
        desktop_summary["run_projections"][0]["next_action"],
        "commit_ready"
    );

    let runs = run_json(&project_dir, &["runs", "--json"]);
    assert_eq!(runs["summary"]["run_count"], 2);
    assert_eq!(runs["summary"]["review_pending"], 1);
    assert_eq!(runs["summary"]["dirty_runs"], 1);
    let task_run = runs["runs"]
        .as_array()
        .expect("runs should be an array")
        .iter()
        .find(|run| run["run_id"] == "task:TASK-266")
        .expect("task run should exist");
    assert_eq!(task_run["run_packet"]["priority"], "P0");
    assert_eq!(
        task_run["run_packet"]["task"],
        "Add Rust operator read models"
    );
    assert_eq!(
        task_run["run_packet"]["branch"],
        "codex/task266-rust-operator-readmodels-20260424"
    );
    assert_eq!(task_run["run_packet"]["labels"][0], "builder-1");
    assert_eq!(task_run["action_items"][0]["kind"], "review_pending");

    let explain = run_json(&project_dir, &["explain", "task:TASK-266", "--json"]);
    assert!(explain["generated_at"].as_str().is_some());
    assert_eq!(
        explain["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(explain["run"]["run_id"], "task:TASK-266");
    assert_eq!(
        explain["observation_pack"]["summary"],
        "captured operator read model"
    );
    assert!(explain["observation_pack"]["packet_type"].is_null());
    assert_eq!(
        explain["consultation_packet"]["recommendation"],
        "keep read-only"
    );
    assert_eq!(explain["explanation"]["next_action"], "commit_ready");
}

#[test]
fn operator_cli_desktop_summary_text_reports_counts() {
    let project_dir = make_temp_project_dir("desktop-summary-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["desktop-summary"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Desktop summary: 2 panes, 2 inbox items, 2 digest items, 2 projections")
    );
}

#[test]
fn operator_cli_desktop_summary_stream_reports_refresh_events() {
    let project_dir = make_temp_project_dir("desktop-summary-stream");
    write_manifest(&project_dir);

    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["desktop-summary", "--stream", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("winsmux stream command should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let _child = ChildKillGuard(child);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(stdout).read_line(&mut line);
        let _ = sender.send(line);
    });

    let line = wait_for_stream_line(&receiver, |attempt| {
        let mut events = fs::OpenOptions::new()
            .append(true)
            .open(project_dir.join(".winsmux").join("events.jsonl"))
            .expect("test should open events file");
        use std::io::Write as _;
        writeln!(
            events,
            r#"{{"timestamp":"2026-04-24T12:00:{:02}+09:00","session":"winsmux-orchestra","event":"operator.followup","pane_id":"%2","data":{{"task_id":"TASK-999"}}}}"#,
            attempt + 3
        )
        .expect("test should append event");
        events.flush().expect("test should flush events");
    });
    let item: serde_json::Value =
        serde_json::from_str(line.trim()).expect("stream output should be json");

    assert_eq!(item["source"], "summary");
    assert_eq!(item["reason"], "operator.followup");
    assert_eq!(item["pane_id"], "%2");
    assert_eq!(item["run_id"], "task:TASK-999");
}

#[test]
fn operator_cli_desktop_summary_stream_accepts_top_level_run_fields() {
    let project_dir = make_temp_project_dir("desktop-summary-stream-top-level");
    write_manifest(&project_dir);

    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["desktop-summary", "--stream", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("winsmux stream command should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let _child = ChildKillGuard(child);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(stdout).read_line(&mut line);
        let _ = sender.send(line);
    });

    let line = wait_for_stream_line(&receiver, |attempt| {
        let mut events = fs::OpenOptions::new()
            .append(true)
            .open(project_dir.join(".winsmux").join("events.jsonl"))
            .expect("test should open events file");
        use std::io::Write as _;
        writeln!(
            events,
            r#"{{"timestamp":"2026-04-24T12:00:{:02}+09:00","session":"winsmux-orchestra","event":"operator.followup","pane_id":"%2","run_id":"manual:1","task_id":"TASK-999","data":{{}}}}"#,
            attempt + 3
        )
        .expect("test should append event");
        events.flush().expect("test should flush events");
    });
    let item: serde_json::Value =
        serde_json::from_str(line.trim()).expect("stream output should be json");

    assert_eq!(item["source"], "summary");
    assert_eq!(item["reason"], "operator.followup");
    assert_eq!(item["run_id"], "manual:1");
}

#[test]
fn operator_cli_provider_capabilities_json_reads_registry() {
    let project_dir = make_temp_project_dir("provider-capabilities-json");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default", "reasoning_efforts": ["provider-default"]},
        {"id": "gpt-5.3-codex-spark", "label": "GPT-5.3-Codex-Spark", "source": "cli-discovery", "availability": "local-account", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.4", "label": "GPT-5.4", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-terra", "label": "GPT-5.6 Terra", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-luna", "label": "GPT-5.6 Luna", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]}
      ],
      "model_sources": ["provider-default", "cli-discovery"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh"],
      "local_access_note": "Local Codex CLI catalog and ChatGPT account access.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Codex CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["local_interactive"],
      "supports_subagents": true
    },
    "local-openai-compatible": {
      "adapter": "openai-compatible",
      "display_name": "Local OpenAI-compatible endpoint",
      "command": "winsmux-local-llm",
      "model_options": [
        {"id": "operator-selected", "label": "Operator-selected runtime model", "source": "operator-override", "availability": "runtime-discovery"}
      ],
      "model_sources": ["operator-override"],
      "reasoning_efforts": ["provider-default"],
      "model_catalog_source": "runtime-health-endpoint",
      "local_access_note": "Local endpoint owns model access and request handling.",
      "harness_availability": "external-adapter",
      "credential_requirements": "runtime-owned-local-endpoint",
      "execution_backend": "openai-compatible-local-endpoint",
      "api_base_url": "http://127.0.0.1:8080/v1",
      "api_key_env": "WINSMUX_LOCAL_OPENAI_COMPATIBLE_API_KEY",
      "runtime_requirements": "127.0.0.1 endpoint; GPU/CPU capacity owned by runtime.",
      "analysis_posture": "read-only-analysis",
      "prompt_transports": ["stdin"],
      "auth_modes": ["none", "local-api-key"],
      "read_only_launch_args": ["--read-only", "--no-file-edits"],
      "supports_file_edit": false,
      "supports_verification": false,
      "supports_consultation": true
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"],
      "supports_parallel_runs": true
    }
  }
}"#,
    )
    .expect("test should write provider registry");

    let registry = run_json(&project_dir, &["provider-capabilities", "--json"]);

    assert_eq!(registry["version"], 1);
    let registry_path = registry["registry_path"]
        .as_str()
        .expect("registry path should be present");
    assert!(
        registry_path.ends_with(".winsmux\\provider-capabilities.json")
            || registry_path.ends_with(".winsmux/provider-capabilities.json")
    );
    assert_eq!(registry["providers"]["codex"]["adapter"], "codex");
    assert_eq!(
        registry["providers"]["codex"]["model_options"][1]["source"],
        "cli-discovery"
    );
    assert_eq!(
        registry["providers"]["codex"]["model_options"][4]["reasoning_efforts"][3],
        "max"
    );
    assert_eq!(
        registry["providers"]["codex"]["reasoning_efforts"][4],
        "xhigh"
    );
    assert_eq!(
        registry["providers"]["codex"]["local_access_note"],
        "Local Codex CLI catalog and ChatGPT account access."
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["analysis_posture"],
        "read-only-analysis"
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["credential_requirements"],
        "runtime-owned-local-endpoint"
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["execution_backend"],
        "openai-compatible-local-endpoint"
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["api_base_url"],
        "http://127.0.0.1:8080/v1"
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["api_key_env"],
        "WINSMUX_LOCAL_OPENAI_COMPATIBLE_API_KEY"
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["read_only_launch_args"][1],
        "--no-file-edits"
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["supports_file_edit"],
        false
    );
    assert_eq!(
        registry["providers"]["local-openai-compatible"]["supports_consultation"],
        true
    );
    assert_eq!(
        registry["providers"]["codex"]["prompt_transports"][2],
        "stdin"
    );
    assert_eq!(
        registry["providers"]["claude"]["supports_parallel_runs"],
        true
    );
}

#[test]
fn operator_cli_machine_contract_json_exposes_hook_facing_catalog() {
    let project_dir = make_temp_project_dir("machine-contract");

    let json = run_json(&project_dir, &["machine-contract", "--json"]);

    assert_eq!(json["version"], "0.36.28");
    assert_eq!(json["roles"][0]["canonical"], "operator");
    assert_eq!(json["roles"][1]["canonical"], "worker");
    assert_eq!(json["worker_backends"][0]["id"], "local");
    assert_eq!(json["worker_backends"][2]["id"], "api_llm");
    assert_eq!(json["worker_backends"][2]["runtime_available"], true);
    assert_eq!(json["worker_backends"][3]["id"], "antigravity");
    assert_eq!(json["worker_backends"][3]["runtime_available"], true);
    assert_eq!(json["worker_backends"][4]["id"], "noop");
    assert_eq!(json["worker_backends"][4]["runtime_available"], false);
    assert_eq!(json["projection_surfaces"][1]["name"], "board");
    assert_eq!(json["projection_surfaces"][1]["command"], "board --json");
    assert_eq!(
        json["projection_surfaces"][4]["rust_type"],
        "LedgerRunsPayload"
    );
    assert_eq!(json["projection_surfaces"][6]["name"], "search-ledger");
    assert_eq!(
        json["projection_surfaces"][6]["command"],
        "search-ledger <search|timeline|detail> --json"
    );
    assert_eq!(
        json["review_state_file"]["path"],
        ".winsmux/review-state.json"
    );
    assert_eq!(json["event_taxonomy"][7]["group"], "security");
    assert_eq!(
        json["event_taxonomy"][7]["events"][3],
        "security.policy.blocked"
    );
    assert_eq!(
        json["verdict_fields"][1]["field"],
        "verification_result.outcome"
    );
}

#[test]
fn operator_cli_skills_json_exposes_agent_readable_contracts() {
    let project_dir = make_temp_project_dir("skills-json");

    let json = run_json(&project_dir, &["skills", "--json"]);

    assert_eq!(json["packet_type"], "progressive_skills_catalog");
    assert_eq!(json["private_skill_bodies_allowed"], false);
    assert_eq!(json["freeform_body_stored"], false);
    let workflow_pack_ids: Vec<_> = json["workflow_pack_registry"]["packs"]
        .as_array()
        .expect("workflow packs should be an array")
        .iter()
        .map(|pack| pack["id"].as_str().expect("pack id should be a string"))
        .collect();
    let skill_ids: Vec<_> = json["skills"]
        .as_array()
        .expect("skills should be an array")
        .iter()
        .map(|skill| skill["id"].as_str().expect("skill id should be a string"))
        .collect();
    assert_eq!(workflow_pack_ids, skill_ids);
    assert_eq!(
        json["workflow_pack_registry"]["private_skill_bodies_allowed"],
        false
    );
    assert_eq!(
        json["workflow_pack_registry"]["local_absolute_paths_allowed"],
        false
    );
    assert_eq!(
        json["workflow_pack_registry"]["discovery"]["supported_levels"][1],
        "user"
    );
    assert_eq!(
        json["workflow_pack_registry"]["discovery"]["sources"][2]["level"],
        "repository"
    );
    assert_eq!(
        json["workflow_pack_registry"]["discovery"]["sources"][2]["source_ref"],
        "repository-workflow-packs"
    );
    assert_eq!(
        json["workflow_pack_registry"]["discovery"]["sources"][1]["private_skill_bodies_allowed"],
        false
    );
    assert!(json["workflow_pack_registry"]
        .get("selected_pack")
        .is_none());
    assert!(json["workflow_pack_registry"]
        .get("scoped_loading_plan")
        .is_none());
    assert_eq!(
        json["workflow_pack_registry"]["packs"][1]["id"],
        "compare-and-promote"
    );
    assert_eq!(
        json["workflow_pack_registry"]["packs"][1]["metadata"]["review_role"],
        "reviewer"
    );
    assert_eq!(
        json["workflow_pack_registry"]["packs"][1]["scope"][2],
        "prepare follow-up candidate contracts"
    );
    assert_eq!(
        json["workflow_pack_registry"]["packs"][1]["supporting_files"][0],
        "docs/operator-model.md"
    );
    assert_eq!(
        json["workflow_pack_registry"]["packs"][1]["provenance"]["private_material_referenced"],
        false
    );
    assert_eq!(
        json["workflow_pack_registry"]["packs"][1]["evidence_requirements"][1],
        "playbook_template_contract"
    );
    assert_eq!(
        json["workflow_execution_contract"]["entrypoint"],
        "winsmux skills --json"
    );
    assert_eq!(
        json["workflow_execution_contract"]["private_skill_bodies_allowed"],
        false
    );
    assert_eq!(
        json["workflow_execution_contract"]["local_absolute_paths_allowed"],
        false
    );
    assert_eq!(
        json["workflow_execution_contract"]["required_request_fields"][0],
        "workflow_pack_id"
    );
    assert_eq!(
        json["workflow_execution_contract"]["operator_judgement_boundaries"][1],
        "operator keeps final merge and release decisions"
    );
    assert_eq!(json["skills"][0]["id"], "run-read-models");
    assert_eq!(json["skills"][0]["commands"][0], "runs --json");
    assert_eq!(
        json["skills"][1]["required_evidence"][1],
        "playbook_template_contract"
    );
    assert_eq!(json["skills"][1]["private_skill_body_stored"], false);
    assert_eq!(json["skills"][2]["review_role"], "tester");
    let discovery_pack = json["workflow_pack_registry"]["packs"]
        .as_array()
        .expect("workflow packs should be an array")
        .iter()
        .find(|pack| pack["id"] == "repository-skill-discovery")
        .expect("repository discovery pack should exist");
    assert_eq!(
        discovery_pack["discovery"]["available_source_levels"][0],
        "user"
    );
    assert_eq!(
        discovery_pack["discovery"]["selection_reason"],
        "repository contracts take precedence when tracked docs define the workflow pack boundary"
    );
    assert_eq!(
        discovery_pack["provenance"]["local_absolute_path_stored"],
        false
    );
    assert_eq!(
        discovery_pack["loading_plan"]["minimum_supporting_files"][0],
        "docs/operator-model.md"
    );
    assert_eq!(
        discovery_pack["evidence_requirements"][2],
        "scoped_loading_plan"
    );
    let catalog_text = serde_json::to_string(&json).expect("catalog should serialize");
    assert!(!catalog_text.contains("private skill body:"));
    assert!(!catalog_text.contains("C:\\"));
    assert!(!catalog_text.contains("C:/"));
    assert!(!catalog_text.contains("\\Users\\"));
    assert!(!catalog_text.contains("/Users/"));
}

#[test]
fn operator_cli_skills_json_exposes_quality_workflow_templates() {
    let project_dir = make_temp_project_dir("skills-quality-templates");

    let json = run_json(&project_dir, &["skills", "--json"]);
    let packs = json["workflow_pack_registry"]["packs"]
        .as_array()
        .expect("workflow packs should be an array");
    let find_pack = |id: &str| {
        packs
            .iter()
            .find(|pack| pack["id"] == id)
            .unwrap_or_else(|| panic!("missing workflow pack {id}"))
    };

    let docs_pack = find_pack("documentation-refresh");
    assert_eq!(docs_pack["metadata"]["status"], "template");
    assert_eq!(docs_pack["metadata"]["review_role"], "writer");
    assert_eq!(docs_pack["required_evidence_fields"][0], "changed_docs");
    assert_eq!(docs_pack["expected_result_fields"][3], "doc_update_summary");

    let ci_pack = find_pack("ci-diagnosis");
    assert_eq!(ci_pack["evidence_requirements"][0], "failing_check");
    assert_eq!(ci_pack["required_evidence_fields"][4], "next_verification");

    let issue_pack = find_pack("issue-dedupe");
    assert_eq!(
        issue_pack["expected_result_fields"][3],
        "dedupe_recommendation"
    );
    assert_eq!(
        issue_pack["operator_judgement_boundary"],
        "operator decides whether to reuse existing tracking or create a new issue"
    );

    let web_pack = find_pack("web-quality-check");
    assert_eq!(web_pack["evidence_requirements"][0], "accessibility_report");
    assert_eq!(web_pack["required_evidence_fields"][1], "viewport_matrix");

    let mcp_pack = find_pack("mcp-tool-builder");
    assert_eq!(mcp_pack["evidence_requirements"][0], "tool_schema");
    assert_eq!(mcp_pack["required_evidence_fields"][4], "smoke_result");

    let skill_ids: Vec<_> = json["skills"]
        .as_array()
        .expect("skills should be an array")
        .iter()
        .map(|skill| skill["id"].as_str().expect("skill id should be a string"))
        .collect();
    for id in [
        "documentation-refresh",
        "ci-diagnosis",
        "issue-dedupe",
        "web-quality-check",
        "mcp-tool-builder",
    ] {
        assert!(skill_ids.contains(&id), "missing skill contract {id}");
    }

    let catalog = serde_json::to_string(&json).expect("catalog should serialize");
    for forbidden in ["Visual Studio Code", "VS Code", "Cursor", "C:\\", "/Users/"] {
        assert!(
            !catalog.contains(forbidden),
            "quality workflow templates should stay public-safe: {forbidden}"
        );
    }
}

#[test]
fn operator_cli_skills_help_and_command_lists_are_discoverable() {
    let project_dir = make_temp_project_dir("skills-help");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["skills", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("usage: winsmux skills"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("--help")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("skills"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("skills")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Workflow packs"));
    assert!(stdout.contains("Skill contracts"));
    assert!(stdout.contains("compare-and-promote"));
}

#[test]
fn operator_cli_skills_rejects_project_dir() {
    let project_dir = make_temp_project_dir("skills-rejects-project-dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["skills", "--json", "--project-dir"])
        .arg(project_dir.as_os_str())
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "skills should reject project-dir");
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("unknown argument for winsmux skills: --project-dir"));
}

#[test]
fn operator_cli_machine_contract_requires_json() {
    let project_dir = make_temp_project_dir("machine-contract-requires-json");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("machine-contract")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "machine-contract should fail");
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("winsmux machine-contract currently supports only --json"));
}

#[test]
fn operator_cli_machine_contract_rejects_project_dir() {
    let project_dir = make_temp_project_dir("machine-contract-rejects-project-dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["machine-contract", "--json", "--project-dir"])
        .arg(project_dir.as_os_str())
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        !output.status.success(),
        "machine-contract should reject project-dir"
    );
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("unknown argument for winsmux machine-contract: --project-dir"));
}

#[test]
fn operator_cli_rust_canary_json_reports_default_cli_gate() {
    let project_dir = make_temp_project_dir("rust-canary-default");

    let json = run_json(&project_dir, &["rust-canary", "--json"]);

    assert_eq!(json["contract_version"], 1);
    assert_eq!(json["task_id"], "TASK-283");
    assert_eq!(json["target_version"], "v0.24.5");
    assert_eq!(json["phase"], "default-on-canary");
    assert_eq!(json["runtime"]["rust_cli_available"], true);
    assert_eq!(json["runtime"]["backend"], "cli");
    assert_eq!(json["runtime"]["backend_source"], "default");
    assert_eq!(json["runtime"]["tauri_backend_candidate"], false);
    assert_eq!(json["required_gates"][2], "shadow_cutover_gate");
    assert_eq!(json["blocking_conditions"][0], "invalid_WINSMUX_BACKEND");
}

#[test]
fn operator_cli_rust_canary_json_reports_tauri_candidate() {
    let project_dir = make_temp_project_dir("rust-canary-tauri");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rust-canary", "--json"])
        .env("WINSMUX_BACKEND", "desktop")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert_eq!(json["runtime"]["backend"], "tauri");
    assert_eq!(json["runtime"]["backend_source"], "WINSMUX_BACKEND");
    assert_eq!(json["runtime"]["tauri_backend_candidate"], true);
}

#[test]
fn operator_cli_rust_canary_rejects_invalid_backend() {
    let project_dir = make_temp_project_dir("rust-canary-invalid");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rust-canary", "--json"])
        .env("WINSMUX_BACKEND", "remote")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "rust-canary should fail");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("WINSMUX_BACKEND must be cli or tauri")
    );
}

#[test]
fn operator_cli_manual_checklist_json_reports_release_gate() {
    let project_dir = make_temp_project_dir("manual-checklist");

    let json = run_json(&project_dir, &["manual-checklist", "--json"]);

    assert_eq!(json["contract_version"], 1);
    assert_eq!(json["task_id"], "TASK-416");
    assert_eq!(json["target_version"], "v1.0.0");
    assert_eq!(
        json["document"]["path"],
        "docs/internal/winsmux-manual-checklist-by-version.md"
    );
    assert_eq!(json["document"]["tracked"], false);
    assert_eq!(json["document"]["exists"], false);
    assert_eq!(json["document"]["storage_policy"], "internal_untracked");
    assert_eq!(json["required_result_values"][0], "未");
    assert_eq!(json["required_result_values"][1], "合格");
    assert_eq!(json["required_result_values"][2], "不合格");
    assert_eq!(json["required_result_values"][3], "保留");
    assert_eq!(
        json["release_gates"][0],
        "version_by_version_results_recorded"
    );
    assert_eq!(
        json["release_gates"][1],
        "desktop_bundle_artifacts_verified"
    );
    assert_eq!(
        json["release_gates"][3],
        "first_launch_project_selection_recorded"
    );
    let release_gates = json["release_gates"]
        .as_array()
        .expect("release_gates should be an array");
    for gate in [
        "project_explorer_accuracy_recorded",
        "operator_composer_editing_recorded",
        "meta_plan_multi_pane_flow_recorded",
        "status_bar_fit_recorded",
        "native_voice_dictation_or_fallback_contract_recorded",
    ] {
        assert!(
            release_gates.iter().any(|item| item == gate),
            "release_gates should contain {gate}"
        );
    }
    let focus_items = json["v1_desktop_focus"]
        .as_array()
        .expect("v1_desktop_focus should be an array");
    for item_id in [
        "first_launch_project_selection",
        "project_explorer_accuracy",
        "operator_composer_editing",
        "meta_plan_multi_pane_flow",
        "clipboard_image_input",
        "settings_language_control",
        "status_bar_fit",
        "native_voice_dictation_or_fallback_contract",
    ] {
        assert!(
            focus_items.iter().any(|item| item == item_id),
            "v1_desktop_focus should contain {item_id}"
        );
    }
    for (item_id, gate) in [
        ("installer_artifacts", "desktop_bundle_artifacts_verified"),
        (
            "first_launch_project_selection",
            "first_launch_project_selection_recorded",
        ),
        (
            "project_explorer_accuracy",
            "project_explorer_accuracy_recorded",
        ),
        (
            "operator_composer_editing",
            "operator_composer_editing_recorded",
        ),
        (
            "meta_plan_multi_pane_flow",
            "meta_plan_multi_pane_flow_recorded",
        ),
        ("clipboard_image_input", "clipboard_image_flow_recorded"),
        (
            "settings_language_control",
            "settings_language_flow_recorded",
        ),
        ("status_bar_fit", "status_bar_fit_recorded"),
        (
            "native_voice_dictation_or_fallback_contract",
            "native_voice_dictation_or_fallback_contract_recorded",
        ),
    ] {
        assert!(
            json["desktop_manual_items"]
                .as_array()
                .expect("desktop_manual_items should be an array")
                .iter()
                .any(|item| item["id"] == item_id),
            "desktop_manual_items should contain {item_id}"
        );
        assert!(
            release_gates.iter().any(|item| item == gate),
            "release_gates should contain gate {gate} for {item_id}"
        );
    }
    for (item_id, evidence_source, dogfood_task_class) in [
        ("installer_artifacts", "release_artifact", None),
        (
            "first_launch_project_selection",
            "dogfood_task_class",
            Some("first_launch_project_selection"),
        ),
        (
            "project_explorer_accuracy",
            "dogfood_task_class",
            Some("project_explorer_accuracy"),
        ),
        (
            "operator_composer_editing",
            "dogfood_task_class",
            Some("operator_composer_editing"),
        ),
        (
            "meta_plan_multi_pane_flow",
            "dogfood_task_class",
            Some("meta_plan_multi_pane_flow"),
        ),
        (
            "clipboard_image_input",
            "dogfood_task_class",
            Some("clipboard_image_input"),
        ),
        (
            "settings_language_control",
            "dogfood_task_class",
            Some("settings_language_control"),
        ),
        (
            "native_voice_dictation_or_fallback_contract",
            "fallback_contract",
            None,
        ),
        (
            "status_bar_fit",
            "dogfood_task_class",
            Some("status_bar_fit"),
        ),
    ] {
        let item = json["desktop_manual_items"]
            .as_array()
            .expect("desktop_manual_items should be an array")
            .iter()
            .find(|item| item["id"] == item_id)
            .unwrap_or_else(|| panic!("desktop_manual_items should contain {item_id}"));
        assert_eq!(item["evidence_source"], evidence_source);
        if let Some(expected_task_class) = dogfood_task_class {
            assert_eq!(item["dogfood_task_class"], expected_task_class);
        } else {
            assert!(item["dogfood_task_class"].is_null());
        }
    }
    assert_eq!(
        json["v1_desktop_focus"][0],
        "desktop_installer_distribution"
    );
    assert_eq!(json["v1_desktop_focus"][4], "meta_plan_multi_pane_flow");
    assert_eq!(json["v1_desktop_focus"][6], "status_bar_fit");
    assert_eq!(
        json["v1_desktop_focus"][8],
        "native_voice_dictation_or_fallback_contract"
    );
    assert_eq!(json["desktop_manual_items"][0]["id"], "installer_artifacts");
    assert_eq!(
        json["desktop_manual_items"][1]["id"],
        "first_launch_project_selection"
    );
    assert_eq!(
        json["desktop_manual_items"][3]["id"],
        "operator_composer_editing"
    );
    assert_eq!(
        json["desktop_manual_items"][5]["id"],
        "clipboard_image_input"
    );
    assert_eq!(
        json["desktop_manual_items"][7]["id"],
        "native_voice_dictation_or_fallback_contract"
    );
    assert_eq!(
        json["native_voice_fallback_contract"]["task_id"],
        "TASK-468"
    );
    assert_eq!(json["native_voice_fallback_contract"]["issue"], "#885");
    assert_eq!(
        json["native_voice_fallback_contract"]["release_gate"],
        "native_voice_dictation_or_fallback_contract_recorded"
    );
    assert_eq!(
        json["native_voice_fallback_contract"]["status"],
        "recorded_for_v1"
    );
    assert_eq!(
        json["native_voice_fallback_contract"]["native_speech_to_text"],
        "not_implemented"
    );
    assert_eq!(
        json["native_voice_fallback_contract"]["metering_is_dictation"],
        false
    );
    assert_eq!(
        json["native_voice_fallback_contract"]["accepted_fallbacks"],
        serde_json::json!([
            "browser_speech_recognition",
            "windows_voice_typing",
            "keyboard_input"
        ])
    );
    assert_eq!(
        json["native_voice_fallback_contract"]["required_evidence"],
        serde_json::json!([
            "desktop_voice_status_reports_browser_fallback_when_native_metering_exists",
            "composer_voice_button_does_not_start_native_metering_as_dictation",
            "manual_checklist_records_supported_fallback_contract"
        ])
    );
    assert!(json["native_voice_fallback_contract"]["decision"]
        .as_str()
        .unwrap_or_default()
        .contains("native microphone capture is metering only"));
    assert_eq!(
        json["blocking_conditions"][0],
        "missing_manual_checklist_document"
    );
    assert_eq!(
        json["blocking_conditions"][4],
        "missing_desktop_artifact_evidence"
    );
    assert_eq!(
        json["blocking_conditions"][6],
        "missing_native_voice_dictation_or_fallback_contract"
    );
    assert_eq!(json["blocking_condition_scope"], "release_blocker_classes");
    assert!(json["blocking_condition_note"]
        .as_str()
        .unwrap_or_default()
        .contains("document.exists"));
}

#[test]
fn operator_cli_manual_checklist_json_reports_existing_internal_document() {
    let project_dir = make_temp_project_dir("manual-checklist-existing-document");
    let document_dir = project_dir.join("docs").join("internal");
    fs::create_dir_all(&document_dir).expect("test should create manual checklist directory");
    fs::write(
        document_dir.join("winsmux-manual-checklist-by-version.md"),
        "# manual checklist\n",
    )
    .expect("test should write manual checklist document");

    let json = run_json(&project_dir, &["manual-checklist", "--json"]);

    assert_eq!(json["document"]["tracked"], false);
    assert_eq!(json["document"]["exists"], true);
    assert_eq!(json["document"]["storage_policy"], "internal_untracked");
}

#[test]
fn operator_cli_manual_checklist_text_reports_next_action() {
    let project_dir = make_temp_project_dir("manual-checklist-text");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("manual-checklist")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Manual checklist: docs/internal/winsmux-manual-checklist-by-version.md")
    );
    assert!(stdout.contains("Record v1.0.0 desktop manual validation results"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_legacy_compat_gate_json_reports_inventory() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core manifest should have a repository parent")
        .to_path_buf();

    let json = run_json_with_cwd(&repo_root, &["legacy-compat-gate", "--json"]);

    assert_eq!(json["contract_version"], 1);
    assert_eq!(json["task_id"], "TASK-408");
    assert_eq!(json["target_version"], "v1.0.0");
    assert_eq!(
        json["inventory"]["path"],
        "docs/project/legacy-compat-surface-inventory.json"
    );
    assert_eq!(json["inventory"]["terms"][0], "psmux");
    assert_eq!(json["summary"]["passed"], true);
    assert!(json["summary"]["matched_file_count"].as_u64().unwrap() > 0);
    assert!(json["summary"]["intentional_shim_files"].as_u64().unwrap() > 0);
    assert!(json["summary"]["removal_candidate_files"].as_u64().unwrap() > 0);
    assert_eq!(json["summary"]["unclassified_count"], 0);
    assert_eq!(json["summary"]["private_reference_count"], 0);
    assert_eq!(
        json["blocking_conditions"][0],
        "unclassified_legacy_compat_surface"
    );
}

#[test]
fn operator_cli_legacy_compat_gate_rejects_private_inventory_reference() {
    let project_dir = make_temp_project_dir("legacy-compat-private-reference");
    run_git(&project_dir, &["init"]);
    fs::create_dir_all(project_dir.join("docs/project"))
        .expect("test should create docs project directory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.json"),
        r#"{
  "task": "TASK-408",
  "version": 1,
  "terms": ["psmux"],
  "allowed_classes": ["intentional-shim", "removal-candidate"],
  "target_version": "v1.0.0",
  "entries": [
    {
      "class": "intentional-shim",
      "owner": "test",
      "surface": "test",
      "reason": "test",
      "target": "test",
      "paths": ["docs/project/legacy-compat-surface-inventory.json"]
    }
  ],
  "example": "C:\\Users\\example"
}
"#,
    )
    .expect("test should write inventory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.md"),
        "# Legacy Compatibility Surface Inventory\n",
    )
    .expect("test should write inventory docs");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["legacy-compat-gate", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should contain JSON");
    assert_eq!(json["summary"]["passed"], false);
    assert_eq!(json["summary"]["private_reference_count"], 1);
    assert_eq!(
        json["private_reference_files"][0],
        "docs/project/legacy-compat-surface-inventory.json"
    );
}

#[test]
fn operator_cli_legacy_compat_gate_rejects_unclassified_reference() {
    let project_dir = make_temp_project_dir("legacy-compat-unclassified");
    run_git(&project_dir, &["init"]);
    fs::create_dir_all(project_dir.join("docs/project"))
        .expect("test should create docs project directory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.json"),
        r#"{
  "task": "TASK-408",
  "version": 1,
  "terms": ["psmux"],
  "allowed_classes": ["intentional-shim", "removal-candidate"],
  "target_version": "v1.0.0",
  "entries": [
    {
      "class": "intentional-shim",
      "owner": "test",
      "surface": "test",
      "reason": "test",
      "target": "test",
      "paths": ["docs/project/legacy-compat-surface-inventory.json"]
    }
  ]
}
"#,
    )
    .expect("test should write inventory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.md"),
        "# Legacy Compatibility Surface Inventory\n",
    )
    .expect("test should write inventory docs");
    fs::write(project_dir.join("untracked.txt"), "new psmux reference\n")
        .expect("test should write untracked compatibility reference");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["legacy-compat-gate", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should contain JSON");
    assert_eq!(json["summary"]["passed"], false);
    assert_eq!(json["summary"]["unclassified_count"], 1);
    assert_eq!(json["unclassified_files"][0], "untracked.txt");
}

#[test]
fn operator_cli_legacy_compat_gate_text_reports_next_action() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core manifest should have a repository parent")
        .to_path_buf();

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("legacy-compat-gate")
        .current_dir(&repo_root)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Legacy compatibility gate:"));
    assert!(stdout.contains("Before v1.0.0"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_guard_json_reports_release_guard_baseline() {
    let project_dir = make_temp_project_dir("guard-json");
    fs::create_dir_all(project_dir.join("scripts")).expect("test should create scripts dir");
    fs::write(project_dir.join("scripts").join("git-guard.ps1"), "")
        .expect("test should write git-guard script");
    fs::write(
        project_dir.join("scripts").join("audit-public-surface.ps1"),
        "",
    )
    .expect("test should write public surface audit script");
    fs::write(project_dir.join("scripts").join("gitleaks-history.ps1"), "")
        .expect("test should write gitleaks script");
    fs::write(
        project_dir
            .join("scripts")
            .join("gitleaks-history-baseline.txt"),
        "abc123\n",
    )
    .expect("test should write gitleaks baseline");
    fs::write(
        project_dir
            .join("scripts")
            .join("generate-release-notes.ps1"),
        "",
    )
    .expect("test should write release notes script");
    fs::create_dir_all(project_dir.join("docs").join("project"))
        .expect("test should create docs project dir");
    fs::write(
        project_dir
            .join("docs")
            .join("project")
            .join("legacy-compat-surface-inventory.json"),
        "{}\n",
    )
    .expect("test should write legacy compat inventory");
    fs::write(
        project_dir
            .join("docs")
            .join("project")
            .join("pester-suite-inventory.json"),
        "{}\n",
    )
    .expect("test should write Pester reduction inventory");
    fs::write(
        project_dir
            .join("docs")
            .join("project")
            .join("pester-suite-reduction-plan.md"),
        "# Pester suite reduction plan\n",
    )
    .expect("test should write Pester reduction plan");
    fs::write(
        project_dir
            .join("scripts")
            .join("validate-pester-reduction-plan.ps1"),
        "",
    )
    .expect("test should write Pester reduction validator");
    fs::create_dir_all(project_dir.join(".github").join("workflows"))
        .expect("test should create workflows dir");
    fs::write(
        project_dir
            .join(".github")
            .join("workflows")
            .join("release-desktop.yml"),
        "name: Release Desktop App\n",
    )
    .expect("test should write desktop release workflow");

    let json = run_json(&project_dir, &["guard", "--json"]);

    assert_eq!(json["command"], "guard");
    assert_eq!(json["task_ids"][0], "TASK-390");
    assert_eq!(json["task_ids"][3], "TASK-384");
    assert_eq!(json["issue_refs"][0], "#522");
    assert_eq!(json["issue_refs"][3], "#525");
    assert_eq!(json["issue_refs"][4], "#685");
    assert_eq!(json["target_version"], "v1.0.0");
    assert_eq!(json["summary"]["required_check_count"], 9);
    assert_eq!(json["summary"]["available_check_count"], 9);
    assert_eq!(
        json["observed_state"]["gitleaks_baseline_file"],
        "scripts/gitleaks-history-baseline.txt"
    );
    assert_eq!(
        json["evidence_contract"]["required_fields"][2],
        "architecture_contract"
    );
    assert_eq!(
        json["evidence_contract"]["required_fields"][4],
        "audit_chain"
    );
    assert_eq!(json["required_checks"][5]["id"], "manual_checklist_v1");
    assert_eq!(json["required_checks"][6]["id"], "legacy_compat_gate");
    assert_eq!(json["required_checks"][7]["id"], "pester_reduction_plan");
    assert_eq!(
        json["required_checks"][7]["source"],
        "docs/project/pester-suite-reduction-plan.md"
    );
    assert_eq!(json["required_checks"][8]["id"], "desktop_release_workflow");
    assert_eq!(json["parent_tracking"]["task_id"], "TASK-390");
    assert_eq!(
        json["parent_tracking"]["scope"],
        "coordination_and_acceptance_tracking"
    );
    assert_eq!(
        json["parent_tracking"]["child_tasks"][0]["task_id"],
        "TASK-382"
    );
    assert_eq!(
        json["parent_tracking"]["child_tasks"][2]["issue_ref"],
        "#525"
    );
    assert_eq!(
        json["evidence_contract"]["security_contract"]["provider_token_broker_allowed"],
        false
    );
    assert_eq!(
        json["public_safety"]["public_release_notes_language"],
        "English"
    );
}

#[test]
fn operator_cli_guard_requires_pester_reduction_plan_document() {
    let project_dir = make_temp_project_dir("guard-pester-plan-required");

    fs::create_dir_all(project_dir.join("scripts")).expect("test should create scripts dir");
    fs::write(project_dir.join("scripts").join("git-guard.ps1"), "")
        .expect("test should write git guard");
    fs::write(
        project_dir.join("scripts").join("audit-public-surface.ps1"),
        "",
    )
    .expect("test should write public surface audit");
    fs::write(project_dir.join("scripts").join("gitleaks-history.ps1"), "")
        .expect("test should write gitleaks history");
    fs::write(
        project_dir
            .join("scripts")
            .join("gitleaks-history-baseline.txt"),
        "abc123\n",
    )
    .expect("test should write gitleaks baseline");
    fs::write(
        project_dir
            .join("scripts")
            .join("generate-release-notes.ps1"),
        "",
    )
    .expect("test should write release notes script");
    fs::write(
        project_dir
            .join("scripts")
            .join("validate-pester-reduction-plan.ps1"),
        "",
    )
    .expect("test should write Pester reduction validator");

    fs::create_dir_all(project_dir.join("docs").join("project"))
        .expect("test should create docs project dir");
    fs::write(
        project_dir
            .join("docs")
            .join("project")
            .join("legacy-compat-surface-inventory.json"),
        "{}\n",
    )
    .expect("test should write legacy compat inventory");
    fs::write(
        project_dir
            .join("docs")
            .join("project")
            .join("pester-suite-inventory.json"),
        "{}\n",
    )
    .expect("test should write Pester reduction inventory");

    fs::create_dir_all(project_dir.join(".github").join("workflows"))
        .expect("test should create workflows dir");
    fs::write(
        project_dir
            .join(".github")
            .join("workflows")
            .join("release-desktop.yml"),
        "name: Release Desktop App\n",
    )
    .expect("test should write desktop release workflow");

    let json = run_json(&project_dir, &["guard", "--json"]);

    assert_eq!(json["summary"]["required_check_count"], 9);
    assert_eq!(json["summary"]["available_check_count"], 8);
    assert_eq!(json["required_checks"][7]["id"], "pester_reduction_plan");
    assert_eq!(json["required_checks"][7]["available"], false);
}

#[test]
fn operator_cli_guard_text_summarizes_contract() {
    let project_dir = make_temp_project_dir("guard-text");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("guard")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Guard baseline: 9 checks for v1.0.0"));
    assert!(stdout.contains("Run the listed guard commands before release tagging"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_provider_capabilities_json_reads_single_provider_case_insensitive() {
    let project_dir = make_temp_project_dir("provider-capabilities-single");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"Codex":{"adapter":" codex ","command":" codex ","prompt_transports":["ARGV"],"auth_modes":["LOCAL_INTERACTIVE"],"supports_file_edit":true,"supports_context_reset":true}}}"#,
    )
    .expect("test should write provider registry");

    let provider = run_json(&project_dir, &["provider-capabilities", "codex", "--json"]);

    assert_eq!(provider["provider_id"], "codex");
    assert_eq!(provider["capabilities"]["adapter"], "codex");
    assert_eq!(provider["capabilities"]["command"], "codex");
    assert_eq!(provider["capabilities"]["prompt_transports"][0], "argv");
    assert_eq!(
        provider["capabilities"]["auth_modes"][0],
        "local_interactive"
    );
    assert_eq!(provider["capabilities"]["supports_file_edit"], true);
    assert_eq!(provider["capabilities"]["supports_context_reset"], true);
}

#[test]
fn operator_cli_provider_capabilities_missing_provider_fails() {
    let project_dir = make_temp_project_dir("provider-capabilities-missing");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"codex":{"adapter":"codex","command":"codex","prompt_transports":["argv"]}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-capabilities", "gemini", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "missing provider should fail");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("provider capability 'gemini' was not found."),
        "stderr should explain missing provider"
    );
}

#[test]
fn operator_cli_provider_capabilities_rejects_invalid_registry_contract() {
    let project_dir = make_temp_project_dir("provider-capabilities-invalid");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"codex":{"adapter":"codex","prompt_transports":["pipe"]}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-capabilities", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "invalid registry should fail");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Invalid provider capability prompt transport 'pipe'.")
            || stderr.contains("Missing provider capability field 'command'."),
        "stderr should explain invalid registry contract: {stderr}"
    );
}

#[test]
fn operator_cli_provider_capabilities_rejects_blank_required_field() {
    let project_dir = make_temp_project_dir("provider-capabilities-blank-required");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"codex":{"adapter":"codex","command":"   ","prompt_transports":["argv"]}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-capabilities", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "blank command should fail");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("Missing provider capability field 'command'."),
        "stderr should explain missing normalized command"
    );
}

#[test]
fn operator_cli_provider_switch_writes_registry_entry() {
    let project_dir = make_temp_project_dir("provider-switch-write");
    write_provider_switch_fixture(&project_dir);

    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--model-source",
            "operator-override",
            "--reasoning-effort",
            "xhigh",
            "--prompt-transport",
            "file",
            "--auth-mode",
            "claude-pro-max-oauth",
            "--reason",
            "operator requested provider switch",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["agent"], "claude");
    assert_eq!(result["model"], "opus");
    assert_eq!(result["model_source"], "operator-override");
    assert_eq!(result["reasoning_effort"], "xhigh");
    assert_eq!(result["prompt_transport"], "file");
    assert_eq!(result["auth_mode"], "claude-pro-max-oauth");
    assert_eq!(result["auth_policy"], "local_interactive_only");
    assert_eq!(result["source"], "registry");
    assert_eq!(result["capability_adapter"], "claude");
    assert_eq!(result["capability_command"], "claude");
    assert_eq!(result["harness_availability"], "official-cli");
    assert_eq!(result["credential_requirements"], "local-cli-owned");
    assert_eq!(result["execution_backend"], "agent-cli");
    assert_eq!(
        result["runtime_requirements"],
        "Claude Code CLI installed in the pane environment."
    );
    assert_eq!(result["analysis_posture"], "read-write-worker");
    assert_eq!(result["supports_file_edit"], true);
    assert_eq!(result["supports_subagents"], false);
    assert_eq!(result["supports_consultation"], true);
    assert_eq!(result["restart_requested"], false);
    assert_eq!(result["restarted"], false);

    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    assert_eq!(registry["slots"]["worker-1"]["agent"], "claude");
    assert_eq!(registry["slots"]["worker-1"]["model"], "opus");
    assert_eq!(
        registry["slots"]["worker-1"]["model_source"],
        "operator-override"
    );
    assert_eq!(registry["slots"]["worker-1"]["reasoning_effort"], "xhigh");
    assert_eq!(registry["slots"]["worker-1"]["prompt_transport"], "file");
    assert_eq!(
        registry["slots"]["worker-1"]["reason"],
        "operator requested provider switch"
    );
}

#[test]
fn operator_cli_provider_switch_rejects_blocked_auth_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-block-auth");
    write_provider_switch_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--prompt-transport",
            "file",
            "--auth-mode",
            "token-broker",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("must not broker OAuth"),
        "stderr should explain blocked auth mode"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_rejects_capability_selector_mismatch_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-capability-selector");
    write_provider_switch_fixture(&project_dir);

    let model_source_output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "codex",
            "--model",
            "gpt-5.5",
            "--model-source",
            "operator-override",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!model_source_output.status.success());
    assert!(
        String::from_utf8_lossy(&model_source_output.stderr)
            .contains("does not support model_source 'operator-override'"),
        "stderr should explain unsupported model source"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());

    let reasoning_output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "codex",
            "--reasoning-effort",
            "max",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!reasoning_output.status.success());
    assert!(
        String::from_utf8_lossy(&reasoning_output.stderr)
            .contains("does not support reasoning_effort 'max'"),
        "stderr should explain unsupported reasoning effort"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_validates_reasoning_effort_against_specific_model() {
    let project_dir = make_temp_project_dir("provider-switch-model-effort");
    write_provider_switch_fixture(&project_dir);
    let capability_path = project_dir
        .join(".winsmux")
        .join("provider-capabilities.json");
    let mut capabilities = read_json_file(&capability_path);
    capabilities["providers"]["codex"]["model_sources"] =
        serde_json::json!(["provider-default", "cli-discovery", "operator-override"]);
    capabilities["providers"]["codex"]["reasoning_efforts"] =
        serde_json::json!(["provider-default", "low", "medium", "high", "max", "xhigh"]);
    capabilities["providers"]["codex"]["model_options"]
        .as_array_mut()
        .expect("Codex model options should be an array")
        .push(serde_json::json!({
            "id": "custom-operator-model",
            "label": "Custom operator model",
            "source": "operator-override",
            "reasoning_efforts": ["max"]
        }));
    fs::write(
        &capability_path,
        serde_json::to_vec_pretty(&capabilities).expect("capabilities should serialize"),
    )
    .expect("test should update provider capabilities");

    let run_switch = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args(args)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run")
    };

    let provider_default = run_switch(&[
        "provider-switch",
        "worker-1",
        "--model",
        "provider-default",
        "--model-source",
        "provider-default",
        "--reasoning-effort",
        "max",
        "--json",
    ]);
    assert!(!provider_default.status.success());
    assert!(
        String::from_utf8_lossy(&provider_default.stderr)
            .contains("model 'provider-default' does not support reasoning_effort 'max'"),
        "provider-default model must reject max"
    );

    let custom_override = run_switch(&[
        "provider-switch",
        "worker-1",
        "--model",
        "custom-operator-model",
        "--model-source",
        "operator-override",
        "--reasoning-effort",
        "max",
        "--json",
    ]);
    assert!(!custom_override.status.success());
    assert!(
        String::from_utf8_lossy(&custom_override.stderr)
            .contains("model 'custom-operator-model' does not support reasoning_effort 'max'"),
        "custom operator override model must reject max"
    );

    let provider_default_xhigh = run_switch(&[
        "provider-switch",
        "worker-1",
        "--agent",
        "codex",
        "--model",
        "provider-default",
        "--model-source",
        "provider-default",
        "--reasoning-effort",
        "xhigh",
        "--prompt-transport",
        "argv",
        "--json",
    ]);
    assert!(
        provider_default_xhigh.status.success(),
        "provider-default Codex model must inherit provider-level xhigh: {}",
        String::from_utf8_lossy(&provider_default_xhigh.stderr)
    );

    let unprojected_custom_high = run_switch(&[
        "provider-switch",
        "worker-1",
        "--agent",
        "codex",
        "--model",
        "custom-operator-model",
        "--model-source",
        "provider-default",
        "--reasoning-effort",
        "high",
        "--prompt-transport",
        "argv",
        "--json",
    ]);
    assert!(
        unprojected_custom_high.status.success(),
        "a provider-default model source must inherit provider-level efforts: {}",
        String::from_utf8_lossy(&unprojected_custom_high.stderr)
    );

    let claude_provider_default_max = run_switch(&[
        "provider-switch",
        "worker-1",
        "--agent",
        "claude",
        "--model",
        "provider-default",
        "--model-source",
        "provider-default",
        "--reasoning-effort",
        "max",
        "--prompt-transport",
        "file",
        "--json",
    ]);
    assert!(
        claude_provider_default_max.status.success(),
        "provider-default Claude model must inherit provider-level max: {}",
        String::from_utf8_lossy(&claude_provider_default_max.stderr)
    );

    let registry_path = project_dir.join(".winsmux").join("provider-registry.json");
    fs::write(
        &registry_path,
        r#"{"version":1,"slots":{"worker-1":{"model":"gpt-5.4","model_source":"cli-discovery","reasoning_effort":"max"}}}"#,
    )
    .expect("test should write stale provider registry");
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write restart manifest");
    let (winsmux_bin, restart_log) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);
    let stale_persisted = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "worker-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux restart command should run");
    assert!(!stale_persisted.status.success());
    assert!(
        String::from_utf8_lossy(&stale_persisted.stderr)
            .contains("model 'gpt-5.4' does not support reasoning_effort 'max'"),
        "stale persisted max must be rejected before rewrite or launch"
    );
    assert!(
        !fs::read_to_string(restart_log)
            .unwrap_or_default()
            .contains("send-keys"),
        "stale persisted max must not reach launcher dispatch"
    );

    fs::remove_file(&registry_path).expect("test should remove stale provider registry");
    let gpt56 = run_switch(&[
        "provider-switch",
        "worker-1",
        "--model",
        "gpt-5.6-terra",
        "--model-source",
        "cli-discovery",
        "--reasoning-effort",
        "max",
        "--json",
    ]);
    assert!(
        gpt56.status.success(),
        "GPT-5.6 Terra max should pass: {}",
        String::from_utf8_lossy(&gpt56.stderr)
    );
    let payload: serde_json::Value = serde_json::from_slice(&gpt56.stdout)
        .expect("successful provider-switch output should be JSON");
    assert_eq!(payload["model"], "gpt-5.6-terra");
    assert_eq!(payload["reasoning_effort"], "max");
}

#[test]
fn operator_cli_provider_switch_allows_only_exact_gpt56_max_without_capabilities() {
    let write_settings = |project_dir: &std::path::Path| {
        fs::write(
            project_dir.join(".winsmux.yaml"),
            r#"
agent: codex
model: gpt-5.4
model-source: cli-discovery
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    model-source: cli-discovery
    prompt-transport: argv
"#,
        )
        .expect("test should write settings");
    };
    let run_switch = |project_dir: &std::path::Path, model: &str, model_source: &str| {
        Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([
                "provider-switch",
                "worker-1",
                "--model",
                model,
                "--model-source",
                model_source,
                "--reasoning-effort",
                "max",
                "--json",
            ])
            .current_dir(project_dir)
            .output()
            .expect("winsmux command should run")
    };

    for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
        let project_dir =
            make_temp_project_dir(&format!("provider-switch-no-capabilities-{model}"));
        write_settings(&project_dir);

        let output = run_switch(&project_dir, model, "cli-discovery");
        assert!(
            output.status.success(),
            "{model} max should pass without capabilities: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let payload: serde_json::Value = serde_json::from_slice(&output.stdout)
            .expect("successful provider-switch output should be JSON");
        assert_eq!(payload["model"], model);
        assert_eq!(payload["reasoning_effort"], "max");
    }

    for model in [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex-spark",
        "provider-default",
        "gpt-5.6-terra-preview",
    ] {
        let project_dir =
            make_temp_project_dir(&format!("provider-switch-no-capabilities-reject-{model}"));
        write_settings(&project_dir);

        let output = run_switch(&project_dir, model, "cli-discovery");
        assert!(!output.status.success(), "{model} max must be rejected");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(&format!(
                "model '{model}' does not support reasoning_effort 'max'"
            )),
            "stderr should explain unsupported max for {model}"
        );
        assert!(
            !project_dir
                .join(".winsmux")
                .join("provider-registry.json")
                .exists(),
            "{model} max must be rejected before provider registry write"
        );
    }

    let project_dir = make_temp_project_dir("provider-switch-empty-capabilities");
    write_settings(&project_dir);
    let capabilities_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&capabilities_dir).expect("test should create capabilities directory");
    fs::write(
        capabilities_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{}}"#,
    )
    .expect("test should write empty capabilities registry");

    let output = run_switch(&project_dir, "gpt-5.6-terra", "cli-discovery");
    assert!(
        output.status.success(),
        "GPT-5.6 Terra max should pass with an empty capabilities registry: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let payload: serde_json::Value = serde_json::from_slice(&output.stdout)
        .expect("successful provider-switch output should be JSON");
    assert_eq!(payload["model"], "gpt-5.6-terra");
    assert_eq!(payload["reasoning_effort"], "max");

    let project_dir =
        make_temp_project_dir("provider-switch-no-capabilities-provider-default-source");
    write_settings(&project_dir);
    let output = run_switch(&project_dir, "gpt-5.6-terra", "provider-default");
    assert!(
        !output.status.success(),
        "max must be rejected when provider-default suppresses the concrete GPT-5.6 model"
    );
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("model 'gpt-5.6-terra' does not support reasoning_effort 'max'"),
        "stderr should explain that an unprojected model cannot use max"
    );
    assert!(
        !project_dir
            .join(".winsmux")
            .join("provider-registry.json")
            .exists(),
        "provider-default max must be rejected before provider registry write"
    );
}

#[test]
fn operator_cli_provider_switch_uses_provider_efforts_for_models_without_per_model_declaration() {
    let project_dir = make_temp_project_dir("provider-switch-provider-effort-fallback");
    write_provider_switch_fixture(&project_dir);
    let capability_path = project_dir
        .join(".winsmux")
        .join("provider-capabilities.json");
    let mut capabilities = read_json_file(&capability_path);
    capabilities["providers"]["codex"]["model_options"]
        .as_array_mut()
        .expect("Codex model options should be an array")
        .push(serde_json::json!({
            "id": "legacy-codex",
            "label": "Legacy Codex",
            "source": "cli-discovery"
        }));
    fs::write(
        &capability_path,
        serde_json::to_vec_pretty(&capabilities).expect("capabilities should serialize"),
    )
    .expect("test should update provider capabilities");

    let run_switch = |model: &str, reasoning_effort: &str| {
        Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([
                "provider-switch",
                "worker-1",
                "--model",
                model,
                "--model-source",
                "cli-discovery",
                "--reasoning-effort",
                reasoning_effort,
                "--json",
            ])
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run")
    };

    for effort in ["low", "medium", "high", "xhigh"] {
        let output = run_switch("legacy-codex", effort);
        assert!(
            output.status.success(),
            "legacy Codex model should accept {effort}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let legacy_max = run_switch("legacy-codex", "max");
    assert!(!legacy_max.status.success());
    assert!(
        String::from_utf8_lossy(&legacy_max.stderr)
            .contains("model 'legacy-codex' does not support reasoning_effort 'max'"),
        "legacy Codex model must still reject max"
    );

    let gpt56_max = run_switch("gpt-5.6-terra", "max");
    assert!(
        gpt56_max.status.success(),
        "GPT-5.6 Terra max should pass: {}",
        String::from_utf8_lossy(&gpt56_max.stderr)
    );
}

#[test]
fn operator_cli_provider_switch_backfills_common_efforts_for_legacy_capabilities() {
    let project_dir = make_temp_project_dir("provider-switch-legacy-gpt56-effort");
    write_provider_switch_fixture(&project_dir);
    let capability_path = project_dir
        .join(".winsmux")
        .join("provider-capabilities.json");
    let mut capabilities = read_json_file(&capability_path);
    let options = capabilities["providers"]["codex"]["model_options"]
        .as_array_mut()
        .expect("Codex model options should be an array");
    for option in options.iter_mut() {
        if ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
            .contains(&option["id"].as_str().unwrap_or_default())
        {
            option.as_object_mut().unwrap().remove("reasoning_efforts");
        }
    }
    options.push(serde_json::json!({
        "id": "legacy-codex",
        "label": "Legacy Codex",
        "source": "cli-discovery"
    }));
    capabilities["providers"]["codex"]
        .as_object_mut()
        .unwrap()
        .remove("reasoning_efforts");
    {
        let claude = capabilities["providers"]["claude"]
            .as_object_mut()
            .expect("Claude capability should be an object");
        let opus = claude["model_options"]
            .as_array_mut()
            .expect("Claude model options should be an array")
            .iter_mut()
            .find(|option| option["id"] == "opus")
            .expect("Claude opus option should exist");
        opus.as_object_mut().unwrap().remove("reasoning_efforts");
        claude.remove("reasoning_efforts");
    }
    fs::write(
        &capability_path,
        serde_json::to_vec_pretty(&capabilities).unwrap(),
    )
    .unwrap();

    let run_switch = |model: &str, source: &str, effort: &str| {
        Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([
                "provider-switch",
                "worker-1",
                "--model",
                model,
                "--model-source",
                source,
                "--reasoning-effort",
                effort,
                "--json",
            ])
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run")
    };

    for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
        let output = run_switch(model, "cli-discovery", "max");
        assert!(
            output.status.success(),
            "legacy {model} max should pass: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let legacy_high = run_switch("legacy-codex", "cli-discovery", "high");
    let gpt56_xhigh = run_switch("gpt-5.6-terra", "cli-discovery", "xhigh");
    let legacy_provider_default_high = run_switch("legacy-codex", "provider-default", "high");
    let gpt56_provider_default_xhigh = run_switch("gpt-5.6-terra", "provider-default", "xhigh");
    assert!(
        legacy_high.status.success()
            && gpt56_xhigh.status.success()
            && legacy_provider_default_high.status.success()
            && gpt56_provider_default_xhigh.status.success(),
        "legacy common efforts should pass regardless of model source (legacy high: {}; GPT-5.6 xhigh: {}; provider-default legacy high: {}; provider-default GPT-5.6 xhigh: {}):\n{}\n{}\n{}\n{}",
        legacy_high.status,
        gpt56_xhigh.status,
        legacy_provider_default_high.status,
        gpt56_provider_default_xhigh.status,
        String::from_utf8_lossy(&legacy_high.stderr),
        String::from_utf8_lossy(&gpt56_xhigh.stderr),
        String::from_utf8_lossy(&legacy_provider_default_high.stderr),
        String::from_utf8_lossy(&gpt56_provider_default_xhigh.stderr)
    );

    let assert_rejected_without_write = |model: &str, source: &str| {
        let registry_path = project_dir.join(".winsmux").join("provider-registry.json");
        let before = fs::read(&registry_path).expect("successful setup should create registry");
        let output = run_switch(model, source, "max");
        assert!(
            !output.status.success(),
            "{model} with {source} must reject max"
        );
        assert!(String::from_utf8_lossy(&output.stderr)
            .contains("does not support reasoning_effort 'max'"));
        assert_eq!(
            fs::read(&registry_path).unwrap(),
            before,
            "rejection must precede registry write"
        );
    };
    assert_rejected_without_write("legacy-codex", "cli-discovery");
    assert_rejected_without_write("legacy-codex", "provider-default");
    assert_rejected_without_write("gpt-5.6-terra", "provider-default");

    capabilities["providers"]["codex"]["model_options"]
        .as_array_mut()
        .unwrap()
        .retain(|option| option["id"] != "gpt-5.6-terra");
    capabilities["providers"]["codex"]["reasoning_efforts"] =
        serde_json::json!(["provider-default", "low", "medium", "high", "xhigh", "max"]);
    fs::write(
        &capability_path,
        serde_json::to_vec_pretty(&capabilities).unwrap(),
    )
    .unwrap();
    assert_rejected_without_write("gpt-5.6-terra", "cli-discovery");

    let luna = capabilities["providers"]["codex"]["model_options"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|option| option["id"] == "gpt-5.6-luna")
        .unwrap();
    luna["reasoning_efforts"] = serde_json::json!(["low", "medium", "high", "xhigh"]);
    fs::write(
        &capability_path,
        serde_json::to_vec_pretty(&capabilities).unwrap(),
    )
    .unwrap();
    assert_rejected_without_write("gpt-5.6-luna", "cli-discovery");

    let run_claude_switch = |model: &str, source: &str, effort: &str| {
        Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([
                "provider-switch",
                "worker-1",
                "--agent",
                "claude",
                "--model",
                model,
                "--model-source",
                source,
                "--reasoning-effort",
                effort,
                "--prompt-transport",
                "file",
                "--json",
            ])
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run")
    };
    let claude_legacy_max = run_claude_switch("opus", "official-doc", "max");
    let registry_path = project_dir.join(".winsmux").join("provider-registry.json");
    let before_missing = fs::read(&registry_path).unwrap();
    let claude_missing_high = run_claude_switch("missing-claude", "operator-override", "high");
    let missing_unchanged = fs::read(&registry_path).unwrap() == before_missing;
    let before_provider_default = fs::read(&registry_path).unwrap();
    let claude_provider_default_high = run_claude_switch("opus", "provider-default", "high");
    let provider_default_unchanged = fs::read(&registry_path).unwrap() == before_provider_default;
    assert!(
        claude_legacy_max.status.success()
            && !claude_missing_high.status.success()
            && missing_unchanged
            && String::from_utf8_lossy(&claude_missing_high.stderr)
                .contains("does not support reasoning_effort 'high'")
            && !claude_provider_default_high.status.success()
            && provider_default_unchanged
            && String::from_utf8_lossy(&claude_provider_default_high.stderr)
                .contains("does not support reasoning_effort 'high'"),
        "non-Codex legacy fallback must preserve the matching-option boundary (matching max: {}; missing high: {}, unchanged: {}; provider-default high: {}, unchanged: {}):\n{}\n{}\n{}",
        claude_legacy_max.status,
        claude_missing_high.status,
        missing_unchanged,
        claude_provider_default_high.status,
        provider_default_unchanged,
        String::from_utf8_lossy(&claude_legacy_max.stderr),
        String::from_utf8_lossy(&claude_missing_high.stderr),
        String::from_utf8_lossy(&claude_provider_default_high.stderr)
    );
}

#[test]
fn operator_cli_provider_switch_validates_candidate_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-candidate-before-write");
    write_provider_switch_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-switch", "worker-1", "--agent", "claude", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("Provider capability 'claude' does not support prompt_transport 'argv'"),
        "stderr should explain inherited transport mismatch"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_rejects_unselected_malformed_registry_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-unselected-malformed-registry");
    write_provider_switch_fixture(&project_dir);
    let registry_path = project_dir.join(".winsmux").join("provider-registry.json");
    let registry_before =
        r#"{"version":1,"slots":{"worker-1":{"agent":"codex"},"worker-99":{"agent":true}}}"#;
    fs::write(&registry_path, registry_before).expect("write malformed provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert_eq!(
        fs::read_to_string(&registry_path).expect("read unchanged provider registry"),
        registry_before
    );
}

#[test]
fn operator_cli_provider_switch_accepts_missing_or_null_slots() {
    let cases = [
        ("missing", r#"{"version":1,"future":"keep"}"#),
        ("null", r#"{"version":1,"future":"keep","slots":null}"#),
    ];

    for (case_name, registry_before) in cases {
        let project_dir = make_temp_project_dir(&format!("provider-switch-{case_name}-slots"));
        write_provider_switch_fixture(&project_dir);
        let registry_path = project_dir.join(".winsmux").join("provider-registry.json");
        fs::write(&registry_path, registry_before).expect("write provider registry control");

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([
                "provider-switch",
                "worker-1",
                "--model",
                "gpt-5.5",
                "--model-source",
                "cli-discovery",
                "--json",
            ])
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(
            output.status.success(),
            "{case_name} slots must remain accepted: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let registry = read_json_file(&registry_path);
        assert_eq!(registry["future"], "keep");
        assert_eq!(registry["slots"]["worker-1"]["model"], "gpt-5.5");
    }
}

#[test]
fn operator_cli_provider_switch_replaces_case_variant_registry_key() {
    let project_dir = make_temp_project_dir("provider-switch-case-key");
    write_provider_switch_fixture(&project_dir);

    let _ = run_json(
        &project_dir,
        &[
            "provider-switch",
            "WORKER-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );
    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.4",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["model"], "gpt-5.4");
    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    let slots = registry["slots"]
        .as_object()
        .expect("slots should be a map");
    assert_eq!(slots.len(), 1);
    assert!(slots.get("WORKER-1").is_none());
    assert_eq!(registry["slots"]["worker-1"]["model"], "gpt-5.4");
}

#[test]
fn operator_cli_provider_switch_clear_validates_fallback_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-clear-invalid-fallback");
    write_provider_switch_fixture(&project_dir);
    let settings = fs::read_to_string(project_dir.join(".winsmux.yaml"))
        .expect("test should read settings")
        .replace("agent: codex\n", "agent: claude\n")
        .replace("    agent: codex\n", "    agent: claude\n");
    fs::write(project_dir.join(".winsmux.yaml"), settings).expect("test should write settings");
    fs::write(
        project_dir.join(".winsmux").join("provider-registry.json"),
        r#"{"version":1,"slots":{"worker-1":{"agent":"claude","model":"opus","prompt_transport":"file","updated_at_utc":"2026-04-26T00:00:00Z"}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-switch", "worker-1", "--clear", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("Provider capability 'claude' does not support prompt_transport 'argv'"),
        "stderr should explain invalid fallback"
    );
    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    assert_eq!(registry["slots"]["worker-1"]["agent"], "claude");
    assert_eq!(registry["slots"]["worker-1"]["prompt_transport"], "file");
}

#[test]
fn operator_cli_provider_switch_clears_override() {
    let project_dir = make_temp_project_dir("provider-switch-clear");
    write_provider_switch_fixture(&project_dir);

    let _ = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--prompt-transport",
            "file",
            "--json",
        ],
    );
    let result = run_json(
        &project_dir,
        &["provider-switch", "worker-1", "--clear", "--json"],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["agent"], "codex");
    assert_eq!(result["model"], "gpt-5.4");
    assert_eq!(result["prompt_transport"], "argv");
    assert_eq!(result["source"], "slot");
    assert_eq!(result["capability_adapter"], "codex");
    assert_eq!(result["supports_parallel_runs"], true);
    assert_eq!(result["supports_verification"], true);
    assert_eq!(result["supports_consultation"], false);
    assert_eq!(result["clear_requested"], true);
    assert_eq!(result["cleared"], true);

    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    assert!(registry["slots"]["worker-1"].is_null());
}

#[test]
fn operator_cli_provider_switch_accepts_default_managed_slots() {
    let project_dir = make_temp_project_dir("provider-switch-default-slots");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
agent: codex
model: gpt-5.4
model-source: cli-discovery
prompt-transport: argv
worker-count: 2
external-operator: true
"#,
    )
    .expect("test should write settings without explicit slots");

    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-2",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-2");
    assert_eq!(result["agent"], "codex");
    assert_eq!(result["model"], "gpt-5.5");
    assert_eq!(result["source"], "registry");
}

#[test]
fn operator_cli_runtime_provider_default_keeps_configured_provider() {
    let project_dir = make_temp_project_dir("runtime-provider-default");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir
            .join(".winsmux")
            .join("runtime-role-preferences.json"),
        r#"{
  "version": 1,
  "roles": {
    "worker": {
      "provider": "provider-default",
      "model": "provider-default",
      "model_source": "provider-default",
      "reasoning_effort": "provider-default"
    }
  }
}"#,
    )
    .expect("test should write runtime role preferences");

    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["agent"], "codex");
    assert_eq!(result["model"], "gpt-5.5");
    assert_eq!(result["source"], "registry");
}

#[test]
fn operator_cli_provider_switch_rejects_restart_stale_target_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-restart-stale");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%stale"
    role: Builder
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let winsmux_bin =
        write_fake_winsmux_list_panes(&project_dir, Some("winsmux-orchestra"), &["%live"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("invalid target: %stale"),
        "stderr should explain stale pane target"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_restart_uses_new_provider_adapter() {
    let project_dir = make_temp_project_dir("provider-switch-restart-adapter");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--prompt-transport",
            "file",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["restarted"], true);
    assert_eq!(payload["restart_pane_id"], "%2");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"claude --model opus"));
    assert!(!log.contains("codex -c"));
}

#[test]
fn operator_cli_provider_switch_restart_projects_gpt56_model_and_max_effort() {
    let project_dir = make_temp_project_dir("provider-switch-restart-gpt56-max");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.6-terra",
            "--model-source",
            "cli-discovery",
            "--reasoning-effort",
            "max",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let launch = fs::read_to_string(&log_path)
        .expect("fake winsmux log should exist")
        .lines()
        .find(|line| line.contains("send-keys"))
        .expect("restart should send a launch command")
        .to_string();
    assert!(
        launch.contains("model=gpt-5.6-terra"),
        "restart launch must project the concrete model: {launch}"
    );
    assert!(
        launch.contains("model_reasoning_effort=max"),
        "restart launch must project max effort: {launch}"
    );
}

#[test]
fn operator_cli_provider_switch_restart_skips_provider_default_model() {
    let project_dir = make_temp_project_dir("provider-switch-restart-provider-default");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "provider-default",
            "--reasoning-effort",
            "provider-default",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["model"], "provider-default");
    assert_eq!(payload["reasoning_effort"], "provider-default");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex --sandbox"));
    assert!(!log.contains("model_reasoning_effort="));
    assert!(!log.contains("model=provider-default"));
}

#[test]
fn operator_cli_provider_switch_restart_skips_provider_default_model_source() {
    let project_dir = make_temp_project_dir("provider-switch-restart-provider-default-source");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.4",
            "--model-source",
            "provider-default",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["model"], "gpt-5.4");
    assert_eq!(payload["model_source"], "provider-default");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex --sandbox"));
    assert!(!log.contains("model=gpt-5.4"));
}

#[test]
fn operator_cli_restart_rejects_unprojected_gpt56_max_before_launch() {
    let project_dir = make_temp_project_dir("restart-unprojected-gpt56-max");
    write_provider_switch_fixture(&project_dir);
    fs::remove_file(
        project_dir
            .join(".winsmux")
            .join("provider-capabilities.json"),
    )
    .expect("test should remove capability registry");
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    fs::write(
        project_dir.join(".winsmux").join("provider-registry.json"),
        r#"{"version":1,"slots":{"worker-1":{"agent":"codex","model":"gpt-5.6-terra","model_source":"provider-default","reasoning_effort":"max","updated_at_utc":"2026-07-12T00:00:00Z"}}}"#,
    )
    .expect("test should write persisted provider override");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "worker-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("model 'gpt-5.6-terra' does not support reasoning_effort 'max'"),
        "restart must reject max when the concrete model is not projected"
    );
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !log.contains("send-keys"),
        "restart must not launch an unprojected max configuration: {log}"
    );
}

#[test]
fn operator_cli_provider_switch_clear_restart_uses_configured_provider() {
    let project_dir = make_temp_project_dir("provider-switch-clear-restart-adapter");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("provider-registry.json"),
        r#"{"version":1,"slots":{"worker-1":{"agent":"claude","model":"opus","prompt_transport":"file","updated_at_utc":"2026-04-26T00:00:00Z"}}}"#,
    )
    .expect("test should write provider registry");
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    provider_target: claude:opus
    capability_adapter: claude
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--clear",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["agent"], "codex");
    assert_eq!(payload["source"], "slot");
    assert_eq!(payload["restarted"], true);
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex -c 'model=gpt-5.4'"));
    assert!(!log.contains("claude --model opus"));
}

#[test]
fn operator_cli_provider_switch_restart_merges_partial_override_with_slot() {
    let project_dir = make_temp_project_dir("provider-switch-partial-restart");
    write_provider_switch_fixture(&project_dir);
    let settings = fs::read_to_string(project_dir.join(".winsmux.yaml"))
        .expect("test should read settings")
        .replace("    agent: codex\n", "    agent: claude\n")
        .replace(
            "    prompt-transport: argv\n",
            "    prompt-transport: file\n",
        );
    fs::write(project_dir.join(".winsmux.yaml"), settings).expect("test should write settings");
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "opus",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["agent"], "claude");
    assert_eq!(payload["model"], "opus");
    assert_eq!(payload["source"], "registry");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"claude --model opus"));
    assert!(!log.contains("codex -c"));
}

#[test]
fn operator_cli_conflict_preflight_json_reports_clean_result() {
    let project_dir = make_temp_project_dir("conflict-preflight-clean");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "left.txt", "left\n");
    run_git(&project_dir, &["add", "left.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "base"]);
    write_git_file(&project_dir, "right.txt", "right\n");
    run_git(&project_dir, &["add", "right.txt"]);
    run_git(&project_dir, &["commit", "-m", "right change"]);
    run_git(&project_dir, &["branch", "right"]);

    let json = run_json(
        &project_dir,
        &["conflict-preflight", "left", "right", "--json"],
    );

    assert_eq!(json["command"], "conflict-preflight");
    assert_eq!(json["status"], "clean");
    assert_eq!(json["reason"], "");
    assert_eq!(json["conflict_detected"], false);
    assert_eq!(json["left_ref"], "left");
    assert_eq!(json["right_ref"], "right");
    assert_eq!(json["merge_tree_exit_code"], 0);
    assert_eq!(json["overlap_paths"].as_array().unwrap().len(), 0);
    assert_eq!(json["left_only_paths"][0], "left.txt");
    assert_eq!(json["right_only_paths"][0], "right.txt");
}

#[test]
fn operator_cli_compare_preflight_json_uses_public_command_name() {
    let project_dir = make_temp_project_dir("compare-preflight-clean");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "left.txt", "left\n");
    run_git(&project_dir, &["add", "left.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "base"]);
    write_git_file(&project_dir, "right.txt", "right\n");
    run_git(&project_dir, &["add", "right.txt"]);
    run_git(&project_dir, &["commit", "-m", "right change"]);
    run_git(&project_dir, &["branch", "right"]);

    let json = run_json(
        &project_dir,
        &["compare", "preflight", "left", "right", "--json"],
    );

    assert_eq!(json["command"], "compare preflight");
    assert_eq!(json["status"], "clean");
    assert_eq!(
        json["next_action"],
        "Safe to continue to compare UI or follow-up review."
    );
}

#[test]
fn operator_cli_compare_preflight_invalid_usage_reports_public_command() {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "preflight", "left-only"])
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "invalid usage should fail");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare preflight <left_ref> <right_ref> [--json]"),
        "stderr should show public usage: {stderr}"
    );
    assert!(
        !stderr.contains("conflict-preflight"),
        "public usage should not mention compatibility command: {stderr}"
    );
}

#[test]
fn operator_cli_conflict_preflight_json_reports_conflict() {
    let project_dir = make_temp_project_dir("conflict-preflight-conflict");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "shared.txt", "left\n");
    run_git(&project_dir, &["add", "shared.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "base"]);
    write_git_file(&project_dir, "shared.txt", "right\n");
    run_git(&project_dir, &["add", "shared.txt"]);
    run_git(&project_dir, &["commit", "-m", "right change"]);
    run_git(&project_dir, &["branch", "right"]);

    let json = run_json(
        &project_dir,
        &["conflict-preflight", "left", "right", "--json"],
    );

    assert_eq!(json["status"], "conflict");
    assert_eq!(json["reason"], "merge_conflict");
    assert_eq!(json["conflict_detected"], true);
    assert_eq!(json["merge_tree_exit_code"], 1);
    assert_eq!(json["overlap_paths"][0], "shared.txt");
}

#[test]
fn operator_cli_conflict_preflight_json_reports_no_merge_base() {
    let project_dir = make_temp_project_dir("conflict-preflight-no-merge-base");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "left.txt", "left\n");
    run_git(&project_dir, &["add", "left.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "--orphan", "unrelated"]);
    run_git(&project_dir, &["rm", "-rf", "."]);
    write_git_file(&project_dir, "unrelated.txt", "unrelated\n");
    run_git(&project_dir, &["add", "unrelated.txt"]);
    run_git(&project_dir, &["commit", "-m", "unrelated change"]);

    let json = run_json(
        &project_dir,
        &["conflict-preflight", "left", "unrelated", "--json"],
    );

    assert_eq!(json["status"], "blocked");
    assert_eq!(json["reason"], "no_merge_base");
    assert_eq!(json["merge_tree_exit_code"], serde_json::Value::Null);
    assert_eq!(json["conflict_detected"], false);
    assert_eq!(
        json["next_action"],
        "Choose related refs with a shared merge base and rerun winsmux conflict-preflight."
    );

    let alias_json = run_json(
        &project_dir,
        &["compare", "preflight", "left", "unrelated", "--json"],
    );
    assert_eq!(alias_json["command"], "compare preflight");
    assert_eq!(
        alias_json["next_action"],
        "Choose related refs with a shared merge base and rerun winsmux compare preflight."
    );
}

#[test]
fn operator_cli_signal_writes_temp_signal_file() {
    let project_dir = make_temp_project_dir("signal-command");
    let tmp_dir = project_dir.join("tmp");
    let temp_dir = project_dir.join("temp");
    fs::create_dir_all(&tmp_dir).expect("test should create tmp dir");
    fs::create_dir_all(&temp_dir).expect("test should create temp dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["signal", "desktop-ready"])
        .env("TMP", &tmp_dir)
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "sent signal: desktop-ready"
    );
    let signal_file = temp_dir
        .join("winsmux")
        .join("signals")
        .join("desktop-ready.signal");
    let signal = fs::read_to_string(signal_file).expect("signal file should exist");
    assert!(signal.contains('T'));
}

#[test]
fn operator_cli_signal_treats_leading_dash_as_channel() {
    let project_dir = make_temp_project_dir("signal-leading-dash");
    let temp_dir = project_dir.join("temp");
    fs::create_dir_all(&temp_dir).expect("test should create temp dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["signal", "--json"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "sent signal: --json"
    );
    let signal_file = temp_dir
        .join("winsmux")
        .join("signals")
        .join("--json.signal");
    assert!(
        signal_file.exists(),
        "leading-dash channel should be literal"
    );
}

#[test]
fn operator_cli_wait_consumes_temp_signal_file() {
    let project_dir = make_temp_project_dir("wait-command");
    let temp_dir = project_dir.join("temp");
    let signal_dir = temp_dir.join("winsmux").join("signals");
    fs::create_dir_all(&signal_dir).expect("test should create signal dir");
    let signal_file = signal_dir.join("desktop-ready.signal");
    fs::write(&signal_file, "ready").expect("test should write signal file");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "desktop-ready", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "received signal: desktop-ready"
    );
    assert!(!signal_file.exists(), "wait should remove consumed signal");
}

#[test]
fn operator_cli_wait_treats_leading_dash_as_channel() {
    let project_dir = make_temp_project_dir("wait-leading-dash");
    let temp_dir = project_dir.join("temp");
    let signal_dir = temp_dir.join("winsmux").join("signals");
    fs::create_dir_all(&signal_dir).expect("test should create signal dir");
    let signal_file = signal_dir.join("--json.signal");
    fs::write(&signal_file, "ready").expect("test should write signal file");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "--json", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "received signal: --json"
    );
    assert!(
        !signal_file.exists(),
        "leading-dash channel should be literal"
    );
}

#[test]
fn operator_cli_wait_treats_dash_t_as_channel() {
    let project_dir = make_temp_project_dir("wait-dash-t");
    let temp_dir = project_dir.join("temp");
    let signal_dir = temp_dir.join("winsmux").join("signals");
    fs::create_dir_all(&signal_dir).expect("test should create signal dir");
    let signal_file = signal_dir.join("-t.signal");
    fs::write(&signal_file, "ready").expect("test should write signal file");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "-t", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "received signal: -t"
    );
    assert!(!signal_file.exists(), "-t channel should be literal");
}

#[test]
fn operator_cli_wait_signal_option_preserves_tmux_alias() {
    let project_dir = make_temp_project_dir("wait-signal-tmux-alias");
    let home_dir = project_dir.join("home");
    fs::create_dir_all(&home_dir).expect("test should create isolated home directory");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "-S", "compat-channel"])
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .env_remove("PSMUX_TARGET_SESSION")
        .env_remove("PSMUX_TARGET_FULL")
        .env_remove("TMUX")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("no server running") || output.status.success(),
        "wait -S should route to the tmux-compatible wait path: {stderr}"
    );
    assert!(
        !stderr.contains("Unknown command"),
        "wait -S must not fall through to unknown command"
    );
}

#[test]
fn operator_cli_wait_timeout_creates_signal_dir() {
    let project_dir = make_temp_project_dir("wait-creates-dir");
    let temp_dir = project_dir.join("temp");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "missing", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "wait should fail on timeout");
    assert!(
        temp_dir.join("winsmux").join("signals").exists(),
        "wait should establish the shared signal directory"
    );
}

#[test]
fn operator_cli_wait_times_out_without_signal() {
    let project_dir = make_temp_project_dir("wait-timeout");
    let temp_dir = project_dir.join("temp");
    fs::create_dir_all(&temp_dir).expect("test should create temp dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "missing", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "wait should fail on timeout");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("timeout waiting for signal: missing (0s)"),
        "stderr should explain timeout: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn operator_cli_poll_events_returns_events_after_cursor() {
    let project_dir = make_temp_project_dir("poll-events");
    write_manifest(&project_dir);

    let json = run_json(&project_dir, &["poll-events", "1"]);

    assert_eq!(json["cursor"], 2);
    assert_eq!(
        json["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        1
    );
    assert_eq!(json["events"][0]["event"], "operator.commit_ready");
    assert_eq!(json["events"][0]["pane_id"], "%2");
}

#[test]
fn operator_cli_poll_events_handles_missing_file_and_cursor_bounds() {
    let project_dir = make_temp_project_dir("poll-events-empty");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("test should create .winsmux");

    let missing = run_json(&project_dir, &["poll-events"]);
    assert_eq!(missing["cursor"], 0);
    assert_eq!(
        missing["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        0
    );

    fs::write(
        project_dir.join(".winsmux").join("events.jsonl"),
        r#"
{"timestamp":"2026-04-24T12:00:01+09:00","event":"one"}

{"timestamp":"2026-04-24T12:00:02+09:00","event":"two"}
"#,
    )
    .expect("test should write events");

    let past_end = run_json(&project_dir, &["poll-events", "99"]);
    assert_eq!(past_end["cursor"], 2);
    assert_eq!(
        past_end["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        0
    );

    let negative = run_json(&project_dir, &["poll-events", "-1"]);
    assert_eq!(negative["cursor"], 2);
    assert_eq!(
        negative["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        2
    );
}

#[test]
fn operator_cli_compare_runs_json_reports_evidence_delta() {
    let project_dir = make_temp_project_dir("compare-runs");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path).expect("test should read manifest");
    let manifest = manifest.replace(
        "    changed_files: '[\"core/src/operator_cli.rs\"]'",
        "    changed_files: '[\"core/src/operator_cli.rs\",\"C:\\\\Users\\\\Example\\\\secret.txt\",\"../private.md\"]'",
    );
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["left"]["run_id"], "task:task-a");
    assert_eq!(json["right"]["run_id"], "task:task-b");
    assert_eq!(json["confidence_delta"], 0.25);
    assert_eq!(json["shared_changed_files"][0], "core/src/operator_cli.rs");
    assert_eq!(json["right_only_changed_files"][0], "core/src/main.rs");
    assert_eq!(json["recommend"]["winning_run_id"], "task:task-a");
    assert_eq!(json["recommend"]["reconcile_consult"], true);
    assert_eq!(
        json["recommend"]["playbook_template"]["packet_type"],
        "playbook_template_contract"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["flow"],
        "compare_winner_follow_up"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["required_evidence"][0],
        "winning_run"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["team_memory_refs"][0],
        "team-memory:task-a:operator-standard"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["freeform_body_stored"],
        false
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["review_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["auto_merge_allowed"],
        false
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["packet_type"],
        "managed_follow_up_run_contract"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["source_run_id"],
        "task:task-a"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["run_mode"],
        "operator_managed"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["playbook_template_ref"],
        "playbook:compare_winner_follow_up"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["required_evidence"][0],
        "winning_run"
    );
    let follow_up_changed_files = json["recommend"]["follow_up_run"]["changed_files"]
        .as_array()
        .expect("follow-up changed_files should be an array");
    assert_eq!(follow_up_changed_files.len(), 1);
    assert_eq!(follow_up_changed_files[0], "core/src/operator_cli.rs");
    assert_eq!(
        json["recommend"]["follow_up_run"]["source_evidence_refs"][0],
        ".winsmux/observation-packs/task-a.json"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["source_evidence_refs"][1],
        ".winsmux/consultations/task-a.json"
    );
    assert_eq!(json["recommend"]["follow_up_run"]["review_required"], true);
    assert_eq!(
        json["recommend"]["follow_up_run"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["auto_merge_allowed"],
        false
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["merge_requires_human"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["packet_type"],
        "diversity_policy_contract"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "mixed_provider"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "mixed_model"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["metadata_policy"]
            ["raw_model_prompts_stored"],
        false
    );
    assert!(
        json["recommend"]["playbook_template"]["diversity_policy"]["provider_target"].is_null()
    );
    let fields: Vec<_> = json["differences"]
        .as_array()
        .expect("differences should be array")
        .iter()
        .filter_map(|difference| difference["field"].as_str())
        .collect();
    assert!(fields.contains(&"result"));
    assert!(fields.contains(&"confidence"));
    assert!(fields.contains(&"changed_files"));
}

#[test]
fn operator_cli_compare_runs_preserves_follow_up_playbook_for_ci_paths() {
    let project_dir = make_temp_project_dir("compare-runs-ci-path-playbook");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path).expect("test should read manifest");
    let manifest = manifest.replace("core/src/operator_cli.rs", ".github/workflows/ci.yml");
    fs::write(manifest_path, manifest).expect("test should write manifest");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["recommend"]["winning_run_id"], "task:task-a");
    assert_eq!(
        json["recommend"]["playbook_template"]["flow"],
        "compare_winner_follow_up"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["template_refs"][0],
        "playbook:compare_winner_follow_up"
    );
}

#[test]
fn operator_cli_compare_runs_public_alias_reports_evidence_delta() {
    let project_dir = make_temp_project_dir("compare-runs-alias");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &["compare", "runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["left"]["run_id"], "task:task-a");
    assert_eq!(json["right"]["run_id"], "task:task-b");
    assert_eq!(json["confidence_delta"], 0.25);
    assert_eq!(json["recommend"]["winning_run_id"], "task:task-a");
}

#[test]
fn operator_cli_compare_runs_public_alias_reports_public_usage() {
    let project_dir = make_temp_project_dir("compare-runs-alias-usage");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "runs", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("usage: winsmux compare runs"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "runs", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare runs"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_compare_runs_text_reports_differences() {
    let project_dir = make_temp_project_dir("compare-runs-text");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare-runs", "task:task-a", "task:task-b"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Compare: task:task-a vs task:task-b"));
    assert!(stdout.contains("Differences:"));
    assert!(stdout.contains("- result: left=cache hit right=rebuild clean"));
    assert!(stdout.contains("- changed_files: left=core/src/operator_cli.rs right=core/src/operator_cli.rs, core/src/main.rs"));
}

#[test]
fn operator_cli_compare_runs_uses_powershell_rounding() {
    let project_dir = make_temp_project_dir("compare-runs-rounding");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace("\"confidence\":0.85", "\"confidence\":0.12345")
        .replace("\"confidence\":0.6", "\"confidence\":0.0");
    fs::write(events_path, events).expect("test should write events");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["confidence_delta"], 0.1234);
}

#[test]
fn operator_cli_compare_runs_marks_partial_provider_metadata_unknown() {
    let project_dir = make_temp_project_dir("compare-runs-partial-provider");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    provider_target: claude:opus\n", "");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let json = run_json(
        &project_dir,
        &[
            "compare-runs",
            "task:task-a",
            "task:task-b",
            "--json",
            "--project-dir",
            project_dir.to_str().unwrap(),
        ],
    );

    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["scope"],
        "run_set"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "unknown"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]
            ["provider_count_bucket"],
        "unknown"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "unknown"
    );
}

#[test]
fn operator_cli_compare_runs_emits_conflict_resolution_playbook_when_no_winner() {
    let project_dir = make_temp_project_dir("compare-runs-conflict-playbook");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace("\"outcome\":\"PASS\"", "\"outcome\":\"FAIL\"");
    fs::write(events_path, events).expect("test should write events");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["recommend"]["winning_run_id"], "");
    assert_eq!(
        json["recommend"]["playbook_template"]["flow"],
        "conflict_resolution"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["compare_run_ids"][0],
        "task:task-a"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["required_evidence"][0],
        "overlap_paths"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["team_memory_refs"][0],
        "team-memory:task-a:operator-standard"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["scope"],
        "run_set"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "mixed_provider"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "mixed_model"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["harness_mix"],
        "single_harness"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["metadata_policy"]
            ["raw_provider_ids_stored"],
        false
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["review_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["auto_merge_allowed"],
        false
    );
    assert!(json["recommend"]["follow_up_run"].is_null());
    let diversity_policy_text =
        json["recommend"]["playbook_template"]["diversity_policy"].to_string();
    assert!(!diversity_policy_text.contains("codex"));
    assert!(!diversity_policy_text.contains("claude"));
    assert!(!diversity_policy_text.contains("gpt-5.4"));
    assert!(!diversity_policy_text.contains("opus"));
}

#[test]
fn operator_cli_promote_tactic_writes_playbook_candidate() {
    let project_dir = make_temp_project_dir("promote-tactic");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &[
            "promote-tactic",
            "task:task-a",
            "--title",
            "Deterministic build command",
            "--json",
        ],
    );

    assert_eq!(json["run_id"], "task:task-a");
    assert!(json["candidate_ref"]
        .as_str()
        .expect("candidate ref should be a string")
        .starts_with(".winsmux/playbook-candidates/playbook-candidate-"));
    let candidate_path = json["candidate_path"]
        .as_str()
        .expect("candidate path should be a string");
    assert!(std::path::Path::new(candidate_path).is_file());
    let candidate_file =
        fs::read_to_string(candidate_path).expect("candidate file should be readable");
    let candidate_json: serde_json::Value =
        serde_json::from_str(&candidate_file).expect("candidate file should be JSON");
    assert_eq!(candidate_json["packet_type"], "playbook_candidate");
    assert_eq!(candidate_json["kind"], "playbook");
    assert!(candidate_json["generated_at"].as_str().is_some());
    assert_eq!(candidate_json["title"], "Deterministic build command");
    assert_eq!(candidate_json["summary"], "prefer cache command");
    assert_eq!(json["candidate"]["packet_type"], "playbook_candidate");
    assert_eq!(json["candidate"]["kind"], "playbook");
    assert_eq!(json["candidate"]["title"], "Deterministic build command");
    assert_eq!(json["candidate"]["summary"], "prefer cache command");
    assert_eq!(json["candidate"]["hypothesis"], "cache command is stable");
    assert_eq!(
        json["candidate"]["changed_files"][0],
        "core/src/operator_cli.rs"
    );
    assert_eq!(
        json["candidate"]["observation_pack_ref"],
        ".winsmux/observation-packs/task-a.json"
    );
    assert_eq!(
        json["candidate"]["consultation_ref"],
        ".winsmux/consultations/task-a.json"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["packet_type"],
        "playbook_template_contract"
    );
    assert_eq!(json["candidate"]["playbook_template"]["flow"], "bugfix");
    assert_eq!(
        json["candidate"]["playbook_template"]["required_evidence"][0],
        "reproduction"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["team_memory_refs"][0],
        "team-memory:task-a:operator-standard"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["execution_backend"],
        "operator_managed"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["freeform_body_stored"],
        false
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["review_required"],
        true
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["auto_merge_allowed"],
        false
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["merge_requires_human"],
        true
    );
    assert!(json["candidate"]["playbook_template"]["freeform_body"].is_null());
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["packet_type"],
        "diversity_policy_contract"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "single_provider"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "single_model"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["metadata_policy"]
            ["private_prompt_bodies_stored"],
        false
    );
    let diversity_policy_text =
        json["candidate"]["playbook_template"]["diversity_policy"].to_string();
    assert!(!diversity_policy_text.contains("codex"));
    assert!(!diversity_policy_text.contains("gpt-5.4"));
}

#[test]
fn operator_cli_compare_promote_alias_writes_playbook_candidate() {
    let project_dir = make_temp_project_dir("compare-promote-alias");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &[
            "compare",
            "promote",
            "task:task-a",
            "--title",
            "Deterministic build command",
            "--json",
        ],
    );

    assert_eq!(json["run_id"], "task:task-a");
    assert!(json["candidate_ref"]
        .as_str()
        .expect("candidate ref should be a string")
        .starts_with(".winsmux/playbook-candidates/playbook-candidate-"));
    assert_eq!(json["candidate"]["packet_type"], "playbook_candidate");
    assert_eq!(json["candidate"]["kind"], "playbook");
    assert_eq!(json["candidate"]["title"], "Deterministic build command");
    assert_eq!(json["candidate"]["summary"], "prefer cache command");
}

#[test]
fn operator_cli_promote_tactic_verification_kind_uses_ci_playbook() {
    let project_dir = make_temp_project_dir("promote-tactic-verification-playbook");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &[
            "promote-tactic",
            "task:task-a",
            "--kind",
            "verification",
            "--json",
        ],
    );

    assert_eq!(json["candidate"]["kind"], "verification");
    assert_eq!(json["candidate"]["playbook_template"]["flow"], "ci");
    assert_eq!(
        json["candidate"]["playbook_template"]["required_evidence"][0],
        "workflow_status"
    );
}

#[test]
fn operator_cli_promote_tactic_review_next_action_uses_review_playbook() {
    let project_dir = make_temp_project_dir("promote-tactic-review-playbook");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace(
            "\"next_action\":\"promote tactic\"",
            "\"next_action\":\"review findings\"",
        );
    fs::write(events_path, events).expect("test should write events");

    let json = run_json(&project_dir, &["promote-tactic", "task:task-a", "--json"]);

    assert_eq!(json["candidate"]["playbook_template"]["flow"], "review");
    assert_eq!(
        json["candidate"]["playbook_template"]["required_evidence"][0],
        "findings"
    );
}

#[test]
fn operator_cli_compare_promote_alias_reports_public_usage() {
    let project_dir = make_temp_project_dir("compare-promote-alias-usage");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "promote", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("usage: winsmux compare promote"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "promote"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare promote"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_promote_tactic_rejects_unhealthy_run() {
    let project_dir = make_temp_project_dir("promote-tactic-unhealthy");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace("\"outcome\":\"PASS\"", "\"outcome\":\"FAIL\"");
    fs::write(events_path, events).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("run is not promotable: task:task-a"));
}

#[test]
fn operator_cli_promote_tactic_rejects_missing_security_clearance() {
    let project_dir = make_temp_project_dir("promote-tactic-no-security");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .lines()
        .filter(|line| !line.contains("\"event\":\"pipeline.security.allowed\""))
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(events_path, events).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("run is not promotable: task:task-a"));
}

#[test]
fn operator_cli_promote_tactic_rejects_unreviewed_architecture_drift() {
    let project_dir = make_temp_project_dir("promote-tactic-architecture-drift");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replacen("    review_state: PASS", "    review_state: ", 1);
    fs::write(manifest_path, manifest).expect("test should write manifest");
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace(
            "verification passed",
            "architecture drift detected after verification",
        );
    fs::write(events_path, events).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("run is not promotable: task:task-a"));
}

#[test]
fn operator_cli_promote_tactic_rejects_unknown_kind() {
    let project_dir = make_temp_project_dir("promote-tactic-kind");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a", "--kind", "unknown"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Unsupported promote kind: unknown"));
}

#[test]
fn operator_cli_consult_error_records_packet_event_and_manifest() {
    let project_dir = make_temp_project_dir("consult-error");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Builder\n", "    role: Worker\n");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-error",
            "stuck",
            "--message",
            "Reviewer context is missing",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("consult error recorded for operator:session-1"));

    let events = fs::read_to_string(project_dir.join(".winsmux").join("events.jsonl"))
        .expect("events should be readable");
    let last_event: serde_json::Value = serde_json::from_str(
        events
            .lines()
            .filter(|line| !line.trim().is_empty())
            .last()
            .expect("events should contain a consultation error"),
    )
    .expect("event should be JSON");
    assert_eq!(last_event["event"], "pane.consult_error");
    assert_eq!(last_event["message"], "Reviewer context is missing");
    let consultation_ref = last_event["data"]["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    assert!(consultation_ref.starts_with(".winsmux/consultations/consult-error-"));

    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["packet_type"], "consultation_packet");
    assert_eq!(packet["kind"], "consult_error");
    assert_eq!(packet["mode"], "stuck");
    assert_eq!(packet["error"], "Reviewer context is missing");
    assert!(packet["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .starts_with("governance:consult:stuck"));
    assert!(packet["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .contains("builder-1"));
    assert_eq!(
        packet["governance_cost_units"][0]["unit_id"],
        packet["cost_unit_refs"][0]
    );
    assert!(packet.get("recommendation").is_none());
    assert!(last_event["data"].get("result").is_none());
    assert_eq!(
        last_event["data"]["cost_unit_refs"],
        packet["cost_unit_refs"]
    );
    assert_eq!(
        last_event["data"]["governance_cost_units"][0]["unit_id"],
        packet["cost_unit_refs"][0]
    );

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["last_event"], "consult.error");
    assert!(builder["last_event_at"].as_str().is_some());
}

#[test]
fn operator_cli_consult_request_records_packet_event_and_manifest() {
    let project_dir = make_temp_project_dir("consult-request");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Builder\n", "    role: Worker\n");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-request",
            "early",
            "--message",
            "Please review the Rust port",
            "--target-slot",
            "reviewer-1",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("consult request recorded for operator:session-1"));

    let events = fs::read_to_string(project_dir.join(".winsmux").join("events.jsonl"))
        .expect("events should be readable");
    let last_event: serde_json::Value = serde_json::from_str(
        events
            .lines()
            .filter(|line| !line.trim().is_empty())
            .last()
            .expect("events should contain a consultation request"),
    )
    .expect("event should be JSON");
    assert_eq!(last_event["event"], "pane.consult_request");
    assert_eq!(last_event["message"], "Please review the Rust port");
    let consultation_ref = last_event["data"]["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    assert!(consultation_ref.starts_with(".winsmux/consultations/consult-request-"));
    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["packet_type"], "consultation_packet");
    assert_eq!(packet["kind"], "consult_request");
    assert_eq!(packet["mode"], "early");
    assert_eq!(packet["request"], "Please review the Rust port");
    assert!(packet.get("recommendation").is_none());
    assert_eq!(
        packet["governance_cost_units"][0]["unit_type"],
        "governance_invocation"
    );
    assert_eq!(packet["governance_cost_units"][0]["kind"], "consult");
    assert_eq!(packet["governance_cost_units"][0]["mode"], "early");

    assert_eq!(last_event["data"]["consultation_ref"], consultation_ref);
    assert_eq!(
        last_event["data"]["governance_cost_units"][0]["unit_id"],
        packet["governance_cost_units"][0]["unit_id"]
    );
    assert!(last_event["data"].get("result").is_none());

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["last_event"], "consult.request");
    assert!(builder["last_event_at"].as_str().is_some());
}

#[test]
fn operator_cli_consult_result_records_packet_event_and_manifest() {
    let project_dir = make_temp_project_dir("consult-result");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Builder\n", "    role: Worker\n");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-result",
            "final",
            "--message",
            "Ship the Rust command",
            "--confidence",
            "0.82",
            "--next-test",
            "cargo test --manifest-path core/Cargo.toml --test operator_cli",
            "--risk",
            "manifest update could drift",
            "--json",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert_eq!(json["run_id"], "operator:session-1");
    assert_eq!(json["task_id"], "TASK-266");
    assert_eq!(json["pane_id"], "%2");
    assert_eq!(json["slot"], "builder-1");
    assert_eq!(json["kind"], "consult_result");
    assert_eq!(json["mode"], "final");
    assert_eq!(json["recommendation"], "Ship the Rust command");
    assert_eq!(json["confidence"], 0.82);
    assert_eq!(
        json["next_test"],
        "cargo test --manifest-path core/Cargo.toml --test operator_cli"
    );
    assert_eq!(json["risks"][0], "manifest update could drift");
    assert!(json["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .starts_with("governance:consult:final"));
    assert!(json["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .contains("builder-1"));
    let consultation_ref = json["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    assert!(consultation_ref.starts_with(".winsmux/consultations/consult-result-"));

    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["packet_type"], "consultation_packet");
    assert_eq!(packet["kind"], "consult_result");
    assert_eq!(packet["mode"], "final");
    assert_eq!(packet["recommendation"], "Ship the Rust command");
    assert_eq!(packet["next_test"], json["next_test"]);
    assert_eq!(packet["risks"][0], "manifest update could drift");
    assert_eq!(packet["cost_unit_refs"], json["cost_unit_refs"]);
    assert_eq!(
        packet["governance_cost_units"][0]["unit_id"],
        json["cost_unit_refs"][0]
    );

    let events = fs::read_to_string(project_dir.join(".winsmux").join("events.jsonl"))
        .expect("events should be readable");
    let last_event: serde_json::Value = serde_json::from_str(
        events
            .lines()
            .filter(|line| !line.trim().is_empty())
            .last()
            .expect("events should contain a consultation result"),
    )
    .expect("event should be JSON");
    assert_eq!(last_event["event"], "pane.consult_result");
    assert_eq!(last_event["message"], "Ship the Rust command");
    assert_eq!(
        last_event["data"]["governance_cost_units"][0]["unit_id"],
        json["cost_unit_refs"][0]
    );
    assert_eq!(last_event["data"]["result"], "Ship the Rust command");
    assert_eq!(last_event["data"]["confidence"], 0.82);
    assert_eq!(last_event["data"]["next_action"], json["next_test"]);
    assert_eq!(last_event["data"]["consultation_ref"], consultation_ref);
    assert_eq!(last_event["data"]["cost_unit_refs"], json["cost_unit_refs"]);

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["last_event"], "consult.result");
    assert!(builder["last_event_at"].as_str().is_some());
}

#[test]
fn operator_cli_consult_result_accepts_run_override() {
    let project_dir = make_temp_project_dir("consult-result-run");
    write_manifest(&project_dir);

    let json = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-result",
            "reconcile",
            "--message",
            "Use the existing review state",
            "--target-slot",
            "reviewer-1",
            "--run-id",
            "task:TASK-266",
            "--json",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");

    assert!(
        json.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&json.stderr)
    );
    let result: serde_json::Value =
        serde_json::from_slice(&json.stdout).expect("stdout should be JSON");
    assert_eq!(result["run_id"], "task:TASK-266");
    assert_eq!(result["mode"], "reconcile");
    assert_eq!(result["target_slot"], "reviewer-1");
    assert_eq!(result["recommendation"], "Use the existing review state");
    assert!(result["confidence"].is_null());
    assert!(result["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .starts_with("governance:consult:reconcile"));

    let consultation_ref = result["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["confidence"], 0.0);
    assert_eq!(packet["next_test"], "");
    assert_eq!(
        packet["risks"]
            .as_array()
            .expect("risks should be an array")
            .len(),
        0
    );

    let explain = run_json(&project_dir, &["explain", "task:TASK-266", "--json"]);
    assert_eq!(
        explain["consultation_packet"]["recommendation"],
        "Use the existing review state"
    );
    assert_eq!(explain["consultation_packet"]["confidence"], 0.0);
    assert_eq!(explain["consultation_packet"]["next_test"], "");
    assert_eq!(
        explain["consultation_packet"]["risks"]
            .as_array()
            .expect("risks should be an array")
            .len(),
        0
    );
}

#[test]
fn operator_cli_consult_result_rejects_invalid_input() {
    let project_dir = make_temp_project_dir("consult-result-invalid");
    write_manifest(&project_dir);

    let bad_mode = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-result", "later", "--message", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_mode.status.success());
    assert!(String::from_utf8_lossy(&bad_mode.stderr).contains("Unsupported consult mode"));

    let missing_message = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-result", "final"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!missing_message.status.success());
    assert!(
        String::from_utf8_lossy(&missing_message.stderr).contains("consult message is required")
    );
}

#[test]
fn operator_cli_consult_request_rejects_invalid_input() {
    let project_dir = make_temp_project_dir("consult-request-invalid");
    write_manifest(&project_dir);

    let bad_mode = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-request", "later", "--message", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_mode.status.success());
    assert!(String::from_utf8_lossy(&bad_mode.stderr).contains("Unsupported consult mode"));

    let ignored_options = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-request",
            "early",
            "--message",
            "compat",
            "--json",
            "--run-id",
            "run-1",
            "--confidence",
            "0.5",
            "--next-test",
            "ignored",
            "--risk",
            "ignored",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(
        ignored_options.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&ignored_options.stderr)
    );

    let unknown_option = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-request", "early", "--unknown", "value"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!unknown_option.status.success());
    assert!(String::from_utf8_lossy(&unknown_option.stderr)
        .contains("unknown argument for winsmux consult-request"));

    let bad_confidence = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-request", "early", "--confidence", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_confidence.status.success());
    assert!(
        String::from_utf8_lossy(&bad_confidence.stderr).contains("Invalid confidence value: nope")
    );
}

#[test]
fn operator_cli_consult_error_rejects_invalid_input() {
    let project_dir = make_temp_project_dir("consult-error-invalid");
    write_manifest(&project_dir);

    let bad_mode = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "later", "--message", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_mode.status.success());
    assert!(String::from_utf8_lossy(&bad_mode.stderr).contains("Unsupported consult mode"));

    let ignored_options = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-error",
            "early",
            "--message",
            "compat",
            "--json",
            "--run-id",
            "run-1",
            "--confidence",
            "0.5",
            "--next-test",
            "ignored",
            "--risk",
            "ignored",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(
        ignored_options.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&ignored_options.stderr)
    );

    let unknown_option = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "early", "--unknown", "value"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!unknown_option.status.success());
    assert!(String::from_utf8_lossy(&unknown_option.stderr)
        .contains("unknown argument for winsmux consult-error"));

    let bad_confidence = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "early", "--confidence", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_confidence.status.success());
    assert!(
        String::from_utf8_lossy(&bad_confidence.stderr).contains("Invalid confidence value: nope")
    );

    let missing_run_id = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "early", "--run-id"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!missing_run_id.status.success());
    assert!(String::from_utf8_lossy(&missing_run_id.stderr).contains("--run-id requires a value"));
}

#[test]
fn operator_cli_accepts_project_dir_argument() {
    let project_dir = make_temp_project_dir("project-dir");
    write_manifest(&project_dir);

    let json = run_json_with_cwd(
        std::env::temp_dir(),
        &[
            "board",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ],
    );

    assert_eq!(json["summary"]["pane_count"], 2);
}

#[test]
fn operator_cli_rejects_unknown_and_extra_arguments() {
    let project_dir = make_temp_project_dir("invalid-args");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["board", "--json", "--bogus"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("unknown argument"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "task:TASK-266", "extra", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux explain"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["inbox", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux inbox [--json]"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["digest", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux digest [--json]"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["runs", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux runs [--json]"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["review-reset", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux review-reset"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["review-request", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux review-request"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux restart"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux restart"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["poll-events", "1", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["poll-events", "not-a-number"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["poll-events", "2147483648"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare-runs", "task:a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare-runs"),
        "unexpected stderr: {stderr}"
    );

    for command in ["review-approve", "review-fail"] {
        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([command, "--json"])
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains(&format!("usage: winsmux {command}")),
            "unexpected stderr for {command}: {stderr}"
        );
    }
}

#[test]
fn operator_cli_review_request_records_pending_state_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-request");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "other-branch": {
    "status": "PASS",
    "branch": "other-branch",
    "head_sha": "def456"
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .env("WINSMUX_AGENT_NAME", "codex")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(
            "review request recorded for codex/task266-rust-operator-readmodels-20260424"
        ),
        "unexpected stdout: {stdout}"
    );

    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
            .expect("review state should be JSON");
    assert!(state.get("other-branch").is_some());
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["status"], "PENDING");
    assert_eq!(
        record["branch"],
        "codex/task266-rust-operator-readmodels-20260424"
    );
    assert_eq!(
        record["head_sha"],
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    );
    assert!(record["request"]["id"]
        .as_str()
        .expect("request id should be a string")
        .starts_with("review-"));
    assert_eq!(record["request"]["target_review_pane_id"], "%3");
    assert_eq!(record["request"]["target_review_label"], "reviewer-1");
    assert_eq!(record["request"]["target_review_role"], "Reviewer");
    assert_eq!(record["request"]["target_reviewer_pane_id"], "%3");
    assert_eq!(record["request"]["review_contract"]["version"], 1);
    assert_eq!(
        record["request"]["review_contract"]["required_scope"][0],
        "design_impact"
    );
    assert_eq!(
        record["request"]["review_contract"]["required_scope"][3],
        "pathspec_completeness"
    );
    assert_eq!(
        record["request"]["review_contract"]["pathspec_policy"]["include_definition_hosts"],
        true
    );
    assert!(record["request"]["dispatched_at"].as_str().is_some());
    assert_eq!(record["reviewer"]["agent_name"], "codex");
    assert!(record["updatedAt"].as_str().is_some());

    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest: serde_yaml::Value =
        serde_yaml::from_slice(&fs::read(&manifest_path).expect("manifest should exist"))
            .expect("manifest should be YAML");
    let panes = manifest["panes"]
        .as_mapping()
        .expect("panes should be a map");
    let reviewer = panes
        .get(&serde_yaml::Value::String("reviewer-1".to_string()))
        .expect("reviewer-1 should exist");
    assert_eq!(reviewer["review_state"].as_str(), Some("pending"));
    assert_eq!(reviewer["task_owner"].as_str(), Some("Reviewer"));
    assert_eq!(
        reviewer["branch"].as_str(),
        Some("codex/task266-rust-operator-readmodels-20260424")
    );
    assert_eq!(
        reviewer["head_sha"].as_str(),
        Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    );
    assert_eq!(reviewer["last_event"].as_str(), Some("review.requested"));
}

#[test]
fn operator_cli_dispatch_review_requires_runtime_manifest_regeneration_before_pane_send() {
    let project_dir = make_temp_project_dir("dispatch-review");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}"#,
    );
    let (winsmux_bin, log_path) = write_fake_winsmux_dispatch_review(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_BIN", winsmux_bin)
        .env("WINSMUX_PANE_ID", "%1")
        .env("WINSMUX_ROLE", "Operator")
        .env("WINSMUX_ROLE_MAP", r#"{"%1":"Operator"}"#)
        .env("WINSMUX_SUBMISSION_POLL_ATTEMPTS", "0")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let receipt: serde_json::Value = serde_json::from_str(stdout.trim()).expect("typed receipt");
    assert_eq!(receipt["protocol_version"], 1);
    assert_eq!(receipt["kind"], "review");
    assert_eq!(receipt["status"], "unavailable");
    assert_eq!(receipt["backend"], "local");
    assert_eq!(receipt["target"]["label"], "reviewer-1");
    assert_eq!(receipt["reason_code"], "manifest_regeneration_required");
    assert!(
        receipt["diagnostic"]
            .as_str()
            .is_some_and(|diagnostic| diagnostic.contains("regenerate")),
        "runtime refusal should explain that regeneration is required: {receipt}"
    );
    assert!(!log_path.exists(), "refusal must happen before pane send");
}

#[test]
fn operator_cli_dispatch_review_retains_reviewer_target_in_runtime_regeneration_receipt() {
    let project_dir = make_temp_project_dir("dispatch-review-prefers-reviewer-role");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    fs::write(
        &manifest_path,
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    state: idle
  reviewer-1:
    pane_id: "%3"
    role: Reviewer
    state: idle
"#,
    )
    .expect("test should write manifest with worker before reviewer");
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}"#,
    );
    let (winsmux_bin, log_path) = write_fake_winsmux_dispatch_review(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_BIN", winsmux_bin)
        .env("WINSMUX_PANE_ID", "%1")
        .env("WINSMUX_ROLE", "Operator")
        .env("WINSMUX_ROLE_MAP", r#"{"%1":"Operator"}"#)
        .env("WINSMUX_SUBMISSION_POLL_ATTEMPTS", "0")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let receipt: serde_json::Value = serde_json::from_str(stdout.trim()).expect("typed receipt");
    assert_eq!(receipt["status"], "unavailable");
    assert_eq!(receipt["target"]["label"], "reviewer-1");
    assert_eq!(receipt["reason_code"], "manifest_regeneration_required");
    assert!(
        receipt["diagnostic"]
            .as_str()
            .is_some_and(|diagnostic| diagnostic.contains("regenerate")),
        "runtime refusal should explain that regeneration is required: {receipt}"
    );
    assert!(!log_path.exists(), "refusal must happen before pane send");
}

#[test]
fn operator_cli_dispatch_review_refuses_before_review_state_dispatch_when_runtime_is_stale() {
    let project_dir = make_temp_project_dir("dispatch-review-stale");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}"#,
    );
    let (winsmux_bin, log_path) = write_fake_winsmux_dispatch_review(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_BIN", winsmux_bin)
        .env("WINSMUX_PANE_ID", "%1")
        .env("WINSMUX_ROLE", "Operator")
        .env("WINSMUX_ROLE_MAP", r#"{"%1":"Operator"}"#)
        .env("WINSMUX_SUBMISSION_POLL_ATTEMPTS", "0")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let receipt: serde_json::Value = serde_json::from_str(stdout.trim()).expect("typed refusal");
    assert_eq!(receipt["status"], "unavailable");
    assert_eq!(receipt["target"]["label"], "reviewer-1");
    assert_eq!(receipt["reason_code"], "manifest_regeneration_required");
    assert!(
        receipt["diagnostic"]
            .as_str()
            .is_some_and(|diagnostic| diagnostic.contains("regenerate")),
        "runtime refusal should explain that regeneration is required: {receipt}"
    );
    assert!(!log_path.exists(), "refusal must happen before pane send");
}

#[test]
fn operator_cli_dispatch_review_rejects_non_operator_role() {
    let project_dir = make_temp_project_dir("dispatch-review-role");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("dispatch-review") && stderr.contains("permitted for the current role"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_request_rejects_non_review_capable_pane() {
    let project_dir = make_temp_project_dir("review-request-builder");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("is not registered as a review-capable pane"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_request_rejects_role_gate_mismatch() {
    let project_dir = make_temp_project_dir("review-request-role-mismatch");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("WINSMUX_ROLE mismatch for pane %3: expected Reviewer, got Worker"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_request_accepts_label_derived_reviewer_role() {
    let project_dir = make_temp_project_dir("review-request-label-role");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Reviewer\n", "");
    fs::write(&manifest_path, manifest).expect("test should write manifest");
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
            .expect("review state should be JSON");
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["request"]["target_review_role"], "Reviewer");
}

#[test]
fn operator_cli_review_request_generates_distinct_request_ids() {
    let project_dir = make_temp_project_dir("review-request-distinct-id");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let first = run_review_request_and_read_id(&project_dir);
    let second = run_review_request_and_read_id(&project_dir);

    assert_ne!(first, second);
}

#[test]
fn operator_cli_review_approve_records_pass_state_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-approve");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    run_review_request_and_read_id(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-approve")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .env("WINSMUX_AGENT_NAME", "codex")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("review PASS recorded for codex/task266-rust-operator-readmodels-20260424"),
        "unexpected stdout: {stdout}"
    );

    let state = read_review_state(&project_dir);
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["status"], "PASS");
    assert_eq!(
        record["head_sha"],
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    );
    assert_eq!(record["reviewer"]["pane_id"], "%3");
    assert_eq!(record["reviewer"]["agent_name"], "codex");
    assert!(record["evidence"]["approved_at"].as_str().is_some());
    assert_eq!(record["evidence"]["approved_via"], "winsmux review-approve");
    assert_eq!(
        record["evidence"]["review_contract_snapshot"]["required_scope"][0],
        "design_impact"
    );

    let reviewer = read_manifest_pane(&project_dir, "reviewer-1");
    assert_eq!(reviewer["review_state"].as_str(), Some("pass"));
    assert_eq!(reviewer["task_owner"].as_str(), Some("Operator"));
    assert_eq!(reviewer["last_event"].as_str(), Some("review.pass"));
}

#[test]
fn operator_cli_review_fail_records_fail_state_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-fail");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    run_review_request_and_read_id(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-fail")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .env("WINSMUX_AGENT_NAME", "codex")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("review FAIL recorded for codex/task266-rust-operator-readmodels-20260424"),
        "unexpected stdout: {stdout}"
    );

    let state = read_review_state(&project_dir);
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["status"], "FAIL");
    assert!(record["evidence"]["failed_at"].as_str().is_some());
    assert_eq!(record["evidence"]["failed_via"], "winsmux review-fail");

    let reviewer = read_manifest_pane(&project_dir, "reviewer-1");
    assert_eq!(reviewer["review_state"].as_str(), Some("fail"));
    assert_eq!(reviewer["task_owner"].as_str(), Some("Operator"));
    assert_eq!(reviewer["last_event"].as_str(), Some("review.fail"));
}

#[test]
fn operator_cli_review_result_requires_pending_request() {
    for command in ["review-approve", "review-fail"] {
        let project_dir = make_temp_project_dir(command);
        write_manifest(&project_dir);
        init_git_branch(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
        );
        set_git_head(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .arg(command)
            .env("WINSMUX_PANE_ID", "%3")
            .env("WINSMUX_ROLE", "Reviewer")
            .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("review request pending for codex/task266-rust-operator-readmodels-20260424 was not found"),
            "unexpected stderr for {command}: {stderr}"
        );
    }
}

#[test]
fn operator_cli_review_result_requires_review_contract() {
    let project_dir = make_temp_project_dir("review-result-contract");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "request": {
      "branch": "codex/task266-rust-operator-readmodels-20260424",
      "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "target_review_pane_id": "%3"
    }
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-approve")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("is missing review_contract"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_result_rejects_pane_and_head_mismatch() {
    let cases = [
        (
            "review-result-pane-mismatch",
            r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "request": {
      "branch": "codex/task266-rust-operator-readmodels-20260424",
      "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "target_review_pane_id": "%9",
      "review_contract": {"required_scope":["design_impact"]}
    }
  }
}"#,
            "is assigned to %9, not %3",
        ),
        (
            "review-result-head-mismatch",
            r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "request": {
      "branch": "codex/task266-rust-operator-readmodels-20260424",
      "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "target_review_pane_id": "%3",
      "review_contract": {"required_scope":["design_impact"]}
    }
  }
}"#,
            "pending review request head mismatch",
        ),
    ];

    for (name, state, expected) in cases {
        let project_dir = make_temp_project_dir(name);
        write_manifest(&project_dir);
        init_git_branch(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
        );
        set_git_head(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
        write_review_state(&project_dir, state);

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .arg("review-approve")
            .env("WINSMUX_PANE_ID", "%3")
            .env("WINSMUX_ROLE", "Reviewer")
            .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains(expected),
            "unexpected stderr for {name}: {stderr}"
        );
    }
}

#[test]
fn operator_cli_review_reset_clears_current_branch_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-reset");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PASS",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "abc123"
  },
  "other-branch": {
    "status": "PENDING",
    "branch": "other-branch",
    "head_sha": "def456"
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-reset")
        .env("WINSMUX_PANE_ID", "%3")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("review PASS cleared for codex/task266-rust-operator-readmodels-20260424"),
        "unexpected stdout: {stdout}"
    );

    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should remain"))
            .expect("review state should be JSON");
    assert!(state
        .get("codex/task266-rust-operator-readmodels-20260424")
        .is_none());
    assert!(state.get("other-branch").is_some());

    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest: serde_yaml::Value =
        serde_yaml::from_slice(&fs::read(&manifest_path).expect("manifest should exist"))
            .expect("manifest should be YAML");
    let panes = manifest["panes"]
        .as_mapping()
        .expect("panes should be a map");
    let builder = panes
        .get(&serde_yaml::Value::String("builder-1".to_string()))
        .expect("builder-1 should exist");
    assert_eq!(builder["review_state"].as_str(), Some("pending"));
    assert_eq!(
        builder["branch"].as_str(),
        Some("codex/task266-rust-operator-readmodels-20260424")
    );
    assert_eq!(builder["head_sha"].as_str(), Some("abc123"));
    let reviewer = panes
        .get(&serde_yaml::Value::String("reviewer-1".to_string()))
        .expect("reviewer-1 should exist");
    assert_eq!(reviewer["review_state"].as_str(), Some(""));
    assert_eq!(reviewer["branch"].as_str(), Some(""));
    assert_eq!(reviewer["head_sha"].as_str(), Some(""));
    assert_eq!(reviewer["last_event"].as_str(), Some("review.reset"));
}

#[test]
fn operator_cli_review_reset_removes_empty_review_state_file() {
    let project_dir = make_temp_project_dir("review-reset-empty");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PASS",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "abc123"
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-reset")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("review-state.json")
        .exists());
}

#[test]
fn operator_cli_rebind_worktree_updates_builder_paths() {
    let project_dir = make_temp_project_dir("rebind-worktree");
    write_manifest(&project_dir);
    let new_worktree = project_dir.join(".worktrees").join("builder-9");
    fs::create_dir_all(&new_worktree).expect("test should create new worktree");
    let winsmux_bin =
        write_fake_winsmux_list_panes(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "rebind-worktree",
            "builder-1",
            new_worktree.to_str().expect("temp path should be utf-8"),
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let expected_path = std::fs::canonicalize(&new_worktree)
        .expect("test should canonicalize path")
        .to_string_lossy()
        .to_string();
    let expected_path = strip_windows_extended_path_prefix(&expected_path);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(&format!("rebound %2 (builder-1) to {expected_path}")),
        "unexpected stdout: {stdout}"
    );

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["launch_dir"].as_str(), Some(expected_path.as_str()));
    assert_eq!(
        builder["builder_worktree_path"].as_str(),
        Some(expected_path.as_str())
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("manifest.yaml.lock")
        .exists());
}

#[test]
fn operator_cli_rebind_worktree_rejects_reviewer_and_missing_path() {
    let project_dir = make_temp_project_dir("rebind-worktree-reject");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rebind-worktree", "reviewer-1", "."])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("rebind-worktree is only supported for Builder/Worker panes"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rebind-worktree", "builder-1", "missing-worktree"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("worktree path not found: missing-worktree"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_rebind_worktree_rejects_stale_manifest_target() {
    let project_dir = make_temp_project_dir("rebind-worktree-stale");
    write_manifest(&project_dir);
    let new_worktree = project_dir.join(".worktrees").join("builder-9");
    fs::create_dir_all(&new_worktree).expect("test should create new worktree");
    let winsmux_bin =
        write_fake_winsmux_list_panes(&project_dir, Some("winsmux-orchestra"), &["%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "rebind-worktree",
            "builder-1",
            new_worktree.to_str().expect("temp path should be utf-8"),
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("invalid target: %2"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_rebind_worktree_validates_target_in_manifest_session() {
    let project_dir = make_temp_project_dir("rebind-worktree-session");
    write_manifest(&project_dir);
    let new_worktree = project_dir.join(".worktrees").join("builder-9");
    fs::create_dir_all(&new_worktree).expect("test should create new worktree");
    let winsmux_bin = write_fake_winsmux_list_panes(&project_dir, Some("other-session"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "rebind-worktree",
            "builder-1",
            new_worktree.to_str().expect("temp path should be utf-8"),
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("invalid target: %2"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_restart_dispatches_launch_plan_and_updates_manifest() {
    let project_dir = make_temp_project_dir("restart");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace(
            "    provider_target: codex:gpt-5.4\n",
            "    provider_target: codex:gpt 5.4;unsafe\n",
        );
    fs::write(&manifest_path, manifest).expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("restarted %2 (builder-1)"),
        "unexpected stdout: {stdout}"
    );

    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("respawn-pane -k -t \"%2\" -c"));
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex -c 'model=gpt 5.4;unsafe'"));
    assert!(log.contains("send-keys -t \"%2\" Enter"));
    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(
        builder["provider_target"].as_str(),
        Some("codex:gpt 5.4;unsafe")
    );
    assert_eq!(builder["capability_adapter"].as_str(), Some("codex"));
}

#[test]
fn operator_cli_restart_infers_adapter_when_registry_lacks_provider() {
    let project_dir = make_temp_project_dir("restart-missing-capability-provider");
    write_manifest(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"claude":{"adapter":"claude","command":"claude","prompt_transports":["file"],"supports_file_edit":true,"supports_verification":true}}}"#,
    )
    .expect("test should write provider capability registry");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex -c 'model=gpt-5.4'"));
    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["capability_adapter"].as_str(), Some("codex"));
}

#[test]
fn operator_cli_restart_supports_openai_compatible_pane_worker_slot() {
    let project_dir = make_temp_project_dir("restart-openai-compatible");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
external-operator: true
agent-slots:
  - slot-id: worker-5
    runtime-role: worker
    worker-backend: api_llm
    agent: openrouter
    model: sakana/fugu-ultra
    model-source: operator-override
    reasoning-effort: provider-default
    prompt-transport: file
    auth-mode: api-key-env
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "openrouter": {
      "adapter": "openai-compatible",
      "command": "openrouter",
      "model_sources": ["provider-default", "operator-override", "provider-api"],
      "reasoning_efforts": ["provider-default"],
      "auth_modes": ["api-key-env"],
      "credential_requirements": "OPENROUTER_API_KEY environment variable",
      "execution_backend": "openai-compatible-chat-completions",
      "api_base_url": "https://openrouter.ai/api/v1",
      "api_key_env": "OPENROUTER_API_KEY",
      "prompt_transports": ["file"]
    }
  }
}
"#,
    )
    .expect("test should write provider capability registry");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        format!(
            r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-5:
    pane_id: "%5"
    role: Worker
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%5"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "worker-5"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("restarted %5 (worker-5)"),
        "unexpected stdout: {stdout}"
    );
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("api-llm-pane-worker.ps1"));
    assert!(log.contains("-SlotId worker-5"));
    assert!(log.contains("-Provider openrouter"));
    assert!(log.contains("-Model sakana/fugu-ultra"));
    let worker = read_manifest_pane(&project_dir, "worker-5");
    assert_eq!(
        worker["provider_target"].as_str(),
        Some("openrouter:sakana/fugu-ultra")
    );
    assert_eq!(
        worker["capability_adapter"].as_str(),
        Some("openai-compatible")
    );
}

#[test]
fn operator_cli_restart_rejects_malformed_provider_registry() {
    let project_dir = make_temp_project_dir("restart-malformed-capability-registry");
    write_manifest(&project_dir);
    fs::write(
        project_dir
            .join(".winsmux")
            .join("provider-capabilities.json"),
        "{",
    )
    .expect("test should write malformed provider capability registry");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Invalid provider capability registry JSON"),
        "unexpected stderr: {stderr}"
    );
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !log.contains("send-keys"),
        "restart should not dispatch with a malformed registry: {log}"
    );
}

#[test]
fn operator_cli_restart_rejects_invalid_runtime_overlays_before_dispatch() {
    let cases = [
        (
            "provider-registry",
            "provider-registry.json",
            r#"{"version":1,"slots":{"unselected":{"agent":true}}}"#,
        ),
        (
            "runtime-roles",
            "runtime-role-preferences.json",
            r#"{"version":"1","roles":{}}"#,
        ),
    ];

    for (case_name, file_name, overlay) in cases {
        let project_dir = make_temp_project_dir(&format!("restart-invalid-{case_name}"));
        write_manifest(&project_dir);
        fs::write(project_dir.join(".winsmux").join(file_name), overlay)
            .expect("write invalid runtime overlay");
        let (winsmux_bin, log_path) =
            write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args(["restart", "builder-1"])
            .env("WINSMUX_BIN", winsmux_bin)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success(), "{case_name} must fail closed");
        assert!(output.stdout.is_empty());
        let log = fs::read_to_string(&log_path).unwrap_or_default();
        assert!(
            !log.contains("send-keys"),
            "{case_name} must not dispatch a restart: {log}"
        );
    }
}

#[test]
fn operator_cli_restart_rejects_stale_manifest_target() {
    let project_dir = make_temp_project_dir("restart-stale");
    write_manifest(&project_dir);
    let (winsmux_bin, _log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("invalid target: %2"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_restart_rejects_missing_provider_metadata() {
    let project_dir = make_temp_project_dir("restart-missing-provider-metadata");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        format!(
            r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "worker-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("restart provider metadata missing"),
        "unexpected stderr: {stderr}"
    );
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !log.contains("send-keys"),
        "restart should not dispatch a fallback command: {log}"
    );
    assert!(
        !winsmux_dir.join("provider-registry.json").exists(),
        "failed restart validation must not persist a partial provider override"
    );
}

#[test]
fn operator_cli_provider_switch_restart_rejects_partial_override_without_provider() {
    let project_dir = make_temp_project_dir("provider-switch-restart-missing-provider");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        format!(
            r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let registry_path = winsmux_dir.join("provider-registry.json");
    let registry_before = r#"{"version":1,"slots":{"worker-9":{"agent":"claude","model":"opus","prompt_transport":"file","auth_mode":"claude-pro-max-oauth","reason":"keep existing override","updated_at_utc":"2026-04-26T00:00:00Z"}}}"#;
    fs::write(&registry_path, registry_before).expect("test should write provider registry");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("restart provider metadata missing"),
        "unexpected stderr: {stderr}"
    );
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !log.contains("send-keys"),
        "restart should not dispatch a fallback command: {log}"
    );
    let registry_after =
        fs::read_to_string(&registry_path).expect("test should read provider registry");
    assert_eq!(
        registry_after, registry_before,
        "failed provider-switch restart validation must not mutate the provider registry"
    );
}

fn run_review_request_and_read_id(project_dir: &std::path::Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
            .expect("review state should be JSON");
    state["codex/task266-rust-operator-readmodels-20260424"]["request"]["id"]
        .as_str()
        .expect("request id should be a string")
        .to_string()
}

fn read_review_state(project_dir: &std::path::Path) -> serde_json::Value {
    let state_path = project_dir.join(".winsmux").join("review-state.json");
    serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
        .expect("review state should be JSON")
}

fn read_manifest_pane(project_dir: &std::path::Path, label: &str) -> serde_yaml::Value {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest: serde_yaml::Value =
        serde_yaml::from_slice(&fs::read(&manifest_path).expect("manifest should exist"))
            .expect("manifest should be YAML");
    let panes = manifest["panes"]
        .as_mapping()
        .expect("panes should be a map");
    panes
        .get(serde_yaml::Value::String(label.to_string()))
        .expect("pane should exist")
        .clone()
}

fn strip_windows_extended_path_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{rest}");
    }
    if let Some(rest) = path.strip_prefix(r"\\?\") {
        return rest.to_string();
    }
    path.to_string()
}

fn write_fake_winsmux_dispatch_review(
    project_dir: &std::path::Path,
) -> (std::path::PathBuf, std::path::PathBuf) {
    let fake_dir = project_dir.join(".test-bin");
    fs::create_dir_all(&fake_dir).expect("test should create fake bin dir");
    let log_path = fake_dir.join("winsmux-dispatch-review.log");
    #[cfg(windows)]
    {
        let fake_path = fake_dir.join("winsmux-dispatch-review-fake.cmd");
        let mut body = String::from("@echo off\r\n");
        body.push_str("echo %*>>\"");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("\"\r\n");
        body.push_str("if \"%1\"==\"capture-pane\" (\r\n");
        body.push_str("  type \"");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("\" 2>nul\r\n");
        body.push_str("  exit /b 0\r\n)\r\n");
        body.push_str("if \"%1\"==\"send-keys\" exit /b 0\r\n");
        body.push_str("exit /b 1\r\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        (fake_path, log_path)
    }
    #[cfg(not(windows))]
    {
        let fake_path = fake_dir.join("winsmux-dispatch-review-fake");
        let mut body = String::from("#!/bin/sh\n");
        body.push_str("printf '%s\\n' \"$*\" >> '");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("'\n");
        body.push_str("if [ \"$1\" = \"capture-pane\" ]; then\n");
        body.push_str("  cat '");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("' 2>/dev/null\n");
        body.push_str("  exit 0\n");
        body.push_str("fi\n");
        body.push_str("if [ \"$1\" = \"send-keys\" ]; then\n  exit 0\nfi\n");
        body.push_str("exit 1\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_path)
                .expect("test should read fake winsmux metadata")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&fake_path, permissions)
                .expect("test should make fake winsmux executable");
        }
        (fake_path, log_path)
    }
}

fn write_fake_winsmux_list_panes(
    project_dir: &std::path::Path,
    expected_session: Option<&str>,
    pane_ids: &[&str],
) -> std::path::PathBuf {
    let fake_dir = project_dir.join(".test-bin");
    fs::create_dir_all(&fake_dir).expect("test should create fake bin dir");
    #[cfg(windows)]
    {
        let fake_path = fake_dir.join("winsmux-fake.cmd");
        let mut body = String::from("@echo off\r\n");
        if let Some(session) = expected_session {
            body.push_str("if not \"%1\"==\"-t\" exit /b 0\r\n");
            body.push_str("if not \"%2\"==\"");
            body.push_str(session);
            body.push_str("\" exit /b 0\r\n");
        }
        body.push_str("if \"%3\"==\"list-panes\" (\r\n");
        for pane_id in pane_ids {
            body.push_str("  echo ");
            body.push_str(&pane_id.replace('%', "%%"));
            body.push_str("\r\n");
        }
        body.push_str("  exit /b 0\r\n)\r\nexit /b 1\r\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        fake_path
    }
    #[cfg(not(windows))]
    {
        let fake_path = fake_dir.join("winsmux-fake");
        let mut body = String::from("#!/bin/sh\n");
        if let Some(session) = expected_session {
            body.push_str("if [ \"$1\" != \"-t\" ] || [ \"$2\" != '");
            body.push_str(session);
            body.push_str("' ]; then\n  exit 0\nfi\n");
        }
        body.push_str("if [ \"$3\" = \"list-panes\" ]; then\n");
        for pane_id in pane_ids {
            body.push_str("  printf '%s\\n' '");
            body.push_str(pane_id);
            body.push_str("'\n");
        }
        body.push_str("  exit 0\nfi\nexit 1\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_path)
                .expect("test should read fake winsmux metadata")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&fake_path, permissions)
                .expect("test should make fake winsmux executable");
        }
        fake_path
    }
}

fn write_fake_winsmux_restart(
    project_dir: &std::path::Path,
    expected_session: Option<&str>,
    pane_ids: &[&str],
) -> (std::path::PathBuf, std::path::PathBuf) {
    let fake_dir = project_dir.join(".test-bin");
    fs::create_dir_all(&fake_dir).expect("test should create fake bin dir");
    let log_path = fake_dir.join("winsmux-restart.log");
    #[cfg(windows)]
    {
        let fake_path = fake_dir.join("winsmux-restart-fake.cmd");
        let mut body = String::from("@echo off\r\n");
        body.push_str("echo %*>>\"");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("\"\r\n");
        if let Some(session) = expected_session {
            body.push_str("if \"%1\"==\"-t\" if not \"%2\"==\"");
            body.push_str(session);
            body.push_str("\" exit /b 0\r\n");
        }
        body.push_str("if \"%3\"==\"list-panes\" (\r\n");
        for pane_id in pane_ids {
            body.push_str("  echo ");
            body.push_str(&pane_id.replace('%', "%%"));
            body.push_str("\r\n");
        }
        body.push_str("  exit /b 0\r\n)\r\n");
        body.push_str("if \"%1\"==\"capture-pane\" (\r\n  echo PS C:\\repo^>\r\n  echo ^>\r\n  echo Welcome to Claude Code!\r\n  echo api_llm[worker-5]^>\r\n  exit /b 0\r\n)\r\n");
        body.push_str("exit /b 0\r\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        (fake_path, log_path)
    }
    #[cfg(not(windows))]
    {
        let fake_path = fake_dir.join("winsmux-restart-fake");
        let mut body = String::from("#!/bin/sh\n");
        body.push_str("printf '%s\\n' \"$*\" >> '");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("'\n");
        if let Some(session) = expected_session {
            body.push_str("if [ \"$1\" = \"-t\" ] && [ \"$2\" != '");
            body.push_str(session);
            body.push_str("' ]; then\n  exit 0\nfi\n");
        }
        body.push_str("if [ \"$3\" = \"list-panes\" ]; then\n");
        for pane_id in pane_ids {
            body.push_str("  printf '%s\\n' '");
            body.push_str(pane_id);
            body.push_str("'\n");
        }
        body.push_str("  exit 0\nfi\n");
        body.push_str("if [ \"$1\" = \"capture-pane\" ]; then\n  printf '%s\\n' 'PS /repo>' '>' 'Welcome to Claude Code!' 'api_llm[worker-5]>'\n  exit 0\nfi\n");
        body.push_str("exit 0\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_path)
                .expect("test should read fake winsmux metadata")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&fake_path, permissions)
                .expect("test should make fake winsmux executable");
        }
        (fake_path, log_path)
    }
}

fn run_json(project_dir: &std::path::Path, args: &[&str]) -> serde_json::Value {
    run_json_with_cwd(project_dir, args)
}

fn read_json_file(path: &std::path::Path) -> serde_json::Value {
    let raw = fs::read_to_string(path).expect("test should read JSON file");
    serde_json::from_str(&raw).expect("test file should contain JSON")
}

fn write_provider_switch_fixture(project_dir: &std::path::Path) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
agent: codex
model: gpt-5.4
model-source: cli-discovery
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    model-source: cli-discovery
    prompt-transport: argv
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default", "reasoning_efforts": ["provider-default"]},
        {"id": "gpt-5.3-codex-spark", "label": "GPT-5.3-Codex-Spark", "source": "cli-discovery", "availability": "local-account", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.4", "label": "GPT-5.4", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-terra", "label": "GPT-5.6 Terra", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-luna", "label": "GPT-5.6 Luna", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]}
      ],
      "model_sources": ["provider-default", "cli-discovery"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh"],
      "local_access_note": "Local Codex CLI catalog and ChatGPT account access.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Codex CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default", "reasoning_efforts": ["provider-default"]},
        {"id": "sonnet", "label": "Sonnet", "source": "official-doc", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "opus", "label": "Opus", "source": "official-doc", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "opusplan", "label": "Opus Plan", "source": "official-doc", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]}
      ],
      "model_sources": ["provider-default", "official-doc", "operator-override"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh", "max"],
      "local_access_note": "Local Claude Code account and settings.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Claude Code CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": true,
      "supports_consultation": true
    },
    "gemini": {
      "adapter": "gemini",
      "command": "gemini",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
        {"id": "operator-override", "label": "Operator override", "source": "operator-override"}
      ],
      "model_sources": ["provider-default", "operator-override"],
      "reasoning_efforts": ["provider-default"],
      "local_access_note": "Local Gemini CLI account and settings.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Gemini CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["argv", "file"],
      "auth_modes": ["gemini-local"],
      "local_interactive_oauth_modes": ["gemini-local"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": true,
      "supports_consultation": true
    }
  }
}"#,
    )
    .expect("test should write provider capabilities");
}

fn run_json_with_cwd(cwd: impl AsRef<std::path::Path>, args: &[&str]) -> serde_json::Value {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(args)
        .current_dir(cwd)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("stdout should be JSON")
}

fn init_conflict_preflight_repo(project_dir: &std::path::Path) {
    run_git(project_dir, &["init"]);
    run_git(
        project_dir,
        &["config", "user.email", "winsmux-test@example.com"],
    );
    run_git(project_dir, &["config", "user.name", "winsmux test"]);
    write_git_file(project_dir, "base.txt", "base\n");
    run_git(project_dir, &["add", "base.txt"]);
    run_git(project_dir, &["commit", "-m", "base"]);
    run_git(project_dir, &["branch", "base"]);
}

fn write_git_file(project_dir: &std::path::Path, name: &str, text: &str) {
    fs::write(project_dir.join(name), text).expect("test should write git file");
}

fn run_git(project_dir: &std::path::Path, args: &[&str]) {
    let output = Command::new("git")
        .args(args)
        .current_dir(project_dir)
        .output()
        .expect("git should run");
    assert!(
        output.status.success(),
        "git {:?} failed\nstdout:\n{}\nstderr:\n{}",
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write_compare_runs_fixture(project_dir: &std::path::Path) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    task_id: task-a
    task: Compare run A
    task_state: completed
    review_state: PASS
    branch: branch-a
    head_sha: aaaabbbbccccdddd
    provider_target: codex:gpt-5.4
    changed_file_count: 1
    changed_files: '["core/src/operator_cli.rs"]'
    last_event: pane.consult_result
    last_event_at: 2026-04-24T12:00:00+09:00
  builder-2:
    pane_id: "%3"
    role: Worker
    task_id: task-b
    task: Compare run B
    task_state: completed
    review_state: PASS
    branch: branch-b
    head_sha: eeeeffff11112222
    provider_target: claude:opus
    changed_file_count: 2
    changed_files: '["core/src/operator_cli.rs","core/src/main.rs"]'
    last_event: pane.consult_result
    last_event_at: 2026-04-24T12:01:00+09:00
"#,
    )
    .expect("test should write manifest");
    fs::write(
        winsmux_dir.join("events.jsonl"),
r#"{"timestamp":"2026-04-24T12:00:00+09:00","session":"winsmux-orchestra","event":"pane.consult_result","message":"consultation completed","label":"builder-1","pane_id":"%2","role":"Builder","branch":"branch-a","head_sha":"aaaabbbbccccdddd","data":{"task_id":"task-a","run_id":"task:task-a","slot":"builder-1","hypothesis":"cache command is stable","result":"cache hit","confidence":0.85,"next_action":"promote tactic","observation_pack_ref":".winsmux/observation-packs/task-a.json","consultation_ref":".winsmux/consultations/task-a.json","worktree":".worktrees/a","env_fingerprint":"env-a","command_hash":"cmd-a"}}
{"timestamp":"2026-04-24T12:00:05+09:00","session":"winsmux-orchestra","event":"operator.mailbox.message_received","message":"team memory captured","source":"mailbox","data":{"task_id":"task-a","run_id":"task:task-a","source":"mailbox","team_memory_refs":["team-memory:task-a:operator-standard"]}}
{"timestamp":"2026-04-24T12:00:10+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"verification passed","label":"builder-1","pane_id":"%2","role":"Builder","branch":"branch-a","head_sha":"aaaabbbbccccdddd","data":{"task_id":"task-a","run_id":"task:task-a","verification_result":{"outcome":"PASS","summary":"cache hit confirmed"}}}
{"timestamp":"2026-04-24T12:00:20+09:00","session":"winsmux-orchestra","event":"pipeline.security.allowed","message":"security allowed","label":"builder-1","pane_id":"%2","role":"Builder","branch":"branch-a","head_sha":"aaaabbbbccccdddd","data":{"task_id":"task-a","run_id":"task:task-a","verdict":"ALLOW","reason":"verified safe"}}
{"timestamp":"2026-04-24T12:01:00+09:00","session":"winsmux-orchestra","event":"pane.consult_result","message":"consultation completed","label":"builder-2","pane_id":"%3","role":"Worker","branch":"branch-b","head_sha":"eeeeffff11112222","data":{"task_id":"task-b","run_id":"task:task-b","slot":"builder-2","hypothesis":"rebuild command is stable","result":"rebuild clean","confidence":0.6,"next_action":"promote tactic","observation_pack_ref":".winsmux/observation-packs/task-b.json","consultation_ref":".winsmux/consultations/task-b.json","worktree":".worktrees/b","env_fingerprint":"env-b","command_hash":"cmd-b"}}
{"timestamp":"2026-04-24T12:01:10+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"verification passed","label":"builder-2","pane_id":"%3","role":"Worker","branch":"branch-b","head_sha":"eeeeffff11112222","data":{"task_id":"task-b","run_id":"task:task-b","verification_result":{"outcome":"PASS","summary":"rebuild confirmed"}}}
{"timestamp":"2026-04-24T12:01:20+09:00","session":"winsmux-orchestra","event":"pipeline.security.allowed","message":"security allowed","label":"builder-2","pane_id":"%3","role":"Worker","branch":"branch-b","head_sha":"eeeeffff11112222","data":{"task_id":"task-b","run_id":"task:task-b","verdict":"ALLOW","reason":"verified safe"}}
"#,
    )
    .expect("test should write events");
    fs::create_dir_all(winsmux_dir.join("observation-packs"))
        .expect("test should create observation pack directory");
    fs::create_dir_all(winsmux_dir.join("consultations"))
        .expect("test should create consultation directory");
    fs::write(
        winsmux_dir.join("observation-packs").join("task-a.json"),
        r#"{"packet_type":"observation_pack","run_id":"task:task-a","summary":"captured cache command"}"#,
    )
    .expect("test should write observation pack");
    fs::write(
        winsmux_dir.join("consultations").join("task-a.json"),
        r#"{"packet_type":"consultation_packet","run_id":"task:task-a","recommendation":"prefer cache command"}"#,
    )
    .expect("test should write consultation packet");
    fs::write(
        winsmux_dir.join("observation-packs").join("task-b.json"),
        r#"{"packet_type":"observation_pack","run_id":"task:task-b","summary":"captured rebuild command"}"#,
    )
    .expect("test should write observation pack");
    fs::write(
        winsmux_dir.join("consultations").join("task-b.json"),
        r#"{"packet_type":"consultation_packet","run_id":"task:task-b","recommendation":"prefer rebuild command"}"#,
    )
    .expect("test should write consultation packet");
}

fn write_manifest(project_dir: &std::path::Path) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: running
    task_id: TASK-266
    task: Add Rust operator read models
    task_state: in_progress
    parent_run_id: operator:session-1
    goal: Keep Rust read models aligned
    task_type: implementation
    priority: P0
    blocking: true
    review_state: pending
    branch: codex/task266-rust-operator-readmodels-20260424
    head_sha: abc123
    changed_file_count: 2
    changed_files: '["core/src/main.rs","core/src/operator_cli.rs"]'
    write_scope: '["core/src/operator_cli.rs"]'
    read_scope: '["scripts/winsmux-core.ps1"]'
    constraints: '["preserve PowerShell JSON shape"]'
    expected_output: Rust read-only CLI
    verification_plan: '["cargo test --manifest-path core/Cargo.toml --test operator_cli"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-24T12:00:00+09:00
  reviewer-1:
    pane_id: "%3"
    role: Reviewer
    state: idle
    task_state: waiting
    review_state: PASS
    branch: codex/task266-rust-operator-readmodels-20260424
    head_sha: def456
"#,
    )
    .expect("test should write manifest");
    fs::create_dir_all(winsmux_dir.join("observation-packs"))
        .expect("test should create observation pack directory");
    fs::create_dir_all(winsmux_dir.join("consultations"))
        .expect("test should create consultation directory");
    fs::write(
        winsmux_dir.join("observation-packs").join("task-266.json"),
        r#"{"packet_type":"observation_pack","run_id":"task:TASK-266","summary":"captured operator read model"}"#,
    )
    .expect("test should write observation pack");
    fs::write(
        winsmux_dir.join("consultations").join("task-266.json"),
        r#"{"packet_type":"consultation_packet","run_id":"task:TASK-266","recommendation":"keep read-only"}"#,
    )
    .expect("test should write consultation packet");
    fs::write(
        winsmux_dir.join("events.jsonl"),
        r#"{"timestamp":"2026-04-24T12:00:01+09:00","session":"winsmux-orchestra","event":"operator.review_requested","message":"review requested","label":"builder-1","pane_id":"%2","role":"Builder","status":"review_requested","data":{"task_id":"TASK-266","run_id":"task:TASK-266","hypothesis":"Rust can read operator evidence","test_plan":["read manifest"],"result":"captured","confidence":0.91,"next_action":"commit_ready","observation_pack_ref":".winsmux/observation-packs/task-266.json","consultation_ref":".winsmux/consultations/task-266.json"}}
{"timestamp":"2026-04-24T12:00:02+09:00","session":"winsmux-orchestra","event":"operator.commit_ready","message":"ready to commit","label":"builder-1","pane_id":"%2","role":"Builder","status":"commit_ready","data":{"task_id":"TASK-266"}}
"#,
    )
    .expect("test should write events");
}

fn write_review_state(project_dir: &std::path::Path, content: &str) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(winsmux_dir.join("review-state.json"), content)
        .expect("test should write review state");
}

fn init_git_branch(project_dir: &std::path::Path, branch: &str) {
    let init = Command::new("git")
        .args(["init", "-b", branch])
        .current_dir(project_dir)
        .output()
        .expect("git init should run");
    assert!(
        init.status.success(),
        "git init failed: {}",
        String::from_utf8_lossy(&init.stderr)
    );
}

fn set_git_head(project_dir: &std::path::Path, branch: &str, head_sha: &str) {
    let ref_path = project_dir
        .join(".git")
        .join("refs")
        .join("heads")
        .join(branch.replace('/', std::path::MAIN_SEPARATOR_STR));
    fs::create_dir_all(ref_path.parent().expect("ref should have a parent"))
        .expect("test should create git ref directory");
    fs::write(ref_path, format!("{head_sha}\n")).expect("test should write git ref");
}

fn make_temp_project_dir(name: &str) -> std::path::PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("winsmux-{name}-{}-{suffix}", std::process::id()));
    fs::create_dir_all(&path).expect("test should create temp project directory");
    path
}
