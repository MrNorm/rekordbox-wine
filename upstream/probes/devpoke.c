/* devpoke — send the device-interface arrival that Wine never sends.
 *
 * T02, 2026-08-19. rekordbox registers for device notifications with
 * DEVICE_NOTIFY_ALL_INTERFACE_CLASSES and waits for a DBT_DEVTYP_DEVICEINTERFACE
 * arrival before it will look at a drive. Wine broadcasts DBT_DEVTYP_VOLUME
 * arrivals and never a device interface, because mountmgr.sys creates its volume
 * devices outside the PnP tree and IoRegisterDeviceInterface refuses any device
 * that is not a bus-enumerated PDO.
 *
 * Fixing that properly means turning mountmgr into a bus driver. Before paying
 * for that, this asks the cheap question: if the notification simply arrives, is
 * that enough? It broadcasts one synthetic GUID_DEVINTERFACE_VOLUME arrival to
 * every top-level window, naming the volume in the form Windows uses.
 *
 * If rekordbox's Devices list populates after this, the notification is the only
 * missing piece and a small helper can ship alongside the application. If it
 * does not, the application needs the real PnP object and this is dead.
 *
 * Usage: devpoke [drive-letter]      default E
 * Freestanding: no CRT.
 */
#include <windows.h>
#include <dbt.h>

/* freestanding: no CRT, so provide the two the compiler emits */
static void *rbw_memset(void *d, int c, size_t n)
{ unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
static void *rbw_memcpy(void *d, const void *s, size_t n)
{ unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }
#define memset rbw_memset
#define memcpy rbw_memcpy

static void out(const char *s)
{
    DWORD w; int n = 0; while (s[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &w, NULL);
}

/* GUID_DEVINTERFACE_VOLUME */
static const GUID vol_class =
    { 0x53f5630d, 0xb6bf, 0x11d0, { 0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b } };
/* GUID_DEVINTERFACE_DISK */
static const GUID disk_class =
    { 0x53f56307, 0xb6bf, 0x11d0, { 0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b } };

static BYTE buffer[1024];
static BYTE buffer_a[1024];
static void *g_dbcc;
static DWORD g_event;
static int g_sent;

static void *g_dbcc_a;   /* the same notification, ANSI form */

/* Send with the charset the target window was registered with. Wine does not
 * convert the embedded name inside a DEV_BROADCAST_DEVICEINTERFACE between A
 * and W, so a W struct sent to an ANSI window is silently dropped -- which is
 * exactly what happened the first time this probe was run. */
static BOOL CALLBACK send_one(HWND hwnd, LPARAM unused)
{
    DWORD_PTR res = 0;
    (void)unused;
    if (!IsWindow(hwnd)) return TRUE;
    if (IsWindowUnicode(hwnd))
    {
        if (SendMessageTimeoutW(hwnd, WM_DEVICECHANGE, g_event, (LPARAM)g_dbcc,
                                SMTO_ABORTIFHUNG | SMTO_NORMAL, 300, &res))
            g_sent++;
    }
    else if (g_dbcc_a)
    {
        if (SendMessageTimeoutA(hwnd, WM_DEVICECHANGE, g_event, (LPARAM)g_dbcc_a,
                                SMTO_ABORTIFHUNG | SMTO_NORMAL, 300, &res))
            g_sent++;
    }
    return TRUE;
}

static void broadcast(const GUID *cls, const WCHAR *name, DWORD event, const char *what)
{
    DEV_BROADCAST_DEVICEINTERFACE_W *dbcc = (DEV_BROADCAST_DEVICEINTERFACE_W *)buffer;
    DWORD recipients = BSM_APPLICATIONS;
    int n = 0;
    long r;

    while (name[n]) n++;
    memset(buffer, 0, sizeof buffer);
    dbcc->dbcc_size = FIELD_OFFSET(DEV_BROADCAST_DEVICEINTERFACE_W, dbcc_name) + (n + 1) * sizeof(WCHAR);
    dbcc->dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    dbcc->dbcc_reserved = 0;
    dbcc->dbcc_classguid = *cls;
    memcpy(dbcc->dbcc_name, name, (n + 1) * sizeof(WCHAR));

    {   /* the ANSI twin */
        DEV_BROADCAST_DEVICEINTERFACE_A *a = (DEV_BROADCAST_DEVICEINTERFACE_A *)buffer_a;
        int k;
        memset(buffer_a, 0, sizeof buffer_a);
        a->dbcc_size = FIELD_OFFSET(DEV_BROADCAST_DEVICEINTERFACE_A, dbcc_name) + n + 1;
        a->dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
        a->dbcc_reserved = 0;
        a->dbcc_classguid = *cls;
        for (k = 0; k <= n; k++) a->dbcc_name[k] = (char)name[k];
        g_dbcc_a = a;
    }

    /* NOT BSF_POSTMESSAGE: a posted message cannot carry a pointer across a
     * process boundary, so the receiver gets a wild LPARAM or nothing at all.
     * A sent message lets the marshalling layer copy the structure. */
    (void)recipients; (void)r;
    /* BroadcastSystemMessageW reaches nothing here, so walk the top-level
     * windows and send to each one. A SENT message is marshalled across the
     * process boundary; a posted one would hand the receiver a wild pointer. */
    g_dbcc = dbcc; g_event = event; g_sent = 0;
    EnumWindows(send_one, 0);
    out(what);
    { char c[32]; int k = 0, v = g_sent;
      c[k++] = ' '; c[k++] = '-'; c[k++] = '>'; c[k++] = ' ';
      if (!v) { c[k++]='0'; }
      else { char t[8]; int m=0; while (v) { t[m++] = '0'+(v%10); v/=10; } while (m) c[k++]=t[--m]; }
      c[k++]=' '; c[k++]='w'; c[k++]='i'; c[k++]='n'; c[k++]='d'; c[k++]='o'; c[k++]='w';
      c[k++]='s'; c[k++]='\r'; c[k++]='\n'; c[k]=0; out(c); }
}

void entry(void)
{
    WCHAR name[128];
    WCHAR letter = 'E';
    LPWSTR cmd = GetCommandLineW();
    int i = 0;

    /* last non-space character of the command line, if it is a letter */
    while (cmd[i]) i++;
    while (i > 0 && (cmd[i-1] == ' ' || cmd[i-1] == '"')) i--;
    if (i > 0 && ((cmd[i-1] >= 'A' && cmd[i-1] <= 'Z') || (cmd[i-1] >= 'a' && cmd[i-1] <= 'z'))
             && (i < 2 || cmd[i-2] == ' ' || cmd[i-2] == '"'))
        letter = cmd[i-1] & ~0x20;

    /* the shape Windows uses: \\?\STORAGE#Volume#...#{guid} */
    {
        static const WCHAR pre[] = L"\\\\?\\STORAGE#Volume#_??_USBSTOR#Disk&Ven_&Prod_&Rev_#0#{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}";
        int k = 0; while (pre[k]) { name[k] = pre[k]; k++; } name[k] = 0;
    }

    out("devpoke: broadcasting a synthetic GUID_DEVINTERFACE_VOLUME arrival\r\n");
    out("         drive letter in the volume name: ");
    { char c[4]; c[0] = (char)letter; c[1] = ':'; c[2] = '\r'; c[3] = 0; out(c); out("\n"); }

    broadcast(&vol_class,  name, DBT_DEVICEARRIVAL, "  VOLUME  interface arrival");
    Sleep(300);
    broadcast(&disk_class, name, DBT_DEVICEARRIVAL, "  DISK    interface arrival");
    Sleep(300);

    /* and the volume-letter form, in case it wants that instead */
    {
        DEV_BROADCAST_VOLUME dbv;
        DWORD recipients = BSM_APPLICATIONS;
        long r;
        memset(&dbv, 0, sizeof dbv);
        dbv.dbcv_size = sizeof(dbv);
        dbv.dbcv_devicetype = DBT_DEVTYP_VOLUME;
        dbv.dbcv_unitmask = 1u << (letter - 'A');
        dbv.dbcv_flags = 0;
        (void)recipients; (void)r;
        g_dbcc = &dbv; g_dbcc_a = &dbv; g_event = DBT_DEVICEARRIVAL; g_sent = 0;
        EnumWindows(send_one, 0);
        out("  VOLUME  letter arrival sent\r\n");
    }

    out("devpoke: done\r\n");
    ExitProcess(0);
}
