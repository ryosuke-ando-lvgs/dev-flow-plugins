# dev-flow-plugins

開発フロー（要件整理 → 計画 → 実装 → レビュー → test → PR → CI/コメント対応）を一連のスキルとして
自動化する Claude Code プラグインの marketplace です。

各スキルは**遅延ロード**されるため、Claude 起動時に消費されるのは説明文（description）のみです。
本文はスキルを呼び出したときに初めて読み込まれます。

## インストール

```text
/plugin marketplace add ryosuke-ando-lvgs/dev-flow-plugins
/plugin install dev-flow@dev-flow-tools
```

## 収録スキル

呼び出しは `/dev-flow:<skill>`。

| スキル | 役割 |
|---|---|
| `requirements` | 曖昧な依頼を構造化された要件メモに整理 |
| `plan` | 要件をもとに実装計画（方針・タスク分解・影響範囲）を作成 |
| `implement` | 作業ブランチを切り、計画に沿って実装 |
| `review` | ローカル差分を観点別にセルフレビュー |
| `pretest` | lint / test / typecheck / build を green にする |
| `pr-create` | push して Pull Request を作成（GitHub / Gitea 自動判定） |
| `pr-review` | PR に観点を1観点1コメントで投稿 |
| `ci-fix` | CI 失敗ログを取得して修正し追加コミットで push |
| `comment-fix` | PR コメントを監視して返信＋修正 |
| `orchestrate` | 上記を順番に実行（各段階で承認） |
| `loop` | フローや特定段階を停止条件まで反復／定期監視 |

最新版に更新するには:

```text
/plugin update dev-flow@dev-flow-tools
```

> このプラグインは `plugin.json` の `version` を明示して管理しています。**既存ユーザーへ更新を
> 届けるには version を上げる必要があります**（commit だけでは反映されません）。version を上げ忘れて
> いないかは CI（`version-check`）が検出します。

## 使い方

一気通貫で回すなら:

```text
/dev-flow:orchestrate <作りたいものの説明 or Issue番号>
```

個別の段階だけ使うこともできます（例 `/dev-flow:ci-fix 123`）。

## 設計方針

- Git/PR 操作は必ずリモート URL を判定してから `gh`（GitHub）/ `tea`（Gitea）を使い分ける。
- 修正は `git commit --amend` や force push を使わず、追加コミット＋通常 push で反映する。
- 段階間のデータは scratchpad のメモファイルと git の状態で受け渡す。

## ライセンス

MIT
