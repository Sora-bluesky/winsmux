use std::fs;
use std::process::Command;

const LIST_JSON: &str = "{\"schema_version\":1,\"action\":\"list\",\"presets\":[{\"preset_id\":\"bugfix\"},{\"preset_id\":\"review\"},{\"preset_id\":\"research\"},{\"preset_id\":\"benchmark\"}]}\n";
const SHIPPED_PRESETS: [&str; 4] = ["bugfix", "review", "research", "benchmark"];
const FIXTURE_YAML: &str = "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\nagent-slots:\n  - slot-id: worker-1\n    agent: codex\n";

fn preview_json(preset: &str) -> String {
    format!(
        "{{\"schema_version\":1,\"action\":\"preview\",\"preset_id\":\"{preset}\",\"recipe_id\":\"{preset}\",\"sinks\":[{{\"path\":\".winsmux.yaml\",\"kind\":\"workspace-recipes\"}},{{\"path\":\".winsmux/workspace-preset.json\",\"kind\":\"adoption-sidecar\"}}]}}\n"
    )
}

fn apply_json(preset: &str) -> String {
    format!(
        "{{\"schema_version\":1,\"action\":\"apply\",\"preset_id\":\"{preset}\",\"recipe_id\":\"{preset}\"}}\n"
    )
}

fn rollback_json(preset: &str) -> String {
    format!(
        "{{\"schema_version\":1,\"action\":\"rollback\",\"preset_id\":\"{preset}\",\"recipe_id\":\"{preset}\"}}\n"
    )
}

fn sidecar_path(project: &std::path::Path) -> std::path::PathBuf {
    project.join(".winsmux").join("workspace-preset.json")
}

fn yaml_mapping(project: &std::path::Path) -> serde_yaml::Mapping {
    serde_yaml::from_slice::<serde_yaml::Value>(
        &fs::read(project.join(".winsmux.yaml")).expect("read applied yaml"),
    )
    .expect("applied yaml should parse")
    .as_mapping()
    .expect("applied yaml should be a mapping")
    .clone()
}

fn recipe_mapping<'a>(root: &'a serde_yaml::Mapping, preset: &str) -> &'a serde_yaml::Mapping {
    root.get(serde_yaml::Value::String("workspace-recipes".into()))
        .and_then(serde_yaml::Value::as_mapping)
        .and_then(|recipes| recipes.get(serde_yaml::Value::String(preset.into())))
        .and_then(serde_yaml::Value::as_mapping)
        .expect("applied yaml must contain the shipped recipe")
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

fn write_preview_fixture(project: &std::path::Path) {
    let runtime_dir = project.join(".winsmux");
    fs::create_dir(&runtime_dir).expect("create runtime fixture directory");
    fs::write(project.join(".winsmux.yaml"), FIXTURE_YAML).expect("write settings fixture");
    fs::write(runtime_dir.join("keep-me.txt"), b"untouched\n").expect("write runtime marker");
}

#[test]
fn list_json_prints_four_shipped_presets_without_stderr() {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["workspace-migrate", "--action", "list", "--json"])
        .output()
        .expect("run workspace-migrate list");

    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "",
        "list must not write stderr"
    );
    assert!(
        output.status.success(),
        "list must exit 0; stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8(output.stdout).expect("list stdout must be UTF-8"),
        LIST_JSON
    );
}

#[test]
fn preview_json_is_side_effect_free_for_four_shipped_presets() {
    for preset in SHIPPED_PRESETS {
        let project = tempfile::tempdir().expect("create preview fixture");
        write_preview_fixture(project.path());
        let runtime_dir = project.path().join(".winsmux");
        let before_root = sorted_entry_names(project.path());
        let before_runtime = sorted_entry_names(&runtime_dir);
        let before_settings = fs::read(project.path().join(".winsmux.yaml")).unwrap();
        let before_marker = fs::read(runtime_dir.join("keep-me.txt")).unwrap();

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([
                "workspace-migrate",
                "--action",
                "preview",
                "--preset",
                preset,
                "--json",
                "--project-dir",
            ])
            .arg(project.path())
            .output()
            .expect("run workspace-migrate preview");

        assert_eq!(
            String::from_utf8_lossy(&output.stderr),
            "",
            "preview must not write stderr for preset {preset}"
        );
        assert!(
            output.status.success(),
            "preview must exit 0 for preset {preset}; stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8(output.stdout).expect("preview stdout must be UTF-8"),
            preview_json(preset),
            "preview stdout must be exact for preset {preset}"
        );
        assert_eq!(sorted_entry_names(project.path()), before_root);
        assert_eq!(sorted_entry_names(&runtime_dir), before_runtime);
        assert_eq!(
            fs::read(project.path().join(".winsmux.yaml")).unwrap(),
            before_settings
        );
        assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
        assert!(
            !runtime_dir.join("workspace-preset.json").exists(),
            "preview must not create the adoption sidecar"
        );
    }
}

#[test]
fn preview_rejects_unknown_preset_without_mutation() {
    let project = tempfile::tempdir().expect("create reject fixture");
    write_preview_fixture(project.path());
    let runtime_dir = project.path().join(".winsmux");
    let before_root = sorted_entry_names(project.path());
    let before_runtime = sorted_entry_names(&runtime_dir);
    let before_settings = fs::read(project.path().join(".winsmux.yaml")).unwrap();
    let before_marker = fs::read(runtime_dir.join("keep-me.txt")).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "preview",
            "--preset",
            "not-a-shipped-preset",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run workspace-migrate preview reject");

    assert!(
        !output.status.success(),
        "unknown preset must be non-zero"
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "",
        "reject must not write a stdout payload"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("unknown workspace-migrate preset."),
        "reject must use the stable unknown-preset error; stderr={stderr}"
    );
    assert!(
        !stderr.contains("not-a-shipped-preset"),
        "reject must not reflect the untrusted preset value"
    );
    assert_eq!(sorted_entry_names(project.path()), before_root);
    assert_eq!(sorted_entry_names(&runtime_dir), before_runtime);
    assert_eq!(
        fs::read(project.path().join(".winsmux.yaml")).unwrap(),
        before_settings
    );
    assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
}

#[test]
fn apply_writes_recipe_and_sidecar_then_rollback_restores_prior_bytes() {
    let project = tempfile::tempdir().expect("create apply fixture");
    write_preview_fixture(project.path());
    let runtime_dir = project.path().join(".winsmux");
    let before_settings = fs::read(project.path().join(".winsmux.yaml")).unwrap();
    let before_marker = fs::read(runtime_dir.join("keep-me.txt")).unwrap();
    let before_root = sorted_entry_names(project.path());
    let before_runtime = sorted_entry_names(&runtime_dir);

    let apply = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "apply",
            "--preset",
            "bugfix",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run workspace-migrate apply");

    assert_eq!(
        String::from_utf8_lossy(&apply.stderr),
        "",
        "apply must not write stderr"
    );
    assert!(
        apply.status.success(),
        "apply must exit 0; stdout={} stderr={}",
        String::from_utf8_lossy(&apply.stdout),
        String::from_utf8_lossy(&apply.stderr)
    );
    assert_eq!(
        String::from_utf8(apply.stdout).expect("apply stdout must be UTF-8"),
        apply_json("bugfix")
    );
    assert_eq!(sorted_entry_names(project.path()), before_root);
    let mut after_runtime = before_runtime.clone();
    after_runtime.push("workspace-preset.json".to_string());
    after_runtime.sort();
    assert_eq!(sorted_entry_names(&runtime_dir), after_runtime);
    assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
    assert_ne!(
        fs::read(project.path().join(".winsmux.yaml")).unwrap(),
        before_settings,
        "apply must change .winsmux.yaml"
    );

    let root = yaml_mapping(project.path());
    assert!(
        root.contains_key(serde_yaml::Value::String("team-profile".into())),
        "apply must preserve unowned Lane B keys"
    );
    let recipe = recipe_mapping(&root, "bugfix");
    assert_eq!(
        recipe.get(serde_yaml::Value::String("schema-version".into())),
        Some(&serde_yaml::Value::Number(1.into()))
    );
    let pane_key = recipe
        .get(serde_yaml::Value::String("panes".into()))
        .and_then(serde_yaml::Value::as_sequence)
        .and_then(|panes| panes.first())
        .and_then(serde_yaml::Value::as_mapping)
        .and_then(|pane| pane.get(serde_yaml::Value::String("pane-key".into())));
    assert_eq!(
        pane_key,
        Some(&serde_yaml::Value::String("implement".into()))
    );

    let sidecar: serde_json::Value = serde_json::from_slice(
        &fs::read(sidecar_path(project.path())).expect("read adoption sidecar"),
    )
    .expect("sidecar must be JSON");
    assert_eq!(sidecar["schema_version"], 1);
    assert_eq!(sidecar["preset_id"], "bugfix");
    assert_eq!(sidecar["yaml_existed"], true);
    assert_eq!(
        sidecar["previous_yaml"].as_str().expect("previous_yaml"),
        FIXTURE_YAML
    );

    let rollback = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "rollback",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run workspace-migrate rollback");

    assert_eq!(
        String::from_utf8_lossy(&rollback.stderr),
        "",
        "rollback must not write stderr"
    );
    assert!(
        rollback.status.success(),
        "rollback must exit 0; stdout={} stderr={}",
        String::from_utf8_lossy(&rollback.stdout),
        String::from_utf8_lossy(&rollback.stderr)
    );
    assert_eq!(
        String::from_utf8(rollback.stdout).expect("rollback stdout must be UTF-8"),
        rollback_json("bugfix")
    );
    assert_eq!(
        fs::read(project.path().join(".winsmux.yaml")).unwrap(),
        before_settings
    );
    assert_eq!(sorted_entry_names(project.path()), before_root);
    assert_eq!(sorted_entry_names(&runtime_dir), before_runtime);
    assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
    assert!(
        !sidecar_path(project.path()).exists(),
        "rollback must remove the adoption sidecar"
    );
}

#[test]
fn apply_rejects_existing_sidecar_and_unknown_preset_without_mutation() {
    let project = tempfile::tempdir().expect("create apply reject fixture");
    write_preview_fixture(project.path());
    let runtime_dir = project.path().join(".winsmux");
    fs::write(sidecar_path(project.path()), b"{\"schema_version\":1}\n")
        .expect("seed existing sidecar");
    let before_settings = fs::read(project.path().join(".winsmux.yaml")).unwrap();
    let before_sidecar = fs::read(sidecar_path(project.path())).unwrap();
    let before_marker = fs::read(runtime_dir.join("keep-me.txt")).unwrap();
    let before_root = sorted_entry_names(project.path());
    let before_runtime = sorted_entry_names(&runtime_dir);

    let existing = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "apply",
            "--preset",
            "bugfix",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run apply against existing sidecar");
    assert!(!existing.status.success(), "existing sidecar must be non-zero");
    assert_eq!(String::from_utf8_lossy(&existing.stdout), "");
    let existing_stderr = String::from_utf8_lossy(&existing.stderr);
    assert!(
        existing_stderr.contains("workspace-migrate apply requires rollback before another apply."),
        "existing sidecar error; stderr={existing_stderr}"
    );

    let unknown = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "apply",
            "--preset",
            "not-a-shipped-preset",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run apply unknown preset");
    assert!(!unknown.status.success(), "unknown preset must be non-zero");
    assert_eq!(String::from_utf8_lossy(&unknown.stdout), "");
    let unknown_stderr = String::from_utf8_lossy(&unknown.stderr);
    assert!(
        unknown_stderr.contains("unknown workspace-migrate preset."),
        "unknown preset error; stderr={unknown_stderr}"
    );
    assert!(!unknown_stderr.contains("not-a-shipped-preset"));

    assert_eq!(sorted_entry_names(project.path()), before_root);
    assert_eq!(sorted_entry_names(&runtime_dir), before_runtime);
    assert_eq!(
        fs::read(project.path().join(".winsmux.yaml")).unwrap(),
        before_settings
    );
    assert_eq!(fs::read(sidecar_path(project.path())).unwrap(), before_sidecar);
    assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
}

#[test]
fn apply_creates_yaml_and_rollback_restores_absence() {
    let project = tempfile::tempdir().expect("create absence fixture");
    let runtime_dir = project.path().join(".winsmux");
    fs::create_dir(&runtime_dir).expect("create runtime fixture directory");
    fs::write(runtime_dir.join("keep-me.txt"), b"untouched\n").expect("write runtime marker");
    let before_marker = fs::read(runtime_dir.join("keep-me.txt")).unwrap();
    assert!(!project.path().join(".winsmux.yaml").exists());

    let apply = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "apply",
            "--preset",
            "review",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run apply without yaml");
    assert_eq!(String::from_utf8_lossy(&apply.stderr), "");
    assert!(
        apply.status.success(),
        "apply without yaml must exit 0; stdout={} stderr={}",
        String::from_utf8_lossy(&apply.stdout),
        String::from_utf8_lossy(&apply.stderr)
    );
    assert_eq!(
        String::from_utf8(apply.stdout).expect("apply stdout must be UTF-8"),
        apply_json("review")
    );
    assert!(project.path().join(".winsmux.yaml").exists());
    let root = yaml_mapping(project.path());
    recipe_mapping(&root, "review");

    let rollback = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "rollback",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run rollback to absence");
    assert_eq!(String::from_utf8_lossy(&rollback.stderr), "");
    assert!(rollback.status.success());
    assert_eq!(
        String::from_utf8(rollback.stdout).expect("rollback stdout must be UTF-8"),
        rollback_json("review")
    );
    assert!(
        !project.path().join(".winsmux.yaml").exists(),
        "rollback must restore yaml absence"
    );
    assert!(!sidecar_path(project.path()).exists());
    assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
}

#[test]
fn apply_recipe_is_consumable_by_workspace_plan() {
    let project = tempfile::tempdir().expect("create plan fixture");
    write_preview_fixture(project.path());
    let runtime_dir = project.path().join(".winsmux");
    fs::write(
        runtime_dir.join("provider-capabilities.json"),
        include_str!("../../tests/fixtures/workspace-recipes/valid-v1.provider-capabilities.json"),
    )
    .expect("write capability fixture");
    let before_capabilities = fs::read(runtime_dir.join("provider-capabilities.json")).unwrap();
    let before_marker = fs::read(runtime_dir.join("keep-me.txt")).unwrap();

    let apply = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-migrate",
            "--action",
            "apply",
            "--preset",
            "bugfix",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run apply before workspace-plan");
    assert_eq!(String::from_utf8_lossy(&apply.stderr), "");
    assert!(
        apply.status.success(),
        "apply must exit 0 before workspace-plan; stdout={} stderr={}",
        String::from_utf8_lossy(&apply.stdout),
        String::from_utf8_lossy(&apply.stderr)
    );

    let plan = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "workspace-plan",
            "--recipe-id",
            "bugfix",
            "--json",
            "--project-dir",
        ])
        .arg(project.path())
        .output()
        .expect("run workspace-plan against applied recipe");
    assert_eq!(
        String::from_utf8_lossy(&plan.stderr),
        "",
        "workspace-plan must not write stderr against the applied recipe"
    );
    assert!(
        plan.status.success(),
        "applied recipe must be readable by workspace-plan; stdout={} stderr={}",
        String::from_utf8_lossy(&plan.stdout),
        String::from_utf8_lossy(&plan.stderr)
    );
    let plan_json: serde_json::Value =
        serde_json::from_slice(&plan.stdout).expect("workspace-plan stdout must be JSON");
    assert_eq!(plan_json["recipe_id"], "bugfix");
    assert_eq!(plan_json["resolved_bindings"]["implement"], "worker-1");
    assert_eq!(
        fs::read(runtime_dir.join("provider-capabilities.json")).unwrap(),
        before_capabilities
    );
    assert_eq!(fs::read(runtime_dir.join("keep-me.txt")).unwrap(), before_marker);
}
