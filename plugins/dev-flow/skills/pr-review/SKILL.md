---
name: pr-review
description: 既存のPRをレビューし、観点を1観点1コメントで個別投稿する。GitHub(gh)/Gitea(tea)を自動判定する。「PRをレビューして」「PRにコメントして」「観点ごとにコメント」「pr-review」などのリクエストで使用。
---

# pr-review（PRレビュー投稿）

PR の変更をレビューし、観点ごとに個別コメントとして投稿する。

## 0. リモート種別の判定（最初に必ず）
```bash
git remote -v
```
- `github.com` → **GitHub モード**（`gh`） / Gitea → **Gitea モード**（`tea`、`gh` 不可）

## 引数
`$ARGUMENTS` にPR番号・リポジトリ・重点観点を受け取る。無指定なら現在ブランチのPRを対象。

## 手順

### Step 1: PR差分の取得
GitHub:
```bash
gh pr view <PR番号> --json title,body,headRefName
gh pr diff <PR番号>
```
Gitea:
```bash
tea pr <PR番号> --login <login名>
# 差分は当該ブランチを fetch して git diff で確認
```

### Step 2: 観点別レビュー
正しさ/バグ・要件適合・設計/再利用・セキュリティ・テスト の観点で指摘を整理する
（詳細観点は review スキルと同様）。

### Step 3: 1観点1コメントで投稿
**1観点＝1コメント**に分ける（まとめない）。各コメント末尾に規約のメンションを付ける。

GitHub:
```bash
gh pr comment <PR番号> --body "**【観点①】<見出し>**

<本文>"
```
Gitea:
```bash
tea comment <PR番号> --login <login名> "**【観点①】<見出し>**

<本文>"
```
観点②③…も個別に実行。

### Step 4: 報告
投稿した観点の一覧を報告する。継続監視して返信したい場合は `comment-fix` に引き継ぐ。

## 注意事項
- コメント削除（`curl -X DELETE`）は環境でブロックされることがある。やり直しは PATCH（編集）で。
- 重要度順に。確証の低い指摘は「要確認」と明示する。
