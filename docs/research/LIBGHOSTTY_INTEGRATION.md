# libghostty 統合メモ（実機検証の結果 / 2026-06-03）

LIBGHOSTTY.md の研究を受けて、実機での取り込みを試した結果。

## 達成（実現性ゲート突破）
- 採用パッケージ: **`Lakr233/libghostty-spm` @ `1.2.3`**（プレビルト GhosttyKit.xcframework、チェックサム付き）。`Package.swift` に追加済み（`.product(name: "GhosttyKit", package: "libghostty-spm")`）。依存に `MSDisplayLink` も入る。
- **このマシン（macOS 26 / Swift 6.2 / arm64）でリンク・ビルド成功**。`libghostty.a` が実行ファイルにリンクされる。xcframework zip ≈ 50MB。
- 公式は Zig ソースビルドのみ・このマシンに zig 無し → プレビルト採用（ユーザー承認済み）。
- 生の C API は不要。高位 Swift API が使える:
  - `AppTerminalView`（macOS。`TerminalView` typealias）/ `TerminalViewState`（SwiftUI 状態）/ `TerminalSurfaceView`（SwiftUI）
  - `TerminalController`（app ライフサイクル・config・テーマ・surface 生成。`init { builder in ... }`）
  - backend = `TerminalSurfaceOptions(backend: .inMemory(session))`

## 重要な制約（要対応）
**このプレビルトは "trimmed build optimized for sandboxed, embedded use"。** libghostty 自身は**ローカルプロセスを起動しない**。
- 同梱 `ShellSession`/`defaultSandboxShell` は**台本化された擬似シェル**（`SandboxShell.swift`、"sandbox@ghostty %" を出すだけ。本物の /bin/zsh ではない）→ **claude は動かせない**。
- 実端末にするには **`.inMemory(InMemoryTerminalSession)` backend にこちら側の実 PTY を接続**する（Termini と同じ方式）。

### `InMemoryTerminalSession` の接続点（API 確認済み）
```swift
let session = InMemoryTerminalSession(
    write:  { (data: Data) in /* 端末→backend: キー入力。自前PTYの master に write */ },
    resize: { (vp: InMemoryTerminalViewport) in /* グリッド変更→ ioctl TIOCSWINSZ で PTY winsize */ }
)
session.receive(_ data: Data)   // PTY の出力をここに流す → 描画
session.sendInput(_ data: Data) // 入力送出
session.finish(exitCode:runtimeMilliseconds:)  // プロセス終了
// 音声注入 send(text:) は write 経路（PTY master へ書く）
```
AppKit 組み立て（Example/GhosttyTerminalApp/ViewController.swift より）:
```swift
let tv = AppTerminalView(frame: ...)
tv.controller = TerminalController { b in b.withBackgroundOpacity(0) }
tv.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
// viewDidLayout: tv.fitToSize()
// 開始: window.makeFirstResponder(tv) ＋ 自前PTY起動 ＋ 読み取りループ開始
```

## 次の一手（PTY ホスト型 Ghostty backend）
1. `TerminalBackendPane` protocol を定義（`send(text:)` / `nsView` / `onTitle` / `onExit` / `onFocus`）。現 SwiftTerm `Pane` を準拠させる（無挙動変更）。
2. `GhosttyBackendPane` を実装:
   - `openpty()`（Darwin）で master/slave 取得 → `posix_spawn` で `/bin/zsh -l` を slave 接続（env に VOICETERM_PANE 等）。
   - master を `DispatchSource.read` で読む → `session.receive(data)`。
   - `InMemoryTerminalSession.write` → master へ write（キー入力）。`resize` → `ioctl(master, TIOCSWINSZ)`。
   - `send(text:)` → master へ write（音声注入。`\r` 分離送信もそのまま）。
   - PTY EOF / child reap → `session.finish` ＋ `onExit`。
   - `AppTerminalView` を `nsView` として返す。
3. `backend = .swiftTerm | .ghostty` フラグ（既定 SwiftTerm）。1ペインで描画・入力・claude 起動・音声注入を検証。
4. 必要なら terminfo を `.app/Contents/Resources/terminfo/78/xterm-ghostty` に同梱（センチネル）。inMemory backend では TERM の扱い次第。まず `TERM=xterm-256color` で試す。
5. レイアウトツリー（tabs/splits）へ展開、`SHOW_CHILD_EXITED`→`removeLeaf`。

## リスク / 留意
- 公開 API（フル埋め込み）不安定。バージョン固定（1.2.3）を維持。
- トリム版＝サンドボックス志向。**自前 PTY が前提**。これが SwiftTerm との実質差分。
- Swift 6.2 並行性（`@unchecked Sendable` な session、PTY 読み取りスレッド→main へ受け渡し）。
- **SwiftTerm は予備として残す**（pure-Swift・安定・PTY内蔵）。Ghostty はフラグ裏で育て、固まってから既定化。
