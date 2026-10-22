#!/bin/bash
# Publishes a release of Ruban on GitHub: version, tag, app signed with the "Ruban" certificate,
# zip, release. Installed copies find it on their next daily check.
#   scripts/release.sh 0.2.0 [notes.md]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [notes.md]}
NOTES=${2:-}
TAG="v$VERSION"
fail() { echo "release: $*" >&2; exit 1; }

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 1.2.3"
[ "$(git branch --show-current)" = main ] || fail "release from main"
[ -z "$(git status --porcelain)" ] || fail "commit your changes first"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main and origin/main differ: pull or push first"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$TAG already exists"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || fail "no notes file at $NOTES"
# A personal Apple certificate would put its owner's email address in every published copy, and
# the installed copies only accept updates signed like themselves.
# (grep without -q reads to the end: with pipefail, quitting early would fail the pipe.)
security find-identity -p codesigning | grep '"Ruban"' >/dev/null || fail "no \"Ruban\" signing certificate in the keychain"

PLIST=Resources/Info.plist
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" != "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  git commit -qm "Release $VERSION" "$PLIST"
fi

swift test
RUBAN_SIGN_IDENTITY=Ruban ./build.sh --no-install
codesign --verify --strict build/Ruban.app
codesign -dvv build/Ruban.app 2>&1 | grep -x "Authority=Ruban" >/dev/null || fail "build/Ruban.app is not signed with the Ruban certificate"

ZIP="build/Ruban-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Ruban.app "$ZIP"

git tag -a "$TAG" -m "Ruban $VERSION"
git push origin main "$TAG"
if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$ZIP" --title "Ruban $VERSION" --notes-file "$NOTES"
else
  gh release create "$TAG" "$ZIP" --title "Ruban $VERSION" --generate-notes
fi
