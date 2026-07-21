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
