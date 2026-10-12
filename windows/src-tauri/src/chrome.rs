//! Geometry of the injected window chrome, and the one place page zoom is
//! compensated for.
//!
//! # Why this module exists
//!
//! The chrome is DOM inside a document we do not control, so its geometry has
//! to survive two multipliers: the browser's page zoom, which scales every CSS
//! pixel in the document, and the OS DPI scale, which we do not care about
//! because it scales everything equally.
//!
//! A design length `D` that must render as `D` logical pixels therefore needs a
//! CSS length of `D / zoom`. That division is [`css_len`], and it is the **only**
//! place in this crate where the page zoom may be divided out.
//!
//! It was previously applied twice — once by dividing each length and again with
//! a `transform: scale(1 / zoom)` on the control clusters — so zooming out made
//! the chrome grow. The symptom is remembered as "the menu bar grows when I zoom
//! out"; the exact pixel figures from that build are not recoverable from here,
//! and a comment that cannot be checked is a comment that will drift. What *is*
//! checkable is the round trip, and that is what the tests assert.
//!
//! # The page does have a contract — use it first
//!
//! dsh ships a desktop-host contract, and the shell used to ignore it and
//! compensate geometrically instead. Setting two properties is enough:
//!
//! ```js
//! document.documentElement.setAttribute('data-windows-titlebar', '')
//! document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '32px')
//! ```
//!
//! dsh then reserves the caption height on its own frame, paints the drag
//! strip, rounds the content column's top-left corner, publishes
//! `--dsh-frame-chrome-top`, insets its own fullscreen modal overlays, and
//! converges both when the window goes fullscreen. Measured, not assumed — see
//! `docs/dsh-desktop-contract.md` §2.3.
//!
//! So the injected script is two layers: a **contract layer** that declares the
//! host and reads dsh's published clearances, and a **fallback layer** of
//! geometric avoidance that runs only when the contract is absent — an older
//! dsh, or the local boot placeholder, which is ours and has no contract at
//! all. The fallback is what `platform_adapt.js` used to be unconditionally, and
//! it stays because "the page has no contract" is still true for a dsh that
//! predates one.
//!
//! What the fallback cannot be is the default path. Insetting a column we found
//! by its geometry is a guess about a document whose CSS-Modules class names are
//! rehashed every build; reading a custom property dsh publishes is a
//! conversation with dsh.

use crate::config::{ZOOM_MAX, ZOOM_MIN, ZOOM_STEP};

/// Design height of the whole bar, in logical pixels.
///
/// 28, not a round number of our own: dsh's own sidebar toggle is centred as
/// `top: calc((var(--dsh-windows-titlebar-height) - 28px) / 2)`, so any other
/// height puts the toggle off-centre inside the caption. This is the one number
/// the contract makes the host own, and dsh's consumers are written against 28.
pub const BAR_H: f64 = 28.0;
/// Design width of one window button.
pub const WIN_W: f64 = 32.0;
/// Corner radius of a button's hover background.
pub const CORNER_R: f64 = 5.0;

/// Width the chrome occupies on the right: the three window buttons.
pub fn reserved_width() -> f64 {
    3.0 * WIN_W
}

/// Width of the window-button cluster.
    ///
    /// A deliberate alias of [`reserved_width`], kept because both names read
    /// correctly at their call sites: one is "how much of the page's right edge
    /// do we own", the other is "how wide is the cluster". They are the same
    /// number because the cluster *is* everything the chrome reserves.
    pub fn window_cluster_width() -> f64 {
        reserved_width()
    }

/// Convert a design length in logical pixels to a CSS length that renders at
/// that size whatever the page zoom is.
///
/// `zoom` is the page zoom as a fraction (50% is `0.5`).
pub fn css_len(design_px: f64, zoom: f64) -> f64 {
    design_px / zoom
}

/// The script to inject, with the geometry baked in as `window.__DSH_SHELL__`.
///
/// Not a `const fn`: the include is fine either way, but keeping this next to
/// the constants makes it obvious that the script is generated, not a static
/// asset.
///
/// The zoom ladder is injected from [`crate::config`] rather than repeated in the
/// script, because the key handler needs the step size to ask for and the clamp
/// needs both ends. A ladder kept in two places is a ladder that disagrees with
/// itself the first time either one is edited.
pub fn script(zoom_percent: u8) -> String {
    format!(
        "window.__DSH_SHELL__ = {{ zoom: {zoom_percent}, barH: {BAR_H}, winW: {WIN_W}, \
         cornerR: {CORNER_R}, \
         zoomMin: {ZOOM_MIN}, zoomMax: {ZOOM_MAX}, zoomStep: {ZOOM_STEP} }};\n{}",
        include_str!("../../platform_adapt.js")
    )
}

/// Invariants that are cheap to check at compile time, so a bad edit is a build
/// failure rather than a test failure nobody ran.
const _: () = {
    // A radius larger than half the button renders as a lozenge.
    assert!(CORNER_R <= BAR_H / 2.0);
    assert!(CORNER_R <= WIN_W / 2.0);
    // The buttons must be able to hold a glyph at a legible size.
    assert!(WIN_W >= 28.0);
};

#[cfg(test)]
mod tests {
    use super::*;

    const ZOOMS: [f64; 6] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0];

    /// A JS number literal for a design length, the way Rust prints it: `24.0`
    /// becomes `24`, and the script's fallbacks are written that way.
    fn js_number(value: f64) -> String {
        format!("{value}")
    }

    #[test]
    fn the_script_carries_every_constant() {
        // If a value is injected but not read, or read but not injected, the
        // script silently runs on its fallback - which is how the bar ended up
        // 28px tall in the page while the Rust constant said 24.
        let js = script(100);
        for (name, value) in [
            ("barH", js_number(BAR_H)),
            ("winW", js_number(WIN_W)),
            ("cornerR", js_number(CORNER_R)),
            ("zoomMin", js_number(f64::from(ZOOM_MIN))),
            ("zoomMax", js_number(f64::from(ZOOM_MAX))),
            ("zoomStep", js_number(f64::from(ZOOM_STEP))),
        ] {
            assert!(
                js.contains(&format!("{name}: {value}")),
                "{name} is not injected as {value}"
            );
        }
    }

    #[test]
    fn the_scripts_fallbacks_agree_with_those_constants() {
        // The script keeps a fallback for each injected value, for the case where
        // it is evaluated without its config. A fallback that disagrees with the
        // constant is a silently wrong chrome, so the two are checked here rather
        // than by eye - the fallbacks are already how a tuned value got lost once.
        let js = script(100);
        for (name, value) in [
            ("barH", js_number(BAR_H)),
            ("winW", js_number(WIN_W)),
            ("cornerR", js_number(CORNER_R)),
        ] {
            assert!(
                js.contains(&format!("num(CFG.{name}, {value})")),
                "the script's fallback for {name} is not {value}"
            );
        }
        // Derived in both places, so it must stay derived in both.
        for (name, value) in [
            ("zoomMin", ZOOM_MIN),
            ("zoomMax", ZOOM_MAX),
            ("zoomStep", ZOOM_STEP),
        ] {
            assert!(
                js.contains(&format!("num(CFG.{name}, {value})")),
                "the script's fallback for {name} is not {value}"
            );
        }
    }

    #[test]
    fn css_len_round_trips_at_every_zoom_step() {
        // The invariant that was violated: css_len compensates exactly once, so
        // multiplying back by the zoom must return the design length.
        for zoom in ZOOMS {
            for design in [
                BAR_H,
                WIN_W,
                CORNER_R,
                reserved_width(),
            ] {
                assert!(
                    (css_len(design, zoom) * zoom - design).abs() < 1e-9,
                    "design {design} at zoom {zoom} did not round-trip"
                );
            }
        }
    }

    #[test]
    fn zoom_out_does_not_inflate_the_chrome() {
        // Stated as an assertion rather than as a remembered pixel count: a
        // button is 32 logical px wide, so at 50% zoom it needs 64 CSS px to
        // paint at 32 logical px. Dividing twice used to double that again, and
        // that is what "the menu bar grows when I zoom out" was.
        let zoom = 0.5;
        assert!((css_len(WIN_W, zoom) - 64.0).abs() < 1e-9);
        assert!((css_len(WIN_W, zoom) * zoom - WIN_W).abs() < 1e-9);
    }

    #[test]
    fn zoomed_out_chrome_occupies_more_css_but_the_same_logical_space() {
        // Same rule for the bar: 28 logical px, so 56 CSS px at 50% zoom.
        assert!((css_len(BAR_H, 0.5) - 56.0).abs() < 1e-9);
        assert!((css_len(BAR_H, 0.5) * 0.5 - BAR_H).abs() < 1e-9);
    }

    #[test]
    fn reserved_width_is_just_the_three_window_buttons() {
        // Was 234 with a zoom control in the corner; the control is gone, and
        // that space belongs to the page again.
        assert!((reserved_width() - 96.0).abs() < 1e-9);
        assert!((window_cluster_width() - 96.0).abs() < 1e-9);
    }

    #[test]
    fn the_injected_script_carries_the_geometry() {
        let script = script(70);
        assert!(script.contains("window.__DSH_SHELL__"), "{script}");
        assert!(script.contains("barH:"), "{script}");
        assert!(script.contains("zoom: 70"), "{script}");
        // The zoom control is gone, so its constant must not linger.
        assert!(!script.contains("zoomW"), "{script}");
        // The static part of the script must follow it.
        assert!(script.contains("dsh-shell-chrome"), "{script}");
    }

    /// The bar height is the one number the contract makes the host own, and dsh
    /// centres its sidebar toggle as `(height - 28px) / 2`. Stated as the
    /// arithmetic rather than as "28 is right" so the reason survives an edit.
    #[test]
    fn the_bar_height_is_the_one_dsh_centres_its_toggle_against() {
        let centred = (BAR_H - 28.0) / 2.0;
        assert!(centred.abs() < 1e-9, "the toggle would sit {centred}px off centre");
    }

    /// The contract layer is not optional. Without it the script silently falls
    /// back to guessing the page's geometry, and the chrome *looks* fine, so
    /// nothing would report the regression.
    #[test]
    fn the_script_declares_the_desktop_contract() {
        let script = script(100);
        assert!(script.contains("data-windows-titlebar"), "{script}");
        assert!(script.contains("--dsh-windows-titlebar-height"), "{script}");
        // And it must read back what dsh publishes rather than assuming it.
        assert!(script.contains("--dsh-frame-chrome-top"), "{script}");
        assert!(script.contains("--dsh-frame-top-clearance"), "{script}");
    }

    /// The two layers must be separable, or the fallback cannot stay dormant.
    #[test]
    fn the_script_distinguishes_the_contract_from_the_fallback() {
        let script = script(100);
        assert!(script.contains("contractActive"), "{script}");
        assert!(script.contains("contractMissing"), "{script}");
    }
}
