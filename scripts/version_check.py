#!/usr/bin/env python3
"""プラグイン内容が変わったのに version を上げ忘れていないか検出する。

使い方: python3 scripts/version_check.py <base_ref>
  base_ref ... 比較元（例: origin/main）。

判定:
- plugins/dev-flow 配下に変更があり、かつ plugin.json の version が base から
  変わっていなければエラー。
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = "plugins/dev-flow"
PLUGIN_JSON = f"{PLUGIN_DIR}/.claude-plugin/plugin.json"


def run(*args: str) -> str:
    return subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout


def main() -> int:
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"

    changed = run("git", "diff", "--name-only", f"{base}...HEAD").split()
    plugin_changed = [f for f in changed if f.startswith(PLUGIN_DIR + "/")]
    if not plugin_changed:
        print("プラグイン内容に変更なし。version-check スキップ。")
        return 0

    cur = json.loads((ROOT / PLUGIN_JSON).read_text(encoding="utf-8")).get("version")
    try:
        base_json = run("git", "show", f"{base}:{PLUGIN_JSON}")
        old = json.loads(base_json).get("version")
    except subprocess.CalledProcessError:
        old = None  # base に plugin.json が無い（初回）

    if old is not None and cur == old:
        print("❌ プラグイン内容が変更されていますが version が据え置きです。")
        print(f"   現在の version: {cur}（base と同じ）")
        print(f"   変更ファイル: {', '.join(plugin_changed)}")
        print(f"   → {PLUGIN_JSON} の version を上げてください（marketplace.json も合わせる）。")
        return 1

    print(f"✅ version OK（{old} → {cur}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
