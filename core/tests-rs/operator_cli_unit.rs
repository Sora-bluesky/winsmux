use super::*;
use std::time::{SystemTime, UNIX_EPOCH};

fn restart_plan(agent: &str, capability_adapter: &str) -> RestartPlan {
    RestartPlan {
        label: "worker-1".to_string(),
        pane_id: "%2".to_string(),
        role: "Worker".to_string(),
        session_name: "winsmux-orchestra".to_string(),
        launch_dir: "C:\\repo".to_string(),
        git_worktree_dir: "C:\\repo\\.git".to_string(),
        agent: agent.to_string(),
        model: String::new(),
        model_source: default_provider_model_source(),
        reasoning_effort: default_provider_reasoning_effort(),
        capability_adapter: capability_adapter.to_string(),
        launch_command: "noop".to_string(),
    }
}

fn test_project_dir(name: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("winsmux-{name}-{}-{suffix}", std::process::id()));
    std::fs::create_dir_all(path.join(".winsmux")).expect("create test project");
    path
}

fn write_workspace_plan_settings(project_dir: &Path, yaml: &str) {
    std::fs::write(project_dir.join(".winsmux.yaml"), yaml).expect("write workspace-plan settings");
}

fn assert_workspace_plan_project_yaml_rejected(name: &str, yaml: &str) -> String {
    let project_dir = test_project_dir(name);
    write_workspace_plan_settings(&project_dir, yaml);
    let error = match read_workspace_plan_settings_with_global_reader(&project_dir, |_| None) {
        Ok(_) => panic!("{name} must be rejected before plan output"),
        Err(error) => error,
    };
    let _ = std::fs::remove_dir_all(project_dir);
    assert_eq!(error.kind(), io::ErrorKind::InvalidData, "{name}");
    error.to_string()
}

#[derive(Debug, serde::Deserialize)]
struct Task658ProjectSettingsParityRow {
    #[serde(rename = "Case")]
    case: String,
    #[serde(rename = "Settings")]
    settings: String,
    #[serde(rename = "Startup")]
    startup: String,
    #[serde(rename = "Preview")]
    preview: String,
    #[serde(rename = "Classification")]
    classification: String,
}

#[test]
fn workspace_plan_task658_project_settings_parity_fixture() {
    let rows: Vec<Task658ProjectSettingsParityRow> = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../tests/fixtures/rust-parity/task658-project-settings-parity.json"
    )))
    .expect("TASK-658 project-settings parity fixture must be valid JSON");
    assert_eq!(rows.len(), 13, "the Foundation R37 parity contract has 13 rows");

    let mut cases = std::collections::HashSet::new();
    for (index, row) in rows.iter().enumerate() {
        assert!(cases.insert(row.case.as_str()), "duplicate Case: {}", row.case);
        assert!(matches!(row.startup.as_str(), "accept" | "reject"));
        assert!(matches!(row.preview.as_str(), "accept" | "reject"));
        assert!(matches!(
            row.classification.as_str(),
            "equivalent" | "startup-rejection" | "R35-explicit-fail-closed"
        ));

        let project_dir = test_project_dir(&format!("task658-parity-{index}"));
        write_workspace_plan_settings(&project_dir, &row.settings);
        let result = read_workspace_plan_settings_with_global_reader(&project_dir, |_| None);
        let _ = std::fs::remove_dir_all(project_dir);

        match row.preview.as_str() {
            "accept" => {
                let settings = result.unwrap_or_else(|error| {
                    panic!("{} should be accepted by preview: {error}", row.case)
                });
                assert!(settings.has_slot("worker-1"), "{}", row.case);
            }
            "reject" => {
                let error = result.expect_err(&format!(
                    "{} should be rejected by preview",
                    row.case
                ));
                assert_eq!(error.kind(), std::io::ErrorKind::InvalidData, "{}", row.case);
            }
            _ => unreachable!("validated above"),
        }
    }
}

#[test]
fn workspace_plan_global_worker_count_limits_the_effective_slot_catalog() {
    let project_dir = test_project_dir("workspace-plan-global-worker-count");
    write_workspace_plan_settings(&project_dir, "config_version: 1\n");

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        (name == "@bridge-worker-count").then(|| "2".to_string())
    })
    .expect("global worker count should resolve");

    assert_eq!(settings.agent_slots.len(), 2);
    assert!(settings.has_slot("worker-2"));
    assert!(!settings.has_slot("worker-3"));

    let slots = settings
        .agent_slots
        .iter()
        .map(|slot| SlotCapabilities {
            slot_id: slot.slot_id.clone(),
            supports_file_edit: true,
            supports_verification: true,
            supports_structured_result: true,
        })
        .collect::<Vec<_>>();
    let error = normalize_workspace_plan(
        r#"workspace-recipes:
  limited:
    schema-version: 1
    panes:
      - pane-key: implementer
        workflow-role: implementer
        slot-ref: worker-3
        region: main
        worktree:
          mode: current
    startup-actions: []
"#,
        "limited",
        None,
        &slots,
    )
    .expect_err("worker-3 must be outside the global two-slot catalog");
    assert_eq!(
        error.to_string(),
        "pane 'implementer' references unknown slot 'worker-3'."
    );

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_project_external_operator_off_disables_generated_slots() {
    let project_dir = test_project_dir("workspace-plan-project-external-operator-off");
    write_workspace_plan_settings(
        &project_dir,
        "config_version: 1\nexternal_operator: off\n",
    );

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |_| None)
        .expect("project external_operator=off should resolve");

    assert!(settings.agent_slots.is_empty());

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_project_negative_worker_count_is_rejected() {
    let project_dir = test_project_dir("workspace-plan-project-negative-worker-count");
    write_workspace_plan_settings(&project_dir, "config_version: 1\nworker_count: -1\n");

    let error = read_workspace_plan_settings_with_global_reader(&project_dir, |_| None)
        .expect_err("negative project worker_count must not fall back to six workers");

    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    assert_eq!(
        error.to_string(),
        "workspace-plan worker_count must be at least 1 when agent_slots are omitted and legacy_role_layout is disabled."
    );

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_project_boolean_scalars_use_the_finite_vocabulary() {
    let cases = [
        ("true", true),
        ("1", true),
        ("yes", true),
        ("ON", true),
        ("false", false),
        ("0", false),
        ("no", false),
        ("Off", false),
    ];

    for (option, enabled_means_slots) in [
        ("external_operator", true),
        ("legacy_role_layout", false),
    ] {
        for (value, parsed) in cases {
            let project_dir = test_project_dir(&format!(
                "workspace-plan-project-{option}-{}",
                value.to_ascii_lowercase()
            ));
            write_workspace_plan_settings(
                &project_dir,
                &format!("config_version: 1\n{option}: {value}\n"),
            );

            let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |_| None)
                .unwrap_or_else(|error| panic!("{option}={value} should resolve: {error}"));
            let should_have_slots = parsed == enabled_means_slots;
            assert_eq!(
                settings.agent_slots.len(),
                if should_have_slots { 6 } else { 0 },
                "unexpected slot count for project {option}={value}"
            );

            let _ = std::fs::remove_dir_all(project_dir);
        }
    }
}

#[test]
fn workspace_plan_global_boolean_scalars_use_the_finite_vocabulary() {
    let cases = [("on", true), ("1", true), ("OFF", false), ("0", false)];

    for (option, enabled_means_slots) in [
        ("@bridge-external-operator", true),
        ("@bridge-legacy-role-layout", false),
    ] {
        for (value, parsed) in cases {
            let project_dir = test_project_dir(&format!(
                "workspace-plan-global-{}-{}",
                option.trim_start_matches("@bridge-"),
                value.to_ascii_lowercase()
            ));
            write_workspace_plan_settings(&project_dir, "config_version: 1\n");

            let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
                (name == option).then(|| value.to_string())
            })
            .unwrap_or_else(|error| panic!("{option}={value} should resolve: {error}"));
            let should_have_slots = parsed == enabled_means_slots;
            assert_eq!(
                settings.agent_slots.len(),
                if should_have_slots { 6 } else { 0 },
                "unexpected slot count for global {option}={value}"
            );

            let _ = std::fs::remove_dir_all(project_dir);
        }
    }
}

#[test]
fn workspace_plan_rejects_unsupported_project_boolean_scalar() {
    for (index, project_setting) in [
        "external_operator: maybe\n",
        "legacy_role_layout: sometimes\n",
    ]
    .into_iter()
    .enumerate()
    {
        let message = assert_workspace_plan_project_yaml_rejected(
            &format!("workspace-plan-project-bool-invalid-{index}"),
            &format!("config_version: 1\n{project_setting}"),
        );
        assert_eq!(
            message,
            "Invalid project settings: unsupported runtime-owned value."
        );
    }
}

#[test]
fn workspace_plan_nonpositive_effective_worker_count_is_rejected() {
    let cases = [
        (Some("worker_count: -1\n"), None),
        (Some("worker_count: 0\n"), None),
        (None, Some("-1")),
        (None, Some("0")),
    ];

    for (index, (project_count, global_count)) in cases.into_iter().enumerate() {
        let project_dir = test_project_dir(&format!("workspace-plan-nonpositive-{index}"));
        write_workspace_plan_settings(
            &project_dir,
            &format!("config_version: 1\n{}", project_count.unwrap_or_default()),
        );

        let error = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
            (name == "@bridge-worker-count")
                .then(|| global_count.map(str::to_string))
                .flatten()
        })
        .expect_err("nonpositive effective worker_count must be rejected");

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(
            error.to_string(),
            "workspace-plan worker_count must be at least 1 when agent_slots are omitted and legacy_role_layout is disabled."
        );

        let _ = std::fs::remove_dir_all(project_dir);
    }
}

#[test]
fn workspace_plan_project_worker_count_precedes_global_nonpositive_value() {
    let project_dir = test_project_dir("workspace-plan-project-count-precedence");
    write_workspace_plan_settings(&project_dir, "config_version: 1\nworker_count: 2\n");

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        (name == "@bridge-worker-count").then(|| "-1".to_string())
    })
    .expect("positive project worker_count should override the global value");

    assert_eq!(settings.agent_slots.len(), 2);
    assert!(settings.has_slot("worker-2"));
    assert!(!settings.has_slot("worker-3"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_rejects_invalid_project_count_and_ignores_invalid_global_count() {
    for (index, project_count) in ["many", "2147483648"].into_iter().enumerate() {
        let message = assert_workspace_plan_project_yaml_rejected(
            &format!("workspace-plan-project-count-invalid-{index}"),
            &format!("config_version: 1\nworker_count: {project_count}\n"),
        );
        assert_eq!(
            message,
            "Invalid project settings: unsupported runtime-owned value."
        );
    }

    for (index, global_count) in ["many", "2147483648"].into_iter().enumerate() {
        let project_dir = test_project_dir(&format!("workspace-plan-global-count-miss-{index}"));
        write_workspace_plan_settings(&project_dir, "config_version: 1\n");

        let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
            (name == "@bridge-worker-count").then(|| global_count.to_string())
        })
        .expect("invalid global count should fall through to the default");
        assert_eq!(settings.agent_slots.len(), 6);

        let _ = std::fs::remove_dir_all(project_dir);
    }
}

#[test]
fn workspace_plan_irrelevant_worker_count_does_not_block_explicit_or_legacy_layouts() {
    let cases = [
        (
            "agent_slots:\n  - slot_id: worker-1\nworker_count: -1\n",
            None,
            1,
        ),
        ("legacy_role_layout: true\nworker_count: 0\n", None, 0),
        (
            "agent_slots:\n  - slot_id: worker-1\n",
            Some(("@bridge-worker-count", "-1")),
            1,
        ),
        (
            "",
            Some(("@bridge-legacy-role-layout", "on")),
            0,
        ),
    ];

    for (index, (project_settings, global_setting, expected_slots)) in
        cases.into_iter().enumerate()
    {
        let project_dir = test_project_dir(&format!("workspace-plan-irrelevant-count-{index}"));
        write_workspace_plan_settings(
            &project_dir,
            &format!("config_version: 1\n{project_settings}"),
        );

        let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
            global_setting
                .filter(|(option, _)| name == *option)
                .map(|(_, value)| value.to_string())
                .or_else(|| {
                    (index == 3 && name == "@bridge-worker-count").then(|| "-1".to_string())
                })
        })
        .expect("irrelevant worker_count should not block the selected layout");
        assert_eq!(settings.agent_slots.len(), expected_slots);

        let _ = std::fs::remove_dir_all(project_dir);
    }
}

#[test]
fn workspace_plan_mixed_case_known_keys_use_finite_validation() {
    let cases = [
        (
            "mixed-case-top-domain",
            "Config_Version: 1\nPrompt_Transport: secret-marker-unsupported\n",
            "Invalid project settings",
        ),
        (
            "mixed-case-role-domain",
            "Config_Version: 1\nRoles:\n  Worker:\n    Reasoning_Effort: secret-marker-unsupported\n",
            "Invalid roles configuration",
        ),
    ];

    for (name, yaml, expected) in cases {
        let message = assert_workspace_plan_project_yaml_rejected(name, yaml);
        assert!(message.contains(expected), "{name}: {message}");
        assert!(!message.contains("secret-marker"), "{name}: {message}");
    }
}

#[test]
fn workspace_plan_mixed_case_alias_collisions_are_rejected() {
    let cases = [
        (
            "mixed-case-top-collision",
            "config_version: 1\nprompt_transport: argv\nPrompt-Transport: file\n",
            "Invalid project settings: conflicting runtime-owned aliases at top level.",
        ),
        (
            "mixed-case-role-collision",
            "config_version: 1\nroles:\n  worker:\n    reasoning_effort: low\n    Reasoning-Effort: high\n",
            "Invalid roles configuration: conflicting runtime-owned aliases.",
        ),
    ];

    for (name, yaml, expected) in cases {
        assert_eq!(assert_workspace_plan_project_yaml_rejected(name, yaml), expected);
    }
}

#[test]
fn workspace_plan_mixed_case_known_keys_accept_valid_values() {
    let project_dir = test_project_dir("workspace-plan-mixed-case-valid");
    write_workspace_plan_settings(
        &project_dir,
        "Config-Version: 1\nPrompt-Transport: FILE\nRoles:\n  Worker:\n    Reasoning-Effort: MEDIUM\nAgent-Slots:\n  - Slot-Id: worker-1\n    Worker-Backend: NOOP\n    Execution-Profile: LOCAL-WINDOWS\n    Runtime-Role: WORKER\n    Worktree-Mode: MANAGED\n",
    );

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |_| None)
        .expect("valid mixed-case runtime-owned keys should resolve");
    assert_eq!(settings.prompt_transport, "file");
    assert_eq!(settings.worker_role.reasoning_effort.as_deref(), Some("medium"));
    assert_eq!(settings.agent_slots.len(), 1);
    assert!(settings.has_slot("worker-1"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_rejects_invalid_top_level_runtime_domains() {
    let cases = [
        ("top-prompt-transport", "prompt_transport"),
        ("top-worker-backend", "worker_backend"),
        ("top-execution-profile", "execution_profile"),
        (
            "top-workspace-lifecycle",
            "workspace_lifecycle_preset",
        ),
        ("top-reasoning-effort", "reasoning_effort"),
    ];

    for (name, field) in cases {
        let message = assert_workspace_plan_project_yaml_rejected(
            name,
            &format!("config_version: 1\n{field}: secret-marker-unsupported\n"),
        );
        assert!(message.contains("Invalid project settings"), "{name}: {message}");
        assert!(!message.contains("secret-marker"), "{name}: {message}");
    }

    for (name, version) in [("unsupported-config-version", "2"), ("malformed-config-version", "many")]
    {
        let message = assert_workspace_plan_project_yaml_rejected(
            name,
            &format!("config_version: {version}\n"),
        );
        assert_eq!(message, "Invalid project settings: unsupported config_version.");
    }

    for retired_key in ["external_commander", "external-commander", "commanders"] {
        let message = assert_workspace_plan_project_yaml_rejected(
            "retired-operator-setting",
            &format!("config_version: 1\n{retired_key}: true\n"),
        );
        assert_eq!(message, "Retired project setting is not supported.");
    }
}

#[test]
fn workspace_plan_rejects_invalid_slot_and_role_runtime_domains() {
    let slot_cases = ["reasoning_effort", "prompt_transport"];
    for field in slot_cases {
        let message = assert_workspace_plan_project_yaml_rejected(
            &format!("slot-invalid-{field}"),
            &format!(
                "config_version: 1\nagent_slots:\n  - slot_id: worker-1\n    {field}: secret-marker-unsupported\n"
            ),
        );
        assert!(message.contains("Invalid agent_slots configuration"));
        assert!(!message.contains("secret-marker"));
    }

    for field in ["reasoning_effort", "prompt_transport"] {
        let message = assert_workspace_plan_project_yaml_rejected(
            &format!("role-invalid-{field}"),
            &format!(
                "config_version: 1\nroles:\n  worker:\n    {field}: secret-marker-unsupported\n"
            ),
        );
        assert!(message.contains("Invalid roles configuration"));
        assert!(!message.contains("secret-marker"));
    }
}

#[test]
fn workspace_plan_rejects_invalid_slot_shapes_and_case_insensitive_ids() {
    let cases = [
        (
            "slot-list-shape",
            "config_version: 1\nagent_slots: {slot_id: worker-1}\n",
        ),
        (
            "slot-entry-shape",
            "config_version: 1\nagent_slots:\n  - worker-1\n",
        ),
        (
            "slot-missing-id",
            "config_version: 1\nagent_slots:\n  - agent: codex\n",
        ),
    ];
    for (name, yaml) in cases {
        let message = assert_workspace_plan_project_yaml_rejected(name, yaml);
        assert!(message.contains("Invalid agent_slots configuration"));
    }
}

#[test]
fn workspace_plan_rejects_explicit_empty_or_non_scalar_runtime_owned_values() {
    let cases = [
        ("top-empty", "config_version: 1\nagent: ''\n"),
        ("top-non-scalar", "config_version: 1\nworker_count: {}\n"),
        (
            "slot-empty",
            "config_version: 1\nagent_slots:\n  - slot_id: worker-1\n    worker_backend: ''\n",
        ),
        (
            "slot-non-scalar",
            "config_version: 1\nagent_slots:\n  - slot_id: worker-1\n    agent: []\n",
        ),
        (
            "role-empty",
            "config_version: 1\nroles:\n  worker:\n    reasoning_effort: ''\n",
        ),
        (
            "role-non-scalar",
            "config_version: 1\nroles:\n  worker:\n    model: {}\n",
        ),
    ];
    for (name, yaml) in cases {
        let message = assert_workspace_plan_project_yaml_rejected(name, yaml);
        assert!(message.contains("Invalid"), "{name}: {message}");
    }
}

#[test]
fn workspace_plan_accepts_valid_runtime_domain_boundaries_and_unknown_fields() {
    let project_dir = test_project_dir("workspace-plan-valid-runtime-domains");
    write_workspace_plan_settings(
        &project_dir,
        r#"config-version: 1
prompt-transport: FILE
worker-backend: API_LLM
execution-profile: ISOLATED-ENTERPRISE
workspace-lifecycle-preset: ephemeral-worktree
reasoning-effort: XHIGH
unknown_future_top: preserved-by-runtime
roles:
  worker:
    reasoning-effort: medium
    prompt-transport: stdin
    unknown_future_role: preserved-by-runtime
agent-slots:
  - slot-id: worker-1
    backend: noop
    execution-profile: local-windows
    mcp-mode: provider-default
    reasoning-effort: max
    prompt-transport: argv
    runtime-role: worker
    worktree-mode: managed
    unknown_future_slot: preserved-by-runtime
"#,
    );

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |_| None)
        .expect("supported runtime domains and unknown fields should resolve");
    assert_eq!(settings.prompt_transport, "file");
    assert_eq!(settings.reasoning_effort, "xhigh");
    assert_eq!(settings.agent_slots.len(), 1);
    assert!(settings.has_slot("worker-1"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_global_option_classification_keeps_per_key_misses_local() {
    assert!(matches!(
        classify_workspace_plan_global_option(false, b"unknown option"),
        WorkspacePlanGlobalOptionRead::Missing
    ));
    assert!(matches!(
        classify_workspace_plan_global_option(true, b"no server running on session"),
        WorkspacePlanGlobalOptionRead::Missing
    ));
    assert!(matches!(
        classify_workspace_plan_global_option(true, b"2\n"),
        WorkspacePlanGlobalOptionRead::Value(value) if value == "2"
    ));
    assert!(matches!(
        classify_workspace_plan_global_option(true, &[0xff]),
        WorkspacePlanGlobalOptionRead::SourceUnavailable
    ));
}

#[test]
fn workspace_plan_in_process_global_reader_distinguishes_missing_and_unavailable() {
    assert!(matches!(
        read_workspace_plan_global_option_with_control("@bridge-agent", |_| {
            Ok("unknown option".to_string())
        }),
        WorkspacePlanGlobalOptionRead::Missing
    ));
    assert!(matches!(
        read_workspace_plan_global_option_with_control("@bridge-agent", |_| {
            Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "synthetic unavailable source",
            ))
        }),
        WorkspacePlanGlobalOptionRead::SourceUnavailable
    ));
    assert!(matches!(
        read_workspace_plan_global_option_with_control("@bridge-worker-count", |command| {
            assert_eq!(command, "show-options -g -v @bridge-worker-count\n");
            Ok("2\n".to_string())
        }),
        WorkspacePlanGlobalOptionRead::Value(value) if value == "2"
    ));
}

#[test]
fn workspace_plan_global_provider_defaults_fill_unset_project_values() {
    let project_dir = test_project_dir("workspace-plan-global-provider-defaults");
    write_workspace_plan_settings(&project_dir, "config_version: 1\n");

    let settings =
        read_workspace_plan_settings_with_global_reader(&project_dir, |name| match name {
            "@bridge-agent" => Some("gemini".to_string()),
            "@bridge-model" => Some("gemini-2.5-pro".to_string()),
            "@bridge-prompt-transport" => Some("stdin".to_string()),
            _ => None,
        })
        .expect("global provider defaults should resolve");

    assert_eq!(settings.agent, "gemini");
    assert_eq!(settings.model, "gemini-2.5-pro");
    assert_eq!(settings.model_source, "operator-override");
    assert_eq!(settings.prompt_transport, "stdin");
    let first = settings.slot("worker-1").expect("default worker slot");
    assert_eq!(first.agent.as_deref(), Some("gemini"));
    assert_eq!(first.model.as_deref(), Some("gemini-2.5-pro"));
    assert_eq!(first.prompt_transport.as_deref(), Some("stdin"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_rejects_project_slots_when_global_enables_legacy_layout() {
    let project_dir = test_project_dir("workspace-plan-global-legacy-layout");
    write_workspace_plan_settings(
        &project_dir,
        "config_version: 1\nagent_slots:\n  - slot_id: worker-1\n",
    );

    let error = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        (name == "@bridge-legacy-role-layout").then(|| "true".to_string())
    })
    .expect_err("runtime legacy layout cannot realize project agent_slots");

    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    assert_eq!(
        error.to_string(),
        "workspace-plan cannot bind agent_slots while legacy_role_layout is enabled."
    );

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_project_false_overrides_global_legacy_layout() {
    let project_dir = test_project_dir("workspace-plan-project-modern-layout");
    write_workspace_plan_settings(
        &project_dir,
        "config_version: 1\nlegacy_role_layout: false\nagent_slots:\n  - slot_id: worker-1\n",
    );

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        (name == "@bridge-legacy-role-layout").then(|| "true".to_string())
    })
    .expect("project false must override the global legacy layout");

    assert_eq!(settings.agent_slots.len(), 1);
    assert!(settings.has_slot("worker-1"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_project_values_override_global_values_per_key() {
    let project_dir = test_project_dir("workspace-plan-project-over-global");
    write_workspace_plan_settings(
        &project_dir,
        "config_version: 1\nagent: claude\nmodel: opus\nprompt_transport: file\nworker_count: 3\n",
    );

    let settings =
        read_workspace_plan_settings_with_global_reader(&project_dir, |name| match name {
            "@bridge-agent" => Some("gemini".to_string()),
            "@bridge-model" => Some("gemini-2.5-pro".to_string()),
            "@bridge-prompt-transport" => Some("stdin".to_string()),
            "@bridge-worker-count" => Some("2".to_string()),
            _ => None,
        })
        .expect("project values should win");

    assert_eq!(settings.agent, "claude");
    assert_eq!(settings.model, "opus");
    assert_eq!(settings.prompt_transport, "file");
    assert_eq!(settings.agent_slots.len(), 3);
    assert!(settings.has_slot("worker-3"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_missing_runtime_globals_use_existing_defaults() {
    let project_dir = test_project_dir("workspace-plan-no-runtime-globals");
    write_workspace_plan_settings(&project_dir, "config_version: 1\n");
    let mut queried = Vec::new();

    let settings = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        queried.push(name.to_string());
        None
    })
    .expect("missing runtime globals should preserve defaults");

    assert_eq!(
        queried,
        WORKSPACE_PLAN_GLOBAL_OPTIONS
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>()
    );
    assert_eq!(settings.agent, "codex");
    assert!(settings.model.is_empty());
    assert_eq!(settings.prompt_transport, "argv");
    assert_eq!(settings.agent_slots.len(), 6);

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_ignores_invalid_non_strict_global_values() {
    let project_dir = test_project_dir("workspace-plan-invalid-non-strict-global");
    write_workspace_plan_settings(&project_dir, "config_version: 1\n");

    let settings =
        read_workspace_plan_settings_with_global_reader(&project_dir, |name| match name {
            "@bridge-worker-count" => Some("many".to_string()),
            "@bridge-external-operator" => Some("maybe".to_string()),
            "@bridge-legacy-role-layout" => Some("sometimes".to_string()),
            _ => None,
        })
        .expect("invalid non-strict globals should be ignored like the runtime loader");

    assert_eq!(settings.agent_slots.len(), 6);
    assert!(settings.has_slot("worker-6"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn workspace_plan_rejects_invalid_strict_global_values() {
    let project_dir = test_project_dir("workspace-plan-invalid-strict-global");
    write_workspace_plan_settings(&project_dir, "config_version: 1\n");

    let transport_error = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        (name == "@bridge-prompt-transport").then(|| "pipe".to_string())
    })
    .expect_err("invalid global prompt transport must fail");
    assert_eq!(
        transport_error.to_string(),
        "Invalid prompt_transport configuration: unsupported value 'pipe'."
    );

    let profile_error = read_workspace_plan_settings_with_global_reader(&project_dir, |name| {
        (name == "@bridge-execution-profile").then(|| "container-mandatory".to_string())
    })
    .expect_err("invalid global execution profile must fail");
    assert_eq!(
        profile_error.to_string(),
        "Invalid execution_profile configuration: unsupported value 'container-mandatory'."
    );

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn stream_event_reader_ignores_partial_tail_line() {
    let project_dir = test_project_dir("stream-partial-tail");
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    std::fs::write(
            &events_path,
            concat!(
                r#"{"timestamp":"2026-04-24T12:00:01+09:00","event":"operator.followup","data":{"run_id":"task:TASK-1"}}"#,
                "\n",
                r#"{"timestamp":"2026-04-24T12:00:02+09:00","event":"#
            ),
        )
        .expect("write partial event log");

    let events =
        read_desktop_summary_events_for_stream(&project_dir).expect("stream reader succeeds");

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event, "operator.followup");
    assert!(read_desktop_summary_events(&project_dir).is_err());
}

fn meta_plan_role(provider: &str, plan_mode: &str) -> MetaPlanRole {
    MetaPlanRole {
        role_id: "planner".to_string(),
        label: "Planner".to_string(),
        provider: provider.to_string(),
        model: "provider-default".to_string(),
        model_source: default_provider_model_source(),
        reasoning_effort: default_provider_reasoning_effort(),
        plan_mode: plan_mode.to_string(),
        read_only: true,
        review_rounds: 1,
        capabilities: vec!["planning".to_string()],
        prompt: "Plan without editing files.".to_string(),
    }
}

#[test]
fn restart_readiness_agent_resolves_known_adapters() {
    assert_eq!(
        restart_readiness_agent(&restart_plan("custom", "codex")),
        "codex"
    );
    assert_eq!(
        restart_readiness_agent(&restart_plan("claude-opus", "")),
        "claude"
    );
    assert_eq!(
        restart_readiness_agent(&restart_plan("gemini:flash", "")),
        "gemini"
    );
}

#[test]
fn restart_readiness_agent_does_not_default_unknown_to_codex() {
    assert_eq!(restart_readiness_agent(&restart_plan("", "")), "");
    assert_eq!(
        restart_readiness_agent(&restart_plan("custom-agent", "")),
        ""
    );
    assert_eq!(
        restart_readiness_agent(&restart_plan("custom-agent", "custom-adapter")),
        ""
    );
}

#[test]
fn meta_plan_role_uses_provider_capability_metadata_for_future_provider() {
    let project_dir = test_project_dir("meta-plan-provider-capability");
    let capability_path = provider_capability_registry_path(&project_dir);
    std::fs::write(
        &capability_path,
        r#"{
              "version": 1,
              "providers": {
                "gemini-planner": {
                  "adapter": "gemini",
                  "command": "gemini",
                  "prompt_transports": ["stdin"],
                  "supports_file_edit": false,
                  "supports_consultation": true
                }
              }
            }"#,
    )
    .expect("write provider capability registry");

    let role = meta_plan_role("gemini-planner", "read_only_equivalent");
    validate_meta_plan_role(&project_dir, &role).expect("role should validate");
    let adapter = meta_plan_provider_adapter(&project_dir, &role).expect("adapter");
    let command = meta_plan_provider_command(&project_dir, &role).expect("command");
    let launch =
        meta_plan_launch_contract(&project_dir, &role, &adapter, &command).expect("launch");

    assert_eq!(adapter, "gemini");
    assert_eq!(command, "gemini");
    assert_eq!(launch["provider"], "gemini-planner");
    assert_eq!(launch["provider_adapter"], "gemini");
    assert_eq!(launch["read_only_equivalent"], true);
    assert_eq!(launch["read_only"], true);

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn meta_plan_role_rejects_future_provider_without_capability_metadata() {
    let project_dir = test_project_dir("meta-plan-missing-provider-capability");
    let role = meta_plan_role("future-planner", "read_only_equivalent");
    let error = validate_meta_plan_role(&project_dir, &role).expect_err("role should fail");

    assert!(error
        .to_string()
        .contains("must be declared in .winsmux/provider-capabilities.json"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn meta_plan_role_rejects_custom_adapter_without_read_only_launch_args() {
    let project_dir = test_project_dir("meta-plan-custom-provider-no-read-only-args");
    let capability_path = provider_capability_registry_path(&project_dir);
    std::fs::write(
        &capability_path,
        r#"{
              "version": 1,
              "providers": {
                "future-planner": {
                  "adapter": "future-cli",
                  "command": "future",
                  "prompt_transports": ["stdin"],
                  "supports_file_edit": false,
                  "supports_consultation": true
                }
              }
            }"#,
    )
    .expect("write provider capability registry");

    let role = meta_plan_role("future-planner", "read_only_equivalent");
    let error = validate_meta_plan_role(&project_dir, &role).expect_err("role should fail");

    assert!(error
        .to_string()
        .contains("must declare read_only_launch_args"));

    let _ = std::fs::remove_dir_all(project_dir);
}

#[test]
fn meta_plan_role_uses_custom_adapter_read_only_launch_args() {
    let project_dir = test_project_dir("meta-plan-custom-provider-read-only-args");
    let capability_path = provider_capability_registry_path(&project_dir);
    std::fs::write(
        &capability_path,
        r#"{
              "version": 1,
              "providers": {
                "future-planner": {
                  "adapter": "future-cli",
                  "command": "future",
                  "prompt_transports": ["stdin"],
                  "read_only_launch_args": ["--read-only", "--no-write"],
                  "supports_file_edit": false,
                  "supports_consultation": true
                }
              }
            }"#,
    )
    .expect("write provider capability registry");

    let role = meta_plan_role("future-planner", "read_only_equivalent");
    validate_meta_plan_role(&project_dir, &role).expect("role should validate");
    let adapter = meta_plan_provider_adapter(&project_dir, &role).expect("adapter");
    let command = meta_plan_provider_command(&project_dir, &role).expect("command");
    let launch =
        meta_plan_launch_contract(&project_dir, &role, &adapter, &command).expect("launch");

    assert_eq!(adapter, "future-cli");
    assert_eq!(command, "future");
    assert_eq!(launch["provider"], "future-planner");
    assert_eq!(launch["provider_adapter"], "future-cli");
    assert_eq!(launch["args"], json!(["--read-only", "--no-write"]));
    assert_eq!(launch["read_only_equivalent"], true);
    assert_eq!(launch["read_only"], true);

    let _ = std::fs::remove_dir_all(project_dir);
}
