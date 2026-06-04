# verm 本番化チェックリスト（一般配布前に参照）

開発/個人運用では問題ないが、**一般配布する前に**手当てが必要な項目。

## 1. 音声エンジンの依存（最重要）

現状は **OpenAI の TTS/STT** を使い、API キーを `~/.claude/openai.key` から読む。一般ユーザーに
キー取得・課金を強いるのは大きな摩擦。

- **対策: 既定を macOS ネイティブ（無料・オンデバイス・鍵不要）にする。**
  - 読み上げ(TTS) = `AVSpeechSynthesizer`（OS 標準。日本語音声あり。Siri 品質の追加音声もDL可）
  - 聞き取り(STT) = `SFSpeechRecognizer`（Speech フレームワーク。Apple Silicon ならオンデバイス・無料）
- **OpenAI は「高品質オプション」**として、設定画面で鍵を入れた人だけ使えるようにする。
- 差し替えは局所的: `Voice.swift` の `speak()` と `stt()` の2メソッドだけ。エンジン選択を設定値にする。
- 追加権限: STT に **Speech Recognition の許可**（`NSSpeechRecognitionUsageDescription` + 初回ダイアログ）。

## 2. Claude フックの自動セットアップ

読み上げの起点は Claude Code の Stop フック（`~/.claude/hooks/tts-stop.sh`）が
`~/.voiceterm/events/*.json` を書く仕組み。手動設定は摩擦。

- **対策: 初回起動時に verm がフックを自動インストール。**
  - `~/.claude/settings.json` の `hooks.Stop` に登録（既存設定を壊さずマージ）。
  - もしくは cmux 方式で `claude` のシムを同梱し、`CMUX_*` 相当の env がある時だけフックを注入。
- 既に同等フックがある場合の共存（重複登録を避ける）を考慮。
- アンインストール手段も用意。

## 3. 配布・署名まわり

- **コード署名 + ノータライズ**: 現状は ad-hoc 署名（`codesign --sign -`）。配布には Developer ID 署名 + `notarytool` でのノータライズが必須（Gatekeeper）。北國さんは Apple Developer 登録済み。
- **Hardened Runtime + entitlements**: マイク(`com.apple.security.device.audio-input`)、音声認識、ネットワークなど。Hardened Runtime 有効化が必要。
- **サンドボックス**: Mac App Store 配布ならサンドボックス必須だが、ローカル PTY で任意シェル/claude を起動する性質上、サンドボックス化は困難（cmux も非サンドボックス）。→ **Developer ID 直配布（App Store 外）**が現実的。
- **自動更新**: Sparkle 等の導入（cmux も Sparkle）。

## 4. libghostty 依存のリスク

- 採用中の `Lakr233/libghostty-spm@1.2.3` は**第三者製プレビルト**＋**公開 API が不安定**（更新で壊れうる）。
  - バージョンを固定し続ける／自前で Zig ビルドして xcframework を vendoring する、を検討。
  - **SwiftTerm を予備 backend として残してある**（`TermBackend` プロトコル）。libghostty が壊れた時の保険。
- Ghostty リソース（terminfo / shell-integration）を cmux からコピーして同梱している点も、配布時は**自前取得**に切り替える（ライセンス上は Ghostty=MIT で可だが、出所を自前ビルドに）。

## 5. セキュリティ / 設定

- **API キーの保管**: 平文ファイル（`~/.claude/openai.key`）ではなく **Keychain** に。設定画面で入力。
  - 開発中に会話ログへ平文露出した鍵は**失効＋再発行**すること（リマインド）。
- **設定 UI**: 音声エンジン選択、OpenAI キー、ホットキー、読み上げ既定 ON/OFF、声/速度などを設定画面に。
- **プライバシー表記**: マイク音声を OpenAI に送る場合の明示（ネイティブ既定なら送信なし）。

## 6. UX 仕上げ（任意）

- タブ名の cwd 追従（現状 libghostty がタイトルを surface しないため未完。`docs/research/LIBGHOSTTY*.md` 参照）。
- ワークスペース/タブの永続化（再起動で復元）。
- アイコン/About/メニューの整備、アプリ名の統一（= Verm）。

---

> 要約: **一般配布の二大ブロッカー（OpenAI 鍵 / 手動フック）は、「ネイティブ音声を既定」「フック自動インストール」で解消できる。**
> その上で Developer ID 署名 + ノータライズ + Sparkle、libghostty のピン留め/自前ビルド、Keychain 化、を整えれば配布可能。
