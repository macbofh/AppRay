#!/bin/zsh
# Regenerates AppRay.xcodeproj from project.yml.
# The project file is not checked in; project.yml is the source of truth.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Run: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo "Open AppRay.xcodeproj, or run scripts/build.sh"
