import SwiftUI
import AppKit
import AVFoundation
import SwiftTerm

// SwiftTerm also exports a `Color`; pin the module's bare `Color` to SwiftUI's.
typealias Color = SwiftUI.Color

// verm — cmux-style UI: workspace sidebar > tabs > tiled split panes, on a
// pluggable terminal backend (libghostty by default). The voice loop lives in
// VoiceCoordinator; a session awaiting a voice reply shows as sidebar status.

// MARK: - Pane (one terminal)

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

// MARK: - Split tree (binary, recursive)

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

// MARK: - Tab (a surface within a workspace) and Workspace (a sidebar row)

final class WSTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var root: LayoutNode
    init(root: LayoutNode) { self.root = root }
}

final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var tabs: [WSTab]
    @Published var activeTabID: UUID
    @Published var zoomed = false
    let accent: Color
    init(firstPane: Pane, title: String, accent: Color) {
        let t = WSTab(root: LayoutNode(pane: firstPane))
        tabs = [t]; activeTabID = t.id; self.title = title; self.accent = accent
    }
    var activeTab: WSTab? { tabs.first { $0.id == activeTabID } }
    func allPanes() -> [Pane] { tabs.flatMap { $0.root.allPanes() } }
    func paneIDs() -> [UUID] { allPanes().map { $0.id } }
    func tabContaining(_ paneID: UUID) -> WSTab? { tabs.first { $0.root.leaf(for: paneID) != nil } }
}

// MARK: - Session controller

final class Session: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var activeWorkspaceID = UUID()
    @Published var sidebarVisible = true
    @Published var useGhostty = true
    @Published var focusedPaneID: UUID? {
        didSet {  // reveal: follow the focused pane into its workspace + tab
            guard let id = focusedPaneID, let w = workspace(ofPane: id) else { return }
            if w.id != activeWorkspaceID { activeWorkspaceID = w.id }
            if let t = w.tabContaining(id), t.id != w.activeTabID { w.activeTabID = t.id; w.objectWillChange.send() }
        }
    }

    private static let palette: [Color] = [.cyan, .green, .orange, .pink, .purple, .yellow, .mint, .teal]
    private var counter = 0
    init() { newWorkspace() }

    var active: Workspace? { workspaces.first { $0.id == activeWorkspaceID } }
    var focusedPane: Pane? {
        guard let id = focusedPaneID else { return nil }
        for w in workspaces { for t in w.tabs { if let n = t.root.leaf(for: id) { return n.pane } } }
        return nil
    }
    func pane(uuid: String) -> Pane? {
        for w in workspaces { for p in w.allPanes() where p.id.uuidString == uuid { return p } }
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
        let w = Workspace(firstPane: p, title: "ws \(counter)", accent: Self.palette[(counter - 1) % Self.palette.count])
        workspaces.append(w)
        activeWorkspaceID = w.id
        focusedPaneID = p.id
        focusSoon(p)
    }
    func newTab() {
        guard let w = active else { return }
        let p = makePane()
        let t = WSTab(root: LayoutNode(pane: p))
        w.tabs.append(t); w.activeTabID = t.id; w.objectWillChange.send()
        focusedPaneID = p.id
        focusSoon(p)
    }
    func selectTab(_ tabID: UUID) {
        guard let w = active else { return }
        w.activeTabID = tabID; w.objectWillChange.send()
        if let t = w.activeTab, let p = t.root.allPanes().first { focusedPaneID = p.id; focusSoon(p) }
    }
    func closeTab(_ tabID: UUID) {
        guard let w = active else { return }
        w.tabs.removeAll { $0.id == tabID }
        if w.tabs.isEmpty { closeWorkspace(w.id); return }
        if w.activeTabID == tabID { w.activeTabID = w.tabs.last!.id }
        w.objectWillChange.send()
        if let t = w.activeTab, let p = t.root.allPanes().first { focusedPaneID = p.id }
    }

    func selectWorkspace(_ id: UUID) {
        activeWorkspaceID = id
        if let w = active, let p = w.activeTab?.root.allPanes().first { focusedPaneID = p.id; focusSoon(p) }
    }
    func selectIndex(_ i: Int) { if i >= 0 && i < workspaces.count { selectWorkspace(workspaces[i].id) } }
    func selectLast() { if let w = workspaces.last { selectWorkspace(w.id) } }
    func nextWorkspace() { guard let i = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }; selectWorkspace(workspaces[(i+1)%workspaces.count].id) }
    func prevWorkspace() { guard let i = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }; selectWorkspace(workspaces[(i-1+workspaces.count)%workspaces.count].id) }
    func closeWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if workspaces.isEmpty { newWorkspace() } else if activeWorkspaceID == id { selectWorkspace(workspaces.last!.id) }
    }

    private func focusedTab() -> (Workspace, WSTab)? {
        if let id = focusedPaneID, let w = workspace(ofPane: id), let t = w.tabContaining(id) { return (w, t) }
        if let w = active, let t = w.activeTab { return (w, t) }
        return nil
    }
    func splitFocused(_ axis: LayoutNode.Axis) {
        guard let fid = focusedPaneID, let (_, t) = focusedTab(), let leaf = t.root.leaf(for: fid), let existing = leaf.pane else { return }
        let np = makePane()
        leaf.pane = nil; leaf.axis = axis
        leaf.first = LayoutNode(pane: existing); leaf.second = LayoutNode(pane: np)
        leaf.objectWillChange.send()
        focusedPaneID = np.id; focusSoon(np)
    }
    func closeFocused() {
        guard let fid = focusedPaneID, let (w, t) = focusedTab(), let leaf = t.root.leaf(for: fid) else { return }
        removeLeaf(leaf, in: t, workspace: w)
    }
    func toggleZoom() { active?.zoomed.toggle(); active?.objectWillChange.send() }
    func cyclePane(_ dir: Int) {
        guard let (_, t) = focusedTab() else { return }
        let panes = t.root.allPanes()
        guard panes.count > 1, let fid = focusedPaneID, let idx = panes.firstIndex(where: { $0.id == fid }) else { return }
        let next = panes[(idx + dir + panes.count) % panes.count]
        focusedPaneID = next.id; focusSoon(next)
    }

    private func handleExit(_ pid: UUID) {
        for w in workspaces { for t in w.tabs where t.root.leaf(for: pid) != nil {
            DispatchQueue.main.async { if let leaf = t.root.leaf(for: pid) { self.removeLeaf(leaf, in: t, workspace: w) } }
            return
        } }
    }
    private func removeLeaf(_ leaf: LayoutNode, in t: WSTab, workspace w: Workspace) {
        if t.root === leaf { closeTab(t.id); return }     // last pane in tab -> close tab
        guard let parent = t.root.parent(of: leaf) else { return }
        let sib = (parent.first === leaf) ? parent.second : parent.first
        guard let s = sib else { return }
        parent.pane = s.pane; parent.axis = s.axis; parent.first = s.first; parent.second = s.second
        parent.objectWillChange.send()
        focusedPaneID = t.root.allPanes().first?.id
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

// MARK: - Tab bar (cmux-style surfaces within a workspace)

struct TabChip: View {
    @ObservedObject var tab: WSTab
    @ObservedObject var titlePane: Pane
    let workspace: Workspace
    @ObservedObject var session: Session
    var isActive: Bool { workspace.activeTabID == tab.id }
    var body: some View {
        HStack(spacing: 6) {
            Text(titlePane.title).lineLimit(1).font(.system(size: 12))
            Button(action: { session.closeTab(tab.id) }) { Image(systemName: "xmark").font(.system(size: 8)) }
                .buttonStyle(.plain).opacity(isActive ? 0.9 : 0.4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 90, maxWidth: 220)
        .background(isActive ? Color.white.opacity(0.10) : Color.clear)
        .overlay(alignment: .bottom) { if isActive { Rectangle().fill(workspace.accent).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { session.selectTab(tab.id) }
    }
}

struct TabBarView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: Session
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        if let p = tab.root.allPanes().first {
                            TabChip(tab: tab, titlePane: p, workspace: workspace, session: session)
                        }
                    }
                    Button(action: { session.newTab() }) { Image(systemName: "plus").font(.system(size: 11)) }
                        .buttonStyle(.plain).padding(.horizontal, 8).help("新規タブ ⌘T")
                }
            }
            Spacer(minLength: 8)
            Button(action: { session.splitFocused(.horizontal) }) { Image(systemName: "rectangle.split.2x1") }
                .buttonStyle(.plain).help("右に分割 ⌘D")
            Button(action: { session.splitFocused(.vertical) }) { Image(systemName: "rectangle.split.1x2") }
                .buttonStyle(.plain).help("下に分割 ⌘⇧D").padding(.leading, 8)
            Button(action: { session.toggleZoom() }) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).help("ズーム ⌘⇧↩").padding(.horizontal, 8)
        }
        .padding(.horizontal, 8).frame(height: 34)
    }
}

// MARK: - Sidebar (workspaces, with voice "返信待ち" status)

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
    private var titleWeight: Font.Weight { isActive ? .semibold : .regular }
    private var statusText: String {
        if isListening { return "🎤 聞き取り中" }
        if needsReply { return "🟠 返信待ち" }
        return ws.allPanes().first?.title ?? "—"
    }

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
                Button(action: micAction) { Image(systemName: "mic.fill").font(.system(size: 10)).foregroundColor(.orange) }
                    .buttonStyle(.plain)
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

// Configures the host NSWindow: transparent titlebar, no title text (cmux-like).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { configure(nsView.window) }
    private func configure(_ win: NSWindow?) {
        guard let win = win else { return }
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.title = ""
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
            workspaceContent
        }
        .frame(minWidth: 900, minHeight: 520)
        .background(WindowConfigurator())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { session.sidebarVisible.toggle() }) { Image(systemName: "sidebar.left") }
                    .help("サイドバー ⌘B")
            }
            ToolbarItem(placement: .navigation) {
                Text(session.active?.title ?? "").font(.system(size: 13, weight: .semibold))
            }
        }
        .onAppear {
            coord.start(session: session)
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in handleKey(ev) ? nil : ev }
            }
        }
    }

    @ViewBuilder private var workspaceContent: some View {
        if let w = session.active {
            VStack(spacing: 0) {
                TabBarView(workspace: w, session: session)
                Divider()
                tabTree(w)
            }
        } else { Color.black }
    }
    @ViewBuilder private func tabTree(_ w: Workspace) -> some View {
        if w.zoomed, let fp = session.focusedPane {
            PaneContainer(pane: fp, session: session)
        } else if let t = w.activeTab {
            NodeView(node: t.root, session: session).id(t.id)
        } else { Color.black }
    }

    private func handleKey(_ ev: NSEvent) -> Bool {
        let m = ev.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = ev.charactersIgnoringModifiers?.lowercased()
        switch true {
        case m == [.command] && ch == "b": session.sidebarVisible.toggle(); return true
        case m == [.command] && ch == "n": session.newWorkspace(); return true
        case m == [.command] && ch == "t": session.newTab(); return true
        case m == [.command] && ch == "d": session.splitFocused(.horizontal); return true
        case m == [.command, .shift] && ch == "d": session.splitFocused(.vertical); return true
        case m == [.command] && ch == "w": session.closeFocused(); return true
        case m == [.command, .control] && ev.keyCode == 30: session.nextWorkspace(); return true   // ⌃⌘]
        case m == [.command, .control] && ev.keyCode == 33: session.prevWorkspace(); return true   // ⌃⌘[
        case m == [.command, .shift] && ev.keyCode == 36: session.toggleZoom(); return true        // ⌘⇧↩
        case m == [.command, .option] && (ev.keyCode == 123 || ev.keyCode == 126): session.cyclePane(-1); return true
        case m == [.command, .option] && (ev.keyCode == 124 || ev.keyCode == 125): session.cyclePane(1); return true
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
        WindowGroup { ContentView() }
    }
}
