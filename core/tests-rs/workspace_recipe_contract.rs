#[path = "../src/workspace_recipe.rs"]
mod workspace_recipe;

use std::fs;
use std::process::Command;

use workspace_recipe::{normalize_workspace_plan, SlotCapabilities};

const VALID_RECIPE: &str = include_str!("../../tests/fixtures/workspace-recipes/valid-v1.yaml");
const EXPECTED_PLAN: &str =
    include_str!("../../tests/fixtures/workspace-recipes/valid-v1.normalized.json");
const VALID_PROVIDER_CAPABILITIES: &str =
    include_str!("../../tests/fixtures/workspace-recipes/valid-v1.provider-capabilities.json");

fn slots() -> Vec<SlotCapabilities> {
    vec![
        SlotCapabilities {
            slot_id: "worker-1".to_string(),
            supports_file_edit: true,
            supports_verification: false,
            supports_structured_result: false,
        },
        SlotCapabilities {
            slot_id: "reviewer-1".to_string(),
            supports_file_edit: false,
            supports_verification: true,
            supports_structured_result: true,
        },
    ]
}

#[test]
fn valid_recipe_matches_the_shared_golden_plan_deterministically() {
    let first = normalize_workspace_plan(
        VALID_RECIPE,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect("valid workspace recipe should normalize");
    let second = normalize_workspace_plan(
        VALID_RECIPE,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect("same workspace recipe should normalize twice");
    let first_json = serde_json::to_string(&first).expect("serialize first plan");
    let second_json = serde_json::to_string(&second).expect("serialize second plan");

    assert_eq!(first_json, second_json);
    assert_eq!(first_json, EXPECTED_PLAN.trim());
    assert_eq!(first.panes[0].region, "main");
    assert_eq!(first.panes[1].region, "side");
    assert_eq!(
        first.panes[0].worktree.name.as_deref(),
        Some("issue-1204-implement")
    );
    assert_eq!(first.resolved_bindings["implement"], "worker-1");
    assert_eq!(first.resolved_bindings["verify"], "reviewer-1");
    assert_eq!(first.panes[1].required_capabilities, ["review"]);
}

#[test]
fn standard_yaml_collection_forms_share_one_rust_normalized_contract() {
    let collection_comments = VALID_RECIPE
        .replace("    panes:", "    panes: # pane collection")
        .replace(
            "    startup-actions:",
            "    startup-actions: # action collection",
        );
    let bare_sequence_entry = VALID_RECIPE.replace(
        "      - pane-key: implement",
        "      -\n        pane-key: implement",
    );
    let flow_mapping = VALID_RECIPE.replace(
        "        worktree:\n          mode: read-only-reference",
        "        worktree: { mode: read-only-reference }",
    );
    let arbitrary_indentation = VALID_RECIPE
        .lines()
        .map(|line| {
            let indentation = line.len() - line.trim_start().len();
            let replacement = match indentation {
                2 => 1,
                4 => 3,
                6 => 4,
                8 => 6,
                10 => 8,
                _ => indentation,
            };
            format!("{}{}", " ".repeat(replacement), line.trim_start())
        })
        .collect::<Vec<_>>()
        .join("\n");

    for yaml in [
        collection_comments,
        bare_sequence_entry,
        flow_mapping,
        arbitrary_indentation,
    ] {
        let plan = normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
            .expect("standard YAML spelling should normalize through serde_yaml");
        assert_eq!(
            serde_json::to_string(&plan).expect("serialize normalized plan"),
            EXPECTED_PLAN.trim()
        );
    }
}

#[test]
fn recipe_schema_version_requires_an_integer_scalar() {
    let quoted = VALID_RECIPE.replace("    schema-version: 1", "    schema-version: '1'");
    let error = normalize_workspace_plan(&quoted, "bugfix-two-slot", Some("issue-1204"), &slots())
        .expect_err("quoted schema-version must not satisfy the integer contract");
    assert_eq!(error.to_string(), "invalid workspace recipe schema.");
}

#[test]
fn document_config_version_accepts_only_the_supported_v1_spellings() {
    let without_version = VALID_RECIPE
        .strip_prefix("config-version: 1\r\n")
        .or_else(|| VALID_RECIPE.strip_prefix("config-version: 1\n"))
        .expect("fixture starts with config-version");
    normalize_workspace_plan(
        without_version,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect("missing config-version defaults to v1");

    for yaml in [
        VALID_RECIPE.to_string(),
        VALID_RECIPE.replacen("config-version: 1", "config-version: '1'", 1),
        VALID_RECIPE.replacen("config-version: 1", "config-version: \" 1 \"", 1),
        VALID_RECIPE.replacen("config-version: 1", "config_version: 1", 1),
        VALID_RECIPE.replacen("config-version: 1", "config_version: '1'", 1),
    ] {
        normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
            .expect("supported document config-version spelling should normalize");
    }
}

#[test]
fn document_config_version_rejects_unsupported_invalid_and_ambiguous_values() {
    for value in [
        "0",
        "2",
        "-1",
        "1.0",
        "not-a-number",
        "true",
        "null",
        "[]",
        "{}",
    ] {
        let yaml =
            VALID_RECIPE.replacen("config-version: 1", &format!("config-version: {value}"), 1);
        let error =
            normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
                .expect_err("unsupported or invalid config-version must be rejected");
        assert_eq!(error.to_string(), "invalid document config-version.");
    }

    let ambiguous = VALID_RECIPE.replacen(
        "config-version: 1",
        "config-version: 1\nconfig_version: 1",
        1,
    );
    let error =
        normalize_workspace_plan(&ambiguous, "bugfix-two-slot", Some("issue-1204"), &slots())
            .expect_err("both document config-version aliases must be rejected");
    assert_eq!(error.to_string(), "ambiguous document config-version.");

    let unsupported_legacy = VALID_RECIPE.replacen("config-version: 1", "config_version: 2", 1);
    let error = normalize_workspace_plan(
        &unsupported_legacy,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect_err("unsupported legacy config-version alias must be rejected");
    assert_eq!(error.to_string(), "invalid document config-version.");
}

#[test]
fn multiple_panes_may_share_one_placement_region() {
    let same_region = VALID_RECIPE.replace("region: side", "region: main");
    let plan = normalize_workspace_plan(
        &same_region,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect("regions are placement classes, not unique IDs");
    assert_eq!(plan.panes[0].region, "main");
    assert_eq!(plan.panes[1].region, "main");
}

#[test]
fn selector_rejects_zero_and_multiple_matches() {
    let zero = normalize_workspace_plan(
        VALID_RECIPE,
        "bugfix-two-slot",
        Some("task-658"),
        &slots()[..1],
    )
    .expect_err("review selector must reject zero matches");
    assert!(zero.to_string().contains("matched 0 slots"));

    let mut ambiguous = slots();
    ambiguous.push(SlotCapabilities {
        slot_id: "worker-3".to_string(),
        supports_file_edit: false,
        supports_verification: true,
        supports_structured_result: true,
    });
    let multiple = normalize_workspace_plan(
        VALID_RECIPE,
        "bugfix-two-slot",
        Some("task-658"),
        &ambiguous,
    )
    .expect_err("review selector must reject multiple matches");
    assert!(multiple.to_string().contains("matched 2 slots"));
}

#[test]
fn review_requires_verification_and_structured_result() {
    let mut incomplete = slots();
    incomplete[1].supports_structured_result = false;
    let error = normalize_workspace_plan(
        VALID_RECIPE,
        "bugfix-two-slot",
        Some("task-658"),
        &incomplete,
    )
    .expect_err("review must require a structured result");
    assert!(error.to_string().contains("matched 0 slots"));
}

#[test]
fn closed_fields_actions_and_safe_worktree_names_fail_before_output() {
    let unknown_field = VALID_RECIPE.replace(
        "        pane-ref: implement",
        "        pane-ref: implement\n        command: whoami",
    );
    let error = normalize_workspace_plan(
        &unknown_field,
        "bugfix-two-slot",
        Some("task-658"),
        &slots(),
    )
    .expect_err("freeform action fields must be rejected");
    assert_eq!(error.to_string(), "invalid workspace recipe schema.");

    let unknown_action = VALID_RECIPE.replace("kind: ensure-slot-ready", "kind: run-shell");
    let error = normalize_workspace_plan(
        &unknown_action,
        "bugfix-two-slot",
        Some("task-658"),
        &slots(),
    )
    .expect_err("unknown action kind must be rejected");
    assert!(error.to_string().contains("unknown startup action kind"));

    let escaped_name = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        "name-template: \"../private\"",
    );
    let error =
        normalize_workspace_plan(&escaped_name, "bugfix-two-slot", Some("task-658"), &slots())
            .expect_err("path-like worktree names must be rejected");
    assert!(error.to_string().contains("safe project-local name"));
}

#[test]
fn startup_action_kind_must_be_compatible_with_the_target_pane() {
    let invalid_target = VALID_RECIPE.replace("pane-ref: implement", "pane-ref: verify");
    let error = normalize_workspace_plan(
        &invalid_target,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect_err("managed-worktree action must reject a read-only target");
    assert_eq!(
        error.to_string(),
        "ensure-managed-worktree requires a managed target pane."
    );

    let crlf_recipe = VALID_RECIPE.replace("\r\n", "\n").replace('\n', "\r\n");
    let slot_ready_on_managed = crlf_recipe.replacen("pane-ref: verify", "pane-ref: implement", 1);
    let plan = normalize_workspace_plan(
        &slot_ready_on_managed,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect("ensure-slot-ready may target a managed pane");
    assert_eq!(plan.startup_actions[1].pane_ref, "implement");
}

#[test]
fn workflow_token_requires_explicit_workflow_id() {
    let error = normalize_workspace_plan(VALID_RECIPE, "bugfix-two-slot", None, &slots())
        .expect_err("workflow token must not use recipe id implicitly");
    assert!(error.to_string().contains("--workflow-id was not provided"));
}

#[test]
fn identifiers_and_worktree_names_use_the_strict_v1_grammar() {
    let uppercase =
        normalize_workspace_plan(VALID_RECIPE, "Bugfix-two-slot", Some("task-658"), &slots())
            .expect_err("uppercase recipe IDs must be rejected");
    assert!(uppercase.to_string().contains("stable ASCII identifier"));

    let repeated_dot = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        "name-template: \"safe..private\"",
    );
    let error =
        normalize_workspace_plan(&repeated_dot, "bugfix-two-slot", Some("task-658"), &slots())
            .expect_err("worktree names containing dot-dot must be rejected");
    assert!(error.to_string().contains("safe project-local name"));
}

#[test]
fn managed_worktree_names_reject_windows_devices_and_trailing_dots() {
    for reserved in [
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
        "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", "con.txt",
        "com1.log", "lpt9.tmp",
    ] {
        let yaml = VALID_RECIPE.replace(
            "name-template: \"{{workflow-id}}-implement\"",
            &format!("name-template: \"{reserved}\""),
        );
        let error =
            normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
                .expect_err("Windows reserved device basename must be rejected");
        assert!(error.to_string().contains("safe project-local name"));
    }

    let trailing_dot = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        "name-template: \"safe-name.\"",
    );
    normalize_workspace_plan(
        &trailing_dot,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect_err("trailing dots must be rejected");
}

#[test]
fn managed_worktree_names_keep_safe_dotted_hyphenated_and_underscored_boundaries() {
    for safe in [
        "conway.txt",
        "prn-file",
        "aux_data",
        "nul-safe",
        "com0.log",
        "com10.log",
        "lpt0.tmp",
        "lpt10.tmp",
        "safe.name-v1_2",
    ] {
        let yaml = VALID_RECIPE.replace(
            "name-template: \"{{workflow-id}}-implement\"",
            &format!("name-template: \"{safe}\""),
        );
        let plan = normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
            .expect("near-boundary safe worktree name should normalize");
        assert_eq!(plan.panes[0].worktree.name.as_deref(), Some(safe));
    }
}

#[test]
fn managed_worktree_names_reject_windows_component_overflow_before_plan_output() {
    let max_component = "a".repeat(255);
    let at_limit = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        &format!("name-template: \"{max_component}\""),
    );
    let plan = normalize_workspace_plan(&at_limit, "bugfix-two-slot", Some("issue-1204"), &slots())
        .expect("a 255-byte ASCII component must remain valid");
    assert_eq!(
        plan.panes[0].worktree.name.as_deref(),
        Some(max_component.as_str())
    );

    let overlong_component = "a".repeat(256);
    let overlong_template = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        &format!("name-template: \"{overlong_component}\""),
    );
    let error = normalize_workspace_plan(
        &overlong_template,
        "bugfix-two-slot",
        Some("issue-1204"),
        &slots(),
    )
    .expect_err("a 256-byte template must be rejected before plan output");
    assert!(error.to_string().contains("safe project-local name"));

    let workflow_id = format!("a{}", "b".repeat(19));
    let expansion_at_limit = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        &format!("name-template: \"{{{{workflow-id}}}}-{}\"", "c".repeat(234)),
    );
    let plan = normalize_workspace_plan(
        &expansion_at_limit,
        "bugfix-two-slot",
        Some(&workflow_id),
        &slots(),
    )
    .expect("a template resolving to a 255-byte component must remain valid");
    assert_eq!(
        plan.panes[0].worktree.name.as_deref().map(str::len),
        Some(255)
    );

    let expansion_over_limit = VALID_RECIPE.replace(
        "name-template: \"{{workflow-id}}-implement\"",
        &format!("name-template: \"{{{{workflow-id}}}}-{}\"", "c".repeat(235)),
    );
    let error = normalize_workspace_plan(
        &expansion_over_limit,
        "bugfix-two-slot",
        Some(&workflow_id),
        &slots(),
    )
    .expect_err("a template resolving to a 256-byte component must be rejected before plan output");
    assert!(error.to_string().contains("safe project-local name"));
}

#[test]
fn new_lane_a_namespace_requires_canonical_kebab_case() {
    let snake_case = VALID_RECIPE.replace("workspace-recipes:", "workspace_recipes:");
    let error =
        normalize_workspace_plan(&snake_case, "bugfix-two-slot", Some("issue-1204"), &slots())
            .expect_err("the new namespace must not create a snake_case load alias");
    assert_eq!(error.to_string(), "workspace-recipes is not configured.");
}

#[test]
fn namespace_recipe_key_and_fields_require_canonical_case() {
    let cases = [
        VALID_RECIPE.replace("workspace-recipes:", "Workspace-Recipes:"),
        VALID_RECIPE.replace("bugfix-two-slot:", "Bugfix-two-slot:"),
        VALID_RECIPE.replace("workflow-role: implementer", "Workflow-Role: implementer"),
    ];

    for yaml in cases {
        normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
            .expect_err("non-canonical key case must be rejected");
    }
}

#[test]
fn credential_shaped_output_identities_are_rejected_without_disclosure() {
    let credential = format!("sk-proj-{}", "a".repeat(32));
    let cases = [
        VALID_RECIPE.replace(
            "workflow-role: implementer",
            &format!("workflow-role: {credential}"),
        ),
        VALID_RECIPE.replace(
            "action-id: prepare-implement-worktree",
            &format!("action-id: {credential}"),
        ),
        VALID_RECIPE.replace(
            "name-template: \"{{workflow-id}}-implement\"",
            &format!("name-template: \"{credential}\""),
        ),
    ];

    for yaml in cases {
        let error =
            normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
                .expect_err("credential-shaped output values must be rejected");
        assert!(!error.to_string().contains(&credential));
    }

    let near_boundary = format!("sk-{}", "a".repeat(19));
    let yaml = VALID_RECIPE.replace(
        "workflow-role: implementer",
        &format!("workflow-role: {near_boundary}"),
    );
    let plan = normalize_workspace_plan(&yaml, "bugfix-two-slot", Some("issue-1204"), &slots())
        .expect("values below the finite credential boundary must remain valid");
    assert_eq!(plan.panes[0].workflow_role, near_boundary);
}

#[test]
fn untrusted_values_are_not_reflected_in_errors() {
    let synthetic_secret = "synthetic-private-value";
    let unknown_capability = VALID_RECIPE.replace("file-edit]", &format!("{synthetic_secret}]"));
    let error = normalize_workspace_plan(
        &unknown_capability,
        "bugfix-two-slot",
        Some("task-658"),
        &slots(),
    )
    .expect_err("unknown capabilities must be rejected");
    assert_eq!(error.to_string(), "unknown workspace capability.");
    assert!(!error.to_string().contains(synthetic_secret));

    let unknown_action = VALID_RECIPE.replace("ensure-slot-ready", synthetic_secret);
    let error = normalize_workspace_plan(
        &unknown_action,
        "bugfix-two-slot",
        Some("task-658"),
        &slots(),
    )
    .expect_err("unknown actions must be rejected");
    assert_eq!(error.to_string(), "unknown startup action kind.");
    assert!(!error.to_string().contains(synthetic_secret));
}

#[test]
fn cli_emits_json_without_creating_runtime_state() {
    let project = tempfile::tempdir().expect("create project fixture");
    let runtime_dir = project.path().join(".winsmux");
    fs::create_dir(&runtime_dir).expect("create capability fixture directory");
    fs::write(project.path().join(".winsmux.yaml"), VALID_RECIPE).expect("write settings fixture");
    fs::write(
        runtime_dir.join("provider-capabilities.json"),
        VALID_PROVIDER_CAPABILITIES,
    )
    .expect("write capability fixture");
    let before_root = sorted_entry_names(project.path());
    let before_runtime = sorted_entry_names(&runtime_dir);
    let before_settings = fs::read(project.path().join(".winsmux.yaml")).unwrap();
    let before_capabilities = fs::read(runtime_dir.join("provider-capabilities.json")).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-plan",
            "--recipe-id",
            "bugfix-two-slot",
            "--workflow-id",
            "issue-1204",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run workspace-plan");

    assert!(
        output.status.success(),
        "workspace-plan stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let actual = String::from_utf8(output.stdout).expect("workspace-plan output should be UTF-8");
    assert_eq!(actual.trim(), EXPECTED_PLAN.trim());
    assert_eq!(sorted_entry_names(project.path()), before_root);
    assert_eq!(sorted_entry_names(&runtime_dir), before_runtime);
    assert_eq!(
        fs::read(project.path().join(".winsmux.yaml")).unwrap(),
        before_settings
    );
    assert_eq!(
        fs::read(runtime_dir.join("provider-capabilities.json")).unwrap(),
        before_capabilities
    );
}

fn sorted_entry_names(path: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(path)
        .expect("read fixture directory")
        .map(|entry| {
            entry
                .expect("read fixture entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    names.sort();
    names
}
