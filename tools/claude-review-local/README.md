# claude-review-local

PR に `/review` とコメントすると、**自分のマシン上の Claude Code**（サブスク認証）が
そのPRをレビューし、review bot のように `gh pr review` で
approve / request-changes / comment を返すローカル常駐ツール。
監視対象リポジトリの固定リストは持たず、GitHub Events API
（`users/{login}/events`）で「自分（`CLAUDE_REVIEW_ALLOWED_USERS`）が
`/review` とコメントした全PR」をリポジトリ横断で検知するため、閲覧可能な
どのリポでもそのまま動く。Search API と異なりインデックス遅延が実質無く、
コメント投稿後ほぼ即座に検知される。

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
$EDITOR config.env   # 許可ユーザーなどを設定
```

`config.env` の主な項目:

| 変数 | 説明 |
| --- | --- |
| `CLAUDE_REVIEW_ALLOWED_USERS` | `/review` を実行してよいGitHubログイン名（Events API のポーリング対象ユーザーにも使う） |
| `CLAUDE_REVIEW_TRIGGER` | PRレビューのトリガー文字列（既定 `/review`） |
| `CLAUDE_REVIEW_FILL_TRIGGER` | Issue本文埋め込みのトリガー文字列（既定 `/fill`） |
| `CLAUDE_REVIEW_POLL_INTERVAL` | ポーリング間隔（秒） |
| `CLAUDE_REVIEW_WORKDIR` | リポジトリのローカルクローン置き場 |

## 動作確認（前景実行）

```bash
./daemon.sh
```

起動した状態で、対象PRに `/review` とコメントすると、次のポーリングで検知され、
レビューが実行される。

`claude -p` にはPRのタイトル・本文・diffをテキストとして渡し、`gh`/`git` コマンドの
実行権限は一切与えない。`Read`/`Grep`/`Glob`でローカルにチェックアウト済みのコードを
参照でき、加えて依存パッケージ更新PRのレビューでリリースノート/CHANGELOGを調べられる
よう`WebFetch`/`WebSearch`も許可している（いずれも読み取り専用でコマンド実行権限では
ない）。claude は `{"action": "approve|comment|request-changes", "body": "<総評Markdown>",
"findings": [{"file", "line", "severity", "message"}, ...]}` という単一のJSONオブジェクト
（```json フェンス付き）だけを返し、実際のGitHubへの投稿は `review-once.sh` 自身が
GitHub Reviews API（`gh api .../pulls/.../reviews`）経由で行う。これにより、claude が
確認待ち状態で停止して「実行したふりをして exit 0 する」問題が構造的に起こらないように
している。

レビューは GitHub 標準の Review UI として投稿され、`body` を総評としてトップレベルの
本文コメントに、`findings` のうち diff の変更範囲内に収まる指摘だけをインラインの
行コメントとして各行に付ける。diff範囲外などGitHubが受理できない指摘は自動的に除外し
（トップレベル本文には元々含まれないため内容が失われることはない）、除外件数はログに
記録される。

## Issue本文の自動埋め込み（`/fill`）

タイトルだけ入力してテンプレートの項目が空のままのIssue（bug/story等）に対し、
その Issue に `/fill`（既定。`CLAUDE_REVIEW_FILL_TRIGGER` で変更可）とコメントすると、
`/review` と同じ仕組み（ローカル Claude が Read/Grep/Glob のみで調査し、結果を
テキストで返す→実際の書き込みはスクリプト側が行う）で、
**Issueテンプレートの項目構成（見出し・フィールド名・チェックボックス等）は変えずに、
各項目の中身だけをリポジトリのコードや文脈から推測して埋める**。

- 対象はデフォルトブランチをチェックアウトして調査する（PRのdiffではなくリポジトリ全体）。
- Issue本文/タイトルは第三者が書き込める内容のため、`/review` と異なり
  `WebFetch`/`WebSearch` は許可しない（プロンプトインジェクション経由での
  外部への情報持ち出しリスクを避けるため）。
- 調査しても具体的な内容が埋められない項目は、内容を捏造せず
  「（要追記: 〜の情報が必要）」のように不足点を明記したプレースホルダを残す。
- 実際の書き込み（Issue本文の更新）は `issue-fill-once.sh` が
  `gh api repos/.../issues/... -X PATCH` で行う。claude 自身は書き込み権限を持たない。
  置き換え前に元の本文をステータスコメントへバックアップとして残す。
- 処理中・完了時は `/review` と同様に `<!-- claude-review-local -->` マーカー付き
  ステータスコメントとリアクションで状態が分かるようにする。

## 常駐化（launchd）

```bash
./install.sh
```

`~/Library/LaunchAgents/com.ryosuke-ando-lvgs.claude-review.plist` に登録され、
ログイン時に自動起動・クラッシュ時は自動再起動する。ログは
`~/.claude-review-local/daemon.log`。

`install.sh` は同時に `post-merge` git hookも設定する。`main` ブランチで
`git pull` した際、`tools/claude-review-local/` 配下に変更が含まれていれば
自動でデーモンを再起動し、最新コードを反映する（`main` 以外のブランチへの
pullやmerge先が変わらない場合は何もしない）。

停止する場合:

```bash
launchctl unload ~/Library/LaunchAgents/com.ryosuke-ando-lvgs.claude-review.plist
```

## レビュー観点のカスタマイズ

`checklists/*.md` に置いたファイルが、ファイル名の昇順で `review-prompt.md` の
`{{CHECKLISTS}}` に連結して埋め込まれる。観点を追加・変更したい場合は、この
ディレクトリにMarkdownファイルを追加・編集するだけでよい（`review-once.sh`や
`review-prompt.md`自体の変更は不要）。ファイル名先頭の数字（`00-`, `10-`, `20-`...）
は表示順の制御用。

## 自分のPRのレビューについて

GitHub の仕様上、PR作者本人は自分のPRを approve / request-changes できない
（self-review制限）。そのため自分の `gh` 認証で実行する限り、**自分のPRに対しては
常に `--comment` が使われる**（`review-prompt.md` の指示で自動フォールバック）。
approve / request-changes が欲しいのは他人のPR、または別アカウント・bot が
作成したPRの場合のみ。

## 課金について

`claude -p` はヘッドレス実行だが、このツールは `ANTHROPIC_API_KEY` を明示的に
unset してから起動する（`lib.sh` の `crl_load_config`）。これにより Claude Code の
ログイン認証（サブスク枠）が使われ、API 従量課金にはならない。

## 冪等性・安全策

- 処理済みコメントIDと `last_seen` を `~/.claude-review-local/state-global.json`
  に記録し、同一コメントを二重処理しない。
- `/review` を実行できるのは `CLAUDE_REVIEW_ALLOWED_USERS` に列挙したユーザーのみ。
- レビュー中・完了時に `<!-- claude-review-local -->` マーカー付きコメントを
  upsert し、状態が分かるようにする（既存コメントがあれば更新、無ければ新規投稿）。

## 既知の制約

- claude が指定のJSON形式に従わない/解析できない出力を返すケースが稀にありうる。
  その場合はステータスコメントに解析失敗が明記されるので、ログ（`daemon.log`）を
  確認すること。
- Events API は許可ユーザー本人の直近の公開activity（ページネーションを含め
  実用上十分な件数）を返す。長期間 `/review` を使わなかった場合など、
  非常に古いイベントは取得対象から外れることがある。
- fork からの PR（head が別リポジトリ）は `origin` に head ブランチが無く
  `git fetch origin <ref>` が失敗しうる。同一リポジトリ内のブランチ間 PR を
  前提としている。
