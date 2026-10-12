// Extracts dsh's whale path from the installed dsh into Swift source.
//
// Run directly:  swift tools/extract-dsh-logo.swift
// Normally run by scripts/build-app.sh before the build.
//
// Why a script rather than a hardcoded string: the whale is dsh's brand and
// lives in its package. Copying it by hand means a dsh upgrade silently leaves
// the menu bar showing the old mark, and nobody notices until someone compares
// it against the web UI.
//
// Why the output is committed rather than regenerated on every build: the
// build must not depend on dsh being installed. `dsh` resolves through PATH at
// runtime and the app is expected to work on a machine where the CLI is absent
// or in an unusual place. So the generated file is in git as the fallback, and
// this script only *refreshes* it when it can find a real dsh — rewriting only
// on a genuine change, so an unchanged extraction leaves no git diff.
//
// dsh's own type declaration gives the path but types the viewBox as
// `{width: number; height: number}` with no values, so the bounding box is
// computed from the path instead.

import Foundation

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tools/
    .deletingLastPathComponent()   // macos/

/// Same candidate order as `ShellSettings.defaultBinaryPath()`, so the script
/// finds the dsh the app would actually use.
func candidateRoots() -> [URL] {
    var out: [URL] = []
    let home = NSHomeDirectory()
    out.append(URL(fileURLWithPath: home).appendingPathComponent(".npm-global/bin/dsh"))
    out.append(URL(fileURLWithPath: home).appendingPathComponent(".local/bin/dsh"))
    for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix"] {
        if let prefix = ProcessInfo.processInfo.environment[key], !prefix.isEmpty {
            out.append(URL(fileURLWithPath: prefix).appendingPathComponent("bin/dsh"))
        }
    }
    out.append(URL(fileURLWithPath: "/opt/homebrew/bin/dsh"))
    out.append(URL(fileURLWithPath: "/usr/local/bin/dsh"))
    out.append(URL(fileURLWithPath: home)
        .appendingPathComponent(".nvm/versions/node")
        .appendingPathComponent("*/bin/dsh"))
    return out
}

func expandGlob(_ pattern: URL) -> [URL] {
    let fm = FileManager.default
    let dir = pattern.deletingLastPathComponent()
    let leaf = pattern.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
    return entries
        .filter { leaf == "*" || $0.hasPrefix(String(leaf.dropLast())) }
        .sorted(by: >)
        .map { dir.appendingPathComponent($0) }
}

/// Resolve the dsh shim to the package tree holding `dsh-client-ui-primitives`.
/// Returns the package's `lib` directory.
func findPackageLibDirectory() -> URL? {
    let fm = FileManager.default
    for candidate in candidateRoots().flatMap({ $0.lastPathComponent == "dsh" ? [$0] : expandGlob($0) }) {
        let resolved = URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: resolved.path) else { continue }

        // Walk up from the executable looking for the UI primitives package.
        var dir = resolved.deletingLastPathComponent()
        for _ in 0..<8 {
            for relative in [
                "node_modules/@deepseek-ai/dsh-client-ui-primitives/lib/types/FishLogo.d.ts",
                "../dsh-client-ui-primitives/lib/types/FishLogo.d.ts",
            ] {
                let probe = dir.appendingPathComponent(relative).standardizedFileURL
                if fm.fileExists(atPath: probe.path) {
                    // …/dsh-client-ui-primitives/lib/types/FishLogo.d.ts → …/lib
                    return probe.deletingLastPathComponent().deletingLastPathComponent()
                }
            }
            dir = dir.deletingLastPathComponent()
        }
    }
    return nil
}

struct Extracted {
    let pathData: String
    let viewBoxWidth: Double
    let viewBoxHeight: Double
    let source: String
}

func extract(path file: URL, bundle: URL) -> Extracted? {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
          let bundled = try? String(contentsOf: bundle, encoding: .utf8) else { return nil }

    // The declaration is a single line: `export declare const FISH_LOGO_PATH = "...";`
    // Match on the assignment, not the bare name: the doc comment two lines above
    // it also mentions {@link FISH_LOGO_PATH} and comes first, so searching for
    // the identifier alone picks up a comment with no quotes in it.
    guard let line = text.split(separator: "\n").first(where: {
        $0.contains("const FISH_LOGO_PATH")
    }), let open = line.firstIndex(of: "\""),
          let close = line[line.index(after: open)...].lastIndex(of: "\"")
    else { return nil }
    let pathData = String(line[line.index(after: open)..<close])
    guard !pathData.isEmpty else { return nil }

    // Prefer dsh's own `FISH_LOGO_VIEWBOX` — the same numbers its `FishLogo`
    // component writes into `viewBox="0 0 …"`. Those are authoritative, and
    // computing a bounding box from the path instead is actively wrong: the
    // path's extremes (minX is *negative*) fall outside the canvas dsh chose, so
    // the raw bounds come out 23.3967 x 17.1921 rather than 23.16 x 17.04.
    // Using them would render the whale a percent or two larger than the web UI
    // shows, and off-centre.
    //
    // The `.d.ts` types these as `{width: number; height: number}` and leaves
    // the values out, so this only resolves against the filled-in declaration.
    func viewBoxSize() -> (Double, Double)? {
        // The viewBox lives in the bundled JS, not the `.d.ts`: the declaration
        // file types `width`/`height` as `number` and never fills them in.
        guard let declaration = bundled.range(of: "FISH_LOGO_VIEWBOX = {") else { return nil }
        let tail = String(bundled[declaration.upperBound...].prefix(240))
        // Plain scanning rather than a regex: this script runs under `swift
        // script.swift`, which is an interpreter and does not carry the regex
        // literal syntax.
        func number(after key: String) -> Double? {
            guard let at = tail.range(of: key) else { return nil }
            // `width: 23.16` has a space (and the declaration is tab-indented
            // with a newline before it), so skip to the digits before reading.
            var rest = tail[at.upperBound...].drop { $0.isWhitespace }
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            rest = digits
            return Double(rest)
        }
        guard let width = number(after: "width:"), let height = number(after: "height:")
        else { return nil }
        return (width, height)
    }

    guard let (viewBoxWidth, viewBoxHeight) = viewBoxSize() else { return nil }

    return Extracted(pathData: pathData,
                     viewBoxWidth: viewBoxWidth.rounded(toPlaces: 4),
                     viewBoxHeight: viewBoxHeight.rounded(toPlaces: 4),
                     source: file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}

let destination = root.appendingPathComponent(
    "Sources/DSHShellCore/Services/DSHFishLogo.generated.swift")

guard let lib = findPackageLibDirectory() else {
    // Fallback by design: keep whatever is already committed.
    if FileManager.default.fileExists(atPath: destination.path) {
        FileHandle.standardError.write(Data("extract-dsh-logo: dsh not found; keeping committed whale\n".utf8))
        exit(0)
    }
    FileHandle.standardError.write(Data("extract-dsh-logo: dsh not found and no generated file to fall back on\n".utf8))
    exit(1)
}

let declaration = lib.appendingPathComponent("types/FishLogo.d.ts")
let bundle = lib.appendingPathComponent("index.js")

guard let found = extract(path: declaration, bundle: bundle) else {
    FileHandle.standardError.write(Data("extract-dsh-logo: found \(lib.path) but could not parse the whale; keeping committed one\n".utf8))
    exit(0)
}

let generated = """
// Generated by tools/extract-dsh-logo.swift — do not edit.
//
// dsh's whale, as it appears in the web UI's sidebar, so the menu bar carries the
// same mark instead of a stand-in. The path is dsh's own `FISH_LOGO_PATH`:
//
//   \(found.source)
//
// …and the canvas is the `FISH_LOGO_VIEWBOX` constant declared alongside it.
//
// `width`/`height` are dsh's own `FISH_LOGO_VIEWBOX` — the canvas its component
// declares, which is slightly larger than the path's bounding box and is not
// origin-aligned with it. The renderer maps the viewBox, not the path bounds.

/// The whale's geometry, in the SVG user units dsh authored it in.
public enum DSHFishLogoGeometry {
    /// dsh's own `FISH_LOGO_VIEWBOX.width`, the width of the canvas its
    /// `FishLogo` component declares.
    public static let width: Double = \(found.viewBoxWidth)

    /// dsh's own `FISH_LOGO_VIEWBOX.height`.
    public static let height: Double = \(found.viewBoxHeight)

    /// The raw `d` attribute. Uses only `M`, `L`, `C` and `Z`.
    public static let pathData = "\(found.pathData)"
}

"""

// Rewrite only on a real change, so an unchanged extraction leaves no git diff.
if let existing = try? String(contentsOf: destination, encoding: .utf8), existing == generated {
    print("extract-dsh-logo: whale unchanged (\(found.viewBoxWidth) × \(found.viewBoxHeight))")
    exit(0)
}
try generated.write(to: destination, atomically: true, encoding: .utf8)
print("extract-dsh-logo: wrote \(destination.lastPathComponent) (\(found.viewBoxWidth) × \(found.viewBoxHeight))")