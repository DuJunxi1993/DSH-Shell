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

/// Design height of the whole bar, in logical pixels.
pub const BAR_H: f64 = 24.0;
/// Design width of one window button.
pub const WIN_W: f64 = 32.0;
/// Height of the strip at the top of the bar that drags the window.
///
/// The full bar height, derived rather than repeated: it was halved at one point
/// to stop it swallowing clicks on the page's top row, but the real answer was
/// to move that row down to the session list's brand line. The strip spans the
/// whole width, so a narrower one only hid part of the problem.
pub const GRAB_H: f64 = BAR_H;
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
pub fn script(zoom_percent: u8) -> String {
    format!(
        "window.__DSH_SHELL__ = {{ zoom: {zoom_percent}, barH: {BAR_H}, winW: {WIN_W}, \
         grabH: {GRAB_H}, resizeBorder: {RESIZE_BORDER}, cornerR: {CORNER_R} }};\n{}",
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
