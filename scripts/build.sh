#!/bin/zsh
# Builds the app and prints the path to the bundle.
#   scripts/build.sh          # Debug
#   scripts/build.sh Release
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-Debug}"

xcodebuild \
  -project AppRay.xcodeproj \
  -scheme AppRay \
  -configuration "$CONFIGURATION" \
  -derivedDataPath build \
  build >/dev/null

echo "$PWD/build/Build/Products/$CONFIGURATION/AppRay.app"
