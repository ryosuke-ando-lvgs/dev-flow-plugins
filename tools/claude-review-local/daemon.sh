#!/usr/bin/env bash
# 監視対象リポの issue comment をポーリングし、/review コメントを検知したら
# review-once.sh に処理を委譲するループ本体。
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$CRL_DIR/lib.sh"

crl_load_config

crl_log "claude-review-local daemon 起動 (全リポ横断検索モード / allowed_users: $CLAUDE_REVIEW_ALLOWED_USERS / interval: ${CLAUDE_REVIEW_POLL_INTERVAL}s)"

GLOBAL_STATE_FILE="$CLAUDE_REVIEW_STATE_DIR/state-global.json"

# 自分（許可ユーザー）が /review とコメントした PR を、リポジトリを問わず
# GitHub Search API (`in:comments` + `commenter:`) で横断検索する。
# 静的なリポジトリリストを持たないため、閲覧可能などのリポでも動く。
poll_global() {
  local last_seen="1970-01-01T00:00:00Z"
  if [ -f "$GLOBAL_STATE_FILE" ]; then
    last_seen="$(jq -r '.last_seen // "1970-01-01T00:00:00Z"' "$GLOBAL_STATE_FILE")"
  fi

  local allowed commenter_q issues
  commenter_q=""
  for allowed in $CLAUDE_REVIEW_ALLOWED_USERS; do
    commenter_q="$commenter_q commenter:$allowed"
  done

  issues="$(gh api search/issues -X GET --paginate \
    -f q="$CLAUDE_REVIEW_TRIGGER in:comments is:pr$commenter_q" \
    --jq '[.items[] | {repo: (.repository_url | sub(".*/repos/"; "")), number}]' 2>/dev/null || echo '[]')"

  local count
  count="$(echo "$issues" | jq 'length')"
  local i=0
  while [ "$i" -lt "$count" ]; do
    local item repo pr_number
    item="$(echo "$issues" | jq -c ".[$i]")"
    repo="$(echo "$item" | jq -r '.repo')"
    pr_number="$(echo "$item" | jq -r '.number')"
    i=$((i + 1))

    # 検索結果のPR単位から、実際の該当コメントを取り直して created_at / author を確定する。
    local comments c_count j
    comments="$(gh api "repos/$repo/issues/$pr_number/comments" -X GET --paginate \
      -f since="$last_seen" \
      --jq "[.[] | select(.body | startswith(\"$CLAUDE_REVIEW_TRIGGER\"))]" 2>/dev/null || echo '[]')"
    c_count="$(echo "$comments" | jq 'length')"
    j=0
    while [ "$j" -lt "$c_count" ]; do
      local c created_at comment_id author
      c="$(echo "$comments" | jq -c ".[$j]")"
      created_at="$(echo "$c" | jq -r '.created_at')"
      comment_id="$(echo "$c" | jq -r '.id')"
      author="$(echo "$c" | jq -r '.user.login')"
      j=$((j + 1))

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
