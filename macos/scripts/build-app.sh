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
# Signing: ad-hoc by default, with the designated requirement re-pinned to the
# bundle identifier rather than a cdhash. A cdhash requirement changes on every
# build, and macOS keys a Screen Recording grant to the requirement — so an
# unmodified ad-hoc build loses its permission each time it is rebuilt. If a
# code-signing identity named "DSHShell Local" exists in the keychain it is used
# instead (override with DSH_SHELL_SIGN_IDENTITY).

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

# Refresh the menu bar whale from the installed dsh, before anything compiles.
# This is deliberately non-fatal: the generated file is committed, so a machine
# without dsh — or with one too old to have the logo — still builds, and simply
# keeps the whale it already has.
echo "==> refreshing the menu bar whale from dsh"
(cd "$ROOT" && DEVELOPER_DIR="$DEVELOPER_DIR" swift tools/extract-dsh-logo.swift) \
  || echo "    (whale not refreshed; using the committed one)"

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

# --- signing -----------------------------------------------------------------
#
# Re-signing is not cosmetic. TCC keys a Screen Recording grant to the app's
# *designated requirement*, and an ad-hoc signature's requirement is
# `cdhash H"…"` — a value that is different for every build. So each rebuild
# silently becomes a different app to TCC: the grant stays attached to a binary
# that no longer exists, the toggle in System Settings still looks ON, and the
# next capture attempt prompts again. That is the bug this step removes.
#
# Re-signing pins the requirement to the bundle identifier, which is stable
# across rebuilds and copies. When a code-signing identity exists it is used
# instead, and the requirement also pins the certificate.
#
# Inside-out order matters: the app's seal covers the frameworks' own hashes,
# so the frameworks are signed first.
echo "==> signing"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
ENTITLEMENTS="$ROOT/App/DSHShell/DSHShell.entitlements"

SIGN_IDENTITY="${DSH_SHELL_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -p codesigning -v 2>/dev/null | grep -q "DSHShell Local"; then
    SIGN_IDENTITY="DSHShell Local"
  else
    SIGN_IDENTITY="-"
  fi
fi

for framework in "$APP"/Contents/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  codesign --force --sign "$SIGN_IDENTITY" "$framework" >/dev/null 2>&1 \
    || { echo "error: could not sign $framework" >&2; exit 6; }
done

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  REQUIREMENT="identifier \"$BUNDLE_ID\""
else
  CERT_SHA1="$(security find-certificate -c "$SIGN_IDENTITY" -p \
    | openssl x509 -inform pem -outform der \
    | shasum -a 1 | cut -d' ' -f1 | tr 'a-f' 'A-F')"
  REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
fi

codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" \
  -r="designated => $REQUIREMENT" "$APP" >/dev/null 2>&1 \
  || { echo "error: could not sign $APP" >&2; exit 6; }

# A requirement that names a cdhash is the defect coming back. Fail loudly
# rather than ship a build whose Screen Recording grant will not survive the
# next compile.
DESIGNATED="$(codesign -d -r- "$APP" 2>&1 | awk -F'=> ' '/designated/{print $2}')"
echo "    identity:    $SIGN_IDENTITY"
echo "    requirement: $DESIGNATED"
if [[ -z "$DESIGNATED" || "$DESIGNATED" == *cdhash* ]]; then
  echo "error: the designated requirement pins a cdhash, so a Screen Recording" >&2
  echo "       grant will be discarded on the next rebuild. Signing identity was" >&2
  echo "       '$SIGN_IDENTITY'." >&2
  exit 7
fi

codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  || { echo "error: the re-signed app does not verify" >&2; exit 7; }

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
# Two properties, because one is not enough:
#
#   1. It stays up. A crash during launch produces a valid bundle, green tests
#      and no window.
#   2. Quitting it releases the port. That is the shell's core promise — closing
#      the app ends the dsh session — and `swift test` verifies it against a
#      stub only.
#
# The first version of this check sent SIGTERM. On macOS that terminates a GUI
# app outright: `applicationWillTerminate` never runs, so `shutdownBlocking()`
# never runs, and the `dsh web` it started is orphaned holding the port. It left
# one behind every time, which is exactly how a later launch found 3080 occupied
# and died with EADDRINUSE. Quitting through AppleScript instead takes the same
# path ⌘Q does, and the port assertion below is what catches a regression in it.
#
# Everything is keyed to PIDs this script recorded itself. Nothing here kills by
# name — see docs/dsh-shell-contract.md §9, rule 1.
echo "==> smoke test: launch, then quit and check the port is released"
SMOKE_LOG="$(mktemp -t dsh-shell-smoke)"
SMOKE_HOME="$(mktemp -d -t dsh-shell-smoke-home)"
SMOKE_APP_PID=""
SMOKE_CHILD_PID=""
cleanup_smoke() {
  # Only ever the two PIDs recorded above, never a name.
  [[ -n "$SMOKE_CHILD_PID" ]] && kill -KILL "$SMOKE_CHILD_PID" 2>/dev/null
  [[ -n "$SMOKE_APP_PID" ]] && kill -KILL "$SMOKE_APP_PID" 2>/dev/null
  rm -rf "$SMOKE_LOG" "$SMOKE_HOME"
}
trap cleanup_smoke EXIT

port_is_free() {
  /usr/bin/nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 1 || return 0
}

# Read the configured port rather than hard-coding 3080, so this keeps working
# if the default ever moves.
PORT="$(/usr/libexec/PlistBuddy -c 'Print :DSHShellPort' "$APP/Contents/Info.plist" 2>/dev/null || true)"
PORT="${PORT:-3080}"
# The real port comes from settings; read the file the app would read.
SETTINGS="$HOME/Library/Application Support/dsh-swiftUI/settings.json"
if [[ -f "$SETTINGS" ]]; then
  PORT="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("preferredPort",3080))' "$SETTINGS" 2>/dev/null || echo "$PORT")"
fi

# Launch it the way a user does: through LaunchServices.
#
# Running the executable straight from this script (`"$APP/Contents/MacOS/
# DSHShell" &`) leaves the app alive but with no window — measured on macOS 27,
# and true of the unmodified tree too, so it is not a regression this check
# introduced. Without a window the scene never appears, `onAppear` never runs,
# no dsh is spawned, and the two things this check exists to prove cannot be
# observed at all. `open` also gives us --env and --stdout, so the smoke run
# still gets its own DSH_HOME and its own log.
SMOKE_BINARY="$APP/Contents/MacOS/DSHShell"

# Never smoke-test over the user's own session. Quitting is keyed to the bundle
# id, so a running instance — from /Applications, say — would be the one that
# quit, and its dsh would then be the orphan this test reports.
SMOKE_RUNNING="$(/usr/bin/pgrep -f "/DSHShell.app/Contents/MacOS/DSHShell" 2>/dev/null | head -1 || true)"
if [[ -n "$SMOKE_RUNNING" ]]; then
  echo "    --   skipped: dsh Shell is already running (pid $SMOKE_RUNNING)."
  echo "         Quit it and re-run this script to exercise the launch/quit path."
  exit 0
fi

DSH_HOME="$SMOKE_HOME" /usr/bin/open -n \
  --env "DSH_HOME=$SMOKE_HOME" \
  --stdout "$SMOKE_LOG" --stderr "$SMOKE_LOG" \
  "$APP"

# `open` reports no PID, so take the newest process running exactly this
# binary. The pattern is the app's own path, not a name: an installed copy at a
# different path cannot be adopted and killed by mistake.
for _ in $(seq 1 20); do
  SMOKE_APP_PID="$(/usr/bin/pgrep -f -- "$SMOKE_BINARY" 2>/dev/null | sort -n | tail -1 || true)"
  [[ -n "$SMOKE_APP_PID" ]] && break
  sleep 0.5
done
if [[ -z "$SMOKE_APP_PID" ]]; then
  echo "error: could not find the app process after launching it" >&2
  sed 's/^/         /' "$SMOKE_LOG" >&2
  exit 7
fi

sleep 8
if ! kill -0 "$SMOKE_APP_PID" 2>/dev/null; then
  echo "error: the app exited within 8s of launch — it crashes on startup." >&2
  echo "       Output was:" >&2
  sed 's/^/         /' "$SMOKE_LOG" >&2
  exit 7
fi
echo "    ok   stayed up"

# Whose dsh is this? Ask the app, not the port.
#
# An earlier version took whatever was listening on $PORT and called it its own.
# With the port already held by someone else, the app never spawned a dsh at all
# — so the check adopted a stranger's process, declared it orphaned, and killed
# it on the way out. The port is the symptom; parentage is the fact.
SMOKE_CHILD_PID=""
for _ in $(seq 1 40); do
  # `|| true`: with `set -e` a failing command substitution aborts the script,
  # and `pgrep` exits 1 whenever there is no child to find — which is the
  # normal state for the first half second, and an expected one in attach mode.
  SMOKE_CHILD_PID="$(/usr/bin/pgrep -P "$SMOKE_APP_PID" 2>/dev/null | head -1 || true)"
  [[ -n "$SMOKE_CHILD_PID" ]] && break
  sleep 0.5
done
if [[ -n "$SMOKE_CHILD_PID" ]]; then
  echo "    ..   the app spawned dsh pid $SMOKE_CHILD_PID"
else
  # No child. Either the port was already taken so it refused to spawn (the
  # thing Preflight exists for), or it is in attach mode. Either way there is
  # nothing of ours to clean up, and claiming otherwise would mean killing
  # something that is not ours.
  PRE="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  if [[ -n "$PRE" ]]; then
    echo "    --   the app spawned no dsh; port $PORT is held by pid $PRE (not ours — left alone)"
  else
    echo "    --   the app spawned no dsh (attach mode?); nothing to verify"
  fi
fi

# Quit the way a user does, so the real teardown path runs.
osascript -e "tell application id \"ai.deepseek.dsh-shell\" to quit" >/dev/null 2>&1 ||   kill -TERM "$SMOKE_APP_PID" 2>/dev/null || true
for _ in $(seq 1 20); do
  kill -0 "$SMOKE_APP_PID" 2>/dev/null || break
  sleep 0.5
done
kill -0 "$SMOKE_APP_PID" 2>/dev/null && kill -KILL "$SMOKE_APP_PID" 2>/dev/null
wait "$SMOKE_APP_PID" 2>/dev/null || true
SMOKE_APP_PID=""

if [[ -n "$SMOKE_CHILD_PID" ]]; then
  for _ in $(seq 1 20); do
    kill -0 "$SMOKE_CHILD_PID" 2>/dev/null || break
    sleep 0.5
  done
  # The child itself, not the port: a dsh that exited but somehow left a socket
  # behind is a different bug, and "is the process gone" is the promise this file
  # is actually able to keep.
  if kill -0 "$SMOKE_CHILD_PID" 2>/dev/null; then
    echo "error: dsh pid $SMOKE_CHILD_PID outlived the app that started it." >&2
    echo "       Closing the window must end the dsh session (docs/dsh-shell-contract.md)." >&2
    echo "       Cleaning up the orphan this run created." >&2
    kill -KILL "$SMOKE_CHILD_PID" 2>/dev/null || true
    exit 8
  fi
  echo "    ok   dsh pid $SMOKE_CHILD_PID ended with the app"
fi
SMOKE_CHILD_PID=""

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