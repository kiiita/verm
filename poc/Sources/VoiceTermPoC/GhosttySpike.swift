import AppKit
import GhosttyTerminal

// De-risking spike: open one standalone window with a libghostty-rendered
// terminal using the `.exec` backend (libghostty spawns the real shell + owns
// the PTY). If this shows a working /bin/zsh, we avoid hosting our own PTY and
// can wire a GhosttyBackend into the pane tree.

private final class GhosttyContainer: NSView {
    let tv: AppTerminalView
    init(_ tv: AppTerminalView) {
        self.tv = tv
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(tv)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        tv.frame = bounds
        tv.fitToSize()
    }
}

private var ghosttyTestWindow: NSWindow?

@MainActor
func openGhosttyTest() {
    let controller = TerminalController { b in
        b.withCustom("command", "/bin/zsh -l")
        b.withBackground("#0d1117")
        b.withForeground("#e6edf3")
    }
    let tv = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
    tv.controller = controller
    tv.configuration = TerminalSurfaceOptions(backend: .exec)

    let container = GhosttyContainer(tv)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable],
                       backing: .buffered, defer: false)
    win.title = "Ghostty (.exec) テスト — zsh が出れば成功"
    win.center()
    win.contentView = container
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(tv)
    NSApp.activate(ignoringOtherApps: true)
    ghosttyTestWindow = win
}
