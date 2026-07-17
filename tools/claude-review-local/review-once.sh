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

# 同一リポジトリの並列実行はローカルクローン(REPO_DIR)を共有するため、
# git checkout 等が競合しないようリポジトリ単位で直列化する（別リポは並列可）。
REPO_LOCK="$(crl_acquire_repo_lock "$REPO_SLUG")"
trap 'rmdir "$REPO_LOCK" 2>/dev/null || true; rm -f "${PROMPT_FILE:-}" "${REVIEW_PAYLOAD_FILE:-}" "${REVIEW_ERR_FILE:-}" "${PARSE_RESULT_FILE:-}" 2>/dev/null || true' EXIT

post_status_comment() { crl_post_status_comment "$REPO" "$PR_NUMBER" "$1"; }
set_trigger_reaction() { crl_set_trigger_reaction "$REPO" "$COMMENT_ID" "$1"; }
clear_trigger_reaction() { crl_clear_trigger_reaction "$REPO" "$COMMENT_ID" "$1"; }

crl_log "PR #${PR_NUMBER} (${REPO}) のレビューを開始します（comment_id=${COMMENT_ID}）"

# --- マージ/クローズ済みPRへの遅延トリガー（head branchが既に削除済み等）を
#     素通りさせず、ここで検知して分かりやすい状態にする ---
PR_STATE="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state --jq .state)"
if [ "$PR_STATE" != "OPEN" ]; then
  crl_log "PR #${PR_NUMBER} (${REPO}) は既に ${PR_STATE} のためレビューをスキップします"
  set_trigger_reaction "confused"
  post_status_comment "ℹ️ このPRは既に ${PR_STATE} のため、レビューをスキップしました。"
  exit 0
fi

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
  CHECKLISTS_DIR="$CRL_DIR/checklists" \
  python3 -c '
import glob
import os
import re
template = open(os.environ["TEMPLATE_PATH"]).read()
checklist_files = sorted(glob.glob(os.path.join(os.environ["CHECKLISTS_DIR"], "*.md")))
checklists = "\n\n".join(open(f).read().strip() for f in checklist_files)
pr_diff = os.environ.get("PR_DIFF", "")
# diff自体に ``` を含む行がありうる（例: Markdown/コードのフェンスを変更するPR）ため、
# diffを囲むフェンスはdiff中の最長バッククォート連続より長くして早期クローズを防ぐ。
longest_run = max([len(m) for m in re.findall(r"`+", pr_diff)] + [2])
diff_fence = "`" * (longest_run + 1)
template = template.replace("{{DIFF_FENCE}}", diff_fence)
for key in ["OWNER", "REPO", "PR_NUMBER", "PR_TITLE", "PR_BODY", "PR_DIFF"]:
    env_key = "NAME" if key == "REPO" else key
    template = template.replace("{{" + key + "}}", os.environ.get(env_key, ""))
template = template.replace("{{CHECKLISTS}}", checklists)
open(os.environ["OUTPUT_PATH"], "w").write(template)
'

# --- claude -p 実行（サブスク認証。ANTHROPIC_API_KEY は crl_load_config で unset 済み）。
#     Bash/gh/gitは一切許可しない。Read/Grep/Globに加え、依存パッケージ更新PRの
#     レビューでリリースノート/CHANGELOGを調べられるようWebFetch/WebSearch
#     （読み取り専用のHTTPフェッチのみで、コマンド実行権限ではない）も許可する。
#     claude自身はgh pr reviewを実行せず、判定結果をテキストで出力するだけにし、
#     実際のGitHub書き込み（gh pr review）はこのスクリプト側で行う。
#     これにより確認待ち（プランモード等）で止まる余地自体をなくす。 ---
set +e
CLAUDE_OUTPUT="$(cd "$REPO_DIR" && "$CLAUDE_REVIEW_CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
  --allowedTools "Read" "Grep" "Glob" "WebFetch" "WebSearch")"
CLAUDE_EXIT=$?
set -e

clear_trigger_reaction "eyes"

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  crl_log "claude -p が失敗しました（exit=${CLAUDE_EXIT}）"
  set_trigger_reaction "confused"
  post_status_comment "⚠️ ローカル Claude でのレビューに失敗しました（exit=${CLAUDE_EXIT}）。ログを確認してください。"
  exit 0
fi

HEAD_SHA="$(cd "$REPO_DIR" && git rev-parse HEAD)"

# --- claudeの出力（```json フェンス付きの単一JSONオブジェクト: action/body/findings）
#     をパースし、findingsをdiffと突き合わせて検証した上で、GitHub Reviews APIの
#     payload（commit_id/event/body/comments）を組み立てる。
#     diffの変更範囲外の行はGitHub側が拒否するため、有効な行のみ comments に残す。 ---
REVIEW_PAYLOAD_FILE="$(mktemp)"
PARSE_RESULT_FILE="$(mktemp)"
PR_DIFF="$PR_DIFF" CLAUDE_OUTPUT="$CLAUDE_OUTPUT" HEAD_SHA="$HEAD_SHA" \
  OUTPUT_PATH="$REVIEW_PAYLOAD_FILE" RESULT_PATH="$PARSE_RESULT_FILE" \
  python3 -c '
import json
import os
import re


def fail(reason):
    with open(os.environ["RESULT_PATH"], "w") as fh:
        fh.write("PARSE_ERROR\n" + reason)
    raise SystemExit(0)


def extract_json_block(text):
    m = re.search(r"```json\s*(\{.*)\s*```", text, re.DOTALL)
    candidates = [m.group(1)] if m else []
    candidates.append(text)
    for c in candidates:
        start = c.find("{")
        if start < 0:
            continue
        try:
            obj, _ = json.JSONDecoder().raw_decode(c[start:])
            return obj
        except Exception:
            continue
    return None


SEVERITIES = {"critical", "high", "mid", "low"}

try:
    data = extract_json_block(os.environ["CLAUDE_OUTPUT"])
    if data is None:
        fail("```json フェンス付きのJSONブロックが見つからないか、パースに失敗しました")

    if not isinstance(data, dict):
        fail("JSONのトップレベルがオブジェクトではありません")

    action = data.get("action")
    body = data.get("body")
    findings = data.get("findings", [])

    event_map = {"approve": "APPROVE", "request-changes": "REQUEST_CHANGES", "comment": "COMMENT"}
    if action not in event_map:
        fail(f"actionの値が不正です: {action!r}")
    if not isinstance(body, str) or not body.strip():
        fail("bodyが空です")
    if not isinstance(findings, list):
        findings = []

    def unquote_diff_path(target):
        # 非ASCII文字を含むパスは git により `"b/...\NNN..."` の形（Cスタイルの
        # 8進エスケープ付きダブルクォート）で出力されるため、実際のUTF-8パスに戻す。
        if target.startswith('"') and target.endswith('"'):
            try:
                inner = target[1:-1]
                # 8進エスケープ文字列 → 生バイト列 → UTF-8文字列、の順に復元する
                return inner.encode("utf-8").decode("unicode_escape").encode("latin1").decode("utf-8")
            except Exception:
                return target
        return target

    diff_text = os.environ["PR_DIFF"]
    valid_lines = {}
    current_path = None
    new_line = None
    for line in diff_text.splitlines():
        dm = re.match(r"^\+\+\+ (.+)$", line)
        if dm:
            target = unquote_diff_path(dm.group(1))
            if target == "/dev/null":
                current_path = None
            else:
                current_path = re.sub(r"^b/", "", target)
                valid_lines.setdefault(current_path, set())
            new_line = None
            continue
        hm = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
        if hm:
            new_line = int(hm.group(1))
            continue
        if current_path is None or new_line is None:
            continue
        if line.startswith("+"):
            valid_lines[current_path].add(new_line)
            new_line += 1
        elif line.startswith(" "):
            valid_lines[current_path].add(new_line)
            new_line += 1
        elif line.startswith("-"):
            pass
        # "\\ No newline..." 等は行番号に影響しないため無視する

    comments = []
    dropped = 0
    for f in findings:
        if not isinstance(f, dict):
            dropped += 1
            continue
        path = f.get("file")
        line_no = f.get("line")
        severity = f.get("severity", "")
        message = f.get("message", "")
        if severity not in SEVERITIES:
            severity = ""
        if not path or not isinstance(line_no, int) or path not in valid_lines or line_no not in valid_lines[path]:
            dropped += 1
            continue
        tag = f"**[{severity}]** " if severity else ""
        comments.append({"path": path, "line": line_no, "side": "RIGHT", "body": f"{tag}{message}"})

    payload = {
        "commit_id": os.environ["HEAD_SHA"],
        "event": event_map[action],
        "body": body,
        "comments": comments,
    }
    with open(os.environ["OUTPUT_PATH"], "w") as fh:
        json.dump(payload, fh)

    with open(os.environ["RESULT_PATH"], "w") as fh:
        fh.write(f"OK\n{action}\n{event_map[action]}\n{dropped}")
except SystemExit:
    raise
except Exception as e:
    fail(f"想定外のエラーが発生しました: {e}")
'

PARSE_STATUS="$(sed -n '1p' "$PARSE_RESULT_FILE")"
if [ "$PARSE_STATUS" != "OK" ]; then
  PARSE_REASON="$(tail -n +2 "$PARSE_RESULT_FILE")"
  crl_log "claude -p の出力をJSONとして解析できませんでした（${PARSE_REASON}）: $CLAUDE_OUTPUT"
  rm -f "$PARSE_RESULT_FILE" "$REVIEW_PAYLOAD_FILE" 2>/dev/null || true
  set_trigger_reaction "confused"
  post_status_comment "⚠️ ローカル Claude の出力形式が不正でレビューを解析できませんでした。ログを確認してください。"
  exit 0
fi

REVIEW_ACTION="$(sed -n '2p' "$PARSE_RESULT_FILE")"
GH_EVENT="$(sed -n '3p' "$PARSE_RESULT_FILE")"
DROPPED_COUNT="$(sed -n '4p' "$PARSE_RESULT_FILE")"
rm -f "$PARSE_RESULT_FILE" 2>/dev/null || true

if [ "${DROPPED_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  crl_log "findingsのうちdiff範囲外/不正な${DROPPED_COUNT}件はインラインコメントをスキップしました"
fi

# --- 実際のレビュー投稿（総評＋インライン行コメント）はこのスクリプトが
#     GitHub Reviews API（gh api .../pulls/.../reviews）で行う ---
REVIEW_ERR_FILE="$(mktemp)"
set +e
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --input "$REVIEW_PAYLOAD_FILE" 2>"$REVIEW_ERR_FILE" >/dev/null
REVIEW_EXIT=$?
set -e

if [ "$REVIEW_EXIT" -ne 0 ] && [ "$GH_EVENT" != "COMMENT" ]; then
  # GitHubの仕様上、PR作者本人は自分のPRをapprove/request-changesできない（self-review制限）。
  # その場合は同内容（インラインコメント含む）で event=COMMENT にフォールバックする。
  crl_log "gh api pulls/reviews ($GH_EVENT) が失敗したため event=COMMENT にフォールバックします: $(cat "$REVIEW_ERR_FILE" 2>/dev/null || true)"
  python3 -c 'import json,sys
p = sys.argv[1]
d = json.load(open(p))
d["event"] = "COMMENT"
json.dump(d, open(p, "w"))' "$REVIEW_PAYLOAD_FILE"
  set +e
  gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --input "$REVIEW_PAYLOAD_FILE" >/dev/null 2>"$REVIEW_ERR_FILE"
  REVIEW_EXIT=$?
  set -e
fi

if [ "$REVIEW_EXIT" -ne 0 ]; then
  # インラインコメントの内容自体が原因で拒否された可能性があるため、
  # 総評本文だけでの投稿にフォールバックし、レビュー自体は失われないようにする。
  crl_log "gh api pulls/reviews がインラインコメント付きで失敗したため、コメント無しで再試行します: $(cat "$REVIEW_ERR_FILE" 2>/dev/null || true)"
  python3 -c 'import json,sys
p = sys.argv[1]
d = json.load(open(p))
d["comments"] = []
json.dump(d, open(p, "w"))' "$REVIEW_PAYLOAD_FILE"
  set +e
  gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --input "$REVIEW_PAYLOAD_FILE" >/dev/null 2>"$REVIEW_ERR_FILE"
  REVIEW_EXIT=$?
  set -e
fi
rm -f "$REVIEW_ERR_FILE" "$REVIEW_PAYLOAD_FILE" 2>/dev/null || true

if [ "$REVIEW_EXIT" -ne 0 ]; then
  crl_log "gh api pulls/reviews の投稿に失敗しました"
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
