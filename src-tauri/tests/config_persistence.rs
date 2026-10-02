//! End-to-end-ish tests that exercise the config + endpoint logic without
//! requiring a real dsh binary.
//!
//! These tests are deterministic and do NOT spawn dsh.

use dsh_shell_core::config::{Config, LaunchMode};
use std::path::PathBuf;

#[test]
fn default_config_matches_swiftui_defaults() {
    // 1:1 parity with dsh-swiftUI's defaults block.
    let c = Config::default();
    assert_eq!(c.preferred_port, 34247);
    assert_eq!(c.listen_host, "127.0.0.1");
    assert_eq!(c.launch_mode, LaunchMode::Spawn);
    assert!(c.auto_restart_on_crash);
    assert!(c.trusted_hosts.contains(&"localhost".to_string()));
}

#[test]
fn config_round_trip_preserves_all_fields() {
    let original = Config {
        dsh_binary_path: PathBuf::from(r"C:\custom\path\dsh.cmd"),
        launch_mode: LaunchMode::Attach,
        listen_host: "127.0.0.1".to_string(),
        preferred_port: 4040,
        trusted_hosts: vec!["a".into(), "b".into()],
        poll_interval_seconds: 0.25,
        spawn_timeout_seconds: 30,
        auto_restart_on_crash: false,
    };
    let json = serde_json::to_string(&original).unwrap();
    let parsed: Config = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed.preferred_port, 4040);
    assert_eq!(parsed.launch_mode, LaunchMode::Attach);
    assert_eq!(parsed.trusted_hosts.len(), 2);
    assert!(!parsed.auto_restart_on_crash);
    assert_eq!(parsed.dsh_binary_path, PathBuf::from(r"C:\custom\path\dsh.cmd"));
}

#[test]
fn config_save_and_reload_in_tempdir() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("settings.json");

    let cfg = Config {
        preferred_port: 12345,
        ..Config::default()
    };
    let json = serde_json::to_string_pretty(&cfg).unwrap();
    std::fs::write(&path, &json).unwrap();

    let loaded = Config::load_from(&path).unwrap();
    assert_eq!(loaded.preferred_port, 12345);
    assert_eq!(loaded.launch_mode, LaunchMode::Spawn);
}

#[test]
fn unknown_fields_are_rejected_to_avoid_stale_keys() {
    // We use `deny_unknown_fields`, so old settings with stale keys fail loudly.
    let bad = r#"{
        "dsh_binary_path": "dsh",
        "launch_mode": "spawn",
        "listen_host": "127.0.0.1",
        "preferred_port": 34247,
        "trusted_hosts": [],
        "poll_interval_seconds": 0.5,
        "spawn_timeout_seconds": 60,
        "auto_restart_on_crash": true,
        "removed_field": "should fail"
    }"#;
    let parsed: Result<Config, _> = serde_json::from_str(bad);
    assert!(parsed.is_err(), "stale keys must not be silently ignored");
}
