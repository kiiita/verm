# cmux UI + Keyboard-Shortcut Replication Spec

> Goal: rebuild cmux's UX (sidebar, tab bar, panes/splits, top bar) and keybindings
> in our SwiftUI macOS terminal app (`voice-terminal`). cmux itself is **read-only
> reference** — never modify `/Applications/cmux.app`.

## 0. Provenance / how this was derived

- **App version:** cmux **0.61.0** (build 73, commit `8caa5e9c9`), bundle id
  `com.cmuxterm.app`, by **Manaflow, Inc.** Built with Xcode 17 / macOS SDK 26.2,
  `LSMinimumSystemVersion 14.0`, category `developer-tools`.
- **Terminal core:** Ghostty (embedded `libghostty`; `Resources/ghostty/` ships
  Ghostty themes + shell integration; terminfo `xterm-ghostty`). Much of the
  Ghostty action/keybind vocabulary surfaces in `strings` but is **inherited**, not
  cmux's own UI layer. cmux's own shortcuts live under the `shortcut.*` /
  `shortcuts.bindings` namespace (see §2).
- **Sources mined**
  1. CLI: `/Applications/cmux.app/Contents/Resources/bin/cmux --help` (full v2 +
     tmux-compat + browser command surface).
  2. `Contents/Info.plist` (services, UTIs, Sparkle update feed).
  3. `strings Contents/MacOS/cmux` → `shortcut.*` ids, `_*ShortcutData` ivars,
     `_sidebar*` config ivars, menu/settings labels, status-pill symbols.
  4. Official docs (authoritative for default keybinds + config keys):
     - https://cmux.com/docs/keyboard-shortcuts
     - https://cmux.com/docs/configuration
     - Mirror: https://manaflow-ai-cmux.mintlify.app/features/keyboard-shortcuts
  5. Repo: https://github.com/manaflow-ai/cmux (README, "Ghostty-based macOS
     terminal with vertical tabs and notifications for AI coding agents").
- **Confidence:** keybind defaults and config keys are **high** (cross-checked
  binary ↔ docs). Exact pixel metrics/materials are **inferred** (SwiftUI
  `.regularMaterial` etc.) since no layout asset file was found — see §5.

---

## 1. UI Layout Spec

cmux is a **3-zone macOS window**: left **sidebar** (vertical workspace tabs) ·
center **content** (tab bar + terminal/browser panes) · optional right sidebar
(file explorer / diff). Title bar is transparent (`setTitlebarAppearsTransparent`,
`NSToolbar`-based; symbols `addTitlebarAccessoryViewController`, `setToolbarStyle`).

```
┌───────────────────────────────────────────────────────────────────────┐
│ [⌃ traffic lights]   <transparent titlebar / toolbar>      🔔  ＋        │  ← top bar
├──────────────┬────────────────────────────────────────────────────────┤
│  SIDEBAR     │  TAB BAR:  [ term ] [ term ] [ browser ] [ diff ]  ＋    │
│ (workspaces) ├────────────────────────────────────────────────────────┤
│ A. Meisei    │                                                          │
│   Claude is  │                                                          │
│   waiting…   │                 ACTIVE PANE / SURFACE                    │
│   ┄ PR #123  │              (terminal, browser, diff, or               │
│ B. VIGGY     │               markdown preview) — splittable             │
│   Running    │                                                          │
│ C. パスライト  │                                                          │
│   Needs input│   ┌──────────────────┬───────────────────┐              │
│ D. YOMOTTO   │   │  split pane L     │   split pane R    │              │
│   merged ✓   │   └──────────────────┴───────────────────┘              │
│ …            │                                                          │
│ G. Config    │                                                          │
└──────────────┴────────────────────────────────────────────────────────┘
   resizer→ │ (draggable; pointer-monitored, cursor stabilized)
```

### 1.1 Object model (from CLI `--help`)

cmux's hierarchy — replicate these as your data model:

```
Window
 └─ Workspace            (= a sidebar row; has title, color, git/PR/port/status metadata)
     └─ Pane             (a split region; tiled left/right/up/down)
         └─ Surface      (a tab inside a pane: terminal | browser | diff | markdown)
     └─ Panel            (addressable target for send/focus; ≈ surface-level handle)
```

- Refs use the form `window:1` / `workspace:2` / `pane:3` / `surface:4`; also
  UUIDs and 0-based indexes. `tab:<n>` is an alias for `surface:<n>`.
- Env vars injected into every cmux terminal: `CMUX_WORKSPACE_ID`,
  `CMUX_SURFACE_ID`, `CMUX_TAB_ID` (used as command defaults). Control channel is a
  Unix socket `/tmp/cmux.sock` (override `CMUX_SOCKET_PATH`), password-auth'd.
- **Terminology mapping for our app:** cmux "Workspace" = top-level project/agent
  context (sidebar row). cmux "Surface" = what most apps call a tab. cmux "Pane" =
  a split. Note the docs label some shortcuts "Surfaces (Tabs)".

### 1.2 LEFT SIDEBAR (the signature feature)

Vertical list of **workspaces**, one row each. This is what the user screenshotted
("A. Meisei / B. VIGGY / C. パスライト / D. YOMOTTO / E. PathLight TSE / F. OMRON /
G. Config"). Drag to reorder (`reorder-workspace`; UTI
`com.cmux.sidebar-tab-reorder`); also "Move Up / Move Down" context actions.
Accessibility label: *"Activate to focus this workspace. Drag to reorder, or use
Move Up and Move Down actions."*

**Per-workspace row anatomy** (each toggleable via `sidebar.*` config — see §2.3):

| Element | Source / config | Notes |
|---|---|---|
| **Index/letter hint** ("A.", "B.", …) | `ShortcutHintPillBackground`, `_sidebarShortcutHintX/YOffset`, `_alwaysShowShortcutHints`, "Sidebar Cmd+1" | A small overlaid **pill** that hints the `⌘1…9` selection key for that row. The "A./B./C." the user saw is this **mnemonic shortcut hint**, not a static label. Render as a faint pill at a configurable offset; show always or on `⌘`-hold. |
| **Workspace title** | `rename-workspace`; `sidebar.wrapWorkspaceTitles` (default off) | One line by default; can wrap. |
| **Active indicator** | "Active Workspace Indicator", `sidebarActiveTabIndicatorStyle` | Highlight bar/pill for the selected workspace. |
| **Agent status line** | `set_status` / `report_meta` via `claude-hook` (see §1.6) | **Dynamic free text** — e.g. "Claude is waiting for your input", "Needs input", "Running". *Not* hardcoded enum (confirmed: no such literals in binary). Has icon + color + optional URL + priority. `sidebar.showNotificationMessage` (default on) shows latest notification text. |
| **Git branch** | `sidebar.showBranch*`, `_sidebarShowGitBranch/Icon/BranchDirectory`, `branchLayout: vertical\|inline`, `watchGitStatus` | Branch name (+ icon, + working dir). Layout vertical or inline. |
| **Pull request pill** | `sidebar.showPullRequests`, `SidebarPullRequestStatus`, `PullRequestStatusIcon`; CLI `report_pr <n> <url> --state open\|merged\|closed` | Shows PR/MR **number + state icon + clickable link**. "merged" in the screenshot is a PR state. Links open in cmux browser (`openPullRequestLinksInCmuxBrowser`) or external. |
| **Ports** | `sidebar.showPorts`, `_sidebarShowPorts`, `openPortLinksInCmuxBrowser` | Detected listening ports, clickable. |
| **Progress bar** | `sidebar.showProgress`; CLI `set_progress <0..1> [--label]` | Built-in determinate bar + spinner glyphs (`extra-progress_*` assets). |
| **Custom metadata pills** | `sidebar.showCustomMetadata`, `sidebarShowStatusPills`; CLI `report_meta` / `report_meta_block` (markdown) | Arbitrary key/value pills (icon, `#hex` color, url, priority, plain/markdown). |
| **Log snippet** | `sidebar.showLog`, `_sidebarShowLog`, `sidebarMaxLogEntries`; CLI `log` | Latest imperative log/status message. |
| **SSH info** | `sidebar.showSSH` | Connection details when remote. |
| **Unread / attention state** | `notifications.unreadPaneRing`, `_notificationDockBadgeEnabled`, `triggerFlash` | Tab "lights up" + pane gets a **blue ring** when an agent needs attention. |

**Sidebar appearance** (config `sidebarAppearance.*` + ivars
`_sidebarMaterial/BlendMode/BlurOpacity/TintHex/TintOpacity/CornerRadius/Width`):
translucent material, tint `#000000` @ opacity `0.03` by default; can match
terminal background (`matchTerminalBackground`), light/dark tint overrides, rounded
corners. Width is user-draggable (`_sidebarWidth`, `_sidebarDragStartWidth`).

**Reordering / notification float:** workspaces can auto-float to top on
notification (config "Move workspaces to the top when they receive a
notification… Disable for stable shortcut positions"). New-workspace placement:
`top` / `afterCurrent` (default) / `end`.

**Workspace context menu** (right-click a row): New Workspace in Current Window ·
Selected Workspace in New Window · Rename Workspace · Clear Workspace Name ·
Choose Custom Color… / Reset Color · Move Up / Move Down · Close Workspace · Close
Other Workspaces · Close Workspaces Above · Close Workspaces Below. (Closing prompts
"Close workspace?")

### 1.3 TAB BAR (surfaces within the active workspace's focused pane)

Horizontal strip above the content area. Tabs = **surfaces** (`new-surface`,
types `terminal | browser`; diff & markdown-preview also appear as surfaces). Tab
shows title (`rename-tab`), close affordance, and a type glyph (terminal / globe
for browser / diff). Trailing **＋** adds a surface. Reorderable
(`reorder-surface`, `move-surface`, UTI `com.splittabbar.tabtransfer` — internal
framework **"Bonsplit"** / `_bonsplitController`). Toolbar can auto-hide
(`AutoHideTabBar`).

### 1.4 PANES / SPLITS (Bonsplit tiling)

- Surfaces live inside **panes**; panes tile **left/right/up/down**
  (`new-split <dir>`). A split "along the larger direction" is created when no dir
  given (`new_split` picks the longer axis).
- **Drag-to-edge to split:** dropping a tab onto a pane edge creates a split in
  that direction (`drag-surface-to-split <id> <left|right|up|down>`).
- **Zoom:** a pane can be zoomed to fill the workspace (`toggle_split_zoom`,
  "ZoomToggle"); `split-preserve-zoom` controls behavior on navigation.
- **Equalize:** reset split ratios (`⌃⌘=`).
- **tmux-compat ops** exist (`swap-pane`, `break-pane`, `join-pane`,
  `resize-pane -L/-R/-U/-D`, `last-pane`) — implement if you want tmux parity.
- **Unread pane ring:** focused-but-unread panes get a colored ring;
  `triggerFlash` flashes a pane (`⌘⇧H`).

### 1.5 TOP BAR controls (matches screenshot's bell + ＋)

- **🔔 Notification bell** — opens the notifications popover
  (`NotificationsPopoverView`, `NotificationsAnchorView`, `NotificationsPage`).
  Empty states: "No notifications yet" / "No unread notifications". Carries an
  unread badge; also mirrored on the **Dock tile** (`notifications.dockBadge`,
  "Show unread count on app icon (Dock and Cmd+Tab)") and an optional **menu-bar
  extra** (`NSStatusItem`, `notifications.showInMenuBar`).
- **＋ button** — new workspace / new surface (primary create action). macOS
  *Services* also expose "New cmux Workspace Here" / "New cmux Window Here" for
  Finder file paths (Info.plist `NSServices` → `openTab` / `openWindow`).
- Title bar is transparent with toolbar accessory views; traffic lights standard.

### 1.6 Agent-status pipeline (KEY architectural finding — replicate this)

The per-workspace status line ("Claude is waiting for your input", "Needs input",
"Running", etc.) is **not** a fixed enum in cmux. It is **pushed in by the agent**:

1. cmux ships a `claude` shim (`Resources/bin/claude`) that wraps Claude Code when
   `CMUX_SURFACE_ID` is set, injecting `--session-id` and a `--settings` JSON that
   registers hooks: `SessionStart → cmux claude-hook session-start`,
   `Stop → cmux claude-hook stop`, `Notification → cmux claude-hook notification`.
2. Those hooks call back over the socket; cmux turns them into sidebar
   **status entries** (`set_status key value --icon --color --url --priority
   --format plain|markdown`), **progress** (`set_progress`), **PR rows**
   (`report_pr`), **logs** (`log`), and **notifications** (`notify`).
3. The sidebar just renders whatever status/metadata is current. Toggle in Settings:
   "Claude Code Integration … cmux wraps the claude command to inject session
   tracking and notification hooks" (`claudeCodeHooksEnabled`).

> **For our app:** model the status line as an open, agent-supplied
> `{text, icon, color, url, priority, format}` record per workspace, refreshed by
> a hook/IPC channel — **do not** hardcode "Running/Needs input/merged" as an enum.
> "merged" specifically is a **PR state** (`open|merged|closed`), rendered as a PR
> pill, distinct from the free-text agent status.

### 1.7 Surface types beyond terminal

- **Browser** surface: WKWebView with omnibar (`BrowserOmnibarPill`,
  `OmnibarPillFramePreferenceKey`), full scripting API (`cmux browser …`:
  navigate/snapshot/click/type/eval/cookies/storage/tabs/console), dev tools,
  JS console, "React Grab". Search engine configurable (google default; 15+
  presets + custom template).
- **Diff viewer** surface: vim-style scroll (`j/k`, `G`, `gg`), `/` file search.
- **Markdown preview** surface: zoomable (`⌘=`/`⌘-`/`⌘0`).

---

## 2. Keyboard Shortcut Table (comprehensive)

**Notation:** ⌘ Cmd · ⌥ Opt · ⌃ Ctrl · ⇧ Shift · ↩ Return.
**Source column:** `docs` = cmux.com/docs/keyboard-shortcuts (authoritative
defaults), `bin` = literal id/`_*ShortcutData` ivar in the cmux binary, `cfg` =
`shortcuts.bindings` key in cmux.json config, `Ghostty` = inherited terminal-core
action. Where docs and binary agree, both are cited.

**Config model:** all cmux-owned shortcuts live under `shortcuts.bindings` in
`~/.config/cmux/cmux.json` (or Settings → **Keyboard Shortcuts**). Value forms:
single `"cmd+b"`; chord `["ctrl+b","c"]` (two-step); unbind with `""`, `null`,
`"none"`, `"clear"`, `"unbound"`, or `"disabled"`. **At least one modifier is
required** (plain letters disallowed). Conflicts are not auto-validated; resolved
by responder-chain priority.

### 2.1 App-level

| Shortcut | Action | cfg key / id | Source |
|---|---|---|---|
| ⌘, | Open Settings | `openSettings` / `shortcut.cmd_shift_comma`* | docs, bin |
| ⌘⇧, | Reload configuration | `reloadConfiguration` | docs, bin (`menu.reload_configuration`) |
| ⌥⌘F | Command palette (open) | `commandPalette` | docs |
| ⌘⇧P | Command palette (alt / next) | `commandPalette` | docs, cfg |
| ⌃N / ⌃P | Palette next / previous (while open) | — | docs |
| ⌘⇧, (system) | Show/hide all windows (global hotkey) | — | docs |
| ⌃⌥⌘. | Global search (global hotkey) | — | docs |
| ⌃P | New window | `newWindow` / `shortcut.newWindow` | docs, bin |
| ⌘⇧N | Close window | `shortcut.closeWindow` | docs, bin |
| ⌃⌘W | Toggle full screen | `toggle_fullscreen` | docs, Ghostty |
| ⌃⌘F | Send feedback (unbound by default) | — | docs |
| ⌘⇧O | Reopen last session | — | docs |
| ⌘Q | Quit (immediate; opt. confirm) | — | docs, bin ("Cmd+Q quits immediately"; "Don't warn again for Cmd+Q") |
| ⌘\` | Toggle Quick Terminal (global) | `toggle_quick_terminal` | bin (`keybind = global:cmd+backquote=toggle_quick_terminal`), Ghostty |

\* Binary id is `shortcut.cmd_shift_comma`; docs map `⌘,`→Settings and `⌘⇧,`→reload.
Treat the docs mapping as canonical and the id as the recorder key.

### 2.2 Workspaces (sidebar)

| Shortcut | Action | cfg key / id | Source |
|---|---|---|---|
| ⌘B | Toggle left sidebar | `toggleSidebar` / `shortcut.toggleSidebar` | docs, bin |
| ⌥⌘B | Toggle right sidebar (file explorer) | `toggleFileExplorer` | docs |
| ⌘N | New workspace | `newTab`† / `shortcut.newWorkspace`-ish | docs, bin (`_newWorkspaceShortcutData`) |
| ⌘P | Go to workspace (switcher) | `goToWorkspace` | docs |
| ⌘O | Open folder | — | docs |
| ⌃⌘] | Next workspace | `shortcut.nextWorkspace` | docs, bin (`_nextWorkspaceShortcutData`) |
| ⌃⌘[ | Previous workspace | `shortcut.prevWorkspace` | docs, bin (`_prevWorkspaceShortcutData`) |
| ⌘1…8 | Select workspace 1–8 | `shortcut.selectWorkspace` (index) | docs, bin ("Sidebar Cmd+1") |
| ⌘9 | Select **last** workspace | — | docs (mirror) |
| ⌘⇧R | Rename workspace | `shortcut.renameWorkspace` | docs, bin (`_renameWorkspaceShortcutData`) |
| ⌥⌘E | Edit workspace description | — | docs |
| ⌘⇧E | Toggle sidebar/right-sidebar focus | — | docs |
| ⌘⇧W | Close workspace | `shortcut.closeWorkspace` | docs, bin (`_closeWorkspaceShortcutData`) |
| J / K / ⌃N / ⌃P / H / L , `/` | Navigate sidebar (collapse/expand folders; `/` = search) | — | docs |

† The cfg key `newTab` is bound to **New workspace** per docs (cmux uses "tab"
loosely for the sidebar). New **surface** is `⌘T` (§2.3).

### 2.3 Surfaces (tabs)

| Shortcut | Action | cfg key / id | Source |
|---|---|---|---|
| ⌘T | New surface | `newSurface` / `shortcut.newSurface` | docs, bin (`_newSurfaceShortcutData`) |
| ⌘⇧] | Next surface | `nextSurface` / `shortcut.nextSurface` | docs, bin |
| ⌘⇧[ | Previous surface | `prevSurface` / `shortcut.prevSurface` | docs, bin |
| ⌃Tab / ⌃⇧Tab | Cycle surfaces (fwd/back) | — | docs (⌃Tab = surfaces, **not** workspaces) |
| ⌃1…8 | Select surface 1–8 | — | docs, bin ("Pane Ctrl/Cmd+1") |
| ⌘R | Rename tab | `shortcut.renameTab` | docs, bin |
| ⌘W | Close tab/surface | `close_surface`/`close_tab` | docs, Ghostty/bin |
| ⌥⌘T | Close other tabs (in pane) | `close_tab:other` | docs, bin |
| ⌘⇧T | Reopen last closed surface | — | docs |
| ⌘⇧M | Toggle copy mode | `copy-mode` | docs, bin |
| ⌘⇧A | Switch focus terminal ↔ TextBox input | — | docs |
| ⌥⌘⇧A | Attach file to TextBox input | — | docs |
| ⌘S | Save focused text preview | — | docs |
| ⌃F (unbound) | Send Ctrl-F to terminal (×2 force-stops Claude Code) | — | docs |
| ⌃/⌘ + sidebar tab nav | Next/prev sidebar tab | `shortcut.nextSidebarTab` / `prevSidebarTab` | bin |

### 2.4 Split panes

| Shortcut | Action | cfg key / id | Source |
|---|---|---|---|
| ⌥⌘← / → / ↑ / ↓ | Focus pane left/right/up/down | `shortcut.focusLeft/Right/Up/Down` | docs, bin |
| ⌘D | Split right | `shortcut.splitRight` | docs, bin (`_splitRightShortcutData`) |
| ⌘⇧D | Split down | `shortcut.splitDown` | docs, bin (`_splitDownShortcutData`) |
| ⌥⌘D | Split browser right | `shortcut.splitBrowserRight` | docs, bin |
| ⌥⌘⇧D | Split browser down | `shortcut.splitBrowserDown` | docs, bin |
| ⌘⇧↩ | Toggle pane zoom | `toggle_split_zoom` | docs, Ghostty/bin |
| ⌃⌘= | Equalize splits | — | docs |

### 2.5 Browser

| Shortcut | Action | cfg key / id | Source |
|---|---|---|---|
| ⌘⇧L | Open browser | `openBrowser` / `shortcut.openBrowser` | docs, bin |
| ⌘L | Focus address bar | `focusBrowserAddressBar` | docs |
| ⌘[ / ⌘] | Back / Forward (also "focus history") | — | docs (unbind to free for browser) |
| ⌘R | Reload | — | docs |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / actual (page & markdown) | — | docs |
| ⌥⌘I | Toggle developer tools | `toggleBrowserDeveloperTools` / `shortcut.toggleBrowserDeveloperTools` | docs, bin |
| ⌥⌘C | Show JavaScript console | `shortcut.showBrowserJavaScriptConsole` | docs, bin |
| ⌥⌘↩ | Browser focus mode (Esc Esc to exit) | — | docs |
| ⌘⇧G | Toggle React Grab | — | docs |

### 2.6 Diff viewer

| Shortcut | Action | Source |
|---|---|---|
| ⌃⌘⇧D | Open diff viewer | docs |
| J / K | Scroll down / up | docs |
| ⇧G / G G | Scroll to bottom / top | docs |
| / | Open file search | docs |

### 2.7 Find

| Shortcut | Action | cfg key | Source |
|---|---|---|---|
| ⌘F | Find | `find` | docs |
| ⌘⇧F | Find in directory | `findInDirectory` | docs |
| ⌘G / ⌥⌘G | Find next / previous | — | docs |
| ⌥⌘⇧F | Hide find bar | — | docs |
| ⌘E | Use selection for find | — | docs |

### 2.8 Notifications

| Shortcut | Action | cfg key / id | Source |
|---|---|---|---|
| ⌘I | Show notifications | `showNotifications` / `shortcut.showNotifications` | docs, bin |
| ⌘⇧U | Jump to latest unread | `shortcut.jumpToUnread` | docs, bin (`_jumpToUnreadShortcutData`) |
| ⌥⌘U | Toggle unread state | — | docs |
| ⌃⌘U | Mark oldest unread / jump next-latest | — | docs |
| ⌘⇧H | Flash focused panel | `shortcut.triggerFlash` | docs, bin |

> **Quick-reference completeness:** the binary additionally carries ivars
> `_openBrowserShortcutData`, `_newWindowShortcutData`, `_toggleSidebarShortcutData`,
> `_showNotificationsShortcutData`, `_renameWorkspaceShortcutData`,
> `_warnBeforeQuitShortcut` — all map onto rows above, confirming the docs set is
> the full cmux-owned shortcut surface.

---

## 3. SwiftUI implementation notes (per component)

General: target macOS 14+ (cmux requires 14.0). Use an `NSWindow` with
transparent titlebar + `NSToolbar` accessory; everything else SwiftUI.

### 3.1 Window chrome / top bar
- `NSWindow.titlebarAppearsTransparent = true`; `.toolbarStyle = .unified`.
  Put the **bell** and **＋** as trailing `NSToolbarItem`s (or a SwiftUI
  `.toolbar { ToolbarItemGroup(placement: .primaryAction) }`).
- Bell → `Popover`/`MenuBarExtra`-style `NotificationsPopoverView`; badge via a
  `ZStack` overlay; mirror count to `NSApp.dockTile.badgeLabel`.

### 3.2 Sidebar (the priority piece)
- `NavigationSplitView` (sidebar column) **or** a custom `HSplitView` for a
  draggable resizer (cmux uses a pointer-monitored custom resizer with cursor
  stabilization — `HSplitView` is the cheap path; custom `DragGesture` +
  `NSCursor.resizeLeftRight` for fidelity).
- Each row = a `WorkspaceRowView`: `VStack(alignment:.leading)` with
  `[shortcutHintPill] title` on top line, then a `LazyVStack` of detail rows
  (status, branch, PR, ports, progress, log) each gated by a `@Published` config
  flag mirroring `sidebar.*`.
- **Status line:** bind to `workspace.status: AgentStatus?` where
  `AgentStatus = {text:String, icon:String?(SF Symbol), color:Color?, url:URL?,
  priority:Int, isMarkdown:Bool}`. Render icon + colored text; **never** enum it.
- **Shortcut hint pill:** a `Capsule().fill(.thinMaterial)` overlay showing
  "⌘1"/"A" at a configurable offset; show on `⌘`-key-down (`NSEvent` flagsChanged
  monitor) or always (`alwaysShowShortcutHints`).
- **PR pill:** `Label("#123", systemImage: prStateIcon)` with state→color map
  (`open`→green, `merged`→purple, `closed`→red); tap opens in-app browser or
  external per config.
- **Progress:** `ProgressView(value:)` (determinate) or animated spinner glyphs.
- **Material:** `.background(.regularMaterial)` + `Color(hex:tint).opacity(0.03)`
  overlay; expose tint/opacity/cornerRadius/light-dark overrides as settings.
- **Reorder:** `.onMove` in a `List`, or `.draggable`/`.dropDestination` with a
  custom `UTType("com.yourapp.sidebar-reorder")`. Context menu via `.contextMenu`.
- Auto-float-to-top on notification = re-sort the `@Published [Workspace]`; make it
  a toggle (it breaks ⌘1-9 stability when on).

### 3.3 Tab bar (surfaces)
- Horizontal `ScrollView(.horizontal)` of `TabChip`s + trailing ＋.
  Per-tab: title (double-click to rename via `TextField`), type glyph, close `×`.
- Reorder with `.draggable`/`.dropDestination`. Selection drives the content view.
- Auto-hide when a single tab if matching cmux's `AutoHideTabBar`.

### 3.4 Panes / splits
- Recursive binary-tree layout: `enum PaneNode { case leaf(Surface), case split(axis, ratio, PaneNode, PaneNode) }`,
  rendered with nested `HSplitView`/`VSplitView` (or `GeometryReader` + custom
  dividers to control ratios precisely and support equalize/zoom).
- **Zoom:** when zoomed, render only the focused leaf full-bleed; keep tree state.
- **Drag-to-edge split:** `dropDestination` regions on each pane's 4 edges →
  insert a split in that direction.
- **Unread ring:** `.overlay(RoundedRectangle().stroke(.blue, lineWidth: 2))`
  conditioned on `surface.hasUnread`.
- **Focus:** maintain `focusedPaneID`; ⌥⌘arrows do directional geometry search.

### 3.5 Terminal surface
- We already have a terminal (voice-terminal). cmux uses Ghostty; we don't need to.
  Just ensure shell-integration env (`OSC 133` prompt marks) and notification OSC
  (`OSC 9 / 99 / 777`) parsing so agents can drive status/notifications like cmux.

### 3.6 Keybindings
- Central `KeybindingStore` loading defaults (§2) overridable from JSON, mirroring
  cmux's `shortcuts.bindings` schema (single string / 2-element chord / null).
- Implement via `NSEvent.addLocalMonitorForEvents(matching:.keyDown)` plus a
  responder-chain router (cmux resolves conflicts by responder priority). SwiftUI
  `.keyboardShortcut` works for menu-backed commands; use the monitor for
  context-sensitive ones (browser focus mode, copy mode, chords).
- Support **chords** (e.g. `["ctrl+b","c"]`): a small state machine that arms on
  prefix and times out.
- Build the **Settings → Keyboard Shortcuts** recorder (cmux:
  `KeyboardShortcutRecorder`, "Click a shortcut value to record a new shortcut.",
  "Press shortcut", min-one-modifier validation).

### 3.7 Command palette
- `⌥⌘F` / `⌘⇧P` → fuzzy-searchable list of actions (cmux uses Ghostty's
  `command-palette-entry` schema: `title`, `description`, `action`). Model each as
  `{title, subtitle, action}`. `⌃N`/`⌃P` move selection.

---

## 4. What could NOT be determined

- **Exact pixel metrics / materials:** sidebar default width, row paddings, corner
  radius value, blur radius, active-indicator pixel style — only the *knob names*
  (`_sidebarWidth`, `_sidebarCornerRadius`, `sidebarActiveTabIndicatorStyle`,
  `sidebarMaterial/BlendMode/BlurOpacity`) are visible, not their numeric defaults
  (except tint `#000000` @ `0.03`). Approximate visually.
- **Status-line vocabulary is open-ended:** "Claude is waiting for your input",
  "Needs input", "Running" are **agent-supplied free text** (via `claude-hook` →
  `set_status`/`notify`), confirmed by their absence from the binary. There is **no
  fixed status enum** to replicate; only "merged/open/closed" (PR states) and log
  levels `info/progress/success/warning/error` and notification states are fixed.
- **Bundled keymap defaults file:** no readable JSON/plist of default keybinds was
  found in the bundle (`Assets.car` is compiled; defaults are baked into the binary
  as `_*ShortcutData` blobs). Default values in §2 come from the **docs**, which
  match the binary's id set 1:1 — treat docs as authoritative.
- **Right sidebar / file-explorer + diff details:** confirmed to exist (`⌥⌘B`,
  `⌃⌘⇧D`, vim-scroll keys) but the panel's full layout/columns weren't enumerable
  from strings.
- **`Assets.car` icon inventory:** not decompiled; SF-Symbol-style names appear in
  strings but the exact glyph per status/pill wasn't extracted. Use sensible SF
  Symbols.

### Does a cmux docs URL exist?  **Yes.**
- Primary: **https://cmux.com/docs/keyboard-shortcuts** and
  **https://cmux.com/docs/configuration** (authoritative, used above).
- Mirror: **https://manaflow-ai-cmux.mintlify.app/features/keyboard-shortcuts**.
- DeepWiki: **https://deepwiki.com/manaflow-ai/cmux/5-configuration-system**.
- Repo: **https://github.com/manaflow-ai/cmux** (README, PROJECTS.md, releases).

---

## 5. cmux.json config keys worth mirroring (for our settings schema)

`sidebar.*`: `hideAllDetails`(false) · `wrapWorkspaceTitles`(false) ·
`showWorkspaceDescription`(true) · `branchLayout`("vertical") ·
`showNotificationMessage`(true) · `showBranchDirectory`(true) ·
`showPullRequests`(true) · `watchGitStatus`(true) · `makePullRequestsClickable`(true) ·
`openPullRequestLinksInCmuxBrowser`(true) · `openPortLinksInCmuxBrowser`(true) ·
`showSSH`(true) · `showPorts`(true) · `showLog`(true) · `showProgress`(true) ·
`showCustomMetadata`(true).

`sidebarAppearance.*`: `matchTerminalBackground`(false) · `tintColor`("#000000") ·
`lightModeTintColor`(null) · `darkModeTintColor`(null) · `tintOpacity`(0.03).

`notifications.*`: `dockBadge`(true) · `showInMenuBar`(true) · `unreadPaneRing`(true) ·
`paneFlash`(true) · `sound`("default", 16 presets+custom+none) ·
`customSoundFilePath` · `command` · `hooksMode`("append") · `hooks`([]).

`browser.*`: `defaultSearchEngine`("google", 15+ presets+custom) ·
`showSearchSuggestions`(true) · `theme`("system") · `discardHiddenWebViews`(true) ·
`hiddenWebViewDiscardDelaySeconds`(300) · `openTerminalLinksInCmuxBrowser`(true) ·
`interceptTerminalOpenCommandInCmuxBrowser`(true) · `hostsToOpenInEmbeddedBrowser`([]) ·
`urlsToAlwaysOpenExternally`([]) · `showImportHintOnBlankTabs`(true).

`app.newWorkspacePlacement`("afterCurrent": top|afterCurrent|end) ·
`workspaceGroups.newWorkspacePlacement`("afterCurrent").
`claudeCodeHooksEnabled`(true) — the agent-status integration master switch.
