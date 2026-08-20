/*
 * dualclient — does WASAPI keep TWO event-driven render clients fed under Wine?
 *
 * WHY THIS EXISTS. Phase 25 pinned rekordbox's audio fault to a single switch:
 * with PC MASTER OUT off the playback engine runs at 1.00x real time; with it on
 * — that is, with a SECOND output stream open — the engine runs at 0.05x, and
 * the file it is playing is read only once per stream rebuild. The application
 * is not writing silence into a running stream; its transport is stopped, and
 * something kicks it for one buffer every ~15.8 s when the stream is rebuilt.
 *
 * The obvious suspect is the event contract. Both streams are event-driven
 * (AUDCLNT_STREAMFLAGS_EVENTCALLBACK); a client whose event stops arriving waits
 * forever and produces nothing, which is exactly the observed shape. But that
 * has never been tested apart from rekordbox, and rekordbox has plenty of its
 * own two-device logic that could stall for reasons of its own.
 *
 * So this is the branch point, in the style of upstream/vblanktest.c and
 * research/probes/authreplay.py: reproduce the CONFIGURATION without the application.
 *
 *     dualclient.exe excl      exclusive client alone   (the DDJ)
 *     dualclient.exe shared    shared client alone      (the default endpoint)
 *     dualclient.exe both      both at once             (= PC MASTER OUT on)
 *
 * For each client it reports, per second of wall time:
 *     events    how often Wine signalled the stream event
 *     timeouts  waits that expired instead  <- a starved client
 *     wrote     frames actually handed to Wine, against real time
 *     GetBuffer successes and failures, with the HRESULT of the last failure
 *
 * READ THE COUNTERS TOGETHER. Frames written is the number that matters: a
 * client can be signalled briskly and still write nothing (GetBuffer refusing),
 * and a client can write everything it is asked for and still be starved (few
 * events). Reporting only one of them is how "the fix works" gets announced
 * about a stream that is dead — this project has done that once already.
 *
 * Deliberately freestanding (no CRT) so it cross-compiles with clang against
 * Wine's own headers — see build-dualclient.sh.
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

static const PROPERTYKEY PKEY_FriendlyName =
    {{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}},14};

int _fltused = 0;

/* Set by the command line; see entry(). */
static int opt_small = 0;    /* exclusive: ask for the MINIMUM device period,
                              * which is what rekordbox's 256-frame buffer
                              * setting amounts to */
static int opt_spin = 0;     /* feed the way rekordbox actually does: never wait
                              * on the event, poll GetCurrentPadding and hammer
                              * GetBuffer. Measured on the real application:
                              * ~160,000 AUDCLNT_E_BUFFER_TOO_LARGE refusals a
                              * second on the exclusive client, 43 successes.
                              * The polite version of this program is fed
                              * perfectly by Wine; the question is whether the
                              * IMPATIENT version still is, and whether one
                              * spinning client starves another. */
static int opt_full = 0;     /* ask GetBuffer for the WHOLE buffer every event,
                              * which is the documented exclusive-mode contract
                              * on Windows and what rekordbox does — phase 20
                              * measured asked=1024 against bufsize=1024 */
static int opt_r44 = 0;      /* shared: force 44100 Hz rather than the mix
                              * format, which is what rekordbox does — its
                              * PipeWire client shows up as 44100 while the
                              * endpoint mixes at 48000 */


static void out(const char *s)
{
    DWORD written, len = 0;
    while (s[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, len, &written, NULL);
}

static void u2a(const WCHAR *w, char *a, int max)
{
    int i = 0;
    while (w && w[i] && i < max - 1) { a[i] = (char)w[i]; i++; }
    a[i] = 0;
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

static const char *hrname(HRESULT hr)
{
    switch ((unsigned)hr) {
    case 0x00000000: return "S_OK";
    case 0x88890001: return "AUDCLNT_E_NOT_INITIALIZED";
    case 0x88890002: return "AUDCLNT_E_ALREADY_INITIALIZED";
    case 0x88890003: return "AUDCLNT_E_WRONG_ENDPOINT_TYPE";
    case 0x88890004: return "AUDCLNT_E_DEVICE_INVALIDATED";
    case 0x88890005: return "AUDCLNT_E_NOT_STOPPED";
    case 0x88890006: return "AUDCLNT_E_BUFFER_TOO_LARGE";
    case 0x88890007: return "AUDCLNT_E_OUT_OF_ORDER";
    case 0x88890008: return "AUDCLNT_E_UNSUPPORTED_FORMAT";
    case 0x88890009: return "AUDCLNT_E_INVALID_SIZE";
    case 0x8889000a: return "AUDCLNT_E_DEVICE_IN_USE";
    case 0x8889000b: return "AUDCLNT_E_BUFFER_OPERATION_PENDING";
    case 0x8889000e: return "AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED";
    case 0x8889000f: return "AUDCLNT_E_ENDPOINT_CREATE_FAILED";
    case 0x88890010: return "AUDCLNT_E_SERVICE_NOT_RUNNING";
    case 0x88890019: return "AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED";
    case 0x88890021: return "AUDCLNT_E_INVALID_DEVICE_PERIOD";
    case 0x80070005: return "E_ACCESSDENIED";
    case 0x80070490: return "ERROR_NOT_FOUND";
    default: return "?";
    }
}

struct clientinfo {
    const char *tag;
    IAudioClient *client;
    IAudioRenderClient *render;
    WAVEFORMATEX *fmt;
    HANDLE event;
    UINT32 bufsize;
    /* counters, written by the feeder thread, read after it has joined */
    volatile LONG events, timeouts, getbuf_ok, getbuf_fail, loops;
    volatile LONG frames_lo;      /* frames written; kept in one thread */
    HRESULT last_fail;
    volatile LONG stop;

    /* SERVICE-GAP TIMING (added for docs/investigation/THEMES/T10 phase 17).
     *
     * The earlier runs of this probe reported both clients writing "100% of
     * real time" and were read as exonerating Wine. They could not have shown
     * otherwise: the fault being chased is a ~46 ms hiccup once every 15 s,
     * which is 0.23% of the run and rounds away completely in a percentage.
     *
     * So time the interval between consecutive SUCCESSFUL service cycles --
     * one GetBuffer/ReleaseBuffer pair -- and keep the outliers with the
     * moment they happened, so their spacing can be read off directly.
     *
     * All arithmetic is integer microseconds: this is a freestanding build and
     * wsprintfA cannot format a double. */
    LARGE_INTEGER qpf, last_serviced, t_start;
    LONGLONG worst_us;
    UINT32 ngaps;
    struct { LONG at_ms; LONG us; } gaps[64];
};

#define GAP_REPORT_US 20000   /* 20 ms: comfortably above a normal period */

/* Freestanding build: there is no CRT, but the compiler is still entitled to
 * emit calls to memcpy/memset for things like struct initialisation. Growing
 * struct clientinfo (the service-gap arrays) was enough to make it do so, and
 * the link failed with "undefined symbol: memcpy". Provide them. */
void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *p = d; const unsigned char *q = s;
    while (n--) *p++ = *q++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

/* Fill with silence. The question here is whether the CONTRACT is honoured —
 * whether the client is signalled and allowed to write — not what it sounds
 * like. Writing audible tone into a DJ controller during an unattended
 * measurement is also a good way to deafen whoever is wearing the headphones. */
static void fill_silence(BYTE *buf, UINT32 frames, WAVEFORMATEX *fmt)
{
    /* volatile so the compiler cannot turn this into a call to memset, which
     * does not exist in a freestanding build. */
    volatile BYTE *p = buf;
    UINT32 i, n = frames * fmt->nBlockAlign;
    for (i = 0; i < n; i++) p[i] = 0;
}

static DWORD WINAPI feeder(void *arg)
{
    struct clientinfo *ci = arg;

    QueryPerformanceFrequency(&ci->qpf);
    QueryPerformanceCounter(&ci->t_start);
    ci->last_serviced = ci->t_start;

    while (!ci->stop) {
        if (!opt_spin) {
            DWORD w = WaitForSingleObject(ci->event, 2000);
            InterlockedIncrement(&ci->loops);
            if (w == WAIT_TIMEOUT) { InterlockedIncrement(&ci->timeouts); continue; }
            if (w != WAIT_OBJECT_0) break;
            InterlockedIncrement(&ci->events);
        } else {
            InterlockedIncrement(&ci->loops);
        }

        /* How much may we write? Exclusive event-driven streams are documented
         * to hand over the whole buffer each event; shared streams must consult
         * padding. Do both properly rather than assuming. */
        UINT32 avail = ci->bufsize;
        UINT32 pad = 0;
        HRESULT hr = IAudioClient_GetCurrentPadding(ci->client, &pad);
        if (SUCCEEDED(hr) && !opt_full) {
            if (pad > ci->bufsize) pad = ci->bufsize;
            avail = ci->bufsize - pad;
        }
        if (!avail) continue;

        BYTE *data;
        hr = IAudioRenderClient_GetBuffer(ci->render, avail, &data);
        if (FAILED(hr)) {
            InterlockedIncrement(&ci->getbuf_fail);
            ci->last_fail = hr;
            continue;
        }
        InterlockedIncrement(&ci->getbuf_ok);
        fill_silence(data, avail, ci->fmt);
        IAudioRenderClient_ReleaseBuffer(ci->render, avail, 0);
        InterlockedExchangeAdd(&ci->frames_lo, (LONG)avail);

        {   /* how long since this client was last served? */
            LARGE_INTEGER now;
            LONGLONG us;
            QueryPerformanceCounter(&now);
            us = (now.QuadPart - ci->last_serviced.QuadPart) * 1000000
                 / ci->qpf.QuadPart;
            if (us > ci->worst_us) ci->worst_us = us;
            if (us >= GAP_REPORT_US && ci->ngaps < 64) {
                ci->gaps[ci->ngaps].us = (LONG)us;
                ci->gaps[ci->ngaps].at_ms = (LONG)((now.QuadPart - ci->t_start.QuadPart)
                                                   * 1000 / ci->qpf.QuadPart);
                ci->ngaps++;
            }
            ci->last_serviced = now;
        }
    }
    return 0;
}

static IMMDevice *find_device(IMMDeviceEnumerator *devenum, const char *want,
                             char *name_out, int name_max)
{
    IMMDeviceCollection *coll = NULL;
    IMMDevice *found = NULL;
    UINT count = 0, i;

    if (!want) {   /* the default endpoint */
        if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(devenum, eRender,
                                                               eMultimedia, &found)))
            return NULL;
    }
    if (FAILED(IMMDeviceEnumerator_EnumAudioEndpoints(devenum, eRender,
                                                      DEVICE_STATE_ACTIVE, &coll)))
        return found;
    IMMDeviceCollection_GetCount(coll, &count);
    for (i = 0; i < count; i++) {
        IMMDevice *dev = NULL;
        IPropertyStore *store = NULL;
        PROPVARIANT v;
        char nm[256] = "";

        if (FAILED(IMMDeviceCollection_Item(coll, i, &dev))) continue;
        if (SUCCEEDED(IMMDevice_OpenPropertyStore(dev, STGM_READ, &store))) {
            PropVariantInit(&v);
            if (SUCCEEDED(IPropertyStore_GetValue(store, &PKEY_FriendlyName, &v))
                && v.vt == VT_LPWSTR)
                u2a(v.pwszVal, nm, sizeof(nm));
            PropVariantClear(&v);
            IPropertyStore_Release(store);
        }
        if (want) {
            /* substring match, case sensitive — the names are stable */
            int i2 = 0, hit = 0;
            for (i2 = 0; nm[i2]; i2++) {
                int j = 0;
                while (want[j] && nm[i2 + j] == want[j]) j++;
                if (!want[j]) { hit = 1; break; }
            }
            if (hit && !found) { found = dev; if (name_out) lstrcpynA(name_out, nm, name_max); continue; }
        } else if (found) {
            /* naming the default endpoint we already have */
            IMMDevice *def = found;
            WCHAR *id1 = NULL, *id2 = NULL;
            IMMDevice_GetId(def, &id1); IMMDevice_GetId(dev, &id2);
            if (id1 && id2) {
                int k = 0, same = 1;
                while (id1[k] || id2[k]) { if (id1[k] != id2[k]) { same = 0; break; } k++; }
                if (same && name_out) lstrcpynA(name_out, nm, name_max);
            }
            if (id1) CoTaskMemFree(id1);
            if (id2) CoTaskMemFree(id2);
        }
        IMMDevice_Release(dev);
    }
    IMMDeviceCollection_Release(coll);
    return found;
}

static int start_client(struct clientinfo *ci, IMMDevice *dev, int exclusive)
{
    HRESULT hr;
    REFERENCE_TIME defp = 0, minp = 0;

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&ci->client);
    if (FAILED(hr)) { outf("  %s: Activate 0x%08x %s\r\n", ci->tag, hr, hrname(hr)); return 0; }

    hr = IAudioClient_GetMixFormat(ci->client, &ci->fmt);
    if (FAILED(hr)) { outf("  %s: GetMixFormat 0x%08x %s\r\n", ci->tag, hr, hrname(hr)); return 0; }
    IAudioClient_GetDevicePeriod(ci->client, &defp, &minp);

    outf("  %s: format %u Hz  %u ch  %u bit    device period def %u us min %u us\r\n",
         ci->tag, ci->fmt->nSamplesPerSec, ci->fmt->nChannels, ci->fmt->wBitsPerSample,
         (unsigned)(defp / 10), (unsigned)(minp / 10));

    if (exclusive) {
        REFERENCE_TIME want = opt_small ? minp : defp;
        outf("  %s: asking for a %u us period%s\r\n", ci->tag,
             (unsigned)(want / 10), opt_small ? "  (--small: the minimum)" : "");
        hr = IAudioClient_Initialize(ci->client, AUDCLNT_SHAREMODE_EXCLUSIVE,
                                     AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                     want, want, ci->fmt, NULL);
    } else {
        DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        if (opt_r44 && ci->fmt->nSamplesPerSec != 44100) {
            /* A shared client whose format is not the mix format needs the
             * auto-convert flags; without them Wine and Windows both refuse.
             * Editing the format in place is safe — it is our own copy from
             * GetMixFormat. */
            ci->fmt->nSamplesPerSec = 44100;
            ci->fmt->nAvgBytesPerSec = 44100 * ci->fmt->nBlockAlign;
            flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
            outf("  %s: forcing 44100 Hz with AUTOCONVERTPCM  (--r44)\r\n", ci->tag);
        }
        hr = IAudioClient_Initialize(ci->client, AUDCLNT_SHAREMODE_SHARED,
                                     flags, 0, 0, ci->fmt, NULL);
    }
    if (FAILED(hr)) {
        outf("  %s: Initialize %s 0x%08x %s\r\n", ci->tag,
             exclusive ? "EXCLUSIVE|EVENT" : "SHARED|EVENT", hr, hrname(hr));
        return 0;
    }

    hr = IAudioClient_GetBufferSize(ci->client, &ci->bufsize);
    if (FAILED(hr)) { outf("  %s: GetBufferSize 0x%08x\r\n", ci->tag, hr); return 0; }

    ci->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    hr = IAudioClient_SetEventHandle(ci->client, ci->event);
    if (FAILED(hr)) { outf("  %s: SetEventHandle 0x%08x %s\r\n", ci->tag, hr, hrname(hr)); return 0; }

    hr = IAudioClient_GetService(ci->client, &IID_IAudioRenderClient, (void **)&ci->render);
    if (FAILED(hr)) { outf("  %s: GetService(render) 0x%08x %s\r\n", ci->tag, hr, hrname(hr)); return 0; }

    outf("  %s: initialised, buffer %u frames (%u ms)\r\n", ci->tag, ci->bufsize,
         ci->bufsize * 1000 / ci->fmt->nSamplesPerSec);
    return 1;
}

static void report(struct clientinfo *ci, DWORD ms)
{
    if (!ci->client) { outf("  %-8s not started\r\n", ci->tag); return; }
    UINT32 expect = (UINT32)((ULONGLONG)ci->fmt->nSamplesPerSec * ms / 1000);
    UINT32 wrote = (UINT32)ci->frames_lo;
    outf("  %-8s events %5d (%3d/s)  timeouts %4d  GetBuffer ok %5d fail %5d (last %s)\r\n",
         ci->tag, ci->events, (int)(ci->events * 1000 / (ms ? ms : 1)),
         ci->timeouts, ci->getbuf_ok, ci->getbuf_fail,
         ci->getbuf_fail ? hrname(ci->last_fail) : "-");
    outf("  %-8s wrote %u frames of %u expected in %u ms  = %u%% of real time\r\n",
         "", wrote, expect, (unsigned)ms, expect ? (unsigned)((ULONGLONG)wrote * 100 / expect) : 0);
}

void entry(void)
{
    HRESULT hr;
    IMMDeviceEnumerator *devenum = NULL;
    IMMDevice *ddj = NULL, *pc = NULL;
    char ddjname[256] = "", pcname[256] = "";
    struct clientinfo excl = { "EXCL/DDJ" }, shar = { "SHARED/PC" };
    int do_excl = 1, do_shared = 1;
    DWORD secs = 20;

    /* argument parsing, freestanding: look at the raw command line */
    {
        const WCHAR *cl = GetCommandLineW();
        char a[512];
        u2a(cl, a, sizeof(a));
        int i;
        for (i = 0; a[i]; i++) {
            if (a[i] == 'e' && a[i+1] == 'x' && a[i+2] == 'c') do_shared = 0;
            if (a[i] == 's' && a[i+1] == 'h' && a[i+2] == 'a') do_excl = 0;
            if (a[i] == 's' && a[i+1] == 'm' && a[i+2] == 'a') opt_small = 1;
            if (a[i] == 'r' && a[i+1] == '4' && a[i+2] == '4') opt_r44 = 1;
            if (a[i] == 'f' && a[i+1] == 'u' && a[i+2] == 'l') opt_full = 1;
            if (a[i] == 's' && a[i+1] == 'p' && a[i+2] == 'i') { opt_spin = 1; opt_full = 1; }
        }
        /* a bare number anywhere on the command line is the duration. The
         * previous version hardcoded 20 s and silently ignored the argument,
         * so every "90 s" run in the record was really a 20 s run. */
        {
            int j = 0, v = 0, seen = 0;
            for (j = 0; a[j]; j++) {
                if (a[j] >= '0' && a[j] <= '9') { v = v * 10 + (a[j] - '0'); seen = 1; }
                else if (seen) break;
                else v = 0;
            }
            if (seen && v >= 5 && v <= 3600) secs = v;
        }
    }

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) { outf("CoInitializeEx 0x%08x\r\n", hr); ExitProcess(2); }
    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IMMDeviceEnumerator, (void **)&devenum);
    if (FAILED(hr)) { outf("CoCreateInstance 0x%08x\r\n", hr); ExitProcess(2); }

    outf("== dualclient: %s%s%s, %u s%s%s%s ==\r\n",
         do_excl ? "exclusive" : "", (do_excl && do_shared) ? " + " : "",
         do_shared ? "shared" : "", secs,
         opt_full ? ", asking for the WHOLE buffer each time" : "",
         opt_spin ? ", SPINNING like rekordbox (no event wait)" : "",
         opt_small ? ", minimum period" : "");

    if (do_excl) {
        ddj = find_device(devenum, "DDJ", ddjname, sizeof(ddjname));
        if (!ddj) { out("  no endpoint whose name contains 'DDJ' — is the controller connected?\r\n"); do_excl = 0; }
        else outf("  exclusive endpoint : %s\r\n", ddjname);
    }
    if (do_shared) {
        pc = find_device(devenum, NULL, pcname, sizeof(pcname));
        if (!pc) { out("  no default render endpoint\r\n"); do_shared = 0; }
        else outf("  shared endpoint    : %s\r\n", pcname[0] ? pcname : "(default)");
    }
    if (!do_excl && !do_shared) ExitProcess(2);

    if (do_excl && !start_client(&excl, ddj, 1)) do_excl = 0;
    if (do_shared && !start_client(&shar, pc, 0)) do_shared = 0;
    if (!do_excl && !do_shared) { out("  nothing started — no measurement.\r\n"); ExitProcess(2); }

    HANDLE th1 = NULL, th2 = NULL;
    if (do_excl)   th1 = CreateThread(NULL, 0, feeder, &excl, 0, NULL);
    if (do_shared) th2 = CreateThread(NULL, 0, feeder, &shar, 0, NULL);

    DWORD t0 = GetTickCount();
    if (do_excl)   IAudioClient_Start(excl.client);
    if (do_shared) IAudioClient_Start(shar.client);
    out("  started; measuring...\r\n");
    Sleep(secs * 1000);
    DWORD elapsed = GetTickCount() - t0;
    if (do_excl)   IAudioClient_Stop(excl.client);
    if (do_shared) IAudioClient_Stop(shar.client);
    excl.stop = shar.stop = 1;
    if (excl.event) SetEvent(excl.event);
    if (shar.event) SetEvent(shar.event);
    if (th1) WaitForSingleObject(th1, 3000);
    if (th2) WaitForSingleObject(th2, 3000);

    outf("\r\n== RESULT after %u ms ==\r\n", elapsed);
    if (do_excl)   report(&excl, elapsed);
    if (do_shared) report(&shar, elapsed);
    out("\r\n== SERVICE GAPS ==\r\n");
    {
        struct clientinfo *all[2]; int n = 0, k, g;
        if (do_excl)   all[n++] = &excl;
        if (do_shared) all[n++] = &shar;
        for (k = 0; k < n; k++) {
            struct clientinfo *ci = all[k];
            outf("  %-9s worst gap between service cycles: %u us  "
                 "(%u gap(s) over %u ms)\r\n",
                 ci->tag, (unsigned)ci->worst_us, ci->ngaps, GAP_REPORT_US / 1000);
            for (g = 0; g < (int)ci->ngaps; g++)
                outf("        at %7u ms   gap %6u us\r\n",
                     ci->gaps[g].at_ms, ci->gaps[g].us);
        }
    }
    out("\r\n  A client writing ~100%% of real time is being kept fed -- but that\r\n"
        "  figure cannot see a brief hiccup, so read the gaps above. Gaps of\r\n"
        "  ~46 ms recurring every ~15 s on the EXCLUSIVE client would be the\r\n"
        "  rekordbox fault reproduced with no rekordbox in the picture.\r\n");
    ExitProcess(0);
}
