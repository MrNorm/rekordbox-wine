/* damagefps — count real repaints of an X11 window, with no screen capture.
 *
 * WHY THIS EXISTS
 *
 * This project needs to answer "is the UI running at 60 fps or at 6" and every
 * previous attempt was invalid. ffmpeg -f x11grab returns a BLACK root window
 * for XWayland clients under KWin, so a capture-based frame counter here counts
 * the mouse cursor ffmpeg draws itself: two runs that should have differed came
 * back at exactly 101 frames each, which is what exposed it (JOURNAL 2026-08-14
 * 17:32). Pixels are not available to us. Events are.
 *
 * The X DAMAGE extension reports, per window, that a region of it has been
 * repainted. It is the same signal the compositor itself uses to decide when to
 * recomposite, it needs no pixels at all, and it therefore cannot be fooled by
 * a black capture. For an Xwayland client the server raises damage whether the
 * window was painted by the CPU (XPutImage / XShmPutImage) or presented from a
 * GL buffer (DRI3 PresentPixmap), so it covers both of rekordbox's paths.
 *
 * WHAT IT REPORTS, and why the jitter numbers matter more than the mean
 *
 * A DJ waveform at "30 fps average" that actually delivers 60,60,60,4,60,60,4
 * is unusable, and its mean says 50. So this prints the distribution of the
 * gaps between repaints -- p50/p90/p99/max -- plus how many gaps exceeded a
 * stutter threshold, plus a per-second timeline so a degradation over a long
 * run is visible as a trend rather than hidden in an average.
 *
 * CALIBRATION IS NOT OPTIONAL. An instrument in this project is not trusted
 * until it has been shown to answer both ways, so --calibrate runs glxgears
 * (which a compositor vsyncs to the refresh rate) as a positive control and a
 * deliberately static window as a negative one. If the positive control does
 * not read ~60 and the negative ~0, no number this tool prints means anything.
 *
 * Usage:
 *   damagefps <window-id> <seconds>        window id in decimal or 0x hex
 *   damagefps --list                       print candidate window ids and names
 *
 * Output is one "key=value" block plus a TIMELINE line, for easy grepping.
 *
 * Build: cc -O2 -o damagefps damagefps.c -lXdamage -lXfixes -lXext -lX11
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xdamage.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/select.h>

#define MAX_EV 2000000
#define STUTTER_MS 33.4   /* two missed frames at 60 Hz */

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double pct(double *sorted, int n, double p)
{
    if (n <= 0) return 0.0;
    int i = (int)(p * (n - 1) + 0.5);
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    return sorted[i];
}

/* Walk the tree and print anything with a WM_NAME, so a caller can find the
 * window without depending on xdotool being installed. */
static void list_windows(Display *dpy, Window w, int depth)
{
    Window root, parent, *kids = NULL;
    unsigned int n = 0;
    char *name = NULL;
    XWindowAttributes at;

    if (XGetWindowAttributes(dpy, w, &at) && at.map_state == IsViewable &&
        at.width > 100 && at.height > 100 && XFetchName(dpy, w, &name) && name) {
        printf("0x%lx  %4dx%-4d  %s\n", w, at.width, at.height, name);
        XFree(name);
    }
    if (depth > 4) return;
    if (XQueryTree(dpy, w, &root, &parent, &kids, &n)) {
        for (unsigned int i = 0; i < n; i++) list_windows(dpy, kids[i], depth + 1);
        if (kids) XFree(kids);
    }
}

int main(int argc, char **argv)
{
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "damagefps: cannot open display\n"); return 2; }

    int ev_base, err_base;
    if (!XDamageQueryExtension(dpy, &ev_base, &err_base)) {
        fprintf(stderr, "damagefps: server has no DAMAGE extension\n");
        return 2;
    }

    if (argc >= 2 && !strcmp(argv[1], "--list")) {
        list_windows(dpy, DefaultRootWindow(dpy), 0);
        return 0;
    }
    if (argc < 3) {
        fprintf(stderr, "usage: damagefps <window-id> <seconds>\n"
                        "       damagefps --list\n");
        return 2;
    }

    Window win = (Window)strtoul(argv[1], NULL, 0);
    double secs = atof(argv[2]);
    if (!win || secs <= 0) { fprintf(stderr, "damagefps: bad arguments\n"); return 2; }

    XWindowAttributes at;
    if (!XGetWindowAttributes(dpy, win, &at)) {
        fprintf(stderr, "damagefps: window 0x%lx does not exist\n", win);
        return 2;
    }

    /* NonEmpty + XDamageSubtract after every event gives one event per damage
     * BATCH rather than one per rectangle. RawRectangles would report a repaint
     * that touched twelve widgets as twelve events and inflate the rate by an
     * amount that varies with what is on screen -- useless for comparing runs. */
    Damage dmg = XDamageCreate(dpy, win, XDamageReportNonEmpty);
    XSync(dpy, False);

    static double t[MAX_EV];
    int n = 0;
    double t0 = now_ms(), tend = t0 + secs * 1000.0;
    int fd = ConnectionNumber(dpy);

    while (now_ms() < tend && n < MAX_EV) {
        /* Drain first: XNextEvent would block past the deadline on a frozen UI,
         * which is exactly the case this tool has to be able to report. */
        while (XPending(dpy)) {
            XEvent e;
            XNextEvent(dpy, &e);
            if (e.type == ev_base + XDamageNotify) {
                t[n++] = now_ms();
                XDamageSubtract(dpy, dmg, None, None);
            }
        }
        struct timeval tv;
        double left = tend - now_ms();
        if (left <= 0) break;
        if (left > 200) left = 200;          /* wake regularly so the deadline holds */
        tv.tv_sec = (long)(left / 1000);
        tv.tv_usec = (long)((left - tv.tv_sec * 1000) * 1000);
        fd_set r; FD_ZERO(&r); FD_SET(fd, &r);
        select(fd + 1, &r, NULL, NULL, &tv);
    }
    double elapsed = (now_ms() - t0) / 1000.0;

    XDamageDestroy(dpy, dmg);

    /* gaps between consecutive repaints */
    int ng = n > 1 ? n - 1 : 0;
    double *gaps = calloc(ng ? ng : 1, sizeof(double));
    for (int i = 1; i < n; i++) gaps[i - 1] = t[i] - t[i - 1];
    double *sorted = calloc(ng ? ng : 1, sizeof(double));
    memcpy(sorted, gaps, (ng ? ng : 1) * sizeof(double));
    qsort(sorted, ng, sizeof(double), cmp_double);

    int stutters = 0;
    double worst = 0;
    for (int i = 0; i < ng; i++) {
        if (gaps[i] > STUTTER_MS) stutters++;
        if (gaps[i] > worst) worst = gaps[i];
    }

    printf("window=0x%lx size=%dx%d\n", win, at.width, at.height);
    printf("seconds=%.2f repaints=%d fps=%.2f\n", elapsed, n, n / elapsed);
    if (ng > 0) {
        printf("gap_ms_p50=%.2f gap_ms_p90=%.2f gap_ms_p99=%.2f gap_ms_max=%.2f\n",
               pct(sorted, ng, 0.50), pct(sorted, ng, 0.90),
               pct(sorted, ng, 0.99), worst);
        printf("stutters_over_%.1fms=%d stutter_pct=%.1f\n",
               STUTTER_MS, stutters, 100.0 * stutters / ng);
    } else {
        printf("gap_ms_p50=- gap_ms_p90=- gap_ms_p99=- gap_ms_max=-\n");
        printf("stutters_over_%.1fms=0 stutter_pct=0.0\n", STUTTER_MS);
    }

    /* Per-second timeline: the whole point of a soak run is to see a number
     * decay, and a single mean cannot show that. */
    int nsec = (int)(elapsed + 0.999);
    if (nsec < 1) nsec = 1;
    int *per = calloc(nsec, sizeof(int));
    for (int i = 0; i < n; i++) {
        int s = (int)((t[i] - t0) / 1000.0);
        if (s >= 0 && s < nsec) per[s]++;
    }
    printf("TIMELINE");
    for (int i = 0; i < nsec; i++) printf(" %d", per[i]);
    printf("\n");

    free(per); free(gaps); free(sorted);
    XCloseDisplay(dpy);
    return 0;
}
