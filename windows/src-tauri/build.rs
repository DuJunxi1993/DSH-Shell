fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            // Autogenerates `allow-set-page-zoom`, `allow-hide-to-tray`,
            // `allow-chrome-report` and `allow-chrome-error` in the ACL.
            //
            // Without this, commands registered through `generate_handler!` are
            // denied on a *remote* origin. The ACL is checked for app commands
            // too, not only for plugins - so an app command missing here fails at
            // invoke time with an error the page cannot see, and fails silently
            // in exactly the way that used to make the zoom control look broken
            // while the window buttons, which are plugin commands listed by hand
            // in capabilities/chrome.json, worked fine.
            //
            // Renaming `zoom_step`/`zoom_reset` to one absolute `set_page_zoom` is
            // deliberate: the hotkeys are Chromium's, so the shell no longer knows
            // what the current zoom is and cannot step from it. A command that
            // took a delta would have to be told the current value by the page,
            // which is the page guessing, not the shell measuring.
            "set_page_zoom",
            "hide_to_tray",
            "chrome_report",
            "chrome_error",
        ])),
    )
    .expect("failed to run tauri-build");
}
