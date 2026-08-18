// fpsuncap -- uncap Geometry Dash's frame loop on macOS.
//
// Two independent problems have to be solved to exceed the display's refresh
// rate. Neither is in GD's own code.
//
// 1. Pacing. GD's render loop is stock cocos2d-x CCDirectorCaller: a
//    CVDisplayLink callback that hops to the main thread. The loop rate is
//    therefore exactly the display link rate. GD queries no refresh-rate API
//    anywhere, so there is nothing to "spoof" -- instead we capture the
//    callback GD registers, never start CoreVideo's link, and drive that
//    callback ourselves from a high-resolution pacer.
//
// 2. Presentation. Every buffer swap parks the main thread in
//      -[NSOpenGLContext flushBuffer] -> CGLFlushDrawable -> glSwap_Exec
//      -> NSCGLSurfaceFlush -> -[NSCGLSurface synchronize]
//      -> NSWaitUntilHostTime
//    which is AppKit sleeping until the next vblank on the legacy
//    OpenGL-on-Metal path. Clearing kCGLCPSwapInterval does NOT stop it
//    (verified: reads back 0, wait continues). Since a display cannot show
//    more frames than its refresh rate anyway, we perform a real swap only at
//    the display's rate and return immediately on every other frame. GD's
//    update/render loop then runs free.
//
// Loaded at process start via an LC_LOAD_DYLIB spliced into libfmod.dylib, so
// dyld honours the __interpose section. Nothing here patches live code, so
// there is no race against a running system thread.

#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define FPSUNCAP_VERSION "1.0.0"

#define SUPPORT_DIR "/Library/Application Support/FPSUncap"
#define CONF_NAME   "config"
#define LOG_NAME    "fpsuncap.log"

// ------------------------------------------------------------------ paths ---

static const char *support_path(const char *leaf) {
    static char buf[1024];
    const char *home = getenv("HOME");
    if (!home || !*home) return NULL;
    snprintf(buf, sizeof buf, "%s%s/%s", home, SUPPORT_DIR, leaf);
    return buf;
}

// ---------------------------------------------------------------- config ---

enum { MODE_SOURCE = 0, MODE_RUNLOOP = 1, MODE_THREAD = 2 };

static double g_fps      = 240.0;
static double g_present  = 0.0;    // 0 = follow the display's refresh rate
static int    g_mode     = MODE_SOURCE;
static int    g_disabled = 0;
static int    g_verbose  = 0;

static void logf_(const char *fmt, ...) {
    const char *p = support_path(LOG_NAME);
    if (!p) return;
    FILE *f = fopen(p, "a");
    if (!f) return;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    char stamp[32];
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
    fprintf(f, "[%s.%03ld] ", stamp, ts.tv_nsec / 1000000);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void trim(char *s) {
    char *p = s + strlen(s);
    while (p > s && (p[-1] == '\n' || p[-1] == '\r' || p[-1] == ' ' || p[-1] == '\t')) *--p = 0;
}

static int parse_mode(const char *v) {
    if (!strcmp(v, "runloop")) return MODE_RUNLOOP;
    if (!strcmp(v, "thread"))  return MODE_THREAD;
    return MODE_SOURCE;
}

// Re-read on every display-link start, so the GUI can change settings without
// reinstalling or rebuilding anything.
static void load_config(void) {
    const char *p = support_path(CONF_NAME);
    FILE *f = p ? fopen(p, "r") : NULL;
    if (f) {
        char line[256];
        while (fgets(line, sizeof line, f)) {
            trim(line);
            if (!line[0] || line[0] == '#') continue;
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = 0;
            const char *k = line, *v = eq + 1;
            if      (!strcmp(k, "fps"))         g_fps     = atof(v);
            else if (!strcmp(k, "present_fps")) g_present = atof(v);
            else if (!strcmp(k, "mode"))        g_mode    = parse_mode(v);
            else if (!strcmp(k, "disable"))     g_disabled = atoi(v);
            else if (!strcmp(k, "verbose"))     g_verbose  = atoi(v);
        }
        fclose(f);
    }
    const char *e;
    if ((e = getenv("FPSUNCAP_FPS")))     g_fps      = atof(e);
    if ((e = getenv("FPSUNCAP_PRESENT"))) g_present  = atof(e);
    if ((e = getenv("FPSUNCAP_MODE")))    g_mode     = parse_mode(e);
    if ((e = getenv("FPSUNCAP_DISABLE"))) g_disabled = atoi(e);
    if ((e = getenv("FPSUNCAP_VERBOSE"))) g_verbose  = atoi(e);

    if (!(g_fps >= 1.0 && g_fps <= 2000.0)) g_fps = 240.0;
    if (!(g_present >= 0.0 && g_present <= 2000.0)) g_present = 0.0;
}

// ---------------------------------------------------------- pass-through ---
//
// dyld does not apply an image's own interpositions to calls originating from
// that image, so a plain call by name here reaches the real implementation.
// dlsym gets no such exemption: it returns the interposed replacement, which
// at -O2 becomes a tail call into ourselves -- an infinite loop with a flat
// stack that presents as a hang, not a crash. Never resolve originals with
// dlsym/RTLD_NEXT from inside an interposing image.

// ----------------------------------------------------------- driver state ---

static CVDisplayLinkOutputCallback g_cb;
static void              *g_ctx;
static CVDisplayLinkRef   g_link;
static atomic_int         g_running;
static CFRunLoopSourceRef g_source;
static CFRunLoopTimerRef  g_timer;
static CFRunLoopRef       g_mainrl;
static pthread_t          g_thread;
static atomic_ullong      g_frames;
static atomic_ullong      g_presents;
static atomic_ullong      g_next_present;
static atomic_int         g_swap_done;

static double g_host_per_sec;   // mach ticks per second

static void init_timebase(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    g_host_per_sec = 1e9 * (double)tb.denom / (double)tb.numer;
}

// The display's true refresh rate, straight from the link GD handed us. This
// is more reliable than CGDisplayModeGetRefreshRate, which reports 0 on many
// built-in panels.
static double detect_refresh(CVDisplayLinkRef link) {
    if (!link) return 0.0;
    CVTime t = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link);
    if (t.flags & kCVTimeIsIndefinite) return 0.0;
    if (t.timeValue <= 0) return 0.0;
    return (double)t.timeScale / (double)t.timeValue;
}

// cocos2d-x takes its delta from gettimeofday, not from these stamps, but they
// still must advance monotonically and look sane.
static void fill_stamps(CVTimeStamp *now, CVTimeStamp *out) {
    uint64_t host   = mach_absolute_time();
    int64_t  period = (int64_t)(1000000000.0 / g_fps);
    uint64_t hstep  = (uint64_t)(g_host_per_sec / g_fps);

    memset(now, 0, sizeof *now);
    now->version            = 0;
    now->flags              = kCVTimeStampHostTimeValid | kCVTimeStampVideoTimeValid
                            | kCVTimeStampVideoRefreshPeriodValid | kCVTimeStampRateScalarValid;
    now->videoTimeScale     = 1000000000;
    now->videoTime          = (int64_t)((double)host / g_host_per_sec * 1e9);
    now->hostTime           = host;
    now->rateScalar         = 1.0;
    now->videoRefreshPeriod = period;

    *out = *now;
    out->hostTime  = host + hstep;
    out->videoTime = now->videoTime + period;
}

static void do_frame(void) {
    if (!g_cb) return;
    CVTimeStamp now, out;
    fill_stamps(&now, &out);
    CVOptionFlags flags_out = 0;
    g_cb(g_link, &now, &out, 0, &flags_out, g_ctx);

    unsigned long long n = atomic_fetch_add(&g_frames, 1) + 1;
    if (g_verbose && n % 600 == 0)
        logf_("frames=%llu presents=%llu", n, atomic_load(&g_presents));
}

// --------------------------------------------------------- mode: source ---
// A paced worker thread signals a run loop source; the frame itself runs on
// the main thread. Signalling coalesces, so when the main thread falls behind
// we drop frames instead of queueing them. That backpressure is essential:
// bursting callbacks without it saturates the main run loop and the app stops
// servicing input.

static void source_perform(void *info) { (void)info; do_frame(); }

static void *pacer_thread(void *arg) {
    int post_to_main = (int)(intptr_t)arg;
    pthread_setname_np("fpsuncap.pacer");

    uint64_t step = (uint64_t)(g_host_per_sec / g_fps);
    uint64_t next = mach_absolute_time() + step;

    while (atomic_load(&g_running)) {
        mach_wait_until(next);
        if (!atomic_load(&g_running)) break;

        if (post_to_main) {
            CFRunLoopSourceSignal(g_source);
            CFRunLoopWakeUp(g_mainrl);
        } else {
            do_frame();
        }

        uint64_t nowt = mach_absolute_time();
        next += step;
        if (next < nowt) next = nowt + step;   // fell behind; resync, don't spiral
    }
    return NULL;
}

// -------------------------------------------------------- mode: runloop ---

static void timer_fired(CFRunLoopTimerRef t, void *info) { (void)t; (void)info; do_frame(); }

// ------------------------------------------------------------ driver ctrl ---

static void driver_start(void) {
    if (atomic_exchange(&g_running, 1)) return;
    g_mainrl = CFRunLoopGetMain();
    logf_("driver start: loop=%.1ffps present=%.1ffps mode=%d", g_fps, g_present, g_mode);

    if (g_mode == MODE_RUNLOOP) {
        CFRunLoopTimerContext tc = {0};
        g_timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                       CFAbsoluteTimeGetCurrent() + 1.0 / g_fps,
                                       1.0 / g_fps, 0, 0, timer_fired, &tc);
        CFRunLoopTimerSetTolerance(g_timer, 0.0);
        CFRunLoopAddTimer(g_mainrl, g_timer, kCFRunLoopCommonModes);
        CFRunLoopWakeUp(g_mainrl);
        return;
    }
    if (g_mode == MODE_SOURCE) {
        CFRunLoopSourceContext sc = {0};
        sc.perform = source_perform;
        g_source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sc);
        CFRunLoopAddSource(g_mainrl, g_source, kCFRunLoopCommonModes);
    }
    pthread_create(&g_thread, NULL, pacer_thread, (void *)(intptr_t)(g_mode == MODE_SOURCE));
}

static void driver_stop(void) {
    if (!atomic_exchange(&g_running, 0)) return;
    if (g_timer) { CFRunLoopTimerInvalidate(g_timer); CFRelease(g_timer); g_timer = NULL; }
    if (g_thread) { pthread_join(g_thread, NULL); g_thread = 0; }
    if (g_source) { CFRunLoopSourceInvalidate(g_source); CFRelease(g_source); g_source = NULL; }
    logf_("driver stop: frames=%llu presents=%llu",
          atomic_load(&g_frames), atomic_load(&g_presents));
}

// -------------------------------------------------------------- interpose ---

#define DYLD_INTERPOSE(_repl, _orig) \
    __attribute__((used)) static struct { const void *repl; const void *orig; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_orig };

static CVReturn my_CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link,
                                                  CVDisplayLinkOutputCallback cb,
                                                  void *ctx) {
    load_config();
    if (g_disabled) return CVDisplayLinkSetOutputCallback(link, cb, ctx);

    init_timebase();
    g_link = link;
    g_cb   = cb;
    g_ctx  = ctx;

    if (g_present <= 0.0) {
        double hz = detect_refresh(link);
        g_present = hz > 0.0 ? hz : 60.0;
        logf_("display refresh detected: %.2f Hz", g_present);
    }
    if (g_present > g_fps) g_present = g_fps;

    logf_("captured callback; loop=%.1ffps present=%.1ffps", g_fps, g_present);
    return kCVReturnSuccess;   // deliberately not registered with CoreVideo
}

static CVReturn my_CVDisplayLinkStart(CVDisplayLinkRef link) {
    if (g_disabled) return CVDisplayLinkStart(link);
    if (!g_cb) {
        // Never saw a callback -- don't leave GD without frames.
        logf_("no captured callback at Start; falling back to CoreVideo");
        return CVDisplayLinkStart(link);
    }
    driver_start();
    return kCVReturnSuccess;   // CoreVideo's own link is never started
}

static CVReturn my_CVDisplayLinkStop(CVDisplayLinkRef link) {
    if (g_disabled || !g_cb) return CVDisplayLinkStop(link);
    driver_stop();
    return kCVReturnSuccess;
}

static void my_CVDisplayLinkRelease(CVDisplayLinkRef link) {
    if (!g_disabled && g_cb) driver_stop();
    CVDisplayLinkRelease(link);
}

static CGLError my_CGLFlushDrawable(CGLContextObj ctx) {
    if (g_disabled || !g_cb) return CGLFlushDrawable(ctx);

    if (ctx && !atomic_exchange(&g_swap_done, 1)) {
        // Clearing this is not sufficient on its own -- AppKit paces the
        // surface regardless -- but it costs nothing and helps on setups where
        // the surface path differs.
        GLint zero = 0;
        CGLSetParameter(ctx, kCGLCPSwapInterval, &zero);
    }

    uint64_t now = mach_absolute_time();
    uint64_t due = atomic_load(&g_next_present);
    if (now < due) {
        glFlush();               // push commands; do not swap, do not wait
        return kCGLNoError;
    }
    uint64_t step = (uint64_t)(g_host_per_sec / g_present);
    uint64_t next = due + step;
    if (next < now) next = now + step;
    atomic_store(&g_next_present, next);
    atomic_fetch_add(&g_presents, 1);
    return CGLFlushDrawable(ctx);
}

DYLD_INTERPOSE(my_CVDisplayLinkSetOutputCallback, CVDisplayLinkSetOutputCallback)
DYLD_INTERPOSE(my_CVDisplayLinkStart,             CVDisplayLinkStart)
DYLD_INTERPOSE(my_CVDisplayLinkStop,              CVDisplayLinkStop)
DYLD_INTERPOSE(my_CVDisplayLinkRelease,           CVDisplayLinkRelease)
DYLD_INTERPOSE(my_CGLFlushDrawable,               CGLFlushDrawable)

__attribute__((constructor))
static void fpsuncap_init(void) {
    const char *p = support_path("");
    if (p) mkdir(p, 0755);
    load_config();
    if (g_verbose) logf_("fpsuncap " FPSUNCAP_VERSION " loaded (pid %d)", getpid());
}
