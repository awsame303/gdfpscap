// Stands in for GD's CCDirectorCaller: register a callback, start the link,
// count callbacks for N seconds. Reproduces the shape we care about
// (callback -> performSelectorOnMainThread equivalent) without needing GL.
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

static atomic_ullong frames;
static atomic_ullong main_frames;

static void on_main(void *info) { (void)info; atomic_fetch_add(&main_frames, 1); }

static CVReturn cb(CVDisplayLinkRef l, const CVTimeStamp *now, const CVTimeStamp *out,
                   CVOptionFlags in, CVOptionFlags *fo, void *ctx) {
    (void)l; (void)now; (void)out; (void)in; (void)fo; (void)ctx;
    atomic_fetch_add(&frames, 1);
    // mimic cocos2d's hop to the main thread
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ on_main(NULL); });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    return kCVReturnSuccess;
}

static void stop(CFRunLoopTimerRef t, void *i) { (void)t; (void)i; CFRunLoopStop(CFRunLoopGetMain()); }

int main(int argc, char **argv) {
    double secs = argc > 1 ? atof(argv[1]) : 3.0;
    CVDisplayLinkRef link = NULL;
    if (CVDisplayLinkCreateWithActiveCGDisplays(&link) != kCVReturnSuccess) { puts("create failed"); return 1; }
    if (CVDisplayLinkSetOutputCallback(link, cb, NULL) != kCVReturnSuccess) { puts("setcb failed"); return 1; }
    if (CVDisplayLinkStart(link) != kCVReturnSuccess) { puts("start failed"); return 1; }

    CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + secs, 0, 0, 0, stop, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    CFRunLoopRun();

    unsigned long long f = atomic_load(&frames), m = atomic_load(&main_frames);
    printf("callbacks=%llu (%.1f/s)   main-thread frames=%llu (%.1f/s)\n", f, f/secs, m, m/secs);
    return 0;
}
