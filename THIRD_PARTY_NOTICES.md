# Componentes de terceiros

O código próprio do KickBack (`kb`, `app/`, `cxcompatdb.c`, scripts e `tools/`) é MIT (veja `LICENSE`).
O app distribuído inclui os componentes abaixo, cada um sob a sua licença. O código-fonte
correspondente de todos eles está anexado a cada [release](https://github.com/JGSimi/kickback/releases)
(`kickback-sources-<versão>.tar.gz` e `crossover-sources-26.3.0.tar.gz`), e `build-runtime.sh`
reproduz o build com os mesmos patches (`patches/`).

| Componente | Versão | Licença | Origem do código |
|---|---|---|---|
| Wine (árvore da CodeWeavers) | 11.0 / CrossOver 26.3.0 | LGPL-2.1-or-later | [crossover-sources-26.3.0.tar.gz](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz) |
| DXVK (fork da CodeWeavers) | 1.10.3 | zlib | mesmo tarball + `patches/dxvk-mingw14.patch` |
| MoltenVK | 1.2.10 | Apache-2.0 | mesmo tarball (inclui SPIRV-Cross, glslang, SPIRV-Tools, cereal, Vulkan-Headers) |
| DXMT | 0.80 | LGPL-2.1-or-later | [github.com/3Shain/dxmt](https://github.com/3Shain/dxmt/tree/v0.80) |
| FreeType | 2.13.3 | FreeType License (FTL) | tarball da CodeWeavers |
| GnuTLS | (tarball da CodeWeavers) | LGPL-2.1-or-later | tarball da CodeWeavers |
| Nettle | 3.10 | LGPL-3.0-or-later / GPL-2.0-or-later | [ftp.gnu.org/gnu/nettle](https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz) |
| GMP | (tarball da CodeWeavers) | LGPL-3.0-or-later / GPL-2.0-or-later | tarball da CodeWeavers |
| GLib | 2.78.0 | LGPL-2.1-or-later | tarball da CodeWeavers + `patches/glib-python312.patch` |
| libffi | (wrap do GLib) | MIT | `kickback-sources` |
| PCRE2 | 10.42 | BSD-3-Clause | `kickback-sources` |
| proxy-libintl | (wrap do GLib) | LGPL-2.0-or-later | `kickback-sources` |
| GStreamer (core, base, good, bad, ugly) | 1.24.4 | LGPL-2.1-or-later | tarball da CodeWeavers |
| SDL2 | 2.32.10 | zlib | [libsdl.org](https://github.com/libsdl-org/SDL/releases/tag/release-2.32.10) |
| libinotify-kqueue | 20240724 | MIT | [github.com/libinotify-kqueue](https://github.com/libinotify-kqueue/libinotify-kqueue/releases/tag/20240724) |
| Wine Mono | 10.4.1 | MIT e outras (ver pacote) | [dl.winehq.org/wine/wine-mono](https://dl.winehq.org/wine/wine-mono/10.4.1/) |
| Wine Gecko | 2.47.4 | MPL-2.0 | [dl.winehq.org/wine/wine-gecko](https://dl.winehq.org/wine/wine-gecko/2.47.4/) |

**Não incluído:** o D3DMetal (Game Porting Toolkit da Apple) não pode ser redistribuído. O usuário baixa o
GPTK no site da Apple e importa pelo app.

KickBack não é afiliado à CodeWeavers nem à Apple. CrossOver é marca registrada da CodeWeavers, Inc.
