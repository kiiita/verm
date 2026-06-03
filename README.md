# verm — Voice Terminal

声で操作するネイティブ macOS ターミナル。並列で走る複数の Claude Code セッションに対して、
**結果の読み上げ（TTS）→ 聞いた直後に声で返信（STT）→ 読み上げたセッションへ確実に注入** を、
ナビゲーション不要・ハンズフリーで行うことを目的とする。cmux 風の左サイドバー UI とキーボード
ショートカット、タイル分割ペインを備える。

## なぜ作るか
cmux 上のフックでは macOS の 2 つの壁——(A) ターミナルアプリにマイク権限が無い、
(B) 外部ツールから raw-mode TUI へ文字を確実に注入できない——を越えられなかった。
**自前のネイティブアプリなら、マイク権限を宣言でき、PTY を所有して子プロセスへ直接注入できる**ため両方が消える。
（実証済み。`docs/research/` 参照。）

## 現状
- ネイティブアプリ（AppKit + SwiftUI、ターミナルは現状 **SwiftTerm**）。実装は `poc/`。
- **音声ループ**: Claude 終了 → TTS 読み上げ → 返信待ちキュー → `⌃D` で聞き取り開始（VAD）→ 該当ペインへ注入＋Enter。
  Aqua Voice 風フローティングピル、グローバルホットキー。
- **cmux 風 UI**: 左ワークスペースサイドバー（音声「返信待ち」を統合表示）、`⌘1-9`/`⌘B`/`⌘D`/`⌘⇧D`/`⌘W`/`⌘⇧↩` 等。
- **音声ショートカット（2キー）**: `⌃D`=次の返信待ちへ / `⌃S`=読み上げ一時停止・聞き取り完了（用がなければターミナルへ素通し）。
- **libghostty**: 実機でリンク・ビルド確認済み（`Lakr233/libghostty-spm@1.2.3`）。プレビルトはサンドボックス向けトリム版のため、
  **自前 PTY をホストして描画させる backend を実装中**（`backend = .swiftTerm | .ghostty`、既定 SwiftTerm）。

## ビルド / 実行
```bash
cd poc
./make-app.sh        # swift build → .app バンドル組み立て → ad-hoc 署名
open VoiceTerm.app
```
初回はマイク許可ダイアログを許可。OpenAI TTS/STT を使うため `~/.claude/openai.key` にキーを置く。

## ドキュメント
- `docs/REQUIREMENTS.md` — 要件定義・調査記録
- `docs/CMUX_ANALYSIS.md` — cmux 解析と再現プラン
- `docs/research/VOICE_UX.md` — Aqua Voice 風 UX 設計
- `docs/research/CMUX_UI_SPEC.md` — cmux UI + ショートカット仕様
- `docs/research/LIBGHOSTTY.md` / `LIBGHOSTTY_INTEGRATION.md` — libghostty 移行計画・実機検証メモ

## 外部依存（音声ループの土台）
Claude Code の Stop フック（`~/.claude/hooks/tts-stop.sh`）が、`VOICETERM_PANE` 環境変数のある
セッション（= verm が起動した PTY）で完了イベントを `~/.voiceterm/events/` に書き出し、アプリが拾う。
このフック連携は今はグローバル設定側にある（将来 `scripts/` に取り込み予定）。
