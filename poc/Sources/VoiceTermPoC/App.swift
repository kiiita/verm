import SwiftUI
import AppKit
import AVFoundation
import SwiftTerm

// SwiftTerm also exports a `Color` type, so bare `Color` is ambiguous in files
// that import both. Pin the module's `Color` to SwiftUI's.
typealias Color = SwiftUI.Color

// VoiceTerm — cmux-style UI (left workspace sidebar + tiled split panes + cmux
// keyboard shortcuts) on SwiftTerm, with the voice loop integrated: a session
// awaiting a voice reply surfaces as a "返信待ち" status in the sidebar (cmux's
// "Needs input" analogue).

// MARK: - Pane (one terminal, SwiftTerm or libghostty backend)

final class Pane: ObservableObject, Identifiable {
    let id = UUID()
    let backend: TermBackend
    @Published var title = "zsh"
    var onFocus: ((UUID) -> Void)?
    var onExit: ((UUID) -> Void)?
    var term: NSView { backend.nsView }

    init(cwd: String?, ghostty: Bool) {
        let pid = id
        backend = MainActor.assumeIsolated { () -> TermBackend in
            if ghostty { return GhosttyBackend(cwd: cwd, paneID: pid) }
            return SwiftTermBackend(cwd: cwd, paneID: pid)
        }
        backend.onTitle = { [weak self] t in self?.title = t }
        backend.onFocus = { [weak self] in guard let s = self else { return }; s.onFocus?(s.id) }
        backend.onExit = { [weak self] in guard let s = self else { return }; s.onExit?(s.id) }
    }
    func send(text: String) { backend.sendText(text) }
    func sendEnter() { backend.sendEnter() }
}

// MARK: - Layout tree (binary, recursive)

final class LayoutNode: ObservableObject, Identifiable {
    enum Axis { case horizontal, vertical }
    let id = UUID()
    @Published var pane: Pane?
    @Published var axis: Axis = .horizontal
    @Published var first: LayoutNode?
    @Published var second: LayoutNode?
    var isLeaf: Bool { pane != nil }
    init(pane: Pane) { self.pane = pane }
    func leaf(for paneID: UUID) -> LayoutNode? {
        if let p = pane { return p.id == paneID ? self : nil }
        return first?.leaf(for: paneID) ?? second?.leaf(for: paneID)
    }
    func parent(of child: LayoutNode) -> LayoutNode? {
        if first === child || second === child { return self }
        return first?.parent(of: child) ?? second?.parent(of: child)
    }
    func allPanes() -> [Pane] {
        if let p = pane { return [p] }
        return (first?.allPanes() ?? []) + (second?.allPanes() ?? [])
    }
}

// MARK: - Workspace (a sidebar row; holds a split tree)

final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var root: LayoutNode
    @Published var zoomed = false
    let accent: Color
    init(root: LayoutNode, title: String, accent: Color) { self.root = root; self.title = title; self.accent = accent }
    func paneIDs() -> [UUID] { root.allPanes().map { $0.id } }
}

// MARK: - Session controller

final class Session: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var activeWorkspaceID = UUID()
    @Published var sidebarVisible = true
    @Published var useGhostty = false      // backend for newly created panes
    @Published var focusedPaneID: UUID? {
        didSet {  // keep the active workspace following the focused pane (reveal)
            if let id = focusedPaneID, let w = workspace(ofPane: id), w.id != activeWorkspaceID {
                activeWorkspaceID = w.id
            }
        }
    }

    private static let palette: [Color] = [.cyan, .green, .orange, .pink, .purple, .yellow, .mint, .teal]
    private var counter = 0

    init() { newWorkspace() }

    var active: Workspace? { workspaces.first { $0.id == activeWorkspaceID } }
    var focusedPane: Pane? {
        guard let id = focusedPaneID else { return nil }
        for w in workspaces { if let n = w.root.leaf(for: id) { return n.pane } }
        return nil
    }
    func pane(uuid: String) -> Pane? {
        for w in workspaces { for p in w.root.allPanes() where p.id.uuidString == uuid { return p } }
        return nil
    }
    func workspace(ofPane id: UUID) -> Workspace? { workspaces.first { $0.paneIDs().contains(id) } }

    private func makePane() -> Pane {
        let p = Pane(cwd: nil, ghostty: useGhostty)
        p.onFocus = { [weak self] pid in self?.focusedPaneID = pid }
        p.onExit = { [weak self] pid in self?.handleExit(pid) }
        return p
    }
    func newWorkspace() {
        counter += 1
        let p = makePane()
        let w = Workspace(root: LayoutNode(pane: p), title: "ws \(counter)",
                          accent: Self.palette[(counter - 1) % Self.palette.count])
        workspaces.append(w)
        activeWorkspaceID = w.id
        focusedPaneID = p.id
        focusSoon(p)
    }
    func selectWorkspace(_ id: UUID) {
        activeWorkspaceID = id
        if let w = active, let p = w.root.allPanes().first { focusedPaneID = p.id; focusSoon(p) }
    }
    func selectIndex(_ i: Int) { if i >= 0 && i < workspaces.count { selectWorkspace(workspaces[i].id) } }
    func selectLast() { if let w = workspaces.last { selectWorkspace(w.id) } }
    func nextWorkspace() {
        guard let i = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }
        selectWorkspace(workspaces[(i + 1) % workspaces.count].id)
    }
    func prevWorkspace() {
        guard let i = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }
        selectWorkspace(workspaces[(i - 1 + workspaces.count) % workspaces.count].id)
    }

    func splitFocused(_ axis: LayoutNode.Axis) {
        guard let w = active, let fid = focusedPaneID, let leaf = w.root.leaf(for: fid), let existing = leaf.pane else { return }
        let np = makePane()
        leaf.pane = nil; leaf.axis = axis
        leaf.first = LayoutNode(pane: existing); leaf.second = LayoutNode(pane: np)
        leaf.objectWillChange.send()
        focusedPaneID = np.id; focusSoon(np)
    }
    func closeFocused() {
        guard let w = active, let fid = focusedPaneID, let leaf = w.root.leaf(for: fid) else { return }
        removeLeaf(leaf, in: w)
    }
    func toggleZoom() { active?.zoomed.toggle(); active?.objectWillChange.send() }
    func cyclePane(_ dir: Int) {
        guard let w = active else { return }
        let panes = w.root.allPanes()
        guard panes.count > 1, let fid = focusedPaneID, let idx = panes.firstIndex(where: { $0.id == fid }) else { return }
        let next = panes[(idx + dir + panes.count) % panes.count]
        focusedPaneID = next.id; focusSoon(next)
    }

    private func handleExit(_ pid: UUID) {
        for w in workspaces where w.root.leaf(for: pid) != nil {
            if let leaf = w.root.leaf(for: pid) { DispatchQueue.main.async { self.removeLeaf(leaf, in: w) } }
            return
        }
    }
    private func removeLeaf(_ leaf: LayoutNode, in w: Workspace) {
        if w.root === leaf {
            workspaces.removeAll { $0.id == w.id }
            if workspaces.isEmpty { newWorkspace() } else { selectWorkspace(workspaces.last!.id) }
            return
        }
        guard let parent = w.root.parent(of: leaf) else { return }
        let sib = (parent.first === leaf) ? parent.second : parent.first
        guard let s = sib else { return }
        parent.pane = s.pane; parent.axis = s.axis; parent.first = s.first; parent.second = s.second
        parent.objectWillChange.send()
        focusedPaneID = parent.allPanes().first?.id
        if let p = focusedPane { focusSoon(p) }
    }
    private func focusSoon(_ p: Pane) { DispatchQueue.main.async { p.term.window?.makeFirstResponder(p.term) } }
}

// MARK: - Pane / split views

struct TerminalRepresentable: NSViewRepresentable {
    let pane: Pane
    func makeNSView(context: Context) -> NSView { pane.backend.nsView }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PaneContainer: View {
    @ObservedObject var pane: Pane
    @ObservedObject var session: Session
    var body: some View {
        TerminalRepresentable(pane: pane)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(session.focusedPaneID == pane.id ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}

struct NodeView: View {
    @ObservedObject var node: LayoutNode
    let session: Session
    var body: some View {
        if node.isLeaf, let pane = node.pane {
            PaneContainer(pane: pane, session: session)
        } else if let f = node.first, let s = node.second {
            if node.axis == .horizontal {
                HSplitView { NodeView(node: f, session: session); NodeView(node: s, session: session) }
            } else {
                VSplitView { NodeView(node: f, session: session); NodeView(node: s, session: session) }
            }
        }
    }
}

// MARK: - Sidebar (cmux-style workspace list, with voice "返信待ち" status)

struct WorkspaceRow: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var session: Session
    @ObservedObject var coord = VoiceCoordinator.shared
    let index: Int

    private var accent: Color { ws.accent }
    private var isActive: Bool { session.activeWorkspaceID == ws.id }
    private var paneIDs: Set<UUID> { Set(ws.paneIDs()) }
    private var isListening: Bool { if let l = coord.listeningPaneID { return paneIDs.contains(l) }; return false }
    private var needsReply: Bool { coord.pending.contains { paneIDs.contains($0.id) } }
    private var statusColor: Color { needsReply ? .orange : (isListening ? .cyan : .secondary) }
    private var bg: Color { isActive ? accent.opacity(0.16) : Color.clear }
    private var statusText: String {
        if isListening { return "🎤 聞き取り中" }
        if needsReply { return "🟠 返信待ち" }
        return ws.root.allPanes().first?.title ?? "—"
    }
    private var titleWeight: Font.Weight { isActive ? .semibold : .regular }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index < 9 ? "⌘\(index + 1)" : "")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(ws.title).font(.system(size: 12, weight: titleWeight)).lineLimit(1)
                }
                Text(statusText).font(.system(size: 10)).foregroundColor(statusColor).lineLimit(1)
            }
            Spacer(minLength: 0)
            if needsReply {
                Button(action: micAction) {
                    Image(systemName: "mic.fill").font(.system(size: 10)).foregroundColor(.orange)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(bg)
        .overlay(alignment: .leading) { if isActive { Rectangle().fill(accent).frame(width: 3) } }
        .contentShape(Rectangle())
        .onTapGesture { session.selectWorkspace(ws.id) }
    }

    private func micAction() {
        if let id = coord.pending.first(where: { paneIDs.contains($0.id) })?.id { coord.listenSpecific(id) }
    }
}

struct Sidebar: View {
    @ObservedObject var session: Session
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WORKSPACES").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button(action: { session.newWorkspace() }) { Image(systemName: "plus") }.buttonStyle(.plain)
            }.padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.workspaces.enumerated()), id: \.element.id) { i, ws in
                        WorkspaceRow(ws: ws, session: session, index: i)
                    }
                }
            }
        }
        .frame(width: 224)
        .background(.regularMaterial)
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject var session = Session()
    @ObservedObject var coord = VoiceCoordinator.shared
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            if session.sidebarVisible { Sidebar(session: session); Divider() }
            VStack(spacing: 0) {
                controlBar
                Divider()
                content
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .onAppear {
            coord.start(session: session)
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                    handleKey(ev) ? nil : ev
                }
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button(action: { session.sidebarVisible.toggle() }) { Image(systemName: "sidebar.left") }
                .help("サイドバー ⌘B")
            Divider().frame(height: 16)
            Button("分割 |") { session.splitFocused(.horizontal) }.help("⌘D")
            Button("分割 —") { session.splitFocused(.vertical) }.help("⌘⇧D")
            Button("ズーム") { session.toggleZoom() }.help("⌘⇧↩")
            Toggle("Ghostty", isOn: $session.useGhostty).toggleStyle(.switch).help("新規ペインを libghostty で起動")
            Divider().frame(height: 16)
            Toggle("単独時自動", isOn: $coord.autoListenSingle).toggleStyle(.switch)
            Button("🎤 聞く") { coord.hotkeyListenNext() }.help("⌃⌥R（グローバル）")
            Text(coord.status).foregroundColor(.cyan).lineLimit(1)
            Spacer()
            Button("🅖 Ghostty試") { openGhosttyTest() }.help("libghostty .exec スパイク")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        if let w = session.active {
            if w.zoomed, let fp = session.focusedPane {
                PaneContainer(pane: fp, session: session)
            } else {
                NodeView(node: w.root, session: session).id(w.id)
            }
        } else { Color.black }
    }

    // cmux-style keybindings (all use ⌘, so terminal text input passes through).
    private func handleKey(_ ev: NSEvent) -> Bool {
        let m = ev.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = ev.charactersIgnoringModifiers?.lowercased()
        switch true {
        case m == [.command] && ch == "b": session.sidebarVisible.toggle(); return true
        case m == [.command] && ch == "n": session.newWorkspace(); return true
        case m == [.command] && ch == "d": session.splitFocused(.horizontal); return true
        case m == [.command, .shift] && ch == "d": session.splitFocused(.vertical); return true
        case m == [.command] && ch == "w": session.closeFocused(); return true
        case m == [.command, .control] && ev.keyCode == 30: session.nextWorkspace(); return true   // ⌃⌘]
        case m == [.command, .control] && ev.keyCode == 33: session.prevWorkspace(); return true   // ⌃⌘[
        case m == [.command, .shift] && ev.keyCode == 36: session.toggleZoom(); return true        // ⌘⇧↩
        case m == [.command, .option] && (ev.keyCode == 123 || ev.keyCode == 126): session.cyclePane(-1); return true // ⌥⌘←/↑
        case m == [.command, .option] && (ev.keyCode == 124 || ev.keyCode == 125): session.cyclePane(1); return true  // ⌥⌘→/↓
        case m == [.control] && ev.keyCode == 2:   // ⌃D — voice: start next pending reply; else pass to terminal (EOF)
            if coord.listeningPaneID == nil && !coord.pending.isEmpty { coord.hotkeyListenNext(); return true }
            return false
        case m == [.control] && ev.keyCode == 1:   // ⌃S — voice escape: pause TTS / finish-or-cancel listen; else pass through
            if coord.speakingNow { coord.toggleTTSPause(); return true }
            if coord.listeningPaneID != nil { coord.stopCurrentListen(); return true }
            return false
        case m == [.command]:
            if let c = ch, let d = Int(c), d >= 1 && d <= 9 {
                if d == 9 { session.selectLast() } else { session.selectIndex(d - 1) }
                return true
            }
            return false
        default: return false
        }
    }
}

@main
struct VoiceTermApp: App {
    var body: some Scene {
        WindowGroup("VoiceTerm") { ContentView() }
    }
}
