/* popupxy — does a WS_POPUP window at a NEGATIVE x ever reach the X server?
 *
 * T04. rekordbox's File menu and its view-mode selector are the only two popups
 * in the application that never appear. Both would open at x = 0..1, and JUCE
 * surrounds every popup with four drop-shadow windows, one of which sits 14 px
 * to the LEFT -- i.e. at x = -13. Every popup that DOES work in rekordbox opens
 * at x >= 32, where that shadow is still on-screen.
 *
 * So: create the same shapes JUCE does, at a negative x and at a positive one,
 * show them the same way (SW_SHOWNA, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE), and
 * report what each one's HWND says about itself. Run it under `xwininfo -root
 * -children` to see which of them the X server actually has.
 *
 * Freestanding: no CRT. Built by upstream/build-probes.sh.
 */
#include <windows.h>

static char buf[512];
static void out(const char *s)
{
    DWORD w; HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    int n = 0; while (s[n]) n++;
    WriteFile(h, s, n, &w, NULL);
}
static char *num(char *p, int v)
{
    char t[16]; int n = 0, neg = v < 0;
    unsigned u = neg ? (unsigned)(-v) : (unsigned)v;
    if (!u) t[n++] = '0';
    while (u) { t[n++] = '0' + (u % 10); u /= 10; }
    if (neg) *p++ = '-';
    while (n) *p++ = t[--n];
    return p;
}
static char *str(char *p, const char *s) { while (*s) *p++ = *s++; return p; }

static void report(const char *label, HWND h)
{
    RECT r; char *p = buf;
    p = str(p, label);
    if (!h) { p = str(p, ": CreateWindowEx FAILED\r\n"); *p = 0; out(buf); return; }
    GetWindowRect(h, &r);
    p = str(p, ": hwnd ok  visible=");
    p = num(p, IsWindowVisible(h));
    p = str(p, "  rect ");
    p = num(p, r.left); p = str(p, ","); p = num(p, r.top);
    p = str(p, " "); p = num(p, r.right - r.left);
    p = str(p, "x"); p = num(p, r.bottom - r.top);
    p = str(p, "\r\n"); *p = 0; out(buf);
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        HBRUSH b = CreateSolidBrush(RGB(220, 40, 40));
        FillRect(dc, &ps.rcPaint, b);
        DeleteObject(b);
        EndPaint(h, &ps);
        return 0;
    }
    return DefWindowProcA(h, m, w, l);
}

static HWND make_ex(const char *cls, int x, int y, int cx, int cy, DWORD ex, BOOL layered, DWORD style)
{
    WNDCLASSA wc; HWND h;
    int i = 0; while (i < (int)sizeof wc) ((char *)&wc)[i++] = 0;
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = cls;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&wc);
    /* JUCE creates the window first and MOVES it into place, exactly as the
     * rekordbox trace shows; create at 0,0 and SetWindowPos, or the test is not
     * the same test. */
    h = CreateWindowExA(ex, cls, "", style, 0, 0, 0, 0, NULL, NULL,
                        GetModuleHandleA(NULL), NULL);
    if (!h) return NULL;
    if (layered) SetLayeredWindowAttributes(h, 0, 200, LWA_ALPHA);
    SetWindowPos(h, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    SetWindowPos(h, NULL, x, y, cx, cy, SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(h, SW_SHOWNA);
    UpdateWindow(h);
    return h;
}
static HWND make(const char *cls, int x, int y, int cx, int cy)
{
    return make_ex(cls, x, y, cx, cy, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, FALSE, WS_POPUP);
}

void entry(void)
{
    MSG msg; int n;

    out("popupxy: creating four windows, the shapes JUCE puts around a popup\r\n");

    /* the menu body itself, as measured for the File menu: 228x270 at (1,50) */
    report("menu-at-x1        ", make("rbwMenu1",   1,  50, 228, 270));
    /* its four shadows: left one lands at -13 */
    report("shadow-left-x-13  ", make("rbwShadowL",-13,  36,  14, 300));
    /* the working case, as measured for the View menu at (46,50) */
    report("menu-at-x46       ", make("rbwMenu46", 46, 400, 239, 200));
    report("shadow-left-x32   ", make("rbwShadow32",32, 386,  14, 230));

    /* the same four shapes again, but LAYERED -- which is what JUCE's drop
     * shadows actually are ("is layered, delaying mapping" in the trace) */
    report("LAYERED menu-at-x1  ", make_ex("rbwLM1",   1, 600, 228, 200, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED, TRUE, WS_POPUP));
    report("LAYERED shadow-x-13 ", make_ex("rbwLSL", -13, 586,  14, 230, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED, TRUE, WS_POPUP));
    report("LAYERED shadow-x32  ", make_ex("rbwLS32", 32, 586,  14, 230, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED, TRUE, WS_POPUP));

    /* THE ONE THAT MATTERS. JUCE's popup style is 0x86080000, which contains
     * WS_SYSMENU (0x00080000). winex11's is_window_managed() returns TRUE for
     * "popup with sysmenu", so Wine hands the window to the window manager --
     * which then enforces its keep-on-screen policy and moves a negative-x
     * window to 0. Same shape, same ex-style, WS_SYSMENU added. */
    report("SYSMENU shadow-x-13 ", make_ex("rbwSysL", -13, 800, 14, 120,
                                           WS_EX_TOOLWINDOW | WS_EX_LAYERED, TRUE, WS_POPUP | WS_SYSMENU));
    report("SYSMENU shadow-x32  ", make_ex("rbwSys32", 32, 800, 14, 120,
                                           WS_EX_TOOLWINDOW | WS_EX_LAYERED, TRUE, WS_POPUP | WS_SYSMENU));

    out("popupxy: settling for 2 s, then re-reading every rect\r\n");
    for (n = 0; n < 200; n++) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        Sleep(10);
    }
    out("popupxy: rects AFTER settling --\r\n");
    report("  again menu-at-x1        ", FindWindowA("rbwMenu1", NULL));
    report("  again shadow-left-x-13  ", FindWindowA("rbwShadowL", NULL));
    report("  again LAYERED shadow-x-13", FindWindowA("rbwLSL", NULL));
    report("  again LAYERED shadow-x32 ", FindWindowA("rbwLS32", NULL));
    report("  again SYSMENU shadow-x-13", FindWindowA("rbwSysL", NULL));
    report("  again SYSMENU shadow-x32 ", FindWindowA("rbwSys32", NULL));

    out("popupxy: windows are up; pumping messages for 12 s\r\n");
    for (n = 0; n < 1200; n++) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg); DispatchMessageA(&msg);
        }
        Sleep(10);
    }
    out("popupxy: done\r\n");
    ExitProcess(0);
}
