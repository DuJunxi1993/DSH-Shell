//! End-to-end-ish tests that exercise the config + endpoint logic without
//! requiring a real dsh binary.
//!
//! These tests are deterministic and do NOT spawn dsh.

use dsh_shell_core::config::{
    normalize_zoom, Config, LaunchMode, ZOOM_DEFAULT, ZOOM_MAX,
};
use std::path::PathBuf;

#[test]
fn default_config_matches_dsh_defaults() {
    let c = Config::default();
    // dsh's own web default (`dsh-web-app`'s webserver row), so a normally
    // started dsh is on this port and attach mode finds it.
    assert_eq!(c.preferred_port, 3080);
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
        zoom_percent: 60,
    };
    let json = serde_json::to_string(&original).unwrap();
    let parsed: Config = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed.preferred_port, 4040);
    assert_eq!(parsed.launch_mode, LaunchMode::Attach);
    assert_eq!(parsed.trusted_hosts.len(), 2);
    assert!(!parsed.auto_restart_on_crash);
    assert_eq!(parsed.zoom_percent, 60);
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

/// A settings file written before `zoom_percent` existed must keep parsing.
///
/// This is the failure mode `deny_unknown_fields` + required fields creates: a
/// newly added field would make the whole file unparseable, and since
/// `load_or_default` falls back to defaults, the user would silently lose their
/// port and launch mode. `zoom_percent` carries a serde default for exactly this
/// reason, and this test is what keeps it that way.
#[test]
fn a_settings_file_without_zoom_still_loads() {
    let older = r#"{
        "dsh_binary_path": "C:\\custom\\path\\dsh.cmd",
        "launch_mode": "attach",
        "listen_host": "127.0.0.1",
        "preferred_port": 4040,
        "trusted_hosts": ["127.0.0.1"],
        "poll_interval_seconds": 0.25,
        "spawn_timeout_seconds": 30,
        "auto_restart_on_crash": false
    }"#;

    let loaded: Config = serde_json::from_str(older).expect("must parse");

    // The new field takes its default...
    assert_eq!(loaded.zoom_percent, ZOOM_DEFAULT);
    // ...and nothing else is disturbed.
    assert_eq!(loaded.preferred_port, 4040);
    assert_eq!(loaded.launch_mode, LaunchMode::Attach);
    assert!(!loaded.auto_restart_on_crash);
}

#[test]
fn zoom_survives_a_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("settings.json");

    let cfg = Config {
        zoom_percent: 70,
        ..Config::default()
    };
    std::fs::write(&path, serde_json::to_string_pretty(&cfg).unwrap()).unwrap();

    let loaded = Config::load_from(&path).unwrap();
    assert_eq!(loaded.zoom_percent, 70);
    // An out-of-range value in the file is clamped on read, not propagated.
    let wild = Config {
        zoom_percent: 240,
        ..Config::default()
    };
    assert_eq!(normalize_zoom(wild.zoom_percent), ZOOM_MAX);
}
