#!/bin/bash
# Builds "build/Painting Exhibit.app" for this Mac from the shared source files and signs it.
# Signs with your free "Apple Development" certificate when one exists (so the Photos permission
# survives rebuilds), otherwise ad-hoc. Mac apps signed this way don't expire.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PaintingExhibit
BIN="$(swift build -c release --show-bin-path)"

APP="build/Painting Exhibit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/PaintingExhibit" "$APP/Contents/MacOS/PaintingExhibit"
cp Mac/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${PAINTING_EXHIBIT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
