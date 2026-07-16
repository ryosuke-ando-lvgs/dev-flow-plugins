#!/usr/bin/env bash
# 1件の /review コメントを処理する: リポ更新 → claude -p でレビュー判定を取得 → gh pr review 投稿。
# claudeにはgh/gitコマンドの実行権限を一切与えず、Read/Grep/Globのみで
# ローカルチェックアウト済みのコードを参照させ、判定結果はテキストで受け取る。
# 実際のGitHub書き込み（gh pr review）は本スクリプト側が行う。
# 使い方: review-once.sh <owner/repo> <pr_number> <comment_id>
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$CRL_DIR/lib.sh"

crl_load_config

REPO="$1"
PR_NUMBER="$2"
COMMENT_ID="$3"

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
REPO_SLUG="$(echo "$REPO" | tr '/' '__')"
REPO_DIR="$CLAUDE_REVIEW_WORKDIR/$REPO_SLUG"
MARKER="<!-- claude-review-local -->"
SELF_LOGIN="$(gh api user --jq .login 2>/dev/null || echo "")"

# 同一リポジトリの並列実行はローカルクローン(REPO_DIR)を共有するため、
# git checkout 等が競合しないようリポジトリ単位で直列化する（別リポは並列可）。
LOCK_DIR="$CLAUDE_REVIEW_STATE_DIR/locks"
mkdir -p "$LOCK_DIR"
REPO_LOCK="$LOCK_DIR/${REPO_SLUG}.lock"
while ! mkdir "$REPO_LOCK" 2>/dev/null; do
  sleep 2
done
trap 'rmdir "$REPO_LOCK" 2>/dev/null || true; rm -f "${PROMPT_FILE:-}" 2>/dev/null || true' EXIT

post_status_comment() {
  local body="$1"
  local full_body
  full_body="$(printf '%s\n%s\n' "$MARKER" "$body")"

  local existing_id
  existing_id="$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"$MARKER\"))][-1].id // empty" 2>/dev/null || true)"

  if [ -n "$existing_id" ]; then
    gh api "repos/$REPO/issues/comments/$existing_id" -X PATCH -f body="$full_body" >/dev/null
  else
    gh api "repos/$REPO/issues/$PR_NUMBER/comments" -X POST -f body="$full_body" >/dev/null
  fi
}

# トリガーとなった /review コメント自体にリアクションを付け、一目で状態が分かるようにする。
# 同じ内容のリアクションはGitHub側で重複作成されないため、都度POSTするだけでよい。
set_trigger_reaction() {
  local content="$1"
  gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" -X POST -f content="$content" >/dev/null 2>&1 || true
}

clear_trigger_reaction() {
  local content="$1"
  local reaction_id
  reaction_id="$(gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" --paginate \
    --jq "[.[] | select(.content == \"$content\" and .user.login == \"$SELF_LOGIN\")][0].id // empty" 2>/dev/null || true)"
  [ -n "$reaction_id" ] && gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions/$reaction_id" -X DELETE >/dev/null 2>&1 || true
}

crl_log "PR #${PR_NUMBER} (${REPO}) のレビューを開始します（comment_id=${COMMENT_ID}）"
set_trigger_reaction "eyes"
post_status_comment "🤖 ローカル Claude がレビュー中です…しばらくお待ちください。"

# --- リポジトリのローカルクローンを最新化 ---
if [ ! -d "$REPO_DIR/.git" ]; then
  gh repo clone "$REPO" "$REPO_DIR" -- --quiet
fi

PR_HEAD_REF="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName --jq .headRefName)"

(
  cd "$REPO_DIR"
  git fetch --quiet origin "$PR_HEAD_REF"
  git checkout --quiet -B "review/$PR_HEAD_REF" "FETCH_HEAD"
)

# --- PR情報・diffの取得は全てこのスクリプト（gh）側で行う。claudeにはgh/gitを一切実行させない ---
PR_TITLE="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title --jq .title)"
PR_BODY="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body --jq .body)"
PR_DIFF="$(gh pr diff "$PR_NUMBER" --repo "$REPO")"

# --- レビュープロンプト生成（プレースホルダ置換はsedではなくpython3のリテラル置換で行う。
#     diffには正規表現特殊文字や改行が含まれるためsedでは壊れる） ---
PROMPT_FILE="$(mktemp)"

OWNER="$OWNER" NAME="$NAME" PR_NUMBER="$PR_NUMBER" PR_TITLE="$PR_TITLE" PR_BODY="$PR_BODY" PR_DIFF="$PR_DIFF" \
  TEMPLATE_PATH="$CRL_DIR/review-prompt.md" OUTPUT_PATH="$PROMPT_FILE" \
  python3 -c '
import os
template = open(os.environ["TEMPLATE_PATH"]).read()
for key in ["OWNER", "REPO", "PR_NUMBER", "PR_TITLE", "PR_BODY", "PR_DIFF"]:
    env_key = "NAME" if key == "REPO" else key
    template = template.replace("{{" + key + "}}", os.environ.get(env_key, ""))
open(os.environ["OUTPUT_PATH"], "w").write(template)
'

# --- claude -p 実行（サブスク認証。ANTHROPIC_API_KEY は crl_load_config で unset 済み）。
#     Bashツールは一切許可せず、Read/Grep/Globのみ許可する。
#     claude自身はgh pr reviewを実行せず、判定結果をテキストで出力するだけにし、
#     実際のGitHub書き込み（gh pr review）はこのスクリプト側で行う。
#     これにより確認待ち（プランモード等）で止まる余地自体をなくす。 ---
set +e
CLAUDE_OUTPUT="$(cd "$REPO_DIR" && "$CLAUDE_REVIEW_CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
  --allowedTools "Read" "Grep" "Glob")"
CLAUDE_EXIT=$?
set -e

clear_trigger_reaction "eyes"

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  crl_log "claude -p が失敗しました（exit=${CLAUDE_EXIT}）"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ ローカル Claude でのレビューに失敗しました（exit=${CLAUDE_EXIT}）。ログを確認してください。"
  exit 0
fi

REVIEW_ACTION="$(echo "$CLAUDE_OUTPUT" | grep -m1 -oE 'ACTION:[[:space:]]*(approve|comment|request-changes)' | sed -E 's/ACTION:[[:space:]]*//')"
REVIEW_BODY="$(echo "$CLAUDE_OUTPUT" | sed -n '/^---$/,$p' | tail -n +2)"

if [ -z "$REVIEW_ACTION" ] || [ -z "$REVIEW_BODY" ]; then
  crl_log "claude -p の出力からACTION/本文を解析できませんでした: $CLAUDE_OUTPUT"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ ローカル Claude の出力形式が不正でレビューを解析できませんでした。ログを確認してください。"
  exit 0
fi

GH_FLAG="--comment"
case "$REVIEW_ACTION" in
  approve) GH_FLAG="--approve" ;;
  request-changes) GH_FLAG="--request-changes" ;;
  comment) GH_FLAG="--comment" ;;
esac

# --- 実際のレビュー投稿はこのスクリプト（gh pr review）が行う ---
REVIEW_ERR_FILE="$(mktemp)"
set +e
gh pr review "$PR_NUMBER" --repo "$REPO" $GH_FLAG -b "$REVIEW_BODY" 2>"$REVIEW_ERR_FILE" >/dev/null
REVIEW_EXIT=$?
set -e

if [ "$REVIEW_EXIT" -ne 0 ] && [ "$GH_FLAG" != "--comment" ]; then
  # GitHubの仕様上、PR作者本人は自分のPRをapprove/request-changesできない（self-review制限）。
  # その場合は同内容で --comment にフォールバックする。
  crl_log "gh pr review ($GH_FLAG) が失敗したため --comment にフォールバックします: $(cat "$REVIEW_ERR_FILE" 2>/dev/null || true)"
  set +e
  gh pr review "$PR_NUMBER" --repo "$REPO" --comment -b "$REVIEW_BODY" >/dev/null 2>"$REVIEW_ERR_FILE"
  REVIEW_EXIT=$?
  set -e
fi
rm -f "$REVIEW_ERR_FILE" 2>/dev/null || true

if [ "$REVIEW_EXIT" -ne 0 ]; then
  crl_log "gh pr review の投稿に失敗しました"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ レビュー結果の投稿に失敗しました。ログを確認してください。"
  exit 0
fi

ACTION_LABEL="コメント"
case "$REVIEW_ACTION" in
  approve) ACTION_LABEL="Approve" ;;
  request-changes) ACTION_LABEL="Request changes" ;;
  comment) ACTION_LABEL="コメント" ;;
esac

set_trigger_reaction "+1"
post_status_comment "✅ ローカル Claude によるレビューが完了しました（${ACTION_LABEL}）。詳細は上記の Review を確認してください。"
crl_log "PR #$PR_NUMBER のレビューが完了しました（action=${REVIEW_ACTION}）"
