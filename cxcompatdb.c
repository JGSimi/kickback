/*
 * Substituto aberto do cxcompatdb.so (fechado) do CrossOver.
 * O ntdll.so da CodeWeavers faz dlopen("<ntdll_dir>/cxcompatdb.so") na inicialização de
 * todo processo (CW Hack 24067, dlls/ntdll/unix/loader.c). Aqui põe-se a pasta do backend
 * pedido em CX_GRAPHICS_BACKEND na frente da busca de DLLs builtin, igual ao original.
 * ponytail: sem regras por processo (o original casa exe/Steam ID); as regras ficam no kb.
 */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

__attribute__((constructor)) static void init(void)
{
    const char *b = getenv("CX_GRAPHICS_BACKEND"), *root = getenv("CX_ROOT"), *sub = NULL;
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
