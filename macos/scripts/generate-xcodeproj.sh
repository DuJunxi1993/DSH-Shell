#!/usr/bin/env bash
# Regenerate App/DSHShell.xcodeproj from project.yml using XcodeGen.
# Usage: ./scripts/generate-xcodeproj.sh
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install it via:" >&2
  echo "  brew install xcodegen" >&2
  echo "or build from source: https://github.com/yonaskolb/XcodeGen" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
xcodegen generate --quiet
echo "→ generated App/DSHShell.xcodeproj"
