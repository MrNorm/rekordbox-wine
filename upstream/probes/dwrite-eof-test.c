/* Regression probe for a DirectWrite source that ends or fails on refresh.
 * Run modes 0 (normal), 1 (end), and 2 (error). Exit 86 means a null read.
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -o dwrite-eof-test.exe \
 *        dwrite-eof-test.c -ldwrite -lole32 -luuid
 * Run using the target Wine runtime and WINEPREFIX; the probe changes no files.
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <dwrite_2.h>
#include <stdio.h>

static const WCHAR text[] = L"AB";
static int mode;

static HRESULT WINAPI query(IDWriteTextAnalysisSource *self, REFIID iid, void **out)
{
    *out = NULL;
    if (!IsEqualIID(iid, &IID_IUnknown) && !IsEqualIID(iid, &IID_IDWriteTextAnalysisSource))
        return E_NOINTERFACE;
    *out = self;
    return S_OK;
}

static ULONG WINAPI ref(IDWriteTextAnalysisSource *self)
{
    return 2;
}

static HRESULT WINAPI at(IDWriteTextAnalysisSource *self, UINT32 pos, const WCHAR **str, UINT32 *len)
{
    *str = NULL;
    *len = 0;
    if (pos >= 2) return S_OK;
    if (pos && mode) return mode == 2 ? E_FAIL : S_OK;
    *str = text + pos;
    *len = 2 - pos;
    return S_OK;
}

static HRESULT WINAPI before(IDWriteTextAnalysisSource *self, UINT32 pos, const WCHAR **str, UINT32 *len)
{
    *str = NULL;
    *len = 0;
    return S_OK;
}

static DWRITE_READING_DIRECTION WINAPI direction(IDWriteTextAnalysisSource *self)
{
    return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
}

static HRESULT WINAPI locale(IDWriteTextAnalysisSource *self, UINT32 pos, UINT32 *len, const WCHAR **str)
{
    *str = L"en-us";
    *len = 2;
    return S_OK;
}

static HRESULT WINAPI number(IDWriteTextAnalysisSource *self, UINT32 pos, UINT32 *len, IDWriteNumberSubstitution **subst)
{
    *subst = NULL;
    *len = 2;
    return S_OK;
}

static IDWriteTextAnalysisSourceVtbl vtable = {query, ref, ref, at, before, direction, locale, number};
static IDWriteTextAnalysisSource source = {&vtable};

static LONG CALLBACK crash(EXCEPTION_POINTERS *p)
{
    if (p->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION)
    {
        puts("FAIL: access violation while refreshing text source");
        fflush(stdout);
        ExitProcess(86);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

int main(int argc, char **argv)
{
    IDWriteFactory2 *factory = NULL;
    IDWriteFontFallback *fallback = NULL;
    IDWriteFont *font = NULL;
    UINT32 mapped = 0;
    FLOAT scale = 0;
    HRESULT hr;

    if (argc != 2 || argv[1][0] < '0' || argv[1][0] > '2' || argv[1][1])
    {
        fprintf(stderr, "usage: %s 0|1|2 (normal|end|error)\n", argv[0]);
        return 2;
    }
    mode = argv[1][0] - '0';
    AddVectoredExceptionHandler(1, crash);
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory2, (IUnknown **)&factory);
    if (FAILED(hr)) return 2;
    hr = IDWriteFactory2_GetSystemFontFallback(factory, &fallback);
    if (FAILED(hr))
    {
        IDWriteFactory2_Release(factory);
        return 3;
    }
    hr = IDWriteFontFallback_MapCharacters(fallback, &source, 0, 2, NULL, L"Arial",
            DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
            &mapped, &font, &scale);
    printf("mode=%d hr=%08lx mapped=%u scale=%g\n", mode, hr, mapped, scale);
    if (font) IDWriteFont_Release(font);
    IDWriteFontFallback_Release(fallback);
    IDWriteFactory2_Release(factory);
    return SUCCEEDED(hr) && mapped == (mode ? 1 : 2) ? 0 : 1;
}
