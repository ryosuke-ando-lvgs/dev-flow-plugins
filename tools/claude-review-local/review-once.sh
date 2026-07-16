#!/usr/bin/env bash
# 1件の /review コメントを処理する: リポ更新 → claude -p でレビュー → gh pr review 投稿。
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

crl_log "PR #${PR_NUMBER} (${REPO}) のレビューを開始します（comment_id=${COMMENT_ID}）"
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

# --- レビュープロンプト生成 ---
PROMPT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE"' EXIT

sed \
  -e "s/{{OWNER}}/$OWNER/g" \
  -e "s/{{REPO}}/$NAME/g" \
  -e "s/{{PR_NUMBER}}/$PR_NUMBER/g" \
  "$CRL_DIR/review-prompt.md" > "$PROMPT_FILE"

# --- claude -p 実行（サブスク認証。ANTHROPIC_API_KEY は crl_load_config で unset 済み） ---
set +e
(
  cd "$REPO_DIR"
  "$CLAUDE_REVIEW_CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --allowedTools "Bash(gh pr view:*)" "Bash(gh pr diff:*)" "Bash(gh pr review:*)" "Bash(git:*)" "Read" "Grep" "Glob"
)
CLAUDE_EXIT=$?
set -e

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  crl_log "claude -p が失敗しました（exit=${CLAUDE_EXIT}）"
  post_status_comment "⚠️ ローカル Claude でのレビューに失敗しました（exit=${CLAUDE_EXIT}）。ログを確認してください。"
  exit 0
fi

post_status_comment "✅ ローカル Claude によるレビューが完了しました。"
crl_log "PR #$PR_NUMBER のレビューが完了しました"
