#!/usr/bin/env python3
"""dev-flow-plugins の構成を検証する。

チェック内容:
- marketplace.json / plugin.json が有効なJSONで必須フィールドを持つ
- marketplace の各 plugin.source ディレクトリが存在し plugin.json を持つ
- 各スキルが SKILL.md を持ち、frontmatter に name と description がある
- frontmatter の name がディレクトリ名と一致する
- name の重複が無い
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        err(f"見つかりません: {path.relative_to(ROOT)}")
    except json.JSONDecodeError as e:
        err(f"JSON不正 {path.relative_to(ROOT)}: {e}")
    return None


def parse_frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        err(f"frontmatterが先頭にありません: {path.relative_to(ROOT)}")
        return {}
    parts = text.split("---", 2)
    if len(parts) < 3:
        err(f"frontmatterが閉じていません: {path.relative_to(ROOT)}")
        return {}
    fm: dict[str, str] = {}
    for line in parts[1].splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip()
    return fm


def main() -> int:
    # marketplace.json
    mkt = load_json(ROOT / ".claude-plugin" / "marketplace.json")
    if mkt is not None:
        for field in ("name", "owner", "plugins"):
            if field not in mkt:
                err(f"marketplace.json: 必須フィールド '{field}' がありません")
        for entry in mkt.get("plugins", []):
            name = entry.get("name", "<no-name>")
            src = entry.get("source")
            if not isinstance(src, str):
                continue  # 外部ソース(github等)は対象外
            plugin_dir = (ROOT / src).resolve()
            if not plugin_dir.is_dir():
                err(f"plugin '{name}': source ディレクトリが無い: {src}")
                continue
            pj = load_json(plugin_dir / ".claude-plugin" / "plugin.json")
            if pj is not None and "name" not in pj:
                err(f"plugin '{name}': plugin.json に name がありません")

    # 各スキル
    seen_names: dict[str, str] = {}
    skill_files = sorted(ROOT.glob("plugins/*/skills/*/SKILL.md"))
    if not skill_files:
        err("SKILL.md が1つも見つかりません")
    for sf in skill_files:
        dir_name = sf.parent.name
        fm = parse_frontmatter(sf)
        name = fm.get("name")
        if not name:
            err(f"{sf.relative_to(ROOT)}: frontmatter に name がありません")
        elif name != dir_name:
            err(f"{sf.relative_to(ROOT)}: name '{name}' がディレクトリ名 '{dir_name}' と不一致")
        if not fm.get("description"):
            err(f"{sf.relative_to(ROOT)}: frontmatter に description がありません")
        if name:
            if name in seen_names:
                err(f"name 重複: '{name}' ({seen_names[name]} と {sf.relative_to(ROOT)})")
            seen_names[name] = str(sf.relative_to(ROOT))

    if errors:
        print("❌ 検証失敗:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"✅ 検証成功: スキル {len(skill_files)} 件、エラーなし")
    return 0


if __name__ == "__main__":
    sys.exit(main())
