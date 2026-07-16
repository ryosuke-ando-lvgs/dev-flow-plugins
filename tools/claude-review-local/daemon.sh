#!/usr/bin/env bash
# 監視対象リポの issue comment をポーリングし、/review コメントを検知したら
# review-once.sh に処理を委譲するループ本体。
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$CRL_DIR/lib.sh"

crl_load_config

crl_log "claude-review-local daemon 起動 (repos: $CLAUDE_REVIEW_REPOS / interval: ${CLAUDE_REVIEW_POLL_INTERVAL}s)"

poll_repo() {
  local repo="$1"
  local state_file
  state_file="$(crl_state_file "$repo")"

  local last_seen="1970-01-01T00:00:00Z"
  if [ -f "$state_file" ]; then
    last_seen="$(jq -r '.last_seen // "1970-01-01T00:00:00Z"' "$state_file")"
  fi

  # issue コメント（PRコメントもここに含まれる）を取得し、last_seen より新しいものだけ処理対象にする。
  # `since` で GitHub 側にも絞り込ませ、毎回全履歴を取得しないようにする。
  local comments
  comments="$(gh api "repos/$repo/issues/comments" \
    -X GET \
    --paginate \
    -f sort=created -f direction=asc -f since="$last_seen" \
    --jq '[.[] | select(.issue_url | test("/pull/"))]' 2>/dev/null || echo '[]')"

  local count
  count="$(echo "$comments" | jq 'length')"
  local i=0
  while [ "$i" -lt "$count" ]; do
    local c created_at comment_id author body pr_number
    c="$(echo "$comments" | jq -c ".[$i]")"
    created_at="$(echo "$c" | jq -r '.created_at')"
    comment_id="$(echo "$c" | jq -r '.id')"
    author="$(echo "$c" | jq -r '.user.login')"
    body="$(echo "$c" | jq -r '.body')"
    pr_number="$(echo "$c" | jq -r '.issue_url' | sed -E 's#.*/pull/([0-9]+)$#\1#')"
    i=$((i + 1))

    # last_seen 以前はスキップ
    if [[ "$created_at" < "$last_seen" || "$created_at" == "$last_seen" ]]; then
      continue
    fi

    if crl_is_processed "$state_file" "$comment_id"; then
      continue
    fi

    if [[ "$body" != "$CLAUDE_REVIEW_TRIGGER"* ]]; then
      crl_mark_processed "$state_file" "$comment_id" "$created_at"
      continue
    fi

    if ! crl_is_allowed_user "$author"; then
      crl_log "許可されていないユーザーからの $CLAUDE_REVIEW_TRIGGER をスキップ: $author (repo=$repo, pr=$pr_number)"
      crl_mark_processed "$state_file" "$comment_id" "$created_at"
      continue
    fi

    crl_log "トリガー検知: repo=$repo pr=$pr_number author=$author comment_id=$comment_id"
    if "$CRL_DIR/review-once.sh" "$repo" "$pr_number" "$comment_id"; then
      crl_mark_processed "$state_file" "$comment_id" "$created_at"
    else
      crl_log "review-once.sh が失敗しました (repo=$repo pr=$pr_number)。次回もリトライ対象にはせず処理済みにします。"
      crl_mark_processed "$state_file" "$comment_id" "$created_at"
    fi
  done
}

while true; do
  for repo in $CLAUDE_REVIEW_REPOS; do
    poll_repo "$repo" || crl_log "poll_repo($repo) でエラーが発生しましたが継続します"
  done
  sleep "$CLAUDE_REVIEW_POLL_INTERVAL"
done
