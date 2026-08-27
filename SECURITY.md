# Security Policy

## Supported versions

現在は正式なGitHub Releaseを公開していないため、最新版の`main`ブランチをセキュリティ修正の対象とします。将来バイナリReleaseを開始した場合は、最新安定Releaseと`main`を優先して修正します。

## Reporting a vulnerability

認証情報の漏えい、リダイレクトによるCredential転送、WebView境界、パーサーのfail-openなどの問題を見つけた場合は、公開Issueへ秘密情報を書かず、GitHubのPrivate Vulnerability Reporting / Security Advisoryから非公開で報告してください。

報告には以下を含めてください。

- 影響するcommitまたはバージョン
- 再現手順
- 期待される動作と実際の動作
- 秘密情報を除去したログまたはfixture

OAuthトークン、Cookie、アカウントID、workspace ID、実APIレスポンス全文は添付しないでください。

GitHub側で非公開報告が利用できない場合も、秘密情報を公開Issueへ投稿しないでください。公開情報だけで再現できる最小限のIssueを作成し、機密情報なしで追加連絡方法を相談してください。
