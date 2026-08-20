/*
 * hidtest — does Wine expose the DJ controller through the Windows HID stack?
 *
 * rekordbox 7.2.x identifies a connected controller through HID, not MIDI:
 * rekordbox.exe imports HidD_GetHidGuid, SetupDiGetClassDevsW,
 * SetupDiEnumDeviceInterfaces, SetupDiGetDeviceInterfaceDetailW,
 * HidD_GetAttributes, HidD_GetProductString and HidP_GetCaps. A Pioneer DDJ-400
 * presents a vendor HID interface (USB interface 4, class 03) alongside its
 * audio and MIDI interfaces, and on Linux that surfaces as /dev/hidraw*.
 *
 * If Wine cannot see that interface, rekordbox never recognises the controller,
 * never opens its MIDI port, and the device sits in its power-on LED animation
 * with no control doing anything — which is exactly the observed failure.
 *
 * This walks the HID device interface class the same way rekordbox does and
 * prints what it finds, so "does Wine expose it" is a measurement rather than an
 * inference.
 *
 * Freestanding (no CRT) — see build-probes.sh.
 */

#include <windows.h>
#include <setupapi.h>
#include <ddk/hidsdi.h>

int _fltused = 0;

static void out(const char *s)
{
    DWORD written, len = 0;
    while (s[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, len, &written, NULL);
}

static void outf(const char *fmt, ...)
{
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    wvsprintfA(buf, fmt, args);
    va_end(args);
    out(buf);
}

static void outw(const WCHAR *w)
{
    char buf[512];
    if (!w || !w[0]) { out("(none)"); return; }
    WideCharToMultiByte(CP_ACP, 0, w, -1, buf, sizeof(buf), NULL, NULL);
    out(buf);
}

#define PIONEER_VID 0x2b73

void __cdecl entry(void)
{
    SP_DEVICE_INTERFACE_DATA iface;
    SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail;
    HIDD_ATTRIBUTES attrs;
    HDEVINFO set;
    GUID hid_guid;
    DWORD i, size;
    HANDLE file;
    WCHAR str[256];
    BYTE buffer[1024];
    int found = 0, pioneer = 0;

    HidD_GetHidGuid(&hid_guid);

    set = SetupDiGetClassDevsW(&hid_guid, NULL, NULL, DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE)
    {
        outf("SetupDiGetClassDevsW failed: %d\r\n", (int)GetLastError());
        ExitProcess(2);
    }

    out("HID device interfaces present:\r\n");

    iface.cbSize = sizeof(iface);
    for (i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &hid_guid, i, &iface); i++)
    {
        found++;

        size = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &iface, NULL, 0, &size, NULL);
        if (!size || size > sizeof(buffer)) { outf("  [%d] detail size %d — skipped\r\n", (int)i, (int)size); continue; }

        detail = (SP_DEVICE_INTERFACE_DETAIL_DATA_W *)buffer;
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, size, NULL, NULL))
        {
            outf("  [%d] detail failed: %d\r\n", (int)i, (int)GetLastError());
            continue;
        }

        outf("  [%d] ", (int)i);
        outw(detail->DevicePath);
        out("\r\n");

        /* rekordbox opens the interface to read its attributes; if the open
         * fails the device is invisible to it even though it is enumerated. */
        file = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (file == INVALID_HANDLE_VALUE)
        {
            outf("        open failed: %d (rw); ", (int)GetLastError());
            file = CreateFileW(detail->DevicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               NULL, OPEN_EXISTING, 0, NULL);
            outf("read-only: %s\r\n", file == INVALID_HANDLE_VALUE ? "also failed" : "ok");
            if (file == INVALID_HANDLE_VALUE) continue;
        }

        attrs.Size = sizeof(attrs);
        if (HidD_GetAttributes(file, &attrs))
        {
            outf("        VID_%04X PID_%04X rev %04X",
                 attrs.VendorID, attrs.ProductID, attrs.VersionNumber);
            if (attrs.VendorID == PIONEER_VID) { out("   <== Pioneer DJ"); pioneer++; }
            out("\r\n");
        }
        else
            outf("        HidD_GetAttributes failed: %d\r\n", (int)GetLastError());

        str[0] = 0;
        if (HidD_GetProductString(file, str, sizeof(str)))
        {
            out("        product: ");
            outw(str);
            out("\r\n");
        }

        CloseHandle(file);
    }

    SetupDiDestroyDeviceInfoList(set);

    outf("\r\ntotal HID interfaces: %d, Pioneer: %d\r\n", found, pioneer);
    if (!found)
        out("VERDICT: Wine exposes NO HID devices at all. winebus.sys is not\r\n"
            "         enumerating anything — check that /dev/hidraw* is readable\r\n"
            "         and that the winebus service is running.\r\n");
    else if (!pioneer)
        out("VERDICT: HID works, but the Pioneer controller is NOT among the\r\n"
            "         devices. rekordbox cannot identify the controller.\r\n");
    else
        out("VERDICT: the controller IS visible through HID.\r\n");

    ExitProcess(0);
}
