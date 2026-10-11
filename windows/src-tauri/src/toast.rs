//! Toasts the shell raises for itself, wired to bring the window back.
//!
//! `tauri-plugin-notification` shows a toast and throws the handle away. On
//! Windows that means the WinRT `Activated` handler it installed dies with the
//! dropped handle, so clicking the toast is swallowed: the click reaches a dead
//! callback and the window is never raised. The plugin is kept for the *page's*
//! notifications (a dsh plugin calling `new Notification(...)` goes through it),
//! where we have no choice but to use it, but the shell's own two toasts — a
//! failed startup and a dsh that died on its own — are the ones a user is
//! actually away from, so they get a real activation path.
//!
//! The fix is to hold on to notify-rust's `NotificationHandle` and wait on it:
//!
//! ```text
//! Notification::show() -> handle
//! spawn a thread:
//!     handle.wait_for_action(|_| { show/unminimize/set_focus the window })
//! ```
//!
//! Keeping the handle alive is the whole difference between "the click was
//! swallowed" and "the click came back to us as an action".

use tauri::{AppHandle, Manager};

#[cfg(target_os = "windows")]
use notify_rust::Timeout;

/// Raise the main window. The single-instance plugin uses the same shape, so a
/// toast click and a second launch land the user in the same place.
fn raise_main_window(app: &AppHandle) {
    let Some(window) = app.get_webview_window(crate::MAIN_WINDOW) else {
        tracing::warn!(target: "dsh_shell", "no window to raise for a toast click");
        return;
    };
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
    tracing::info!(target: "dsh_shell", "window raised from a toast click");
}

/// Whether this build runs from a cargo target directory rather than from an
/// install.
///
/// It decides whether a toast may claim the app's own AUMID. An AUMID only works
/// if something registered it - an installed app does, via its Start Menu entry -
/// and claiming an unregistered one makes the toast fail to appear at all. The
/// notification plugin makes the same call, and a dev run falls back to the
/// PowerShell AUMID, which always displays. So a dev run still sees the toast and
/// simply does not get click-to-focus, which is the honest outcome: the activation
/// plumbing only exists once the app is actually installed.
fn installed_build() -> bool {
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let dir = exe.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    !(dir.ends_with(&format!("{}target{}debug", std::path::MAIN_SEPARATOR, std::path::MAIN_SEPARATOR))
        || dir.ends_with(&format!("{}target{}release", std::path::MAIN_SEPARATOR, std::path::MAIN_SEPARATOR)))
}

/// Show a toast whose click raises the window.
///
/// Best effort by design: a notification that cannot be shown must never take the
/// app down, and neither must the wait thread.
#[cfg(target_os = "windows")]
pub fn show_clickable(app: &AppHandle, title: &str, body: String) {
    use notify_rust::Notification;

    let mut notification = Notification::new();
    notification.summary(title).body(&body).timeout(Timeout::Never);
    if installed_build() {
        notification.app_id(&app.config().identifier);
    }

    let handle = match notification.show() {
        Ok(handle) => handle,
        Err(err) => {
            tracing::warn!(target: "dsh_shell", "could not show a toast ({title}): {err}");
            return;
        }
    };

    // The wait blocks until the toast is clicked or dismissed. Both end the wait;
    // only a click should raise the window, which `wait_for_action` tells us by
    // not reporting the "closed" sentinel.
    let app = app.clone();
    std::thread::spawn(move || {
        handle.wait_for_action(|action| {
            if action == "__closed" {
                return;
            }
            raise_main_window(&app);
        });
    });

    tracing::info!(target: "dsh_shell", "notified (clickable): {title} — {body}");
}

/// Non-Windows, or any build that cannot show a toast: log it and move on. The
/// plugin remains the path for page-originated notifications everywhere.
#[cfg(not(target_os = "windows"))]
pub fn show_clickable(app: &AppHandle, title: &str, body: String) {
    use tauri_plugin_notification::NotificationExt;
    let _ = app
        .notification()
        .builder()
        .title(title)
        .body(body.clone())
        .show();
    tracing::info!(target: "dsh_shell", "notified: {title} — {body}");
}