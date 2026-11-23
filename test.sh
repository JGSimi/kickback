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

# garrafa falsa do CrossOver
export KB_CROSSOVER_BOTTLES="$T/cx"
X="$KB_CROSSOVER_BOTTLES/Meus Jogos"
mkdir -p "$X/dosdevices" "$X/windata" "$X/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Jogo"
touch "$X/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Jogo/Jogo.lnk" "$X/cxmenu.conf"
ln -s ../drive_c "$X/dosdevices/c:"; ln -s / "$X/dosdevices/z:"; ln -s "$X/drive_c/ProgramData" "$X/dosdevices/p:"
W=$(printf 'Z:%s' "$X" | sed 's|/|\\\\|g')
printf '[Software\\\\Jogo]\n"Dir"="%s\\\\drive_c"\n' "$W" > "$X/user.reg"; echo 'WINE REGISTRY' > "$X/system.reg"
printf '[Bottle]\n"WineArch" = "win64"\n[EnvironmentVariables]\n"WINEMSYNC" = "1"\n"CX_GRAPHICS_BACKEND" = "dxmt"\n"CX_BOTTLE_CREATOR_APPID" = "x"\n"FOO" = "a b"\n[Outra]\n"BAR" = "1"\n' > "$X/cxbottle.conf"
[ "$("$KB" import-crossover)" = "Meus Jogos" ] || fail "listar garrafas do CrossOver"
"$KB" import-crossover "Meus Jogos" >/dev/null || fail "import-crossover"
I="$KB_HOME/bottles/Meus Jogos"
[ -f "$I/prefix/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Jogo/Jogo.lnk" ] || fail "drive_c importado"
[ "$(readlink "$I/prefix/dosdevices/c:")" = ../drive_c ] || fail "link relativo"
[ "$(readlink "$I/prefix/dosdevices/p:")" = "$I/prefix/drive_c/ProgramData" ] || fail "link absoluto para a garrafa"
grep -qF "$(printf 'Z:%s' "$I/prefix" | sed 's|/|\\\\|g')\\\\drive_c" "$I/prefix/user.reg" || fail "caminho no registro: $(cat "$I/prefix/user.reg")"
[ -e "$I/prefix/cxmenu.conf" ] || [ -e "$I/prefix/windata" ] && fail "arquivos do CrossOver não devem ir"
( set -a; . "$I/bottle.env"; [ "$BACKEND" = dxmt ] && [ "$WINEMSYNC" = 1 ] && [ "$FOO" = "a b" ] && [ -z "${BAR:-}" ] \
  && [ -z "${CX_BOTTLE_CREATOR_APPID:-}" ] ) || fail "bottle.env: $(cat "$I/bottle.env")"
[ -f "$X/cxmenu.conf" ] && [ -L "$X/dosdevices/p:" ] && grep -qF "$W" "$X/user.reg" || fail "garrafa do CrossOver alterada"
"$KB" import-crossover "Meus Jogos" >/dev/null 2>&1 && fail "importar por cima deve falhar"
"$KB" import-crossover "Meus Jogos" Cópia >/dev/null || fail "importar com outro nome"
"$KB" import-crossover nada >/dev/null 2>&1 && fail "garrafa inexistente deve falhar"
ls -A "$KB_HOME/bottles" | grep -q '^\.import' && fail "sobrou pasta temporária"
# install-steam: download (file://), checagem de MZ e instalador falso que cria o steam.exe
printf 'MZfake' > "$T/SteamSetup.exe"; printf '<html>erro' > "$T/erro.html"
mkrt "$T/st"
cat > "$T/st/bin/wineloader" <<'EOF'
#!/bin/sh
[ "$2" = /S ] || exit 1
mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Steam" && touch "$WINEPREFIX/drive_c/Program Files (x86)/Steam/Steam.exe"
EOF
chmod +x "$T/st/bin/wineloader"
mkdir -p "$KB_HOME/bottles/st/prefix"; echo BACKEND=auto > "$KB_HOME/bottles/st/bottle.env"
KB_RUNTIME="$T/st" KB_STEAM_URL="file://$T/erro.html" "$KB" install-steam st >/dev/null 2>&1 && fail "html não pode passar como instalador"
KB_RUNTIME="$T/st" KB_STEAM_URL="file://$T/SteamSetup.exe" "$KB" install-steam st >/dev/null 2>&1 || fail "install-steam"
[ -f "$KB_HOME/bottles/st/prefix/drive_c/Program Files (x86)/Steam/Steam.exe" ] || fail "steam.exe"
KB_RUNTIME="$T/st" KB_STEAM_URL="file:///nada" "$KB" install-steam st >/dev/null 2>&1 || fail "já instalada não baixa de novo"

echo OK
