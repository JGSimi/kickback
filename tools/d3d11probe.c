/* Cria um device D3D11 e mostra quem respondeu: caminho da d3d11.dll carregada e o adaptador.
 * Compilar: x86_64-w64-mingw32-gcc -O2 -o d3d11probe.exe d3d11probe.c -ld3d11 -ldxgi */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

int main(void)
{
    ID3D11Device *dev = NULL;
    IDXGIDevice *dxgi;
    IDXGIAdapter *ad;
    DXGI_ADAPTER_DESC desc;
    D3D_FEATURE_LEVEL fl;
    char path[MAX_PATH] = "?";
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &dev, &fl, NULL);

    GetModuleFileNameA(GetModuleHandleA("d3d11.dll"), path, sizeof(path));
    printf("d3d11.dll: %s\n", path);
    if (FAILED(hr)) { printf("D3D11CreateDevice falhou: 0x%08lx\n", hr); return 1; }
    printf("feature level: 0x%x\n", fl);
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &ad)) && SUCCEEDED(IDXGIAdapter_GetDesc(ad, &desc)))
        printf("adaptador: %ls (VRAM %llu MB)\n", desc.Description, (unsigned long long)desc.DedicatedVideoMemory >> 20);
    return 0;
}
