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

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tauri::{RunEvent, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use dsh_shell_core::config::Config;
use dsh_shell_core::error::ShellError;
use dsh_shell_core::process::{self, DshProcess};

/// Hard ceiling on the exit path. Shutdown must never be able to wedge the app.
const SHUTDOWN_DEADLINE: Duration = Duration::from_secs(15);

struct AppState {
    dsh: tokio::sync::Mutex<Option<DshProcess>>,
    shutting_down: AtomicBool,
}

fn main() {
    init_tracing();

    let state = Arc::new(AppState {
        dsh: tokio::sync::Mutex::new(None),
        shutting_down: AtomicBool::new(false),
    });

    let app = match build(state.clone()) {
        Ok(app) => app,
        Err(err) => {
            write_crash_log(&format!("failed to start: {err}"));
            std::process::exit(1);
        }
    };

    app.run(move |app_handle, event| {
        if let RunEvent::ExitRequested { api, .. } = event {
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
    });
}

fn build(state: Arc<AppState>) -> tauri::Result<tauri::App> {
    let setup_state = state;
    tauri::Builder::default()
        .setup(move |app| {
            let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("DSH Shell")
                .inner_size(1280.0, 800.0)
                .min_inner_size(800.0, 600.0)
                .resizable(true)
                .center()
                // Runs before any page script, on every navigation, so it cannot
                // be lost to a race with the SPA booting.
                .initialization_script(include_str!("../../platform_adapt.js"))
                .build()?;

            let state = setup_state.clone();
            tauri::async_runtime::spawn(async move {
                let config = Config::load_or_default();
                tracing::info!(
                    target: "dsh_shell",
                    "starting: mode={:?} port={} host={} binary={}",
                    config.launch_mode,
                    config.preferred_port,
                    config.listen_host,
                    config.dsh_binary_path.display(),
                );

                match process::launch(config).await {
                    Ok(dsh) => point_at_dsh(window, state, dsh).await,
                    Err(err) => report_failure(&window, &err),
                }
            });

            Ok(())
        })
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
