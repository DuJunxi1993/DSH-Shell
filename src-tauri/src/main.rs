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

use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use dsh_shell_core::config::{self, Config};
use dsh_shell_core::error::ShellError;
use dsh_shell_core::process::{self, DshProcess};

/// Hard ceiling on the exit path. Shutdown must never be able to wedge the app.
const SHUTDOWN_DEADLINE: Duration = Duration::from_secs(15);

/// Rust is invoked through `tauri::async_runtime::handle` from the chrome
/// script, so commands must be async.
type CommandResult<T> = Result<T, String>;

struct AppState {
    dsh: tokio::sync::Mutex<Option<DshProcess>>,
    shutting_down: AtomicBool,
    /// Current page zoom in percent; the single source of truth for the readout
    /// the chrome draws.
    zoom_percent: AtomicU8,
}

fn main() {
    init_tracing();

    let config = Config::load_or_default();
    let zoom = config::normalize_zoom(config.zoom_percent);
    let state = Arc::new(AppState {
        dsh: tokio::sync::Mutex::new(None),
        shutting_down: AtomicBool::new(false),
        zoom_percent: AtomicU8::new(zoom),
    });

    let app = match build(state.clone(), zoom) {
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
                    }
                    tracing::info!(target: "dsh_shell", "dsh terminated; exiting");
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

const MAIN_WINDOW: &str = "main";

/// The chrome script plus the value it needs before its first line runs.
///
/// `initialization_script` is re-run on every navigation, so this covers both
/// the local boot placeholder and the remote dsh origin.
fn chrome_script(zoom_percent: u8) -> String {
    format!(
        "window.__DSH_SHELL_ZOOM__ = {zoom_percent};\n{}",
        include_str!("../../platform_adapt.js")
    )
}

/// Step the page zoom by one rung and persist the choice.
///
/// The chrome sends a delta rather than an absolute value so the ladder lives
/// here alone; the page just redraws the number it gets back, which is what
/// keeps the readout from drifting away from the real zoom.
///
/// Reachable from the remote dsh origin without a capability: Tauri checks the
/// ACL only on the plugin command path, and `generate_handler!` commands are
/// trusted by definition. That is fine here - this command can only change the
/// page zoom - but it is the reason a state-changing command added here later
/// needs to think twice.
#[tauri::command]
async fn zoom_step(
    window: WebviewWindow,
    state: tauri::State<'_, Arc<AppState>>,
    delta: i16,
) -> CommandResult<u8> {
    let current = state.zoom_percent.load(Ordering::Relaxed);
    let target = i32::from(current) + i32::from(delta);
    let next = u8::try_from(target)
        .ok()
        .map(config::normalize_zoom)
        .unwrap_or(config::ZOOM_DEFAULT);

    if next != current {
        window
            .set_zoom(config::zoom_scale(next))
            .map_err(|err| format!("could not set zoom: {err}"))?;
        state.zoom_percent.store(next, Ordering::Relaxed);
        persist_zoom(next);
    }
    Ok(next)
}

/// Write the zoom back to settings, keeping every other field the user has.
fn persist_zoom(percent: u8) {
    let mut config = Config::load_or_default();
    if config.zoom_percent == percent {
        return;
    }
    config.zoom_percent = percent;
    if let Err(err) = config.save() {
        tracing::warn!(target: "dsh_shell", "could not save zoom: {err}");
    }
}

/// Report what the injected chrome managed to do.
///
/// Not decoration. The chrome lives inside a remote document we do not
/// control, so a future dsh release could remove the bar, restyle it, or wipe
/// it from the DOM — and a frameless window with no close button is a trap.
/// A one-line log turns that into a diagnosable event.
#[tauri::command]
fn chrome_report(report: ChromeReport) {
    if report.installed && report.still_present {
        tracing::info!(
            target: "dsh_shell",
            "chrome installed: origin={} height={}px zoom={} placeholder={} ready={:?}",
            report.origin,
            report.height_css_px,
            report.zoom,
            report.placeholder,
            report.ready_state
        );
        // The layout boxes are what you want when the chrome is present but
        // invisible: they distinguish "element is missing" from "element is
        // there but not painted", which a screenshot cannot.
        tracing::debug!(
            target: "dsh_shell",
            "chrome layout: computed_zoom={:?} dsh_root_children={} {}",
            report.computed_zoom,
            report.dsh_root_children,
            report.boxes
        );
    } else {
        tracing::warn!(
            target: "dsh_shell",
            "chrome FAILED to install (installed={}, still_present={}, ready_state={:?}, \
             origin={}, dsh_root_children={}) — this window has no title bar and no way to close it",
            report.installed,
            report.still_present,
            report.ready_state,
            report.origin,
            report.boxes
        );
    }
}

#[derive(serde::Deserialize)]
struct ChromeReport {
    installed: bool,
    /// Whether the bar was still in the document a moment after install, which
    /// is how a SPA that rewrites `<body>` shows up.
    still_present: bool,
    height_css_px: f64,
    zoom: f64,
    /// `--dsh-shell-zoom` as the browser resolved it. Kept in the debug log
    /// because a mismatch means another stylesheet is redefining the variable,
    /// which would silently rescale the bar.
    computed_zoom: String,
    placeholder: bool,
    ready_state: String,
    origin: String,
    dsh_root_children: i64,
    boxes: String,
}

/// A throw inside the injected script. Logged verbatim: it is the only record of
/// why the window has no title bar.
#[tauri::command]
fn chrome_error(message: String) {
    tracing::error!(target: "dsh_shell", "chrome script threw:\n{message}");
}

fn build(state: Arc<AppState>, zoom: u8) -> tauri::Result<tauri::App> {
    let setup_state = state.clone();
    let page_load_state = state.clone();
    let chrome = chrome_script(zoom);
    let page_load_chrome = chrome.clone();
    tauri::Builder::default()
        // Required by the `zoom_step` and `chrome_report` commands, which read
        // the zoom through `tauri::State`. Without it, state resolution fails at
        // invoke time and the command returns an error the page cannot see -
        // which is exactly the failure that made the zoom control do nothing.
        .manage(state)
        .setup(move |app| {
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
                // Chromium's own Ctrl+= zoom would bypass our state and leave
                // the percentage readout lying.
                .zoom_hotkeys_enabled(false)
                // Runs before any page script, on every navigation, so it cannot
                // be lost to a race with the SPA booting.
                .initialization_script(chrome.clone())
                .on_page_load(move |window, payload| {
                    // Re-assert the zoom on every document. It survives
                    // navigation inside one webview, but not across a webview
                    // being torn down, and a page that renders at 100% before
                    // snapping to the saved zoom is visibly wrong.
                    if payload.event() != tauri::webview::PageLoadEvent::Finished {
                        return;
                    }
                    let percent = page_load_state.zoom_percent.load(Ordering::Relaxed);
                    if let Err(err) = window.set_zoom(config::zoom_scale(percent)) {
                        tracing::warn!(target: "dsh_shell", "could not apply zoom: {err}");
                    }
                    // The initialization script above only reaches our own local
                    // boot page: dsh serves its own Content-Security-Policy, and
                    // a document-created injection is subject to it. `eval` comes
                    // from the host side, which is not, so the chrome for the
                    // real page is injected here instead. The script is
                    // idempotent, so running it on the placeholder too is a
                    // no-op.
                    if let Err(err) = window.eval(page_load_chrome.clone()) {
                        tracing::error!(target: "dsh_shell", "could not inject chrome: {err}");
                    }
                })
                .build()?;

            let state = setup_state.clone();
            tauri::async_runtime::spawn(async move {
                let config = Config::load_or_default();
                tracing::info!(
                    target: "dsh_shell",
                    "starting: mode={:?} port={} host={} zoom={}% binary={}",
                    config.launch_mode,
                    config.preferred_port,
                    config.listen_host,
                    config::normalize_zoom(config.zoom_percent),
                    config.dsh_binary_path.display(),
                );

                match process::launch(config).await {
                    Ok(dsh) => point_at_dsh(window, state, dsh).await,
                    Err(err) => report_failure(&window, &err),
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![zoom_step, chrome_report, chrome_error])
        .build(tauri::generate_context!())
}

async fn point_at_dsh(window: WebviewWindow, state: Arc<AppState>, dsh: DshProcess) {
    let url = dsh.url().to_string();
    tracing::info!(target: "dsh_shell", "dsh ready (pid {:?}) at {url}", dsh.pid());

    let parsed = match tauri::Url::parse(&url) {
        Ok(parsed) => parsed,
        Err(err) => {
            report_failure(&window, &ShellError::EndpointTimeout {
                host: String::from("<unparsable>"),
                port: 0,
                waited: Duration::ZERO,
                tail: format!("dsh printed an unparsable URL: {url}: {err}"),
            });
            return;
        }
    };

    // Store before navigating: from here on, the exit path owns a child that must
    // be reaped.
    *state.dsh.lock().await = Some(dsh);

    if let Err(err) = window.navigate(parsed) {
        tracing::error!(target: "dsh_shell", "could not navigate the window: {err}");
        return;
    }
    let _ = window.set_title("DSH Shell — dsh");
}

/// Surface a startup failure in the window itself. A release build has no
/// console, so a silent exit here is indistinguishable from a hung app.
fn report_failure(window: &WebviewWindow, err: &ShellError) {
    tracing::error!(target: "dsh_shell", "startup failed: {err}");
    write_crash_log(&format!("startup failed: {err}"));

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
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,dsh_shell=debug"));

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
