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
# The build number counts the commits, so every build of a newer version has a higher one.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
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

# Sign with a stable identity so the Accessibility permission survives rebuilds and updates.
# First choice: the self-signed "Ruban" certificate the releases are signed with (it names nobody,
# and an app signed with it accepts the updates from GitHub). Then a Developer ID or Apple
# Development certificate, then ad hoc. RUBAN_SIGN_IDENTITY overrides the choice.
NAME=${RUBAN_SIGN_IDENTITY:-}
if [ -z "$NAME" ]; then
  NAME=$(security find-identity -p codesigning | awk -F'"' '$2 == "Ruban" && !n++ {print $2}')
fi
if [ -z "$NAME" ]; then
  NAME=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ && !n++ {print $2}')
fi
# By hash: a self-signed certificate is not "valid" for macOS, which is fine for signing.
# (awk reads to the end: with pipefail, stopping early could fail the pipe.)
IDENTITY=-
if [ -n "$NAME" ]; then
  IDENTITY=$(security find-identity -p codesigning | awk -v n="$NAME" -F'"' '$2 == n && !k++ {split($1, a, " "); print a[2]}')
  [ -n "$IDENTITY" ] || { echo "Pas de certificat de signature « $NAME » dans le trousseau." >&2; exit 1; }
fi
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "Signé avec : ${NAME:-ad hoc}"

if [ "${1:-}" != "--no-install" ]; then
  DEST="$HOME/Applications/Ruban.app"
  mkdir -p "$HOME/Applications"
  pkill -x Ruban 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installé : $DEST"
fi
