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
//! a `transform: scale(1 / zoom)` on the control clusters — so at 50% zoom the
//! window buttons rendered at 92 logical pixels instead of 40, i.e. zooming out
//! made the chrome grow. The rule is now enforced by the tests below rather than
//! by a comment, and `chrome_report` re-checks it against the live DOM.
//!
//! # The page is the unknown
//!
//! There is no stable selector to hook: dsh's app shell has no semantic `id`
//! and no ARIA landmark roles, and its CSS-Modules class names are hashed per
//! build. So these constants are the contract the injected script is given, and
//! the only adjustment that can be made to the page itself is the inset the
//! script applies to whatever column it finds in the reserved corner.

use crate::config::{ZOOM_MAX, ZOOM_MIN, ZOOM_STEP};

/// Design height of the whole bar, in logical pixels.
pub const BAR_H: f64 = 24.0;
/// Design width of one window button.
pub const WIN_W: f64 = 32.0;
/// Height of the strip at the top of the bar that drags the window.
///
/// Two thirds of the bar, not all of it. The strip spans the full width, so
/// anything the page puts at the very top of the window sits under it and cannot
/// be clicked; the status line in the bar is click-through and needs no such
/// clearance, which leaves the lower third of the bar free for page controls.
pub const GRAB_H: f64 = BAR_H * 2.0 / 3.0;
/// Top strip left free for the OS resize border, since a frameless window has
/// no caption to drag. Inside [`GRAB_H`], so it costs nothing extra.
pub const RESIZE_BORDER: f64 = 4.0;
/// Corner radius of a button's hover background.
pub const CORNER_R: f64 = 5.0;

/// Width the chrome occupies on the right: the three window buttons.
pub fn reserved_width() -> f64 {
    3.0 * WIN_W
}

/// Width of the window-button cluster.
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
         grabH: {GRAB_H}, resizeBorder: {RESIZE_BORDER}, cornerR: {CORNER_R}, \
         zoomMin: {ZOOM_MIN}, zoomMax: {ZOOM_MAX}, zoomStep: {ZOOM_STEP} }};\n{}",
        include_str!("../../platform_adapt.js")
    )
}

/// Invariants that are cheap to check at compile time, so a bad edit is a build
/// failure rather than a test failure nobody ran.
const _: () = {
    // The resize border lives inside the drag strip, so the strip has to be at
    // least twice as tall for the border not to swallow all of it.
    assert!(GRAB_H >= RESIZE_BORDER * 2.0);
    assert!(GRAB_H <= BAR_H);
    // A radius larger than half the button renders as a lozenge.
    assert!(CORNER_R <= BAR_H / 2.0);
    assert!(CORNER_R <= WIN_W / 2.0);
    // The buttons must be able to hold a glyph at a legible size.
    assert!(WIN_W >= 28.0);
    // The button row is inset from the top, so it has to leave room for itself.
    assert!(RESIZE_BORDER < BAR_H - RESIZE_BORDER);
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
            ("grabH", js_number(GRAB_H)),
            ("resizeBorder", js_number(RESIZE_BORDER)),
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
            ("resizeBorder", js_number(RESIZE_BORDER)),
            ("cornerR", js_number(CORNER_R)),
        ] {
            assert!(
                js.contains(&format!("num(CFG.{name}, {value})")),
                "the script's fallback for {name} is not {value}"
            );
        }
        // Derived in both places, so it must stay derived in both.
        assert!(
            js.contains("num(CFG.grabH, BAR_H * 2 / 3)"),
            "grabH's fallback should be derived from BAR_H, not spelled out"
        );
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
                GRAB_H,
                RESIZE_BORDER,
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
        // The regression, stated as a test: at 50% the window buttons must still
        // resolve to 40 CSS pixels * 2 = 80, which paints as 40 logical pixels.
        // Dividing twice used to give 160, which is what "the menu bar grows
        // when I zoom out" was.
        let zoom = 0.5;
        assert!((css_len(WIN_W, zoom) - 64.0).abs() < 1e-9);
        assert!((css_len(WIN_W, zoom) * zoom - WIN_W).abs() < 1e-9);
    }

    #[test]
    fn zoomed_out_chrome_occupies_more_css_but_the_same_logical_space() {
        // At 50% the bar is 56 CSS px tall so that it paints as 28 logical px.
        assert!((css_len(BAR_H, 0.5) - 48.0).abs() < 1e-9);
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
        assert!(script.contains("grabH:"), "{script}");
        assert!(script.contains("zoom: 70"), "{script}");
        // The zoom control is gone, so its constant must not linger.
        assert!(!script.contains("zoomW"), "{script}");
        // The static part of the script must follow it.
        assert!(script.contains("dsh-shell-chrome"), "{script}");
    }
}
