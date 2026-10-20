#!/bin/bash
# Builds Ruban.app, signs it and installs it in ~/Applications.
#   ./build.sh            build + install
#   ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Ruban

APP=build/Ruban.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ruban"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/ruban "$APP/Contents/Resources/ruban"
chmod +x "$APP/Contents/Resources/ruban"

# App icon, drawn once and cached.
if [ ! -f build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so the Accessibility permission survives rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signé avec : ${IDENTITY:-ad hoc}"

if [ "${1:-}" != "--no-install" ]; then
  DEST="$HOME/Applications/Ruban.app"
  mkdir -p "$HOME/Applications"
  pkill -x Ruban 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installé : $DEST"
fi
