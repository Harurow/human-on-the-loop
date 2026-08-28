---
name: hotl
description: アプリ開発ワークフロー human-on-the-loop を実行・再開する。「新しいアプリを作りたい」「開発を進めて」「続きから」「要件を承認します」「進捗を教えて」等で起動。ヒアリング→要件定義→人間の承認→仕様化→設計→開発を、承認後は自律的に進める。
---

# HOTL Orchestrator

このスキルはステートマシンである。プロジェクトの state ファイルを読み、現在フェーズの playbook を Read して実行する。
承認ゲート（要件承認）以降は人間をブロックせず自律的に開発を完走する。

## Step 1: ランタイム検出

`/workspace/group` が存在すれば **nanoclaw**、なければ **Claude Code**。
最初に `playbooks/reporting.md` を Read し、以後の報告・質問・承認の方法はすべてそれに従う。

## Step 2: プロジェクト特定

- **Claude Code**: カレントディレクトリがプロジェクト。`docs/hotl.state.json` を探す
- **nanoclaw**: `/workspace/group/projects/*/docs/hotl.state.json` を glob
  - 1件 → それを使う
  - 複数 → ユーザーの発言から対象を推定。特定できなければどれか確認する
  - 0件 → 新規開発の意図なら Step 3 へ。プロジェクト名（kebab-case）を決め `/workspace/group/projects/<app-name>/` を作成

## Step 3: ブートストラップ（state ファイルが無い場合のみ）

1. プロジェクト直下に `docs/` を作成
2. `templates/state.json` を元に `docs/hotl.state.json` を生成（`project`、`created_at`/`updated_at` を現在時刻で埋める。`phase` は `"hearing"`）
3. git repo でなければ `git init`
4. `docs/log.md` を作成し、開始エントリを追記
5. Step 5 へ（hearing から開始）

## Step 4: 状態読み込みと整合性チェック

`docs/hotl.state.json` を Read する。

- `approval.approved` が true の場合、`approval.document` の現在の sha256 を計算し `approval.document_sha256` と比較する
- **不一致なら自律続行してはならない**。要件が承認後に変更されたことを報告し、`phase` を `requirements` に戻して承認ゲートを再実行する
- `phase` が `done` のプロジェクトに新しい要望が来た場合は、新イテレーションを開始する: `phase` を `hearing` に戻し（`phase_history` に追記）、差分ヒアリング → 要件更新 → 再承認 → 自律開発、と同じ流れを回す

## Step 5: フェーズ実行

`phase` に対応する playbook を Read して、その内容に従って実行する:

| state.phase | playbook |
|---|---|
| hearing | `playbooks/01-hearing.md` |
| requirements | `playbooks/02-requirements.md` |
| awaiting_approval | `playbooks/02-requirements.md`（承認ゲート節から） |
| specification | `playbooks/03-specification.md` |
| design | `playbooks/04-design.md` |
| development | `playbooks/05-development.md` |
| done | 完了報告のみ（新しい要望があれば Step 4 のイテレーション開始） |

## Step 6: フェーズ遷移ルール

playbook の完了条件を満たしたら:

1. `docs/hotl.state.json` を更新: `phase` を次へ、`phase_history` の現エントリに `completed_at`、次エントリを追加、`updated_at` 更新
2. git repo なら成果物を commit（メッセージ: `hotl: complete <phase>`）
3. `reporting.md` の書式でフェーズ完了報告（log.md への追記を忘れない）

**ターンを終了してよいのは `hearing`（質問の返信待ち）と `awaiting_approval`（承認待ち）のみ。**
`specification` / `design` / `development` は自律区間であり、フェーズ完了後そのまま同一ターン内で次フェーズの playbook を Read して続行する。途中でターンを終えてはならない。

## Step 7: 割り込みと途中介入

実行中にユーザーの指示が来た場合の扱いは `reporting.md` の「割り込みへの対応」に従う。
停止指示以外で作業を止めない。方針変更はドキュメントと state に反映し、log.md に記録してから続行する。
