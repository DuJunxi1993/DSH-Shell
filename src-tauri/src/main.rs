//! dsh-shell entry point.
//!
//! Flow:
//! 1. Configure tracing to log to a rolling file under the platform log dir.
//! 2. Load config (default 34247 / spawn mode).
//! 3. Launch dsh and capture its endpoint.
//! 4. Open a Tauri WebView pointed at that endpoint.
//! 5. On window close, gracefully terminate dsh before exiting.

// Suppress the console subsystem so double-click on Windows does not spawn a
// conhost window alongside the GUI. Logs are written to file (see init_tracing).
#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

use std::sync::Arc;
use tauri::{WebviewUrl, WebviewWindowBuilder, WindowEvent};

use dsh_shell_core::{config::Config, process};

fn log_dir() -> std::path::PathBuf {
    directories::ProjectDirs::from("ai", "deepseek", "dsh-shell")
        .map(|p| p.data_dir().join("logs"))
        .unwrap_or_else(|| std::env::temp_dir().join("dsh-shell-logs"))
}

fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    // In debug builds we still want console output for `cargo run`. In release
    // builds (no console subsystem) we write to a file under the log dir.
    let log_path = log_dir().join("dsh-shell.log");
    let _ = std::fs::create_dir_all(log_dir());

    #[cfg(all(not(debug_assertions), target_os = "windows"))]
    {
        let file_appender = tracing_appender::rolling::daily(log_dir(), "dsh-shell.log");
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_target(true)
            .with_writer(file_appender)
            .try_init();
    }

    #[cfg(not(all(not(debug_assertions), target_os = "windows")))]
    {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_target(true)
            .try_init();
    }

    tracing::info!(
        target: "dsh_shell",
        "tracing initialized; log file = {}",
        log_path.display()
    );
}

fn main() {
    init_tracing();

    let config = Config::load_or_default();
    tracing::info!(
        target: "dsh_shell",
        "starting: launch_mode={:?} port={} host={}",
        config.launch_mode,
        config.preferred_port,
        config.listen_host,
    );

    let dsh = Arc::new(parking_lot::Mutex::new(None::<process::DshProcess>));

    let dsh_for_setup = dsh.clone();
    let dsh_for_event = dsh.clone();

    tauri::Builder::default()
        .setup(move |app| {
            // Block the UI thread until dsh is up. This is exactly dsh-swiftUI's
            // model: no window appears before the endpoint is reachable.
            let cfg = Config::load_or_default();
            let runtime = tauri::async_runtime::handle();
            let dsh_proc = runtime.block_on(async move {
                let cfg_for_task = cfg.clone();
                process::launch(cfg_for_task).await
            });

            match dsh_proc {
                Ok(proc) => {
                    let url = proc.url().to_string();
                    tracing::info!(target: "dsh_shell", "dsh up at {}", url);

                    let parsed_url = url::Url::parse(&url)
                        .map_err(|e| format!("invalid endpoint url {}: {}", url, e))?;
                    let win = WebviewWindowBuilder::new(
                        app,
                        "main",
                        WebviewUrl::External(parsed_url),
                    )
                    .title(format!(
                        "DSH Shell — dsh @ {}",
                        proc.config().listen_host
                    ))
                    .inner_size(1280.0, 800.0)
                    .min_inner_size(800.0, 600.0)
                    .resizable(true)
                    .build()?;

                    *dsh_for_setup.lock() = Some(proc);

                    // Inject platform CSS after page load so DSH SPA adapts to OS chrome.
                    let css = include_str!("../../platform_adapt.css");
                    win.eval(css)?;

                    Ok(())
                }
                Err(e) => {
                    tracing::error!(target: "dsh_shell", "failed to start dsh: {}", e);
                    // Also dump to the crash log so a non-console release can
                    // surface the failure to whoever runs the binary.
                    let path = std::env::temp_dir().join("dsh-shell-crash.log");
                    let _ = std::fs::write(
                        &path,
                        format!("[dsh-shell] failed to start dsh: {}\n", e),
                    );
                    Err(Box::new(e) as Box<dyn std::error::Error>)
                }
            }
        })
        .on_window_event(move |_window, event| {
            if let WindowEvent::CloseRequested { .. } = event {
                // Synchronous-feeling shutdown: block_on the async kill + wait.
                let guard = dsh_for_event.lock();
                if let Some(proc) = guard.as_ref() {
                    let runtime = tauri::async_runtime::handle();
                    runtime.block_on(async move {
                        proc.shutdown().await;
                    });
                }
                tracing::info!(target: "dsh_shell", "window closed; dsh terminated; exiting");
            }
        })
        .run(tauri::generate_context!())
        .map_err(|e| {
            // Last-resort crash log so users (and our manual-checklist operator)
            // can recover the failure mode even in release builds with no
            // console subsystem. The path is intentionally short and outside
            // the AppData tree, so it's visible without shell tricks.
            let path = std::env::temp_dir().join("dsh-shell-crash.log");
            let msg = format!(
                "[dsh-shell crash] {}\n  binary: {}\n  cwd: {}\n",
                e,
                std::env::args().next().unwrap_or_default(),
                std::env::current_dir()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|_| "<unknown>".to_string()),
            );
            let _ = std::fs::write(&path, msg);
            e
        })
        .expect("failed to start dsh-shell");
}