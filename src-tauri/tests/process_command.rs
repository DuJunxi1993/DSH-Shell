//! Tests for `process::DshProcess::build_command` — ensures that the dsh CLI
//! flags we emit are correct, no orphan args, and we never invoke anything
//! that could spawn another shell.

use dsh_shell_core::config::{Config, LaunchMode};
use dsh_shell_core::process::DshProcess;

fn arg_strings(c: &Config) -> Vec<String> {
    let cmd = DshProcess::build_command(c);
    cmd.as_std()
        .get_args()
        .filter_map(|s| s.to_str().map(|s| s.to_string()))
        .collect()
}

#[test]
fn default_command_is_well_formed() {
    let c = Config::default();
    let args = arg_strings(&c);
    assert_eq!(args[0], "web");
    assert!(args.contains(&"--no-open".to_string()));
    assert!(args.contains(&"--host".to_string()));
    assert!(args.contains(&"127.0.0.1".to_string()));
    assert!(args.contains(&"--port".to_string()));
    assert!(args.contains(&"3080".to_string()));
    // No `--help`, no debug flags leaked.
    assert!(!args.contains(&"--help".to_string()));
}

#[test]
fn attach_mode_still_builds_a_command() {
    // The shell command is the same shape regardless of mode; `attach`
    // decides whether to actually spawn.
    let c = Config {
        launch_mode: LaunchMode::Attach,
        ..Config::default()
    };
    let args = arg_strings(&c);
    assert_eq!(args[0], "web");
    assert!(args.contains(&"--no-open".to_string()));
}

#[test]
fn trusted_hosts_are_repeated_for_each_value() {
    let c = Config {
        trusted_hosts: vec!["a".into(), "b".into(), "c".into()],
        ..Config::default()
    };
    let args = arg_strings(&c);
    let trusted_count = args.iter().filter(|a| *a == "--trusted-host").count();
    assert_eq!(trusted_count, 3);
}

#[test]
fn port_zero_omits_flag() {
    let c = Config {
        preferred_port: 0,
        ..Config::default()
    };
    let args = arg_strings(&c);
    assert!(!args.contains(&"--port".to_string()));
}

#[test]
fn child_will_not_itself_spawn_another_shell() {
    // The build_command target must be the literal `dsh` binary path;
    // it must never be `dsh-shell` or `dsh-shell.exe` — that would create
    // a self-recursion loop.
    let c = Config::default();
    let cmd = DshProcess::build_command(&c);
    let bin_name = cmd.as_std().get_program().to_string_lossy().to_string();
    assert!(
        !bin_name.contains("dsh-shell"),
        "build_command must not target dsh-shell itself; got {}",
        bin_name
    );
}