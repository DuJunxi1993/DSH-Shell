//! Geometry of the injected window chrome.
//!
//! # Why this module exists
//!
//! The chrome is DOM inside a document we do not control, so its geometry has to
//! agree with dsh's own layout at every scale. It used to have to survive the
//! browser's page zoom as well: each length was divided by the zoom so a design
//! length rendered at its intended size regardless of zoom, which meant the
//! division had to be applied exactly once. It was applied twice — once by
//! dividing the lengths and again with a `transform: scale(1 / zoom)` — so
//! zooming out made the chrome grow.
//!
//! That whole class of bug is gone. Zoom is Chromium's now (`Ctrl` +`±`/`0` is
//! not intercepted), and every length here is a plain CSS pixel, so the chrome
//! scales with the page exactly as dsh's own content does. That is not a
//! concession: `--dsh-windows-titlebar-height` is itself a CSS length, so dsh's
//! reserved caption band scales too, and the two cannot drift apart. Dividing
//! the chrome out while dsh scaled in would have been the thing keeping them
//! aligned.
//!
//! The OS DPI scale is untouched by any of this, because it scales everything
//! equally.
//!
//! # The page does have a contract — use it first
//!
//! dsh ships a desktop-host contract, and this shell used to ignore it and
//! compensate geometrically instead. Setting two properties is enough:
//!
//! ```js
//! document.documentElement.setAttribute('data-windows-titlebar', '')
//! document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '36px')
//! ```
//!
//! dsh then reserves the caption height on its own frame, paints the drag
//! strip, rounds the content column's top-left corner, publishes
//! `--dsh-frame-chrome-top`, insets its own fullscreen modal overlays, and
//! converges both when the window goes fullscreen. Measured, not assumed — see
//! `docs/dsh-desktop-contract.md` §2.3.
//!
//! The contract also takes over part of the caption: it pins dsh's sidebar
//! toggle to `left: 12px` and centres it in the band, which is why [`BAR_H`]
//! and [`CONTROL_TOP`] are not free parameters but answers to dsh's layout.
//!
//! The geometric fallback that used to sit underneath is deleted. It found
//! columns by geometry in a document whose CSS-Modules class names are rehashed
//! every build, then wrote padding and transforms onto whatever it believed was
//! a column; the pass that once "padded list items and conversation bubbles" was
//! that code with the wrong anchor. Reading a custom property dsh publishes is a
//! conversation with dsh, and guessing is not.

/// Design height of the whole bar, in logical pixels.
///
/// Not a number of our own choosing. dsh centres its sidebar toggle as
/// `top: calc((var(--dsh-windows-titlebar-height) - 28px) / 2)` against a 28px
/// button, so the caption has to be *taller* than 28 for the toggle to land
/// inside it rather than on the window's edge — and at exactly 28 the formula
/// returns 0, which parks a 28px button flush against the top of the window.
///
/// [`CONTROL_TOP`] is what makes the choice deliberate: 36 puts the toggle at
/// `(36-28)/2 = 4`, the same top edge our own controls use. [`tests`] states it
/// as that alignment rather than as the number 36, so the reason survives the
/// next edit.
pub const BAR_H: f64 = 36.0;
/// Design width of one window button.
pub const WIN_W: f64 = 32.0;
/// Corner radius of a button's hover background.
pub const CORNER_R: f64 = 5.0;
/// The box every caption control occupies, top edge to bottom.
///
/// **Exactly the box dsh gives its own sidebar toggle**: 28 tall, starting at
/// [`CONTROL_TOP`]. Matching it rather than filling the caption is what puts the
/// three controls on one line. Our row used to be `BUTTON_GAP..BAR_H`, i.e. 4..36
/// — same top edge, 4px taller — so the centres were 2px apart permanently, and
/// no choice of `BAR_H` could fix it: dsh's centre is always `BAR_H / 2` and
/// ours was always `BAR_H / 2 + gap / 2`.
pub const CONTROL_H: f64 = 28.0;
/// Where every caption control starts, measured from the window's top.
///
/// Derived from [`BAR_H`] and [`CONTROL_H`] rather than chosen, because it has to
/// equal whatever dsh's own formula produces for the height we declared. If these
/// two ever disagree, the sidebar toggle sits on a different line from the window
/// buttons — which is exactly what a screenshot showed.
pub const CONTROL_TOP: f64 = (BAR_H - CONTROL_H) / 2.0;
/// The height of dsh's sidebar toggle, from the same rule.
#[cfg(test)]
const DSH_TOGGLE_H: f64 = 28.0;

/// Width the chrome occupies on the right: the three window buttons.
pub fn reserved_width() -> f64 {
    3.0 * WIN_W
}

/// Width of the window-button cluster.
///
/// A deliberate alias of [`reserved_width`], kept because both names read
/// correctly at their call sites: one is "how much of the page's right edge do
/// we own", the other is "how wide is the cluster". They are the same number
/// because the cluster *is* everything the chrome reserves.
pub fn window_cluster_width() -> f64 {
    reserved_width()
}

/// The script to inject, with the geometry baked in as `window.__DSH_SHELL__`.
///
/// Not a `const fn`: the include is fine either way, but keeping this next to
/// the constants makes it obvious that the script is generated, not a static
/// asset.
///
/// `os_scale` is the window's system DPI factor, injected so the script can tell
/// the page zoom apart from the display's own scaling by dividing
/// `devicePixelRatio` by it. Chromium applies zoom on top of the system factor
/// and Tauri has no getter for either, so this is the only way the menu can know
/// the current zoom while the hotkeys are Chromium's.
pub fn script(os_scale: f64) -> String {
    format!(
        "window.__DSH_SHELL__ = {{ osScale: {os_scale}, barH: {BAR_H}, winW: {WIN_W}, \
         cornerR: {CORNER_R}, controlH: {CONTROL_H}, controlTop: {CONTROL_TOP} }};\n{}",
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
    // Every caption control has to fit the bar with room left over, or there is
    // no band for dsh to reserve and its toggle lands on the window's edge.
    assert!(CONTROL_H <= BAR_H);
    assert!(CONTROL_TOP > 0.0, "the controls would sit flush against the window");
};

#[cfg(test)]
mod tests {
    use super::*;

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
        let js = script(1.0);
        for (name, value) in [
            ("barH", js_number(BAR_H)),
            ("winW", js_number(WIN_W)),
            ("cornerR", js_number(CORNER_R)),
            ("controlH", js_number(CONTROL_H)),
            ("controlTop", js_number(CONTROL_TOP)),
        ] {
            assert!(
                js.contains(&format!("{name}: {value}")),
                "{name} is not injected as {value}"
            );
        }
        assert!(js.contains(&format!("osScale: {}", js_number(1.0))), "{js}");
    }

    #[test]
    fn the_scripts_fallbacks_agree_with_those_constants() {
        // The script keeps a fallback for each injected value, for the case where
        // it is evaluated without its config. A fallback that disagrees with the
        // constant is a silently wrong chrome, so the two are checked here rather
        // than by eye - the fallbacks are already how a tuned value got lost once.
        let js = script(1.0);
        for (name, value) in [
            ("barH", js_number(BAR_H)),
            ("winW", js_number(WIN_W)),
            ("cornerR", js_number(CORNER_R)),
            ("controlH", js_number(CONTROL_H)),
            ("controlTop", js_number(CONTROL_TOP)),
        ] {
            assert!(
                js.contains(&format!("num(CFG.{name}, {value})")),
                "the script's fallback for {name} is not {value}"
            );
        }
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
        let script = script(1.0);
        assert!(script.contains("window.__DSH_SHELL__"), "{script}");
        assert!(script.contains("barH:"), "{script}");
        assert!(script.contains("osScale: 1"), "{script}");
        // The zoom control is gone, so its constant must not linger.
        assert!(!script.contains("zoomW"), "{script}");
        // The static part of the script must follow it.
        assert!(script.contains("dsh-shell-chrome"), "{script}");
    }

    /// The bar height is the one number the contract makes the host own, and dsh
    /// places its 28px sidebar toggle at `top: calc((height - 28px) / 2)`.
    ///
    /// Stated as *alignment* rather than as the number 36, because the number is
    /// only ever justified by this: at 28 the formula returns 0 and the toggle
    /// ends up flush against the window's top edge, which is what the screenshot
    /// showed. What we actually want is for its top edge to equal ours.
    #[test]
    fn dshs_toggle_lands_on_the_same_top_edge_as_our_button_row() {
        let toggle_top = (BAR_H - DSH_TOGGLE_H) / 2.0;
        assert!(
            (toggle_top - CONTROL_TOP).abs() < 1e-9,
            "dsh's toggle would start at {toggle_top}px while our controls start at {CONTROL_TOP}px"
        );
        // Same top edge is not enough on its own. Our row used to be
        // `CONTROL_TOP..BAR_H`, four pixels taller than dsh's toggle, so the
        // centres were permanently two pixels apart and no value of `BAR_H` could
        // have fixed it — which is what the first screenshot showed.
        assert!(
            (CONTROL_H - DSH_TOGGLE_H).abs() < 1e-9,
            "different heights, so the eye reads different lines"
        );
        assert_eq!(CONTROL_TOP + CONTROL_H / 2.0, toggle_top + DSH_TOGGLE_H / 2.0);
    }

    /// The caption's left edge is not ours to place a control in, and nothing in
    /// the script is allowed to try.
    ///
    /// dsh's contract pins its sidebar toggle to `left: 12px`, and when the sidebar
    /// is collapsed it *also* moves its new-session button to `left: 48px`. Any
    /// hardcoded x on the left is therefore a collision waiting for the sidebar to
    /// collapse — which is what the screenshot showed, the menu button sitting
    /// exactly on dsh's new-session button.
    ///
    /// Asserted against the generated script rather than against the constants,
    /// because "the constants are in a sensible order" is not the property: the
    /// property is that there is no coordinate to be wrong about. The menu button
    /// is placed by `margin-left:auto` in the bar's flex row, so it is pushed right
    /// by the layout instead of by an arithmetic that has to know what dsh claims.
    #[test]
    fn no_caption_control_is_placed_at_a_hardcoded_x() {
        let js = script(1.0);
        for stale in ["menuLeft", "MENU_LEFT", "buttonGap", "BUTTON_GAP"] {
            assert!(
                !js.contains(stale),
                "`{stale}` is the coordinate that collided with dsh; the menu button \
                 belongs in the flex row, not at an x"
            );
        }
        assert!(
            js.contains("margin-left:auto"),
            "and the menu button must still be pushed to the right by the layout"
        );
    }

    /// Both controls have to fit the caption vertically as well as clear each
    /// other horizontally, or the menu hangs below the bar it belongs to.
    #[test]
    fn both_caption_controls_fit_inside_the_bar() {
        for (name, top, height) in [
            ("dsh toggle", (BAR_H - DSH_TOGGLE_H) / 2.0, DSH_TOGGLE_H),
            ("menu button", CONTROL_TOP, CONTROL_H),
            ("window buttons", CONTROL_TOP, CONTROL_H),
        ] {
            assert!(top >= 0.0, "{name} starts above the window: {top}px");
            assert!(
                top + height <= BAR_H + 1e-9,
                "{name} ends at {}px, below the {BAR_H}px bar",
                top + height
            );
        }
    }

    /// The contract layer is not optional. Without it the chrome silently falls
    /// back to guessing the page's geometry, and the chrome *looks* fine, so
    /// nothing would report the regression.
    #[test]
    fn the_script_declares_the_desktop_contract() {
        let script = script(1.0);
        assert!(script.contains("data-windows-titlebar"), "{script}");
        assert!(script.contains("--dsh-windows-titlebar-height"), "{script}");
        // And it must read back what dsh publishes rather than assuming it.
        assert!(script.contains("--dsh-frame-chrome-top"), "{script}");
        assert!(script.contains("--dsh-frame-top-clearance"), "{script}");
    }

    /// The two states must stay distinguishable, or a dsh that stopped honouring
    /// the contract would be invisible: the window would look right and nothing
    /// would be reserving the caption.
    #[test]
    fn the_script_distinguishes_the_contract_from_its_absence() {
        let script = script(1.0);
        assert!(script.contains("contractActive"), "{script}");
        assert!(script.contains("contractMissing"), "{script}");
    }
}
