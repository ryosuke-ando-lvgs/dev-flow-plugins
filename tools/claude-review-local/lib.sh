#!/usr/bin/env bash
# tools/claude-review-local の共通関数群。daemon.sh / review-once.sh から source される。
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

crl_load_config() {
  local config_file="${1:-$CRL_DIR/config.env}"
  if [ ! -f "$config_file" ]; then
    echo "[claude-review-local] config が見つかりません: $config_file" >&2
    echo "  cp config.example.env config.env としてから編集してください。" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$config_file"

  : "${CLAUDE_REVIEW_ALLOWED_USERS:?CLAUDE_REVIEW_ALLOWED_USERS が未設定です}"
  : "${CLAUDE_REVIEW_TRIGGER:=/review}"
  : "${CLAUDE_REVIEW_FILL_TRIGGER:=/fill}"
  : "${CLAUDE_REVIEW_POLL_INTERVAL:=90}"
  : "${CLAUDE_REVIEW_WORKDIR:=$HOME/.claude-review-local/repos}"
  : "${CLAUDE_REVIEW_STATE_DIR:=$HOME/.claude-review-local}"
  : "${CLAUDE_REVIEW_CLAUDE_BIN:=claude}"
  : "${CLAUDE_REVIEW_MAX_PARALLEL:=3}"

  mkdir -p "$CLAUDE_REVIEW_WORKDIR" "$CLAUDE_REVIEW_STATE_DIR"

  # サブスク認証を強制するため、API課金経路の環境変数はここで確実に落とす。
  unset ANTHROPIC_API_KEY || true
}

crl_state_file() {
  local repo_slug
  repo_slug="$(echo "$1" | tr '/' '__')"
  echo "$CLAUDE_REVIEW_STATE_DIR/state-${repo_slug}.json"
}

crl_is_processed() {
  local state_file="$1" comment_id="$2"
  [ -f "$state_file" ] || return 1
  jq -e --arg id "$comment_id" '.processed_ids | index($id) != null' "$state_file" >/dev/null 2>&1
}

crl_mark_processed() {
  local state_file="$1" comment_id="$2" created_at="$3" last_seen_key="${4:-last_seen}"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$state_file" ]; then
    jq \
      --arg id "$comment_id" \
      --arg ts "$created_at" \
      --arg lsk "$last_seen_key" \
      '.processed_ids = ((.processed_ids // []) + [$id] | unique | .[-200:]) | .[$lsk] = ([.[$lsk] // "1970-01-01T00:00:00Z", $ts] | max)' \
      "$state_file" > "$tmp"
  else
    jq -n --arg id "$comment_id" --arg ts "$created_at" --arg lsk "$last_seen_key" \
      '{processed_ids: [$id]} + {($lsk): $ts}' > "$tmp"
  fi
  mv "$tmp" "$state_file"
}

crl_is_allowed_user() {
  local user="$1"
  for allowed in $CLAUDE_REVIEW_ALLOWED_USERS; do
    if [ "$allowed" = "$user" ]; then
      return 0
    fi
  done
  return 1
}

crl_log() {
  echo "[$(env TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')] $*"
}

CRL_MARKER="<!-- claude-review-local -->"

# PR/Issue共通: マーカー付きステータスコメントをupsertする（review-once.sh/issue-fill-once.shで共用）。
crl_post_status_comment() {
  local repo="$1" number="$2" body="$3"
  local full_body existing_id
  full_body="$(printf '%s\n%s\n' "$CRL_MARKER" "$body")"

  existing_id="$(gh api "repos/$repo/issues/$number/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"$CRL_MARKER\"))][-1].id // empty" 2>/dev/null || true)"

  if [ -n "$existing_id" ]; then
    gh api "repos/$repo/issues/comments/$existing_id" -X PATCH -f body="$full_body" >/dev/null
  else
    gh api "repos/$repo/issues/$number/comments" -X POST -f body="$full_body" >/dev/null
  fi
}

# トリガーコメント自体にリアクションを付け、一目で状態が分かるようにする。
crl_set_trigger_reaction() {
  local repo="$1" comment_id="$2" content="$3"
  gh api "repos/$repo/issues/comments/$comment_id/reactions" -X POST -f content="$content" >/dev/null 2>&1 || true
}

crl_clear_trigger_reaction() {
  local repo="$1" comment_id="$2" content="$3"
  local self_login reaction_id
  self_login="$(gh api user --jq .login 2>/dev/null || echo "")"
  reaction_id="$(gh api "repos/$repo/issues/comments/$comment_id/reactions" --paginate \
    --jq "[.[] | select(.content == \"$content\" and .user.login == \"$self_login\")][0].id // empty" 2>/dev/null || true)"
  [ -n "$reaction_id" ] && gh api "repos/$repo/issues/comments/$comment_id/reactions/$reaction_id" -X DELETE >/dev/null 2>&1 || true
}

# 同一リポジトリの並列実行はローカルクローンを共有するため、リポジトリ単位で直列化する。
# 取得したロックディレクトリのパスを標準出力に返す（呼び出し側でtrapによる解放が必要）。
crl_acquire_repo_lock() {
  local repo_slug="$1"
  local lock_dir="$CLAUDE_REVIEW_STATE_DIR/locks"
  mkdir -p "$lock_dir" >&2
  local lock="$lock_dir/${repo_slug}.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 2
  done
  echo "$lock"
}
