# claude-review-local

PR に `/review` とコメントすると、**自分のマシン上の Claude Code**（サブスク認証）が
そのPRをレビューし、review bot のように `gh pr review` で
approve / request-changes / comment を返すローカル常駐ツール。

`dev-flow` の各スキル（`/dev-flow:*`）は Claude Code セッション内で明示的に呼び出す
ものだが、これは GitHub 側の PR コメントをトリガーに**外部から**自律的に動く常駐
デーモンなので、スキルではなく `tools/` 配下の独立ツールとして置いている。
GitHub Actions のクラウド実行（`claude-code-action` 等）だと Anthropic API 課金に
なるため、**ローカルの Claude Code サブスク枠**をそのまま使うためにあえてローカル
常駐デーモンにしている。

## 前提

- `claude` (Claude Code CLI) にログイン済みであること（`claude -p "hi"` が通ること）
- `gh` CLI にログイン済みであること（`gh auth status`）
- `jq` がインストールされていること

## セットアップ

```bash
cd tools/claude-review-local
cp config.example.env config.env
$EDITOR config.env   # 監視リポ・許可ユーザーなどを設定
```

`config.env` の主な項目:

| 変数 | 説明 |
| --- | --- |
| `CLAUDE_REVIEW_REPOS` | 監視する `owner/repo` （スペース区切りで複数可） |
| `CLAUDE_REVIEW_ALLOWED_USERS` | `/review` を実行してよいGitHubログイン名 |
| `CLAUDE_REVIEW_TRIGGER` | トリガー文字列（既定 `/review`） |
| `CLAUDE_REVIEW_POLL_INTERVAL` | ポーリング間隔（秒） |
| `CLAUDE_REVIEW_WORKDIR` | リポジトリのローカルクローン置き場 |

## 動作確認（前景実行）

```bash
./daemon.sh
```

起動した状態で、対象PRに `/review` とコメントすると、次のポーリングで検知され、
`claude -p` によるレビュー後に `gh pr review` が実行される。

## 常駐化（launchd）

```bash
./install.sh
```

`~/Library/LaunchAgents/com.ryosuke-ando-lvgs.claude-review.plist` に登録され、
ログイン時に自動起動・クラッシュ時は自動再起動する。ログは
`~/.claude-review-local/daemon.log`。

停止する場合:

```bash
launchctl unload ~/Library/LaunchAgents/com.ryosuke-ando-lvgs.claude-review.plist
```

## 課金について

`claude -p` はヘッドレス実行だが、このツールは `ANTHROPIC_API_KEY` を明示的に
unset してから起動する（`lib.sh` の `crl_load_config`）。これにより Claude Code の
ログイン認証（サブスク枠）が使われ、API 従量課金にはならない。

## 冪等性・安全策

- 処理済みコメントIDと `last_seen` を `~/.claude-review-local/state-<owner>__<repo>.json`
  に記録し、同一コメントを二重処理しない。
- `/review` を実行できるのは `CLAUDE_REVIEW_ALLOWED_USERS` に列挙したユーザーのみ。
- レビュー中・完了時に `<!-- claude-review-local -->` マーカー付きコメントを
  upsert し、状態が分かるようにする（既存コメントがあれば更新、無ければ新規投稿）。

## 既知の制約

- レビュー本体（diff読解〜`gh pr review`実行）は Claude 自身の agentic 実行に
  委ねているため、`review-prompt.md` の指示に従わない/`gh pr review` を
  実行し忘れるケースが稀にありうる。その場合はステータスコメントが
  「レビュー中…」のまま残るので、ログ（`daemon.log`）を確認すること。
- 複数リポを監視する場合、リポごとに独立した state ファイルでポーリングする
  （並列実行はしないため、リポ数が多いとレビュー完了まで直列で待つ）。
