# cmux 解析 & 機能再現プラン

- 作成日: 2026-06-03
- 目的: 自作の音声ネイティブ・ターミナル（VoiceTerm 仮称）が、cmux 相当の多重化機能をどう備えるかの設計材料。
- 前提: **PoC で「壁A（マイク権限）」「壁B（PTY 直接注入）」が自前ネイティブアプリで両方消えることを実証済み**（`poc/`）。残るは cmux 相当のターミナル多重化レイヤの実装。

> 法務/倫理メモ: cmux は Manaflow, Inc. の商用製品。再現するのは**機能・UX（著作権の対象外）**であって、cmux のバイナリ/ソースの流用ではない。土台は**オープンソース（Ghostty=MIT, SwiftTerm=MIT）**を使う。

---

## 1. cmux のアーキテクチャ（解析で判明）

| レイヤ | cmux の実装 | 根拠 |
|---|---|---|
| アプリ本体 | **Swift / SwiftUI / AppKit** ネイティブ | otool: SwiftUI, AppKit, Combine, CoreData |
| ターミナル描画 | **Ghostty を静的リンク**（Metal/GPU） | Resources に ghostty/themes(461), shell-integration, xterm-ghostty, terminfo。Metal/CoreText/IOSurface |
| ブラウザペイン | **WKWebView** | WebKit リンク。CLI の `browser *`（"not_supported on WKWebView" の注記） |
| 制御プレーン | **Unix ソケット**サーバ + `cmux` CLI(7MB) | Network.framework。`/tmp/cmux.sock`、keychain 認証 |
| 永続化 | **CoreData** | レイアウト/ワークスペース状態の保存 |
| グローバル入力 | **Carbon** | ホットキー |
| 通知 | **UserNotifications** | CLI の `notify` |
| 自動更新 | **Sparkle.framework** | — |
| 計測 | **Sentry.framework + PostHog** | クラッシュ/解析 |
| 配布 | Developer ID 署名 + notarize | Authority: Manaflow, Inc. (7WLXT3NR37) |

メタ: bundle id `com.cmuxterm.app` / v0.61.0(73) / 最小 macOS 14。同梱 `claude`・`open` シムあり。**マイク/カメラ権限の宣言なし**（＝壁A の根本原因）。

---

## 2. 機能カタログ（CLI `--help` + 実挙動から）

### A. ターミナル多重化（コア）
- **ウィンドウ / ワークスペース / タブ / ペイン / サーフェス**の階層。ワークスペースは命名・並び替え・サイドバー表示。1 ペインに複数サーフェス（タブ）を持てる。
- 分割（left/right/up/down）、`resize-pane` / `swap-pane` / `break-pane` / `join-pane` / `move-surface` / `reorder`。
- フォーカス制御（`focus-pane` / `focus-window` / `select-workspace` / `last-pane` / `next/previous-window`）。

### B. 制御プレーン（cmux の真の差別化点）
- **`cmux` CLI が全操作をソケット経由で叩ける**。スクリプト/エージェントから完全制御可能。
  - 入力: `send <text>` / `send-key <key>` / `set-buffer`+`paste-buffer`（ブラケットペースト）。
  - 読み取り: `read-screen` / `capture-pane`。
  - 生成/破棄: `new-window/new-workspace/new-pane/new-surface/close-*`。
  - 同期: `wait-for`（signal）、`pipe-pane`、`set-hook`。
  - UI 連携: `notify`、サイドバーの `set-status` / `set-progress` / `log`。
- 端末ごとに `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` を自動注入 → スクリプタビリティの源泉。
- **tmux 互換層**（`capture-pane`/`bind-key`*/`copy-mode`/`buffers`/`respawn-pane`/`display-message` 等）。*一部 "not supported yet"。

### C. ブラウザペイン（WKWebView + Playwright 風自動化）
- ペインをブラウザにでき、`browser navigate/click/type/fill/eval/snapshot/cookies/...` で自動操作。エージェント用途。

### D. エージェント / Claude 連携
- **`cmux claude-hook <session-start|stop|notification>`** — Claude Code ライフサイクルをネイティブに認識。
- サイドバーの status/progress でエージェントが状態を可視化。
- 同梱 `claude` シム。

### E. プラットフォーム機能
- Ghostty テーマ(461)・シェル統合、Sparkle 自動更新、ネイティブ通知、Sentry/PostHog。

---

## 3. 我々の VoiceTerm へのマッピング（MVP / 後回し / スキップ）

差別化の核は **音声ループ（実証済み）**。多重化は「自分のワークフローに要る分だけ」段階的に。

| cmux 機能 | 我々の方針 | 備考 |
|---|---|---|
| PTY ペイン + 描画 | **MVP**: SwiftTerm（PoC で実証済み） / 後で **libghostty** に差し替え検討 | cmux は Ghostty 静的リンク。SwiftTerm で十分始められる |
| タブ / 分割 / ワークスペース | **MVP**: タブ + 単純分割 → 後でワークスペース/サイドバー | SwiftUI で構築 |
| セッション完了検知（claude-hook 相当） | **MVP（最優先）**: Claude Code の Stop フック → アプリのローカルソケットへ通知 | 音声ループの引き金。既に設計済み |
| PTY 直接注入 | **済（PoC）**: `terminalView.send(txt:)` | 壁B 解決の本体 |
| ネイティブ録音 + STT + TTS | **MVP**: PoC を発展（VAD自動停止、マイク調停、完了FIFO） | 壁A 解決済み。OpenAI 流用 |
| サイドバー status/progress | **後回し**: あると便利（どのペインが喋った/聞いてる） | 音声 UI と相性良 |
| 制御ソケット CLI | **縮小版**: 自分用の最小コマンド（送信/読取/フォーカス/完了通知）。フル CLI は不要 | まずアプリ内 IPC で足りる |
| ブラウザペイン(WKWebView)+自動化 | **スキップ（当面）** | 大機能。音声ターミナルの本筋ではない |
| Sparkle 自動更新 | **後回し**: 配布段階で導入 | 個人運用なら当面不要 |
| Sentry/PostHog | **スキップ** | 個人ツールに計測不要 |
| グローバルホットキー(Carbon) | **後回し**: 停止キー等が欲しくなったら | まずは VAD 自動停止 |

---

## 4. エンジン選択: SwiftTerm vs libghostty

| | SwiftTerm（PoC採用） | libghostty（cmux採用） |
|---|---|---|
| 言語 | 純 Swift | C/Zig コア + 薄い Swift ラッパ |
| 導入 | SPM 1 行、即動いた | 静的リンク/ビルド統合が必要・上級 |
| 描画品質 | 良好（CoreText） | 最高（Metal/GPU、合字・高速） |
| 推奨 | **MVP はこれ** | 後日のアップグレード候補 |

> 結論: **MVP は SwiftTerm で多重化 UI と音声ループを完成させる**。描画品質を詰める段階で libghostty 移行を検討（cmux と同じ土台になる）。

---

## 5. 推奨ビルド順

1. **(済) PoC** — 壁A・B の解消を実証。`poc/`。
2. **音声ループの本実装（1ペイン）** — Stop フック→ローカルソケット IPC→TTS→ネイティブ録音(VAD)→STT→該当ペイン注入。マイク調停 + 完了 FIFO。
3. **多重化 UI** — タブ + 分割（SwiftUI + SwiftTerm を複数）。各ペイン状態バッジ（待機/読み上げ/聞き取り）。
4. **ワークスペース + サイドバー** — 命名・並び替え・「いま聞いてるペイン」表示。
5. **最小制御 IPC** — 自分用コマンド（送信/読取/フォーカス/完了通知）。
6. **仕上げ** — 署名/ノータライズ、（必要なら）libghostty 移行、ホットキー、自動更新。

> 設計の心臓は「Stop フック→アプリ IPC→音声ループ→PTY 注入」。ここは PoC で全ピース実証済みなので、あとは UI と多重化を肉付けするフェーズ。

---

## 6. オープンソースの土台（流用先）

- **Ghostty**（MIT, Mitchell Hashimoto）: GPU ターミナル。libghostty で組込み可能。cmux の描画はこれ。
- **SwiftTerm**（MIT, Miguel de Icaza）: Swift 製ターミナルエミュレータ。PoC で採用。`LocalProcessTerminalView` が PTY 起動+描画+`send(txt:)` を提供。
- いずれも cmux の独自コードとは無関係に利用できる。
