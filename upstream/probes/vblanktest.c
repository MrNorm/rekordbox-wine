/*
 * vblanktest — minimal reproducer for the dxgi WaitForVBlank stub.
 *
 * IDXGIOutput::WaitForVBlank is documented to block until the next vertical
 * blank. Wine's dxgi_output_WaitForVBlank returns E_NOTIMPL immediately, so a
 * caller that drives a frame clock from it never blocks and never gets a tick.
 * That starves any toolkit which schedules repaints from vblank (JUCE 8 does),
 * producing an application that paints one frame and then freezes for good
 * while still processing input.
 *
 * This program calls WaitForVBlank in a loop and reports the achieved rate.
 *
 *   on Windows / patched Wine : ~= the display refresh rate (e.g. 60/s)
 *   on Wine as shipped        : hundreds of thousands per second, hr=0x80004001
 *
 * Deliberately freestanding (no CRT) so it can be cross-compiled with clang
 * against Wine's own headers and import libraries — see build-vblanktest.sh.
 */

#define COBJMACROS
#include <windows.h>
#include <dxgi.h>

static void out(const char *s)
{
    DWORD written, len = 0;
    while (s[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, len, &written, NULL);
}

static void outf(const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    wvsprintfA(buf, fmt, args);
    va_end(args);
    out(buf);
}

#define ITERATIONS 200

void __cdecl entry(void)
{
    LARGE_INTEGER freq, start, end;
    IDXGIFactory *factory = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIOutput *output = NULL;
    HRESULT hr, last = S_OK;
    LONGLONG elapsed_ms, rate;
    int i, failures = 0;

    hr = CreateDXGIFactory(&IID_IDXGIFactory, (void **)&factory);
    if (FAILED(hr)) { outf("CreateDXGIFactory failed: 0x%08x\r\n", hr); ExitProcess(2); }

    hr = IDXGIFactory_EnumAdapters(factory, 0, &adapter);
    if (FAILED(hr)) { outf("EnumAdapters failed: 0x%08x\r\n", hr); ExitProcess(2); }

    hr = IDXGIAdapter_EnumOutputs(adapter, 0, &output);
    if (FAILED(hr)) { outf("EnumOutputs failed: 0x%08x — no output attached?\r\n", hr); ExitProcess(2); }

    out("calling IDXGIOutput::WaitForVBlank 200 times...\r\n");

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    for (i = 0; i < ITERATIONS; i++)
    {
        hr = IDXGIOutput_WaitForVBlank(output);
        if (FAILED(hr)) { failures++; last = hr; }
    }
    QueryPerformanceCounter(&end);

    /* integer maths only: keeps the reproducer free of any CRT float support */
    elapsed_ms = ((end.QuadPart - start.QuadPart) * 1000) / freq.QuadPart;
    rate = elapsed_ms > 0 ? ((LONGLONG)ITERATIONS * 1000) / elapsed_ms : 999999;

    outf("last HRESULT      : 0x%08x  (%d of %d calls failed)\r\n",
         last, failures, ITERATIONS);
    outf("elapsed           : %d ms\r\n", (int)elapsed_ms);
    outf("achieved rate     : %d calls/second\r\n", (int)rate);

    if (failures)
        out("VERDICT: BROKEN — WaitForVBlank does not block. A vblank-driven\r\n"
            "         repaint loop gets no tick and the app never redraws.\r\n");
    else if (rate > 200)
        out("VERDICT: SUSPECT — succeeds but far faster than any refresh rate.\r\n");
    else
        out("VERDICT: OK — rate is consistent with a real display refresh.\r\n");

    IDXGIOutput_Release(output);
    IDXGIAdapter_Release(adapter);
    IDXGIFactory_Release(factory);
    ExitProcess(failures ? 1 : 0);
}
