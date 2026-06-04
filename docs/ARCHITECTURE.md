# verm アーキテクチャ

## 1. Ghostty / libghostty とは

- **Ghostty** = Mitchell Hashimoto 作の GPU 描画ターミナルエミュレータ（Zig 製コア + Metal 描画）。
- **libghostty** = その中核を「部品として他アプリに組み込める C ライブラリ」にしたもの。
  verm は公式ソースビルドの代わりに、コミュニティのプレビルト xcframework（`Lakr233/libghostty-spm@1.2.3`、`GhosttyTerminal` 高位ラッパ付き）を使っている。
- **verm における役割 = 各ペインの「端末そのもの」**。次を全部 libghostty が担当する:
  - 文字の GPU 描画 / キーボード・IME 入力処理
  - **PTY を開いて `/bin/zsh` を起動・管理**（`.exec` backend）
- 呼んでいる API: `AppTerminalView`(NSView) + `TerminalController` + `TerminalSurfaceOptions(backend: .exec)`。
  入力注入 = `sendText`、送信 = 合成した Return キーイベント、状態 = `TerminalSurfaceViewDelegate`（title/exit/focus）。

> ポイント: **Ghostty はペイン1枚1枚の“端末エンジン”でしかない。** サイドバー・分割・音声・ショートカットは全部 verm 側の実装で、Ghostty とは独立。差し替え可能なように `TermBackend` プロトコルの裏にあり、SwiftTerm 実装も残してある。

## 2. 全体設計（3 レイヤー）

```
┌──────────────────────────────────────────────────────────┐
│ (A) アプリ/UI 層  — verm 自作（SwiftUI + AppKit）          │
│   ウィンドウ / 左サイドバー / 分割ツリー / ショートカット    │
│   / フローティングピル                                      │
├──────────────────────────────────────────────────────────┤
│ (B) 音声ループ層 — verm 自作（VoiceCoordinator）           │
│   Stopフック→イベント→TTS→返信待ち→聞き取り→注入         │
├──────────────────────────────────────────────────────────┤
│ (C) ターミナル backend 層 — libghostty                    │
│   各ペインの中身（描画・入力・PTY・シェル）                  │
└──────────────────────────────────────────────────────────┘
```

## 3. オブジェクトの階層（コードの実体）

```
Session（アプリ状態。ただ1つ）
 └─ Workspace（サイドバーの1行。複数。⌘1-9 / ⌘N で切替・追加）
     └─ LayoutNode（分割の二分木）
         ├─ 葉   → Pane（端末1枚）
         └─ 枝   → axis(縦/横) + first/second（再帰的に何度でも分割）
              Pane
               └─ TermBackend（= GhosttyBackend）
                    └─ AppTerminalView + libghostty surface + /bin/zsh(PTY)
```

| 型 | 役割 |
|---|---|
| **Session** | 全 Workspace のリスト、`activeWorkspaceID`、`focusedPaneID`、サイドバー表示など**アプリ状態の単一の源**。作成/選択/分割/閉じる/ズーム/ペイン移動の操作も持つ。 |
| **Workspace** | サイドバーの1行（ユーザーが言う「セッション」のまとまり）。タイトル・アクセント色・ズーム状態・そして**分割ツリーのルート `LayoutNode`** を持つ。1 ワークスペース = 1 つの分割可能な画面。 |
| **LayoutNode** | 二分木。葉なら 1 つの `Pane`、枝なら軸 + 2 子。SwiftUI の `HSplitView`/`VSplitView` で再帰描画。 |
| **Pane** | 「端末1枚」の論理単位。UUID、タイトル、フォーカス/終了コールバック、そして **`backend`**(端末の実体)。 |
| **TermBackend / GhosttyBackend** | ペインの中身。`AppTerminalView`(libghostty) を作り、`.exec` で `/usr/bin/env VOICETERM_PANE=<uuid> VOICETERM_EVENTS=<dir> /bin/zsh -l` を起動。 |

### 「セッション」という言葉の対応
文脈で 2 つを指す:
- **(a) サイドバーの1行 = Workspace**（プロジェクト/作業の単位）
- **(b) その端末で走っている claude の対話 = 1 つの Pane で動く claude プロセス**

入れ子は **Workspace（行）＞ Pane（端末）＞ その中の claude（プロセス）**。1 ワークスペースを分割すれば、複数 Pane（＝複数の claude）を 1 行の中に並べられる。

## 4. 音声ループのデータフロー（1 往復）

```
[ペイン内の claude が応答終了]
  → Stop フック tts-stop.sh が、VOICETERM_PANE があるセッションで
     ~/.voiceterm/events/<ts>.json に {pane:<uuid>, summary} を書く
  → VoiceCoordinator が 0.25 秒ごとに events を監視 → TTS 読み上げ(OpenAI marin)
  → 読み上げ後、そのセッションを「返信待ち」キューへ（サイドバーに 🟠 表示）
  → ⌃D（グローバル） → 該当ペインを前面化 + ピル表示 + 録音(VAD自動停止)
  → OpenAI STT で文字起こし
  → backend.sendText でペインに注入 → 0.35秒後に Return キーイベントで送信
  → claude が動く → 最初へ戻る
```

### 「探さず・該当セッションへ」の核
**Pane の UUID を `VOICETERM_PANE` として env 注入** → claude の Stop フックがそれをイベントに書く →
VoiceCoordinator が UUID で Pane を逆引き（`session.pane(uuid:)`）→ その Pane の `backend.sendText` で注入。
だから「どのウィンドウか探して移動」不要で、読み上げたセッションへ正確に返せる。

## 5. 主なファイル
- `App.swift` — Pane / LayoutNode / Workspace / Session / SwiftUI ビュー / キーボードショートカット
- `Backend.swift` — `TermBackend` プロトコル / `GhosttyBackend`(libghostty) / `SwiftTermBackend`(予備)
- `Voice.swift` — `VoiceCoordinator`（イベント監視・TTS・返信待ち・VAD・STT・注入・グローバル ⌃D/⌃S）
- `Pill.swift` — フローティングピル（NSPanel + 波形）
- `HotKey.swift` — Carbon グローバルホットキー（動的に登録/解放）
- 外部: `~/.claude/hooks/tts-stop.sh`（VOICETERM_PANE 分岐でイベント書き出し）
