#!/usr/bin/env bash
#
# Build the deliverable DSH Shell.app.
#
# One command, from a fresh clone, with no manual steps:
#
#     ./scripts/build-app.sh              # Release
#     ./scripts/build-app.sh --debug      # Debug
#     ./scripts/build-app.sh --run        # Release, then launch it
#
# Why this script exists at all, given `swift build` also compiles the code:
#
#   - `swift build` produces a bare Mach-O executable. There is no bundle, so no
#     Info.plist, no bundle identifier, and no resource bundle — `bridge.js` and
#     `dsh_desktop_bridge.js` are simply absent, and the JS bridge silently does
#     not exist. That is not a build error; it is a feature that quietly is not
#     there.
#   - The .xcodeproj is generated from project.yml by xcodegen. The generated
#     shared scheme is committed, which is what makes `-scheme DSHShell` work on
#     a fresh clone. Regenerate with `xcodegen generate` after editing
#     project.yml; never hand-edit the project.
#
# Toolchain: this machine has Xcode at /Applications/Xcode-beta.app but
# `xcode-select -p` points at CommandLineTools, so `xcodebuild` is not on PATH.
# The script sets DEVELOPER_DIR for its own process rather than changing any
# global setting, because pointing `xcode-select` at a beta would silently move
# every other tool on the machine onto it.
#
# Architecture: arm64 only. `platform=macOS` alone matches both arm64 and
# x86_64 on Apple silicon and xcodebuild picks the wrong one, which fails the
# build inside Swift's prebuilt-module set rather than on anything the project
# controls.
#
# Signing: ad-hoc. There are no signing identities on this machine
# (`security find-identity -p codesigning` returns none), so the app is signed
# locally and runs here, but Gatekeeper will quarantine it if it arrives from
# anywhere else. See the README for the one-time step.

set -euo pipefail

CONFIGURATION="Release"
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIGURATION="Debug" ;;
    --release) CONFIGURATION="Release" ;;
    --run)     LAUNCH=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"          # macos/
REPO="$(dirname "$ROOT")"          # repository root

# --- toolchain ---------------------------------------------------------------

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in /Applications/Xcode*.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
if [[ -z "${DEVELOPER_DIR:-}" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "error: no usable Xcode found. Set DEVELOPER_DIR to a full Xcode, not the" >&2
  echo "       CommandLineTools — an .app bundle cannot be produced without it." >&2
  exit 3
fi
echo "==> toolchain: $(xcodebuild -version | head -1)"

command -v xcodegen >/dev/null || {
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 3
}

# --- the injected scripts, checked before anything is built ----------------
#
# A syntax error in either script is invisible at runtime in the worst possible
# way: `dsh_desktop_bridge.js` sets `data-platform='darwin'` as its first
# statement, so a script that throws immediately leaves dsh in the desktop
# runtime with no bridge — and the Web UI then never finishes booting. The probe
# hit exactly this and it cost two rounds of misdiagnosis.
if command -v node >/dev/null; then
  for js in "$ROOT/Sources/DSHShell/Bridge/bridge.js" \
            "$ROOT/Sources/DSHShell/Bridge/dsh_desktop_bridge.js"; do
    node --check "$js" || { echo "error: syntax error in $js" >&2; exit 4; }
  done
  echo "==> injected scripts: syntax ok"
else
  echo "==> node not found; skipping the injected-script syntax check"
fi

# --- generate, test, build ---------------------------------------------------

echo "==> generating the Xcode project from project.yml"
(cd "$ROOT" && xcodegen generate)

echo "==> running the hermetic test suite"
# Never boots a real dsh: the lifecycle tests drive `stub-dsh`. A failure here
# means the app is not worth packaging.
#
# `swift test` does NOT compile the app target — only the core library, the
# bridge shim and stub-dsh are reachable from the tests. That is how
# `Bundle.module` (which exists only under SwiftPM) survived to the Xcode build,
# where it does not compile. `swift build` covers the gap in the other
# direction, so both build systems see every source file.
(cd "$ROOT" && DEVELOPER_DIR="$DEVELOPER_DIR" swift test)
(cd "$ROOT" && DEVELOPER_DIR="$DEVELOPER_DIR" swift build)

BUILD_DIR="$ROOT/build/$CONFIGURATION"
echo "==> building $CONFIGURATION"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -project "$ROOT/DSHShell.xcodeproj" \
  -scheme DSHShell \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -destination "platform=macOS,arch=arm64" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build | tail -20

APP="$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION/DSHShell.app"
if [[ ! -d "$APP" ]]; then
  echo "error: expected $APP but it is not there" >&2
  exit 5
fi

echo
echo "==> built $APP"
echo "    size:      $(du -sh "$APP" | cut -f1)"
echo "    version:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "    bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo
echo "    The two injected scripts must be present — without them the JS bridge and"
echo "    the desktop runtime are silently absent:"
for f in bridge.js dsh_desktop_bridge.js; do
  if [[ -f "$APP/Contents/Resources/$f" ]]; then
    echo "      ok   $f"
  else
    echo "      MISSING $f"
    exit 6
  fi
done

# --- launch smoke test -------------------------------------------------------
#
# A crash during `applicationDidFinishLaunching` produces a perfectly good .app,
# green tests, and a window that never appears — the user gets a dock icon and
# no dsh. It is the worst failure this project can ship, and it is invisible to
# `swift test` because that never compiles or launches the app.
#
# This caught a real one: a `MainActor.assumeIsolated` inside
# `UNUserNotificationCenter.requestAuthorization`'s completion, which arrives on
# an internal queue rather than the main thread, so the isolation assertion
# trapped before the window existed.
echo "==> smoke test: launching for 8s and checking it stays up"
SMOKE_LOG="$(mktemp -t dsh-shell-smoke)"
SMOKE_PID=""
cleanup_smoke() {
  if [[ -n "$SMOKE_PID" ]]; then kill "$SMOKE_PID" 2>/dev/null || true; fi
  rm -f "$SMOKE_LOG"
}
trap cleanup_smoke EXIT

DSH_HOME="$(mktemp -d -t dsh-shell-smoke-home)"
DSH_HOME="$DSH_HOME" "$APP/Contents/MacOS/DSHShell" >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
sleep 8
if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
  echo "error: the app exited within 8s of launch — it crashes on startup." >&2
  echo "       Output was:" >&2
  sed 's/^/         /' "$SMOKE_LOG" >&2
  exit 7
fi
kill -TERM "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
SMOKE_PID=""
rm -f "$SMOKE_LOG"
rm -rf "$DSH_HOME"
echo "    ok   stayed up"

cat <<EOF

To run it:
    open "$APP"

If Gatekeeper refuses ("cannot be opened because the developer cannot be
verified"), right-click the app once and choose Open, or:

    xattr -dr com.apple.quarantine "$APP"

That is a one-time step and only applies to a copy that came from somewhere
else. An app built here by this script is not quarantined.
EOF

if [[ "$LAUNCH" == "1" ]]; then
  echo "==> launching"
  open "$APP"
fi