/*
 * winedetect — can the application see that it is running under Wine?
 *
 * rekordbox.exe contains the string "wine_get_version", which is the standard
 * way an application asks: GetProcAddress(GetModuleHandle("ntdll.dll"),
 * "wine_get_version"). It works correctly on a real Windows machine and stalls
 * here, so anything that makes it take a different code path under Wine is a
 * suspect — and wine-staging can hide those exports via
 * HKCU\Software\Wine\HideWineExports.
 *
 * Before drawing any conclusion from that switch, this proves whether the
 * switch actually does anything: a knob that silently fails to take effect
 * reads exactly like a knob that made no difference.
 *
 * Freestanding, like the other probes here — see build-dualclient.sh for the
 * pattern.
 */
#include <windows.h>

int _fltused = 0;

static void out(const char *s)
{
    DWORD w, n = 0;
    while (s[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &w, NULL);
}

void entry(void)
{
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    const char *names[] = { "wine_get_version", "wine_get_build_id",
                            "wine_get_host_version", "wine_server_call", NULL };
    char buf[256];
    int i, hidden = 1;

    if (!ntdll) { out("ntdll.dll not loaded?!\r\n"); ExitProcess(2); }

    for (i = 0; names[i]; i++) {
        FARPROC p = GetProcAddress(ntdll, names[i]);
        wsprintfA(buf, "  %-24s %s\r\n", names[i], p ? "VISIBLE" : "hidden");
        out(buf);
        if (p) hidden = 0;
    }

    if (hidden) {
        out("\r\n  Every Wine export is hidden: an application probing for Wine\r\n"
            "  this way cannot tell.\r\n");
        ExitProcess(0);
    }
    out("\r\n  Wine exports are VISIBLE — any application checking for them\r\n"
        "  knows it is not on Windows.\r\n");
    ExitProcess(1);
}
