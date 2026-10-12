import AppKit
import DSHShellCore

/// dsh's whale, drawn as a menu bar template image.
///
/// ## Why this is drawn rather than copied
///
/// dsh ships the whale as an SVG path, and the web UI renders it with
/// `currentColor`, which the webview resolves per appearance. The menu bar has
/// no stylesheet to inherit: AppKit expects an `NSImage` and applies its own
/// rules for light and dark appearances.
///
/// ## Why it is a template image
///
/// Setting `isTemplate` is what hands those rules to AppKit. The menu bar draws
/// template images as black-on-light and white-on-dark automatically, and
/// treats them as monochrome when the user turns on "Reduce transparency" or
/// switches to a high-contrast appearance. Building that as two hardcoded PNGs
/// would mean tracking every appearance macOS ships, and drifting out of date
/// the first time it shipped another.
///
/// A fixed-colour image would be wrong in a more basic way: it is what this
/// replaced. The previous note here said dsh's whale "cannot be used as-is"
/// because it is a coloured SVG. That was true of the *file* and not of the
/// *shape* — the path is monochrome fill, so redrawing it as a silhouette is
/// both faithful to the brand and what the platform wants.
enum FishLogoImage {
    /// Height in points. The menu bar is 22pt tall on current macOS; this
    /// leaves the usual breathing room rather than filling the whole strip.
    static let height: CGFloat = 14

    /// Width for `height`, from the whale's own aspect ratio.
    static var width: CGFloat {
        height * CGFloat(DSHFishLogoGeometry.width / DSHFishLogoGeometry.height)
    }

    /// The whale as a template image, or `nil` if the committed geometry cannot
    /// be parsed.
    ///
    /// `nil` is the fallback path for an unsupported path grammar: the status
    /// item then shows an SF Symbol rather than an empty slot.
    static func make() -> NSImage? {
        guard let commands = SVGPathGeometry.parse(DSHFishLogoGeometry.pathData),
              let outline = outlinePath(for: commands)
        else { return nil }

        // Filled black; `isTemplate` is what discards this colour. Building it
        // as a drawing handler keeps the whale a vector at any menu bar scale,
        // including the Retina 2x pass.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            outline.addClip()
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The whale's outline in CoreGraphics space, scaled to `width × height`.
    ///
    /// This is the only place the coordinate systems meet. SVG y grows
    /// **downwards**; AppKit's context grows **upwards**. Missing the flip does
    /// not throw or draw nothing — it draws the whale upside down, which looks
    /// like a bug in dsh's artwork rather than in this code. Hence the explicit
    /// `height - y`.
    ///
    /// The mapping is onto dsh's `FISH_LOGO_VIEWBOX`, not onto the path's
    /// bounding box. The path's extremes overshoot that canvas slightly (its
    /// minimum x is negative), so fitting the bounds instead would render the
    /// whale marginally larger than the web UI does and nudge it off centre.
    private static func outlinePath(for commands: [SVGPathGeometry.Command]) -> NSBezierPath? {
        let path = NSBezierPath()
        var hasCurrentPoint = false
        let viewBoxWidth = DSHFishLogoGeometry.width
        let viewBoxHeight = DSHFishLogoGeometry.height

        /// Map one SVG point into the image's rectangle, y flipped.
        func place(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: CGFloat(x / viewBoxWidth) * width,
                    y: height - CGFloat(y / viewBoxHeight) * height)
        }

        for command in commands {
            switch command {
            case .move(let x, let y):
                path.move(to: place(x, y))
                hasCurrentPoint = true
            case .line(let x, let y):
                guard hasCurrentPoint else { return nil }
                path.line(to: place(x, y))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                guard hasCurrentPoint else { return nil }
                path.curve(to: place(x, y),
                           controlPoint1: place(x1, y1),
                           controlPoint2: place(x2, y2))
            case .close:
                guard hasCurrentPoint else { return nil }
                path.close()
            }
        }
        // A subpath with no closing command would render as an open stroke and
        // fill as a straight chord, which is not the brand mark.
        return hasCurrentPoint ? path : nil
    }
}