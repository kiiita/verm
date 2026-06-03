# Embedding libghostty to replace SwiftTerm in VoiceTerm

Research date: 2026-06-03. Target: `/Users/kiiita/Dev/voice-terminal/poc`
(SwiftPM macOS app, AppKit + SwiftUI, Swift 6.2, ad-hoc signed `.app`).

This document describes how to replace `SwiftTerm.LocalProcessTerminalView` with a
GPU-rendered terminal surface backed by **libghostty** (the embeddable library form
of Ghostty), and gives a feasibility verdict, build steps, the exact C API call
sequence, the Swift interop plan, the `send(txt:)`/delegate replacements, caveats,
and a concrete migration plan.

---

## 0. TL;DR / Feasibility verdict

**Feasible, but it is a real integration project, not a drop-in swap. Recommendation:
keep SwiftTerm as the default and put libghostty behind a feature flag / protocol.**

Key facts established by this research:

- libghostty's **terminal core is production-proven** (it is the engine inside the
  shipping Ghostty app and inside `/Applications/cmux.app`, which statically links it).
- The **full embedding C API exists today** (`include/ghostty.h`, ~1200 lines) and is
  exactly what Ghostty's own macOS Swift app uses. It covers everything we need:
  app/surface lifecycle, binding a surface to an `NSView`, spawning the PTY/process,
  feeding text (`ghostty_surface_text` = our `send(txt:)`), resize, focus, and
  title/exit callbacks.
- **BUT the public/stable, separately-versioned release is `libghostty-vt` — that is
  parsing/VT-state only, NOT rendering or surface embedding.** The full app+surface
  rendering API (what we need) is still **explicitly marked unstable** ("The only
  consumer of this API is the macOS app... This isn't meant to be a general purpose
  embedding API (yet)" — verbatim from the header). Function *signatures will change*
  between Ghostty releases even though behavior is stable.
- **No Zig toolchain is installed** on this machine (`which zig` → not found). Building
  the xcframework from source requires Zig 0.15.x. The lower-risk path is to consume a
  **prebuilt `GhosttyKit.xcframework`** via a Swift Package (`libghostty-spm`) and pin
  the exact version.
- Several real apps already do this: Ghostty's own macOS app, **cmux** (which we
  inspected), Kytos, Termini, fantastty, vvterm. So the path is well-trodden — it is
  just unstable-API trodden.

**Risk summary**

| Concern | Assessment |
|---|---|
| Terminal correctness/perf | Low risk. Best-in-class, GPU/Metal, 120 fps ProMotion, proven. |
| C API stability | **Medium-high.** Unstable, will break on upgrade. Must pin a version. |
| Build complexity | Medium. Zig from source, or pin a prebuilt xcframework. |
| Resource bundling | Medium. Must ship terminfo + shell-integration in the `.app` (cmux does). |
| Our specific UI (tabs/splits/voice inject) | Low-medium. We bypass Ghostty's own tab/split chrome and drive raw surfaces. `ghostty_surface_text` cleanly replaces `send(txt:)`. |
| Effort | Roughly 1–2 weeks for a working single-pane PoC; more to reach SwiftTerm parity in our split/tab tree. |

**Verdict: prototype behind a protocol abstraction; do NOT delete SwiftTerm.**

---

## 1. What we currently use from SwiftTerm (the contract to reproduce)

From `poc/Sources/VoiceTermPoC/App.swift`, the surface area we must replace is small
and well-defined. `LocalProcessTerminalView` gives us:

| SwiftTerm usage (in `Pane`) | What it does | libghostty equivalent |
|---|---|---|
| `LocalProcessTerminalView(frame:)` | Create the terminal NSView | Subclass a layer-backed `NSView`, create a `ghostty_surface_t` bound to it |
| `term.startProcess(executable:"/bin/zsh", args:["-l"], environment:env, currentDirectory:cwd)` | Spawn zsh in a PTY | Set `command`, `env_vars`, `working_directory` on `ghostty_surface_config_s`; libghostty spawns + owns the PTY |
| `term.send(txt: t)` (voice injection) and `term.send(txt:"\r")` | Inject text/Enter into the PTY | `ghostty_surface_text(surface, ptr, len)` |
| `processDelegate` → `setTerminalTitle(source:title:)` | Title updates | `action_cb` → `GHOSTTY_ACTION_SET_TITLE` |
| `processDelegate` → `processTerminated(source:exitCode:)` | Process exit → close pane | `action_cb` → `GHOSTTY_ACTION_SHOW_CHILD_EXITED` (or poll `ghostty_surface_process_exited`) |
| `sizeChanged`, `hostCurrentDirectoryUpdate` | (currently no-ops / unused) | resize is automatic from view layout; pwd via `GHOSTTY_ACTION_PWD` |
| `NSClickGestureRecognizer` for focus tracking | Know which pane is focused | `NSWindow.makeFirstResponder` + `ghostty_surface_set_focus`; our existing click recognizer still works |
| Embedded in SwiftUI via `NSViewRepresentable` | Host in our layout tree | Same — host the new `NSView` subclass in an `NSViewRepresentable` |

Everything else in `App.swift` (the layout tree, tabs, the voice record/STT/TTS loop,
the event-file polling) is **independent of the terminal backend** and does not change,
*except* the two `term.send(txt:)` call sites in `VoiceController.stop` and
`VoiceLoop.submit`.

> The critical insight for our app: the voice path needs **exactly two things** from the
> terminal — `send(txt:)` and a focus notion. Both map cleanly. The bulk of the work is
> the rendering/input plumbing, not the voice integration.

---

## 2. Architecture of libghostty (and why there are "two" libghosttys)

There is a naming trap that matters a lot for risk assessment:

1. **`libghostty-vt`** — the zero-dependency VT parser + terminal state library. This is
   the one that is being *formally released and versioned independently* (a tagged
   stable release was targeted for ~early 2026). **It does NOT render and does NOT
   embed a surface.** It is for people building their *own* renderer (Node/.NET/Go/Python
   bindings all wrap this). **It is NOT what we want.**

2. **Full libghostty / `GhosttyKit`** — the complete engine: VT + input encoding +
   **GPU (Metal) rendering** + PTY/process management + an "apprt" (application runtime)
   layer. This is exposed via `include/ghostty.h` and packaged for macOS as
   `GhosttyKit.xcframework`. **This is what we want, and it is the part still marked
   "not a general-purpose API yet."**

The header says it plainly (verbatim, top of `include/ghostty.h`):

> "The only consumer of this API is the macOS app, but the API is built to be more
> general purpose." … "This isn't meant to be a general purpose embedding API (yet) so
> there hasn't been documentation or example work beyond [the Zig source]."

So: the **engine** is stable; the **C function signatures** for full embedding are not
versioned and can change. Pin your version and expect to do small fix-ups on upgrade.

---

## 3. How libghostty is built (Zig)

libghostty is written in Zig and exposes a C ABI. There is no `libc` dependency in the
core. To produce the macOS framework you run Zig's build inside a Ghostty checkout:

```bash
# Requires Zig 0.15.x (NOT installed on this machine — `which zig` → not found)
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
# Produces macos/GhosttyKit.xcframework (universal arm64 + x86_64 by default).
# Controls: -Dxcframework-target=native  (arm64-only, faster local builds)
```

The xcframework contains the Zig-compiled core plus the C header (`ghostty.h`) and a
`module.modulemap` that defines the `GhosttyKit` Clang module:

```
// include/module.modulemap (verbatim)
module GhosttyKit {
    umbrella header "ghostty.h"
    export *
}
```

`import GhosttyKit` in Swift then exposes every `ghostty_*` symbol.

**Two ways to get the framework:**

- **(A — recommended) Prebuilt via SwiftPM.** Use `libghostty-spm` (a.k.a. the
  community "libghostty-spm" / GhosttyKit Swift package) which ships a prebuilt,
  versioned `GhosttyKit.xcframework` as a `.binaryTarget`. Add it to `Package.swift`,
  pin an exact tag, and you skip needing Zig entirely. **This is the lowest-risk path
  given Zig isn't installed and the API is unstable** — pinning a known-good binary is
  exactly the mitigation you want.
- **(B) Build from source.** Install Zig 0.15.x, run the `zig build` above, vendor the
  resulting `GhosttyKit.xcframework` into the repo, reference it from a local
  `.binaryTarget(path:)`. More control, reproducible, but you own the Zig toolchain.

For our SwiftPM app, add a binary target to `Package.swift`:

```swift
// Option A: remote prebuilt package
dependencies: [
    .package(url: "https://github.com/<libghostty-spm-repo>", exact: "<pinned-tag>"),
],
// ... target depends on the package's "GhosttyKit" product

// Option B: vendored local xcframework
targets: [
    .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
    .executableTarget(
        name: "VoiceTermPoC",
        dependencies: ["GhosttyKit"],
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
            .linkedFramework("QuartzCore"),
            .linkedFramework("CoreText"),
            .linkedFramework("Carbon"),   // HID / key event translation
        ]
    ),
]
```

These framework links were confirmed against the linked dylibs of
`/Applications/cmux.app/Contents/MacOS/cmux` (it links `Metal`, `QuartzCore`,
`Carbon`, `CoreText`). Note: if linking a *static* libghostty (not the dylib),
define `GHOSTTY_STATIC` before including the header so `GHOSTTY_API` becomes a no-op.

---

## 4. Resource bundling (terminfo + shell-integration + themes)

libghostty needs a resources directory on disk at runtime for `xterm-ghostty` terminfo
and shell integration. This is mandatory — without it, `TERM=xterm-ghostty` breaks
tools and shell integration (pwd/title reporting) won't work.

**How discovery works (no env var needed):** Ghostty walks up from the executable path
looking for the sentinel file `terminfo/78/xterm-ghostty`; when found it sets
`resources_dir` automatically. (Env override `GHOSTTY_RESOURCES_DIR` also exists as a
fallback.)

We confirmed the exact bundle layout to replicate by inspecting cmux read-only:

```
/Applications/cmux.app/Contents/Resources/
├── xterm-ghostty                         # compiled terminfo (top-level copy)
├── terminfo/
│   ├── 78/xterm-ghostty                  # <-- the sentinel libghostty looks for
│   ├── 67/ghostty
│   ├── ghostty.terminfo                  # source
│   └── ghostty.termcap
└── ghostty/
    ├── shell-integration/
    │   ├── bash/ghostty.bash
    │   ├── zsh/ghostty-integration        # <-- we spawn /bin/zsh, this matters
    │   ├── fish/vendor_conf.d/ghostty-shell-integration.fish
    │   ├── elvish/lib/ghostty-integration.elv
    │   └── nushell/vendor/autoload/ghostty.nu
    └── themes/                            # ~460 theme files (optional but cheap to ship)
```

Get these files from the Ghostty checkout/install (`zig-out/share/ghostty/...` after a
build, or copy from an installed Ghostty.app / cmux.app of a matching version). Add a
**build phase / SwiftPM resource copy** that places them under
`YourApp.app/Contents/Resources/` preserving the structure above, so the sentinel sits
at `Contents/Resources/terminfo/78/xterm-ghostty` and the binary is at
`Contents/MacOS/VoiceTermPoC`. With a SwiftPM `.executableTarget`, use a `resources:`
copy rule or a post-build script; the key requirement is final on-disk layout, not the
mechanism.

> Version-match the resources to the libghostty you link. Mismatched terminfo/shell
> integration vs. engine version can cause subtle breakage.

---

## 5. The exact C API call sequence

All symbols below are verbatim from `include/ghostty.h` (Ghostty 1.3.x line — cmux
strings show `Since Ghostty 1.3.0` markers). The Swift usage patterns are distilled
from Ghostty's own `macos/Sources/Ghostty/Ghostty.App.swift`,
`Ghostty.Surface.swift`, and `Surface View/SurfaceView_AppKit.swift`.

### 5.1 One-time process init

```c
GHOSTTY_API int ghostty_init(uintptr_t argc, char** argv);   // returns GHOSTTY_SUCCESS (0)
GHOSTTY_API ghostty_info_s ghostty_info(void);               // build mode + version
```

Call `ghostty_init(0, nil)` once at app launch before anything else.

### 5.2 Config

```c
ghostty_config_t ghostty_config_new();
void ghostty_config_load_default_files(ghostty_config_t);   // optional: load ~/.config/ghostty
void ghostty_config_finalize(ghostty_config_t);             // REQUIRED before use
void ghostty_config_free(ghostty_config_t);
```

You can skip loading user files and just `new` → `finalize` for a sealed config.

### 5.3 Create the app (with our runtime callbacks)

```c
ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t);
void ghostty_app_tick(ghostty_app_t);          // drive the event loop / process IO
void ghostty_app_set_focus(ghostty_app_t, bool);
void ghostty_app_free(ghostty_app_t);
```

The runtime config wires in our callbacks. This is the single most important struct —
it is how title/exit/clipboard/wakeup get back to us:

```c
typedef struct {
  void* userdata;                         // we pass our App/coordinator pointer
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;             // void(*)(void* userdata)
  ghostty_runtime_action_cb action_cb;             // bool(*)(app, target, action) -- TITLE/EXIT/etc.
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;   // void(*)(void* userdata, bool processAlive)
} ghostty_runtime_config_s;
```

`wakeup_cb` fires from a background thread to tell us "you have work; call
`ghostty_app_tick` on the main thread soon." `action_cb` is the firehose for everything
event-like (titles, child exit, bell, pwd, mouse shape, ...).

### 5.4 Create a surface bound to our NSView (this spawns the PTY)

```c
ghostty_surface_config_s ghostty_surface_config_new();   // zero-inited defaults
ghostty_surface_t ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
```

The config struct — note `command`, `env_vars`, `working_directory`,
`platform.macos.nsview`, `scale_factor`. **Setting `command`/`env_vars`/`working_directory`
is the `startProcess(...)` equivalent — libghostty spawns and owns the PTY/zsh:**

```c
typedef struct {
  ghostty_platform_e platform_tag;     // GHOSTTY_PLATFORM_MACOS
  ghostty_platform_u platform;         // .macos.nsview = (void*)our NSView
  void* userdata;                      // per-surface back-pointer (our Pane)
  double scale_factor;                 // NSScreen backingScaleFactor
  float font_size;                     // 0 = use config default
  const char* working_directory;       // == startProcess(currentDirectory:)
  const char* command;                 // == startProcess(executable:+args:), e.g. "/bin/zsh -l"
  ghostty_env_var_s* env_vars;         // == startProcess(environment:)
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;   // WINDOW / TAB / SPLIT
} ghostty_surface_config_s;
```

The way Ghostty's macOS app fills this (from `SurfaceConfiguration.withCValue`):

```swift
var c = ghostty_surface_config_new()
c.userdata     = Unmanaged.passUnretained(view).toOpaque()
c.platform_tag = GHOSTTY_PLATFORM_MACOS
c.platform     = ghostty_platform_u(macos: .init(nsview: Unmanaged.passUnretained(view).toOpaque()))
c.scale_factor = NSScreen.main!.backingScaleFactor
c.font_size    = 0
c.working_directory = cwdCString        // optional
c.command           = "/bin/zsh -l"     // optional; default is user shell
// env_vars: build [ghostty_env_var_s] of {key,value} C strings, set c.env_vars + c.env_var_count
let surface = ghostty_surface_new(app, &c)
```

> **Important:** libghostty creates and owns the `CAMetalLayer` from the `nsview`
> handle. Our `NSView` must be **layer-backed** (`wantsLayer = true`) and should not
> fight Ghostty for `layer`/`contentsScale`. Ghostty's own view is an `OSView`
> subclass that defers layer management appropriately. **No `MTKView` / no Metal code of
> our own is needed** — that is the whole point of using the full engine vs. `vt`.

### 5.5 Drive size / scale / focus / draw

```c
void ghostty_surface_set_size(ghostty_surface_t, uint32_t width_px, uint32_t height_px);
void ghostty_surface_set_content_scale(ghostty_surface_t, double x, double y);
void ghostty_surface_set_focus(ghostty_surface_t, bool);
void ghostty_surface_draw(ghostty_surface_t);    // render a frame
void ghostty_surface_refresh(ghostty_surface_t); // request redraw
ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);  // cols/rows/cell px
```

Call `set_size` from `NSView` layout (`setFrameSize`/`viewDidChangeBackingProperties`),
`set_content_scale` when backing scale changes, `set_focus` from first-responder
changes. **Resize is handled for us** — libghostty recomputes cols/rows and resizes the
PTY (replacing SwiftTerm's `sizeChanged` delegate, which we currently no-op anyway).

### 5.6 Input — keyboard, text, and our voice injection

```c
bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);          // physical key events
void ghostty_surface_text(ghostty_surface_t, const char* utf8, uintptr_t len);  // committed text
void ghostty_surface_preedit(ghostty_surface_t, const char* utf8, uintptr_t len); // IME marked text
bool ghostty_surface_mouse_button(...); void ghostty_surface_mouse_pos(...); // mouse
```

- **Real keyboard** goes through `ghostty_surface_key` (via `NSResponder.keyDown` →
  build `ghostty_input_key_s` from the `NSEvent`) and `ghostty_surface_text` (via
  `NSTextInputClient.insertText`). To get correct CJK/emoji/IME you implement
  `NSTextInputClient` on the view (`insertText`, `setMarkedText`,
  `firstRectForCharacterRange`, etc.). Ghostty's `SurfaceView_AppKit.swift` is the
  reference; Kytos confirms CJK+emoji work this way.
- **Voice injection (our `send(txt:)`)** does NOT need any of the keyboard machinery —
  it is exactly `ghostty_surface_text`. The canonical pattern (from Ghostty's
  `readSelection(from:)` paste handler) is:

```swift
// Replacement for SwiftTerm's `term.send(txt: t)`:
func send(text str: String) {
    let len = str.utf8CString.count        // includes NUL terminator
    if len <= 1 { return }
    str.withCString { ptr in
        ghostty_surface_text(surface, ptr, UInt(len - 1))   // len-1 to drop NUL
    }
}
```

The `"\r"` Enter we send 0.35s later in `VoiceController`/`VoiceLoop` is also just
`send(text: "\r")` (or `"\n"`) — same call. **The carriage-return-as-separate-event
trick that we rely on for Claude Code submission keeps working**, because
`ghostty_surface_text` writes to the PTY just like SwiftTerm's `send` did.

### 5.7 Title and exit (the delegate replacements) — via `action_cb`

`action_cb` is `bool (*)(ghostty_app_t, ghostty_target_s target, ghostty_action_s action)`.
Switch on `action.tag`; resolve `target.target.surface` back to our `Pane` via the
surface userdata. The two we care about:

```c
// Title  (replaces setTerminalTitle(source:title:))
case GHOSTTY_ACTION_SET_TITLE:
    // action.action.set_title.title  is a C string
    // -> pane.title = String(cString:)

// Process exit (replaces processTerminated(source:exitCode:))
case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
    // action.action.child_exited.exit_code (uint32)
    // -> trigger our pane-close / removeLeaf logic
```

Also available and useful: `GHOSTTY_ACTION_PWD` (cwd updates — replaces the unused
`hostCurrentDirectoryUpdate`), `GHOSTTY_ACTION_RING_BELL`, `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`,
`GHOSTTY_ACTION_MOUSE_SHAPE`, `GHOSTTY_ACTION_CELL_SIZE`.

> **Important — actions we must intentionally ignore/handle:** because we run our *own*
> tabs/splits, we must return `false` (or no-op) for `GHOSTTY_ACTION_NEW_TAB`,
> `NEW_SPLIT`, `GOTO_SPLIT`, `CLOSE_TAB`, `TOGGLE_FULLSCREEN`, etc., OR map them to our
> `Session` tree if we want Ghostty keybinds to drive our layout. For a first pass,
> handle only `SET_TITLE` + `SHOW_CHILD_EXITED` + `PWD` and ignore the rest.

You can also **poll** instead of/in addition to the callback:
`bool ghostty_surface_process_exited(ghostty_surface_t)`.

### 5.8 Teardown

```c
ghostty_surface_free(surface);   // per pane on close
ghostty_app_free(app);           // once at app shutdown
```

### Full sequence, condensed

```
ghostty_init(0, nil)
cfg  = ghostty_config_new(); ghostty_config_finalize(cfg)
app  = ghostty_app_new(&runtime_cfg /*callbacks+userdata*/, cfg)
ghostty_app_set_focus(app, true)
--- per pane ---
sc = ghostty_surface_config_new()
   set platform_tag/nsview/scale_factor/command/env_vars/working_directory/userdata
surface = ghostty_surface_new(app, &sc)          // <- spawns /bin/zsh in a PTY
ghostty_surface_set_content_scale(surface, sx, sy)
ghostty_surface_set_size(surface, wpx, hpx)
ghostty_surface_set_focus(surface, true)
--- runtime ---
on wakeup_cb  -> dispatch to main -> ghostty_app_tick(app)
on layout     -> ghostty_surface_set_size / set_content_scale
on keyDown    -> ghostty_surface_key ; NSTextInputClient.insertText -> ghostty_surface_text
on VOICE      -> ghostty_surface_text(surface, utf8, len)        // == send(txt:)
on draw       -> ghostty_surface_draw(surface)
action_cb     -> SET_TITLE / SHOW_CHILD_EXITED / PWD ...
--- teardown ---
ghostty_surface_free(surface) ; ghostty_app_free(app)
```

---

## 6. Swift interop plan

### 6.1 Module / bridging

With the xcframework approach there is **no manual bridging header**. The xcframework
ships `module.modulemap` (the `GhosttyKit` module shown above), so you simply:

```swift
import GhosttyKit
```

and every `ghostty_*` symbol, enum (`GHOSTTY_ACTION_SET_TITLE`, …), and struct
(`ghostty_surface_config_s`, …) is visible to Swift. If instead you link the raw static
lib + header in a hand-rolled SwiftPM C target, create a `systemLibrary`/C target with
the same `module.modulemap` pointing at `ghostty.h`.

### 6.2 C callbacks ↔ Swift

The runtime callbacks are C function pointers. In Swift they must be **non-capturing
closures** (or top-level/`static` funcs). Pass context through `userdata` and recover it
with `Unmanaged`. Ghostty's own pattern (from `Ghostty.App.swift`):

```swift
var rc = ghostty_runtime_config_s(
  userdata: Unmanaged.passUnretained(self).toOpaque(),
  supports_selection_clipboard: true,
  wakeup_cb: { ud in App.wakeup(ud) },                         // non-capturing
  action_cb: { app, target, action in App.action(app!, target: target, action: action) },
  read_clipboard_cb:        { ud, loc, st in App.readClipboard(ud, location: loc, state: st) },
  confirm_read_clipboard_cb:{ ud, s, st, req in App.confirmReadClipboard(ud, string: s, state: st, request: req) },
  write_clipboard_cb:       { ud, loc, c, n, cf in App.writeClipboard(ud, location: loc, content: c, len: n, confirm: cf) },
  close_surface_cb:         { ud, alive in App.closeSurface(ud, processAlive: alive) }
)
guard let app = ghostty_app_new(&rc, cfg.config) else { /* error */ }
```

Inside each static handler, recover the Swift object:

```swift
static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    // for surface-targeted actions:
    guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface,
          let ud = ghostty_surface_userdata(s) else { return false }
    let pane = Unmanaged<PaneController>.fromOpaque(ud).takeUnretainedValue()
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        pane.title = String(cString: action.action.set_title.title)
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        pane.onExit()
    default: return false
    }
    return true
}
```

### 6.3 Threading

- `ghostty_app_tick` and all surface mutation must happen on the **main thread**.
- `wakeup_cb` can fire off-thread → always `DispatchQueue.main.async { ghostty_app_tick(app) }`.
- Swift 6.2 strict concurrency: the C handles are `UnsafeMutableRawPointer`-ish
  (`ghostty_app_t = void*`), not `Sendable`. Wrap them in a `@MainActor` controller and
  pass `@unchecked Sendable` boxes across the wakeup boundary. Budget time for
  concurrency annotation friction (this is a known Swift-6-era pain point).

### 6.4 Hosting in `NSViewRepresentable`

Replace our current `TerminalRepresentable`:

```swift
final class GhosttyTermView: NSView, NSTextInputClient {
    var surface: ghostty_surface_t?
    override var wantsUpdateLayer: Bool { true }
    // wantsLayer = true; let libghostty own the CAMetalLayer it makes from this view.

    func attach(app: ghostty_app_t, pane: PaneController, cwd: String?, env: [String:String]) {
        wantsLayer = true
        var c = ghostty_surface_config_new()
        c.userdata = Unmanaged.passUnretained(pane).toOpaque()
        c.platform_tag = GHOSTTY_PLATFORM_MACOS
        c.platform = .init(macos: .init(nsview: Unmanaged.passUnretained(self).toOpaque()))
        c.scale_factor = (window?.screen ?? NSScreen.main)?.backingScaleFactor ?? 2.0
        // set command/env_vars/working_directory here (Section 5.4)
        surface = ghostty_surface_new(app, &c)
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(surface, UInt32(s.width * scale), UInt32(s.height * scale))
    }
    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }; return super.becomeFirstResponder()
    }
    override func keyDown(with e: NSEvent) { /* build ghostty_input_key_s -> ghostty_surface_key; inputContext?.handleEvent(e) */ }
    func insertText(_ s: Any, replacementRange: NSRange) { /* -> ghostty_surface_text */ }
    // ... rest of NSTextInputClient
}

struct GhosttyRepresentable: NSViewRepresentable {
    let pane: PaneController
    func makeNSView(context: Context) -> GhosttyTermView { pane.view }
    func updateNSView(_ v: GhosttyTermView, context: Context) {}
}
```

Our existing `NSClickGestureRecognizer`-based focus tracking and the
`overlay(RoundedRectangle…)` focus ring in `PaneContainer` keep working unchanged.

---

## 7. Replacing `LocalProcessTerminalView` in our code (concrete diff sketch)

Only `Pane` and the two `send(txt:)` call sites change. Define a tiny protocol so
SwiftTerm and Ghostty are swappable behind a flag:

```swift
protocol TerminalBackendPane: AnyObject {
    var title: String { get }
    func send(text: String)          // both backends implement this
    var nsView: NSView { get }
    var onTitle: ((String) -> Void)? { get set }
    var onExit:  (() -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
}
```

- SwiftTerm impl: wraps `LocalProcessTerminalView`; `send` → `term.send(txt:)`.
- Ghostty impl: wraps `GhosttyTermView` + `ghostty_surface_t`; `send` →
  `ghostty_surface_text`; `onTitle`/`onExit` driven by `action_cb`.

Then in `VoiceController.stop` and `VoiceLoop.submit`, change `target.term.send(txt: t)`
→ `target.backend.send(text: t)` and `pane.term.send(txt: "\r")` →
`pane.backend.send(text: "\r")`. Everything else in `App.swift` (layout tree, tabs,
voice loop, event polling) is untouched.

---

## 8. Caveats / risks (be honest)

1. **Unstable C API.** The full-embedding API is explicitly "not general purpose yet";
   signatures change between Ghostty releases. **Pin an exact version** of the
   xcframework AND the matching resource files. Upgrades are manual and may break the
   build. This is the #1 reason to keep SwiftTerm.
2. **No Zig toolchain here.** Building from source needs Zig 0.15.x. Prefer the prebuilt
   SwiftPM package to avoid owning that.
3. **Resource bundling is mandatory** and easy to get subtly wrong (sentinel path,
   version mismatch). cmux's layout (Section 4) is the known-good reference.
4. **`NSTextInputClient` is non-trivial.** Full keyboard + IME (CJK/emoji) means
   implementing the text-input protocol correctly; Ghostty's `SurfaceView_AppKit.swift`
   (~2400 lines) is the reference and it is large. *Our voice path needs none of this*
   (`ghostty_surface_text` only), but a usable terminal does.
5. **We must suppress Ghostty's own window/tab/split actions** in `action_cb` since we
   run our own multiplexing UI, or deliberately bridge them to our `Session` tree.
6. **Swift 6.2 strict concurrency** friction around the raw C handles and off-thread
   `wakeup_cb`.
7. **Code signing / entitlements.** Our app is ad-hoc signed. libghostty needs Metal
   (works ad-hoc). If we later sandbox or notarize, the bundled terminfo/shell-integration
   scripts and the spawned shell need to be accounted for. cmux ships unsandboxed.
8. **Binary size + universal slices.** The xcframework is sizable (full GPU terminal
   engine). Build arm64-only locally to speed iteration.
9. **App bundle required.** libghostty's resource discovery walks up from the executable
   expecting an `.app` layout; the `swift run` bare-binary flow won't find resources.
   Test via the assembled `.app`, not `swift run`.

---

## 9. Recommended migration plan (step by step)

**Phase 0 — Decision/spike (½–1 day).**
- Keep SwiftTerm as default. Add the `TerminalBackendPane` protocol (Section 7) and make
  the current `Pane` conform — no behavior change. This de-risks everything downstream.

**Phase 1 — Get the framework (½–1 day).**
- Add the prebuilt `GhosttyKit.xcframework` SwiftPM package (Option A), pin an exact tag
  matching a Ghostty 1.3.x-ish release. Add the framework links (Metal/MetalKit/
  QuartzCore/CoreText/Carbon). Confirm `import GhosttyKit` compiles and
  `ghostty_info()` returns a version.

**Phase 2 — Resources (½ day).**
- Copy `terminfo/` + `ghostty/{shell-integration,themes}` into the `.app` bundle
  (Section 4), version-matched. Verify the sentinel lands at
  `Contents/Resources/terminfo/78/xterm-ghostty`.

**Phase 3 — Single static surface PoC (2–4 days).**
- `ghostty_init` → config → `ghostty_app_new` (with real `action_cb`/`wakeup_cb`).
- One `GhosttyTermView` in a plain window, surface bound to it, `command="/bin/zsh -l"`,
  our env (TERM handling, `VOICETERM_*` vars). Wire `set_size`/`set_content_scale`/
  `set_focus`/`draw` and the main-thread `app_tick` pump.
- Implement `NSTextInputClient` + `keyDown`→`ghostty_surface_key`. Goal: type in zsh,
  see GPU-rendered output, resize works, title updates via `SET_TITLE`.

**Phase 4 — Voice injection parity (½ day).**
- Implement `send(text:)` via `ghostty_surface_text` (Section 5.6). Point
  `VoiceController.stop` / `VoiceLoop.submit` at the protocol. Verify the
  text-then-separate-`\r` Claude Code submission still works.

**Phase 5 — Wire into our layout tree (2–3 days).**
- Make the Ghostty backend a full `TerminalBackendPane`. Plug into `Session`/`LayoutNode`
  tabs+splits. Map `SHOW_CHILD_EXITED` → `handleExit`/`removeLeaf`; keep our click-focus.
- Ensure each surface is its own `ghostty_surface_t` under the single shared
  `ghostty_app_t`. Suppress Ghostty's own tab/split actions.

**Phase 6 — Feature flag + soak (ongoing).**
- Ship behind a runtime flag (`backend = .swiftTerm | .ghostty`), default SwiftTerm.
  Dogfood Ghostty; watch for IME, resize, exit-handling, and concurrency issues.
- Only flip the default after it is solid AND a tagged/stable full libghostty API lands
  (or you accept pinning a known-good unstable version indefinitely).

**Keep SwiftTerm** as the fallback for the foreseeable future — it is pure-Swift, stable,
and has zero native-build/resource/signing burden. libghostty wins on rendering quality
and fidelity, but at the cost of an unstable C API and a heavier build. Treat the switch
as an enhancement, not a hard cutover.

---

## 10. Reference source files (already located, for implementation)

When implementing, read these from a Ghostty checkout (`github.com/ghostty-org/ghostty`):

- `include/ghostty.h` — the entire C API (the authoritative contract).
- `include/module.modulemap` — the `GhosttyKit` Clang module.
- `macos/Sources/Ghostty/Ghostty.App.swift` — `ghostty_app_new`, the runtime callback
  wiring, and the full `action_cb` dispatcher incl. `setTitle` / `showChildExited`.
- `macos/Sources/Ghostty/Surface View/SurfaceView.swift` — `struct SurfaceConfiguration`
  + `withCValue` (how `nsview`/`scale`/`command`/`env_vars` are filled).
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` — the canonical
  layer-backed `NSView`: surface creation, `ghostty_surface_set_size`/`set_content_scale`/
  `set_focus`, `keyDown`→`ghostty_surface_key`, `NSTextInputClient`→`ghostty_surface_text`.
- `macos/Sources/Ghostty/Surface View/OSSurfaceView.swift` — the shared base view.
- Reference apps: **cmux** (`/Applications/cmux.app`, static link, inspected here),
  **Ghostling** (minimal single-file C consumer), **Kytos** (XcodeGen + xcframework + CJK/IME).

### Sources

- [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
- [Libghostty Is Coming — Mitchell Hashimoto](https://mitchellh.com/writing/libghostty-is-coming)
- [Integrating Zig and SwiftUI — Mitchell Hashimoto](https://mitchellh.com/writing/zig-and-swiftui)
- [awesome-libghostty (Uzaaft)](https://github.com/Uzaaft/awesome-libghostty)
- [ghostty-org/ghostling](https://github.com/ghostty-org/ghostling)
- [Kytos: A Native macOS Terminal Built on Ghostty (Julien Wintz)](https://jwintz.gitlabpages.inria.fr/jwintz/blog/2026-03-14-kytos-terminal-on-ghostty/)
- Local inspection: `/Applications/cmux.app` (static GhosttyKit link, resource layout, linked frameworks), `include/ghostty.h` @ Ghostty `main`.
