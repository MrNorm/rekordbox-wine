/*
 * hcdtest — walk the USB bus from user mode the way rekordbox does.
 *
 * rekordbox's djplay::USBDeviceValidation opens \\.\HCD0..\\.\HCD9, asks each
 * controller for its root hub, asks the hub how many ports it has, then asks
 * each port what is connected — comparing idVendor/idProduct and reading the
 * device's bcdDevice. If that walk yields nothing it destroys the device object
 * it has already built and never opens the controller's MIDI port.
 *
 * Stock Wine has no \\.\HCDn device object at all, so every open fails with
 * STATUS_OBJECT_NAME_NOT_FOUND. This probe measures whether the RBW-USBHCD
 * driver patch fixes that, WITHOUT involving rekordbox — so "does the patch
 * work" is answered separately from "does the application accept it", which are
 * two different questions and have to be measured as such.
 *
 * Expected on this machine with the DDJ-400 attached:
 *     HCD0 -> root hub -> a port reporting VID_2B73 PID_0026 rev 0103
 *
 * Freestanding (no CRT) — see build-probes.sh.
 */

#include <windows.h>
#include <winioctl.h>

int _fltused = 0;

/* FILE_DEVICE_USB lives in ddk/usbiodef.h, which a user-mode program has no
 * business including; it is FILE_DEVICE_UNKNOWN. These five codes are what the
 * IOCTLs actually are on the wire: 0x220408, 0x22040c, 0x220410, 0x220424. */
#define FILE_DEVICE_USB 0x22

#define IOCTL_USB_GET_ROOT_HUB_NAME \
    CTL_CODE(FILE_DEVICE_USB, 258, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_USB_GET_NODE_INFORMATION \
    CTL_CODE(FILE_DEVICE_USB, 258, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_USB_GET_NODE_CONNECTION_INFORMATION \
    CTL_CODE(FILE_DEVICE_USB, 259, METHOD_BUFFERED, FILE_ANY_ACCESS)

#include "pshpack1.h"
struct device_descriptor
{
    UINT8 bLength, bDescriptorType;
    UINT16 bcdUSB;
    UINT8 bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize0;
    UINT16 idVendor, idProduct, bcdDevice;
    UINT8 iManufacturer, iProduct, iSerialNumber, bNumConfigurations;
};

struct node_connection_information
{
    ULONG ConnectionIndex;
    struct device_descriptor DeviceDescriptor;
    UINT8 CurrentConfigurationValue;
    UINT8 LowSpeed;
    UINT8 DeviceIsHub;
    UINT16 DeviceAddress;
    ULONG NumberOfOpenPipes;
    ULONG ConnectionStatus;
};

struct hub_descriptor
{
    UINT8 bDescriptorLength, bDescriptorType, bNumberOfPorts;
    UINT16 wHubCharacteristics;
    UINT8 bPowerOnToPowerGood, bHubControlCurrent, bRemoveAndPowerMask[64];
};

struct node_information
{
    ULONG NodeType;
    struct hub_descriptor HubDescriptor;
    UINT8 HubIsBusPowered;
};

struct name_result
{
    ULONG ActualLength;
    WCHAR Name[128];
};
#include "poppack.h"

/* No CRT, so nothing provides memset -- and clang recognises a byte-zeroing
 * loop and rewrites it INTO a call to memset, which is why hand-rolling one did
 * not help. `volatile` defeats that loop-idiom recognition, so this definition
 * cannot be turned into a call to itself. */
void * __cdecl memset(void *dst, int c, size_t n)
{
    volatile char *b = dst;
    while (n--) *b++ = (char)c;
    return dst;
}

static void zero(void *p, int n) { memset(p, 0, n); }

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

void __cdecl entry(void)
{
    int hcd, found_hcd = 0, found_dev = 0, pioneer = 0;
    char path[64];

    out("hcdtest — walking the USB bus the way rekordbox does\r\n\r\n");

    for (hcd = 0; hcd < 10; hcd++)
    {
        struct name_result rootname;
        struct node_information nodeinfo;
        HANDLE hub, ctl;
        DWORD ret;
        int port;

        wsprintfA(path, "\\\\.\\HCD%d", hcd);
        ctl = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (ctl == INVALID_HANDLE_VALUE)
            continue;

        found_hcd++;
        outf("%s opened\r\n", path);

        zero(&rootname, sizeof(rootname));
        if (!DeviceIoControl(ctl, IOCTL_USB_GET_ROOT_HUB_NAME, NULL, 0,
                &rootname, sizeof(rootname), &ret, NULL))
        {
            outf("    IOCTL_USB_GET_ROOT_HUB_NAME failed: %d\r\n", (int)GetLastError());
            CloseHandle(ctl);
            continue;
        }
        CloseHandle(ctl);
        outf("    root hub: %S\r\n", rootname.Name);

        wsprintfA(path, "\\\\.\\%S", rootname.Name);
        hub = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (hub == INVALID_HANDLE_VALUE)
        {
            outf("    cannot open %s: %d\r\n", path, (int)GetLastError());
            continue;
        }

        zero(&nodeinfo, sizeof(nodeinfo));
        if (!DeviceIoControl(hub, IOCTL_USB_GET_NODE_INFORMATION, &nodeinfo, sizeof(nodeinfo),
                &nodeinfo, sizeof(nodeinfo), &ret, NULL))
        {
            outf("    IOCTL_USB_GET_NODE_INFORMATION failed: %d\r\n", (int)GetLastError());
            CloseHandle(hub);
            continue;
        }
        outf("    hub reports %d ports\r\n", nodeinfo.HubDescriptor.bNumberOfPorts);

        for (port = 1; port <= nodeinfo.HubDescriptor.bNumberOfPorts; port++)
        {
            /* Oversized, as a real caller does: the struct is followed by a
             * variable-length pipe list. */
            char buffer[512];
            struct node_connection_information *conn = (void *)buffer;

            zero(buffer, sizeof(buffer));
            conn->ConnectionIndex = port;
            if (!DeviceIoControl(hub, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION,
                    buffer, sizeof(buffer), buffer, sizeof(buffer), &ret, NULL))
                continue;
            if (conn->ConnectionStatus != 1)
                continue;

            found_dev++;
            outf("    port %d: VID_%04X PID_%04X rev %04X  class %02X  addr %d%s\r\n",
                    port, conn->DeviceDescriptor.idVendor, conn->DeviceDescriptor.idProduct,
                    conn->DeviceDescriptor.bcdDevice, conn->DeviceDescriptor.bDeviceClass,
                    conn->DeviceAddress,
                    conn->DeviceDescriptor.idVendor == 0x2b73 ? "   <== Pioneer DJ" : "");
            if (conn->DeviceDescriptor.idVendor == 0x2b73)
                pioneer++;
        }
        CloseHandle(hub);
    }

    outf("\r\nhost controllers: %d, connected devices: %d, Pioneer: %d\r\n",
            found_hcd, found_dev, pioneer);

    if (!found_hcd)
        out("VERDICT: no \\\\.\\HCDn at all — this is stock Wine behaviour, the patch is not active.\r\n");
    else if (!pioneer)
        out("VERDICT: the bus walk works, but no Pioneer device was found on it.\r\n");
    else
        out("VERDICT: the bus walk works AND reports the Pioneer device with its real bcdDevice.\r\n");

    ExitProcess(pioneer ? 0 : 1);
}
