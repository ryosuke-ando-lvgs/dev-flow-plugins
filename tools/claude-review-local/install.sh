#!/usr/bin/env bash
# launchd に daemon.sh を常駐登録する。
set -euo pipefail

CRL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$CRL_DIR/config.env" ]; then
  echo "config.env がありません。先に作成してください:" >&2
  echo "  cp $CRL_DIR/config.example.env $CRL_DIR/config.env" >&2
  exit 1
fi

# shellcheck source=lib.sh
source "$CRL_DIR/lib.sh"
crl_load_config

PLIST_LABEL="com.ryosuke-ando-lvgs.claude-review"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_PATH="$CLAUDE_REVIEW_STATE_DIR/daemon.log"

mkdir -p "$HOME/Library/LaunchAgents" "$CLAUDE_REVIEW_STATE_DIR"

sed \
  -e "s#__DAEMON_PATH__#$CRL_DIR/daemon.sh#g" \
  -e "s#__LOG_PATH__#$LOG_PATH#g" \
  "$CRL_DIR/com.ryosuke-ando-lvgs.claude-review.plist" > "$PLIST_DEST"

launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo "インストール完了: $PLIST_DEST"
echo "ログ: $LOG_PATH"
echo "停止する場合: launchctl unload $PLIST_DEST"
