# AIUsage

<p align="center"><img src="docs/icon.png" width="128" alt="AIUsage icon"></p>

macOSのメニューバーから、複数のAIサービスの使用枠をまとめて確認するアプリです。

メニューバーには選択中の1サービスの残量が常に表示され、クリックするとメニューバー直下にPopoverが開き、全サービス（OpenCode Go、Qwen Cloud、OpenAI Codex）の使用枠をカード形式で確認できます。

## 使い方

1. 起動するとメニューバーに選択したサービスの残量が短縮表示されます（例: `GO 5h:99.8% / W:99.9% / M:67.9%`）。
2. メニューバー表示を**クリック**すると、その直下にPopoverが開きます。もう一度クリックするかPopover外をクリックすると閉じます。
3. Popover内のカードをクリックすると、そのサービスをメニューバー表示へ固定できます。カードはドラッグで並び替えでき、Sign in / Sign out / Refresh / Open dashboardも各カードから実行できます。
4. Settingsで表示形式（残量/使用量）を変更できます。

## 対応サービス

| Provider | 取得方法 | 認証 |
|---|---|---|
| OpenCode Go | ログイン済みページをWKWebViewで解析 | アプリ内ブラウザでログイン |
| Qwen Cloud | Qwen Cloudのusage API | アプリ内ブラウザ、旧QwenUsage Cookieの一度限りの移行フォールバック |
| OpenAI Codex | ChatGPT usage endpoint | `~/.codex/auth.json`の既存OAuthセッション |

各サービスの非公開・非安定APIやWebページ構造に依存するため、サービス側の変更で取得できなくなる可能性があります。Providerごとに障害を隔離しているため、1サービスの失敗で他サービスの表示が止まることはありません。

Qwenの旧Cookie移行は`https://home.qwencloud.com`だけに限定され、AIUsageで新たにWebログインした後、またはSign outした後は旧平文Cookieへフォールバックしません。

## 必要環境

- macOS 14以降
- Apple Silicon (arm64) ネイティブビルド
- Xcode 16.2以降（ソースからビルドする場合）
- XcodeGen

## ビルド

```bash
brew install xcodegen
xcodegen generate
xcodebuild test \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

Release成果物をローカル利用する場合は、必要に応じてad-hoc署名します。

```bash
codesign --force --deep --sign - AIUsage.app
```

## 実アカウントテスト

通常のテストは認証情報を使わないfixtureだけで実行されます。ローカルの実セッションを使うテストは明示的なopt-inです。

```bash
touch /tmp/aiusage-live-tests-enabled
xcodebuild test \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AIUsageTests/LiveProviderTests
rm -f /tmp/aiusage-live-tests-enabled
```

実レスポンス、Cookie、OAuthトークン、アカウントIDはfixtureやログへ保存しません。

## プライバシー

- 外部分析、テレメトリー、広告SDKはありません。
- 認証情報や使用率をUnified Loggingへ定期出力しません。
- CodexのBearer付きリクエストとQwenのCookie付きリクエストはHTTPリダイレクトを拒否します。
- Qwenの旧Cookieファイルは移行元として読み取るだけで、AIUsage側の平文ファイルへ複製せず、新しいログイン後は再利用しません。

詳細は[PRIVACY.md](PRIVACY.md)を参照してください。

## ライセンスと免責

MIT Licenseです。各サービスおよびCodexBarとの提携・承認関係はありません。サービス名と商標は各権利者に帰属します。

Codex取得方式の調査ではMITライセンスの[CodexBar](https://github.com/steipete/CodexBar)を参考にしています。詳細は[NOTICE](NOTICE)を参照してください。
