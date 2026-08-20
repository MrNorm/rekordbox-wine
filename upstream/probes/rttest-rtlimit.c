/* Does a spinning SCHED_RR thread die against a finite RLIMIT_RTTIME? */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sched.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <unistd.h>

static volatile sig_atomic_t got;
static void h(int s){ got = s; }

int main(int argc, char **argv)
{
    struct rlimit rl;
    struct sched_param sp;
    struct timeval t0, t1;
    int spin = argc > 1 && !strcmp(argv[1], "spin");

    getrlimit(RLIMIT_RTTIME, &rl);
    printf("RLIMIT_RTTIME soft=%ld hard=%ld\n", (long)rl.rlim_cur, (long)rl.rlim_max);

    signal(SIGXCPU, h);
    sp.sched_priority = 5;
    if (sched_setscheduler(0, SCHED_RR, &sp) < 0) { perror("sched_setscheduler"); return 2; }
    printf("now SCHED_RR, mode=%s\n", spin ? "spin (never blocks)" : "block (sleeps often)");

    gettimeofday(&t0, NULL);
    for (;;) {
        if (spin) { volatile double x = 0; for (int i = 0; i < 20000000; i++) x += i; }
        else usleep(1000);
        gettimeofday(&t1, NULL);
        double el = (t1.tv_sec-t0.tv_sec) + (t1.tv_usec-t0.tv_usec)/1e6;
        if (got) { printf("  -> got signal %d after %.2fs\n", got, el); return 0; }
        if (el > 6.0) { printf("  -> survived %.1fs with no signal\n", el); return 0; }
    }
}
