# AIUsage

<p align="center"><img src="docs/icon.png" width="128" alt="AIUsage icon"></p>

macOSのメニューバーから、複数のAIサービスの使用枠をまとめて確認するアプリです。

メニューバーには選択中の1サービスの残量が常に表示され、クリックするとメニューバー直下にPopoverが開き、全サービス（OpenCode Go、Qwen Cloud、OpenAI Codex）の使用枠をカード形式で確認できます。

> [!IMPORTANT]
> AIUsageは各サービスの公式SDKではなく、非公開・非安定なusage endpointやWebページ構造を利用します。サービス側の変更で一時的に取得できなくなる可能性があります。認証情報や実レスポンスをIssueへ貼らないでください。

## 使い方

1. 起動するとメニューバーに選択したサービスの残量が短縮表示されます（例: `GO 5h:99.8% / W:99.9% / M:67.9%`）。
2. メニューバー表示を**クリック**すると、その直下にPopoverが開きます。もう一度クリックするかPopover外をクリックすると閉じます。
3. Popover内のカードをクリックすると、そのサービスをメニューバー表示へ固定できます。カードはドラッグで並び替えでき、Sign in / Sign out / Refresh / Open dashboardも各カードから実行できます。
4. Settingsで表示形式（残量/使用量）を変更できます。

## 対応サービスと初期設定

| Provider | 取得方法 | 初期設定 |
|---|---|---|
| OpenCode Go | ログイン済みページをWKWebViewで解析 | カードの **Sign in** からOpenCodeへログイン |
| Qwen Cloud | Qwen Cloudのusage API | カードの **Sign in** からQwen Cloudへログイン |
| OpenAI Codex | ChatGPT usage endpoint | Codex CLIでログインし、`~/.codex/auth.json`が存在する状態にする |

Providerごとに取得処理を分離しており、1サービスの取得失敗時も、他サービスの状態と最後に正常取得できた値は可能な限り維持します。

Qwenの旧QwenUsage Cookie移行は`https://home.qwencloud.com`だけに限定され、AIUsageで新たにWebログインした後、またはSign outした後は旧平文Cookieへフォールバックしません。

## 必要環境

- macOS 14以降
- Xcode 16.2以降（ソースからビルドする場合）

CIと通常の開発では、リポジトリにコミットされている`AIUsage.xcodeproj`を使用します。通常のビルドにXcodeGenは不要です。

## ソースからビルド

```bash
git clone https://github.com/PeachGumi/AIUsage.git
cd AIUsage

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

## 配布用ZIPを作る

リポジトリ付属のスクリプトで、テスト → Release build → ad-hoc署名 → ZIP化 → SHA-256生成まで同じ手順で実行できます。XcodeGenは不要です。

```bash
./Scripts/build_release.sh
```

成果物は次に作成されます。

```text
build/dist/AIUsage.app
build/dist/AIUsage-macOS.zip
build/dist/AIUsage-macOS.zip.sha256
```

このスクリプトの署名はローカル利用・検証向けの**ad-hoc署名**で、Developer ID署名やApple notarizationではありません。GitHub Releasesから未公証バイナリを配布する場合、ダウンロードしたユーザーにはGatekeeperの警告が出る可能性があります。ソース公開だけならDeveloper IDは必須ではありません。

`project.yml`はプロジェクト構成の宣言用にも保持していますが、コミット済み`.xcodeproj`と差分が生じないように扱ってください。XcodeGenで再生成する変更は、生成後の`.xcodeproj`も同じPull Requestで確認・コミットします。

## トラブルシューティング

### `Codex login not found`

Codex CLI側でログインできているか確認してください。AIUsageは`~/.codex/auth.json`を読み取るだけで、認証情報を書き換えません。

### `Qwen Cloud login is required`

PopoverのQwen Cloudカードから **Sign in** を実行してください。古いQwenUsageのCookieファイルは移行用フォールバックに限って参照され、新しいAIUsageログイン後には再利用されません。

### `OpenCode login is required`

PopoverのOpenCode Goカードから **Sign in** を実行してください。ログイン後、workspace IDはローカルのUserDefaultsへ保存されます。

### 昨日まで取得できていたのに急に失敗する

Provider側の非公開APIまたはDOM変更の可能性があります。まず **Refresh** を試し、それでも継続する場合は既存Issueを確認してから、新しいIssueを作成してください。その際、OAuthトークン、Cookie、アカウントID、workspace ID、実APIレスポンス全文は投稿しないでください。

## テスト

通常のテストは認証情報を使わないfixtureだけで実行されます。Pull Requestでは、SwiftファイルのXcodeプロジェクト登録漏れ、ユニットテスト、Releaseビルド、Swift compiler warningをCIで検査します。

ローカルの実セッションを使うテストは明示的なopt-inです。

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

## セキュリティ報告

脆弱性や認証情報に関係する問題は、秘密情報を公開Issueへ書かず、[SECURITY.md](SECURITY.md)の手順に従ってください。

## コントリビューション

Issue / Pull Requestを歓迎します。開発手順とProvider追加時のルールは[CONTRIBUTING.md](CONTRIBUTING.md)を参照してください。

## ライセンスと免責

MIT Licenseです。各サービスおよびCodexBarとの提携・承認関係はありません。サービス名と商標は各権利者に帰属します。

Codex取得方式の調査ではMITライセンスの[CodexBar](https://github.com/steipete/CodexBar)を参考にしています。詳細は[NOTICE](NOTICE)を参照してください。
