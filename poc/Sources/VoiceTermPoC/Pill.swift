import AppKit
import SwiftUI

// Aqua-Voice-style floating pill shown while listening: cancel / status dot /
// live waveform / target-session label / stop. Floats over other apps without
// stealing focus.

final class PillModel: ObservableObject {
    enum Phase { case idle, listening, recording, transcribing, sending }
    @Published var phase: Phase = .idle
    @Published var targetLabel = ""
    @Published var targetColor: Color = .cyan
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 40)

    func push(power dbfs: Float) {
        let clamped = max(-60, min(0, dbfs))
        let norm = CGFloat((clamped + 60) / 60)      // -60..0 dB -> 0..1
        levels.removeFirst()
        levels.append(norm * norm)
    }
    func decay() {
        levels = levels.map { $0 * 0.6 }
    }
}

struct WaveformView: View {
    let levels: [CGFloat]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let n = levels.count
            let slot = geo.size.width / CGFloat(n)
            HStack(spacing: slot * 0.35) {
                ForEach(0..<n, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: slot * 0.65, height: max(2, levels[i] * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.linear(duration: 0.05), value: levels)
        }
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    var onCancel: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.plain).foregroundColor(.secondary)
            Circle().fill(statusColor).frame(width: 8, height: 8)
            WaveformView(levels: model.levels, color: model.targetColor)
                .frame(width: 140, height: 22)
            Text(model.targetLabel).font(.system(size: 12, weight: .medium))
                .foregroundColor(model.targetColor).lineLimit(1).frame(maxWidth: 160)
            Button(action: onStop) { Image(systemName: "stop.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.plain).foregroundColor(.red)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(model.targetColor.opacity(0.35), lineWidth: 1))
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle: return .gray
        case .listening: return .cyan
        case .recording: return .red
        case .transcribing: return .yellow
        case .sending: return .green
        }
    }
}

final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PillController {
    let model = PillModel()
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    private let panel: PillPanel

    init() {
        panel = PillPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 44),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let view = PillView(model: model,
                            onCancel: { [weak self] in self?.onCancel?() },
                            onStop: { [weak self] in self?.onStop?() })
        let host = NSHostingView(rootView: view)
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)
    }

    func show() { positionBottomCenter(); panel.orderFrontRegardless() }
    func hide() { model.phase = .idle; panel.orderOut(nil) }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2, y: vf.minY + 56))
    }
}
