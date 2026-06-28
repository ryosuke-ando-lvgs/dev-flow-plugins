---
name: implement
description: 計画に沿って実装する。冒頭でベースブランチを最新化して作業ブランチを切り、計画のタスクを順に実装してコミットする。「実装して」「開発して」「作って」「コードを書いて」「implement」などのリクエストで使用。
---

# implement（実装）

計画メモに沿って作業ブランチを切り、実装する。自己完結（外部スキルに依存しない）。

## 引数

`$ARGUMENTS` に計画メモのパス、または実装内容を受け取る。
`plan` 直後なら scratchpad の `plan_*.md` を自動で探して使う。

## 手順

### Step 1: 作業ブランチの作成
現在の状態を確認し、ベースから新ブランチを切る。

```bash
git remote -v            # リモート種別（後続のpush/PRで使う）
git status               # 未コミット変更の有無
git branch --show-current
```

- 未コミット変更があれば `AskUserQuestion` で stash / 先にコミット / 破棄 / 中止 を確認。
- ベースブランチ（`develop` が無ければ `main`）を最新化して新ブランチを作成:

```bash
git checkout develop 2>/dev/null || git checkout main
git pull --ff-only
git checkout -b <prefix>/<短い説明>
```

- prefix は変更種別に合わせる: `feat/` `fix/` `refactor/` `chore/` `docs/`。
- `package.json` 等に依存変更があれば `npm install`（または `pnpm install`）。

### Step 2: 実装
計画のタスクを順に実装する。

- 周囲のコードのスタイル（命名・コメント密度・イディオム）に合わせる。
- 既存の関数/ユーティリティを再利用する。
- 各タスク単位、または意味のあるまとまりでコミットする（メッセージは規約に従う）。

### Step 3: 自己確認と報告
実装範囲・触れたファイル・残課題を簡潔に報告する。
（lint/testの本格チェックは `pretest` スキルで行う。）

## 注意事項
- `develop` / `main` への直接コミットは禁止。必ずブランチを切る。
- 既に同名ブランチがあれば警告し別名を提案する。
- 大きな仮定を置く前にユーザーへ確認する。
