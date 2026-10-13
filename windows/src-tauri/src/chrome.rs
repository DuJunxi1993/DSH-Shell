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
/// Gap between the window buttons and the window's right edge.
///
/// Windows puts a maximized window's controls hard against the corner, and
/// against dsh's own surface that reads as the ✕ being part of the page rather
/// than part of the caption. A small inset fixes it.
///
/// It is also the offset the zoom panel is placed by, since the panel hangs from
/// the menu button's right edge: it must clear the window buttons *and* this
/// inset, or it slides under the ✕.
pub const EDGE_INSET: f64 = 10.0;
/// Width from the window's right edge to the menu button's left edge: the window
/// buttons plus the inset between them and the frame.
pub fn chrome_right_edge() -> f64 {
    reserved_width() + EDGE_INSET
}
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
         cornerR: {CORNER_R}, controlH: {CONTROL_H}, controlTop: {CONTROL_TOP}, \
         edgeInset: {EDGE_INSET} }};\n{}",
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
    // An inset that swallowed a button, or a negative one, would both be wrong in
    // the same way: the caption would no longer line up with the window's edge.
    assert!(EDGE_INSET >= 0.0 && EDGE_INSET < WIN_W, "the inset is not a gap between controls");
    assert!(
        CONTROL_H <= BAR_H - CONTROL_TOP,
        "the control box must sit inside the band dsh reserves"
    );
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
            ("edgeInset", js_number(EDGE_INSET)),
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
            ("edgeInset", js_number(EDGE_INSET)),
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

    /// A caption control must not carry an inline `background`.
    ///
    /// An inline background outranks every stylesheet rule, `:hover` included, so
    /// the menu button had no hover highlight while the window buttons beside it
    /// did — the stylesheet rule was correct, it was simply being overridden. This
    /// is the second time this file has been bitten by it, which is why
    /// `installStylesheet` says so in a comment and `control()` omits it.
    #[test]
    fn no_caption_control_carries_an_inline_background() {
        let js = script(1.0);
        assert!(
            !js.contains("\"background:transparent\""),
            "an inline background defeats the :hover rules in the stylesheet: {js}"
        );
    }

    /// The menu glyph must be drawn from real elements.
    ///
    /// It used to be one `border-top` plus two `box-shadow`s, which draws two more
    /// 1.5px lines only while the element's border box *is* 1.5px tall. Giving it
    /// the 11px height that centring needs turned the same two shadows into an
    /// 11px filled block — a black rectangle in place of the hamburger.
    #[test]
    fn the_menu_glyph_is_not_drawn_with_box_shadow() {
        let js = script(1.0);
        // Scoped to the technique, not to `box-shadow` at all: the zoom panel
        // legitimately has a drop shadow. What cannot work is casting an extra
        // copy of a *border* with an offset, because a shadow follows the border
        // box — so the moment the element is given a height so it can be centred,
        // those "lines" become a filled block. That is the black rectangle.
        assert!(
            !js.contains("0 currentColor"),
            "the glyph must not be drawn by casting offset copies of its border: {js}"
        );
        // And it must be three real bars, which is what behaves.
        assert!(
            js.contains("flex-direction:column") && js.contains("for (var i = 0; i < 3; i++)"),
            "the glyph should be three child elements in a column: {js}"
        );
    }

    /// Clicking the menu button must not also count as clicking "outside".
    ///
    /// The dismiss handler runs in the capture phase, before the button's own
    /// handler. With `event.target === menuButton` it never matched, because a
    /// click lands on the glyph *inside* the button: the panel closed and then
    /// immediately reopened, and the menu could not be shut.
    #[test]
    fn the_dismiss_handler_tests_containment_not_identity() {
        let js = script(1.0);
        assert!(
            js.contains("menuButton.contains(event.target)"),
            "the dismiss handler must use contains(): {js}"
        );
        assert!(
            !js.contains("event.target === menuButton"),
            "an identity test misses clicks that land on the button's children: {js}"
        );
    }

    /// Every key Rust injects must actually be read, and every key the script
    /// reads must actually be injected.
    ///
    /// This exists because of a bug it would have caught: an edit dropped
    /// `var OS_SCALE = num(CFG.osScale, 1)` from the script while Rust kept
    /// injecting `osScale`. Every other test passed — they check that each
    /// constant is *injected*, which was still true — and the chrome died at
    /// runtime with `ReferenceError: OS_SCALE is not defined`, so the window had
    /// no title bar at all and nothing failed until somebody looked at the log.
    #[test]
    fn the_injected_config_and_the_script_agree_on_their_keys() {
        let js = script(1.0);

        let injected: Vec<String> = js
            .split("window.__DSH_SHELL__ = {")
            .nth(1)
            .and_then(|rest| rest.split('}').next())
            .map(|block| {
                block
                    .split(',')
                    .filter_map(|pair| pair.split(':').next())
                    .map(|name| name.trim().to_string())
                    .filter(|name| !name.is_empty() && !name.contains('{'))
                    .collect()
            })
            .unwrap_or_default();
        assert!(!injected.is_empty(), "could not read the injected config: {js}");

        let read: Vec<String> = {
            let mut names: Vec<String> = Vec::new();
            let mut rest = js.as_str();
            while let Some(at) = rest.find("CFG.") {
                rest = &rest[at + 4..];
                let name: String = rest
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                    .collect();
                if !name.is_empty() {
                    names.push(name);
                }
            }
            names
        };

        for key in &injected {
            assert!(
                read.contains(key),
                "Rust injects `{key}` but the script never reads it — a silent dead value, \
                 and if its `var` was lost the whole chrome throws at runtime"
            );
        }
        for key in &read {
            assert!(
                injected.contains(key),
                "the script reads `CFG.{key}`, which Rust does not inject, so it silently \
                 falls back to the literal"
            );
        }
    }

    /// Every control we own must opt out of dsh's drag strip.
    ///
    /// The contract paints `.frame::before` with `-webkit-app-region: drag`
    /// across the entire caption, and our controls sit on top of it. Chromium
    /// collects drag regions by bounds, so a control that does not declare its own
    /// app-region does not mask the strip beneath it — two quick clicks on the
    /// menu button were read as a double-click on a drag region, and the window
    /// maximised itself instead of the menu opening and closing.
    ///
    /// dsh applies `no-drag` to its own sidebar toggle for the same reason. The
    /// rest of the caption must stay draggable, so this is asserted on the
    /// controls and not on the bar.
    #[test]
    fn our_controls_opt_out_of_the_captions_drag_region() {
        let js = script(1.0);
        let no_drag = js.matches("-webkit-app-region:no-drag").count();
        // Two source sites, not four: `control()` builds all three window buttons,
        // so one declaration covers minimize/maximize/close at runtime. Counting
        // source occurrences is the only thing available here, and it is what
        // this is really guarding — that `control()` did not lose its own.
        assert!(
            no_drag >= 2,
            "the menu button and `control()` must both declare no-drag, found {no_drag}: {js}"
        );
        assert!(
            !js.contains("-webkit-app-region:drag"),
            "the caption itself must stay draggable — only our controls opt out: {js}"
        );
    }

    /// The menu button's hover highlight has to be shaped like its neighbours'.
    ///
    /// Its background comes from the stylesheet's `:hover` rule, which carries no
    /// radius — each control sets its own inline, because the radius is geometry
    /// and has to track the zoom from one place. The menu button was the one
    /// control that never got one, so its highlight was a square rectangle sitting
    /// beside three rounded ones.
    #[test]
    fn every_caption_control_shares_one_corner_radius() {
        let js = script(1.0);
        let rounded = js.matches("\"border-radius:\" + px(CORNER_R)").count();
        assert!(
            rounded >= 2,
            "the menu button and the shared `control()` must both use CORNER_R, found {rounded}"
        );
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
