/* drivetest — what does Wine tell an application about the volumes it has?
 *
 * T02's decisive question is whether GetDriveTypeW returning DRIVE_REMOVABLE is
 * enough for rekordbox's export panel, or whether it enumerates volumes through
 * SetupAPI (which Wine cannot answer, because mountmgr.sys creates its devices
 * outside the PnP tree). This reports both, side by side, so the configuration
 * can be verified before the application is blamed.
 *
 * Freestanding: no CRT.
 */
#include <windows.h>
#include <setupapi.h>

static void out(const char *s)
{
    DWORD w; int n = 0; while (s[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &w, NULL);
}
static char buf[1024];
static char *str(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
static char *num(char *p, int v)
{
    char t[16]; int n = 0; unsigned u = v < 0 ? -v : v;
    if (v < 0) *p++ = '-';
    if (!u) t[n++] = '0';
    while (u) { t[n++] = '0' + (u % 10); u /= 10; }
    while (n) *p++ = t[--n];
    return p;
}
static const char *type_name(UINT t)
{
    switch (t) {
    case DRIVE_UNKNOWN:   return "UNKNOWN";
    case DRIVE_NO_ROOT_DIR: return "NO_ROOT_DIR";
    case DRIVE_REMOVABLE: return "REMOVABLE";
    case DRIVE_FIXED:     return "FIXED";
    case DRIVE_REMOTE:    return "REMOTE";
    case DRIVE_CDROM:     return "CDROM";
    case DRIVE_RAMDISK:   return "RAMDISK";
    }
    return "?";
}

void entry(void)
{
    DWORD mask = GetLogicalDrives();
    WCHAR root[4] = { 'A', ':', '\\', 0 };
    WCHAR vol[64], fs[32];
    DWORD serial, complen, flags;
    int i, n;
    HDEVINFO set;
    SP_DEVICE_INTERFACE_DATA iface;

    out("drivetest: drive letters, as this Wine reports them\r\n");
    for (i = 0; i < 26; i++)
    {
        char *p = buf;
        if (!(mask & (1u << i))) continue;
        root[0] = (WCHAR)('A' + i);
        p = str(p, "   ");
        *p++ = (char)('A' + i); *p++ = ':'; *p++ = ' ';
        p = str(p, type_name(GetDriveTypeW(root)));
        vol[0] = 0; fs[0] = 0;
        if (GetVolumeInformationW(root, vol, 64, &serial, &complen, &flags, fs, 32))
        {
            int k;
            p = str(p, "  label \"");
            for (k = 0; vol[k] && k < 40; k++) *p++ = (char)vol[k];
            p = str(p, "\"  fs \"");
            for (k = 0; fs[k] && k < 20; k++) *p++ = (char)fs[k];
            p = str(p, "\"");
        }
        else p = str(p, "  (no volume information)");
        {   /* the join key rekordbox uses: QueryDosDeviceW("X:") compared against
             * SPDRP_PHYSICAL_DEVICE_OBJECT_NAME of a GUID_DEVCLASS_VOLUME device */
            WCHAR nt[256], dos[3];
            int k;
            dos[0] = (WCHAR)('A' + i); dos[1] = ':'; dos[2] = 0;
            if (QueryDosDeviceW(dos, nt, 256))
            {
                p = str(p, "  nt \"");
                for (k = 0; nt[k] && k < 120; k++) *p++ = (char)nt[k];
                p = str(p, "\"");
            }
            else p = str(p, "  nt (QueryDosDevice failed)");
        }
        p = str(p, "\r\n"); *p = 0; out(buf);
    }

    /* the expensive question: does SetupAPI see any volumes at all? */
    {
        GUID vol_class = { 0x53f5630d, 0xb6bf, 0x11d0,
                           { 0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b } };
        char *p = buf;
        set = SetupDiGetClassDevsW(&vol_class, NULL, NULL,
                                   DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        n = 0;
        if (set != INVALID_HANDLE_VALUE)
        {
            int j = 0;
            iface.cbSize = sizeof(iface);
            while (SetupDiEnumDeviceInterfaces(set, NULL, &vol_class, j, &iface)) { n++; j++; }
            SetupDiDestroyDeviceInfoList(set);
        }
        else n = -1;
        p = str(p, "drivetest: SetupDiGetClassDevsW(GUID_DEVINTERFACE_VOLUME) -> ");
        if (n < 0) p = str(p, "INVALID_HANDLE_VALUE");
        else { p = num(p, n); p = str(p, " volume interface(s)"); }
        p = str(p, "\r\n"); *p = 0; out(buf);
    }
    /* the enumeration rekordbox actually performs: the VOLUME device CLASS,
       and for each device the four properties it reads */
    {
        GUID vol_devclass = { 0x71a27cdd, 0x812a, 0x11d0,
                              { 0xbe, 0xc7, 0x08, 0x00, 0x2b, 0xe2, 0x09, 0x2f } };
        SP_DEVINFO_DATA info = { sizeof(info) };
        WCHAR pdo[256], fname[256], desc[256];
        DWORD type, req, caps;
        int j;
        char *p;

        out("\r\ndrivetest: SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME, DIGCF_PRESENT)\r\n");
        set = SetupDiGetClassDevsW(&vol_devclass, NULL, NULL, DIGCF_PRESENT);
        if (set == INVALID_HANDLE_VALUE) { out("   INVALID_HANDLE_VALUE\r\n"); ExitProcess(0); }
        for (j = 0; SetupDiEnumDeviceInfo(set, j, &info); j++)
        {
            int k;
            p = buf;
            p = str(p, "   device "); p = num(p, j); p = str(p, ":");
            desc[0] = fname[0] = pdo[0] = 0; caps = 0;
            if (SetupDiGetDeviceRegistryPropertyW(set, &info, SPDRP_DEVICEDESC, &type,
                                                  (BYTE *)desc, sizeof(desc), &req))
            { p = str(p, "  desc \""); for (k=0; desc[k] && k<40; k++) *p++=(char)desc[k]; p = str(p, "\""); }
            if (SetupDiGetDeviceRegistryPropertyW(set, &info, SPDRP_FRIENDLYNAME, &type,
                                                  (BYTE *)fname, sizeof(fname), &req))
            { p = str(p, "  name \""); for (k=0; fname[k] && k<40; k++) *p++=(char)fname[k]; p = str(p, "\""); }
            if (SetupDiGetDeviceRegistryPropertyW(set, &info, SPDRP_CAPABILITIES, &type,
                                                  (BYTE *)&caps, sizeof(caps), &req))
            { p = str(p, "  caps 0x"); p = num(p, (int)caps); }
            if (SetupDiGetDeviceRegistryPropertyW(set, &info, SPDRP_PHYSICAL_DEVICE_OBJECT_NAME, &type,
                                                  (BYTE *)pdo, sizeof(pdo), &req))
            { p = str(p, "  PDO \""); for (k=0; pdo[k] && k<80; k++) *p++=(char)pdo[k]; p = str(p, "\""); }
            else p = str(p, "  PDO (property unavailable)");
            p = str(p, "\r\n"); *p = 0; out(buf);
        }
        if (!j) out("   (no devices enumerated)\r\n");
        SetupDiDestroyDeviceInfoList(set);
    }
    ExitProcess(0);
}
