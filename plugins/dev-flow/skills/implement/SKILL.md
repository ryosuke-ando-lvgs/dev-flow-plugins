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

### Step 1: 作業ブランチの作成（既定 = worktree）
現在の状態を確認し、ベースから新しい作業ブランチを切る。**このスキルでは既定で worktree を作成する**（plan を exit した後は worktree でいい感じに作業を進める運用のため）。ただしユーザーが作業ディレクトリ/ブランチ運用を明示指定した場合はその限りではない。

まず状態確認:

```bash
git remote -v            # リモート種別（後続のpush/PRで使う）
git status               # 未コミット変更の有無
git branch --show-current
```

- 未コミット変更があれば `AskUserQuestion` で stash / 先にコミット / 破棄 / 中止 を確認。

#### 既定: worktree を作成する（作業ディレクトリの明示指定がない場合）

- `EnterWorktree` を `name: "<prefix>/<短い説明>"` で呼び、worktree＋ブランチを作成してセッションをそこへ移動する。
  - prefix は変更種別に合わせる: `feat/` `fix/` `refactor/` `chore/` `docs/`。
  - `EnterWorktree` は baseRef=fresh により `origin/<デフォルトブランチ>` から分岐するため、手動の `git checkout` / `git pull` は不要。
- worktree は依存が未インストールなので、`package.json` 等に依存変更があれば worktree 内で `npm install`（または `pnpm install`）を実行する。

#### 例外: 通常ブランチを使う（作業ディレクトリ/ブランチ運用が明示された場合）

「このディレクトリで」「worktree 不要」「今のブランチで」等の明示があれば、worktree を作らず従来フローを使う:

```bash
git checkout develop 2>/dev/null || git checkout main
git pull --ff-only
git checkout -b <prefix>/<短い説明>
```

- prefix ルールは同上。依存変更があれば `npm install`（または `pnpm install`）。

### Step 2: 実装
計画のタスクを順に実装する。

- 周囲のコードのスタイル（命名・コメント密度・イディオム）に合わせる。
- 既存の関数/ユーティリティを再利用する。
- 各タスク単位、または意味のあるまとまりでコミットする（メッセージは規約に従う）。

### Step 3: 自己確認と報告
実装範囲・触れたファイル・残課題を簡潔に報告する。
（lint/testの本格チェックは `pretest` スキルで行う。）

## 注意事項
- **既定は worktree を作成する。** 作業ディレクトリ/ブランチ運用の明示指定があるときのみ通常ブランチを使う。
- `develop` / `main` への直接コミットは禁止。必ずブランチを切る。
- 既に同名ブランチがあれば警告し別名を提案する。
- 大きな仮定を置く前にユーザーへ確認する。
