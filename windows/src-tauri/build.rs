fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            // Autogenerates `allow-set-page-zoom`, `allow-hide-to-tray`,
            // `allow-startup-retry`, `allow-chrome-report` and `allow-chrome-error`
            // in the ACL.
            //
            // Without this, commands registered through `generate_handler!` are
            // denied on a *remote* origin. The ACL is checked for app commands
            // too, not only for plugins - so an app command missing here fails at
            // invoke time with an error the page cannot see, and fails silently
            // in exactly the way that used to make the zoom control look broken
            // while the window buttons, which are plugin commands listed by hand
            // in capabilities/chrome.json, worked fine.
            //
            // `set_page_zoom` takes an **absolute** percentage rather than a delta,
            // and that is deliberate: the hotkeys are Chromium's, so the shell
            // cannot know what the user last did to the zoom, and a command that
            // stepped from our own remembered value would drift from the real one
            // the first time they pressed `Ctrl`+`=`. The page measures what it can
            // and asks for the rung it wants; Rust clamps it onto the ladder.
            "set_page_zoom",
            "startup_retry",
            "hide_to_tray",
            "chrome_report",
            "chrome_error",
        ])),
    )
    .expect("failed to run tauri-build");
}
