#!/bin/bash
# Gera dist/KickBack.app e dist/KickBack.dmg a partir de ./runtime (rode ./build-runtime.sh antes).
# Uso: VERSION=0.1.0 ./package.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
VERSION=${VERSION:-0.1.0}
DIST=$ROOT/dist
APP=$DIST/KickBack.app
R=$APP/Contents/Resources
WINEBUILD=$ROOT/build/obj/wine/tools/winebuild/winebuild
[ -x "$ROOT/runtime/bin/wine" ] && [ -x "$WINEBUILD" ] || { echo "rode ./build-runtime.sh primeiro" >&2; exit 1; }

rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$R"

echo "==> app (universal)"
for a in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target $a-apple-macos13.0 -o "$DIST/KickBack-$a" "$ROOT/app/KickBack.swift"
done
lipo -create -output "$APP/Contents/MacOS/KickBack" "$DIST/KickBack-arm64" "$DIST/KickBack-x86_64"
rm "$DIST"/KickBack-arm64 "$DIST"/KickBack-x86_64

echo "==> ícone"
I=$DIST/AppIcon.iconset; mkdir -p "$I"
swift "$ROOT/tools/make-icon.swift" "$DIST/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$DIST/icon.png" --out "$I/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$DIST/icon.png" --out "$I/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$R/AppIcon.icns" "$I"
rm -rf "$I" "$DIST/icon.png"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KickBack</string>
  <key>CFBundleDisplayName</key><string>KickBack</string>
  <key>CFBundleIdentifier</key><string>io.github.jgsimi.kickback</string>
  <key>CFBundleExecutable</key><string>KickBack</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Programa do Windows</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>exe</string><string>msi</string><string>lnk</string><string>bat</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF

echo "==> runtime"
# só o necessário para rodar: sem headers, libs estáticas, ferramentas de build e documentação
rsync -a --exclude '/include/' --exclude '/lib/pkgconfig/' --exclude '/lib/cmake/' --exclude '/lib/glib-2.0/' \
  --exclude '/lib/gio/' --exclude '*.a' --exclude '*.la' --exclude '/share/man/' --exclude '/share/doc/' \
  --exclude '/share/gtk-doc/' --exclude '/share/aclocal/' --exclude '/share/info/' --exclude '/share/locale/' \
  --exclude '/share/glib-2.0/' --exclude '/share/gettext/' --exclude '/share/applications/' \
  --exclude '/share/bash-completion/' --exclude '/share/gdb/' --exclude '/share/sdl2/' \
  "$ROOT/runtime/" "$R/runtime/"
find "$R/runtime/bin" -mindepth 1 ! -name wine ! -name wineserver -delete

echo "==> removendo debug das DLLs do Windows"
# o strip regrava o cabeçalho DOS e apaga a marca "Wine builtin DLL": guarda quem tinha e remarca
MARKED=$DIST/builtin.list
python3 -I - "$R/runtime" > "$MARKED" <<'PY'
import os, sys
for d, _, fs in os.walk(sys.argv[1]):
    for n in fs:
        p = os.path.join(d, n)
        if not os.path.islink(p):
            with open(p, "rb") as f:
                if f.read(80)[64:80] == b"Wine builtin DLL":
                    print(p)
PY
for a in x86_64:x86_64-w64-mingw32 i386:i686-w64-mingw32; do
  find "$R/runtime" -type f -path "*/${a%%:*}-windows/*" -print0 | xargs -0 "${a#*:}-strip" --strip-debug 2>/dev/null || true
done
tr '\n' '\0' < "$MARKED" | xargs -0 "$WINEBUILD" --builtin
rm "$MARKED"

echo "==> relocando"
python3 -I "$ROOT/tools/relocate.py" "$R/runtime" "$ROOT/runtime"

cp "$ROOT/kb" "$ROOT/games.conf" "$R/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$R/" 2>/dev/null || true

echo "==> assinando (ad-hoc)"
codesign --force -s - "$APP"

echo "==> dmg"
S=$DIST/dmg; mkdir -p "$S"
mv "$APP" "$S/"; ln -s /Applications "$S/Applications"
hdiutil create -volname KickBack -srcfolder "$S" -ov -format ULFO "$DIST/KickBack.dmg" >/dev/null
mv "$S/KickBack.app" "$DIST/"; rm -rf "$S"
du -sh "$DIST/KickBack.app" "$DIST/KickBack.dmg"
