# claude-review-local セットアップ手順

自分のマシン上の Claude Code（サブスク認証）で、GitHub PR への `/review` コメントを
トリガーに自動レビューを行うローカル常駐ツールです。ツールの仕組み・動作の詳細は
[README.md](./README.md) を参照してください。ここではセットアップ手順のみをまとめます。

## 前提条件

- `claude`（Claude Code CLI）にログイン済みで `claude -p "hi"` が通ること
- `gh` CLI にログイン済みであること（`gh auth status`）
- `jq` がインストールされていること（`brew install jq`）
- macOS（launchd での常駐化を想定。手動起動のみなら他OSでも動く）

## 1. リポジトリを取得する

このツールは `dev-flow-plugins` リポジトリの `tools/claude-review-local/` に含まれます。
既にどこかにクローン済みならそのディレクトリを使ってください。

```bash
git clone git@github.com:ryosuke-ando-lvgs/dev-flow-plugins.git
cd dev-flow-plugins/tools/claude-review-local
```

## 2. 設定ファイルを作成する

```bash
cp config.example.env config.env
$EDITOR config.env
```

最低限、以下を自分用に変更してください。

| 変数 | 内容 |
| --- | --- |
| `CLAUDE_REVIEW_ALLOWED_USERS` | `/review` / `/fill` を実行してよい自分のGitHubログイン名 |
| `CLAUDE_REVIEW_CLAUDE_BIN` | `which claude` の絶対パス（launchd はログインシェルのPATHを継承しないため必須） |

他の項目（トリガー文字列・ポーリング間隔・並列数など）は既定値のままで問題ありません。

`config.env` は `.gitignore` 対象なので、コミットされる心配はありません。

## 3. 前景実行で動作確認する

常駐化する前に、まず前景で動くか確認します。

```bash
./daemon.sh
```

起動した状態で、自分がアクセス権を持つ任意のリポジトリのPRに `/review` とコメントすると、
次のポーリング（既定90秒）で検知され、レビューが実行されます。ログはターミナルに
そのまま出力されます。うまく動いたら `Ctrl+C` で止めて次に進んでください。

## 4. 常駐化する（launchd）

```bash
./install.sh
```

これで以下が設定されます。

- `~/Library/LaunchAgents/com.ryosuke-ando-lvgs.claude-review.plist` に登録され、
  ログイン時に自動起動・クラッシュ時は自動再起動する
- `main` ブランチで `git pull` した際、`tools/claude-review-local/` 配下に変更が
  含まれていれば自動でデーモンを再起動する `post-merge` git hook

ログは `~/.claude-review-local/daemon.log` に出力されます。

停止する場合:

```bash
launchctl unload ~/Library/LaunchAgents/com.ryosuke-ando-lvgs.claude-review.plist
```

## 5. 使い方

- レビューしてほしいPRに `/review` とコメントする
- タイトルだけ入力してテンプレの項目が空のIssue（bug/story等）に `/fill` とコメントすると、
  項目構成は変えずに中身だけをリポジトリの内容から推測して埋める

いずれも処理中・完了時に `<!-- claude-review-local -->` マーカー付きのステータスコメントと
リアクションで状態が分かります。

## うまく動かないとき

- `~/.claude-review-local/daemon.log` を確認する
- 初めてレビューする対象リポジトリでは、ローカルクローン時に
  「このworkspaceが信頼されていない」という警告が出ることがあります。その場合は
  `cd ~/.claude-review-local/repos/<owner>_<repo> && claude` を一度対話実行して
  信頼ダイアログを承認してください
- その他の既知の制約は [README.md の「既知の制約」](./README.md#既知の制約) を参照
