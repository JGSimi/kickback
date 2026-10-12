#!/bin/bash
# Teste do kb com um runtime falso (não roda Wine de verdade).
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
KB="$(cd "$(dirname "$0")" && pwd)/kb"
export KB_HOME="$T/home" KB_RULES="$T/games.conf"
fail() { echo "FALHOU: $*"; exit 1; }

mkrt() { # $1 = dir, demais = arquivos a criar
  local r=$1; shift
  mkdir -p "$r/bin" "$r/lib/wine/x86_64-windows" "$r/lib/wine/x86_64-unix"
  printf '#!/bin/sh\nexit 0\n' > "$r/bin/wineloader"; cp "$r/bin/wineloader" "$r/bin/wineserver"
  chmod +x "$r/bin/"*
  for f; do mkdir -p "$r/$(dirname "$f")"; touch "$r/$f"; done
}

# runtime estilo CrossOver (cxcompatdb + D3DMetal + DXMT + DXVK)
mkrt "$T/cw" lib/wine/x86_64-unix/cxcompatdb.so lib64/apple_gptk/external/D3DMetal.framework \
  lib/dxmt/x86_64-windows/d3d11.dll lib/dxvk/x86_64-windows/d3d11.dll
# runtime Wine puro só com DXVK
mkrt "$T/up" lib/dxvk/x86_64-windows/d3d11.dll lib/dxvk/x86_64-windows/dxgi.dll lib/dxvk/i386-windows/d3d9.dll
printf 'Program Files/Jogo/GAME.exe|dxvk|DXVK_ASYNC=1 FOO=bar\n' > "$KB_RULES"

KB_RUNTIME="$T/cw" "$KB" create b1 || fail "create"
[ -f "$KB_HOME/bottles/b1/bottle.env" ] || fail "bottle.env"

o=$(KB_RUNTIME="$T/cw" "$KB" env b1 'C:\x\other.exe' 2>&1)
echo "$o" | grep -q '^CX_GRAPHICS_BACKEND=d3dmetal$' || fail "auto -> d3dmetal: $o"
echo "$o" | grep -q '^ROSETTA_ADVERTISE_AVX=1$' || fail "rosetta avx"
echo "$o" | grep -q '^DOTNET_EnableWriteXorExecute=0$' || fail "dotnet"
echo "$o" | grep -q "^DYLD_FALLBACK_LIBRARY_PATH=$T/cw/lib:" || fail "dyld fallback"

o=$(KB_RUNTIME="$T/cw" "$KB" env b1 'C:\program files\jogo\game.EXE' 2>&1)
echo "$o" | grep -q '^CX_GRAPHICS_BACKEND=dxvk$' || fail "regra por sufixo: $o"
echo "$o" | grep -q '^DXVK_ASYNC=1$' || fail "env da regra"

o=$(KB_RUNTIME="$T/cw" KB_BACKEND=dxmt "$KB" env b1 'C:\program files\jogo\game.exe' 2>&1)
echo "$o" | grep -q '^CX_GRAPHICS_BACKEND=dxmt$' || fail "KB_BACKEND vence regra"

o=$(ROSETTA_ADVERTISE_AVX=0 KB_RUNTIME="$T/cw" "$KB" env b1 x.exe 2>&1)
echo "$o" | grep -q ROSETTA_ADVERTISE_AVX && fail "AVX=0 deve virar unset"

mkdir -p "$KB_HOME/bottles/b2/prefix/drive_c/windows/system32" "$KB_HOME/bottles/b2/prefix/drive_c/windows/syswow64"
echo BACKEND=auto > "$KB_HOME/bottles/b2/bottle.env"
o=$(KB_RUNTIME="$T/up" "$KB" env b2 x.exe 2>&1)
echo "$o" | grep -q 'backend dxvk' || fail "wine puro -> dxvk: $o"
echo "$o" | grep -q '^WINEDLLOVERRIDES=d3d11,dxgi,d3d9=n,b;winemenubuilder.exe=d$' || fail "overrides: $o"
echo "$o" | grep -q CX_GRAPHICS_BACKEND && fail "wine puro não usa CX_GRAPHICS_BACKEND"

KB_RUNTIME="$T/up" KB_BACKEND=d3dmetal "$KB" env b2 x.exe >/dev/null 2>&1 && fail "d3dmetal sem cxcompatdb deve falhar"
"$KB" env ../x x.exe >/dev/null 2>&1 && fail "nome inválido"

# GPTK importado pelo usuário (fora do runtime)
mkrt "$T/cw2" lib/wine/x86_64-unix/cxcompatdb.so lib/dxmt/x86_64-windows/d3d11.dll
mkdir -p "$T/vol/redist/lib/external/D3DMetal.framework" "$T/vol/redist/lib/wine/x86_64-windows"
touch "$T/vol/redist/lib/external/libd3dshared.dylib" "$T/vol/redist/lib/wine/x86_64-windows/d3d12.dll"
o=$(KB_RUNTIME="$T/cw2" "$KB" env b1 x.exe 2>&1)
echo "$o" | grep -q 'backend dxmt' || fail "sem GPTK -> dxmt: $o"
KB_RUNTIME="$T/cw2" "$KB" import-gptk "$T/vol" >/dev/null || fail "import-gptk"
o=$(KB_RUNTIME="$T/cw2" "$KB" env b1 x.exe 2>&1)
echo "$o" | grep -q '^CX_GRAPHICS_BACKEND=d3dmetal$' || fail "GPTK importado -> d3dmetal: $o"
echo "$o" | grep -q "^CX_GPTK_DIR=$KB_HOME/apple_gptk$" || fail "CX_GPTK_DIR"
"$KB" import-gptk "$T/nada" >/dev/null 2>&1 && fail "import-gptk sem GPTK deve falhar"

echo OK
