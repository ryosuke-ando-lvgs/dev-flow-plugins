---
name: pr-create
description: 変更をpushしてPull Requestを作成する。リモートURLでGitHub(gh)/Gitea(tea)を自動判定し、要件・変更内容からPR本文テンプレートを生成する。「PRを作って」「プルリク作成」「pushしてPR」「pr-create」などのリクエストで使用。
---

# pr-create（PR作成）

ブランチを push し、Pull Request を作成する。

## 0. リモート種別の判定（最初に必ず）
```bash
git remote -v
```
- ホストが `github.com` → **GitHub モード**（`gh` CLI）
- ホストが Gitea（`localhost:3939` や自社Giteaドメイン）→ **Gitea モード**（`tea` CLI、`gh` 不可）

## 引数
`$ARGUMENTS` にPRタイトル・対象ブランチ・レビュアー指定などを受け取る。

## 手順

### Step 1: push 前確認
```bash
git status
git branch --show-current
git log --oneline origin/develop..HEAD   # 含まれるコミットを確認（base は develop or main）
```
未コミット変更があれば確認の上コミット。

### Step 2: push
```bash
git push -u origin <ブランチ名>
```
（`--force` は使わない。リジェクトされたら pull/rebase ではなく状況を報告し方針を確認。）

### Step 3: PR本文の生成
要件メモ・コミット内容から本文を作る。

```markdown
## 概要
何を・なぜ変えたか。

## 変更内容
- 変更点1
- 変更点2

## 動作確認
- [ ] lint / test / build pass（pretest 済み）
- [ ] 受入条件を満たす

## 関連
Issue / 要件メモ など
```

### Step 4: PR作成
GitHub:
```bash
gh pr create --base develop --title "<title>" --body "<body>"
```
Gitea:
```bash
tea pr create --base develop --title "<title>" --description "<body>" --login <login名>
```
base は `develop` が無ければ `main`。作成後、PR の URL/番号を報告する。

## 注意事項
- force push 禁止。修正は追加コミットで反映する。
- レビュアー/ラベル/メンションはプロジェクト規約に従う。
- 作成したPR番号は `pr-review` / `ci-fix` / `comment-fix` が参照する。
