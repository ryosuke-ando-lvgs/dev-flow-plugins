#!/usr/bin/env bash
# GitHub Events API で許可ユーザー自身の /review コメントを検知したら
# review-once.sh に処理を委譲するループ本体。
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$CRL_DIR/lib.sh"

crl_load_config

crl_log "claude-review-local daemon 起動 (Events APIモード / allowed_users: $CLAUDE_REVIEW_ALLOWED_USERS / interval: ${CLAUDE_REVIEW_POLL_INTERVAL}s)"

GLOBAL_STATE_FILE="$CLAUDE_REVIEW_STATE_DIR/state-global.json"

# 許可ユーザー本人の GitHub Events API (`users/{login}/events`) から
# 自身が投稿した IssueCommentEvent を取得し、/review トリガーコメントを検知する。
# GitHub Search API と異なりインデックス遅延が実質無く、静的なリポジトリリストも不要。
# コメント本文は稀に先頭に \r\n が付くことがあるため、startswith 判定前にトリムする。
poll_global() {
  local last_seen="1970-01-01T00:00:00Z"
  if [ -f "$GLOBAL_STATE_FILE" ]; then
    last_seen="$(jq -r '.last_seen // "1970-01-01T00:00:00Z"' "$GLOBAL_STATE_FILE")"
  fi

  local allowed
  for allowed in $CLAUDE_REVIEW_ALLOWED_USERS; do
    local events count i
    events="$(gh api "users/$allowed/events" -X GET --paginate \
      --jq '[.[] | select(.type=="IssueCommentEvent" and .payload.issue.pull_request != null and (.payload.comment.body | sub("^[\r\n]+"; "") | startswith("'"$CLAUDE_REVIEW_TRIGGER"'"))) | {repo: .repo.name, number: .payload.issue.number, comment_id: .payload.comment.id, created_at: .payload.comment.created_at, author: .actor.login}]' 2>/dev/null || echo '[]')"

    count="$(echo "$events" | jq 'length')"
    i=0
    while [ "$i" -lt "$count" ]; do
      local item repo pr_number created_at comment_id author
      item="$(echo "$events" | jq -c ".[$i]")"
      repo="$(echo "$item" | jq -r '.repo')"
      pr_number="$(echo "$item" | jq -r '.number')"
      created_at="$(echo "$item" | jq -r '.created_at')"
      comment_id="$(echo "$item" | jq -r '.comment_id')"
      author="$(echo "$item" | jq -r '.author')"
      i=$((i + 1))

      if [[ "$created_at" < "$last_seen" || "$created_at" == "$last_seen" ]]; then
        continue
      fi

      if crl_is_processed "$GLOBAL_STATE_FILE" "$comment_id"; then
        continue
      fi

      if ! crl_is_allowed_user "$author"; then
        crl_mark_processed "$GLOBAL_STATE_FILE" "$comment_id" "$created_at"
        continue
      fi

      crl_log "トリガー検知: repo=$repo pr=$pr_number author=$author comment_id=$comment_id"
      # 成功・失敗どちらでも二重処理防止のため先に処理済みにし、実行はバックグラウンドで並列化する。
      # 同一リポジトリの同時実行は review-once.sh 側のロックで直列化される。
      crl_mark_processed "$GLOBAL_STATE_FILE" "$comment_id" "$created_at"

      while [ "$(jobs -rp | wc -l)" -ge "$CLAUDE_REVIEW_MAX_PARALLEL" ]; do
        wait -n 2>/dev/null || sleep 1
      done
      (
        "$CRL_DIR/review-once.sh" "$repo" "$pr_number" "$comment_id" \
          || crl_log "review-once.sh が失敗しました (repo=$repo pr=$pr_number)"
      ) &
    done
  done
}

while true; do
  poll_global || crl_log "poll_global でエラーが発生しましたが継続します"
  sleep "$CLAUDE_REVIEW_POLL_INTERVAL"
done
