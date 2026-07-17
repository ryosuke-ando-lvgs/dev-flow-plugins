#!/usr/bin/env bash
# 1件の /fill コメントを処理する: リポ更新 → claude -p でIssue本文の埋め込み案を取得 → Issue本文を更新。
# claudeにはgh/gitコマンドの実行権限を一切与えず、Read/Grep/Glob/WebFetch/WebSearchのみで
# ローカルチェックアウト済みのコードや外部情報を参照させ、埋め込み後の本文はテキストで受け取る。
# 実際のGitHub書き込み（Issue本文の更新）は本スクリプト側が行う。
# 使い方: issue-fill-once.sh <owner/repo> <issue_number> <comment_id>
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$CRL_DIR/lib.sh"

crl_load_config

REPO="$1"
ISSUE_NUMBER="$2"
COMMENT_ID="$3"

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
REPO_SLUG="$(echo "$REPO" | tr '/' '__')"
REPO_DIR="$CLAUDE_REVIEW_WORKDIR/$REPO_SLUG"
MARKER="<!-- claude-review-local -->"

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
  existing_id="$(gh api "repos/$REPO/issues/$ISSUE_NUMBER/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"$MARKER\"))][-1].id // empty" 2>/dev/null || true)"

  if [ -n "$existing_id" ]; then
    gh api "repos/$REPO/issues/comments/$existing_id" -X PATCH -f body="$full_body" >/dev/null
  else
    gh api "repos/$REPO/issues/$ISSUE_NUMBER/comments" -X POST -f body="$full_body" >/dev/null
  fi
}

set_trigger_reaction() {
  local content="$1"
  gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" -X POST -f content="$content" >/dev/null 2>&1 || true
}

clear_trigger_reaction() {
  local content="$1"
  local self_login reaction_id
  self_login="$(gh api user --jq .login 2>/dev/null || echo "")"
  reaction_id="$(gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" --paginate \
    --jq "[.[] | select(.content == \"$content\" and .user.login == \"$self_login\")][0].id // empty" 2>/dev/null || true)"
  [ -n "$reaction_id" ] && gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions/$reaction_id" -X DELETE >/dev/null 2>&1 || true
}

crl_log "Issue #${ISSUE_NUMBER} (${REPO}) の本文埋め込みを開始します（comment_id=${COMMENT_ID}）"

ISSUE_STATE="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json state --jq .state)"
if [ "$ISSUE_STATE" != "OPEN" ]; then
  crl_log "Issue #${ISSUE_NUMBER} (${REPO}) は既に ${ISSUE_STATE} のため埋め込みをスキップします"
  set_trigger_reaction "confused"
  post_status_comment "ℹ️ このIssueは既に ${ISSUE_STATE} のため、本文埋め込みをスキップしました。"
  exit 0
fi

set_trigger_reaction "eyes"
post_status_comment "🤖 ローカル Claude が本文の埋め込みを検討中です…しばらくお待ちください。"

if [ ! -d "$REPO_DIR/.git" ]; then
  gh repo clone "$REPO" "$REPO_DIR" -- --quiet
fi

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"

(
  cd "$REPO_DIR"
  git fetch --quiet origin "$DEFAULT_BRANCH"
  git checkout --quiet -B "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
)

ISSUE_TITLE="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title --jq .title)"
ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body --jq .body)"
ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '[.labels[].name] | join(", ")')"

PROMPT_FILE="$(mktemp)"

OWNER="$OWNER" NAME="$NAME" ISSUE_NUMBER="$ISSUE_NUMBER" ISSUE_TITLE="$ISSUE_TITLE" \
  ISSUE_BODY="$ISSUE_BODY" ISSUE_LABELS="$ISSUE_LABELS" \
  TEMPLATE_PATH="$CRL_DIR/issue-fill-prompt.md" OUTPUT_PATH="$PROMPT_FILE" \
  python3 -c '
import os
template = open(os.environ["TEMPLATE_PATH"]).read()
for key in ["OWNER", "NAME", "ISSUE_NUMBER", "ISSUE_TITLE", "ISSUE_BODY", "ISSUE_LABELS"]:
    template = template.replace("{{" + key + "}}", os.environ.get(key, ""))
open(os.environ["OUTPUT_PATH"], "w").write(template)
'

set +e
CLAUDE_OUTPUT="$(cd "$REPO_DIR" && "$CLAUDE_REVIEW_CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
  --allowedTools "Read" "Grep" "Glob" "WebFetch" "WebSearch")"
CLAUDE_EXIT=$?
set -e

clear_trigger_reaction "eyes"

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  crl_log "claude -p が失敗しました（exit=${CLAUDE_EXIT}）"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ ローカル Claude での本文埋め込みに失敗しました（exit=${CLAUDE_EXIT}）。ログを確認してください。"
  exit 0
fi

NEW_BODY="$(echo "$CLAUDE_OUTPUT" | sed -n '/^---$/,$p' | tail -n +2)"

if [ -z "$NEW_BODY" ]; then
  crl_log "claude -p の出力から本文を解析できませんでした: $CLAUDE_OUTPUT"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ ローカル Claude の出力形式が不正で本文埋め込みを解析できませんでした。ログを確認してください。"
  exit 0
fi

# --- Issue本文の更新（項目構成は変えず内容だけ置き換える。実際の書き込みはこのスクリプトが行う） ---
UPDATE_ERR_FILE="$(mktemp)"
set +e
gh api "repos/$REPO/issues/$ISSUE_NUMBER" -X PATCH -f body="$NEW_BODY" 2>"$UPDATE_ERR_FILE" >/dev/null
UPDATE_EXIT=$?
set -e
rm -f "$UPDATE_ERR_FILE" 2>/dev/null || true

if [ "$UPDATE_EXIT" -ne 0 ]; then
  crl_log "Issue本文の更新に失敗しました"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ Issue本文の更新に失敗しました。ログを確認してください。"
  exit 0
fi

set_trigger_reaction "+1"
post_status_comment "✅ ローカル Claude によりIssue本文を埋め込みました（項目構成は維持し、内容のみ置き換え）。内容を確認してください。"
crl_log "Issue #$ISSUE_NUMBER の本文埋め込みが完了しました"
