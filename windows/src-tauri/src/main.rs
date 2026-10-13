//! dsh-shell entry point.
//!
//! Flow:
//!
//! 1. Start tracing. A release build has no console, so logs go to a daily
//!    rolling file under the app data dir.
//! 2. Show a window with a boot placeholder immediately, so a slow dsh start
//!    looks like progress rather than a hung app.
//! 3. Fork dsh off the UI thread and wait for the authenticated URL.
//! 4. Navigate the window to it.
//! 5. On exit, terminate dsh *before* the process goes away, and only ever by
//!    the PID we spawned.
//!
//! Step 5 is why `RunEvent::ExitRequested` is used instead of
//! `WindowEvent::CloseRequested`: the window event handler runs on the event
//! loop, where blocking on the async runtime to reap a child would deadlock the
//! very loop that has to service the exit.

#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;

mod toast;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, RunEvent, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use dsh_shell_core::chrome;
use dsh_shell_core::config::{self, Config};
use dsh_shell_core::error::ShellError;
use dsh_shell_core::navigate;
use dsh_shell_core::orphan;
use dsh_shell_core::platform;
use dsh_shell_core::preflight;
use dsh_shell_core::process::{self, DshProcess};

/// Hard ceiling on the exit path. Shutdown must never be able to wedge the app.
const SHUTDOWN_DEADLINE: Duration = Duration::from_secs(15);

/// Rust is invoked through `tauri::async_runtime::handle` from the chrome
/// script, so commands must be async.
type CommandResult<T> = Result<T, String>;

struct AppState {
    dsh: tokio::sync::Mutex<Option<DshProcess>>,
    /// PID of a dsh that has been spawned but is not yet owned by `dsh`, because
    /// `launch` has not returned yet.
    ///
    /// Without this, closing the window *during startup* orphans dsh: the exit
    /// handler finds `dsh == None`, has nothing to terminate, and exits the
    /// process while the spawn task is still in flight — so nothing ever runs
    /// `DshProcess::drop` and the harness keeps the port. Observed, not
    /// theoretical.
    starting_pid: AtomicU32,
    shutting_down: AtomicBool,
    /// Origin of the dsh page the window is allowed to navigate within, as
    /// `scheme://host:port`. Empty until dsh resolves, while only the local boot
    /// placeholder is reachable.
    dsh_origin: parking_lot::RwLock<String>,
}

/// Menu ids for the tray, so the click handler does not match on labels.
const TRAY_TOGGLE: &str = "toggle";
const TRAY_ZOOM_RESET: &str = "zoom-reset";
const TRAY_QUIT: &str = "quit";

/// Hide the window instead of closing it.
///
/// The window has no native caption, so this is what the title bar's ✕ does.
/// The process stays alive with dsh running, and the tray is the only way out —
/// which is why Alt+F4 is deliberately *not* routed here: it must still close
/// the window for real, so there is always an exit that does not require finding
/// the tray.
#[tauri::command]
async fn hide_to_tray(window: WebviewWindow) -> CommandResult<()> {
    window.hide().map_err(|err| format!("could not hide: {err}"))
}

/// Show and focus the window. Used by the tray, and by a second launch.
fn raise_window(app: &AppHandle) {
    let Some(window) = app.get_webview_window(MAIN_WINDOW) else {
        tracing::warn!(target: "dsh_shell", "no window to raise");
        return;
    };
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
    tracing::info!(target: "dsh_shell", "window raised");
}

fn main() {
    init_tracing();
    // Before anything creates a window or a webview: after that point the call
    // fails and the process stays DPI-unaware, which is what made every scale
    // query in this file report 1.0 on a 125% display.
    declare_dpi_awareness();

    let state = Arc::new(AppState {
        dsh: tokio::sync::Mutex::new(None),
        starting_pid: AtomicU32::new(0),
        shutting_down: AtomicBool::new(false),
        dsh_origin: parking_lot::RwLock::new(String::new()),
    });

    let app = match build(state.clone()) {
        Ok(app) => app,
        Err(err) => {
            write_crash_log(&format!("failed to start: {err}"));
            std::process::exit(1);
        }
    };

    app.run(move |app_handle, event| {
        match event {
            RunEvent::ExitRequested { api, .. } => {
                // Re-entrant: `exit()` below fires this event again, and that second
                // pass must fall through so the process can actually leave.
                if state.shutting_down.swap(true, Ordering::SeqCst) {
                    return;
                }
                api.prevent_exit();

                let state = state.clone();
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    let dsh = state.dsh.lock().await.take();
                    if let Some(dsh) = dsh {
                        if tokio::time::timeout(SHUTDOWN_DEADLINE, dsh.shutdown())
                            .await
                            .is_err()
                        {
                            tracing::warn!(target: "dsh_shell", "shutdown deadline reached; exiting anyway");
                        }
                    } else if let Some(pid) = nonzero_pid(&state) {
                        // Closed while dsh was still starting, or in the gap
                        // between `launch` returning and the process being
                        // stored: there is no DshProcess to drop, so the tree has
                        // to be terminated from the recorded PID or it outlives
                        // us and keeps the port.
                        tracing::warn!(
                            target: "dsh_shell",
                            "no owned dsh at exit; terminating recorded pid {pid}"
                        );
                        platform::terminate_tree_sync(pid);
                    } else {
                        tracing::info!(
                            target: "dsh_shell",
                            "no dsh running at exit; nothing to terminate"
                        );
                    }
                    tracing::info!(target: "dsh_shell", "dsh terminated; exiting");
                    // The port is the contract this whole repository exists to
                    // keep, so it is checked rather than assumed: if something is
                    // still listening after our own tree is gone, then either the
                    // tree kill missed a grandchild or an earlier run left one
                    // behind. Both are ours to clear, and both are cleared by the
                    // same rule that decides at start-up — a dsh with no living
                    // parent, running our own harness, on our own port. Anything
                    // else is left alone, including a dsh the operator started
                    // from a terminal.
                    let config = Config::load_or_default();
                    orphan::reclaim_orphan(&config, orphan::ReclaimReason::AtExit);
                    handle.exit(0);
                });
            }
            // Our own maximize/restore glyph has to track the real window state,
            // because the chrome is DOM and there is no native title bar to do it.
            RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::Resized(_),
                ..
            } if label == MAIN_WINDOW => {
                if let Some(window) = app_handle.get_webview_window(MAIN_WINDOW) {
                    let maximized = window.is_maximized().unwrap_or(false);
                    let script = format!(
                        "window.__DSH_SHELL_CHROME__ && window.__DSH_SHELL_CHROME__.setMaximized({maximized})"
                    );
                    let _ = window.eval(script);
                }
            }
            _ => {}
        }
    });
}

/// Record the child's PID the moment it exists, so the exit path can terminate
/// it even if the window closes before [`DshProcess`] is handed over.
///
/// `process::launch` only returns once the URL line arrives, which is seconds
/// after the spawn. Without this record, that gap is exactly where a closed
/// window leaves an orphan.
///
/// The record is deliberately **not** cleared here on success. It is cleared by
/// `point_at_dsh`, once the process is actually in `AppState` — clearing it at
/// the moment `launch` returns opens a second gap, between that return and the
/// store, where the exit path finds neither a `DshProcess` nor a PID and lets dsh
/// outlive the app. The invariant is: while we own, or are about to own, a dsh,
/// its PID is recorded.
async fn launch_recording_pid(
    state: &Arc<AppState>,
    config: Config,
) -> Result<process::DshProcess, ShellError> {
    let dsh = process::launch_with_pid_hook(config, move |pid| {
        state.starting_pid.store(pid, Ordering::SeqCst);
        tracing::info!(target: "dsh_shell", "dsh spawned as pid {pid}");
    })
    .await;
    if dsh.is_err() {
        // Nothing is running, so the record is dead weight.
        state.starting_pid.store(0, Ordering::SeqCst);
    }
    dsh
}

const MAIN_WINDOW: &str = "main";

/// The PID recorded for an in-flight spawn, if any.
fn nonzero_pid(state: &Arc<AppState>) -> Option<u32> {
    match state.starting_pid.swap(0, Ordering::SeqCst) {
        0 => None,
        pid => Some(pid),
    }
}

/// The display's scaling as a multiple of 96 DPI.
///
/// This is the denominator that turns the page's `devicePixelRatio` back into a
/// zoom: Chromium reports `dpr = system scale × page zoom`, and Tauri can read
/// neither factor, so the one it can read has to be baked in and handed over.
///
/// `GetDpiForSystem` is used rather than `primary_monitor().scale_factor()`
/// because the latter answers in the process's DPI awareness context, and a debug
/// run had none — so it reported 1.0 while the display was genuinely 120 DPI.
/// `declare_dpi_awareness` fixes that, and this API does not depend on it at all.
///
/// Falls back to 1.0 rather than 0: a wrong-but-usable scale makes the caption's
/// zoom readout off by a constant factor, whereas 0 would divide to nothing and
/// take the whole chrome down with it.
#[cfg(windows)]
fn system_dpi_scale() -> f64 {
    use windows::Win32::UI::HiDpi::GetDpiForSystem;
    let dpi = unsafe { GetDpiForSystem() };
    if dpi == 0 {
        1.0
    } else {
        f64::from(dpi) / 96.0
    }
}

#[cfg(not(windows))]
fn system_dpi_scale() -> f64 {
    1.0
}

/// Opt into per-monitor DPI awareness, before any window exists.
///
/// This is not a nicety. A DPI-*unaware* process is told the display is 96 DPI no
/// matter what it really is, and this process was one: `primary_monitor()`,
/// `window.scale_factor()` and `GetDpiForSystem()` all reported a scale of 1.0 on
/// a display whose real DPI was 119, while WebView2 — which does its own
/// awareness — rendered the page at `devicePixelRatio` 1.25.
///
/// That single wrong number made the caption's zoom readout lie by a constant
/// factor: it divided 1.25 by 1.0 and reported "125%" for a page that was at
/// 100%. Nothing crashed and nothing looked broken, which is why it survived
/// being written twice.
///
/// Must run before Tauri creates anything; afterwards the call fails with
/// `ERROR_ACCESS_DENIED`, which is harmless — the manifest already set awareness
/// for packaged builds — so the error is logged rather than treated as failure.
#[cfg(windows)]
#[cfg(windows)]
fn declare_dpi_awareness() {
    use windows::Win32::UI::HiDpi::{
        SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
    };
    if let Err(err) =
        unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
    {
        tracing::debug!(
            target: "dsh_shell",
            "per-monitor DPI awareness not set here ({err}); a manifest probably set it"
        );
    }
}

#[cfg(not(windows))]
fn declare_dpi_awareness() {}

/// The chrome script, with its geometry and the display's scale factor baked in.///
/// `initialization_script` is re-run on every navigation, so this covers both
/// the local boot placeholder and the remote dsh origin.
fn chrome_script(os_scale: f64) -> String {
    chrome::script(os_scale)
}

/// Set the page zoom to an absolute percentage.
///
/// Absolute rather than a delta, and that is the whole design: the hotkeys are
/// Chromium's, so we cannot know what the user last did to the zoom, and a
/// command that stepped from our own remembered value would drift away from the
/// real one the first time they pressed `Ctrl+=`. The page works it out instead -
/// `devicePixelRatio` over the system scale it is given - and asks for the rung
/// it wants. Rust's job is only to clamp it onto the ladder.
///
/// Nothing is persisted: WebView2 restores the last zoom per origin on its own.
#[tauri::command]
fn set_page_zoom(window: WebviewWindow, percent: u8) -> CommandResult<u8> {
    let next = config::normalize_zoom(percent);
    window
        .set_zoom(f64::from(next) / 100.0)
        .map_err(|err| format!("could not set zoom: {err}"))?;
    tracing::info!(target: "dsh_shell", "page zoom set to {next}%");
    Ok(next)
}

/// Back to 100%, from the tray.
fn reset_zoom(app: &AppHandle) {
    let Some(window) = app.get_webview_window(MAIN_WINDOW) else {
        return;
    };
    match set_page_zoom(window, config::ZOOM_DEFAULT) {
        Ok(percent) => tracing::info!(target: "dsh_shell", "zoom reset to {percent}% from the tray"),
        Err(err) => tracing::warn!(target: "dsh_shell", "zoom reset failed: {err}"),
    }
}

/// How long a page is given to answer the desktop contract before its silence is
/// worth a warning. Must match `CONTRACT_SETTLE_MS` in `platform_adapt.js`, which
/// is the side that decides; this is the side that trusts it.
const CONTRACT_SETTLE_MS: u64 = 5_000;

/// Report what the injected chrome managed to do.
///
/// Not decoration. The chrome lives inside a remote document we do not
/// control, so a future dsh release could remove the bar, restyle it, or wipe
/// it from the DOM — and a frameless window with no close button is a trap.
/// A one-line log turns that into a diagnosable event.
#[tauri::command]
fn chrome_report(report: ChromeReport) {
    if !report.installed || !report.still_present {
        tracing::warn!(
            target: "dsh_shell",
            "chrome FAILED to install (installed={}, still_present={}, ready_state={:?}, \
             origin={}) — this window has no title bar and no way to close it. {}",
            report.installed,
            report.still_present,
            report.ready_state,
            report.origin,
            report.boxes
        );
        return;
    }

    // The invariant, checked against the constants that live here rather than
    // in the script. The page multiplies its measurements by the zoom, so these
    // must come back as the design lengths. They did not once: dividing the
    // lengths *and* counter-scaling the clusters applied the correction twice,
    // and zooming out made the chrome grow. The pixel figures from that build
    // are not recoverable, and a comment asserting a number nothing checks is a
    // comment that will be edited into a lie; the round trip is the assertion,
    // and `chrome::tests` holds it.
    let expected = [
        ("bar height", report.measured_bar_h, chrome::BAR_H),
        // The window cluster is the whole reserved corner now that the zoom
        // control is gone, so one measurement covers both.
        (
            "reserved width",
            report.measured_win_w,
            chrome::reserved_width(),
        ),
    ];
    let wrong: Vec<String> = expected
        .iter()
        .filter(|(_, measured, want)| (measured - want).abs() > 0.5)
        .map(|(name, measured, want)| {
            format!("{name} measured {}px, expected {}px", round1(*measured), round1(*want))
        })
        .collect();

    // Whether dsh honoured the desktop contract. There is no geometric pass to
    // fall back to any more: when this is `contractMissing` the chrome is simply
    // not reserving the caption, which is a different and much plainer failure
    // than it used to be. It is logged explicitly so that a dsh which never
    // answers is visible rather than silent.
    if report.contract == "contractMissing" && report.contract_settled && !report.placeholder {
        tracing::warn!(
            target: "dsh_shell",
            "dsh did not answer the desktop contract ({}), and has had {}s to do it. \
             Nothing is reserving the caption, so the page's own top row runs under \
             the chrome. contract_top_clearance={:?}",
            report.origin,
            CONTRACT_SETTLE_MS / 1000,
            report.contract_top_clearance
        );
    }

    if wrong.is_empty() {
        tracing::info!(
            target: "dsh_shell",
            "chrome ok: origin={} bar={}px reserved={}px zoom={} placeholder={} \
             contract={} top_clearance={:?} notifications={} dpr={} os_scale={}",
            report.origin,
            round1(report.measured_bar_h),
            round1(report.measured_win_w),
            report.zoom,
            report.placeholder,
            report.contract,
            report.contract_top_clearance,
            report.notifications,
            round2(report.dpr),
            round2(report.os_scale)
        );
    } else {
        tracing::warn!(
            target: "dsh_shell",
            "chrome geometry is WRONG: {}. The 1/zoom correction must be applied exactly \
             once, in chrome::css_len. notifications={} {}",
            wrong.join("; "),
            report.notifications,
            report.boxes
        );
    }

    // The layout boxes are what you want when the chrome is present but
    // invisible: they distinguish "element is missing" from "element is there
    // but not painted", which a screenshot cannot.
    tracing::debug!(target: "dsh_shell", "chrome layout: {}", report.boxes);
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

/// Two decimals, for the scale factors. `dpr` and `os_scale` are thirds and
/// quarters more often than they are halves, and rounding them to one decimal
/// would print `1.6 / 1.2` for a division that is meant to come out exact.
fn round2(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

#[derive(serde::Deserialize)]
struct ChromeReport {
    installed: bool,
    /// Whether the bar was still in the document a moment after install, which
    /// is how a SPA that rewrites `<body>` shows up.
    still_present: bool,
    /// Bar height multiplied by the page zoom, i.e. in logical pixels. Compared
    /// against [`chrome::BAR_H`].
    measured_bar_h: f64,
    /// Window-button cluster width, multiplied by the page zoom. Compared
    /// against [`chrome::window_cluster_width`].
    measured_win_w: f64,
    zoom: f64,
    /// The page's `devicePixelRatio` as reported, and the system scale factor
    /// `zoom` was derived by dividing out. Both are logged so the caption's zoom
    /// percentage can be checked rather than taken on trust.
    dpr: f64,
    os_scale: f64,
    placeholder: bool,
    ready_state: String,
    origin: String,
    /// The page's `Notification.permission`, or `"absent"` when it is not there
    /// at all.
    ///
    /// The page's `Notification` is the notification plugin's shim rather than
    /// the browser's, and it forwards to this app over IPC, so this is really
    /// "did the ACL allow it". It matters because the refusal is invisible: a
    /// plugin that shows system notifications, dsh-notification included, checks
    /// this itself and gives up silently.
    notifications: String,
    /// Whether dsh honoured the desktop-host contract: `"contractActive"` when it
    /// reserves the caption itself, `"contractMissing"` when it does not.
    ///
    /// Logged explicitly because with no geometric pass there is nothing to look
    /// at instead: the window can look correct while nothing is reserving the
    /// caption, and the page's top row runs under the chrome.
    contract: String,
    /// dsh's published `--dsh-frame-top-clearance`, when it publishes one.
    contract_top_clearance: Option<f64>,
    /// Whether the page has been up long enough for dsh to have answered.
    ///
    /// dsh injects the contract's stylesheet about 1.4 s after load, so every
    /// report before that says `contractMissing`. Warning on those trains the
    /// reader to ignore the warning, which is the one thing a warning must not do
    /// — the case worth reporting is a dsh that *never* answers.
    contract_settled: bool,
    boxes: String,
}

/// A throw inside the injected script. Logged verbatim: it is the only record of
/// why the window has no title bar.
#[tauri::command]
fn chrome_error(message: String) {
    tracing::error!(target: "dsh_shell", "chrome script threw:\n{message}");
}

/// The tray icon and its menu.
///
/// The window has no native caption, so once the ✕ hides it this is the only
/// remaining way out. Left click raises the window because that is what a user
/// double-clicking a tray icon expects; the menu is on the right click, where a
/// menu is expected.
fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let toggle = MenuItem::with_id(app, TRAY_TOGGLE, "显示 / 隐藏", true, None::<&str>)?;
    let reset = MenuItem::with_id(app, TRAY_ZOOM_RESET, "缩放复位 100%", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, TRAY_QUIT, "退出（关闭 dsh）", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&toggle, &reset, &quit])?;

    // The window icon, so the tray does not need its own asset: it is the same
    // whale the app already ships.
    let mut tray = TrayIconBuilder::with_id("main").menu(&menu).tooltip("DSH Shell");
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.on_menu_event(|app, event| match event.id().as_ref() {
        TRAY_TOGGLE => toggle_window(app),
        TRAY_ZOOM_RESET => reset_zoom(app),
        TRAY_QUIT => {
            // The normal exit: ExitRequested runs the dsh tree kill.
            app.exit(0);
        }
        other => tracing::debug!(target: "dsh_shell", "unhandled tray item {other}"),
    })
    .on_tray_icon_event(|tray, event| {
        // Left click toggles. Right click is left to the platform so the menu
        // appears the way Windows users expect.
        if let TrayIconEvent::Click {
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
            ..
        } = event
        {
            toggle_window(tray.app_handle());
        }
    })
    .build(app)?;
    Ok(())
}

/// Show the window if it is hidden, hide it if it is shown. One place, because
/// the tray icon and the tray menu both mean the same thing by it.
fn toggle_window(app: &AppHandle) {
    let visible = app
        .get_webview_window(MAIN_WINDOW)
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false);
    if visible {
        if let Some(window) = app.get_webview_window(MAIN_WINDOW) {
            let _ = window.hide();
        }
    } else {
        raise_window(app);
    }
}

impl AppState {
    /// May the webview navigate here? The rule and the reason for it live in    /// [`navigate::is_internal`]; this only supplies the dsh origin, which is
    /// unknown until dsh has resolved.
    fn is_allowed_navigation(&self, url: &tauri::Url) -> bool {
        navigate::is_internal(url, &self.dsh_origin.read())
    }
}

/// Hand a URL to the system default browser.
fn open_externally(url: &tauri::Url) {
    if !navigate::is_openable(url) {
        tracing::warn!(
            target: "dsh_shell",
            "refused to open {url} externally: scheme is not http(s)"
        );
        return;
    }
    tracing::info!(target: "dsh_shell", "opening {url} in the default browser");
    if let Err(err) = tauri_plugin_opener::open_url(url.as_str(), None::<&str>) {
        tracing::warn!(target: "dsh_shell", "could not open {url}: {err}");
    }
}

fn build(state: Arc<AppState>) -> tauri::Result<tauri::App> {
    let setup_state = state.clone();
    let nav_state = state.clone();
    let new_window_state = state.clone();
    tauri::Builder::default()
        // A second launch raises the window that is already running instead of
        // starting a rival one - which would otherwise race dsh for the port and
        // fail with "port already in use". Registered before anything else so
        // there is no window in which two instances can both be alive.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            tracing::info!(target: "dsh_shell", "a second instance was launched; raising ours");
            raise_window(app);
        }))
        .plugin(tauri_plugin_opener::init())
        // Toast only, and only from Rust: the page never gets a notification
        // capability, because a dsh page has no business posting toasts as us.
        .plugin(tauri_plugin_notification::init())
        .manage(state)
        .setup(move |app| {
            build_tray(app)?;
            // The window's *system* DPI, not Tauri's idea of the monitor's scale
            // factor. `primary_monitor().scale_factor()` and even
            // `window.scale_factor()` both reported 1.0 on a 125% display while
            // WebView2 was rendering at 1.25 — the process is not per-monitor DPI
            // aware, so Windows virtualises every scale query it makes. That is
            // not cosmetic: this number is the denominator that turns
            // `devicePixelRatio` back into a page zoom, and getting it wrong made
            // the caption claim 125% when the zoom was 100%.
            //
            // `GetDpiForSystem` is documented as unaffected by the calling
            // process's awareness, which is exactly the property needed here.
            let os_scale = system_dpi_scale();
            tracing::info!(target: "dsh_shell", "display scale factor = {os_scale}");

            let chrome = chrome_script(os_scale);
            let page_load_chrome = chrome.clone();
            let window = WebviewWindowBuilder::new(app, MAIN_WINDOW, WebviewUrl::App("index.html".into()))
                .title("DSH Shell")
                .inner_size(1280.0, 800.0)
                .min_inner_size(800.0, 600.0)
                .resizable(true)
                .center()
                // No native title bar: the chrome is injected instead, so the dsh
                // sidebar can reach the top edge of the window. Wry still
                // hit-tests the window border, so edge resizing survives.
                .decorations(false)
                // Tauri replaces WebView2's drop handler, which is why files
                // cannot be dragged onto the dsh page. Hand drops back to the
                // page; it has its own drop target for the chat composer.
                .disable_drag_drop_handler()
                // Chromium's own zoom hotkeys. Written explicitly rather than
                // left to the default: the default is a `#[serde(default)]`
                // bool, which is false, and this used to be disabled on purpose
                // so the chrome could divide the zoom out. Now the chrome scales
                // with the page the way dsh's own content does, so the hotkeys are
                // wanted and the division is gone.
                .zoom_hotkeys_enabled(true)
                // Runs before any page script, on every navigation, so it cannot
                // be lost to a race with the SPA booting.
                .initialization_script(chrome.clone())
                .on_page_load(move |window, payload| {
                    // The initialization script above only reaches our own local
                    // boot page: dsh serves its own Content-Security-Policy, and
                    // a document-created injection is subject to it. `eval` comes
                    // from the host side, which is not, so the chrome for the
                    // real page is injected here instead. The script is
                    // idempotent, so running it on the placeholder too is a
                    // no-op.
                    if payload.event() != tauri::webview::PageLoadEvent::Finished {
                        return;
                    }
                    if let Err(err) = window.eval(page_load_chrome.clone()) {
                        tracing::error!(target: "dsh_shell", "could not inject chrome: {err}");
                    }
                })
                // Keep the webview on the page it is meant to be showing. dsh's
                // own routing is client-side and never reaches here, so the only
                // things that do are genuine external destinations: a link, or a
                // server-side redirect off dsh's origin. Letting either through
                // would replace the app's contents with someone else's website.
                .on_navigation(move |url| {
                    if nav_state.is_allowed_navigation(url) {
                        return true;
                    }
                    open_externally(url);
                    false
                })
                // `target="_blank"` and `window.open` would otherwise open a
                // second webview with no chrome, no tray and no dsh. Denied
                // either way, but only an external URL is worth passing on: a
                // dsh URL sent to the browser would have no token, and the index
                // answers 401 without one.
                .on_new_window(move |url, _features| {
                    if new_window_state.is_allowed_navigation(&url) {
                        tracing::warn!(
                            target: "dsh_shell",
                            "refused a second webview for our own {url}"
                        );
                    } else {
                        open_externally(&url);
                    }
                    tauri::webview::NewWindowResponse::Deny
                })
                .build()?;

            let state = setup_state.clone();
            tauri::async_runtime::spawn(async move {
                let config = Config::load_or_default();
                tracing::info!(
                    target: "dsh_shell",
                    "starting: mode={:?} port={} host={} binary={} auto_restart={} os_scale={os_scale}",
                    config.launch_mode,
                    config.preferred_port,
                    config.listen_host,
                    config.dsh_binary_path.display(),
                    config.auto_restart_on_crash,
                );

                supervise_dsh(&window, state, config).await;
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            hide_to_tray,
            set_page_zoom,
            chrome_report,
            chrome_error
        ])
        .build(tauri::generate_context!())
}

/// Launch dsh, point the window at it, and restart it a bounded number of times if
/// it crashes.
///
/// The counter resets once dsh has been up long enough to count as working. It
/// has to: a process that crashes after nine hours is a new failure, not a
/// continuation of the one that was fixed at lunchtime, and without the reset the
/// third crash of the morning would never be retried.
async fn supervise_dsh(window: &WebviewWindow, state: Arc<AppState>, config: Config) {
    let mut attempt: u32 = 0;
    loop {
        // Before the first spawn, and only then: a dsh orphaned by a previous
        // run holds the port this launch needs, and `starting_pid` cannot know
        // about it because it never saw the process.
          if attempt == 0 {
              orphan::reclaim_orphan(&config, orphan::ReclaimReason::AtStartup);
          }
        let started = std::time::Instant::now();
        let dsh = match launch_recording_pid(&state, config.clone()).await {
            Ok(dsh) => dsh,
            Err(err) => {
                report_failure(window, &err);
                return;
            }
        };

        let ending = match point_at_dsh(window.clone(), state.clone(), dsh).await {
            Some(ending) => ending,
            // A URL we cannot parse is a failure to start, not a crash to retry.
            None => return,
        };
        if ending == DshEnding::ShuttingDown || state.shutting_down.load(Ordering::SeqCst) {
            tracing::info!(target: "dsh_shell", "dsh ended because the app is exiting");
            return;
        }

        if !config.auto_restart_on_crash {
            tracing::info!(target: "dsh_shell", "auto_restart_on_crash is off; not restarting");
            return;
        }
        if attempt >= config::MAX_RESTARTS {
            tracing::error!(
                target: "dsh_shell",
                "dsh crashed {attempt} time(s) in a row; giving up. Fix it, or set auto_restart_on_crash to false."
            );
            notify(
                window.app_handle(),
                "dsh 反复崩溃",
                format!("DSH Shell 已重启 dsh {attempt} 次，仍然失败。窗口保留，但页面已无法连接。"),
            );
            return;
        }

        // A dsh that lived long enough resets the budget: this is a new failure,
        // not a continuation of the one that was already handled.
        if started.elapsed() >= config::HEALTHY_AFTER {
            tracing::info!(
                target: "dsh_shell",
                "dsh ran for {:?}; restarting the budget",
                started.elapsed()
            );
            attempt = 0;
        }

        let wait = config::restart_backoff(attempt);
        attempt += 1;
        tracing::warn!(
            target: "dsh_shell",
            "dsh crashed ({}); restarting in {wait:?} (attempt {attempt}/{})",
            ending.describe(),
            config::MAX_RESTARTS
        );

        // The port has to be free before the respawn, not after it. `launch`
        // would fail on a port the dead dsh has not finished releasing, and the
        // failure would be indistinguishable from the crash that caused it.
        wait_for_port_release(&config).await;

        tokio::time::sleep(wait).await;
        tracing::info!(target: "dsh_shell", "restarting dsh after a crash");
    }
}

/// How long to keep waiting for a crashed dsh to release its port.
///
/// Past this the port belongs to somebody else, and the respawn should fail
/// loudly in preflight rather than hang here.
const PORT_RELEASE_TIMEOUT: Duration = Duration::from_secs(10);

/// Wait for the crashed dsh's port to come free, bounded.
async fn wait_for_port_release(config: &Config) {
    if config.preferred_port == 0 {
        return;
    }
    let deadline = std::time::Instant::now() + PORT_RELEASE_TIMEOUT;
    while std::time::Instant::now() < deadline {
        if preflight::port_is_free(&config.listen_host, config.preferred_port) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    tracing::warn!(
        target: "dsh_shell",
        "port {}:{} still busy after {:?}; the respawn will fail in preflight",
        config.listen_host,
        config.preferred_port,
        PORT_RELEASE_TIMEOUT
    );
}

async fn point_at_dsh(window: WebviewWindow, state: Arc<AppState>, dsh: DshProcess) -> Option<DshEnding> {
    let url = dsh.url().to_string();
    tracing::info!(target: "dsh_shell", "dsh ready (pid {:?}) at {url}", dsh.pid());

    let parsed = match tauri::Url::parse(&url) {
        Ok(parsed) => parsed,
        Err(err) => {
            report_failure(
                &window,
                &ShellError::EndpointTimeout {
                    host: String::from("<unparsable>"),
                    port: 0,
                    waited: Duration::ZERO,
                    tail: format!("dsh printed an unparsable URL: {url}: {err}"),
                },
            );
            return None;
        }
    };

    // Record the origin before navigating: the navigation guard reads it to tell
    // dsh's own pages from an external destination, and the very next
    // navigation is the dsh page.
    let origin = parsed.origin().ascii_serialization();
    *state.dsh_origin.write() = origin.clone();
    tracing::info!(target: "dsh_shell", "dsh origin {origin}");

    // Store before navigating: from here on, the exit path owns a child that must
    // be reaped.
    *state.dsh.lock().await = Some(dsh);
    // Only now is the PID redundant: the DshProcess owns it. Clearing it any
    // earlier re-opens the window where a close leaks dsh.
    state.starting_pid.store(0, Ordering::SeqCst);

    if let Err(err) = window.navigate(parsed) {
        tracing::error!(target: "dsh_shell", "could not navigate the window: {err}");
        return None;
    }
    let _ = window.set_title("DSH Shell — dsh");
    Some(wait_for_dsh_exit(&window, &state).await)
}

/// Why dsh stopped being there.
///
/// The supervisor needs this to tell "dsh crashed" — which is worth restarting —
/// from "the user quit the app", which is not, and conflating the two would
/// resurrect dsh after the user asked for it to go.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DshEnding {
    /// Died on its own while we were still running.
    Crashed { code: Option<i32> },
    /// We are shutting down; this is the exit path doing its job.
    ShuttingDown,
}

impl DshEnding {
    fn describe(self) -> String {
        match self {
            DshEnding::Crashed { code: Some(code) } => format!("退出代码 {code}"),
            DshEnding::Crashed { code: None } => "被信号终止".to_string(),
            DshEnding::ShuttingDown => "壳正在退出".to_string(),
        }
    }
}

/// How often to ask dsh whether it is still there.
const EXIT_POLL: Duration = Duration::from_secs(1);

/// Wait until dsh is gone, and say why it went.
///
/// Awaited rather than spawned, so the supervisor owns the whole lifetime of a
/// dsh instance and can restart it without racing a detached watcher. Nothing
/// used to notice an exit at all: dsh could die and the window would sit there
/// showing a page with no server behind it, looking like a hang.
async fn wait_for_dsh_exit(window: &WebviewWindow, state: &Arc<AppState>) -> DshEnding {
    let app = window.app_handle().clone();
    loop {
        tokio::time::sleep(EXIT_POLL).await;
        if state.shutting_down.load(Ordering::SeqCst) {
            return DshEnding::ShuttingDown;
        }
        // Locked in the same order as the shutdown path (dsh, then child), and
        // only for the length of one non-blocking poll.
        let polled = {
            let guard = state.dsh.lock().await;
            match guard.as_ref() {
                Some(dsh) => dsh.poll_exit().await,
                None => continue,
            }
        };
        match polled {
            Ok(process::Exited::No) => {}
            Ok(process::Exited::Yes(code)) => {
                let ending = DshEnding::Crashed { code };
                let how = ending.describe();
                tracing::error!(target: "dsh_shell", "dsh exited unexpectedly ({how})");
                notify(
                    &app,
                    "dsh 已退出",
                    format!("DSH Shell 的 dsh 意外退出（{how}）。窗口仍然打开，但页面已无法连接。"),
                );
                return ending;
            }
            Err(err) => {
                // A failed poll says nothing about dsh. Keep watching.
                tracing::warn!(target: "dsh_shell", "could not poll dsh: {err}");
            }
        }
    }
}

/// Put a toast on screen, and log it either way.
///
/// Best-effort by design: the log is the diagnostic of record, and a notification
/// that cannot be shown must never take the app down with it.
///
/// Delegated to [`toast`] so the toast's handle survives and clicking it raises
/// the window — the plugin's fire-and-forget `show()` swallows the click.
fn notify(app: &AppHandle, title: &str, body: String) {
    toast::show_clickable(app, title, body);
}

/// Surface a startup failure in the window itself. A release build has no
/// console, so a silent exit here is indistinguishable from a hung app.
fn report_failure(window: &WebviewWindow, err: &ShellError) {
    tracing::error!(target: "dsh_shell", "startup failed: {err}");
    write_crash_log(&format!("startup failed: {err}"));
    notify(
        window.app_handle(),
        "dsh 启动失败",
        format!("DSH Shell 无法启动 dsh：{err}"),
    );

    let message = serde_json::to_string(&err.to_string()).unwrap_or_else(|_| "\"unknown\"".into());
    let script = format!(
        "document.getElementById('status') && (document.getElementById('status').textContent = 'Failed to start dsh');
         document.getElementById('detail') && (document.getElementById('detail').textContent = {message});
         document.body && document.body.classList.add('failed');"
    );
    let _ = window.eval(&script);
}

fn log_dir() -> std::path::PathBuf {
    directories::ProjectDirs::from("ai", "deepseek", "dsh-shell")
        .map(|dirs| dirs.data_dir().join("logs"))
        .unwrap_or_else(|| std::env::temp_dir().join("dsh-shell-logs"))
}

fn write_crash_log(message: &str) {
    let dir = log_dir();
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("crash.log");
    let _ = std::fs::write(
        &path,
        format!(
            "[{message}]\n  binary: {}\n  cwd: {}\n",
            std::env::args().next().unwrap_or_default(),
            std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default(),
        ),
    );
}

fn init_tracing() {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,dsh_shell=debug,tauri=debug,tao=warn"));

    let dir = log_dir();
    let _ = std::fs::create_dir_all(&dir);

    // The daily file is the diagnostic channel in every build: a release binary
    // has no console, and `cargo run` is not the only way this thing breaks.
    let writer = tracing_appender::rolling::daily(&dir, "dsh-shell.log");
    let file_layer = tracing_subscriber::fmt::layer()
        .with_target(true)
        .with_ansi(false)
        .with_writer(writer);

    // `EnvFilter` used as a layer filters every layer below it.
    let subscriber = tracing_subscriber::registry().with(filter).with(file_layer);

    // Console output only where there is a console to read it.
    #[cfg(debug_assertions)]
    let _ = subscriber
        .with(tracing_subscriber::fmt::layer().with_target(true))
        .try_init();

    #[cfg(not(debug_assertions))]
    let _ = subscriber.try_init();

    tracing::info!(target: "dsh_shell", "logging to {}", dir.display());
}
