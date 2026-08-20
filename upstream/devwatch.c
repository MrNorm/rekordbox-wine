/*
 * devwatch — is anything broadcasting WM_DEVICECHANGE on a timer under Wine?
 *
 * WHY THIS EXISTS. Static analysis of rekordbox 7.2.18 (THEMES/T10, phases 6-7)
 * traced the 15.9 s audio teardown back to its first cause: rekordbox's own
 * rb::AudioIODeviceType announces "the device list changed", a
 * djplay::AudioDeviceWatcher re-broadcasts it, and a djplay::SettingIF listener
 * responds — correctly — by destroying both audio streams and reopening them a
 * second later.
 *
 * JUCE's WASAPI device type does not poll. It rescans when its hidden window
 * receives WM_DEVICECHANGE (coalesced through a 500 ms timer), and it only
 * tells its listeners if the rescanned device-name list actually differs.
 *
 * That predicts a two-factor fault:
 *   1. something broadcasts WM_DEVICECHANGE spuriously, on a ~15 s cadence,
 *      in BOTH arms, and
 *   2. only when a second output device is open does the rescan come back
 *      different, turning the broadcast into a teardown.
 *
 * This probe measures factor 1 alone, with no audio involved at all. If
 * WM_DEVICECHANGE arrives here every ~15 s while rekordbox is running, the
 * trigger is a Wine device-layer bug and the audio path is a victim, not a
 * cause. If nothing arrives, factor 1 is refuted and the announcement must come
 * from somewhere else inside rekordbox.
 *
 * It creates an ordinary top-level (never shown) window, because broadcast
 * messages are not delivered to message-only windows -- the same reason JUCE
 * uses a real window here. It also registers for targeted device-interface
 * notifications, which arrive whether or not the broadcast does.
 *
 * Freestanding, like the other probes here -- see build-devwatch.sh.
 *
 * Usage (inside the prefix):  devwatch.exe [seconds]     default 120
 */
#include <windows.h>
#include <dbt.h>

int _fltused = 0;

static DWORD t0;
static int   n_devchange = 0;

static void out(const char *s)
{
    DWORD w, n = 0;
    while (s[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &w, NULL);
}

/* elapsed seconds, to 1 decimal, without the CRT or floating point */
static void stamp(char *buf)
{
    DWORD ms = GetTickCount() - t0;
    wsprintfA(buf, "%3lu.%01lu", ms / 1000, (ms % 1000) / 100);
}

static const char *evname(WPARAM w)
{
    switch (w) {
    case DBT_DEVNODES_CHANGED:      return "DBT_DEVNODES_CHANGED";
    case DBT_DEVICEARRIVAL:         return "DBT_DEVICEARRIVAL";
    case DBT_DEVICEREMOVECOMPLETE:  return "DBT_DEVICEREMOVECOMPLETE";
    case DBT_DEVICEQUERYREMOVE:     return "DBT_DEVICEQUERYREMOVE";
    case DBT_DEVICEQUERYREMOVEFAILED: return "DBT_DEVICEQUERYREMOVEFAILED";
    case DBT_DEVICEREMOVEPENDING:   return "DBT_DEVICEREMOVEPENDING";
    case DBT_DEVICETYPESPECIFIC:    return "DBT_DEVICETYPESPECIFIC";
    case DBT_CUSTOMEVENT:           return "DBT_CUSTOMEVENT";
    default:                        return "other";
    }
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    char buf[512], ts[32];

    if (msg == WM_DEVICECHANGE) {
        n_devchange++;
        stamp(ts);
        /* lParam, when present, names the interface or volume that changed */
        if (lp) {
            DEV_BROADCAST_HDR *hdr = (DEV_BROADCAST_HDR *)lp;
            if (hdr->dbch_devicetype == DBT_DEVTYP_DEVICEINTERFACE) {
                DEV_BROADCAST_DEVICEINTERFACE_A *di = (DEV_BROADCAST_DEVICEINTERFACE_A *)lp;
                wsprintfA(buf, "  %s s  WM_DEVICECHANGE  %-24s  iface=%.200s\r\n",
                          ts, evname(wp), di->dbcc_name);
            } else {
                wsprintfA(buf, "  %s s  WM_DEVICECHANGE  %-24s  devicetype=%lu\r\n",
                          ts, evname(wp), (unsigned long)hdr->dbch_devicetype);
            }
        } else {
            wsprintfA(buf, "  %s s  WM_DEVICECHANGE  %-24s  (no data)\r\n", ts, evname(wp));
        }
        out(buf);
        return TRUE;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

void entry(void)
{
    WNDCLASSA wc;
    HWND hwnd;
    MSG msg;
    DEV_BROADCAST_DEVICEINTERFACE_A filter;
    HDEVNOTIFY notify;
    char buf[256], ts[32];
    DWORD secs = 120, deadline, last_beat = 0;
    char *cmd = GetCommandLineA();

    /* crude argv: take the last space-separated token if it is all digits */
    {
        char *p = cmd, *last = 0;
        int all_digits = 1, v = 0;
        while (*p) { if (*p == ' ') last = p + 1; p++; }
        if (last && *last) {
            for (p = last; *p; p++) {
                if (*p < '0' || *p > '9') { all_digits = 0; break; }
                v = v * 10 + (*p - '0');
            }
            if (all_digits && v > 0) secs = v;
        }
    }

    t0 = GetTickCount();
    deadline = t0 + secs * 1000;

    wc.style = 0;
    wc.lpfnWndProc = wndproc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hIcon = NULL;
    wc.hCursor = NULL;
    wc.hbrBackground = NULL;
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "RBWDevWatch";
    if (!RegisterClassA(&wc)) { out("RegisterClass failed\r\n"); ExitProcess(2); }

    /* An ordinary top-level window, never shown. Broadcast messages are NOT
     * delivered to HWND_MESSAGE windows, which is why JUCE uses a real one. */
    hwnd = CreateWindowExA(0, "RBWDevWatch", "RBWDevWatch", WS_OVERLAPPED,
                           0, 0, 0, 0, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { out("CreateWindow failed\r\n"); ExitProcess(2); }

    /* Targeted notifications for every device-interface class, in addition to
     * the untargeted DBT_DEVNODES_CHANGED broadcast. */
    {
        int i, n = sizeof(filter);
        char *z = (char *)&filter;
        for (i = 0; i < n; i++) z[i] = 0;
    }
    filter.dbcc_size = sizeof(filter);
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    notify = RegisterDeviceNotificationA(hwnd, &filter,
                 DEVICE_NOTIFY_WINDOW_HANDLE | DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);

    wsprintfA(buf, "== devwatch: listening %lu s  (device notifications %s)\r\n",
              secs, notify ? "registered" : "NOT registered");
    out(buf);
    out("   Any line below is a device-change event delivered to an ordinary\r\n"
        "   hidden top-level window -- exactly what JUCE's WASAPI device type\r\n"
        "   rescans on.\r\n\r\n");

    SetTimer(hwnd, 1, 500, NULL);

    while (GetTickCount() < deadline) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        if (GetTickCount() - last_beat >= 15000) {
            last_beat = GetTickCount();
            stamp(ts);
            wsprintfA(buf, "  %s s  (alive, %d device-change events so far)\r\n",
                      ts, n_devchange);
            out(buf);
        }
        Sleep(20);
    }

    if (notify) UnregisterDeviceNotification(notify);
    stamp(ts);
    wsprintfA(buf, "\r\n== RESULT: %d WM_DEVICECHANGE event(s) in %s s\r\n", n_devchange, ts);
    out(buf);
    if (n_devchange == 0)
        out("   NONE. Factor 1 refuted: nothing is broadcasting device changes,\r\n"
            "   so rekordbox's device-list announcement comes from elsewhere.\r\n");
    ExitProcess(n_devchange ? 1 : 0);
}
