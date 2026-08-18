# Uncapping Geometry Dash on macOS: what actually blocks it

A record of how this was solved, including the wrong answers — because three of
the four dead ends look like walls and aren't, and two published-looking
conclusions along the way were simply incorrect.

Target: Geometry Dash 2.2081, macOS 15+, Apple Silicon (verified under Rosetta
too). Display used for measurements: 75 Hz.

---

## What GD's renderer actually is

Everything relevant is stock cocos2d-x 2.x Mac code, not something RobTop
wrote. From the shipped binary:

```
$ nm -u "Geometry Dash" | grep -i cvdisplaylink
_CVDisplayLinkCreateWithActiveCGDisplays
_CVDisplayLinkRelease
_CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext
_CVDisplayLinkSetOutputCallback
_CVDisplayLinkStart

$ strings -a "Geometry Dash" | grep -E "doCaller|getFrameForTime|performSelector"
doCaller:
getFrameForTime:
performSelectorOnMainThread:withObject:waitUntilDone:
```

That is `CCDirectorCaller` verbatim: a `CVDisplayLink` callback that does not
draw, but calls `performSelectorOnMainThread:@selector(doCaller:)
waitUntilDone:YES`. The frame rate is therefore exactly the display link rate.

Two facts that shape everything else:

- **GD never queries a refresh rate.** No `CGDisplayModeGetRefreshRate`, no
  `CVDisplayLinkGetActualOutputVideoRefreshPeriod`, nothing. Any plan built on
  "make the game think the display is 240 Hz" is dead on arrival — there is no
  value to spoof.
- **GD never sets the OpenGL swap interval.** No `CGLSetParameter` import, and
  no `setValues:forParameter:` selector either (worth checking both — the
  ObjC path won't show up in `nm`). It sits at the default, which is `1`.

---

## Dead end 1: physics substepping

Hooked `GJBaseGameLayer::update(dt)` and called it repeatedly with smaller `dt`
slices. Worked, didn't crash, but cost real CPU (~22% vs ~9% baseline) because
`update()` is a large monolithic function — camera, audio sync, particles, not
just physics. Wrong layer entirely; abandoned.

## Dead end 2: DYLD interposing from inside a Geode mod

Hooked `CVDisplayLinkSetOutputCallback` via `__DATA,__interpose`, loaded as a
normal Geode mod through `$on_mod(Loaded)`.

**Failed silently — the replacement never fired.** dyld only honours interpose
sections for images present at launch. Geode loads mods with `dlopen()`, well
into GD's runtime, far too late.

## Dead end 3: inline hooking with TulipHook

Same target, hooked through Geode's `Mod::get()->hook(...)`. Installed and fired
correctly, then crashed with `SIGBUS` inside `CoreVideo::runIOThread()`.
Reproduced under both Rosetta and native arm64, and with a pure passthrough
detour containing no logic at all.

Root cause: installing the patch requires making the target code page writable
while CoreVideo's own IO thread is already live and may be executing on it. A
hot-patching race against a system framework's running thread. Not fixable by
changing what the detour does.

**This is what motivated load-time injection.** If the payload is present
before any thread exists, there is nothing to race.

---

## The two real problems

### Problem A — the interpose recursion that isn't about `RTLD_NEXT`

The obvious way to call the original from a replacement is
`dlsym(RTLD_NEXT, ...)`. That recursed infinitely. The natural diagnosis —
"`RTLD_NEXT` resolved back to me given where this dylib sits in the dependency
graph, so use `dlopen(path, RTLD_NOLOAD)` + `dlsym` on that handle instead" —
**is wrong, and the replacement has the identical bug.**

The actual rule:

> dyld does not apply an image's own interpositions to calls originating from
> that image. Inside the interposing dylib, the plain name reaches the real
> function. **`dlsym` gets no such exemption** and returns the interposed
> replacement — from any handle, `RTLD_NEXT` or otherwise.

So the pass-through calls itself. And because it's a tail call at `-O2`, the
stack never grows: it presents as a *hang*, not a stack overflow, which sends
you looking for a deadlock that doesn't exist. A `sample` of the process shows
one flat frame spinning:

```
main
 └ my_CVDisplayLinkSetOutputCallback     ← one frame, forever
    └ logf_ → fopen/fclose (looping)
```

**Fix:** delete the `dlfcn` code. Call `CVDisplayLinkStart(link)` by name.

### Problem B — the 75 Hz cap is in AppKit, and the swap interval doesn't control it

With the clock replaced (see below), frames were genuinely being driven at
240 Hz — and the game still ran at exactly 74.9 FPS. The frame counter told the
story: 600 frames per 8.01 s, with the pacer firing 240 times a second. Two of
every three were being dropped because the main thread couldn't finish a frame
faster than 13.3 ms.

`sample` on the main thread, 1377 of 1842 samples:

```
do_frame
 └ Geometry Dash +0x321790
    └ -[NSOpenGLContext flushBuffer]
       └ CGLFlushDrawable
          └ glSwap_Exec
             └ NSCGLSurfaceFlush
                └ -[NSCGLSurface synchronize]
                   └ NSWaitUntilHostTime
                      └ mach_msg2_trap
```

`NSWaitUntilHostTime` is AppKit sleeping until the next vblank. Not GD's code.
Not CVDisplayLink. Not a semaphore inside the game. It is the legacy
NSOpenGLContext-on-Metal compatibility path (`AppleMetalOpenGLRenderer`,
`glmtl`, `com.Metal.CompletionQueueDispatch` all appear in the sample) pacing
its surface to the display.

The documented remedy is `kCGLCPSwapInterval = 0`. **It does not work.**
Measured directly by interposing `CGLFlushDrawable` and setting it on the real
context:

```
swap interval on ctx 0x...: was 1 -> set 0 (err=0, reads back 0)
```

and the very next run: still 74.9 FPS, still parked in `NSWaitUntilHostTime`.
AppKit paces that surface no matter what the context says.

---

## The solution

### Replace the clock

`CVDisplayLink` is just a thing that calls your callback. Rather than
multiplying its ticks:

- interpose `CVDisplayLinkSetOutputCallback` → stash `(callback, context)`,
  return success, never register with CoreVideo;
- interpose `CVDisplayLinkStart` → return success, never start it;
- drive the stashed callback from a `mach_wait_until` pacer thread.

CoreVideo's thread never runs, so dead end 3 cannot recur.

**Frames must run on the main thread with backpressure.** GD's callback ends in
`performSelectorOnMainThread:waitUntilDone:YES`. An earlier attempt that kept
the real display link and simply called the callback twice per real tick
produced a grey, unresponsive window — two frames delivered in one vsync
window, flooding the main run loop with sources it couldn't drain while also
servicing input. The fix is a `CFRunLoopSource` signalled by the pacer:
signalling coalesces, so when the main thread falls behind, frames are dropped
rather than queued.

### Decouple present rate from loop rate

The vblank wait is unavoidable on a *real* buffer swap — but a display cannot
show more frames than its refresh rate anyway. So interpose `CGLFlushDrawable`
and perform a real swap only at the display's rate; on every other frame call
`glFlush()` (to push commands without presenting) and return `kCGLNoError`.

The display's true rate comes from the link GD already handed us, via
`CVDisplayLinkGetNominalOutputVideoRefreshPeriod` — more reliable than
`CGDisplayModeGetRefreshRate`, which returns 0 on many built-in panels.

### Get it loaded early

Splice an `LC_LOAD_DYLIB` into `libfmod.dylib`, which GD links at launch — the
same hook point Geode's own macOS installer uses (visible by diffing
`libfmod.dylib` against Geode's `restore_fmod.dylib` backup: one extra
`@rpath/Geode.dylib` entry). The command is written into existing Mach-O header
padding, so nothing in the file moves and the edit is byte-for-byte reversible.

---

## Results

| | before | after |
|---|---|---|
| game loop | 75 fps | **219.5 fps** (target 240) |
| buffer swaps | 75 fps | 72.5 fps |
| main thread in `NSWaitUntilHostTime` | 75% | only on real swaps |
| CPU | ~9% | ~23% |

The gap between 240 target and ~220 actual is real work, not pacing error: the
main thread is now running GD's full update and render 240 times a second.

---

## Method notes

**Use `sample`, not guesswork.** Every wrong conclusion here came from
reasoning about what *should* block instead of looking. `/usr/bin/sample <pid>`
needs no debugger, no entitlements, no code changes, and works on a hung
process:

```bash
/usr/bin/sample $(pgrep -x "Geometry Dash") 3 -f /tmp/gd.txt
```

Use the absolute path — Anaconda ships a `sample` that shadows it on `PATH`.

**Measure with a counter, not a feel.** A frame counter logged every 600 frames
distinguishes "the pacer isn't firing" from "the pacer fires and frames get
dropped downstream" — which are entirely different bugs with identical
symptoms.

**Test the injection outside the game.** `tests/harness.c` registers a display
link callback and counts invocations. It validates all three pacing modes and
the kill switch in about ten seconds, with no risk to a real install.
