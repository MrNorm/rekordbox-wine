/*
 * miditest — does Wine expose the controller's MIDI ports, and does opening one
 * by index actually connect to THAT device?
 *
 * A DJ controller is two devices in one shell: an audio interface and a MIDI
 * surface. Getting the audio path working says nothing about whether the jog
 * wheels, faders and pads reach the application, and the two are handled by
 * completely different Wine code.
 *
 * Written for a concrete failure: with rekordbox 7.2.x running and a Pioneer
 * DDJ-400 connected, `aconnect -l` shows Wine's MIDI client subscribed to
 * "Midi Through" rather than to the controller, and the controller's rawmidi
 * counters show zero bytes in either direction. So the interesting question is
 * not "are the ports enumerated" (they are) but "does midiOutOpen(n) subscribe
 * to the same device midiOutGetDevCaps(n) describes".
 *
 * Modes:
 *   miditest              list MIDI IN and OUT devices
 *   miditest out <n>      open OUT device n, send a note, hold it open
 *   miditest in <n>       open IN device n, receive for a while, print messages
 *
 * The hold-open behaviour is deliberate: it gives an observer time to run
 * `aconnect -l` and see which ALSA client Wine actually subscribed to.
 *
 * Freestanding (no CRT) — see build-probes.sh.
 */

#define COBJMACROS
#include <windows.h>
#include <mmsystem.h>

int _fltused = 0;

#define HOLD_SECONDS 8
#define MAX_LOGGED   64

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

/* Substring match and integer parse, no CRT. */
static int contains(const char *hay, const char *needle)
{
    int i, j;
    for (i = 0; hay[i]; i++)
    {
        for (j = 0; needle[j] && hay[i + j] == needle[j]; j++) ;
        if (!needle[j]) return 1;
    }
    return 0;
}

/* Last integer on the command line, or -1. */
static int trailing_int(const char *s)
{
    int i, last = -1, val = 0, in_num = 0;
    for (i = 0; s[i]; i++)
    {
        if (s[i] >= '0' && s[i] <= '9') { val = in_num ? val * 10 + (s[i] - '0') : (s[i] - '0'); in_num = 1; }
        else if (in_num) { last = val; in_num = 0; }
    }
    return in_num ? val : last;
}

static void list_devices(void)
{
    MIDIOUTCAPSA ocaps;
    MIDIINCAPSA icaps;
    UINT n, i;

    n = midiOutGetNumDevs();
    outf("MIDI OUT devices: %d\r\n", (int)n);
    for (i = 0; i < n; i++)
        if (midiOutGetDevCapsA(i, &ocaps, sizeof(ocaps)) == MMSYSERR_NOERROR)
            outf("  [%d] %s\r\n", (int)i, ocaps.szPname);

    n = midiInGetNumDevs();
    outf("MIDI IN devices : %d\r\n", (int)n);
    for (i = 0; i < n; i++)
        if (midiInGetDevCapsA(i, &icaps, sizeof(icaps)) == MMSYSERR_NOERROR)
            outf("  [%d] %s\r\n", (int)i, icaps.szPname);
}

static void do_out(int idx)
{
    MIDIOUTCAPSA caps;
    HMIDIOUT h = NULL;
    MMRESULT r;
    int i;

    if (midiOutGetDevCapsA(idx, &caps, sizeof(caps)) != MMSYSERR_NOERROR)
    { outf("no OUT device %d\r\n", idx); return; }

    outf("opening OUT [%d] %s\r\n", idx, caps.szPname);
    r = midiOutOpen(&h, idx, 0, 0, CALLBACK_NULL);
    outf("  midiOutOpen : %d %s\r\n", (int)r, r == MMSYSERR_NOERROR ? "(ok)" : "(FAILED)");
    if (r != MMSYSERR_NOERROR) return;

    /* Note On / Note Off on channel 1, a few times. On a controller with LED
     * feedback this is visible; on any device it moves the rawmidi Tx counter,
     * which is the measurement that matters. */
    for (i = 0; i < 8; i++)
    {
        midiOutShortMsg(h, 0x00417F90);   /* 90 7F 41 -> note on  */
        Sleep(120);
        midiOutShortMsg(h, 0x00410090);   /* 90 00 41 -> note off */
        Sleep(120);
    }
    outf("  sent 16 short messages\r\n");

    outf("  holding the port open for %d s — run `aconnect -l` now\r\n", HOLD_SECONDS);
    Sleep(HOLD_SECONDS * 1000);

    midiOutClose(h);
    out("  closed\r\n");
}

static volatile LONG g_count = 0;
static DWORD g_msgs[MAX_LOGGED];

static void CALLBACK in_cb(HMIDIIN h, UINT msg, DWORD_PTR inst, DWORD_PTR p1, DWORD_PTR p2)
{
    LONG n;
    if (msg != MIM_DATA) return;
    n = InterlockedIncrement(&g_count);
    if (n <= MAX_LOGGED) g_msgs[n - 1] = (DWORD)p1;
}

static void do_in(int idx)
{
    MIDIINCAPSA caps;
    HMIDIIN h = NULL;
    MMRESULT r;
    int i, n;

    if (midiInGetDevCapsA(idx, &caps, sizeof(caps)) != MMSYSERR_NOERROR)
    { outf("no IN device %d\r\n", idx); return; }

    outf("opening IN [%d] %s\r\n", idx, caps.szPname);
    r = midiInOpen(&h, idx, (DWORD_PTR)in_cb, 0, CALLBACK_FUNCTION);
    outf("  midiInOpen  : %d %s\r\n", (int)r, r == MMSYSERR_NOERROR ? "(ok)" : "(FAILED)");
    if (r != MMSYSERR_NOERROR) return;

    r = midiInStart(h);
    outf("  midiInStart : %d %s\r\n", (int)r, r == MMSYSERR_NOERROR ? "(ok)" : "(FAILED)");

    outf("  listening for %d s — MOVE A CONTROL ON THE CONTROLLER NOW\r\n", HOLD_SECONDS);
    Sleep(HOLD_SECONDS * 1000);

    midiInStop(h);
    n = g_count;
    outf("  messages received: %d\r\n", n);
    if (n > MAX_LOGGED) n = MAX_LOGGED;
    for (i = 0; i < n; i++)
        outf("    %02x %02x %02x\r\n", g_msgs[i] & 0xff,
             (g_msgs[i] >> 8) & 0xff, (g_msgs[i] >> 16) & 0xff);
    if (!g_count)
        out("  VERDICT: nothing arrived. Either the port is not subscribed to the\r\n"
            "           device, or input is not delivered to the callback.\r\n");
    else
        out("  VERDICT: MIDI input works on this device index.\r\n");

    midiInClose(h);
}

void __cdecl entry(void)
{
    const char *cmd = GetCommandLineA();
    int idx = trailing_int(cmd);

    if (contains(cmd, "out") && idx >= 0)      do_out(idx);
    else if (contains(cmd, "in ") && idx >= 0) do_in(idx);
    else                                       list_devices();

    ExitProcess(0);
}
