# 音声入力 UX 設計 — Aqua Voice 風フローティング・ピル + 並列セッション「声で返信」モデル

- 作成日: 2026-06-03
- 著者: Claude Code（北國さんとのセッションより）
- ステータス: 設計ドラフト（実装前。`poc/Sources/VoiceTermPoC/App.swift` の `VoiceLoop` を置き換える指針）
- 位置づけ: 現状の「TTS 直後に **無条件で自動聞き取り（VAD・30s タイムアウト）**」を、Aqua Voice 流の **可視ピル + ユーザー主導（ホットキー）の聞き取り** に作り替えるための UX/技術設計。`App.swift` は本書では変更しない。

> 本書のスコープ: (1) フローティング・ピル（NSPanel）、(2) グローバルホットキー、(3)「needs-input キュー + ユーザー主導 listen」のステートマシンと `VoiceLoop` リファクタ、(4) 既定値（いつ自動 listen するか / タイムアウト）。

---

## 0. 設計の出発点 — 今の挙動と、変えたい理由

### 今（`VoiceLoop`）
```
イベント(.json) → FIFO queue → pump():
  busy=true → focus 移動 → speak(summary) → [enabled なら] listen(pane) で即録音
  listen: VAD（speech 検知→1.8s 無音で停止 / 30s 無発話で打ち切り）→ STT → submit → finishLoop → 次へ
```
- **1 マイク直列**は `busy` フラグ + FIFO で既に担保されている（良い）。
- 問題は「**読み上げ終わった瞬間に必ず録音が始まる**」こと。北國さんのワークフローは 3–4 並列で、**今すぐ返せないことが多い**。今の設計だと：
  - 返せないセッションでも 30s マイクを占有し、その間ほかの完了セッションは待たされる。
  - 無音タイムアウトで「打ち切り」扱いになり、後で返したくても**もう一度トリガする導線がない**。
  - どのセッションに対して喋っているのか、画面上の保証（可視性）が弱い（control bar の文字列だけ）。

### 変えること（本設計の核）
1. **TTS と listen を分離する。** 読み上げは即時・自動。**listen は自動で始めない**（既定）。完了セッションは「**返信待ち (awaiting reply)**」としてキュー/サイドバーに積まれる。
2. ユーザーが **いつ・どのセッションに返すかを選ぶ**。グローバルホットキー一発で「次の返信待ちセッション」に対して listen を開始（cmux の "Needs input" を声で消化するイメージ）。
3. listen 中は **Aqua Voice 風のフローティング・ピル**を画面下中央に常時表示。**どのセッション宛てか**をピル上に明示。X（キャンセル）/ 波形 / ■（確定送信）。
4. 開始/停止/キャンセルは **アプリが非フォーカスでも効くグローバルホットキー**で。ピル上のボタンでも可。

### Aqua Voice から踏襲する点（guide 確認事項）
- **アクティベーションキーはグローバル**で、「**NOT bubble down to your active application**」（前面アプリにイベントを渡さない）。→ 我々も**グローバル捕捉 + イベント消費**にする。
- **アクティベーションキーは複数登録可（最大 5）**。→ ホットキーは設定で差し替え/複数可にする余地を残す。
- 整形済みテキストを**フォーカス中のフィールドへ流し込む**。→ 我々は「フォーカス欄」ではなく「**宛先ペイン（送信元セッション）**」へ送る点が違う（ナビゲーション不要が要件の核）。
- **History**（過去の文字起こし一覧）がある。→ 失敗・空認識のリカバリとして後述の「直近 transcript の再送」に活かす。

---

## 1. フローティング・ピル（NSPanel）

### 1.1 見た目 / レイアウト

画面**下中央**、デスクトップ最前面に浮く角丸ピル（Aqua Voice 準拠）。左→右で：

```
┌─────────────────────────────────────────────────────────┐
│  ⊗   ●  ▁▂▅▇▆▃▁▂▄▇▅▂▁   「pane: claude (api-fix)」   ■  │
│  X  dot   live waveform        宛先ラベル            STOP │
└─────────────────────────────────────────────────────────┘
   cancel status   audio levels                        send
```
- **⊗ キャンセル (左)**: 録音破棄。何も送らない。赤グレーの細いリング。
- **● ステータスドット**: 状態色。`idle`=グレー / `listening(無発話)`=シアン点滅 / `recording(発話中)`=赤 / `transcribing`=黄 スピナ / `sending`=緑。
- **波形 (中央)**: マイクレベル駆動のライブ波形（後述）。本ピルの主役。`recording` 中のみ振幅が伸びる。
- **宛先ラベル**: **どのセッション宛てか**（ペインタイトル + タブ名）。要件の核「探さず・移動せず」を視覚で担保。色 = そのセッションのアクセント色（タブと一致）。
- **■ 確定送信 (右)**: 今すぐ録音を終えて STT→送信。赤丸ボタン。

サイズの目安: 幅 360–460pt（宛先ラベル長で可変）、高さ 44pt、角丸 22pt、マテリアル背景（`.hudWindow` / `NSVisualEffectView`）。下端から 56pt 上、水平中央。

### 1.2 NSPanel の要件（非アクティブ化・最前面・ボーダレス）

ピルは「**前面アプリのフォーカスを奪わない**」ことが最重要。クリックしても VoiceTerm 本体や前面アプリがアクティブにならないよう、**non-activating panel** にする。

```swift
import AppKit
import SwiftUI

final class PillPanel: NSPanel {
    // キー/メインにならないが、ボタンクリックは受ける
    override var canBecomeKey: Bool { true }   // ボタン操作のため key は許可
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PillController {
    private let panel: PillPanel
    let model: PillModel               // ObservableObject（状態・レベル）

    init(model: PillModel) {
        self.model = model
        panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],   // ← フォーカスを奪わない
            backing: .buffered, defer: false)

        panel.isFloatingPanel = true
        panel.level = .statusBar                    // 常に最前面（.floating でも可）
        panel.collectionBehavior = [.canJoinAllSpaces,    // 全 Space に出す
                                    .fullScreenAuxiliary, // 他アプリの全画面上にも出す
                                    .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false             // VoiceTerm が背面でも消さない
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false            // ボタンは押せる

        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)
    }

    func show() { positionBottomCenter(); panel.orderFrontRegardless() } // activate せず前面へ
    func hide() { panel.orderOut(nil) }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.minY + 56
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

要点:
- `.nonactivatingPanel` + `orderFrontRegardless()`: VoiceTerm をフォアグラウンドにせずに表示。前面アプリ（ブラウザ等）で作業中でもピルだけ浮く。
- `level = .statusBar`、`collectionBehavior` に `.canJoinAllSpaces` / `.fullScreenAuxiliary`: 全 Space・他アプリ全画面の上にも出る（cmux/Aqua と同じ常時可視性）。
- `hidesOnDeactivate = false`: VoiceTerm が裏に回っても消えない。
- ボタンを押す瞬間だけ panel が key になるが `canBecomeMain=false` なので**前面アプリのフォーカスは事実上保持**（厳密にフォーカス保持が要るならボタン操作も全部ホットキー側で受ける）。

### 1.3 ライブ波形（オーディオレベル駆動）

PoC の `AVAudioRecorder.updateMeters()`/`averagePower(forChannel:)` を**そのまま流用**できる。0.05s 周期でレベルをサンプリングし、リングバッファに積んで SwiftUI Canvas/Shape で描く。

```swift
@MainActor
final class PillModel: ObservableObject {
    enum Phase { case idle, listening, recording, transcribing, sending }
    @Published var phase: Phase = .idle
    @Published var targetLabel: String = ""        // "claude (api-fix)"
    @Published var targetColor: Color = .cyan
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 48)  // 0...1 リングバッファ
    @Published var transcript: String = ""         // 途中/確定テキスト（任意表示）

    func push(power dbfs: Float) {                  // averagePower(forChannel:)
        let clamped = max(-60, min(0, dbfs))
        let norm = CGFloat((clamped + 60) / 60)     // -60..0 dB → 0..1
        levels.removeFirst()
        levels.append(norm * norm)                  // 体感に合わせ軽く非線形
    }
}

struct WaveformView: View {
    let levels: [CGFloat]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = levels.count
            let bar = w / CGFloat(n) * 0.6, gap = w / CGFloat(n) * 0.4
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: bar, height: max(2, levels[i] * h))
                }
            }
            .frame(width: w, height: h)
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
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundColor(.secondary)
            Circle().fill(statusColor).frame(width: 8, height: 8)
                .opacity(model.phase == .listening ? blink : 1)
            WaveformView(levels: model.levels, color: model.targetColor)
                .frame(width: 150, height: 22)
            Text(model.targetLabel).font(.system(size: 12, weight: .medium))
                .foregroundColor(model.targetColor).lineLimit(1)
            Button(action: onStop) { Image(systemName: "stop.circle.fill") }
                .buttonStyle(.plain).foregroundColor(.red)
                .opacity(model.phase == .recording || model.phase == .listening ? 1 : 0.4)
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
    private var blink: Double { 0.5 }   // 実際は TimelineView 等で点滅
}
```

> 波形の駆動元: `listen()` 内の VAD タイマー（0.1s）を 0.05s に上げ、`rec.updateMeters()` の後に `pillModel.push(power:)` を呼ぶだけ。録音停止中（`idle/transcribing/sending`）は `push` を止めて波形を 0 に減衰させる。

---

## 2. グローバルホットキー（アプリ非フォーカスでも効く）

### 2.1 3 つの選択肢と評価

| 方式 | API | 前面アプリへ「渡さない」 | TCC（権限） | 採否 |
|---|---|---|---|---|
| **Carbon `RegisterEventHotKey`** | Carbon `EventHotKey` | **渡さない**（システムレベルで消費） | **不要**（Accessibility/Input Monitoring 不要） | **採用（主）** |
| `NSEvent.addGlobalMonitorForEvents` | AppKit | **渡せない（観測のみ／消費不可）** | **Input Monitoring が必要**になりがち | 不採用（消費できない） |
| CGEventTap | CoreGraphics | 渡さない（消費可） | **Accessibility 必須** + 重い | 不採用（過剰） |
| `NSEvent.addLocalMonitorForEvents` | AppKit | アプリ内のみ | 不要 | **補助**（フォーカス時のピル操作用） |

**結論: 主役は Carbon `RegisterEventHotKey`。** 理由:
- Aqua Voice と同じ「**前面アプリにイベントを bubble down させない**（グローバルで消費）」が、**追加の TCC 権限なしで**実現できる唯一の軽量手段。`addGlobalMonitorForEvents` は**観測専用で消費できない**ため、押下が前面アプリにも届いてしまい不可。CGEventTap は消費可能だが **Accessibility 権限**が要り、起動体験が重くなる（cmux も Carbon を採用しているのは otool で確認済み）。
- cmux 解析でも「グローバル入力 = **Carbon**」。先行例として妥当。

注意点:
- Carbon API は deprecated 表示が出るが**現役で動作**（多くの主要アプリが利用）。`Carbon.framework` をリンク。
- ホットキーは**システム/他アプリと衝突しない**組み合わせにする（後述の既定値）。Aqua の Ctrl+F は我々の既定では避ける（後述）。
- 設定で**複数キー登録可**（Aqua 同様）にする余地を残す。各キーごとに `RegisterEventHotKey` を呼ぶだけ。

### 2.2 コードスケッチ（Carbon ホットキー薄ラッパ）

```swift
import Carbon.HIToolbox
import AppKit

final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: EventHotKeyID
    private let handler: () -> Void
    private static var registry: [UInt32: HotKey] = [:]
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, signature: OSType, idNum: UInt32, _ handler: @escaping () -> Void) {
        self.handler = handler
        self.id = EventHotKeyID(signature: signature, id: idNum)
        HotKey.installHandlerIfNeeded()
        HotKey.registry[idNum] = self
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
    deinit { if let r = ref { UnregisterEventHotKey(r) } }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { HotKey.registry[hkID.id]?.handler() }
            return noErr           // ← 消費（前面アプリに渡さない）
        }, 1, &spec, nil, nil)
    }
}

// 使用例（modifiers は cmdKey/optionKey/controlKey/shiftKey の OR）
let sig: OSType = 0x56544B59 // 'VTKY'
let hkListen = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), signature: sig, idNum: 1) {
    VoiceCoordinator.shared.hotkeyListenNext()
}
let hkStop   = HotKey(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey | optionKey), signature: sig, idNum: 2) {
    VoiceCoordinator.shared.hotkeyStopSend()
}
let hkCancel = HotKey(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey | optionKey), signature: sig, idNum: 3) {
    VoiceCoordinator.shared.hotkeyCancel()
}
```

補助（フォーカス時のみ・ピル上の素早い Esc 等）には `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` を併用してよい（TCC 不要）。

### 2.3 TCC / 権限まとめ
- **マイク (`NSMicrophoneUsageDescription`)**: 必須。PoC の `VoiceTerm.app` には既に宣言あり（壁A はネイティブ化で解決済み）。`AVCaptureDevice.requestAccess(for: .audio)` を起動時に。
- **Carbon ホットキー**: **Accessibility も Input Monitoring も不要**。これが採用理由の中核。
- **CGEventTap を使う場合のみ** Accessibility（`AXIsProcessTrusted`）が必要 → 今回は使わない。
- ピル NSPanel 自体に追加権限は不要。

---

## 3. ステートマシン:「needs-input キュー + ユーザー主導 listen」

### 3.1 セッション単位の状態

各「Claude セッション（= 宛先ペイン）」が独立した状態を持つ。**全体で listen は同時に 1 つだけ**（1 マイク・アービタ）。

```swift
enum SessionVoiceState {
    case idle                 // 何もしていない
    case speaking             // この pane の summary を TTS 読み上げ中
    case awaitingReply        // ★読み上げ済み・返信待ち（キュー/サイドバーに出る）
    case listening            // ★今この pane に対して録音中（全体で同時 1 つ）
    case transcribing
    case sending
}
```

遷移:
```
イベント受信
   └→ speak(summary)        [speaking]
        └→ TTS 終了
             ├─(autoListen 条件成立)→ tryListen(pane)     // 後述の既定。通常はここに来ない
             └─(既定)──────────────→ awaitingReply        // ★キューに積む + そっと通知

awaitingReply の pane に対して、ユーザーがホットキー / サイドバークリック:
   listenNext() / listen(pane) → アービタ取得できれば [listening]

[listening]
   ├ STOP(ホットキー/■)            → [transcribing] → STT
   │      ├ 空 or stopword         → awaitingReply に戻す（再挑戦できる）★
   │      └ テキストあり           → [sending] submit→Enter → idle、アービタ解放→次へ
   ├ CANCEL(ホットキー/⊗)         → 破棄 → awaitingReply に戻す ★
   └ 無発話タイムアウト(短め)       → 破棄 → awaitingReply に戻す ★（打ち切り≠消滅）
```

**今との最大の違い**: 「無発話 → 打ち切り」が**セッションを消す**のではなく **`awaitingReply` に戻す**。後でいつでも再トリガできる（cmux の "Needs input" が消えないのと同じ）。

### 3.2 1 マイク・アービタ

```swift
@MainActor
final class MicArbiter {
    private(set) var holder: UUID?           // listening 中の paneID
    func tryAcquire(_ pane: UUID) -> Bool { if holder == nil { holder = pane; return true }; return false }
    func release(_ pane: UUID) { if holder == pane { holder = nil } }
    var isBusy: Bool { holder != nil }
}
```
- TTS（出力）は**並列で複数走らせない**点は今と同じ（キューで直列）。ただし **TTS と listen は別物**にし、listen 占有のみアービタで管理。
- ユーザーが listen 中に別セッションのホットキーを押しても **`isBusy` で弾く**（または「現在のを確定して次へ」のオプション。既定は弾く + 軽い beep）。

### 3.3 UI: 返信待ちサイドバー / キュー（cmux "Needs input" 相当）

- 右サイドバー or タブバー上に「**返信待ち (N)**」リスト。各行 = 宛先ラベル + summary 先頭 + 待ち時間 + アクセント色ドット。
- 行クリック = そのセッションへ即 listen（= `listen(pane)`）。**ナビゲーション不要**で声を返せる導線をここでも提供（ホットキーが主、クリックは副）。
- 完了して `awaitingReply` に入ったら **そっと通知**: 小さなバッジ増加 + 任意で控えめな効果音（今の `Glass` を流用、ただし鳴らしすぎない）。macOS の `UserNotifications` バナーは**既定オフ**（並列で鳴ると煩い）。サイドバーのバッジで足りる。
- TTS 読み上げ自体が「完了した」合図になっているので、視覚通知は最小限でよい。

### 3.4 `VoiceLoop` リファクタ方針（`App.swift` への適用指針）

現 `VoiceLoop` を**3 つに割る**:

1. **`EventIngest`**（現 `poll()` 部分そのまま）: `~/.voiceterm/events/*.json` を監視 → `(pane, summary)` を `VoiceCoordinator` に渡す。
2. **`SpeechQueue`**（現 `speak()` 周辺）: summary を**直列に** TTS 再生。再生終了で coordinator に `didFinishSpeaking(pane)` を通知。TTS は listen と独立して回り続ける（聞き取り中でも次の summary は読み上げ可能 / もしくは「listen 中は TTS を待たせる」の 2 択。既定は**listen 中は次の TTS を待たせる**＝音が被らない）。
3. **`VoiceCoordinator`**（新・状態の中心、`@MainActor`）:
   - `sessions: [UUID: SessionVoiceState]`、`pendingOrder: [UUID]`（awaitingReply の順序）、`MicArbiter`、`PillController`/`PillModel` を保持。
   - `didFinishSpeaking(pane)` → 既定で `awaitingReply` に積む（`pendingOrder.append`）。
   - `hotkeyListenNext()` → `pendingOrder.first` を取り出し `listen(pane)`。
   - `hotkeyStopSend()` / `hotkeyCancel()` → 現 listen 中 pane に作用。
   - `listen(pane)`: アービタ取得 → ピル `show()` + `targetLabel/targetColor` をそのセッションに設定 → 録音開始（現 `listen()` のレコーダ + VAD をここへ移植、波形のため 0.05s 周期化）。
   - `endListen`/`submit` は現行ロジックを流用。違いは「失敗時に消すのではなく `awaitingReply` に戻す」点と「終了後アービタ解放 → 自動で次を listen しない（既定）」点。

現 `VoiceLoop` の流用可能パーツ（そのまま移植）: `poll()`、`speak()/runCurl/jsonString/apiKey`、`stt()`、`submit()`（text→0.35s→`\r` の Enter 分離）、VAD のしきい値群（`speechThreshold -38`, `trailingSilence 1.8` 等）、`isStopword()`。

擬似コード（中心部）:
```swift
@MainActor
final class VoiceCoordinator {
    static let shared = VoiceCoordinator()
    private var state: [UUID: SessionVoiceState] = [:]
    private var pendingOrder: [UUID] = []          // awaitingReply の FIFO
    private let mic = MicArbiter()
    let pill = PillController(model: PillModel())
    weak var session: Session?

    func didFinishSpeaking(pane: UUID) {            // SpeechQueue から
        if Defaults.autoListen(for: pane), mic.tryAcquire(pane) {
            beginListen(pane)                       // 例外的に自動 listen（後述条件）
        } else {
            state[pane] = .awaitingReply
            if !pendingOrder.contains(pane) { pendingOrder.append(pane) }
            notifyAwaiting(pane)                    // サイドバーのバッジ更新（そっと）
        }
    }

    func hotkeyListenNext() {
        guard !mic.isBusy, let pane = pendingOrder.first else { softBeep(); return }
        pendingOrder.removeFirst()
        guard mic.tryAcquire(pane) else { return }
        beginListen(pane)
    }
    func hotkeyStopSend() { if let p = mic.holder { endListen(p, transcribe: true) } }
    func hotkeyCancel()   { if let p = mic.holder { endListen(p, transcribe: false, requeue: true) } }

    private func beginListen(_ pane: UUID) {
        state[pane] = .listening
        pill.model.targetLabel = label(pane); pill.model.targetColor = color(pane)
        pill.model.phase = .listening
        pill.show()
        startRecorder(pane)                         // 現 listen() のレコーダ+VAD（0.05s）
    }

    private func endListen(_ pane: UUID, transcribe: Bool, requeue: Bool = false) {
        stopRecorder()                              // 現 endListen の停止部
        if !transcribe {                            // CANCEL or 無発話
            pill.hide(); mic.release(pane)
            if requeue { requeueFront(pane) } else { requeueFront(pane) } // 既定: 戻す
            return
        }
        pill.model.phase = .transcribing
        stt(currentAudioURL) { [weak self] text in
            guard let self else { return }
            if let t = text, !t.isEmpty, !isStopword(t) {
                self.pill.model.phase = .sending
                self.submit(pane, t)                // 現 submit（text→0.35s→\r）
                self.pill.hide(); self.mic.release(pane); self.state[pane] = .idle
            } else {
                self.pill.hide(); self.mic.release(pane); self.requeueFront(pane) // 空→戻す
            }
        }
    }
    private func requeueFront(_ pane: UUID) {       // 失敗は先頭に戻して再挑戦容易に
        state[pane] = .awaitingReply
        if !pendingOrder.contains(pane) { pendingOrder.insert(pane, at: 0) }
        notifyAwaiting(pane)
    }
}
```

---

## 4. 既定値（いつ自動 listen / いつ待つ / タイムアウト）

### 4.1 自動 listen するか、ホットキー待ちか
- **既定: ホットキー待ち（自動 listen しない）。** 並列前提では「読み上げ即録音」は占有と取りこぼしの元。完了は `awaitingReply` に積むだけ。
- **例外的に自動 listen してよいケース（`Defaults.autoListen(for:)` で判定、いずれも任意の opt-in 設定）**:
  - (a) **シングル稼働モード**: 返信待ちが**この 1 件だけ**かつ他に listen も TTS キューも無いとき → 旧来の即聞き取りが快適。
  - (b) **会話継続モード**: 直前に同じ pane へ自分が送信した直後（往復ラリー中）→ そのターンだけ自動 listen。
  - 既定の出荷設定は **(a) のみ ON**（最も自然で事故が少ない）。

### 4.2 タイムアウト / VAD（PoC 値をベースに調整）
| パラメータ | 現値 | 新既定 | 理由 |
|---|---|---|---|
| 発話しきい値 `speechThreshold` | -38 dBFS | -38 | 流用 |
| 末尾無音で確定 `trailingSilence` | 1.8s | **1.6s** | ピルがあるので少し詰めて軽快に |
| **無発話タイムアウト** | 30s | **8s** | ★打ち切っても消えず `awaitingReply` に戻るだけ。長く占有しない。マイクの空き回転を上げる |
| 最大録音長 `maxDuration` | 25s | 25s | 流用 |
| 波形サンプル周期 | 0.1s | **0.05s** | 波形の滑らかさ |
| listen 開始音 | Glass | Glass（小音量） | 流用、ただし `awaitingReply` 通知は原則無音（バッジのみ） |

- **無発話 8s で戻す**のが今回の肝: 「ホットキーを押したが、やっぱり今は無理」を握り潰さない。ピルは消え、サイドバーに戻る。
- listen 中に**何も話さず STOP(■/ホットキー)**を押したら即 `awaitingReply` に戻す（誤爆ガード）。
- stopword（「キャンセル」「やめて」等、現 `isStopword`）認識時も**送信せず `awaitingReply` に戻す**（消さない）。

### 4.3 推奨ホットキー（既定・衝突回避）
- **Listen 次の返信待ち**: `Ctrl+Option+R`（録音=Record）。
- **STOP（確定送信）**: `Ctrl+Option+Return`。
- **CANCEL（破棄して戻す）**: `Ctrl+Option+Esc`。
- いずれも `RegisterEventHotKey` で**前面アプリに渡さず消費**。Aqua の `Ctrl+F` とは衝突しない帯を選択。設定で差し替え・最大 5 個まで追加可（Aqua 準拠）。
- 補助: ピル上の **⊗ = CANCEL / ■ = STOP** はマウスでも同義。

---

## 5. まとめ（実装順の推奨）
1. `PillPanel`/`PillController`/`PillModel`/`PillView`/`WaveformView` を新規追加（`App.swift` とは別ファイル可）。まずダミーレベルで点灯確認。
2. `HotKey`（Carbon）導入 → 3 ホットキーを `VoiceCoordinator` のメソッドに配線。
3. `VoiceLoop` を `EventIngest` + `SpeechQueue` + `VoiceCoordinator` に分割。TTS は流用、listen を coordinator 配下へ。波形駆動を `updateMeters` に接続。
4. `awaitingReply` キューとサイドバー/バッジを追加（最小はタブバー上の「返信待ち N」表示でも可）。
5. 既定値（自動 listen は (a) のみ、無発話 8s で戻す）を適用し、3–4 並列で実地調整。

> 重要な不変点: **1 マイク直列**（`MicArbiter`）、**Enter 分離送信**（`submit` の text→0.35s→`\r`）、**マイク権限はネイティブアプリの Info.plist 宣言で確保済み**（壁A 解決済み）。これらは崩さない。

<!-- TTS: 音声入力のUX設計書を書きました。フローティングピルとグローバルホットキー、返信待ちキューの仕組みをまとめてあります。 -->
