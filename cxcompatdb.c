/*
 * Substituto aberto do cxcompatdb.so (fechado) do CrossOver.
 * O ntdll.so da CodeWeavers faz dlopen("<ntdll_dir>/cxcompatdb.so") na inicialização de
 * todo processo (CW Hack 24067, dlls/ntdll/unix/loader.c). Aqui põe-se a pasta do backend
 * pedido em CX_GRAPHICS_BACKEND na frente da busca de DLLs builtin, igual ao original.
 * ponytail: regras por processo só para a linha de comando (append_cmdline); backend fica no kb.
 */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void *ntdll_sym(const char *name)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
    {
        const char *img = _dyld_get_image_name(i);
        size_t n = strlen(img);
        if (n >= 9 && !strcmp(img + n - 9, "/ntdll.so"))
        {
            void *h = dlopen(img, RTLD_NOLOAD | RTLD_LAZY);
            return h ? dlsym(h, name) : NULL;
        }
    }
    return NULL;
}

/* Layout x86_64 do Windows: TEB+0x60 = PEB, PEB+0x20 = RTL_USER_PROCESS_PARAMETERS,
 * +0x60 = ImagePathName, +0x70 = CommandLine (UNICODE_STRING). O ntdll já preencheu tudo
 * (init_startup_info) antes de carregar este módulo, e o kernelbase só lê depois. */
typedef struct { unsigned short Length, MaximumLength; unsigned short *Buffer; } ustr;

static int ends_with_ci(const ustr *s, const char *suffix)
{
    size_t n = strlen(suffix), len = s->Length / 2;
    if (!s->Buffer || len < n) return 0;
    for (size_t i = 0; i < n; i++)
    {
        unsigned short c = s->Buffer[len - n + i];
        if (c < 128 && (c | 0x20) != (suffix[i] | 0x20) && c != suffix[i]) return 0;
        if (c >= 128) return 0;
    }
    return 1;
}

static int contains(const ustr *s, const char *needle)
{
    size_t n = strlen(needle), len = s->Length / 2;
    for (size_t i = 0; i + n <= len; i++)
    {
        size_t j = 0;
        while (j < n && s->Buffer[i + j] == (unsigned char)needle[j]) j++;
        if (j == n) return 1;
    }
    return 0;
}

/* Regras por programa, as mesmas que o CrossOver aplica (vistas no log dele com
 * `wine --bottle X --cx-log f --debugmsg +cxcompatdb`; o banco dele é fechado).
 *  - Telas web (CEF) desenham num processo de GPU separado, e o Wine no Mac não mostra o que um
 *    processo desenha na janela de outro: --in-process-gpu põe tudo no mesmo processo.
 *  - main_only: só o processo principal (sem --type=), como o CrossOver faz com a Steam. */
static const struct rule { const char *exe, *append; int main_only; const char *backend; } rules[] = {
    /* "Hack 13322": tela da Steam */
    { "\\steamwebhelper.exe", " --no-sandbox --in-process-gpu --disable-gpu", 1, NULL },
    /* "Hack 18582: Rockstar launcher": tela do Rockstar Games Launcher / Social Club */
    { "\\SocialClubHelper.exe", " --in-process-gpu --use-gl=angle --use-angle=swiftshader", 0, NULL },
    /* "Bug 23348": o Rockstar Games Launcher só abre com WineD3D */
    { "\\Rockstar Games\\Launcher\\Launcher.exe", NULL, 0, "wined3d" },
    /* "Hack 24279": GTA V Enhanced sem o BattlEye (anti-cheat do modo online, que não roda no Wine) */
    { "\\PlayGTAV.exe", " -nobattleye", 0, NULL },
};

/* Aplica as regras ao processo atual; devolve o backend gráfico forçado pela regra, se houver. */
static const char *apply_rules(void)
{
    void *(*teb_fn)(void) = (void *(*)(void))ntdll_sym("NtCurrentTeb");
    char *teb, *peb, *params;
    ustr *image, *cmd;

    if (getenv("KB_NO_CMDLINE_HACKS") || !teb_fn || !(teb = teb_fn())) return NULL;
    if (!(peb = *(char **)(teb + 0x60)) || !(params = *(char **)(peb + 0x20))) return NULL;
    image = (ustr *)(params + 0x60);
    cmd = (ustr *)(params + 0x70);
    if (getenv("KB_CX_DEBUG"))
    {
        FILE *f = fopen(getenv("KB_CX_DEBUG"), "a");
        if (f)
        {
            fprintf(f, "%d image=", getpid());
            for (int i = 0; image->Buffer && i < image->Length / 2; i++) fputc(image->Buffer[i] < 128 ? image->Buffer[i] : '?', f);
            fprintf(f, " cmdlen=%d\n", cmd->Length / 2);
            fclose(f);
        }
    }
    if (!cmd->Buffer) return NULL;
    for (size_t r = 0; r < sizeof(rules) / sizeof(rules[0]); r++)
    {
        const struct rule *ru = &rules[r];
        if (!ends_with_ci(image, ru->exe) || (ru->main_only && contains(cmd, "--type="))) continue;
        if (ru->append)
        {
            size_t old = cmd->Length / 2, add = strlen(ru->append);
            unsigned short *buf = malloc((old + add + 1) * 2);   /* nunca liberado */
            if (buf)
            {
                memcpy(buf, cmd->Buffer, old * 2);
                for (size_t i = 0; i < add; i++) buf[old + i] = (unsigned char)ru->append[i];
                buf[old + add] = 0;
                cmd->Buffer = buf;
                cmd->Length = (unsigned short)((old + add) * 2);
                cmd->MaximumLength = (unsigned short)((old + add + 1) * 2);
            }
        }
        return ru->backend;
    }
    return NULL;
}

__attribute__((constructor)) static void init(void)
{
    const char *forced = apply_rules();
    const char *b = forced ? forced : getenv("CX_GRAPHICS_BACKEND"), *root = getenv("CX_ROOT"), *sub = NULL;
    void (*prepend)(const char *);
    char *dir;

    if (!b || !root) return;
    if (!strcmp(b, "d3dmetal"))
    {
        /* GPTK importado pelo usuário fora do runtime (a Apple não permite redistribuir) */
        if (getenv("CX_GPTK_DIR")) { root = getenv("CX_GPTK_DIR"); sub = "wine"; }
        else sub = "lib64/apple_gptk/wine";
    }
    else if (!strcmp(b, "dxmt")) sub = "lib/dxmt";
    else if (!strcmp(b, "dxvk")) sub = "lib/dxvk";
    else if (strcmp(b, "wined3d")) { fprintf(stderr, "cxcompatdb: backend desconhecido '%s'\n", b); return; }

    if (sub)
    {
        if (!(prepend = (void (*)(const char *))ntdll_sym("prepend_dll_path")))
        {
            fprintf(stderr, "cxcompatdb: ntdll.so sem prepend_dll_path\n");
            return;
        }
        if (asprintf(&dir, "%s/%s", root, sub) < 0) return;
        prepend(dir);  /* o ntdll guarda o ponteiro: não liberar */
    }
    /* lido por win32u (d3dkmt.c, vulkan.c) */
    setenv("CX_ACTIVE_GRAPHICS_BACKEND", b, 1);
}
