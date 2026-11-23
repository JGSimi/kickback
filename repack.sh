#!/bin/bash
# Gera um DMG novo reaproveitando o runtime de um DMG já publicado. Serve quando só mudou o
# app/kb/games.conf e o runtime não precisa ser recompilado (o ./package.sh exige runtime/ e build/).
# Uso: VERSION=0.2.0 ./repack.sh <KickBack.dmg antigo>
#   SIGN_ID e NOTARY_PROFILE como no package.sh (sem SIGN_ID não dá: o runtime já é Developer ID)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
OLD=${1:?uso: VERSION=X.Y.Z ./repack.sh <KickBack.dmg antigo>}
: "${VERSION:?defina VERSION}" "${SIGN_ID:?defina SIGN_ID}"
DIST=$ROOT/dist
APP=$DIST/KickBack.app
R=$APP/Contents/Resources

rm -rf "$DIST"; mkdir -p "$DIST"
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$OLD" >/dev/null
trap 'hdiutil detach -quiet "$MNT" || true' EXIT
ditto "$MNT/KickBack.app" "$APP"
hdiutil detach -quiet "$MNT"; trap - EXIT

echo "==> app (universal)"
for a in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target $a-apple-macos13.0 -o "$DIST/KickBack-$a" "$ROOT"/app/*.swift
done
lipo -create -output "$APP/Contents/MacOS/KickBack" "$DIST/KickBack-arm64" "$DIST/KickBack-x86_64"
rm "$DIST"/KickBack-arm64 "$DIST"/KickBack-x86_64
cp "$ROOT/kb" "$ROOT/games.conf" "$ROOT/THIRD_PARTY_NOTICES.md" "$R/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

echo "==> assinando com $SIGN_ID (o runtime mantém as assinaturas do DMG antigo)"
codesign -f -s "$SIGN_ID" -o runtime --timestamp --entitlements "$ROOT/app/wine.entitlements" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> dmg"
S=$DIST/dmg; mkdir -p "$S"
mv "$APP" "$S/"; ln -s /Applications "$S/Applications"
hdiutil create -volname KickBack -srcfolder "$S" -ov -format ULFO "$DIST/KickBack.dmg" >/dev/null
mv "$S/KickBack.app" "$DIST/"; rm -rf "$S"
codesign -f -s "$SIGN_ID" --timestamp "$DIST/KickBack.dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> notarizando (leva alguns minutos)"
  xcrun notarytool submit "$DIST/KickBack.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST/KickBack.dmg"
fi
du -sh "$DIST/KickBack.app" "$DIST/KickBack.dmg"
