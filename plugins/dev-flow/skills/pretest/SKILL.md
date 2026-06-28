---
name: pretest
description: push前にlint・test・型チェック・buildを実行して品質を確認する。プロジェクト設定から実行コマンドを自動検出し、失敗があればgreenになるまで修正する。「push前チェック」「testして」「lint確認」「eslint」「型チェック」「pretest」などのリクエストで使用。
---

# pretest（push前チェック）

push前に lint / test / typecheck / build を実行し、すべて green にする。

## 引数

`$ARGUMENTS` に実行したいチェック種別やコマンドの指定を受け取る（無指定なら自動検出して全実行）。

## 手順

### Step 1: チェックコマンドの検出
プロジェクト設定からコマンドを特定する。

- Node: `package.json` の `scripts`（`lint` / `test` / `typecheck` / `build` / `format`）。
  パッケージマネージャは lockfile で判定（`pnpm-lock.yaml`→pnpm / `yarn.lock`→yarn / 既定 npm）。
- 設定ファイルの存在も手がかりにする: `.eslintrc*` / `eslint.config.*`、`tsconfig.json`、
  `jest.config.*` / `vitest.config.*`、`biome.json` など。
- 他言語: `Makefile`、`pyproject.toml`、`go.mod` 等から対応コマンドを推定。
- 不明なら検出結果を提示し、実行対象を `AskUserQuestion` で確認する。

### Step 2: 実行
変更ファイルに関係するものから実行。一般的な順序: format/lint → typecheck → test → build。

```bash
<pm> run lint
<pm> run typecheck
<pm> run test
<pm> run build
```

### Step 3: 失敗の修正
失敗があれば原因を特定して修正し、再実行する。green になるまで繰り返す。

- lint は自動修正（`--fix`）を試し、残りを手動修正。
- test 失敗は「実装の不具合」か「テストの陳腐化」かを見極めてから直す。
- 修正は追加コミットで積む。

### Step 4: 報告
各チェックの結果（pass/fail と件数）を正直に報告する。修正できなかった項目は明示する。

## 注意事項
- 「直したつもり」で報告しない。実際に再実行して green を確認する。
- スキップしたチェックがあれば、その旨を必ず伝える。
