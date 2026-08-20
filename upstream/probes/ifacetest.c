/*
 * ifacetest — dump DRV_QUERYDEVICEINTERFACE for every winmm device.
 *
 * rekordbox asks winmm for a "device interface path" for MIDI devices and then
 * declines to open them. Wine implements the same query for WAVE devices, and
 * that implementation predates us — so whatever it returns there is a
 * known-good answer that some application, somewhere, accepted. This probe
 * prints the exact string for wave out, wave in, midi out and midi in so the
 * two shapes can be compared side by side.
 *
 * Freestanding (no CRT) — see build-probes.sh.
 */

#include <windows.h>
#include <mmsystem.h>

#ifndef DRV_QUERYDEVICEINTERFACE
#define DRV_QUERYDEVICEINTERFACE     (DRV_RESERVED + 12)
#endif
#ifndef DRV_QUERYDEVICEINTERFACESIZE
#define DRV_QUERYDEVICEINTERFACESIZE (DRV_RESERVED + 13)
#endif

int _fltused = 0;

static void out(const char *s)
{
    DWORD written, len = 0;
    while (s[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, len, &written, NULL);
}

static void outf(const char *fmt, ...)
{
    char buf[2048];
    va_list args;
    va_start(args, fmt);
    wvsprintfA(buf, fmt, args);
    va_end(args);
    out(buf);
}

static WCHAR wbuf[1024];
static char abuf[2048];

static void query(const char *what, int idx, MMRESULT (WINAPI *msg)(void*, UINT, DWORD_PTR, DWORD_PTR))
{
    ULONG size = 0;
    MMRESULT r;

    r = msg((void*)(DWORD_PTR)idx, DRV_QUERYDEVICEINTERFACESIZE, (DWORD_PTR)&size, 0);
    outf("  %s[%d] SIZE   -> rc=%d size=%d\r\n", what, idx, (int)r, (int)size);
    if (r != MMSYSERR_NOERROR) return;
    if (size == 0 || size > sizeof(wbuf)) { outf("      (unusable size)\r\n"); return; }

    wbuf[0] = 0;
    r = msg((void*)(DWORD_PTR)idx, DRV_QUERYDEVICEINTERFACE, (DWORD_PTR)wbuf, size);
    if (r != MMSYSERR_NOERROR) { outf("      FETCH  -> rc=%d\r\n", (int)r); return; }

    WideCharToMultiByte(CP_ACP, 0, wbuf, -1, abuf, sizeof(abuf), NULL, NULL);
    outf("      FETCH  -> rc=0  \"%s\"\r\n", abuf);
}

void entry(void)
{
    UINT n, i;
    WAVEOUTCAPSA wo;
    WAVEINCAPSA  wi;
    MIDIOUTCAPSA mo;
    MIDIINCAPSA  mi;

    n = waveOutGetNumDevs();
    outf("WAVE OUT: %d\r\n", (int)n);
    for (i = 0; i < n; i++)
    {
        if (waveOutGetDevCapsA(i, &wo, sizeof(wo)) == MMSYSERR_NOERROR)
            outf("  [%d] %s\r\n", (int)i, wo.szPname);
        query("waveOut", i, (MMRESULT (WINAPI *)(void*, UINT, DWORD_PTR, DWORD_PTR))waveOutMessage);
    }

    n = waveInGetNumDevs();
    outf("WAVE IN: %d\r\n", (int)n);
    for (i = 0; i < n; i++)
    {
        if (waveInGetDevCapsA(i, &wi, sizeof(wi)) == MMSYSERR_NOERROR)
            outf("  [%d] %s\r\n", (int)i, wi.szPname);
        query("waveIn", i, (MMRESULT (WINAPI *)(void*, UINT, DWORD_PTR, DWORD_PTR))waveInMessage);
    }

    n = midiOutGetNumDevs();
    outf("MIDI OUT: %d\r\n", (int)n);
    for (i = 0; i < n; i++)
    {
        if (midiOutGetDevCapsA(i, &mo, sizeof(mo)) == MMSYSERR_NOERROR)
            outf("  [%d] %s\r\n", (int)i, mo.szPname);
        query("midiOut", i, (MMRESULT (WINAPI *)(void*, UINT, DWORD_PTR, DWORD_PTR))midiOutMessage);
    }

    n = midiInGetNumDevs();
    outf("MIDI IN: %d\r\n", (int)n);
    for (i = 0; i < n; i++)
    {
        if (midiInGetDevCapsA(i, &mi, sizeof(mi)) == MMSYSERR_NOERROR)
            outf("  [%d] %s\r\n", (int)i, mi.szPname);
        query("midiIn", i, (MMRESULT (WINAPI *)(void*, UINT, DWORD_PTR, DWORD_PTR))midiInMessage);
    }

    ExitProcess(0);
}
