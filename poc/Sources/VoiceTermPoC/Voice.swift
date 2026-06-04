import AppKit
import SwiftUI
import AVFoundation
import Carbon.HIToolbox

// Hands-free voice loop, redesigned per docs/research/VOICE_UX.md:
//  - event -> TTS read-out (always, serial)
//  - after TTS, the session goes to an "awaiting reply" queue (NOT auto-recorded),
//    except single-session mode where it auto-listens.
//  - user triggers listen via global hotkey / pill / sidebar chip; one mic at a time.
//  - failures (cancel / no-speech / empty / stopword) requeue the session, never drop it.
//  - floating pill shows state + which session it's for.
final class VoiceCoordinator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoiceCoordinator()
    static let eventsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voiceterm/events")

    struct Pending: Identifiable { let id: UUID; let label: String; let summary: String }

    @Published var status = "待機"
    @Published var autoListenSingle = true       // mode (a): auto-listen only when it's the only pending one
    @Published var pending: [Pending] = []
    @Published var listeningPaneID: UUID?

    weak var session: Session?
    let pill = PillController()

    private var speakQueue: [(pane: UUID, summary: String)] = []
    private var speaking = false
    @Published private(set) var speakingNow = false   // for ⌃S context
    private var ttsPaused = false
    private var player: AVAudioPlayer?
    private var ttsDone: (() -> Void)?

    private var micHolder: UUID?
    private var recorder: AVAudioRecorder?
    private var vadTimer: Timer?
    private var watchTimer: Timer?
    private var speechSeen = false
    private var vadStart = Date()
    private var lastVoice = Date()
    private var currentAudioURL: URL?
    private var dHotKey: HotKey?   // ⌃D global: start next reply (claimed only while pending)
    private var sHotKey: HotKey?   // ⌃S global: pause TTS / finish listen (claimed only while active)

    private let speechThreshold: Float = -38
    private let trailingSilence: TimeInterval = 1.6
    private let noSpeechTimeout: TimeInterval = 8     // requeues, doesn't drop
    private let maxDuration: TimeInterval = 25
    private let tmp = FileManager.default.temporaryDirectory
    private static let palette: [Color] = [.cyan, .green, .orange, .pink, .purple, .yellow, .mint, .teal]

    func start(session: Session) {
        self.session = session
        pill.onCancel = { [weak self] in self?.hotkeyCancel() }
        pill.onStop = { [weak self] in self?.hotkeyStopSend() }
        try? FileManager.default.createDirectory(at: Self.eventsDir, withIntermediateDirectories: true)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    // ⌃D / ⌃S are claimed GLOBALLY (Carbon) only while there's voice work, so
    // they work from any frontmost app yet stay free for terminals otherwise.
    private func updateGlobalHotkeys() {
        let wantD = !pending.isEmpty && micHolder == nil
        if wantD, dHotKey == nil {
            dHotKey = HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey)) { [weak self] in self?.hotkeyListenNext() }
        } else if !wantD, let d = dHotKey { d.invalidate(); dHotKey = nil }

        let wantS = speakingNow || micHolder != nil
        if wantS, sHotKey == nil {
            sHotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey)) { [weak self] in self?.ctrlS() }
        } else if !wantS, let s = sHotKey { s.invalidate(); sHotKey = nil }
    }
    private func ctrlS() {
        if speakingNow { toggleTTSPause() } else if micHolder != nil { stopCurrentListen() }
    }

    // MARK: ingest + TTS
    private func poll() {
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.eventsDir, includingPropertiesForKeys: nil) {
            for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let data = try? Data(contentsOf: f),
                   let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let pid = o["pane"] as? String, let uuid = UUID(uuidString: pid),
                   let summary = o["summary"] as? String {
                    speakQueue.append((uuid, summary))
                }
                try? FileManager.default.removeItem(at: f)
            }
        }
        pumpSpeak()
        updateGlobalHotkeys()
    }

    private func pumpSpeak() {
        guard !speaking, micHolder == nil, !speakQueue.isEmpty else { return }
        let item = speakQueue.removeFirst()
        guard session?.pane(uuid: item.pane.uuidString) != nil else { pumpSpeak(); return }
        speaking = true
        speakingNow = true
        status = "🔊 読み上げ中…"
        speak(item.summary) { [weak self] in
            guard let self = self else { return }
            self.speaking = false
            self.speakingNow = false
            self.ttsPaused = false
            self.didFinishSpeaking(pane: item.pane, summary: item.summary)
            self.pumpSpeak()
        }
    }

    private func didFinishSpeaking(pane: UUID, summary: String) {
        if autoListenSingle && pending.isEmpty && micHolder == nil {
            beginListen(pane)
        } else {
            addPending(pane, summary)
        }
    }

    private func addPending(_ pane: UUID, _ summary: String) {
        guard let p = session?.pane(uuid: pane.uuidString) else { return }
        if !pending.contains(where: { $0.id == pane }) {
            pending.append(Pending(id: pane, label: p.title, summary: String(summary.prefix(40))))
        }
        status = "返信待ち \(pending.count) 件（⌃⌥R で次へ）"
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    // MARK: listen triggers
    func hotkeyListenNext() {
        guard micHolder == nil else { softBeep(); return }
        let pane = pending.first?.id ?? session?.focusedPaneID
        guard let pane = pane else { softBeep(); return }
        pending.removeAll { $0.id == pane }
        beginListen(pane)
    }
    func listenSpecific(_ pane: UUID) {
        guard micHolder == nil else { softBeep(); return }
        pending.removeAll { $0.id == pane }
        beginListen(pane)
    }
    func hotkeyStopSend() { if let p = micHolder { endListen(p, transcribe: true) } }
    func hotkeyCancel()   { if let p = micHolder { endListen(p, transcribe: false) } }

    // ⌃S "escape": pause/resume the read-out, or finish-or-cancel the current listen.
    func toggleTTSPause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); ttsPaused = true; status = "⏸ 読み上げ一時停止（⌃Sで再開）" }
        else { p.play(); ttsPaused = false; status = "🔊 読み上げ中…" }
    }
    func stopCurrentListen() {   // send what you said; if nothing, close without input
        if let p = micHolder { endListen(p, transcribe: speechSeen) }
    }

    private func beginListen(_ pane: UUID) {
        guard let p = session?.pane(uuid: pane.uuidString) else { return }
        micHolder = pane
        listeningPaneID = pane
        session?.focusedPaneID = pane
        pill.model.targetLabel = p.title
        pill.model.targetColor = color(for: pane)
        pill.model.phase = .listening
        pill.show()
        NSSound(named: NSSound.Name("Glass"))?.play()
        status = "🎤 聞いています → \(p.title)"
        startRecorder()
    }

    private func startRecorder() {
        let url = tmp.appendingPathComponent("vt_in.m4a")
        try? FileManager.default.removeItem(at: url)
        currentAudioURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else {
            if let p = micHolder { endListen(p, transcribe: false) }; return
        }
        rec.isMeteringEnabled = true
        rec.record()
        recorder = rec
        speechSeen = false; vadStart = Date(); lastVoice = Date()
        vadTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.vadTick() }
    }

    private func vadTick() {
        guard let rec = recorder, let pane = micHolder else { return }
        rec.updateMeters()
        let power = rec.averagePower(forChannel: 0)
        pill.model.push(power: power)
        let now = Date()
        if power > speechThreshold {
            if !speechSeen { speechSeen = true; pill.model.phase = .recording; status = "🔴 録音中…" }
            lastVoice = now
        }
        let elapsed = now.timeIntervalSince(vadStart)
        if !speechSeen && elapsed > noSpeechTimeout { endListen(pane, transcribe: false) }
        else if speechSeen && now.timeIntervalSince(lastVoice) > trailingSilence { endListen(pane, transcribe: true) }
        else if elapsed > maxDuration { endListen(pane, transcribe: speechSeen) }
    }

    private func endListen(_ pane: UUID, transcribe doIt: Bool) {
        vadTimer?.invalidate(); vadTimer = nil
        recorder?.stop(); recorder = nil
        guard doIt, let url = currentAudioURL else {
            pill.hide(); releaseMic(pane); requeueFront(pane)
            status = "返信待ちに戻しました"; pumpSpeak(); return
        }
        pill.model.phase = .transcribing
        status = "文字起こし中…"
        stt(url) { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let t = text, !t.isEmpty, !self.isStopword(t) {
                    self.pill.model.phase = .sending
                    self.submit(pane, t)
                    self.status = "✓ 送信: \(t)"
                    self.pill.hide(); self.releaseMic(pane)
                } else {
                    self.pill.hide(); self.releaseMic(pane); self.requeueFront(pane)
                    self.status = "（送信なし・返信待ちに戻す）"
                }
                self.pumpSpeak()
            }
        }
    }

    private func releaseMic(_ pane: UUID) {
        if micHolder == pane { micHolder = nil }
        if listeningPaneID == pane { listeningPaneID = nil }
    }
    private func requeueFront(_ pane: UUID) {
        guard let p = session?.pane(uuid: pane.uuidString) else { return }
        if !pending.contains(where: { $0.id == pane }) {
            pending.insert(Pending(id: pane, label: p.title, summary: ""), at: 0)
        }
    }

    private func submit(_ pane: UUID, _ text: String) {
        guard let p = session?.pane(uuid: pane.uuidString) else { return }
        p.send(text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { p.sendEnter() }
    }

    // MARK: TTS
    private func speak(_ text: String, done: @escaping () -> Void) {
        guard let key = apiKey() else { done(); return }
        let mp3 = tmp.appendingPathComponent("vt_tts.mp3")
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts", "voice": "marin", "input": text,
            "instructions": "日本語の短い通知文を、抑揚を抑えたフラットで落ち着いたトーンで、テンポよくやや速めに、はっきり読み上げて。",
            "speed": 1.15, "response_format": "mp3"]
        runCurl(["-sS", "--max-time", "30", "-X", "POST", "https://api.openai.com/v1/audio/speech",
                 "-H", "Authorization: Bearer \(key)", "-H", "Content-Type: application/json",
                 "-d", jsonString(body), "-o", mp3.path]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let pl = try? AVAudioPlayer(contentsOf: mp3) {
                    pl.delegate = self; self.player = pl; self.ttsDone = done; pl.play()
                } else { done() }
            }
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let d = ttsDone; ttsDone = nil; d?()
    }

    // MARK: helpers
    private func color(for pane: UUID) -> Color { Self.palette[abs(pane.hashValue) % Self.palette.count] }
    private func softBeep() { NSSound(named: NSSound.Name("Funk"))?.play() }
    private func apiKey() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/openai.key")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }
    private func jsonString(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    private func runCurl(_ args: [String], done: @escaping (Data) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        p.terminationHandler = { _ in done(out.fileHandleForReading.readDataToEndOfFile()) }
        do { try p.run() } catch { done(Data()) }
    }
    private func stt(_ url: URL, done: @escaping (String?) -> Void) {
        guard let key = apiKey() else { done(nil); return }
        runCurl(["-sS", "--max-time", "60", "-X", "POST", "https://api.openai.com/v1/audio/transcriptions",
                 "-H", "Authorization: Bearer \(key)", "-F", "file=@\(url.path)",
                 "-F", "model=gpt-4o-mini-transcribe", "-F", "language=ja", "-F", "response_format=json"]) { data in
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["text"] as? String {
                done(t.trimmingCharacters(in: .whitespacesAndNewlines))
            } else { done(nil) }
        }
    }
    private func isStopword(_ t: String) -> Bool {
        let n = t.trimmingCharacters(in: CharacterSet(charactersIn: "。、.,!?！？ 　\n"))
        return ["おわり", "終わり", "終了", "ストップ", "キャンセル", "やめて", "なし"].contains(n)
    }
}
