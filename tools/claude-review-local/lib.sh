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
  local state_file="$1" comment_id="$2" created_at="$3"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$state_file" ]; then
    jq \
      --arg id "$comment_id" \
      --arg ts "$created_at" \
      '.processed_ids = ((.processed_ids // []) + [$id] | unique | .[-200:]) | .last_seen = ([.last_seen // "1970-01-01T00:00:00Z", $ts] | max)' \
      "$state_file" > "$tmp"
  else
    jq -n --arg id "$comment_id" --arg ts "$created_at" \
      '{processed_ids: [$id], last_seen: $ts}' > "$tmp"
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
