#!/bin/bash
# Monta o runtime do kb a partir do código aberto do CrossOver 26.3 (crossover-sources-26.3.0).
# Uso: ./build-runtime.sh [etapa ...]   etapas: deps moltenvk media sdl inotify fixnames wine dxvk dxmt addons builtin shim   (sem argumento: todas)
# Saída em ./runtime, com o mesmo layout do SharedSupport/CrossOver.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SRC=$ROOT/build/src/sources
OBJ=$ROOT/build/obj
OUT=$ROOT/runtime   # ponytail: deps com install name absoluto aqui; runtime não é relocável
J=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET=13.0
export PATH="/opt/homebrew/opt/bison/bin:$PATH"   # Wine exige bison >= 3; o do macOS é 2.3
export PKG_CONFIG_LIBDIR=$OUT/lib/pkgconfig   # não deixa o Homebrew arm64 vazar
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64"
export CPPFLAGS="-I$OUT/include" LDFLAGS="-L$OUT/lib"
HOST="--host=x86_64-apple-darwin --prefix=$OUT"

step() { echo; echo "==> $*"; }
obj() { rm -rf "$OBJ/$1"; mkdir -p "$OBJ/$1"; cd "$OBJ/$1"; }
# aplica patches/<arquivo> uma vez só
apply() {
  patch -R -p1 -s -f --dry-run -d "$1" < "$ROOT/patches/$2" >/dev/null 2>&1 ||
    patch -p1 -s -d "$1" < "$ROOT/patches/$2"
}

deps() {
  step freetype
  cmake -S "$SRC/freetype" -B "$OBJ/freetype" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_INSTALL_PREFIX="$OUT" -DCMAKE_INSTALL_NAME_DIR="$OUT/lib" -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
  cmake --build "$OBJ/freetype" && cmake --install "$OBJ/freetype"

  step gmp
  obj gmp; "$SRC/gnutls/gmp/configure" $HOST --enable-shared --disable-static
  make -j$J && make install

  step nettle
  # o tarball da CodeWeavers veio sem o Makefile.in do nettle; o release GNU 3.10 tem o mesmo código
  local N=$ROOT/build/dl/nettle/nettle-3.10
  if [ ! -d "$N" ]; then
    mkdir -p "$ROOT/build/dl/nettle"
    curl -fsSL https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz | tar -xz -C "$ROOT/build/dl/nettle"
  fi
  obj nettle; "$N/configure" $HOST --disable-static --disable-documentation \
    --disable-openssl --enable-shared --libdir="$OUT/lib"
  make -j$J && make install

  step gnutls
  obj gnutls; NETTLE_LIBS=-lnettle HOGWEED_LIBS=-lhogweed GMP_LIBS=-lgmp \
    "$SRC/gnutls/gnutls/configure" $HOST --disable-static --disable-doc --disable-tests \
    --disable-tools --disable-cxx --disable-guile --without-p11-kit --without-idn --without-brotli \
    --without-zstd --disable-gost --without-tpm --without-tpm2 --with-included-libtasn1 --with-included-unistring
  make -j$J && make install
}

moltenvk() {
  step moltenvk
  # mesma versão do CrossOver 26.3 (1.2.10); fetchDependencies baixa SPIRV-Cross, Vulkan-Headers etc.
  # o SPIRV-Cross embutido é o da CodeWeavers; o script tentaria reclonar via git
  local S=$ROOT/build/dl/SPIRV-Cross-cw
  [ -d "$S" ] || cp -R "$SRC/moltenvk/External/SPIRV-Cross" "$S"
  # Xcode 27 não aceita mais o alvo 10.15 fixado nos projetos
  sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 10.15;/MACOSX_DEPLOYMENT_TARGET = 13.0;/' "$SRC"/moltenvk/*.xcodeproj/project.pbxproj \
    "$SRC"/moltenvk/*/*.xcodeproj/project.pbxproj
  (unset CC CXX OBJC CPPFLAGS LDFLAGS; cd "$SRC/moltenvk" &&
   { [ -d External/build/Latest/glslang.xcframework ] || ./fetchDependencies --macos --spirv-cross-root "$S"; } && make macos)
  cp "$SRC/moltenvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$OUT/lib/"
  install_name_tool -id "$OUT/lib/libMoltenVK.dylib" "$OUT/lib/libMoltenVK.dylib"
  codesign -f -s - "$OUT/lib/libMoltenVK.dylib"   # install_name_tool invalida a assinatura
}

# arquivo cross do meson para gerar x86_64 num Mac arm64 (Rosetta roda as ferramentas geradas)
crossfile() {
  mkdir -p "$OBJ"
  cat > "$OBJ/x86_64-darwin.ini" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = '$(command -v pkg-config)'
[properties]
needs_exe_wrapper = false
pkg_config_libdir = '$OUT/lib/pkgconfig'
[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

meson_x86() { # $1 = nome do build, $2 = fonte, resto = opções
  local d=$OBJ/$1 s=$2; shift 2; rm -rf "$d"
  (unset CC CXX OBJC CPPFLAGS LDFLAGS
   meson setup "$d" "$s" --cross-file "$OBJ/x86_64-darwin.ini" --prefix "$OUT" --libdir lib \
     --buildtype release "$@" && ninja -C "$d" install)
}

media() { glib; gstreamer; }

glib() {
  # o que o CrossOver 26.3 embute: glib 2.78 + GStreamer 1.24 com 17 plugins, sem FFmpeg
  crossfile
  step glib
  # submódulo gvdb veio vazio no tarball; sem a pasta o meson baixa pelo gvdb.wrap
  rmdir "$SRC/glib/subprojects/gvdb" 2>/dev/null || true
  apply "$SRC/glib" glib-python312.patch
  meson_x86 glib "$SRC/glib" -Dtests=false -Dlibelf=disabled -Dman=false -Dgtk_doc=false \
    -Dselinux=disabled -Dlibmount=disabled -Dxattr=false -Ddtrace=false -Dsystemtap=false -Dsysprof=disabled
}

gstreamer() {
  crossfile
  step gstreamer
  local B=-Dgst-plugins-base: G=-Dgst-plugins-good: X=-Dgst-plugins-bad:
  meson_x86 gstreamer "$SRC/gstreamer" --auto-features=disabled --wrap-mode=nofallback \
    -Dbase=enabled -Dgood=enabled -Dbad=enabled -Dugly=enabled -Dlibav=disabled -Dgpl=enabled \
    -Ddevtools=disabled -Dges=disabled -Drtsp_server=disabled -Dpython=disabled -Dvaapi=disabled \
    -Dsharp=disabled -Drs=disabled -Dintrospection=disabled -Dexamples=disabled -Dtests=disabled \
    -Dtools=disabled -Ddoc=disabled -Dorc=disabled -Dqt5=disabled -Dqt6=disabled -Dtls=disabled \
    -Dgstreamer:tools=enabled \
    ${B}app=enabled ${B}audioconvert=enabled ${B}audioresample=enabled ${B}playback=enabled \
    ${B}typefind=enabled ${B}videoconvertscale=enabled ${B}gl=enabled ${B}gl_api=opengl \
    ${B}gl_platform=cgl ${B}gl_winsys=cocoa \
    ${G}audioparsers=enabled ${G}avi=enabled ${G}deinterlace=enabled ${G}id3demux=enabled \
    ${G}isomp4=enabled ${G}wavparse=enabled ${G}videofilter=enabled \
    ${X}gl=enabled ${X}applemedia=enabled ${X}videoparsers=enabled -Dgst-plugins-ugly:asfdemux=enabled
}

sdl() {
  step sdl2   # controles (winebus); o CrossOver também embute SDL2
  local v=2.32.10 d=$ROOT/build/dl
  [ -d "$d/SDL2-$v" ] || curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-$v/SDL2-$v.tar.gz" | tar -xz -C "$d"
  cmake -S "$d/SDL2-$v" -B "$OBJ/sdl2" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_INSTALL_PREFIX="$OUT" -DCMAKE_INSTALL_NAME_DIR="$OUT/lib" -DSDL_STATIC=OFF -DSDL_TEST=OFF
  cmake --build "$OBJ/sdl2" && cmake --install "$OBJ/sdl2"
}

inotify() {
  step libinotify   # notificações de arquivo (ReadDirectoryChangesW); idem CrossOver
  local v=20240724 d=$ROOT/build/dl
  [ -d "$d/libinotify-$v" ] || curl -fsSL "https://github.com/libinotify-kqueue/libinotify-kqueue/releases/download/$v/libinotify-$v.tar.gz" | tar -xz -C "$d"
  # fdclosedir só existe no macOS 26.4+; o alvo é 13.0, então usa o fallback
  # e o Makefile usa libinotify.sym por caminho relativo: só compila dentro da árvore
  (cd "$d/libinotify-$v" && ac_cv_func_fdclosedir=no ./configure $HOST --disable-static && make -j$J && make install)
}

# meson grava @rpath/... como install name; o Wine faz dlopen sem rpath, então tudo vira absoluto
fixnames() {
  step fixnames
  local f id dep
  for f in "$OUT"/lib/*.dylib "$OUT"/lib/gstreamer-1.0/*.dylib; do
    [ -L "$f" ] && continue
    id=$(otool -D "$f" | tail -n +2)
    case "$id" in @rpath/*) install_name_tool -id "$(dirname "$f")/${id#@rpath/}" "$f";; esac
    for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep '^@rpath/' || true); do
      install_name_tool -change "$dep" "$OUT/lib/${dep#@rpath/}" "$f"
    done
    codesign -f -s - "$f" 2>/dev/null
  done
}

wine() {
  step wine
  obj wine
  # build=host=x86_64: as ferramentas do Wine rodam via Rosetta, o clang segue nativo
  "$SRC/wine/configure" --build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix="$OUT" \
    --enable-archs=i386,x86_64 --disable-tests \
    --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-udev \
    --without-v4l2 --without-capi --without-dbus --without-sane --without-gphoto --without-krb5 \
    --without-netapi --without-pcap --without-usb --without-cups --without-gssapi
  make -j$J && make install
}

dxvk() {
  step dxvk
  # como no cxlab/build.yml da CodeWeavers; sem dxgi, igual ao CrossOver (usa o dxgi do Wine)
  local a d
  apply "$SRC/dxvk" dxvk-mingw14.patch
  for a in 64:x86_64 32:i386; do
    d=$OBJ/dxvk${a%%:*}; rm -rf "$d"
    (unset CC CXX OBJC CPPFLAGS LDFLAGS
     meson setup "$d" "$SRC/dxvk" --cross-file "$SRC/dxvk/build-win${a%%:*}.txt" --buildtype release \
       --strip --prefix "$OUT/lib/dxvk" --bindir "${a#*:}-windows" --libdir "${a#*:}-windows" -Denable_dxgi=false \
       -Dcpp_args='-include cstdint'   # código de 2022 (GCC 10) no mingw GCC 16
     ninja -C "$d" install)
  done
  rm -f "$OUT"/lib/dxvk/*/*.a
}

dxmt() {
  step dxmt
  # não vem no tarball da CodeWeavers; release oficial (já marcado como builtin), mesmo conjunto de DLLs do CrossOver
  local v=v0.80 d=$ROOT/build/dl/dxmt
  [ -d "$d/$v" ] || { mkdir -p "$d"; curl -fsSL "https://github.com/3Shain/dxmt/releases/download/$v/dxmt-$v-builtin.tar.gz" | tar -xz -C "$d"; }
  rm -rf "$OUT/lib/dxmt"; cp -R "$d/$v" "$OUT/lib/dxmt"
  # o winemetal.so procura @rpath/winemac.so e ntdll.so, que aqui ficam em lib/wine/x86_64-unix
  install_name_tool -add_rpath @loader_path/../../wine/x86_64-unix "$OUT/lib/dxmt/x86_64-unix/winemetal.so"
  codesign -f -s - "$OUT/lib/dxmt/x86_64-unix/winemetal.so"
}

addons() {
  step addons
  # .NET (wine-mono) e IE/HTML (wine-gecko) nas versões que este Wine pede (dlls/appwiz.cpl/addons.c),
  # as mesmas embutidas no CrossOver; sem eles o wineboot para numa janela de download
  local u=https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.tar.xz a
  mkdir -p "$OUT/share/wine/mono" "$OUT/share/wine/gecko"
  [ -d "$OUT/share/wine/mono/wine-mono-10.4.1" ] || curl -fsSL "$u" | tar -xJ -C "$OUT/share/wine/mono"
  for a in x86 x86_64; do
    [ -d "$OUT/share/wine/gecko/wine-gecko-2.47.4-$a" ] ||
      curl -fsSL "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-$a.tar.xz" | tar -xJ -C "$OUT/share/wine/gecko"
  done
}

# marca DLLs PE como "Wine builtin", senão o loader ignora as que vêm do caminho de DLLs
builtin() {
  step builtin
  "$OBJ/wine/tools/winebuild/winebuild" --builtin "$OUT"/lib/dxvk/*/*.dll
}

shim() {
  step cxcompatdb
  clang -arch x86_64 -O2 -dynamiclib -o "$OUT/lib/wine/x86_64-unix/cxcompatdb.so" "$ROOT/cxcompatdb.c"
}

[ $# -gt 0 ] || set -- deps moltenvk media sdl inotify fixnames wine dxvk dxmt addons builtin shim
for s; do "$s"; done
echo; echo "runtime pronto em $OUT"
