# FPS Uncap for Geometry Dash (macOS)

Run Geometry Dash's game loop faster than your display's refresh rate on macOS.

On Windows, uncapping is routine. On macOS it has been an open problem: GD's
frame pacing comes from stock cocos2d-x code driven by Apple's `CVDisplayLink`,
which fires in lockstep with hardware vsync by design, and the usual escape
hatch — turning off the OpenGL swap interval — **does not work**, because the
actual wait lives in AppKit, not in the swap interval.

This tool solves both halves. On a 75 Hz display it runs the loop at 240 FPS.

```
loop     240 fps      ← how often the game updates
present   75 fps      ← your display's real refresh rate
```

---

## Install

### The easy way

1. Download `FPS Uncap.pkg` from [Releases](../../releases).
2. **Right-click it → Open** (not double-click — see [Gatekeeper](#gatekeeper) below).
3. Follow the prompts. It finds Geometry Dash, installs the payload, and sets
   the loop to 240 FPS.

That's it. Launch Geometry Dash normally afterwards.

To change the FPS later: `fpsuncap set 300`.

> **Why a `.pkg` and not an app?** Since macOS Ventura, modifying a file that is
> sealed into another application's code signature requires **App Management**
> permission. A double-clicked, unsigned app is never offered that consent
> prompt — the write just fails with `Operation not permitted`. A package's
> `postinstall` runs as root under `installd`, which is not subject to that
> restriction. This is the same approach Geode's macOS installer uses, and the
> reason it works where an app does not.

`FPS Uncap.app` is still built by `make app` and works fine for changing
settings, but it can only install if you grant it App Management in
**System Settings → Privacy & Security**.

### From source

```bash
git clone https://github.com/awsame303/fpsuncap-gd
cd fpsuncap-gd
make            # builds a universal (arm64 + x86_64) dylib
make test       # 9 checks, none of which touch your game
make install    # installs into Geometry Dash
make pkg        # build the installer package (the recommended front end)
make app        # optionally build the settings app
```

Requires the Xcode command line tools (`xcode-select --install`). Nothing else
— no Python, no LIEF, no package manager.

---

## What it does and doesn't do

**Does:** raise how often Geometry Dash updates and renders its world.

**Doesn't:** make your monitor show more frames than it physically can. A 75 Hz
panel shows 75 frames per second no matter what. The gain here is finer
simulation and input granularity, not visual smoothness.

> **This changes physics timing.** Geometry Dash steps its physics from the
> loop rate, so running at 240 changes the delta time per step. This is the
> same situation as any 240 FPS setup and is normally paired with
> `customFPSTarget=240` and Click Between Frames — but it is *not* a
> render-only change, and you should decide for yourself whether that is
> acceptable for leaderboard submissions. It is not a cheat and does not touch
> the game's logic, but it is not a no-op on replays either.

---

## Configuration

Settings live in `~/Library/Application Support/FPSUncap/config` and are
re-read every time Geometry Dash starts. No reinstall needed after a change.

| Key | Default | Meaning |
|---|---|---|
| `fps` | `240` | Game loop rate. The number you want to raise. |
| `present_fps` | `0` | Real buffer swaps per second. `0` follows your display's refresh rate, which is almost always correct. |
| `mode` | `source` | Pacing strategy: `source`, `runloop`, or `thread`. See below. |
| `disable` | `0` | `1` restores stock behaviour without uninstalling. |
| `verbose` | `0` | `1` logs frame counters to `fpsuncap.log`. |

### Pacing modes

- **`source`** (default) — a high-resolution pacer thread signals a run loop
  source; frames run on the main thread. Signal coalescing means that when the
  machine can't keep up, frames are *dropped* rather than queued. Use this.
- **`runloop`** — a `CFRunLoopTimer` on the main thread. Simpler, slightly more
  jitter.
- **`thread`** — the pacer calls the render callback directly, exactly as
  CoreVideo would. Useful for debugging.

---

## Command line

The app is a front end for a CLI you can also use directly:

```
fpsuncap install          install into Geometry Dash
fpsuncap uninstall        restore Geometry Dash to stock
fpsuncap set 240          set the loop rate
fpsuncap status           show what's installed and configured
fpsuncap on | off         enable/disable without uninstalling
fpsuncap log              recent log output
fpsuncap doctor           diagnostics for bug reports
```

Pass `--app "/path/to/Geometry Dash.app"` if auto-detection can't find your
install.

### Where it looks

In order, stopping at the first directory that is a real install (an executable
*and* a `libfmod.dylib`, so a stale backup or a lookalike folder is skipped):

1. Every Steam library — the default one, plus every `path` listed in
   `steamapps/libraryfolders.vdf`, which is how Steam records libraries kept on
   other volumes or external drives.
2. `/Applications` and `~/Applications`.
3. `~/Desktop`, `~/Downloads`, `~/Documents`, `~/Games`.
4. Spotlight (`mdfind`), ignoring anything under a backup folder or the Trash.

If none of that finds it, the installer asks you to pick it yourself.

---

## How it works

Two independent problems, both outside GD's own code. Full write-up with the
dead ends in [`docs/INVESTIGATION.md`](docs/INVESTIGATION.md).

### 1. Pacing — replace the clock, don't spoof a rate

GD's loop is stock cocos2d-x `CCDirectorCaller`: a `CVDisplayLink` callback
that hops to the main thread via `performSelectorOnMainThread:`. The loop rate
*is* the display link rate.

A natural first idea is to make the game think the display is faster. That
cannot work — GD never queries a refresh rate. There is no
`CGDisplayModeGetRefreshRate`, no `CVDisplayLinkGetActualOutputVideoRefreshPeriod`,
nothing to lie to.

But `CVDisplayLink` is just *a thing that calls your callback*. So:

- interpose `CVDisplayLinkSetOutputCallback` → stash the callback, don't
  register it,
- interpose `CVDisplayLinkStart` → don't start CoreVideo's link at all,
- drive the stashed callback from our own `mach_wait_until` pacer.

CoreVideo's thread never runs, which also removes any possibility of racing it.

### 2. Presentation — the wait is in AppKit, and it is not the swap interval

Even with frames driven at 240 Hz, the loop still ran at exactly 75. Sampling
the main thread showed where every frame went:

```
-[NSOpenGLContext flushBuffer]
  └ CGLFlushDrawable
     └ glSwap_Exec
        └ NSCGLSurfaceFlush
           └ -[NSCGLSurface synchronize]
              └ NSWaitUntilHostTime     ← 75% of all main-thread time
```

That is **AppKit** sleeping until the next vblank, on the legacy
OpenGL-on-Metal path (`AppleMetalOpenGLRenderer`). It is not GD's code and not
a semaphore inside the game.

Setting `kCGLCPSwapInterval` to `0` — the documented way to disable vsync —
**does not stop it**. Verified: the parameter read back `0` and the wait
continued unchanged at 74.9 FPS. AppKit paces that surface regardless.

The fix is to stop paying that cost on every frame. Your display can't show
more than its refresh rate anyway, so `CGLFlushDrawable` is interposed to
perform a real swap only at the display's rate, and to `glFlush()` and return
immediately otherwise. The game loop then runs free.

### Loading

dyld only honours a `__DATA,__interpose` section for images present at launch.
Geode loads mods with `dlopen()` far too late for that, so the payload is
loaded by splicing an `LC_LOAD_DYLIB` into `libfmod.dylib` — the same hook
point Geode's own macOS installer uses. The splicer (`tools/machsplice.c`)
writes into existing Mach-O header padding, so nothing in the file moves,
edits are exactly reversible, and there is no Python or LIEF dependency.

---

## Troubleshooting

**Nothing changed.** Confirm with `fpsuncap status`. A Geometry Dash update or
a Geode reinstall replaces `libfmod.dylib` and silently removes the splice —
just run the installer again.

**The game feels slower than the FPS I set.** Your machine may not sustain it.
Set `verbose=1` and check `fpsuncap log`: `frames=` is what you actually got.
Lower `fps` until it keeps up. Geometry Dash also throttles itself when it
isn't the frontmost app, so measure while actually playing.

**It crashed / hung.** Set `disable=1` in the config, or run `fpsuncap off`, to
get back to stock behaviour instantly without uninstalling. Then please open an
issue with the output of `fpsuncap doctor`.

**Nothing happens after I click Install.** macOS is blocking the installer from
reaching Geometry Dash. This happens when GD lives in a protected folder —
`~/Documents`, `~/Desktop`, `~/Downloads`, or an external drive — and shows up
as `Operation not permitted` rather than a normal permission error. Open
**System Settings → Privacy & Security → Files and Folders**, enable **FPS
Uncap**, and try again. If **App Management** lists FPS Uncap, enable it there
too. Running `fpsuncap install` from a terminal also works, because your
terminal usually already holds that permission — which is exactly why this
failure only shows up in the app.

<a name="gatekeeper"></a>
**"FPS Uncap.app is damaged" or "cannot be opened".** The app is unsigned
(signing requires a paid Apple Developer account). Right-click → Open the first
time, or:

```bash
xattr -dr com.apple.quarantine "FPS Uncap.app"
```

**Geometry Dash won't launch after installing.** Run `fpsuncap uninstall`. The
original `libfmod.dylib` is backed up next to it as
`libfmod.dylib.fpsuncap-original` and is restored byte-for-byte.

---

## Compatibility

- macOS 11+, Apple Silicon and Intel (universal binary; works under Rosetta).
- Geometry Dash 2.2 (2.2081 tested).
- Coexists with Geode and Click Between Frames.
- Only affects the OpenGL rendering path macOS GD uses.

---

## Uninstall

Open the app and choose **Uninstall completely**, or:

```bash
fpsuncap uninstall
```

This restores `libfmod.dylib` byte-for-byte and removes the payload.

---

## Credits

Built by [awsame303](https://github.com/awsame303).

The technique is described in full in [`docs/INVESTIGATION.md`](docs/INVESTIGATION.md),
including the dead ends — the two blockers that had previously made this look
impossible on macOS both turned out to be misdiagnoses.

## License

MIT © 2026 awsame303 — see [LICENSE](LICENSE).
