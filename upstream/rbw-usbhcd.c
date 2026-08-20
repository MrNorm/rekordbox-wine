/* RBW-USBHCD: the user-mode USB host controller interface --------------------
 *
 * This block is spliced into dlls/wineusb.sys/wineusb.c by
 * bin/build-wineusb-hcd.sh. It lives here as a separate file so it stays
 * reviewable and so the eventual upstream patch can be generated from it.
 *
 * WHAT IS MISSING FROM WINE
 *
 * Windows presents each USB host controller to user mode as \\.\HCDn and lets
 * an application walk the bus through it: ask the controller for its root hub,
 * ask that hub how many ports it has, then ask each port what is connected and
 * for that device's descriptors. usbview.exe is the canonical consumer, and an
 * application uses the same route when it wants a device's bcdDevice, which is
 * not reachable from user mode any other way.
 *
 * Wine has none of it. There is no \\.\HCDn device object anywhere in the tree,
 * and ddk/usbioctl.h defines only IOCTL_INTERNAL_USB_SUBMIT_URB. An application
 * that enumerates USB this way concludes that no USB hardware exists.
 *
 * Measured with rekordbox 7.2.17 and a Pioneer DDJ-400: rekordbox identifies the
 * controller correctly over HID, then calls djplay::USBDeviceValidation, which
 * opens \\.\HCD0 through \\.\HCD9 to read the device's bcdDevice. All ten opens
 * fail with STATUS_OBJECT_NAME_NOT_FOUND, the validation returns negative, and
 * rekordbox destroys the device object it had just built and never opens the
 * controller's MIDI port. Zero midiInOpen calls in the entire run.
 *
 * WHAT THIS REPORTS
 *
 * The truth as the kernel has it. Device and configuration descriptors are
 * copied verbatim from /sys/bus/usb/devices/<dev>/descriptors, so an application
 * asking what is plugged in gets exactly what the hardware reported to Linux.
 * Nothing is synthesised and no identity is invented.
 *
 * The one simplification is topology: each HCD maps to a real Linux USB bus and
 * each port to a real device on that bus, rather than reproducing the exact hub
 * tree. Device identity is therefore correct; anything that genuinely depends on
 * physical port layout would need the tree modelled properly.
 */

#define RBW_MAX_HCD   8
#define RBW_MAX_USB   64
#define RBW_HUB_PORTS 16    /* fixed, so a device plugged in later still fits */

#include "pshpack1.h"
struct rbw_device_descriptor
{
    UINT8 bLength, bDescriptorType;
    UINT16 bcdUSB;
    UINT8 bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize0;
    UINT16 idVendor, idProduct, bcdDevice;
    UINT8 iManufacturer, iProduct, iSerialNumber, bNumConfigurations;
};

struct rbw_node_connection_information
{
    ULONG ConnectionIndex;
    struct rbw_device_descriptor DeviceDescriptor;
    UINT8 CurrentConfigurationValue;
    UINT8 LowSpeed;
    UINT8 DeviceIsHub;
    UINT16 DeviceAddress;
    ULONG NumberOfOpenPipes;
    ULONG ConnectionStatus;
    /* USB_PIPE_INFO PipeList[] follows */
};

struct rbw_hub_descriptor
{
    UINT8 bDescriptorLength, bDescriptorType, bNumberOfPorts;
    UINT16 wHubCharacteristics;
    UINT8 bPowerOnToPowerGood, bHubControlCurrent, bRemoveAndPowerMask[64];
};

struct rbw_node_information
{
    ULONG NodeType;
    struct rbw_hub_descriptor HubDescriptor;
    UINT8 HubIsBusPowered;
};

struct rbw_descriptor_request
{
    ULONG ConnectionIndex;
    struct
    {
        UINT8 bmRequest, bRequest;
        UINT16 wValue, wIndex, wLength;
    } SetupPacket;
    /* descriptor data follows */
};

struct rbw_name_result
{
    ULONG ActualLength;
    WCHAR Name[1];
};
#include "poppack.h"

/* These packed layouts are the wire format of the IOCTLs. If one drifts a caller
 * silently reads the wrong field: ConnectionStatus sits at offset 31, and only
 * because the whole struct is byte-packed. rekordbox reads it at exactly +0x1f,
 * which is how the layout was confirmed. */
C_ASSERT(sizeof(struct rbw_device_descriptor) == 18);
C_ASSERT(sizeof(struct rbw_node_connection_information) == 35);
C_ASSERT(sizeof(struct rbw_node_information) == 76);

#define RBW_IOCTL_USB_GET_NODE_INFORMATION \
    CTL_CODE(FILE_DEVICE_USB, 258, METHOD_BUFFERED, FILE_ANY_ACCESS)  /* 0x220408 */
#define RBW_IOCTL_USB_GET_ROOT_HUB_NAME \
    CTL_CODE(FILE_DEVICE_USB, 258, METHOD_BUFFERED, FILE_ANY_ACCESS)  /* same code, sent to the HCD */
#define RBW_IOCTL_USB_GET_NODE_CONNECTION_INFORMATION \
    CTL_CODE(FILE_DEVICE_USB, 259, METHOD_BUFFERED, FILE_ANY_ACCESS)  /* 0x22040c */
#define RBW_IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION \
    CTL_CODE(FILE_DEVICE_USB, 260, METHOD_BUFFERED, FILE_ANY_ACCESS)  /* 0x220410 */
#define RBW_IOCTL_GET_HCD_DRIVERKEY_NAME \
    CTL_CODE(FILE_DEVICE_USB, 265, METHOD_BUFFERED, FILE_ANY_ACCESS)  /* 0x220424 */

static DEVICE_OBJECT *rbw_hcd_device[RBW_MAX_HCD];
static DEVICE_OBJECT *rbw_hub_device[RBW_MAX_HCD];
static UINT8 rbw_hcd_bus[RBW_MAX_HCD];
static unsigned int rbw_hcd_count;

static int rbw_find_device(DEVICE_OBJECT *device, BOOL *is_hub)
{
    unsigned int i;

    for (i = 0; i < rbw_hcd_count; ++i)
    {
        if (rbw_hcd_device[i] == device) { *is_hub = FALSE; return i; }
        if (rbw_hub_device[i] == device) { *is_hub = TRUE;  return i; }
    }
    return -1;
}

/* Devices on one bus, in port order. Re-read per call, so a controller plugged
 * in after startup is still seen. */
static UINT32 rbw_bus_devices(UINT8 busnum, struct usb_hcd_device *out, UINT32 capacity)
{
    static struct usb_hcd_device all[RBW_MAX_USB];
    struct usb_enum_hcd_params params;
    UINT32 i, n = 0;

    params.devices = all;
    params.capacity = RBW_MAX_USB;
    params.count = 0;
    if (WINE_UNIX_CALL(unix_usb_enum_hcd, &params))
        return 0;

    for (i = 0; i < params.count && n < capacity; ++i)
    {
        if (all[i].busnum != busnum) continue;
        out[n++] = all[i];
    }
    return n;
}

static NTSTATUS rbw_return_name(IRP *irp, ULONG outsize, const WCHAR *name)
{
    struct rbw_name_result *result = irp->AssociatedIrp.SystemBuffer;
    ULONG namelen = (wcslen(name) + 1) * sizeof(WCHAR);
    ULONG needed = offsetof(struct rbw_name_result, Name) + namelen;

    if (outsize < sizeof(ULONG))
        return STATUS_BUFFER_TOO_SMALL;

    result->ActualLength = needed;
    if (outsize < needed)
    {
        /* The documented two-step: ask with a small buffer, read ActualLength,
         * then ask again with a buffer of that size. */
        irp->IoStatus.Information = sizeof(ULONG);
        return STATUS_SUCCESS;
    }
    memcpy(result->Name, name, namelen);
    irp->IoStatus.Information = needed;
    return STATUS_SUCCESS;
}

static NTSTATUS rbw_hcd_ioctl(int index, ULONG code, IRP *irp, ULONG outsize)
{
    WCHAR name[32];

    switch (code)
    {
    case RBW_IOCTL_USB_GET_ROOT_HUB_NAME:
        /* The caller reopens this as \\.\<name>, so it must match the symbolic
         * link created in rbw_create_host_controllers(). */
        swprintf(name, ARRAY_SIZE(name), L"WINEUSBROOTHUB%u", index);
        TRACE("RBW-USBHCD: HCD%d root hub name -> %s\n", index, debugstr_w(name));
        return rbw_return_name(irp, outsize, name);

    case RBW_IOCTL_GET_HCD_DRIVERKEY_NAME:
        swprintf(name, ARRAY_SIZE(name), L"wineusb\\%u", index);
        return rbw_return_name(irp, outsize, name);

    default:
        FIXME("RBW-USBHCD: unhandled HCD ioctl %#lx\n", code);
        return STATUS_NOT_SUPPORTED;
    }
}

static NTSTATUS rbw_hub_ioctl(int index, ULONG code, IRP *irp, ULONG insize, ULONG outsize)
{
    static struct usb_hcd_device devices[RBW_MAX_USB];
    void *buffer = irp->AssociatedIrp.SystemBuffer;
    UINT32 count;

    switch (code)
    {
    case RBW_IOCTL_USB_GET_NODE_INFORMATION:
    {
        struct rbw_node_information *info = buffer;

        if (outsize < sizeof(*info)) return STATUS_BUFFER_TOO_SMALL;
        memset(info, 0, sizeof(*info));
        info->NodeType = 0;                                 /* UsbHub */
        info->HubDescriptor.bDescriptorLength = 9;
        info->HubDescriptor.bDescriptorType = 0x29;
        info->HubDescriptor.bNumberOfPorts = RBW_HUB_PORTS;
        info->HubDescriptor.bPowerOnToPowerGood = 1;
        info->HubIsBusPowered = 0;                          /* a root hub is self powered */
        irp->IoStatus.Information = sizeof(*info);
        return STATUS_SUCCESS;
    }

    case RBW_IOCTL_USB_GET_NODE_CONNECTION_INFORMATION:
    {
        struct rbw_node_connection_information *conn = buffer;
        ULONG port;

        if (insize < sizeof(ULONG) || outsize < sizeof(*conn))
            return STATUS_BUFFER_TOO_SMALL;
        port = conn->ConnectionIndex;

        count = rbw_bus_devices(rbw_hcd_bus[index], devices, RBW_MAX_USB);
        memset((char *)conn + sizeof(ULONG), 0, outsize - sizeof(ULONG));
        conn->ConnectionIndex = port;

        if (!port || port > count)
        {
            conn->ConnectionStatus = 0;                     /* NoDeviceConnected */
            irp->IoStatus.Information = outsize;
            return STATUS_SUCCESS;
        }

        memcpy(&conn->DeviceDescriptor, devices[port - 1].device_desc,
                sizeof(conn->DeviceDescriptor));
        conn->CurrentConfigurationValue = 1;
        conn->LowSpeed = devices[port - 1].low_speed;
        conn->DeviceIsHub = devices[port - 1].is_hub;
        conn->DeviceAddress = devices[port - 1].devnum;
        conn->NumberOfOpenPipes = 0;
        conn->ConnectionStatus = 1;                         /* DeviceConnected */
        TRACE("RBW-USBHCD: hub %d port %u -> VID_%04X PID_%04X rev %04X\n", index, (int)port,
                conn->DeviceDescriptor.idVendor, conn->DeviceDescriptor.idProduct,
                conn->DeviceDescriptor.bcdDevice);
        irp->IoStatus.Information = outsize;
        return STATUS_SUCCESS;
    }

    case RBW_IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION:
    {
        struct rbw_descriptor_request *req = buffer;
        ULONG port, avail, type, srclen;
        const UINT8 *src;

        if (insize < sizeof(*req) || outsize < sizeof(*req))
            return STATUS_BUFFER_TOO_SMALL;
        port = req->ConnectionIndex;
        type = req->SetupPacket.wValue >> 8;

        count = rbw_bus_devices(rbw_hcd_bus[index], devices, RBW_MAX_USB);
        if (!port || port > count)
            return STATUS_DEVICE_NOT_CONNECTED;

        if (type == 1)          /* device descriptor */
        {
            src = devices[port - 1].device_desc;
            srclen = sizeof(devices[port - 1].device_desc);
        }
        else if (type == 2)     /* configuration descriptor */
        {
            src = devices[port - 1].config_desc;
            srclen = devices[port - 1].config_len;
        }
        else
        {
            FIXME("RBW-USBHCD: descriptor type %u is not available from sysfs\n", (int)type);
            return STATUS_NOT_SUPPORTED;
        }

        avail = outsize - sizeof(*req);
        if (avail > srclen) avail = srclen;
        memcpy((char *)buffer + sizeof(*req), src, avail);
        irp->IoStatus.Information = sizeof(*req) + avail;
        return STATUS_SUCCESS;
    }

    default:
        FIXME("RBW-USBHCD: unhandled hub ioctl %#lx\n", code);
        return STATUS_NOT_SUPPORTED;
    }
}

static NTSTATUS WINAPI rbw_dispatch_create_close(DEVICE_OBJECT *device, IRP *irp)
{
    NTSTATUS status = STATUS_SUCCESS;
    BOOL is_hub;

    /* Answer only for the host controller objects this patch adds. Anything
     * else must keep whatever behaviour it had before. */
    if (rbw_find_device(device, &is_hub) < 0)
        status = STATUS_INVALID_DEVICE_REQUEST;

    irp->IoStatus.Status = status;
    irp->IoStatus.Information = 0;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

static NTSTATUS WINAPI rbw_dispatch_ioctl(DEVICE_OBJECT *device, IRP *irp)
{
    IO_STACK_LOCATION *stack = IoGetCurrentIrpStackLocation(irp);
    ULONG code = stack->Parameters.DeviceIoControl.IoControlCode;
    ULONG outsize = stack->Parameters.DeviceIoControl.OutputBufferLength;
    ULONG insize = stack->Parameters.DeviceIoControl.InputBufferLength;
    NTSTATUS status;
    BOOL is_hub;
    int index;

    if ((index = rbw_find_device(device, &is_hub)) < 0)
        status = STATUS_INVALID_DEVICE_REQUEST;
    else if (is_hub)
        status = rbw_hub_ioctl(index, code, irp, insize, outsize);
    else
        status = rbw_hcd_ioctl(index, code, irp, outsize);

    if (status) irp->IoStatus.Information = 0;
    irp->IoStatus.Status = status;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

/* One HCD per real Linux USB bus, each with its root hub. */
static void rbw_create_host_controllers(DRIVER_OBJECT *driver)
{
    static struct usb_hcd_device all[RBW_MAX_USB];
    struct usb_enum_hcd_params params;
    UNICODE_STRING devname, linkname;
    WCHAR devbuf[64], linkbuf[64];
    UINT8 buses[RBW_MAX_HCD];
    unsigned int i, j, nbuses = 0;
    DEVICE_OBJECT *device;

    params.devices = all;
    params.capacity = RBW_MAX_USB;
    params.count = 0;
    if (WINE_UNIX_CALL(unix_usb_enum_hcd, &params))
    {
        WARN("RBW-USBHCD: cannot enumerate USB devices; no host controllers exposed\n");
        return;
    }

    for (i = 0; i < params.count && nbuses < RBW_MAX_HCD; ++i)
    {
        for (j = 0; j < nbuses; ++j)
            if (buses[j] == all[i].busnum) break;
        if (j == nbuses) buses[nbuses++] = all[i].busnum;
    }

    for (i = 0; i < nbuses; ++i)
    {
        swprintf(devbuf, ARRAY_SIZE(devbuf), L"\\Device\\WineUsbHcd%u", i);
        swprintf(linkbuf, ARRAY_SIZE(linkbuf), L"\\??\\HCD%u", i);
        RtlInitUnicodeString(&devname, devbuf);
        RtlInitUnicodeString(&linkname, linkbuf);
        if (IoCreateDevice(driver, 0, &devname, FILE_DEVICE_CONTROLLER, 0, FALSE, &device))
            continue;
        device->Flags &= ~DO_DEVICE_INITIALIZING;
        IoCreateSymbolicLink(&linkname, &devname);
        rbw_hcd_device[i] = device;

        swprintf(devbuf, ARRAY_SIZE(devbuf), L"\\Device\\WineUsbRootHub%u", i);
        swprintf(linkbuf, ARRAY_SIZE(linkbuf), L"\\??\\WINEUSBROOTHUB%u", i);
        RtlInitUnicodeString(&devname, devbuf);
        RtlInitUnicodeString(&linkname, linkbuf);
        if (IoCreateDevice(driver, 0, &devname, FILE_DEVICE_CONTROLLER, 0, FALSE, &device))
            continue;
        device->Flags &= ~DO_DEVICE_INITIALIZING;
        IoCreateSymbolicLink(&linkname, &devname);
        rbw_hub_device[i] = device;

        rbw_hcd_bus[i] = buses[i];
        rbw_hcd_count = i + 1;
    }

    /* ERR, not TRACE, so that "is my patched driver actually loaded" is a single
     * grep -- the project rule is that a patch is not a fix until it is
     * greppable, and a comment-only change has fooled us before. */
    ERR("RBW-USBHCD: exposed %u host controller(s) as \\\\.\\HCDn for %u USB device(s)\n",
            rbw_hcd_count, params.count);
}
