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
