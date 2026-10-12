import Foundation

/// Finds a bundled resource in a build system we do not control.
///
/// ## Why this exists rather than `Bundle.module`
///
/// `Bundle.module` is a SwiftPM-only accessor. The app is built by two build
/// systems from the same sources — `swift build` and the XcodeGen project — and
/// the Xcode target has no generated accessor, so a reference to it compiles
/// under SwiftPM and fails under Xcode with "type 'Bundle' has no member
/// 'module'". One build system passing while the other fails is worse than
/// either failing.
///
/// ## The two layouts
///
/// In the `.app` the scripts are copied into the bundle's `Contents/Resources`,
/// so `Bundle.main` finds them.
///
/// Under SwiftPM an executable target's resources do *not* go into any bundle:
/// they are copied into a sibling `<executable>_<target>.bundle` next to the
/// binary. Nothing in `Bundle` finds those without the generated accessor, so
/// they are found by looking beside the executable instead.
///
/// A resource that cannot be located is the one failure worth caring about in
/// this project — `dsh_desktop_bridge.js` missing means the desktop runtime is
/// never declared — so both layouts are searched and the caller decides what a
/// miss means.
public enum ResourceLocator {
    /// Searches `bundle` and then any `*.bundle` directory sitting beside it.
    ///
    /// `container` is the directory that may hold SwiftPM resource bundles:
    /// the app's own `Contents` for a built `.app`, or the executable's
    /// directory under SwiftPM. It is injectable so the SwiftPM branch can be
    /// tested without building the package.
    public static func url(forResource name: String,
                           withExtension ext: String,
                           in bundle: Bundle,
                           container: URL? = nil) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        guard let container else { return nil }
        return url(forResource: name, withExtension: ext, inBundleDirectory: container)
    }

    /// One half of `url(forResource:withExtension:in:container:)`, separated so
    /// the SwiftPM layout can be tested directly: a temp directory holding a
    /// binary and a `<name>.bundle` beside it.
    public static func url(forResource name: String,
                           withExtension ext: String,
                           inBundleDirectory container: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for candidate in contents where candidate.pathExtension == "bundle" {
            guard let scoped = Bundle(url: candidate),
                  let url = scoped.url(forResource: name, withExtension: ext)
            else { continue }
            return url
        }
        return nil
    }

    /// The directory a SwiftPM executable's resource bundles live in.
    ///
    /// `Bundle.main.bundleURL` is the executable's directory for a bare
    /// SwiftPM binary and `MyApp.app/Contents` for a built app, so the same
    /// expression covers both without asking which build produced the binary.
    public static func defaultContainer(for bundle: Bundle = .main) -> URL {
        bundle.bundleURL
    }
}