/*
 * wasapitest — what does IAudioClient::IsFormatSupported actually answer?
 *
 * Written for a concrete failure: rekordbox 7.2.x under Wine lists every audio
 * endpoint but shows an EMPTY sample-rate dropdown for all of them, including a
 * Pioneer DDJ-400 whose hardware is 44100-only. A +mmdevapi trace shows the app
 * sweeping rates with AUDCLNT_SHAREMODE_EXCLUSIVE (mode 1) and a NULL closest-
 * match pointer, which is exactly what the API says to do for exclusive mode.
 *
 * Wine's PulseAudio driver answers every one of those with
 * AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED (0x8889000e):
 *
 *     dlls/winepulse.drv/pulse.c, pulse_is_format_supported()
 *         /..* This driver does not support exclusive mode. *../
 *
 * so no rate is ever supported, and any application that builds its rate list
 * from exclusive-mode probes gets an empty list. The ALSA driver
 * (dlls/winealsa.drv/alsa.c, alsa_is_format_supported()) does a real hardware
 * check and answers properly.
 *
 * This program prints the answer for every render endpoint so the two drivers
 * can be compared directly:
 *
 *     WINEDLLOVERRIDES=... wine wasapitest.exe            # whatever is configured
 *
 * Deliberately freestanding (no CRT) so it cross-compiles with clang against
 * Wine's own headers and import libraries — see build-wasapitest.sh.
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

/* Defined by hand rather than pulled from ksmedia.h, whose DEFINE_GUIDEX form
 * does not survive a freestanding build. */
static const GUID SUBTYPE_PCM =
    {0x00000001,0x0000,0x0010,{0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}};
static const GUID SUBTYPE_FLOAT =
    {0x00000003,0x0000,0x0010,{0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}};
/* PKEY_Device_FriendlyName, likewise. */
static const PROPERTYKEY PKEY_FriendlyName =
    {{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}},14};

/* Freestanding: the compiler emits a reference to this the moment a float is
 * used, and there is no CRT here to provide it. */
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

static void zero(void *p, int n)
{
    char *c = p;
    while (n--) *c++ = 0;
}

/* The handful of HRESULTs that actually come back here, named — because
 * 0x8889001a means nothing to a reader and "EXCLUSIVE_MODE_NOT_ALLOWED" is the
 * whole finding. */
static const char *hrname(HRESULT hr)
{
    /* Named from the header constants, never from remembered hex — the first
     * version of this table guessed EXCLUSIVE_MODE_NOT_ALLOWED as 0x8889001a
     * (it is AUDCLNT_ERR(0x0e)) and reported the whole finding as "ERR". */
    if (hr == S_OK)                                   return "S_OK";
    if (hr == S_FALSE)                                return "S_FALSE";
    if (hr == E_POINTER)                              return "E_POINTER";
    if (hr == E_INVALIDARG)                           return "E_INVALIDARG";
    if (hr == AUDCLNT_E_NOT_INITIALIZED)              return "NOT_INITIALIZED";
    if (hr == AUDCLNT_E_DEVICE_INVALIDATED)           return "DEVICE_INVALIDATED";
    if (hr == AUDCLNT_E_UNSUPPORTED_FORMAT)           return "UNSUPPORTED_FORMAT";
    if (hr == AUDCLNT_E_DEVICE_IN_USE)                return "DEVICE_IN_USE";
    if (hr == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED)   return "EXCLUSIVE_MODE_NOT_ALLOWED";
    if (hr == AUDCLNT_E_ENDPOINT_CREATE_FAILED)       return "ENDPOINT_CREATE_FAILED";
    if (hr == AUDCLNT_E_SERVICE_NOT_RUNNING)          return "SERVICE_NOT_RUNNING";
    if (hr == AUDCLNT_E_BUFFER_TOO_LARGE)             return "BUFFER_TOO_LARGE";
    if (hr == AUDCLNT_E_OUT_OF_ORDER)                 return "OUT_OF_ORDER";
    if (hr == AUDCLNT_E_BUFFER_SIZE_ERROR)            return "BUFFER_SIZE_ERROR";
    return "?";
}

/* Compact per-cell marker so a whole sweep fits on one screen. */
static const char *cell(HRESULT hr)
{
    if (hr == S_OK)                                 return " ok ";
    if (hr == S_FALSE)                              return " S_F";  /* no, but here is a closer one */
    if (hr == AUDCLNT_E_UNSUPPORTED_FORMAT)         return "  . ";  /* honest "hardware cannot"      */
    if (hr == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED) return " XCL";  /* driver refuses exclusive mode */
    if (hr == AUDCLNT_E_DEVICE_IN_USE)              return " BSY";  /* already open elsewhere        */
    return " ERR";
}

static const int RATES[] = {44100, 48000, 88200, 96000, 176400, 192000};
#define NRATES 6
static const int CHANS[] = {2, 4};
#define NCHANS 2

struct depth { int bits; const GUID *sub; const char *label; };
static const struct depth DEPTHS[] = {
    {16, &SUBTYPE_PCM,   " 16 "},
    {24, &SUBTYPE_PCM,   " 24 "},
    {32, &SUBTYPE_PCM,   "32i "},
    {32, &SUBTYPE_FLOAT, "32f "},
};
#define NDEPTHS 4

static void make_fmt(WAVEFORMATEXTENSIBLE *w, int rate, int chans, const struct depth *d)
{
    zero(w, sizeof(*w));
    w->Format.wFormatTag      = WAVE_FORMAT_EXTENSIBLE;
    w->Format.nChannels       = chans;
    w->Format.nSamplesPerSec  = rate;
    w->Format.wBitsPerSample  = d->bits;
    w->Format.nBlockAlign     = chans * d->bits / 8;
    w->Format.nAvgBytesPerSec = rate * w->Format.nBlockAlign;
    w->Format.cbSize          = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    w->Samples.wValidBitsPerSample = d->bits;
    w->dwChannelMask          = chans == 2 ? 0x3 : 0xf;
    w->SubFormat              = *d->sub;
}

static void print_name(IMMDevice *dev)
{
    IPropertyStore *props = NULL;
    PROPVARIANT pv;
    char name[256];

    if (FAILED(IMMDevice_OpenPropertyStore(dev, STGM_READ, &props)))
    {
        out("(no property store)");
        return;
    }
    zero(&pv, sizeof(pv));
    if (SUCCEEDED(IPropertyStore_GetValue(props, &PKEY_FriendlyName, &pv)) && pv.pwszVal)
    {
        WideCharToMultiByte(CP_ACP, 0, pv.pwszVal, -1, name, sizeof(name), NULL, NULL);
        out(name);
    }
    else
        out("(unnamed)");
    IPropertyStore_Release(props);
}

static void probe_device(IMMDevice *dev, int idx)
{
    IAudioClient *client = NULL;
    WAVEFORMATEX *mix = NULL, *closest = NULL;
    WAVEFORMATEXTENSIBLE w;
    HRESULT hr;
    int r, c, d, exclusive_ok = 0, exclusive_refused = 0;
    HRESULT seen[16];
    int nseen = 0, s;

    outf("\r\n[%d] ", idx);
    print_name(dev);
    out("\r\n");

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    if (FAILED(hr)) { outf("    Activate failed: 0x%08x %s\r\n", hr, hrname(hr)); return; }

    hr = IAudioClient_GetMixFormat(client, &mix);
    if (SUCCEEDED(hr) && mix)
        outf("    mix format      : %d Hz, %d ch, %d bit\r\n",
             (int)mix->nSamplesPerSec, (int)mix->nChannels, (int)mix->wBitsPerSample);
    else
        outf("    GetMixFormat failed: 0x%08x %s\r\n", hr, hrname(hr));

    /* SHARED, at the mix format. Should always be S_OK; if this fails the
     * device is unusable for ordinary playback too. */
    if (mix)
    {
        hr = IAudioClient_IsFormatSupported(client, AUDCLNT_SHAREMODE_SHARED, mix, &closest);
        outf("    shared @ mix    : 0x%08x %s\r\n", hr, hrname(hr));
        if (closest) { CoTaskMemFree(closest); closest = NULL; }
    }

    /* EXCLUSIVE sweep — this is the one that populates a DJ application's
     * sample-rate list. NULL closest-match pointer is correct here. */
    for (c = 0; c < NCHANS; c++)
    {
        outf("\r\n    EXCLUSIVE, %d channels\r\n", CHANS[c]);
        out("        rate     16   24  32i  32f\r\n");
        for (r = 0; r < NRATES; r++)
        {
            outf("      %6d ", RATES[r]);
            for (d = 0; d < NDEPTHS; d++)
            {
                make_fmt(&w, RATES[r], CHANS[c], &DEPTHS[d]);
                hr = IAudioClient_IsFormatSupported(client, AUDCLNT_SHAREMODE_EXCLUSIVE,
                                                    (WAVEFORMATEX *)&w, NULL);
                out(cell(hr));
                if (hr == S_OK) exclusive_ok++;
                if (hr == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED) exclusive_refused++;
                for (s = 0; s < nseen; s++) if (seen[s] == hr) break;
                if (s == nseen && nseen < 16) seen[nseen++] = hr;
            }
            out("\r\n");
        }
    }

    /* The table cells are deliberately terse, so name every distinct code that
     * actually came back — an unexplained "ERR" is worse than no probe at all. */
    out("\r\n    HRESULTs seen   :");
    for (s = 0; s < nseen; s++)
        outf(" 0x%08x(%s)", seen[s], hrname(seen[s]));
    out("\r\n");

    out("\r\n    verdict: ");
    if (exclusive_refused == NRATES * NCHANS * NDEPTHS)
        out("EVERY exclusive probe refused with EXCLUSIVE_MODE_NOT_ALLOWED.\r\n"
            "             The driver does not implement exclusive mode at all, so an\r\n"
            "             application building a rate list from it gets nothing.\r\n");
    else if (!exclusive_ok)
        out("no exclusive format accepted (but the driver did answer per-format).\r\n");
    else
        outf("%d exclusive formats accepted — a rate list can be built.\r\n", exclusive_ok);

    if (mix) CoTaskMemFree(mix);
    IAudioClient_Release(client);
}

/* IsFormatSupported saying "yes" is not the same as a stream that runs, and the
 * difference is exactly where a driver swap can look like a fix and not be one.
 * `wasapitest play` opens an EXCLUSIVE stream at the device's native rate and
 * pushes a tone through it, so the claim is end-to-end rather than advisory. */
static int play_tone(IMMDevice *dev, int rate, int chans)
{
    IAudioClient *client = NULL;
    IAudioRenderClient *render = NULL;
    WAVEFORMATEXTENSIBLE w;
    REFERENCE_TIME def_period = 0, min_period = 0;
    UINT32 frames = 0, padding, avail;
    BYTE *data;
    HRESULT hr;
    int i, c, phase = 0, half, written = 0;
    float sample;

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    if (FAILED(hr)) { outf("    Activate: 0x%08x %s\r\n", hr, hrname(hr)); return 1; }

    IAudioClient_GetDevicePeriod(client, &def_period, &min_period);
    outf("    device period   : default %d00 ns, min %d00 ns\r\n",
         (int)(def_period / 100), (int)(min_period / 100));

    make_fmt(&w, rate, chans, &DEPTHS[3]);          /* 32-bit float */

    /* Exclusive mode wants buffer duration == periodicity. */
    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_EXCLUSIVE, 0,
                                 def_period, def_period, (WAVEFORMATEX *)&w, NULL);
    outf("    Initialize excl : 0x%08x %s   (%d Hz, %d ch, 32f)\r\n",
         hr, hrname(hr), rate, chans);
    if (FAILED(hr)) { IAudioClient_Release(client); return 1; }

    hr = IAudioClient_GetBufferSize(client, &frames);
    outf("    buffer size     : %d frames\r\n", (int)frames);

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    if (FAILED(hr)) { outf("    GetService: 0x%08x %s\r\n", hr, hrname(hr)); return 1; }

    hr = IAudioClient_Start(client);
    outf("    Start           : 0x%08x %s\r\n", hr, hrname(hr));
    if (FAILED(hr)) return 1;

    /* ~1.5 s of a 440 Hz square wave. No CRT, so no sin() — a square wave needs
     * nothing but a counter, and audibility is the only thing being tested. */
    half = rate / 880;
    while (written < rate * 3 / 2)
    {
        IAudioClient_GetCurrentPadding(client, &padding);
        avail = frames - padding;
        if (!avail) { Sleep(5); continue; }
        if (FAILED(IAudioRenderClient_GetBuffer(render, avail, &data))) break;
        for (i = 0; i < (int)avail; i++)
        {
            sample = (phase < half) ? 0.15f : -0.15f;
            if (++phase >= half * 2) phase = 0;
            for (c = 0; c < chans; c++)
                ((float *)data)[i * chans + c] = sample;
        }
        IAudioRenderClient_ReleaseBuffer(render, avail, 0);
        written += avail;
    }
    Sleep(200);
    IAudioClient_Stop(client);
    outf("    wrote           : %d frames — you should have heard a 440 Hz tone\r\n", written);

    IAudioRenderClient_Release(render);
    IAudioClient_Release(client);
    return 0;
}

/* Exclusive mode + AUDCLNT_STREAMFLAGS_EVENTCALLBACK is the standard
 * low-latency pattern for professional audio on Windows, and is exactly what
 * rekordbox asks for: buffer duration == periodicity == 58050 (5.805 ms), float
 * samples, and one event per period. Wine's mmdevapi refuses the combination in
 * adjust_timing() with AUDCLNT_E_DEVICE_IN_USE, which is why the device is
 * unusable. `wasapitest event` reproduces that call on its own. */
static int play_event(IMMDevice *dev, int rate, int chans)
{
    IAudioClient *client = NULL;
    IAudioRenderClient *render = NULL;
    WAVEFORMATEXTENSIBLE w;
    /* The exact duration rekordbox asks for, so this is a reproducer and not an
     * approximation of one. */
    const REFERENCE_TIME period = 58050;
    HANDLE evt;
    UINT32 frames = 0;
    BYTE *data;
    HRESULT hr;
    int i, c, phase = 0, half, periods = 0, late = 0, refused = 0, spins = 0;

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    if (FAILED(hr)) { outf("    Activate: 0x%08x %s\r\n", hr, hrname(hr)); return 1; }

    make_fmt(&w, rate, chans, &DEPTHS[3]);          /* 32-bit float */

    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_EXCLUSIVE,
                                 AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                 period, period, (WAVEFORMATEX *)&w, NULL);
    outf("    Initialize excl+event : 0x%08x %s   (%d Hz, %d ch, 32f, period %d us)\r\n",
         hr, hrname(hr), rate, chans, (int)(period / 10));
    if (FAILED(hr))
    {
        out("    -> this is the call rekordbox makes. Stock Wine returns\r\n"
            "       AUDCLNT_E_DEVICE_IN_USE here from adjust_timing(), with no\r\n"
            "       device actually in use.\r\n");
        IAudioClient_Release(client);
        return 1;
    }

    evt = CreateEventW(NULL, FALSE, FALSE, NULL);
    hr = IAudioClient_SetEventHandle(client, evt);
    outf("    SetEventHandle        : 0x%08x %s\r\n", hr, hrname(hr));
    if (FAILED(hr)) return 1;

    IAudioClient_GetBufferSize(client, &frames);
    outf("    buffer size           : %d frames (one period, as it should be)\r\n", (int)frames);

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    if (FAILED(hr)) { outf("    GetService: 0x%08x %s\r\n", hr, hrname(hr)); return 1; }

    /* Pre-fill one period BEFORE Start. This is not optional in event-driven
     * mode: starting with an empty buffer underruns immediately, and the first
     * version of this test omitted it and blamed the backend for the result. */
    if (SUCCEEDED(IAudioRenderClient_GetBuffer(render, frames, &data)))
    {
        for (i = 0; i < (int)frames * chans; i++) ((float *)data)[i] = 0.0f;
        IAudioRenderClient_ReleaseBuffer(render, frames, 0);
        out("    pre-filled one period of silence\r\n");
    }

    hr = IAudioClient_Start(client);
    outf("    Start                 : 0x%08x %s\r\n", hr, hrname(hr));
    if (FAILED(hr)) return 1;

    /* ~2 s driven entirely by the event, which is the point: if the backend
     * never signals, this blocks and the count comes out low. */
    half = rate / 880;
    while (periods < (rate * 2) / (int)frames && spins++ < 4000)
    {
        if (WaitForSingleObject(evt, 1000) != WAIT_OBJECT_0) { late++; break; }
        /* Report WHY the loop stops. The first version just broke, and "the
         * event never arrived" was printed for what was actually a failing
         * GetBuffer — a wrong diagnosis produced by a lazy instrument. */
        /* A real client does NOT give up on one refusal — it waits for the next
         * event and tries again. The first version of this loop broke out on the
         * first failure and reported a working stream as broken. Retry, and
         * measure how often the buffer is actually free when the event fires,
         * which is the number that says whether playback can sustain. */
        hr = IAudioRenderClient_GetBuffer(render, frames, &data);
        if (FAILED(hr))
        {
            UINT32 pad = 0;
            IAudioClient_GetCurrentPadding(client, &pad);
            if (refused < 8)
                outf("    GetBuffer(%d) refused at period %d: %s (padding %d)\r\n",
                     (int)frames, periods, hrname(hr), (int)pad);
            refused++;
            continue;
        }
        for (i = 0; i < (int)frames; i++)
        {
            float sample = (phase < half) ? 0.15f : -0.15f;
            if (++phase >= half * 2) phase = 0;
            for (c = 0; c < chans; c++)
                ((float *)data)[i * chans + c] = sample;
        }
        IAudioRenderClient_ReleaseBuffer(render, frames, 0);
        periods++;
    }
    IAudioClient_Stop(client);
    outf("    periods serviced      : %d of %d wanted, %d refusals%s\r\n",
         periods, (rate * 2) / (int)frames, refused,
         late ? "  (TIMED OUT waiting for the event)" : "");
    out(periods > 10 ? "    VERDICT: event-driven exclusive stream works.\r\n"
        : late ? "    VERDICT: the event never arrived — the backend is not driving it.\r\n"
               : "    VERDICT: the event fires, but the buffer never comes free.\r\n");

    IAudioRenderClient_Release(render);
    IAudioClient_Release(client);
    return 0;
}

/* Substring match, no CRT. */
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

static void device_name(IMMDevice *dev, char *buf, int len)
{
    IPropertyStore *props = NULL;
    PROPVARIANT pv;

    buf[0] = 0;
    if (FAILED(IMMDevice_OpenPropertyStore(dev, STGM_READ, &props))) return;
    zero(&pv, sizeof(pv));
    if (SUCCEEDED(IPropertyStore_GetValue(props, &PKEY_FriendlyName, &pv)) && pv.pwszVal)
        WideCharToMultiByte(CP_ACP, 0, pv.pwszVal, -1, buf, len, NULL, NULL);
    IPropertyStore_Release(props);
}

void __cdecl entry(void)
{
    IMMDeviceEnumerator *devenum = NULL;
    IMMDeviceCollection *coll = NULL;
    IMMDevice *dev = NULL;
    UINT count = 0, i;
    HRESULT hr;
    const char *cmdline = GetCommandLineA();
    int mode_play = contains(cmdline, "play");
    int mode_event = contains(cmdline, "event");
    char name[256];

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) { outf("CoInitializeEx: 0x%08x\r\n", hr); ExitProcess(2); }

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IMMDeviceEnumerator, (void **)&devenum);
    if (FAILED(hr)) { outf("MMDeviceEnumerator: 0x%08x %s\r\n", hr, hrname(hr)); ExitProcess(2); }

    hr = IMMDeviceEnumerator_EnumAudioEndpoints(devenum, eRender, DEVICE_STATE_ACTIVE, &coll);
    if (FAILED(hr)) { outf("EnumAudioEndpoints: 0x%08x %s\r\n", hr, hrname(hr)); ExitProcess(2); }

    IMMDeviceCollection_GetCount(coll, &count);
    outf("render endpoints: %d\r\n", (int)count);

    for (i = 0; i < count; i++)
    {
        if (FAILED(IMMDeviceCollection_Item(coll, i, &dev))) continue;
        if (mode_play || mode_event)
        {
            device_name(dev, name, sizeof(name));
            if (contains(name, "DDJ"))
            {
                outf("\r\n[%d] %s\r\n", (int)i, name);
                /* DDJ-400 hardware is 44100-only, 4 ch (master + cue). */
                if (mode_event) play_event(dev, 44100, 4);
                else            play_tone(dev, 44100, 4);
            }
        }
        else
            probe_device(dev, i);
        IMMDevice_Release(dev);
    }

    IMMDeviceCollection_Release(coll);
    IMMDeviceEnumerator_Release(devenum);
    ExitProcess(0);
}
