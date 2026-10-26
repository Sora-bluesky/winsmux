#![cfg(all(windows, debug_assertions))]
#[path = "../workspace-privacy/support.rs"]
mod support;
use serde_json::json;
use std::fs;
use support::*;
use winsmux_workspace::auth::testing::Harness;

#[test]
fn v03638_golden_bytes_survive_registration_cancel_save_failure_and_restore() {
    for case in ["register-and-return", "cancel-no-dispatch", "save-failure", "unknown-layout"] {
        let tree = Scratch::new("winsmux-migration-golden");
        let legacy = tree.0.join("legacy"); fs::create_dir(&legacy).unwrap();
        fs::write(legacy.join("psmux.conf"), include_bytes!("fixtures/v03638/psmux.conf")).unwrap();
        fs::write(legacy.join("old-user-artifact.txt"), include_bytes!("fixtures/v03638/old-user-artifact.txt")).unwrap();
        let before = snapshot(&legacy);
        let store = tree.0.join("new-store");
        let h = Harness::new(Vec::new());
        assert!(h.authorization().testing_install_isolated_layout(&store));
        if case != "cancel-no-dispatch" {
            let opened = owner(&h, "project.open", json!({"path":legacy.to_str().unwrap()}));
            let project_id = accepted(&opened)["project_id"].as_str().unwrap();
            accepted(&owner(&h, "pane.create", json!({"project_id":project_id,"shell_profile_id":"pwsh"})));
            if case == "save-failure" {
                fs::create_dir(store.join("confirmed.json")).unwrap();
                let failed = owner(&h,"layout.save",json!({}));
                assert_eq!(failed["accepted"],false); assert_eq!(failed["error"]["code"],"persistence_failed");
                h.close_generation();
            } else if case == "unknown-layout" {
                fs::write(store.join("confirmed.json"), br#"{"schema_version":999}"#).unwrap();
                let before_memory = owner(&h,"project.list",json!({}))["result"]["data"].clone();
                assert_eq!(owner(&h,"layout.restore",json!({}))["accepted"],false);
                assert_eq!(owner(&h,"project.list",json!({}))["result"]["data"],before_memory);
                h.close_generation();
            } else {
                accepted(&owner(&h,"layout.save",json!({})));
                h.close_generation();
                drop(h);
                let returned = Harness::new(Vec::new());
                assert!(returned.authorization().testing_install_isolated_layout(&store));
                accepted(&owner(&returned,"layout.restore",json!({})));
                assert_eq!(returned.authorization().testing_spawn_counts(),(0,0));
                returned.close_generation();
            }
        } else { h.close_generation(); }
        if std::env::var_os("WINSMUX_MIGRATION_NEGATIVE").is_some() {
            fs::write(legacy.join("psmux.conf"), b"synthetic unintended mutation").unwrap();
        }
        assert_eq!(snapshot(&legacy), before, "old bytes changed: {case}");
    }
    println!("{{\"golden_cases\":4,\"legacy_native_process\":\"not_run\",\"pty\":false}}");
}
