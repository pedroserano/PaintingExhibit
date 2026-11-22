#!/bin/bash
# Fetches Apple's MobileCLIP-S0 image model (used to recognise paintings, on the device) and compiles it into
# PaintingExhibit.swiftpm/App/Models, where both the Mac and the iPhone and iPad builds include it.
# The model isn't kept in this repository: Apple licenses its weights under the Apple Machine Learning Research
# Model License (see PaintingExhibit.swiftpm/App/Models/LICENSE-MobileCLIP.txt), which doesn't allow
# redistributing them here. Run once before building in Xcode; scripts/make-mac-app.sh runs it for you.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="PaintingExhibit.swiftpm/App/Models"
NAME="mobileclip_s0_image"
[ -d "$OUT/$NAME.mlmodelc" ] && exit 0
SRC="https://huggingface.co/apple/coreml-mobileclip/resolve/main/$NAME.mlpackage"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    mkdir -p "$TMP/$NAME.mlpackage/$(dirname "$f")"
    curl -fsSL "$SRC/$f" -o "$TMP/$NAME.mlpackage/$f"
done
mkdir -p "$OUT"
xcrun coremlcompiler compile "$TMP/$NAME.mlpackage" "$OUT" >/dev/null
echo "Fetched $OUT/$NAME.mlmodelc"
