/*
 * devtreetest — walk the Windows device tree the way an application looks for
 * "the other interfaces of the device I just found".
 *
 * rekordbox locates a controller through its HID interface
 * (HID\VID_2B73&PID_0026&MI_04\...) and then has to reach the SAME physical
 * device's MIDI interface to bind it. On Windows that is a devnode walk: go up
 * to the USB composite parent, then enumerate its children with
 * CM_Get_Child + CM_Get_Sibling and pick the interface you want.
 *
 * Two things can break that under Wine, and they need telling apart:
 *
 *   1. The API lies. CM_Get_Child_Ex and CM_Get_DevNode_Status_Ex were stubs
 *      that returned CR_SUCCESS WITHOUT writing their out-parameters, so the
 *      caller walked off into stack garbage. (Patch 0005 fixes this.)
 *
 *   2. The tree is too shallow. Wine's winebus creates one PDO per HID device
 *      hanging off ROOT\WINE\WINEBUS — there is no USB composite parent and no
 *      devnode at all for the audio or MIDI interfaces, so there is nothing to
 *      walk to even with a correct API.
 *
 * This prints the tree it can actually see, so which of those is happening is a
 * measurement. Run it against stock Wine and against the patched cfgmgr32 and
 * diff the two.
 *
 * Freestanding (no CRT) — see build-probes.sh.
 */

#include <windows.h>
#include <cfgmgr32.h>

int _fltused = 0;

/* ARRAY_SIZE is a Wine-internal macro and this probe is freestanding.
 * CM_LOCATE_DEVNODE_NORMAL is absent from Wine's cfgmgr32.h entirely (its
 * documented value is 0), which is itself a small header gap. */
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#ifndef CM_LOCATE_DEVNODE_NORMAL
#define CM_LOCATE_DEVNODE_NORMAL 0x00000000
#endif

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
    if (!w || !w[0]) { out("(empty)"); return; }
    WideCharToMultiByte(CP_ACP, 0, w, -1, buf, sizeof(buf), NULL, NULL);
    out(buf);
}

static const char *crname(CONFIGRET cr)
{
    switch (cr)
    {
    case CR_SUCCESS:           return "CR_SUCCESS";
    case CR_INVALID_POINTER:   return "CR_INVALID_POINTER";
    case CR_INVALID_DEVNODE:   return "CR_INVALID_DEVNODE";   /* == CR_INVALID_DEVINST */
    case CR_NO_SUCH_DEVNODE:   return "CR_NO_SUCH_DEVINST";   /* == CR_NO_SUCH_DEVNODE */
    case CR_NO_SUCH_VALUE:     return "CR_NO_SUCH_VALUE";
    case CR_BUFFER_SMALL:      return "CR_BUFFER_SMALL";
    case CR_FAILURE:           return "CR_FAILURE";
    default:                   return "CR_<other>";
    }
}

static void indent(int depth) { for (int i = 0; i < depth; i++) out("  "); }

/* Recursive child/sibling walk — the classic idiom, written exactly as an
 * application would write it, so that a broken CM_Get_Child shows up here the
 * same way it shows up in real software. */
static void dump(DEVINST node, int depth, int maxdepth)
{
    WCHAR id[MAX_DEVICE_ID_LEN];
    ULONG status = 0xdeadbeef, problem = 0xdeadbeef;
    DEVINST child, sib;
    CONFIGRET cr;

    if (depth > maxdepth) return;

    id[0] = 0;
    if (CM_Get_Device_IDW(node, id, ARRAY_SIZE(id), 0) != CR_SUCCESS)
        lstrcpyW(id, L"<CM_Get_Device_IDW failed>");

    indent(depth);
    outw(id);

    /* Deliberately pre-poisoned: if the callee returns CR_SUCCESS without
     * writing these, 0xdeadbeef is printed and the bug is visible rather than
     * looking like a plausible device state. */
    cr = CM_Get_DevNode_Status(&status, &problem, node, 0);
    outf("   [status: %s st=%08X prob=%08X]\r\n", crname(cr), (int)status, (int)problem);

    child = 0xdeadbeef;
    cr = CM_Get_Child(&child, node, 0);
    if (cr != CR_SUCCESS)
    {
        if (cr != CR_NO_SUCH_DEVNODE) { indent(depth + 1); outf("CM_Get_Child -> %s\r\n", crname(cr)); }
        return;
    }
    if (child == 0xdeadbeef)
    {
        indent(depth + 1);
        out("*** CM_Get_Child returned CR_SUCCESS but never wrote *child ***\r\n");
        return;
    }

    dump(child, depth + 1, maxdepth);

    for (;;)
    {
        sib = 0xdeadbeef;
        cr = CM_Get_Sibling(&sib, child, 0);
        if (cr != CR_SUCCESS) break;
        if (sib == 0xdeadbeef)
        {
            indent(depth + 1);
            out("*** CM_Get_Sibling returned CR_SUCCESS but never wrote *sibling ***\r\n");
            break;
        }
        dump(sib, depth + 1, maxdepth);
        child = sib;
    }
}

void __cdecl entry(void)
{
    static const WCHAR ddj_hid[] = L"HID\\VID_2B73&PID_0026&MI_04";
    WCHAR id[MAX_DEVICE_ID_LEN];
    DEVINST root, node, parent;
    CONFIGRET cr;
    ULONG len;
    WCHAR *list, *p;

    out("=== whole device tree, 4 levels ===\r\n");
    if ((cr = CM_Locate_DevNodeW(&root, NULL, CM_LOCATE_DEVNODE_NORMAL)) != CR_SUCCESS)
        outf("CM_Locate_DevNodeW(root) -> %s\r\n", crname(cr));
    else
        dump(root, 0, 4);

    out("\r\n=== the DDJ-400, and what can be reached from it ===\r\n");

    /* Find the controller's HID devnode by prefix — the instance suffix varies
     * between replugs, so it cannot be hardcoded. */
    len = 0;
    if (CM_Get_Device_ID_List_SizeW(&len, NULL, CM_GETIDLIST_FILTER_NONE) != CR_SUCCESS || !len)
    { out("CM_Get_Device_ID_List_SizeW failed\r\n"); ExitProcess(2); }

    list = HeapAlloc(GetProcessHeap(), 0, len * sizeof(WCHAR));
    if (!list) ExitProcess(3);
    if (CM_Get_Device_ID_ListW(NULL, list, len, CM_GETIDLIST_FILTER_NONE) != CR_SUCCESS)
    { out("CM_Get_Device_ID_ListW failed\r\n"); ExitProcess(4); }

    for (p = list; *p; p += lstrlenW(p) + 1)
    {
        if (CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, p, lstrlenW(ddj_hid),
                           ddj_hid, lstrlenW(ddj_hid)) != CSTR_EQUAL)
            continue;

        out("found: "); outw(p); out("\r\n");

        if ((cr = CM_Locate_DevNodeW(&node, p, CM_LOCATE_DEVNODE_NORMAL)) != CR_SUCCESS)
        { outf("  CM_Locate_DevNodeW -> %s\r\n", crname(cr)); continue; }

        /* This is the walk rekordbox needs: up to the composite device, then
         * across its children to the MIDI interface. */
        parent = 0xdeadbeef;
        if ((cr = CM_Get_Parent(&parent, node, 0)) != CR_SUCCESS)
        { outf("  CM_Get_Parent -> %s\r\n", crname(cr)); continue; }

        id[0] = 0;
        CM_Get_Device_IDW(parent, id, ARRAY_SIZE(id), 0);
        out("  parent: "); outw(id); out("\r\n");

        parent = 0xdeadbeef;
        if ((cr = CM_Get_Parent(&parent, node, 0)) == CR_SUCCESS)
        {
            DEVINST grand = 0xdeadbeef;
            if ((cr = CM_Get_Parent(&grand, parent, 0)) == CR_SUCCESS)
            {
                id[0] = 0;
                CM_Get_Device_IDW(grand, id, ARRAY_SIZE(id), 0);
                out("  grandparent: "); outw(id); out("\r\n");
                out("  siblings of the HID interface under the grandparent:\r\n");
                dump(grand, 2, 3);
            }
            else outf("  CM_Get_Parent(grandparent) -> %s\r\n", crname(cr));
        }
    }

    out("\r\nWhat to look for: on Windows the grandparent is the USB composite\r\n"
        "device USB\\VID_2B73&PID_0026\\<serial> and its children are MI_00..MI_04,\r\n"
        "one of which is the MIDI interface. If the grandparent is ROOT\\WINE\\WINEBUS\r\n"
        "and the siblings are unrelated devices, the tree cannot express this\r\n"
        "hardware and no amount of correct API will find the MIDI interface.\r\n");

    ExitProcess(0);
}
