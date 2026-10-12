//! Configuration types and persistence.
//!
//! Mirrors dsh-swiftUI's `settings.json` schema 1:1.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// How the shell should connect to a dsh instance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LaunchMode {
    /// Fork `dsh web` ourselves, capture URL, render into WebView.
    #[default]
    Spawn,
    /// Only connect to an already-running dsh; do not fork.
    Attach,
}

/// Zoom ladder. Kept as constants rather than baked into the UI so raising the
/// ceiling later is a one-line change, not a redesign of the control.
///
/// The ceiling is 200, matching `ZoomLadder` on the macOS shell. It was 100
/// there and here, and nothing was defending it: measured against real dsh
/// (`macos/tools/dsh-probe --zoom`), 200% costs nothing but a narrower CSS
/// viewport, which crosses dsh's ≤900px and ≤700px breakpoints without a single
/// page error or horizontal overflow. A cap that only ever denied a safe choice
/// is a cap worth raising.
pub const ZOOM_MIN: u8 = 50;
pub const ZOOM_MAX: u8 = 200;
pub const ZOOM_STEP: u8 = 10;
pub const ZOOM_DEFAULT: u8 = 100;

fn default_zoom_percent() -> u8 {
    ZOOM_DEFAULT
}

/// Snap an arbitrary value onto the supported zoom ladder.
///
/// Anything below the floor or above the ceiling is clamped rather than
/// rejected, because the value can arrive from a hand-edited settings file.
pub fn normalize_zoom(value: u8) -> u8 {
    if value < ZOOM_MIN {
        return ZOOM_MIN;
    }
    if value > ZOOM_MAX {
        return ZOOM_MAX;
    }
    // Snap to the nearest rung so a hand-written 57 behaves like 60.
    let offset = value - ZOOM_MIN;
    let steps = ZOOM_MAX - ZOOM_MIN;
    let snapped = ZOOM_MIN + (offset + ZOOM_STEP / 2) / ZOOM_STEP * ZOOM_STEP;
    snapped.min(steps + ZOOM_MIN)
}

/// The rung one `delta` away from `current`, clamped to the ladder.
///
/// `delta` is signed and comes from the page, so this cannot assume a keyboard's
/// worth of movement. Everything outside the ladder clamps to the nearest end -
/// including a delta that would take the sum below zero, which is why the sum is
/// done in `i32`. An earlier version returned the *default* when the sum
/// underflowed, so one oversized `Ctrl+-` from the page could jump the zoom to
/// 100% instead of leaving it at the floor.
pub fn next_zoom(current: u8, delta: i16) -> u8 {
    let target = i32::from(normalize_zoom(current)) + i32::from(delta);
    let clamped = target.clamp(i32::from(ZOOM_MIN), i32::from(ZOOM_MAX));
    normalize_zoom(clamped as u8)
}

/// The scale factor to hand the webview: 50 → 0.5.
pub fn zoom_scale(percent: u8) -> f64 {
    f64::from(normalize_zoom(percent)) / 100.0
}

/// Top-level configuration. Persisted as JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Absolute path to the `dsh` executable.
    pub dsh_binary_path: PathBuf,
    /// Spawn vs. attach mode.
    pub launch_mode: LaunchMode,
    /// Loopback host passed to `dsh web --host`.
    pub listen_host: String,
    /// Fixed port forwarded to `dsh web --port`. `0` = OS-assigned.
    ///
    /// 3080 is dsh's own default (`dsh-web-app`'s webserver row:
    /// `port: ctx.webStartup.port ?? 3080`), so this matches a normally started
    /// dsh and makes `attach` mode work out of the box.
    pub preferred_port: u16,
    /// Extra trusted hosts appended to `dsh web --trusted-host`.
    pub trusted_hosts: Vec<String>,
    /// Polling interval for port probe / endpoint resolution.
    pub poll_interval_seconds: f64,
    /// How long to wait for the URL line on stdout before probing the port.
    pub spawn_timeout_seconds: u64,
    /// Whether to restart dsh on unexpected child exit.
    pub auto_restart_on_crash: bool,
    /// WebView page zoom, in percent. See [`normalize_zoom`].
    ///
    /// `#[serde(default)]` is load-bearing, not decoration: this struct uses
    /// `deny_unknown_fields` and every other field is required, so a new
    /// required field would make an existing settings file fail to parse — and
    /// [`Config::load_or_default`] would then quietly discard the user's port
    /// and launch mode along with it.
    #[serde(default = "default_zoom_percent")]
    pub zoom_percent: u8,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            dsh_binary_path: default_dsh_binary_path(),
            launch_mode: LaunchMode::Spawn,
            listen_host: "127.0.0.1".to_string(),
            preferred_port: 3080,
            trusted_hosts: vec!["127.0.0.1".to_string(), "localhost".to_string()],
            poll_interval_seconds: 0.5,
            spawn_timeout_seconds: 60,
            auto_restart_on_crash: true,
            zoom_percent: ZOOM_DEFAULT,
        }
    }
}

impl Config {
    /// Resolve the configuration file path under the platform's data dir.
    pub fn config_path() -> Result<PathBuf, ConfigError> {
        let dirs = directories::ProjectDirs::from("ai", "deepseek", "dsh-shell")
            .ok_or(ConfigError::NoDataDir)?;
        Ok(dirs.config_dir().join("settings.json"))
    }

    /// Load from the default location, or return `Config::default()` if missing.
    ///
    /// A malformed file falls back to the defaults, which is the friendlier
    /// behaviour at runtime but destroys whatever the user had configured — so
    /// it is logged loudly rather than swallowed.
    pub fn load_or_default() -> Self {
        match Self::config_path() {
            Ok(path) if path.exists() => match Self::load_from(&path) {
                Ok(config) => config,
                Err(err) => {
                    tracing::warn!(
                        target: "dsh_shell",
                        "ignoring {}: {err}; falling back to defaults",
                        path.display()
                    );
                    Self::default()
                }
            },
            _ => Self::default(),
        }
    }

    /// Load from an explicit path. Returns an error if the file is malformed.
    pub fn load_from(path: &Path) -> Result<Self, ConfigError> {
        let raw = std::fs::read_to_string(path).map_err(ConfigError::Io)?;
        serde_json::from_str(&raw).map_err(ConfigError::Json)
    }

    /// Persist to the default location. Creates parent directories if missing.
    pub fn save(&self) -> Result<(), ConfigError> {
        let path = Self::config_path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(ConfigError::Io)?;
        }
        let serialized = serde_json::to_string_pretty(self).map_err(ConfigError::Json)?;
        std::fs::write(&path, serialized).map_err(ConfigError::Io)?;
        Ok(())
    }
}

/// Platform-default dsh binary path.
///
/// Prefers the npm-global shim that `npm i -g @deepseek-ai/dsh` writes, and
/// falls back to plain `dsh` on PATH so a non-npm install still works.
fn default_dsh_binary_path() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        // %APPDATA%\npm\dsh.cmd is the canonical npm-global install location.
        if let Some(appdata) = std::env::var_os("APPDATA") {
            let candidate = PathBuf::from(appdata).join("npm").join("dsh.cmd");
            if candidate.exists() {
                return candidate;
            }
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        if let Ok(home) = std::env::var("HOME") {
            // ~/.npm-global/bin/dsh is the safest global install (avoids /usr/local requiring sudo).
            let candidate = PathBuf::from(&home).join(".npm-global").join("bin").join("dsh");
            if candidate.exists() {
                return candidate;
            }
        }
    }
    PathBuf::from("dsh") // last-resort: rely on PATH
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("could not determine platform data directory")]
    NoDataDir,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialize/parse error: {0}")]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_serializes_round_trip() {
        let cfg = Config::default();
        let json = serde_json::to_string(&cfg).unwrap();
        let parsed: Config = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.preferred_port, cfg.preferred_port);
        assert_eq!(parsed.launch_mode, cfg.launch_mode);
    }

    #[test]
    fn load_or_default_when_missing() {
        // Just exercise the missing-file branch; do not write any real config.
        let cfg = Config::load_or_default();
        // dsh's own web default, so attach mode finds a running instance.
        assert_eq!(cfg.preferred_port, 3080);
    }

    #[test]
    fn zoom_clamps_to_the_ladder() {
        // Written against the ladder's ends, not against literal percentages:
        // the ceiling is deliberately raisable, and hardcoding it here made these
        // assert the old ladder rather than the rule.
        assert_eq!(normalize_zoom(0), ZOOM_MIN);
        assert_eq!(normalize_zoom(ZOOM_MIN - 1), ZOOM_MIN);
        assert_eq!(normalize_zoom(ZOOM_MIN), ZOOM_MIN);
        assert_eq!(normalize_zoom(u8::MAX), ZOOM_MAX);
    }

    #[test]
    fn the_ladder_spans_100_percent() {
        // 100% was the original ceiling and is now a rung in the middle of it. A
        // page value must survive normalization unchanged, or every window
        // rendered at the wrong scale after a restart.
        assert_eq!(normalize_zoom(100), 100);
        // The ceiling leaving room above 100% is a property of the ladder, not of
        // this test, so it is checked where it cannot be optimized away.
        const _: () = assert!(ZOOM_MAX > 100, "the ceiling must leave room above 100%");
    }

    #[test]
    fn zoom_snaps_to_the_nearest_step() {
        // A hand-edited 57 should behave like 60, not like some untested value.
        assert_eq!(normalize_zoom(54), 50);
        assert_eq!(normalize_zoom(55), 60);
        assert_eq!(normalize_zoom(57), 60);
        assert_eq!(normalize_zoom(95), 100);
    }

    #[test]
    fn zoom_ladder_is_evenly_divisible() {
        // A ladder that does not divide evenly would make the top or bottom rung
        // unreachable, which is a silently broken control.
        assert_eq!((ZOOM_MAX - ZOOM_MIN) % ZOOM_STEP, 0);
        assert_eq!(ZOOM_MIN % ZOOM_STEP, 0);
        assert_eq!(ZOOM_MAX % ZOOM_STEP, 0);
    }

    #[test]
    fn next_zoom_walks_the_ladder() {
        // Rung-to-rung from a mid-ladder value, and against the ends for the
        // clamps. A literal "90 + 10 is the top" silently stopped being true when
        // the ceiling moved, which is exactly the class of assertion that should
        // not survive a ladder change.
        //
        // The start is snapped to a rung first: an off-ladder midpoint would be
        // normalized on the way in, and the arithmetic would compare against a
        // value the caller never held.
        let mid = normalize_zoom(((u32::from(ZOOM_MIN) + u32::from(ZOOM_MAX)) / 2) as u8);
        assert_eq!(u32::from(mid) % u32::from(ZOOM_STEP), 0, "the midpoint must be a rung");
        assert_eq!(i32::from(next_zoom(mid, ZOOM_STEP as i16)), i32::from(mid) + i32::from(ZOOM_STEP));
        assert_eq!(
            i32::from(next_zoom(mid, -(ZOOM_STEP as i16))),
            i32::from(mid) - i32::from(ZOOM_STEP)
        );
        assert_eq!(next_zoom(mid, 0), mid);
    }

    #[test]
    fn next_zoom_stops_at_the_ends() {
        // Held at the floor or the ceiling, a key press must be a no-op rather
        // than a jump to the other end.
        assert_eq!(next_zoom(ZOOM_MIN, -10), ZOOM_MIN);
        assert_eq!(next_zoom(ZOOM_MAX, 10), ZOOM_MAX);
        assert_eq!(next_zoom(ZOOM_MIN, -1), ZOOM_MIN);
    }

    #[test]
    fn next_zoom_survives_an_oversized_delta() {
        // The page supplies this number, so it is not necessarily one step. A
        // delta that would take the sum negative must clamp to the floor: it used
        // to fall through to the default and jump the zoom to 100%.
        assert_eq!(next_zoom(50, -1000), ZOOM_MIN);
        assert_eq!(next_zoom(50, i16::MIN), ZOOM_MIN);
        assert_eq!(next_zoom(100, 1000), ZOOM_MAX);
        assert_eq!(next_zoom(100, i16::MAX), ZOOM_MAX);
        assert_eq!(next_zoom(50, 0), ZOOM_MIN);
    }

    #[test]
    fn next_zoom_starts_from_a_scrambled_current_value() {
        // A current value that is not on the ladder - a hand-edited settings file,
        // or a value that predates a ladder change - must not produce a rung that
        // is off the ladder.
        for current in [0u8, 37, 57, 99, 200, 255] {
            for delta in [-30i16, -10, -1, 0, 1, 10, 30] {
                let next = next_zoom(current, delta);
                assert!(
                    (ZOOM_MIN..=ZOOM_MAX).contains(&next),
                    "next_zoom({current}, {delta}) = {next} is off the ladder"
                );
                assert_eq!(
                    next % ZOOM_STEP,
                    0,
                    "next_zoom({current}, {delta}) = {next} is not a rung"
                );
            }
        }
    }

    #[test]
    fn zoom_scale_matches_percent() {
        assert!((zoom_scale(50) - 0.5).abs() < f64::EPSILON);
        assert!((zoom_scale(100) - 1.0).abs() < f64::EPSILON);
        assert!((zoom_scale(70) - 0.7).abs() < f64::EPSILON);
    }
}
