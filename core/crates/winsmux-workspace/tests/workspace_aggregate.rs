#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::{
    parse_request, ConnectionId, OperationId, ProjectId, Request, MAX_SAFE_INTEGER,
};
use winsmux_workspace::host::ProductHost;
use winsmux_workspace::memory_testing::{
    classify_path_syntax, exclusive_directory_hold, observe_root, paths_are_windows_aliases,
    short_path_name, testing_create_unpaired_surrogate_directory, testing_os_utf16_final_path,
    testing_probe_volumes, testing_remove_wide_directory, AllocationPool, ObserveError,
    ObserveHold, PhaseHold, ProductPhase, WriteBodyHold, RETAINED_BYTES,
};

struct TempTree {
    root: PathBuf,
}

impl TempTree {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "winsmux-863-{}-{}-{}",
            label,
            stamp,
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).expect("temp tree");
        Self { root }
    }

    fn child(&self, name: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::create_dir_all(&path).expect("child");
        path
    }

    fn path_text(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn request_q(operation: &str, instance: Option<&str>, params: Value) -> Request {
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": instance,
            "operation_id": uuid::Uuid::new_v4().to_string(),
            "expected_topology_revision": null,
            "operation": operation,
            "params": params,
        }))
        .expect("json"),
    )
    .expect("request")
}

fn next_operation_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!(
        "20000000-0000-4000-8000-{:012x}",
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

fn request_t(operation: &str, instance: &str, revision: u64, params: Value) -> Request {
    request_tid(operation, instance, &next_operation_id(), revision, params)
}

fn request_tid(
    operation: &str,
    instance: &str,
    operation_id: &str,
    revision: u64,
    params: Value,
) -> Request {
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": instance,
            "operation_id": operation_id,
            "expected_topology_revision": revision,
            "operation": operation,
            "params": params,
        }))
        .expect("json"),
    )
    .unwrap_or_else(|error| panic!("{operation} parse: {error}"))
}

fn operation_id(value: &str) -> OperationId {
    OperationId::new(value.to_owned()).expect("operation id")
}

fn recorded_os_skip(class: &str, reason: &str) {
    eprintln!("TASK863 recorded OS skip class={class} reason={reason}");
}

fn mklink_junction(link: &Path, target: &Path) -> Result<(), String> {
    let output = Command::new("cmd")
        .args([
            "/C",
            "mklink",
            "/J",
            &TempTree::path_text(link),
            &TempTree::path_text(target),
        ])
        .output()
        .map_err(|error| format!("spawn mklink: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "status={:?} stdout={} stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn value(response: &winsmux_workspace::Response) -> Value {
    serde_json::to_value(response).expect("json")
}

fn instance(harness: &Harness) -> String {
    serde_json::to_value(harness.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("instance")
}

#[test]
fn root_identity_alias_matrix() {
    let tree = TempTree::new("alias");
    let japanese = tree.child("プロジェクト");
    fs::write(japanese.join("marker.txt"), b"keep").expect("marker");
    let japanese_path = TempTree::path_text(&japanese);
    let authority = winsmux_workspace::memory_testing::AllocationAuthority::host();

    let first = observe_root(&japanese_path, &authority, AllocationPool::ActiveOwner)
        .expect("japanese open");
    let slash = japanese_path.replace('\\', "/");
    let trailing = format!("{}\\", japanese_path.trim_end_matches(['\\', '/']));
    let verbatim = if japanese_path.starts_with(r"\\?\") {
        japanese_path.clone()
    } else {
        format!(r"\\?\{}", japanese_path.trim_start_matches(r"\\?\"))
    };
    let mut drive_lower_chars: Vec<char> = japanese_path.chars().collect();
    assert!(
        drive_lower_chars
            .first()
            .is_some_and(|ch| ch.is_ascii_uppercase()),
        "fixture drive letter must already be uppercase so the case-alias input can change: {japanese_path}"
    );
    drive_lower_chars[0] = drive_lower_chars[0].to_ascii_lowercase();
    let drive_lower: String = drive_lower_chars.into_iter().collect();
    assert_ne!(
        drive_lower, japanese_path,
        "case-alias input must differ from the original path"
    );
    let ascii_dir = tree.child("CaseAlias");
    let ascii_path = TempTree::path_text(&ascii_dir);
    let ascii_flipped = ascii_path.replace("CaseAlias", "casealias");
    assert_ne!(
        ascii_flipped, ascii_path,
        "ASCII component case-alias must change the input"
    );
    let ascii_identity = observe_root(&ascii_path, &authority, AllocationPool::ActiveOwner)
        .expect("ascii case folder");
    let ascii_alias = observe_root(&ascii_flipped, &authority, AllocationPool::ActiveOwner)
        .unwrap_or_else(|error| panic!("{ascii_flipped}: {error:?}"));
    assert_eq!(ascii_alias.identity, ascii_identity.identity);
    assert!(paths_are_windows_aliases(&ascii_path, &ascii_flipped));
    drop(ascii_identity);
    drop(ascii_alias);
    for alias in [&slash, &trailing, &verbatim, &drive_lower] {
        let observed = observe_root(alias, &authority, AllocationPool::ActiveOwner)
            .unwrap_or_else(|error| panic!("{alias}: {error:?}"));
        assert_eq!(observed.identity, first.identity, "{alias}");
        assert!(paths_are_windows_aliases(&first.actual_path, &observed.actual_path) || observed.identity == first.identity);
    }

    let sibling = tree.child("プロジェクト-b");
    let other = observe_root(
        &TempTree::path_text(&sibling),
        &authority,
        AllocationPool::ActiveOwner,
    )
    .expect("same name other folder");
    assert_ne!(other.identity, first.identity);
    drop(first);
    drop(other);

    let rejected = [
        "relative",
        r"C:foo",
        r"\\server\share\dir",
        r"\\.\pipe\x",
        "NUL",
        r"C:\foo:stream",
        r"C:\foo\.\bar",
        r"C:\foo\..\bar",
        r"C:\foo ",
        r"C:\foo.",
        r"C:\CON",
        r"C:\PRN\out",
        r"C:\COM1",
        r"C:\LPT1\out",
        r"C:\AUX",
        r"C:\foo\NUL",
        "C:\\fffd-\u{FFFD}",
    ];
    for path in rejected {
        assert_eq!(
            classify_path_syntax(path),
            Err(ObserveError::InvalidRequest),
            "{path}"
        );
    }

    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);
    let listed = value(&harness.owner(&request_q("project.list", Some(&inst), json!({}))));
    assert_eq!(listed["accepted"], json!(true));
    assert_eq!(listed["result"]["data"]["projects"], json!([]));
    let marker = tree.root.join("disk-bytes.bin");
    fs::write(&marker, b"keep-disk").expect("marker");
    for path in rejected {
        let denied = value(&harness.owner(&request_t(
            "project.open",
            &inst,
            0,
            json!({"path": path}),
        )));
        assert_eq!(
            denied["error"]["code"],
            json!("invalid_request"),
            "{path} {denied}"
        );
        assert_eq!(denied["topology_revision"], json!(0), "{path}");
    }
    assert!(!Path::new("relative").exists(), "relative path must not be created");
    assert_eq!(fs::read(&marker).expect("disk"), b"keep-disk");

    let opened = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        0,
        json!({"path": japanese_path}),
    )));
    assert_eq!(opened["accepted"], json!(true), "{opened}");
    let project_id = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("id")
        .to_owned();
    assert_eq!(opened["result"]["data"]["created"], json!(true));
    assert_eq!(opened["topology_revision"], json!(1));
    let listed = value(&harness.owner(&request_q("project.list", Some(&inst), json!({}))));
    let row = listed["result"]["data"]["projects"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["project_id"] == json!(project_id))
        .expect("opened row");
    assert_eq!(row["display_name"], json!("プロジェクト"));
    assert!(
        row["path"].as_str().is_some_and(|path| path.ends_with("プロジェクト")
            || paths_are_windows_aliases(path, &japanese_path)),
        "{row}"
    );

    for alias in [&slash, &trailing, &verbatim, &drive_lower] {
        let again = value(&harness.owner(&request_t(
            "project.open",
            &inst,
            1,
            json!({"path": alias}),
        )));
        assert_eq!(again["accepted"], json!(true), "{alias} {again}");
        assert_eq!(again["result"]["data"]["created"], json!(false), "{alias}");
        assert_eq!(
            again["result"]["data"]["project_id"],
            json!(project_id),
            "{alias}"
        );
        assert_eq!(again["topology_revision"], json!(1), "{alias}");
    }
    match short_path_name(&japanese_path) {
        Some(short) => {
            let short_open = value(&harness.owner(&request_t(
                "project.open",
                &inst,
                1,
                json!({"path": short}),
            )));
            assert_eq!(short_open["accepted"], json!(true), "{short_open}");
            assert_eq!(short_open["result"]["data"]["created"], json!(false));
            assert_eq!(short_open["result"]["data"]["project_id"], json!(project_id));
            assert_eq!(short_open["topology_revision"], json!(1));
        }
        None => recorded_os_skip(
            "8.3",
            "GetShortPathNameW returned none or a name without a distinct tilde alias",
        ),
    }

    let ascii_open = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        1,
        json!({"path": ascii_path}),
    )));
    assert_eq!(ascii_open["accepted"], json!(true), "{ascii_open}");
    let ascii_id = ascii_open["result"]["data"]["project_id"].clone();
    let ascii_rev = ascii_open["topology_revision"].as_u64().expect("rev");
    let ascii_again = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        ascii_rev,
        json!({"path": ascii_flipped}),
    )));
    assert_eq!(ascii_again["accepted"], json!(true), "{ascii_again}");
    assert_eq!(ascii_again["result"]["data"]["created"], json!(false));
    assert_eq!(ascii_again["result"]["data"]["project_id"], ascii_id);
    assert_eq!(ascii_again["topology_revision"], json!(ascii_rev));

    let other_open = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        ascii_rev,
        json!({"path": TempTree::path_text(&sibling)}),
    )));
    assert_eq!(other_open["accepted"], json!(true), "{other_open}");
    assert_ne!(other_open["result"]["data"]["project_id"], json!(project_id));

    let replaced = tree.child("swap-src");
    let replaced_path = TempTree::path_text(&replaced);
    let hold_open = tree.child("hold-open");
    let hold_path = TempTree::path_text(&hold_open);
    let hold = ObserveHold::install(&hold_path);
    let harness_open = harness.clone();
    let inst_open = inst.clone();
    let hold_path_open = hold_path.clone();
    let hold_revision = other_open["topology_revision"].as_u64().expect("rev");
    let worker = thread::spawn(move || {
        harness_open.owner(&request_t(
            "project.open",
            &inst_open,
            hold_revision,
            json!({"path": hold_path_open}),
        ))
    });
    hold.wait_entered();
    let moved_hold = tree.root.join("hold-moved");
    assert!(
        fs::rename(&hold_open, &moved_hold).is_err(),
        "product FILE_SHARE_READ handles must block replacement"
    );
    assert!(
        exclusive_directory_hold(&TempTree::path_text(&hold_open)).is_err(),
        "share=0 must fail while product open holds FILE_SHARE_READ"
    );
    hold.release_waiters();
    hold.clear();
    let held_open = worker.join().expect("open thread");
    let held_open = value(&held_open);
    assert_eq!(held_open["accepted"], json!(true), "{held_open}");
    let held_rev = held_open["topology_revision"].as_u64().expect("rev");

    let first_swap = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        held_rev,
        json!({"path": replaced_path}),
    )));
    assert_eq!(first_swap["accepted"], json!(true), "{first_swap}");
    let swap_id = first_swap["result"]["data"]["project_id"].clone();
    let revision = first_swap["topology_revision"].as_u64().expect("rev");
    let moved = tree.root.join("swap-moved");
    fs::rename(&replaced, &moved).expect("rename after product commit released handles");
    fs::create_dir_all(&replaced).expect("replacement folder");
    let changed = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        revision,
        json!({"path": replaced_path}),
    )));
    assert_eq!(changed["error"]["code"], json!("root_changed"), "{changed}");
    assert_eq!(changed["topology_revision"], json!(revision));
    let still = value(&harness.owner(&request_q("project.list", Some(&inst), json!({}))));
    assert!(still["result"]["data"]["projects"]
        .as_array()
        .expect("rows")
        .iter()
        .any(|row| row["project_id"] == swap_id));

    let forgotten = value(&harness.owner(&request_t(
        "project.forget",
        &inst,
        revision,
        json!({"project_id": project_id}),
    )));
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");
    let rereg = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        forgotten["topology_revision"].as_u64().expect("rev"),
        json!({"path": japanese_path}),
    )));
    assert_eq!(rereg["accepted"], json!(true), "{rereg}");
    assert_eq!(rereg["result"]["data"]["created"], json!(true));
    assert_ne!(rereg["result"]["data"]["project_id"], json!(project_id));
    assert_eq!(fs::read(japanese.join("marker.txt")).expect("bytes"), b"keep");

    let probes = testing_probe_volumes();
    let volume_types = probes
        .iter()
        .map(|probe| {
            format!(
                "{}:t{}s{}",
                probe.letter, probe.drive_type, probe.subst as u8
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let mut volume_attempts = 0usize;
    let mut volume_unsupported = 0usize;
    for probe in &probes {
        if probe.drive_type <= 1 {
            continue;
        }
        if probe.fixed && !probe.subst {
            continue;
        }
        volume_attempts += 1;
        let path = format!("{}:\\", probe.letter);
        match observe_root(&path, &authority, AllocationPool::ActiveOwner) {
            Err(ObserveError::UnsupportedFile) => {
                volume_unsupported += 1;
            }
            Ok(_) => panic!(
                "non-fixed/subst {} type={} subst={} dos={:?} gle={} succeeded",
                probe.letter,
                probe.drive_type,
                probe.subst,
                probe.dos_device,
                probe.dos_device_gle
            ),
            Err(error) => recorded_os_skip(
                "subst-non-fixed-observe",
                &format!(
                    "{}: type={} subst={} dos={:?} gle={} observe={error:?}",
                    probe.letter,
                    probe.drive_type,
                    probe.subst,
                    probe.dos_device,
                    probe.dos_device_gle
                ),
            ),
        }
    }
    if volume_attempts == 0 {
        recorded_os_skip(
            "subst-non-fixed",
            &format!("A-Z scan found no subst/non-fixed volume to observe; types={volume_types}"),
        );
    } else {
        eprintln!(
            "TASK863 recorded OS row class=subst-non-fixed unsupported={volume_unsupported} attempts={volume_attempts} types={volume_types}"
        );
    }

    let (wide, utf16_create) = testing_create_unpaired_surrogate_directory(&japanese_path);
    if utf16_create.created {
        let converted =
            testing_os_utf16_final_path(&wide, &authority, AllocationPool::ActiveOwner);
        let _ = testing_remove_wide_directory(&wide);
        assert!(
            matches!(converted, Err(ObserveError::UnsupportedFile)),
            "GetFinalPathNameByHandleW units must fail lossless UTF-16: {converted:?}"
        );
    } else {
        recorded_os_skip(
            "os-utf16-non-lossless",
            &format!(
                "CreateDirectoryW unpaired surrogate GLE={}",
                utf16_create.last_error
            ),
        );
    }

    let junction_target = tree.child("junction-target");
    let junction = tree.root.join("junction-leaf");
    match mklink_junction(&junction, &junction_target) {
        Ok(()) => {
            let observed = observe_root(
                &TempTree::path_text(&junction),
                &authority,
                AllocationPool::ActiveOwner,
            );
            match observed {
                Err(ObserveError::UnsupportedFile) => {}
                Err(error) => panic!("leaf junction observe must be unsupported_file: {error:?}"),
                Ok(_) => panic!("leaf junction observe succeeded"),
            }
            let opened = value(&harness.owner(&request_t(
                "project.open",
                &inst,
                rereg["topology_revision"].as_u64().expect("rev"),
                json!({"path": TempTree::path_text(&junction)}),
            )));
            assert_eq!(
                opened["error"]["code"],
                json!("unsupported_file"),
                "{opened}"
            );
        }
        Err(reason) => recorded_os_skip("leaf-junction", &reason),
    }

    let ancestor_target = tree.child("ancestor-target");
    let ancestor_leaf = ancestor_target.join("leaf");
    fs::create_dir_all(&ancestor_leaf).expect("ancestor leaf");
    let ancestor_link = tree.root.join("ancestor-junc");
    match mklink_junction(&ancestor_link, &ancestor_target) {
        Ok(()) => {
            let through = ancestor_link.join("leaf");
            let opened = value(&harness.owner(&request_t(
                "project.open",
                &inst,
                rereg["topology_revision"].as_u64().expect("rev"),
                json!({"path": TempTree::path_text(&through)}),
            )));
            assert_eq!(
                opened["error"]["code"],
                json!("unsupported_file"),
                "ancestor junction via project.open: {opened}"
            );
        }
        Err(reason) => recorded_os_skip("ancestor-junction", &reason),
    }

    let denied = tree.child("acl-denied");
    let denied_path = TempTree::path_text(&denied);
    let user = std::env::var("USERNAME").unwrap_or_default();
    let deny = Command::new("icacls")
        .args([&denied_path, "/deny", &format!("{user}:(OI)(CI)(R)")])
        .output()
        .expect("icacls deny");
    if deny.status.success() {
        let opened = value(&harness.owner(&request_t(
            "project.open",
            &inst,
            rereg["topology_revision"].as_u64().expect("rev"),
            json!({"path": denied_path}),
        )));
        let restore = Command::new("icacls")
            .args([&denied_path, "/remove:d", &user])
            .output()
            .expect("icacls restore");
        assert!(
            restore.status.success(),
            "DACL restore failed: status={:?} stderr={}",
            restore.status,
            String::from_utf8_lossy(&restore.stderr)
        );
        let restored = observe_root(&denied_path, &authority, AllocationPool::ActiveOwner);
        assert!(
            restored.is_ok(),
            "DACL restore must allow observe: {:?}",
            restored.err()
        );
        assert_eq!(
            opened["error"]["code"],
            json!("permission_denied"),
            "ACL deny via project.open: {opened}"
        );
    } else {
        recorded_os_skip(
            "acl-deny",
            &format!(
                "icacls deny failed status={:?} stderr={}",
                deny.status,
                String::from_utf8_lossy(&deny.stderr)
            ),
        );
    }

    let share = tree.child("share-block");
    let share_path = TempTree::path_text(&share);
    let exclusive = exclusive_directory_hold(&share_path).expect("exclusive hold");
    let shared = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        rereg["topology_revision"].as_u64().expect("rev"),
        json!({"path": share_path}),
    )));
    drop(exclusive);
    assert_eq!(
        shared["error"]["code"],
        json!("runtime_failed"),
        "share violation via project.open: {shared}"
    );
    assert_eq!(
        shared["topology_revision"],
        json!(rereg["topology_revision"].as_u64().expect("rev"))
    );

    let missing = tree.child("missing-root");
    let missing_path = TempTree::path_text(&missing);
    let missing_open = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        rereg["topology_revision"].as_u64().expect("rev"),
        json!({"path": missing_path}),
    )));
    assert_eq!(missing_open["accepted"], json!(true), "{missing_open}");
    let missing_id = missing_open["result"]["data"]["project_id"]
        .as_str()
        .expect("missing id")
        .to_owned();
    let missing_rev = missing_open["topology_revision"].as_u64().expect("rev");
    fs::remove_dir_all(&missing).expect("delete registered root");
    let listed = value(&harness.owner(&request_q("project.list", Some(&inst), json!({}))));
    let missing_row = listed["result"]["data"]["projects"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["project_id"] == json!(missing_id))
        .expect("missing row");
    assert_eq!(missing_row["root_state"], json!("unavailable"), "{listed}");
    let selected = value(&harness.owner(&request_t(
        "project.select",
        &inst,
        missing_rev,
        json!({"project_id": missing_id}),
    )));
    assert_eq!(
        selected["error"]["code"],
        json!("target_not_found"),
        "{selected}"
    );
    assert_eq!(selected["topology_revision"], json!(missing_rev));

    let cs = tree.child("case-sensitive");
    let cs_path = TempTree::path_text(&cs);
    let cs_out = Command::new("fsutil")
        .args(["file", "setCaseSensitiveInfo", &cs_path, "enable"])
        .output()
        .expect("fsutil");
    if cs_out.status.success() {
        let opened = value(&harness.owner(&request_t(
            "project.open",
            &inst,
            missing_rev,
            json!({"path": cs_path}),
        )));
        assert_eq!(
            opened["error"]["code"],
            json!("unsupported_file"),
            "case-sensitive dir via project.open: {opened}"
        );
    } else {
        recorded_os_skip(
            "case-sensitive-dir",
            &format!(
                "fsutil setCaseSensitiveInfo failed status={:?} stdout={} stderr={}",
                cs_out.status,
                String::from_utf8_lossy(&cs_out.stdout),
                String::from_utf8_lossy(&cs_out.stderr)
            ),
        );
    }
    assert_eq!(fs::read(&marker).expect("disk"), b"keep-disk");
}

#[test]
fn atomic_project_grant_commit() {
    let tree = TempTree::new("grant");
    let one = tree.child("one");
    let two = tree.child("two");
    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);
    let first = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        0,
        json!({"path": TempTree::path_text(&one)}),
    )));
    assert_eq!(first["accepted"], json!(true), "{first}");
    let id_a = first["result"]["data"]["project_id"]
        .as_str()
        .expect("a")
        .to_owned();
    let second = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        first["topology_revision"].as_u64().expect("rev"),
        json!({"path": TempTree::path_text(&two)}),
    )));
    assert_eq!(second["accepted"], json!(true), "{second}");
    let id_b = second["result"]["data"]["project_id"]
        .as_str()
        .expect("b")
        .to_owned();
    let revision = second["topology_revision"].as_u64().expect("rev");

    let client = harness.connect("client.exe");
    let pending = client
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [id_a, id_b], "scopes": ["metadata", "control"]}),
        ))
        .expect("pending");
    assert_eq!(value(&pending)["accepted"], json!(true));
    let connection_id = value(&pending)["result"]["data"]["connection_id"]
        .as_str()
        .expect("cid")
        .to_owned();
    let allowed = harness.owner(&request_q(
        "connection.decide",
        Some(&inst),
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": [id_a, id_b],
            "scopes": ["metadata", "control"]
        }),
    ));
    assert_eq!(value(&allowed)["accepted"], json!(true), "{}", value(&allowed));

    let selected = harness.owner(&request_t(
        "project.select",
        &inst,
        revision,
        json!({"project_id": id_a}),
    ));
    assert_eq!(value(&selected)["accepted"], json!(true), "{}", value(&selected));
    let revision = value(&selected)["topology_revision"].as_u64().expect("rev");

    let forgotten = harness.owner(&request_t(
        "project.forget",
        &inst,
        revision,
        json!({"project_id": id_a}),
    ));
    let forgotten = value(&forgotten);
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");
    let listed = value(&harness.owner(&request_q("connection.list", Some(&inst), json!({}))));
    let grants = &listed["result"]["data"]["connections"][0]["granted_project_ids"];
    assert_eq!(grants, &json!([id_b]), "{listed}");
    let projects = value(&harness.owner(&request_q("project.list", Some(&inst), json!({}))));
    let ids: Vec<_> = projects["result"]["data"]["projects"]
        .as_array()
        .expect("rows")
        .iter()
        .map(|row| row["project_id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ids, vec![id_b.clone()]);
    assert_eq!(projects["result"]["data"]["selected_project_id"], Value::Null);

    let resurrect = client
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [id_a], "scopes": ["metadata"]}),
        ))
        .expect("old id");
    assert_eq!(value(&resurrect)["error"]["code"], json!("invalid_request"));

    let reopen = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        forgotten["topology_revision"].as_u64().expect("rev"),
        json!({"path": TempTree::path_text(&one)}),
    )));
    assert_eq!(reopen["accepted"], json!(true), "{reopen}");
    let new_id = reopen["result"]["data"]["project_id"].as_str().unwrap().to_owned();
    assert_ne!(new_id, id_a);
    let listed = value(&harness.owner(&request_q("connection.list", Some(&inst), json!({}))));
    assert_eq!(
        listed["result"]["data"]["connections"][0]["granted_project_ids"],
        json!([id_b])
    );

    harness
        .authorization()
        .testing_set_occupancy(&ProjectId::new(&id_b).expect("b"), true, false);
    let busy = value(&harness.owner(&request_t(
        "project.forget",
        &inst,
        reopen["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": id_b}),
    )));
    assert_eq!(busy["error"]["code"], json!("already_running"), "{busy}");
    harness
        .authorization()
        .testing_set_occupancy(&ProjectId::new(&id_b).expect("b"), false, true);
    let reserved = value(&harness.owner(&request_t(
        "project.forget",
        &inst,
        reopen["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": id_b}),
    )));
    assert_eq!(
        reserved["error"]["code"],
        json!("operation_conflict"),
        "{reserved}"
    );
    harness
        .authorization()
        .testing_set_occupancy(&ProjectId::new(&id_b).expect("b"), false, false);

    let path = TempTree::path_text(&two);
    let concurrent_revision = reopen["topology_revision"].as_u64().expect("rev");
    let threads = (0..2)
        .map(|_| {
            let harness = harness.clone();
            let inst = inst.clone();
            let path = path.clone();
            std::thread::spawn(move || {
                harness.owner(&request_t(
                    "project.open",
                    &inst,
                    concurrent_revision,
                    json!({"path": path}),
                ))
            })
        })
        .collect::<Vec<_>>();
    let results: Vec<_> = threads
        .into_iter()
        .map(|thread| value(&thread.join().expect("join")))
        .collect();
    assert!(results.iter().all(|row| row["accepted"] == json!(true)), "{results:?}");
    let ids: Vec<_> = results
        .iter()
        .map(|row| row["result"]["data"]["project_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids[0], ids[1]);

    let selected_a = value(&harness.owner(&request_t(
        "project.select",
        &inst,
        reopen["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": id_b}),
    )));
    assert_eq!(selected_a["accepted"], json!(true), "{selected_a}");
    let selected_before = harness
        .authorization()
        .testing_selected()
        .expect("selected");
    harness.set_event_seq_to_max();
    let exhausted_select = value(&harness.owner(&request_t(
        "project.select",
        &inst,
        selected_a["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": new_id}),
    )));
    assert_eq!(
        exhausted_select["error"]["code"],
        json!("resource_exhausted"),
        "{exhausted_select}"
    );
    assert_eq!(
        harness.authorization().testing_selected().as_ref(),
        Some(&selected_before),
        "select must not mutate before counter/capacity preflight"
    );
    assert_eq!(
        exhausted_select["topology_revision"],
        selected_a["topology_revision"]
    );
    assert_eq!(harness.event_seq(), MAX_SAFE_INTEGER);

    let host = ProductHost::start(Vec::new()).expect("product host");
    host.set_event_seq_to_max();
    let inst = serde_json::to_value(host.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("host instance");
    let saturated = host
        .owner_request(&request_t(
            "project.open",
            &inst,
            0,
            json!({"path": TempTree::path_text(&one)}),
        ))
        .expect("saturated open");
    let saturated = value(&saturated);
    assert_eq!(
        saturated["error"]["code"],
        json!("resource_exhausted"),
        "create at MAX_SAFE_INTEGER event_seq must refuse without wrap: {saturated}"
    );
    host.shutdown().expect("join");
}

#[test]
fn send_forget_ticket_and_queued_owner_matrix() {
    let tree = TempTree::new("send-forget");
    let folder_a = tree.child("a");
    let folder_b = tree.child("b");
    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);
    let open_a = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        0,
        json!({"path": TempTree::path_text(&folder_a)}),
    )));
    let open_b = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        open_a["topology_revision"].as_u64().expect("rev"),
        json!({"path": TempTree::path_text(&folder_b)}),
    )));
    let id_a = open_a["result"]["data"]["project_id"]
        .as_str()
        .expect("a")
        .to_owned();
    let id_b = open_b["result"]["data"]["project_id"]
        .as_str()
        .expect("b")
        .to_owned();
    let rev = open_b["topology_revision"].as_u64().expect("rev");

    let client = harness.connect("owner-actor.exe");
    let real_cid = client.connection_id();
    let owner_request = value(&harness.owner(&request_q(
        "connection.request",
        Some(&inst),
        json!({"project_ids": [id_a], "scopes": ["metadata"]}),
    )));
    assert_eq!(
        owner_request["error"]["code"],
        json!("invalid_request"),
        "owner connection.request is InvalidRequest with a real public id in the fixture: {owner_request}"
    );
    let _ = real_cid.as_str();

    client
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [id_a, id_b], "scopes": ["metadata", "control"]}),
        ))
        .expect("pending");
    let decided = value(&harness.owner(&request_q(
        "connection.decide",
        Some(&inst),
        json!({
            "connection_id": client.connection_id().as_str(),
            "decision": "allow",
            "project_ids": [id_a, id_b],
            "scopes": ["metadata", "control"]
        }),
    )));
    assert_eq!(decided["accepted"], json!(true), "{decided}");

    let pending = harness.connect("fresh.exe");
    let pending_id = next_operation_id();
    let first_pending = pending
        .request(&parse_request(
            &serde_json::to_vec(&json!({
                "schema_version": 1,
                "instance_id": null,
                "operation_id": pending_id,
                "expected_topology_revision": null,
                "operation": "connection.request",
                "params": {"project_ids": [id_b], "scopes": ["metadata"]}
            }))
            .expect("json"),
        )
        .expect("pending request"))
        .expect("first pending");
    let stored_seq = value(&first_pending)["event_seq"].as_u64().expect("seq");
    let bump = harness.connect("bump.exe");
    bump.request(&request_q(
        "connection.request",
        None,
        json!({"project_ids": [id_a], "scopes": ["metadata"]}),
    ))
    .expect("unrelated pending");
    let unrelated = value(&harness.owner(&request_q(
        "connection.decide",
        Some(&inst),
        json!({
            "connection_id": bump.connection_id().as_str(),
            "decision": "allow",
            "project_ids": [id_a],
            "scopes": ["metadata"]
        }),
    )));
    assert_eq!(unrelated["accepted"], json!(true), "{unrelated}");
    let current_seq = harness.authorization().testing_counters().0;
    assert!(current_seq > stored_seq, "unrelated T must bump event_seq");
    let replay_pending = pending
        .request(&parse_request(
            &serde_json::to_vec(&json!({
                "schema_version": 1,
                "instance_id": null,
                "operation_id": pending_id,
                "expected_topology_revision": null,
                "operation": "connection.request",
                "params": {"project_ids": [id_b], "scopes": ["metadata"]}
            }))
            .expect("json"),
        )
        .expect("replay request"))
        .expect("same-id replay");
    assert_eq!(
        value(&replay_pending)["event_seq"].as_u64().expect("seq"),
        stored_seq
    );
    let fresh_id = next_operation_id();
    let fresh = pending
        .request(&parse_request(
            &serde_json::to_vec(&json!({
                "schema_version": 1,
                "instance_id": null,
                "operation_id": fresh_id,
                "expected_topology_revision": null,
                "operation": "connection.request",
                "params": {"project_ids": [id_b], "scopes": ["metadata"]}
            }))
            .expect("json"),
        )
        .expect("fresh request"))
        .expect("fresh id");
    assert_eq!(
        value(&fresh)["event_seq"].as_u64().expect("seq"),
        current_seq
    );

    let select_id = next_operation_id();
    let select_null = client
        .request(&request_tid(
            "project.select",
            &inst,
            &select_id,
            rev,
            json!({"project_id": null}),
        ))
        .expect("select null");
    let select_null = value(&select_null);
    assert_eq!(select_null["accepted"], json!(true), "{select_null}");
    let stored_select = harness
        .authorization()
        .testing_replay_receipt(&operation_id(&select_id))
        .expect("select receipt");
    let forget_a = value(&harness.owner(&request_t(
        "project.forget",
        &inst,
        select_null["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": id_a}),
    )));
    assert_eq!(forget_a["accepted"], json!(true), "{forget_a}");
    assert!(
        client
            .request(&request_tid(
                "project.select",
                &inst,
                &select_id,
                select_null["topology_revision"].as_u64().expect("rev"),
                json!({"project_id": null}),
            ))
            .is_none(),
        "public select-null replay after subset forget must not send"
    );
    let after = harness
        .authorization()
        .testing_replay_receipt(&operation_id(&select_id))
        .expect("unchanged receipt");
    assert_eq!(after.phase, stored_select.phase);
    assert_eq!(after.event_seq, stored_select.event_seq);
    assert_eq!(after.topology_revision, stored_select.topology_revision);
    let snapshot = harness
        .authorization()
        .testing_connection_snapshot(&client.connection_id())
        .expect("snapshot");
    assert_eq!(snapshot.state, "granted");
    assert_eq!(snapshot.granted_project_ids, vec![id_b.clone()]);

    let decide_then_forget = harness.connect("queued.exe");
    decide_then_forget
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [id_b], "scopes": ["metadata"]}),
        ))
        .expect("queued pending");
    let allow = value(&harness.owner(&request_q(
        "connection.decide",
        Some(&inst),
        json!({
            "connection_id": decide_then_forget.connection_id().as_str(),
            "decision": "allow",
            "project_ids": [id_b],
            "scopes": ["metadata"]
        }),
    )));
    assert_eq!(allow["accepted"], json!(true), "{allow}");
    let after_allow = value(&harness.owner(&request_t(
        "project.forget",
        &inst,
        allow["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": id_b}),
    )));
    assert_eq!(after_allow["accepted"], json!(true), "{after_allow}");
    let replay_allow = value(&harness.owner(&parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": inst,
            "operation_id": allow["operation_id"],
            "expected_topology_revision": null,
            "operation": "connection.decide",
            "params": {
                "connection_id": decide_then_forget.connection_id().as_str(),
                "decision": "allow",
                "project_ids": [id_b],
                "scopes": ["metadata"]
            }
        }))
        .expect("json"),
    )
    .expect("replay decide")));
    assert_eq!(
        replay_allow["accepted"], json!(true),
        "owner decide receipt survives target removal: {replay_allow}"
    );

    let reopen_a = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        after_allow["topology_revision"].as_u64().expect("rev"),
        json!({"path": TempTree::path_text(&folder_a)}),
    )));
    let reopen_b = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        reopen_a["topology_revision"].as_u64().expect("rev"),
        json!({"path": TempTree::path_text(&folder_b)}),
    )));
    let new_a = reopen_a["result"]["data"]["project_id"]
        .as_str()
        .expect("new a")
        .to_owned();
    let new_b = reopen_b["result"]["data"]["project_id"]
        .as_str()
        .expect("new b")
        .to_owned();
    let listed = harness.connect("list.exe");
    let sibling = harness.connect("sibling.exe");
    listed
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [new_a, new_b], "scopes": ["metadata"]}),
        ))
        .expect("list pending");
    sibling
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [new_a], "scopes": ["metadata"]}),
        ))
        .expect("sibling pending");
    let list_rev = reopen_b["topology_revision"].as_u64().expect("rev");
    assert_eq!(
        value(&harness.owner(&request_q(
            "connection.decide",
            Some(&inst),
            json!({
                "connection_id": listed.connection_id().as_str(),
                "decision": "allow",
                "project_ids": [new_a, new_b],
                "scopes": ["metadata"]
            }),
        )))["accepted"],
        json!(true)
    );
    assert_eq!(
        value(&harness.owner(&request_q(
            "connection.decide",
            Some(&inst),
            json!({
                "connection_id": sibling.connection_id().as_str(),
                "decision": "allow",
                "project_ids": [new_a],
                "scopes": ["metadata"]
            }),
        )))["accepted"],
        json!(true)
    );

    let hold = PhaseHold::install_for(ProductPhase::SendGate, &listed.connection_id());
    let listed_thread = listed.clone();
    let inst_list = inst.clone();
    let worker = thread::spawn(move || {
        listed_thread.request(&request_q(
            "project.list",
            Some(&inst_list),
            json!({}),
        ))
    });
    hold.wait_entered();
    let forget_harness = harness.clone();
    let inst_forget = inst.clone();
    let forget_id = new_b.clone();
    let forget_rev = list_rev;
    let forget_thread = thread::spawn(move || {
        forget_harness.owner(&request_t(
            "project.forget",
            &inst_forget,
            forget_rev,
            json!({"project_id": forget_id}),
        ))
    });
    let sibling_list = sibling
        .request(&request_q("project.list", Some(&inst), json!({})))
        .expect("idle sibling list payload");
    let sibling_list = value(&sibling_list);
    assert_eq!(sibling_list["accepted"], json!(true), "{sibling_list}");
    assert!(
        sibling_list["result"]["data"]["projects"]
            .as_array()
            .expect("rows")
            .iter()
            .any(|row| row["project_id"] == json!(new_a)),
        "unaffected sibling must keep the other-project payload: {sibling_list}"
    );
    listed.wait_cancelled();
    hold.release_waiters();
    hold.clear();
    let stale = worker.join().expect("list thread");
    assert!(
        stale.is_none(),
        "affected list send must not deliver a stale projection"
    );
    let forgotten = value(&forget_thread.join().expect("forget thread"));
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");

    let host = ProductHost::start(Vec::new()).expect("product write_frame host");
    let inst_host = serde_json::to_value(host.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("host instance");
    let host_open_a = host
        .owner_request(&request_t(
            "project.open",
            &inst_host,
            0,
            json!({"path": TempTree::path_text(&folder_a)}),
        ))
        .expect("host open a");
    let host_open_a = value(&host_open_a);
    assert_eq!(host_open_a["accepted"], json!(true), "{host_open_a}");
    let host_a = host_open_a["result"]["data"]["project_id"]
        .as_str()
        .expect("host a")
        .to_owned();
    let host_open_b = host
        .owner_request(&request_t(
            "project.open",
            &inst_host,
            host_open_a["topology_revision"].as_u64().expect("rev"),
            json!({"path": TempTree::path_text(&folder_b)}),
        ))
        .expect("host open b");
    let host_open_b = value(&host_open_b);
    assert_eq!(host_open_b["accepted"], json!(true), "{host_open_b}");
    let host_b = host_open_b["result"]["data"]["project_id"]
        .as_str()
        .expect("host b")
        .to_owned();
    let listed_public = host.connect_authenticated().expect("listed public");
    let sibling_public = host.connect_authenticated().expect("sibling public");
    let pending_listed = listed_public
        .transact(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [host_a, host_b], "scopes": ["metadata"]}),
        ))
        .expect("listed pending");
    let listed_cid = ConnectionId::new(
        value(&pending_listed)["result"]["data"]["connection_id"]
            .as_str()
            .expect("listed cid")
            .to_owned(),
    )
    .expect("listed connection id");
    let pending_sibling = sibling_public
        .transact(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [host_a], "scopes": ["metadata"]}),
        ))
        .expect("sibling pending");
    let sibling_cid = value(&pending_sibling)["result"]["data"]["connection_id"]
        .as_str()
        .expect("sibling cid")
        .to_owned();
    assert_eq!(
        value(&host.decide_allow(
            listed_cid.as_str(),
            json!([host_a, host_b]),
            json!(["metadata"])
        ))["accepted"],
        json!(true)
    );
    assert_eq!(
        value(&host.decide_allow(&sibling_cid, json!([host_a]), json!(["metadata"])))["accepted"],
        json!(true)
    );

    {
        let dropped = WriteBodyHold::install_for(&listed_cid);
        drop(dropped);
    }
    let unparked = listed_public
        .transact(&request_q("project.list", Some(&inst_host), json!({})))
        .expect("drop must not park a later matching public response");
    assert_eq!(value(&unparked)["accepted"], json!(true), "{}", value(&unparked));

    let stale = WriteBodyHold::install_for(&listed_cid);
    let owner_unmatched = host
        .owner_request(&request_q("project.list", Some(&inst_host), json!({})))
        .expect("owner write_frame must ignore a public write-body identity");
    assert_eq!(
        value(&owner_unmatched)["accepted"],
        json!(true),
        "{}",
        value(&owner_unmatched)
    );
    let sibling_unmatched = sibling_public
        .transact(&request_q("project.list", Some(&inst_host), json!({})))
        .expect("sibling public identity must not match listed hold");
    assert_eq!(
        value(&sibling_unmatched)["accepted"],
        json!(true),
        "{}",
        value(&sibling_unmatched)
    );
    stale.clear();

    let hold = WriteBodyHold::install_for(&listed_cid);
    let listed_req = request_q("project.list", Some(&inst_host), json!({}));
    let worker = thread::spawn(move || listed_public.transact(&listed_req));
    hold.wait_header_written();
    let owner_while_held = host
        .owner_request(&request_q("project.list", Some(&inst_host), json!({})))
        .expect("owner command/response must continue while matching public header is held");
    let owner_while_held = value(&owner_while_held);
    assert_eq!(owner_while_held["accepted"], json!(true), "{owner_while_held}");
    let sibling_while_held = sibling_public
        .transact(&request_q("project.list", Some(&inst_host), json!({})))
        .expect("unrelated public connection must continue");
    let sibling_while_held = value(&sibling_while_held);
    assert_eq!(
        sibling_while_held["accepted"],
        json!(true),
        "{sibling_while_held}"
    );
    assert!(
        sibling_while_held["result"]["data"]["projects"]
            .as_array()
            .expect("rows")
            .iter()
            .any(|row| row["project_id"] == json!(host_a)),
        "unaffected sibling payload must keep the other project: {sibling_while_held}"
    );
    let forget_rev = owner_while_held["topology_revision"].as_u64().expect("rev");
    let host = Arc::new(Mutex::new(host));
    let forget_host = host.clone();
    let forget_id = host_b.clone();
    let inst_forget = inst_host.clone();
    let forget_thread = thread::spawn(move || {
        forget_host
            .lock()
            .expect("product host")
            .owner_request(&request_t(
                "project.forget",
                &inst_forget,
                forget_rev,
                json!({"project_id": forget_id}),
            ))
    });
    hold.wait_cancelled();
    hold.release_body();
    hold.clear();
    let forgotten = forget_thread
        .join()
        .expect("forget join")
        .expect("forget response");
    assert_eq!(
        value(&forgotten)["accepted"],
        json!(true),
        "{}",
        value(&forgotten)
    );
    let listed_result = worker.join().expect("listed join");
    assert!(
        listed_result.is_err(),
        "matching public partial write must not deliver a completed stale body: {listed_result:?}"
    );
    let host = Arc::into_inner(host)
        .expect("forget thread dropped")
        .into_inner()
        .expect("product host");
    host.shutdown().expect("join product write_frame host");
}

#[test]
fn observe_commit_generation_grant_and_alias_matrix() {
    let tree = TempTree::new("observe-commit");
    let folder = tree.child("held");
    let folder_path = TempTree::path_text(&folder);
    let sibling = tree.child("sibling");
    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);

    let open_id = next_operation_id();
    let hold = ObserveHold::install(&folder_path);
    let worker = {
        let harness = harness.clone();
        let inst = inst.clone();
        let path = folder_path.clone();
        let open_id = open_id.clone();
        std::thread::spawn(move || {
            harness.owner(&request_tid(
                "project.open",
                &inst,
                &open_id,
                0,
                json!({"path": path}),
            ))
        })
    };
    hold.wait_entered();
    assert_eq!(
        harness
            .authorization()
            .testing_replay_phase(&operation_id(&open_id)),
        Some("preparing")
    );
    harness.close_generation();
    hold.release_waiters();
    let closed = value(&worker.join().expect("join"));
    hold.clear();
    assert_eq!(closed["error"]["code"], json!("state_unknown"), "{closed}");
    assert_eq!(
        harness
            .authorization()
            .testing_replay_phase(&operation_id(&open_id)),
        Some("done")
    );
    assert!(harness.generation_is_closed());

    let harness = Harness::new(Vec::new());
    let inst = instance(&harness);
    let first = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        0,
        json!({"path": folder_path}),
    )));
    assert_eq!(first["accepted"], json!(true), "{first}");
    let id_a = first["result"]["data"]["project_id"]
        .as_str()
        .expect("a")
        .to_owned();
    let second = value(&harness.owner(&request_t(
        "project.open",
        &inst,
        first["topology_revision"].as_u64().expect("rev"),
        json!({"path": TempTree::path_text(&sibling)}),
    )));
    assert_eq!(second["accepted"], json!(true), "{second}");
    let id_b = second["result"]["data"]["project_id"]
        .as_str()
        .expect("b")
        .to_owned();
    let revision = second["topology_revision"].as_u64().expect("rev");
    let client = harness.connect("observe.exe");
    let pending = client
        .request(&request_q(
            "connection.request",
            None,
            json!({"project_ids": [id_a, id_b], "scopes": ["metadata", "control"]}),
        ))
        .expect("pending");
    let connection_id = value(&pending)["result"]["data"]["connection_id"]
        .as_str()
        .expect("cid")
        .to_owned();
    assert_eq!(
        value(&harness.owner(&request_q(
            "connection.decide",
            Some(&inst),
            json!({
                "connection_id": connection_id,
                "decision": "allow",
                "project_ids": [id_a, id_b],
                "scopes": ["metadata", "control"]
            }),
        )))["accepted"],
        json!(true)
    );

    let select_id = next_operation_id();
    let hold = ObserveHold::install(&folder_path);
    let worker = {
        let client = client.clone();
        let inst = inst.clone();
        let id_a = id_a.clone();
        let select_id = select_id.clone();
        std::thread::spawn(move || {
            client.request(&request_tid(
                "project.select",
                &inst,
                &select_id,
                revision,
                json!({"project_id": id_a}),
            ))
        })
    };
    hold.wait_entered();
    let forgotten = value(&harness.owner(&request_t(
        "project.forget",
        &inst,
        revision,
        json!({"project_id": id_a}),
    )));
    assert_eq!(forgotten["accepted"], json!(true), "{forgotten}");
    hold.release_waiters();
    let raced = worker.join().expect("join").expect("select finished after observe");
    hold.clear();
    let raced = value(&raced);
    assert_eq!(
        raced["error"]["code"],
        json!("stale_topology"),
        "forget during observe bumps topology; select must seal stale_topology without applying: {raced}"
    );
    assert_ne!(
        harness
            .authorization()
            .testing_selected()
            .as_ref()
            .map(ProjectId::as_str),
        Some(id_a.as_str())
    );
    let listed = value(&harness.owner(&request_q("connection.list", Some(&inst), json!({}))));
    assert_eq!(
        listed["result"]["data"]["connections"][0]["granted_project_ids"],
        json!([id_b]),
        "{listed}"
    );

    let idle = harness.connect("idle.exe");
    idle.request(&request_q(
        "connection.request",
        None,
        json!({"project_ids": [id_b], "scopes": ["metadata"]}),
    ))
    .expect("idle pending");
    assert!(idle.send_if_current());

    let same_null = value(&harness.owner(&request_t(
        "project.select",
        &inst,
        forgotten["topology_revision"].as_u64().expect("rev"),
        json!({"project_id": null}),
    )));
    assert_eq!(same_null["accepted"], json!(true), "{same_null}");
    let after_null = same_null["topology_revision"].as_u64().expect("rev");
    let again_null = value(&harness.owner(&request_t(
        "project.select",
        &inst,
        after_null,
        json!({"project_id": null}),
    )));
    assert_eq!(again_null["accepted"], json!(true), "{again_null}");
    assert_eq!(again_null["topology_revision"], json!(after_null));

    match short_path_name(&TempTree::path_text(&sibling)) {
        Some(short) => {
            let before = harness.authorization().testing_alias_charge_count();
            let alias_open = value(&harness.owner(&request_t(
                "project.open",
                &inst,
                after_null,
                json!({"path": short}),
            )));
            assert_eq!(alias_open["accepted"], json!(true), "{alias_open}");
            assert_eq!(alias_open["result"]["data"]["created"], json!(false));
            assert_eq!(alias_open["result"]["data"]["project_id"], json!(id_b));
            let live = harness.authorization().testing_alias_charge_count();
            assert!(
                live > before,
                "alias CapacityCharge must remain on the live record: before={before} live={live}"
            );
            let forget_b = value(&harness.owner(&request_t(
                "project.forget",
                &inst,
                alias_open["topology_revision"].as_u64().expect("rev"),
                json!({"project_id": id_b}),
            )));
            assert_eq!(forget_b["accepted"], json!(true), "{forget_b}");
            assert_eq!(
                harness.authorization().testing_alias_charge_count(),
                0,
                "forget must drop alias charges with the project record"
            );
        }
        None => recorded_os_skip(
            "alias-charge-8.3",
            "no distinct 8.3 name; alias CapacityCharge cannot be exercised through a non-alias path",
        ),
    }
    let _ = Duration::from_millis(0);
    let _ = RETAINED_BYTES;
}
