---
name: ci-fix
description: PRのCIが失敗したら、失敗ログを取得して原因を修正し、追加コミットでpushする。CIが通るまで監視・修正を繰り返す。「CIを直して」「CIが落ちた」「ビルド失敗を修正」「ci-fix」などのリクエストで使用。
---

# ci-fix（CI失敗修正）

PR の CI を確認し、失敗を修正して green にする。

## 0. リモート種別の判定（最初に必ず）
```bash
git remote -v
```
- `github.com` → **GitHub モード**（`gh`） / Gitea → **Gitea モード**（`tea` / API）

## 引数
`$ARGUMENTS` にPR番号を受け取る。無指定なら現在ブランチのPRを対象。

## 手順

### Step 1: CI状態の確認
GitHub:
```bash
gh pr checks <PR番号>
gh run list --branch <ブランチ名> --limit 5
```
Gitea: `tea pr <PR番号>` でステータス確認、CI（Actions/Drone等）の該当を特定。

成功していれば「green」を報告して終了。

### Step 2: 失敗ログの取得
GitHub:
```bash
gh run view <run-id> --log-failed
```
失敗した job/step とエラーメッセージを特定する。Gitea は CI UI/API からログを取得。

### Step 3: 原因の特定と修正
- lint / 型 / test / build いずれの失敗かを切り分ける。
- ローカルで再現できるものは `pretest` 相当を実行して確認しながら直す。
- 環境依存（flaky・キャッシュ・シークレット）の可能性も考慮し、コード修正で済まない場合は報告。

### Step 4: 追加コミットして push
```bash
git add -A && git commit -m "fix: <CI修正内容>"
git push
```
`--amend` / force push は使わない。

### Step 5: 再確認
push 後に再度 CI を確認する。落ち着くまで監視したい場合は `ScheduleWakeup` で **60秒（1分）間隔** の
再チェックをスケジュールする。green になり、かつユーザーからの明示的な停止指示があるか
PR がマージ/クローズされていれば報告して監視終了。green になっただけでは監視を終了せず、
次のラウンドでも CI 状態を確認し続ける（新規pushやコメントで再度落ちる可能性があるため）。

## 注意事項
- 失敗の根本原因を直す。テストを無効化して通すような誤魔化しはしない。
- 直せない/環境起因の失敗は正直に報告し、対応方針を確認する。
- 監視を止めるのは、ユーザーからの明示的な停止指示を受けたとき、または PR がマージ/クローズされたときのみ。
