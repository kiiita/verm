import AppKit
import SwiftTerm
import GhosttyTerminal

// A pane's terminal is one of two interchangeable backends. The voice loop only
// needs send(text:) + focus/title/exit, so both implement this small protocol.
protocol TermBackend: AnyObject {
    var nsView: NSView { get }
    func sendText(_ s: String)
    func sendEnter()                    // submit (a real Enter, not a literal newline)
    var onTitle: ((String) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
    var onCwd: ((String) -> Void)? { get set }   // working-directory updates (tab title)
}

// MARK: - SwiftTerm backend (pure-Swift, default)

final class SwiftTermBackend: NSObject, TermBackend, LocalProcessTerminalViewDelegate {
    private let term: LocalProcessTerminalView
    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onFocus: (() -> Void)?
    var onCwd: ((String) -> Void)?
    var nsView: NSView { term }
    func sendText(_ s: String) { term.send(txt: s) }
    func sendEnter() { term.send(txt: "\r") }

    init(cwd: String?, paneID: UUID) {
        term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init()
        term.processDelegate = self
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        click.delaysPrimaryMouseButtonEvents = false
        term.addGestureRecognizer(click)
        var env: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment where k != "TERM" { env.append("\(k)=\(v)") }
        env.append("TERM=xterm-256color")
        env.append("VOICETERM_PANE=\(paneID.uuidString)")
        env.append("VOICETERM_EVENTS=\(VoiceCoordinator.eventsDir.path)")
        term.startProcess(executable: "/bin/zsh", args: ["-l"], environment: env, currentDirectory: cwd)
    }
    @objc private func handleClick() { onFocus?() }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle?(title.isEmpty ? "zsh" : title) }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        if let d = directory { onCwd?(d) }
    }
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) { onExit?() }
}

// MARK: - libghostty backend (.exec: GPU rendering, libghostty owns the PTY)

final class GhosttyBackend: NSObject, TermBackend, TerminalSurfaceViewDelegate {
    private let view: AppTerminalView
    private let controller: TerminalController
    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onFocus: (() -> Void)?
    var onCwd: ((String) -> Void)?
    var nsView: NSView { view }
    func sendText(_ s: String) { view.sendText(s) }
    // libghostty treats sendText("\r") as a literal newline, so submit by
    // synthesizing a real Return key event (-> ghostty_surface_key).
    func sendEnter() {
        let ev = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)
        if let ev = ev { view.keyDown(with: ev) } else { view.sendText("\r") }
    }

    // A wrapper ZDOTDIR that loads the user's real zsh config, then adds a precmd
    // emitting OSC 0 (title) = current-directory name -> Ghostty's title delegate
    // -> tab title. (The trimmed libghostty doesn't inject Ghostty's own shell
    // integration, so we drive the cwd->title ourselves.)
    private static var zdotReady = false
    static func setupZDotDir() -> String {
        let home = NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(".voiceterm/zdotdir")
        if zdotReady { return dir }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func w(_ name: String, _ s: String) {
            try? s.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        w(".zshenv", "[ -f \"$VERM_REAL_ZDOTDIR/.zshenv\" ] && source \"$VERM_REAL_ZDOTDIR/.zshenv\"\n")
        w(".zprofile", "[ -f \"$VERM_REAL_ZDOTDIR/.zprofile\" ] && source \"$VERM_REAL_ZDOTDIR/.zprofile\"\n")
        w(".zlogin", "[ -f \"$VERM_REAL_ZDOTDIR/.zlogin\" ] && source \"$VERM_REAL_ZDOTDIR/.zlogin\"\n")
        w(".zshrc",
          "[ -f \"$VERM_REAL_ZDOTDIR/.zshrc\" ] && source \"$VERM_REAL_ZDOTDIR/.zshrc\"\n" +
          "_verm_title() { print -Pn \"\\e]0;${PWD:t}\\a\" }\n" +
          "typeset -ag precmd_functions\n" +
          "precmd_functions+=(_verm_title)\n_verm_title\n")
        zdotReady = true
        return dir
    }

    init(cwd: String?, paneID: UUID) {
        let events = VoiceCoordinator.eventsDir.path
        let zdir = GhosttyBackend.setupZDotDir()
        let real = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()
        let c = TerminalController { b in
            b.withCustom("command", "/bin/zsh -l")
            b.withCustom("env", "ZDOTDIR=\(zdir)")
            b.withCustom("env", "VERM_REAL_ZDOTDIR=\(real)")
            b.withCustom("env", "VOICETERM_PANE=\(paneID.uuidString)")
            b.withCustom("env", "VOICETERM_EVENTS=\(events)")
            if let cwd = cwd { b.withCustom("working-directory", cwd) }
            b.withBackground("#0d1117")
            b.withForeground("#e6edf3")
        }
        controller = c
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init()
        view.controller = c
        view.configuration = TerminalSurfaceOptions(backend: .exec)
        view.delegate = self
    }
    func terminalDidChangeTitle(_ title: String) { onTitle?(title.isEmpty ? "zsh" : title) }
    func terminalDidChangeFocus(_ focused: Bool) { if focused { onFocus?() } }
    func terminalDidClose(processAlive: Bool) { onExit?() }
    func terminalDidChangeWorkingDirectory(_ path: String) { onCwd?(path) }
}
