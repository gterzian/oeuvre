#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/setup.sh
rm -f .build/out/Products/Release/agent-browser
swift build -c release --disable-sandbox

PRODUCTS=".build/out/Products/Release"
APP="dist/Agent Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$PRODUCTS/agent-browser" "$APP/Contents/MacOS/agent-browser"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for helper in formal-web-content formal-web-net formal-web-graphics formal-web-media; do
  if [[ -f "formal-web/target/release/$helper" ]]; then
    cp "formal-web/target/release/$helper" "$APP/Contents/Resources/engine/$helper"
  fi
done
for bundle in "$PRODUCTS"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
  cp -R "$bundle" "$APP/Contents/MacOS/"
done
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
