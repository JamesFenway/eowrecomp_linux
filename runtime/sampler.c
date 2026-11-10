// CPU sampler. EOWRECOMP_SAMPLE=<from>:<to> samples where the CPU time goes between those presented frames: a
// SIGPROF timer (1 kHz of the process's CPU time, all threads) records the interrupted host pc and thread; at <to> the
// log gets "[sample]" lines - per thread, per library, and the hottest functions (game functions as f_<guest addr>
// with the NSO's symbol when it has one, runtime and driver functions by name). Unlike fnprof (call counts, needs game
// code built with FNPROF=1) this measures time, in any build: the Steam Deck spent ~17 ms of CPU per frame on the
// presenting thread (EOWRECOMP_LOG_PACE, 2026-11-10) and only a profile on the Deck itself says where.
#define _GNU_SOURCE  // (dladdr, REG_RIP)
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rt.h"

#if defined(_WIN32)
void sampler_frame(uint64_t frame) { (void)frame; }
#else
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

#define CAP (1u << 20)  // samples (~17 min of one core's time at 1 kHz)
// (the kernel checks CPU timers at its tick: fewer than 1000 a second where HZ is lower - shares stay right, and the
// times come from the CPU clocks below)
static uint64_t g_pc[CAP];
static uint32_t g_tid[CAP];
static _Atomic uint32_t g_n;
static uint32_t g_present_tid;

static uint32_t this_tid(void) {
#ifdef __linux__
    return (uint32_t)syscall(SYS_gettid);
#else
    return (uint32_t)pthread_mach_thread_np(pthread_self());
#endif
}

static void on_prof(int sig, siginfo_t *si, void *ucv) {
    (void)sig, (void)si;
    ucontext_t *uc = ucv;
    uint64_t pc;
#if defined(__APPLE__) && defined(__aarch64__)
    pc = uc->uc_mcontext->__ss.__pc;
#elif defined(__APPLE__)
    pc = uc->uc_mcontext->__ss.__rip;
#elif defined(__aarch64__)
    pc = uc->uc_mcontext.pc;
#else
    pc = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
#endif
    uint32_t i = atomic_fetch_add_explicit(&g_n, 1, memory_order_relaxed);
    if (i < CAP) { g_pc[i] = pc; g_tid[i] = this_tid(); }
}

static void timer_set(bool on) {
    struct itimerval it = {{0, on ? 1000 : 0}, {0, on ? 1000 : 0}};
    setitimer(ITIMER_PROF, &it, NULL);
}

const char *rt_host_fn_name(uint64_t pc, uint64_t *offset);  // runtime/dispatch.c
const char *plat_symbol(uint64_t pc, uint64_t *offset);

// A function (or, without symbols, a library) and its samples: total, and on the presenting thread
typedef struct { uint64_t key; uint32_t all, pres; char name[160]; } Row;
#define NROW (1u << 16)

static const char *lib_of(uint64_t pc, uint64_t *base) {
    Dl_info di = {0};
    if (!dladdr((void *)(uintptr_t)pc, &di) || !di.dli_fname) { *base = 0; return "?"; }
    *base = (uint64_t)(uintptr_t)di.dli_fbase;
    const char *s = strrchr(di.dli_fname, '/');
    return s ? s + 1 : di.dli_fname;
}

// what the pc is in: its function (start address as the key) and the library holding it
static void classify(uint64_t pc, uint64_t *key, char *name, size_t cap, uint64_t *lib_key, const char **lib) {
    uint64_t off = 0, base;
    *lib = lib_of(pc, &base);
    *lib_key = base;
    const char *g = rt_host_fn_name(pc, &off);
    if (g) {  // a game function: its guest address, and the NSO's own name for it when it has one
        *key = pc - off;
        uint64_t guest = strtoull(g + 2, NULL, 16), so = 0;
        const char *s = loader_symbol_at(guest, &so);
        if (s && so < 0x4000) snprintf(name, cap, "%s %.100s+%llx", g, s, (unsigned long long)so);
        else snprintf(name, cap, "%s", g);
        *lib = "game code";
        return;
    }
    const char *s = plat_symbol(pc, &off);
    if (s) { *key = pc - off; snprintf(name, cap, "%.120s (%s)", s, *lib); return; }
    *key = base ? base : pc;
    snprintf(name, cap, "(%s)", *lib);
}

static Row *row_of(Row *t, uint64_t key) {
    uint32_t h = (uint32_t)((key >> 4) * 0x9E3779B1u) & (NROW - 1);
    for (uint32_t n = 0; n < NROW; n++, h = (h + 1) & (NROW - 1))
        if (t[h].key == key || !t[h].key) return &t[h];
    return NULL;
}

static int by_all(const void *a, const void *b) { return (int)((const Row *)b)->all - (int)((const Row *)a)->all; }
static int by_pres(const void *a, const void *b) { return (int)((const Row *)b)->pres - (int)((const Row *)a)->pres; }

static void report(long from, long to, double secs, double pres_cpu_ms, double proc_cpu_ms) {
    uint32_t n = atomic_load(&g_n);
    if (n > CAP) n = CAP;
    Row *fn = calloc(NROW, sizeof *fn), *lib = calloc(256, sizeof *lib);
    struct { uint32_t tid, count; } th[64] = {{0}};
    uint32_t pres = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t key, lkey;
        const char *lname;
        char name[160];
        classify(g_pc[i], &key, name, sizeof name, &lkey, &lname);
        bool p = g_tid[i] == g_present_tid;
        pres += p;
        Row *r = row_of(fn, key ? key : 1);
        if (r) {
            if (!r->key) { r->key = key ? key : 1; snprintf(r->name, sizeof r->name, "%s", name); }
            r->all++, r->pres += p;
        }
        if (!strcmp(lname, "game code")) lkey = 1;  // (the game library as one, whatever dladdr says)
        for (int k = 0; k < 256; k++)
            if (lib[k].key == lkey || !lib[k].key) {
                if (!lib[k].key) { lib[k].key = lkey ? lkey : 2; snprintf(lib[k].name, sizeof lib[k].name, "%s", lname); }
                lib[k].all++, lib[k].pres += p;
                break;
            }
        for (int k = 0; k < 64; k++)
            if (th[k].tid == g_tid[i] || !th[k].tid) { th[k].tid = g_tid[i]; th[k].count++; break; }
    }
    LOG("[sample] frames %ld-%ld in %.1f s: %u samples; CPU time %.2f cores, the presenting thread %.1f ms a frame%s\n",
        from, to, secs, n, secs > 0 ? proc_cpu_ms / 1e3 / secs : 0, to > from ? pres_cpu_ms / (to - from) : 0,
        n == CAP ? " - buffer full" : "");
    LOG("[sample] threads (presenting thread %u: %u samples):\n", g_present_tid, pres);
    for (int k = 0; k < 64 && th[k].tid; k++)
        if (th[k].count * 200 >= n)
            LOG("[sample]   thread %u%s: %u (%.1f%%)\n", th[k].tid, th[k].tid == g_present_tid ? " (presenting)" : "",
                th[k].count, 100.0 * th[k].count / n);
    qsort(lib, 256, sizeof *lib, by_all);
    LOG("[sample] by library (all threads / presenting thread):\n");
    for (int k = 0; k < 256 && lib[k].all && k < 16; k++)
        LOG("[sample]   %5.1f%% %5.1f%%  %s\n", 100.0 * lib[k].all / n, pres ? 100.0 * lib[k].pres / pres : 0, lib[k].name);
    qsort(fn, NROW, sizeof *fn, by_pres);
    LOG("[sample] hottest on the presenting thread (%% of its samples):\n");
    for (uint32_t k = 0; k < 40 && fn[k].pres; k++)
        LOG("[sample]   %5.1f%%  %s\n", 100.0 * fn[k].pres / pres, fn[k].name);
    qsort(fn, NROW, sizeof *fn, by_all);
    LOG("[sample] hottest on all threads (%% of all samples):\n");
    for (uint32_t k = 0; k < 30 && fn[k].all; k++)
        LOG("[sample]   %5.1f%%  %s\n", 100.0 * fn[k].all / n, fn[k].name);
    free(fn);
    free(lib);
}

static double cpu_ms(clockid_t c) {
    struct timespec ts;
    return clock_gettime(c, &ts) ? 0 : ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

void sampler_frame(uint64_t frame) {
    static long from = -2, to;
    static uint64_t t0;
    static double pres0, proc0;
    if (from == -2) {
        from = -1;
        const char *e = getenv("EOWRECOMP_SAMPLE");
        if (e && sscanf(e, "%ld:%ld", &from, &to) != 2) from = -1;
        if (from >= 0 && to <= from) from = -1;
    }
    if (from < 0) return;
    if ((long)frame == from) {
        g_present_tid = this_tid();
        struct sigaction sa = {0};
        sa.sa_sigaction = on_prof;
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPROF, &sa, NULL);
        t0 = plat_now_ns();
        pres0 = cpu_ms(CLOCK_THREAD_CPUTIME_ID), proc0 = cpu_ms(CLOCK_PROCESS_CPUTIME_ID);
        timer_set(true);
        LOG("[sample] on at frame %llu\n", (unsigned long long)frame);
    }
    if ((long)frame != to) return;
    timer_set(false);
    signal(SIGPROF, SIG_IGN);
    report(from, to, (plat_now_ns() - t0) / 1e9, cpu_ms(CLOCK_THREAD_CPUTIME_ID) - pres0,
           cpu_ms(CLOCK_PROCESS_CPUTIME_ID) - proc0);
    from = -1;
}
#endif
