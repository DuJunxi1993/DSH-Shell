//! Configuration types and persistence.
//!
//! Mirrors dsh-swiftUI's `settings.json` schema 1:1.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

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

/// The page-zoom ladder: 50–200 in 10% steps, 16 rungs.
///
/// Deliberately identical to `ZoomLadder` in the macOS shell, which is where the
/// ladder actually lives conceptually — one ladder, two implementations that must
/// agree. A ladder written down twice is a ladder that disagrees with itself the
/// first time either copy is edited, and the symptom is a menu offering a 130%
/// that nothing can produce.
///
/// **The ceiling is 200, not 100.** It was 100 on both sides, and nothing was
/// defending it. Measured against real dsh with the macOS probe (`--zoom`): 200%
/// costs nothing but a narrower CSS viewport, which crosses dsh's ≤900px and
/// ≤700px breakpoints with no page errors and no horizontal overflow. So a dsh at
/// 200% boots clean and reflows into its narrow layout, which is the honest trade
/// — past ~150% you are choosing to read dsh as a small window, not making it
/// bigger. Capping at 100% did not prevent that, it just denied a choice that
/// turns out to be available and safe. 200 is the point where the ≤700px layout
/// takes over and further zooming only makes it smaller.
pub const ZOOM_MIN: u8 = 50;
pub const ZOOM_MAX: u8 = 200;
pub const ZOOM_STEP: u8 = 10;
pub const ZOOM_DEFAULT: u8 = 100;

/// Every rung, ascending.
///
/// Exists so the caption menu cannot drift from the ladder: it enumerates this
/// rather than writing out its own percentages, which is how a menu ends up
/// offering a zoom level `zoom_step` could never produce. The macOS shell has the
/// identical helper in `ZoomLadder.rungs`, for the identical reason.
///
/// A `Vec` rather than an iterator because this crosses into JavaScript, which
/// wants an array, and because a 16-element ladder is not worth being clever about.
pub fn zoom_rungs() -> Vec<u8> {
    (0..=(u16::from(ZOOM_MAX - ZOOM_MIN) / u16::from(ZOOM_STEP)))
        .map(|i| ZOOM_MIN + i as u8 * ZOOM_STEP)
        .collect()
}

/// Snap an arbitrary value onto the ladder.
///
/// Snapping rather than rejecting is deliberate: a hand-edited 57 should behave
/// like 60, not like an error the user cannot see.
pub fn normalize_zoom(value: u8) -> u8 {
    if value < ZOOM_MIN {
        return ZOOM_MIN;
    }
    if value > ZOOM_MAX {
        return ZOOM_MAX;
    }
    let offset = value - ZOOM_MIN;
    let steps = ZOOM_MAX - ZOOM_MIN;
    let snapped = ZOOM_MIN + (offset + ZOOM_STEP / 2) / ZOOM_STEP * ZOOM_STEP;
    snapped.min(steps + ZOOM_MIN)
}

/// The rung one step away from `current`, in `direction`.
///
/// `current` is a `f64` because the page measures its zoom as
/// `devicePixelRatio / osScale`, which is rarely on the ladder: Chromium keeps
/// whatever zoom it was last given, and `Ctrl`+`+` lands on rungs of its own.
/// `normalize_zoom` would round to the *nearest* rung, which is the wrong
/// question — the user asked for a direction.
///
/// The rule is floor for `-` and ceil for `+`, so from 137% shrink goes to 130%
/// and enlarge goes to 140%, each exactly one rung. A value already on a rung has
/// floor and ceil both equal to itself, so it needs one step added explicitly;
/// that is what makes repeated presses walk the ladder instead of stalling on
/// every other click.
///
/// This was computed in JavaScript until the ladder was moved here, and the JS
/// version rounded first and *then* added the direction — which double-counted
/// whenever the two disagreed, so from 125% an enlarge landed on 150% and skipped
/// 130. Keeping the arithmetic in Rust is also what gives `ZOOM_MIN`/`ZOOM_MAX`/
/// `ZOOM_STEP` a single owner instead of a second copy in the injected script
/// that could drift.
pub fn zoom_ladder_step(current: f64, direction: i32) -> u8 {
    // NaN and infinities come out of a dpr that has not settled yet. Treat them
    // as "unknown" and step from 100% rather than propagating into a cast, which
    // in Rust saturates to 0 and would send the user to the floor.
    let here = if current.is_finite() && current > 0.0 {
        current.clamp(f64::from(ZOOM_MIN), f64::from(ZOOM_MAX))
    } else {
        100.0
    };

    let min = i32::from(ZOOM_MIN);
    let max = i32::from(ZOOM_MAX);
    let step = i32::from(ZOOM_STEP);
    // Kept in integer percent so the floor/ceil is exact: on the f64 ladder,
    // 130/10 lands on 12.999999999999998 in binary and floors to 12.
    let here = here.round() as i32;
    let offset = here - min;

    let target = match direction.cmp(&0) {
        std::cmp::Ordering::Less => {
            let rung = offset.div_euclid(step);
            if offset.rem_euclid(step) == 0 {
                rung - 1
            } else {
                rung
            }
        }
        // Ceil, and +1 for both cases: an exact rung ceils to itself and then
        // moves on; anything else ceils to the rung above it, which is the same
        // +1 from `div_euclid`. Written as one expression because the two
        // branches are identical, and a `rem_euclid` check here would suggest a
        // distinction that does not exist.
        std::cmp::Ordering::Greater => offset.div_euclid(step) + 1,
        // No direction: snap to the nearest rung and stay there.
        std::cmp::Ordering::Equal => (offset + step / 2).div_euclid(step),
    };

    (min + target * step).clamp(min, max) as u8
}

/// How many times dsh may be restarted after crashing before the shell gives up.
///
/// A bound is the whole point. A dsh that cannot start — a broken binary, a port
/// somebody else owns, a profile that will not load — would otherwise be spawned
/// forever, one crash per attempt, which is a fork bomb with a user interface.
pub const MAX_RESTARTS: u32 = 3;

/// How long to wait before restart number `attempt` (0-based).
///
/// Exponential, because the failures that repeat are usually the slow ones: a
/// plugin Loader that needs ten seconds will fail again immediately if asked
/// again instantly. Capped, because the alternative is a wait that grows without
/// bound and an app that has stopped trying while looking alive.
pub fn restart_backoff(attempt: u32) -> Duration {
    match attempt {
        0 => Duration::from_secs(2),
        1 => Duration::from_secs(4),
        _ => Duration::from_secs(8),
    }
}

/// How long dsh must stay up before a later crash counts as a new failure.
///
/// Without this the budget is spent once per *session* rather than once per
/// *outage*: three crashes spread across a day would exhaust it, and a dsh that
/// crashed at lunchtime and again at nine would not be retried the second time.
pub const HEALTHY_AFTER: Duration = Duration::from_secs(60);

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
    /// Page zoom, 50–200 in 10% steps. Mirrors `zoomPercent` in the macOS shell.
    ///
    /// This is the **only** record of the intended zoom, and it is what the caption
    /// menu's radio check is drawn from. Nothing tries to read the zoom back out of
    /// the page: WebView2 has no getter, Tauri exposes only `set_zoom`, and the one
    /// inference available — `devicePixelRatio` divided by the display's scale — was
    /// measured wrong twice on this machine before it was deleted (see
    /// `zoom_ladder_step`). The macOS shell makes the same choice for the same
    /// reason, in `ZoomDecision`: the shell knows what it decided, and cannot know
    /// what the webview or a pinch did.
    ///
    /// What happens when the two disagree is [`ZoomDecision`]'s question, mirrored
    /// in `main.rs::push_configured_zoom`.
    ///
    /// `#[serde(default)]` so a settings file written before this field existed
    /// still parses — the same guard as every other field here, and the reason this
    /// is not a tombstone.
    #[serde(default = "default_zoom_percent")]
    pub zoom_percent: u8,
}

fn default_zoom_percent() -> u8 {
    ZOOM_DEFAULT
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

    /// A settings file written before this field existed still parses, and keeps
    /// its port.
    ///
    /// This struct uses `deny_unknown_fields`, so *removing* the name outright
    /// would make such a file fail to parse, and `load_or_default` answers a
    /// parse failure with defaults — which would quietly hand the user a different
    /// port and launch mode. `#[serde(default)]` is what prevents that, and this
    /// is the test that would notice it being removed along with the field.
    #[test]
    fn a_settings_file_without_zoom_percent_still_loads() {
        let json = serde_json::json!({
            "dsh_binary_path": "C:/tools/dsh.cmd",
            "launch_mode": "spawn",
            "listen_host": "127.0.0.1",
            "preferred_port": 4455,
            "trusted_hosts": ["127.0.0.1"],
            "poll_interval_seconds": 0.5,
            "spawn_timeout_seconds": 60,
            "auto_restart_on_crash": true
        });
        let cfg: Config = serde_json::from_value(json).expect("an old settings file must parse");
        assert_eq!(cfg.preferred_port, 4455, "the port has to survive the parse");
        assert_eq!(
            cfg.zoom_percent, ZOOM_DEFAULT,
            "and the missing zoom falls back to the default rung"
        );
    }

    /// A stored zoom outside the ladder — hand-edited, or written by a build with
    /// a wider one — is snapped rather than refused.
    ///
    /// The same reason the macOS shell snaps: 57 should behave like 60, not fail to
    /// parse and take the user's port down with it.
    #[test]
    fn a_stored_zoom_off_the_ladder_is_snapped_on_load() {
        for (stored, want) in [(57, 60), (9, 50), (255, 200), (100, 100)] {
            let cfg = Config {
                zoom_percent: stored,
                ..Config::default()
            };
            assert_eq!(
                normalize_zoom(cfg.zoom_percent),
                want,
                "a stored {stored}% must land on {want}%"
            );
        }
    }

    /// The menu enumerates the ladder, so it cannot offer a rung `zoom_step` could
    /// never produce — and cannot miss one either, which is the other direction of
    /// the same drift.
    #[test]
    fn the_rungs_are_the_whole_ladder() {
        let rungs = zoom_rungs();
        assert_eq!(rungs.len(), 16, "50..200 by 10 is sixteen rungs");
        assert_eq!(rungs.first(), Some(&ZOOM_MIN));
        assert_eq!(rungs.last(), Some(&ZOOM_MAX));
        // Every rung is reachable from the one below it by a single step, which is
        // what makes `Ctrl`+`±` and the menu agree about what "next" means.
        for pair in rungs.windows(2) {
            assert_eq!(pair[1] - pair[0], ZOOM_STEP, "{pair:?} are not adjacent");
        }
        // And every rung above the floor is exactly what `zoom_step` produces from
        // the rung below it — which is the property that makes `Ctrl`+`±` and a
        // click on a menu item the same operation. The floor is excluded because
        // stepping *up* from the floor leaves it; there is no rung below it to
        // reach.
        for pair in rungs.windows(2) {
            let (below, above) = (pair[0], pair[1]);
            assert_eq!(
                zoom_ladder_step(f64::from(below), 1),
                above,
                "the ladder cannot step up from {below}% to {above}%"
            );
            assert_eq!(
                zoom_ladder_step(f64::from(above), -1),
                below,
                "the ladder cannot step down from {above}% to {below}%"
            );
        }
    }

    /// The reported bug, exactly: from a display that reads 125% while the real
    /// zoom is 100%, "放大" jumped to 150% and skipped the 130 rung.
    ///
    /// Reproduced verbatim so the arithmetic cannot regress into rounding-then-
    /// adding, which is how it got here.
    #[test]
    fn ladder_step_takes_exactly_one_rung_from_between_rungs() {
        assert_eq!(zoom_ladder_step(125.0, 1), 130);
        assert_eq!(zoom_ladder_step(125.0, -1), 120);
        assert_eq!(zoom_ladder_step(137.0, 1), 140);
        assert_eq!(zoom_ladder_step(137.0, -1), 130);
        // A value just past a rung still moves one, not two.
        assert_eq!(zoom_ladder_step(131.0, 1), 140);
        assert_eq!(zoom_ladder_step(131.0, -1), 130);
    }

    /// Repeated presses must walk the ladder and never stall on every other click.
    #[test]
    fn ladder_step_walks_from_a_rung() {
        assert_eq!(zoom_ladder_step(100.0, 1), 110);
        assert_eq!(zoom_ladder_step(100.0, -1), 90);
        assert_eq!(zoom_ladder_step(120.0, 1), 130);
        assert_eq!(zoom_ladder_step(120.0, -1), 110);

        let mut at = 100.0_f64;
        for _ in 0..5 {
            let next = f64::from(zoom_ladder_step(at, 1));
            assert_eq!(next, at + 10.0, "stepping up from {at} should be one rung");
            at = next;
        }
        assert_eq!(at, 150.0);
    }

    /// `Ctrl`+`+` held down, and the end of the ladder: both must stop rather than
    /// wrap or run off the end.
    #[test]
    fn ladder_step_clamps_at_both_ends() {
        assert_eq!(zoom_ladder_step(50.0, -1), 50);
        assert_eq!(zoom_ladder_step(50.0, 1), 60);
        assert_eq!(zoom_ladder_step(200.0, 1), 200);
        assert_eq!(zoom_ladder_step(200.0, -1), 190);
        assert_eq!(zoom_ladder_step(10.0, 1), 60);
        assert_eq!(zoom_ladder_step(10.0, -1), 50);
        assert_eq!(zoom_ladder_step(900.0, 1), 200);
        assert_eq!(zoom_ladder_step(900.0, -1), 190);
    }

    /// A dpr that has not settled reads as NaN or 0. `as i32` saturates those to
    /// 0, which would silently send the user to the floor.
    #[test]
    fn ladder_step_survives_an_unmeasured_zoom() {
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 0.0, -1.0] {
            assert_eq!(zoom_ladder_step(bad, 1), 110, "enlarge from {bad}");
            assert_eq!(zoom_ladder_step(bad, -1), 90, "shrink from {bad}");
        }
    }

    /// Every answer is a rung inside the ladder — the property that makes the
    /// menu's radio check meaningful.
    #[test]
    fn ladder_step_lands_on_a_rung() {
        for here in 50..=200 {
            for direction in [-1, 1] {
                let next = zoom_ladder_step(f64::from(here), direction);
                assert!(
                    (i32::from(ZOOM_MIN)..=i32::from(ZOOM_MAX)).contains(&i32::from(next)),
                    "{next} from {here} is off the ladder"
                );
                assert_eq!(
                    i32::from(next) % i32::from(ZOOM_STEP),
                    0,
                    "{next} from {here} is not a rung"
                );
            }
        }
    }

    /// The floor/ceil is done in integer percent on purpose: on the f64 ladder
    /// 130/10 is 12.999999999999998 and floors to 12, which would put "放大" from
    /// 120% on 120% — a key that silently does nothing.
    #[test]
    fn the_rounding_is_exact_on_every_rung() {
        for rung in zoom_rungs() {
            assert_eq!(
                zoom_ladder_step(f64::from(rung), 1),
                (rung + ZOOM_STEP).min(ZOOM_MAX),
                "enlarge from {rung}%"
            );
            assert_eq!(
                zoom_ladder_step(f64::from(rung), -1),
                rung.saturating_sub(ZOOM_STEP).max(ZOOM_MIN),
                "shrink from {rung}%"
            );
        }
    }

    #[test]
    fn the_restart_budget_is_finite() {
        // The property that matters: however long this runs, the number of spawns
        // is bounded. A dsh that cannot start must not become a fork bomb with a
        // UI. Both bounds are properties of the constant, so they are checked
        // where the compiler cannot fold them away.
        const _: () = assert!(MAX_RESTARTS > 0, "a zero budget never recovers at all");
        const _: () = assert!(
            MAX_RESTARTS <= 5,
            "past five attempts the user needs to see it, not have the app keep trying"
        );
    }

    #[test]
    fn the_restart_backoff_grows_then_stops() {
        // Exponential so a slow failure (a plugin Loader that needs ten seconds)
        // is not retried instantly, capped so the wait cannot grow without bound.
        let first = restart_backoff(0);
        let second = restart_backoff(1);
        let third = restart_backoff(2);
        assert!(second > first, "attempt 2 must wait longer than attempt 1");
        assert!(third > second, "attempt 3 must wait longer than attempt 2");
        // Everything past the third is the cap, not a longer delay.
        for attempt in 3..50 {
            assert_eq!(
                restart_backoff(attempt),
                third,
                "attempt {attempt} must not keep growing the wait"
            );
        }
    }

    #[test]
    fn the_restart_wait_never_exceeds_the_budget() {
        // The whole schedule has to fit inside a span a user will tolerate, or
        // the bound on the count buys nothing: three spawns spaced a minute apart
        // is not a recovery.
        let total: Duration = (0..MAX_RESTARTS).fold(Duration::ZERO, |sum, attempt| {
            sum + restart_backoff(attempt)
        });
        assert!(
            total <= Duration::from_secs(30),
            "the full retry schedule is {total:?}, which is too long to hold a window open"
        );
    }

    #[test]
    fn a_healthy_dsh_outlives_the_reset_window() {
        // The reset only helps if it fires before the budget is normally spent,
        // and does not fire so eagerly that a crash loop never gets to restart.
        assert!(
            HEALTHY_AFTER > Duration::from_secs(30),
            "a process that survives this long was working, not failing"
        );
    }
}
