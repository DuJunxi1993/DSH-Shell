fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            // Autogenerates `allow-zoom-step`, `allow-chrome-report` and
            // `allow-chrome-error` in the ACL. Without this, commands registered
            // through `generate_handler!` are denied on a *remote* origin - the
            // ACL is checked for app commands too, not only for plugins - so the
            // zoom control silently does nothing while the window buttons, which
            // are plugin commands listed in capabilities/chrome.json, work fine.
            "zoom_step",
            "chrome_report",
            "chrome_error",
        ])),
    )
    .expect("failed to run tauri-build");
}
