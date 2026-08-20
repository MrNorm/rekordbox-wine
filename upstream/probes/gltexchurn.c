/* gltexchurn — does create/upload/delete of GL textures leak GPU memory here?
 *
 * WHY THIS EXISTS
 *
 * Measured in rekordbox under Wine (docs/investigation/THEMES/T08 §6): the GPU memory charged to the
 * process climbs ~1.4 MB/sec for as long as it renders, the frame rate falls in
 * lockstep (Pearson r = -0.963 over a 14-minute soak), and a restart recovers it
 * completely. But the GL calls BALANCE -- in an 80-second window, 5,807
 * glGenBuffers against 5,842 glDeleteBuffers, and 191 glGenTextures against 190
 * glDeleteTextures. Nothing is being created and left undeleted.
 *
 * What does accumulate is ~2.7 objects/sec averaging 349 KiB, and glTexImage2D is
 * called ~2.4 times/sec. So the suspicion is that a texture is created, uploaded,
 * deleted -- and its storage is not actually released.
 *
 * Three parties could be responsible: the application, Wine's GL translation, or
 * Mesa/i915. This program removes the first two. It is a plain native GLX client
 * doing nothing but that one pattern. If it leaks here, the effect is in the
 * driver stack and neither rekordbox nor Wine is at fault; if it does not leak
 * here, the finger points back at Wine's opengl32 and the same test should be
 * rebuilt as a Windows binary and run under Wine to complete the comparison.
 *
 * It reports the process's own GPU memory the same way the harness does, by
 * reading drm-total-system0 out of /proc/self/fdinfo -- the same counter, so the
 * numbers are directly comparable with runs/SOAK/*.tsv.
 *
 * Usage: gltexchurn [seconds] [textures_per_second] [texture_edge_px]
 *        defaults: 40 seconds, 3 per second, 300 px (~350 KiB at RGBA8)
 *
 * Build: cc -O2 -o gltexchurn gltexchurn.c -lGL -lX11 -lm
 */
#include <X11/Xlib.h>
#include <GL/glx.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Exactly what research/probes/uisoak.sh samples, so the two are comparable. */
static long gpu_kib_self(void)
{
    DIR *d = opendir("/proc/self/fdinfo");
    struct dirent *e;
    long best = 0;
    char path[256], line[256];

    if (!d) return -1;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof(path), "/proc/self/fdinfo/%s", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        while (fgets(line, sizeof(line), f)) {
            long v;
            if (sscanf(line, "drm-total-system0: %ld", &v) == 1) {
                if (v > best) best = v;
                break;
            }
        }
        fclose(f);
    }
    closedir(d);
    return best;
}

int main(int argc, char **argv)
{
    double secs  = argc > 1 ? atof(argv[1]) : 40.0;
    double rate  = argc > 2 ? atof(argv[2]) : 3.0;
    int    edge  = argc > 3 ? atoi(argv[3]) : 300;

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "cannot open display\n"); return 2; }

    int attribs[] = { GLX_RGBA, GLX_DOUBLEBUFFER, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8,
                      GLX_BLUE_SIZE, 8, GLX_DEPTH_SIZE, 16, None };
    XVisualInfo *vi = glXChooseVisual(dpy, DefaultScreen(dpy), attribs);
    if (!vi) { fprintf(stderr, "no suitable visual\n"); return 2; }

    XSetWindowAttributes swa;
    memset(&swa, 0, sizeof(swa));
    swa.colormap = XCreateColormap(dpy, RootWindow(dpy, vi->screen), vi->visual, AllocNone);
    Window win = XCreateWindow(dpy, RootWindow(dpy, vi->screen), 0, 0, 400, 300, 0,
                               vi->depth, InputOutput, vi->visual, CWColormap, &swa);
    XStoreName(dpy, win, "gltexchurn");
    XMapWindow(dpy, win);

    GLXContext ctx = glXCreateContext(dpy, vi, NULL, True);
    if (!ctx) { fprintf(stderr, "no GL context\n"); return 2; }
    glXMakeCurrent(dpy, win, ctx);

    printf("renderer : %s\n", (const char *)glGetString(GL_RENDERER));
    printf("pattern  : %.1f textures/sec of %dx%d RGBA (%.0f KiB each), %.0f s\n",
           rate, edge, edge, edge * (double)edge * 4 / 1024, secs);

    size_t px = (size_t)edge * edge * 4;
    unsigned char *pixels = malloc(px);
    for (size_t i = 0; i < px; i++) pixels[i] = (unsigned char)i;

    double t0 = now_s(), next_tex = t0, next_report = t0 + 5.0;
    long base = gpu_kib_self(), created = 0;
    printf("start    : gpu %ld KiB\n", base);

    while (now_s() - t0 < secs) {
        /* one frame */
        glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        /* the pattern under test: create, upload, use once, delete */
        if (now_s() >= next_tex) {
            GLuint tex = 0;
            glGenTextures(1, &tex);
            glBindTexture(GL_TEXTURE_2D, tex);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, edge, edge, 0, GL_RGBA,
                         GL_UNSIGNED_BYTE, pixels);
            /* touch it, so the driver cannot optimise the upload away entirely */
            glEnable(GL_TEXTURE_2D);
            glBegin(GL_TRIANGLES);
            glTexCoord2f(0, 0); glVertex2f(-1, -1);
            glTexCoord2f(1, 0); glVertex2f( 1, -1);
            glTexCoord2f(0, 1); glVertex2f(-1,  1);
            glEnd();
            glBindTexture(GL_TEXTURE_2D, 0);
            glDeleteTextures(1, &tex);
            created++;
            next_tex += 1.0 / rate;
        }

        glXSwapBuffers(dpy, win);

        if (now_s() >= next_report) {
            long g = gpu_kib_self();
            printf("t=%5.1fs  textures %-6ld gpu %7ld KiB  (%+ld KiB since start)\n",
                   now_s() - t0, created, g, g - base);
            next_report += 5.0;
        }
    }

    long end = gpu_kib_self();
    printf("\n%ld textures created and deleted in %.0f s\n", created, secs);
    printf("gpu memory %ld -> %ld KiB  (%+ld KiB, %+.2f KiB per texture)\n",
           base, end, end - base, created ? (double)(end - base) / created : 0.0);
    printf("\nVERDICT: %s\n", (end - base) > (created * (long)(px / 1024) / 4)
           ? "GROWS with the churn — the driver stack retains deleted texture storage"
           : "does NOT grow — this pattern is not what leaks here");

    free(pixels);
    glXMakeCurrent(dpy, None, NULL);
    glXDestroyContext(dpy, ctx);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
