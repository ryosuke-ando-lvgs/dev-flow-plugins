---
name: comment-fix
description: PRに付いた新規コメント/レビューを監視し、観点ごとに返信して必要ならコード修正をpushする。GitHub(gh)/Gitea(tea)を自動判定し、ScheduleWakeupで定期監視する。「コメントを拾って修正して」「レビュー対応」「指摘を直して」「comment-fix」などのリクエストで使用。
---

# comment-fix（コメント対応）

PR の新規コメントを監視し、返信＋必要な修正を行う。

## 0. リモート種別の判定（最初に必ず）
```bash
git remote -v
```
- `github.com` → **GitHub モード**（`gh` / API） / Gitea → **Gitea モード**（`tea` / API）

## 引数
`$ARGUMENTS` にPR番号・対象の絞り込み（自分がauthorのPRのみ 等）を受け取る。

## 手順

### Step 1: 監視基準の記録
「ここまで見た」基準を scratchpad に保存する。issue コメントとレビュー(インライン)コメントは
ID空間が別なので、両方を横断できる `created_at` の最大時刻を基準にすると堅い。

GitHub:
```bash
issue="$(gh api repos/<owner>/<repo>/issues/<PR番号>/comments --jq '[.[].created_at] | max // "1970-01-01T00:00:00Z"')"
review="$(gh api repos/<owner>/<repo>/pulls/<PR番号>/comments  --jq '[.[].created_at] | max // "1970-01-01T00:00:00Z"')"
printf '%s\n%s\n' "$issue" "$review" | sort | tail -1 > <scratchpad>/pr<番号>_last_seen.txt
```

### Step 2: 新規コメントの抽出
issue/review 両方のコメントを取得し、`last_seen` より新しく **author が自分以外** のものを新規とする。

### Step 3: 観点ごとに返信
新規コメントの論点を読み取り、**1論点1コメント**で返信する（規約のメンション付き）。

### Step 4: 必要なら修正して push
コード修正が必要なら編集 → **追加コミット** → 通常 push で反映し、対応内容を該当コメントに返信する。
「返信のみ（修正は承認後）」の依頼なら修正案を提示して承認を待つ。

### Step 5: 基準更新と再スケジュール
返信後、`last_seen` を最新の created_at に更新。継続監視するなら `ScheduleWakeup` で同じ
prompt を **60秒（1分）間隔** で再帰スケジュールする。
新規コメントが無いラウンドでも、ユーザーからの明示的な停止指示や PR のマージ/クローズが
確認できるまでは再スケジュールを続ける（1ラウンド静かだっただけで監視を終わらせない）。

## 注意事項
- `--amend` / force push 禁止。修正は追加コミットで積む。
- コメント削除はブロックされることがある。やり直しは PATCH（編集）で。
- 監視を止めるのは、ユーザーからの明示的な停止指示を受けたとき、または PR がマージ/クローズされたときのみ。それ以外は新規コメントが無くても再スケジュールを続ける。
