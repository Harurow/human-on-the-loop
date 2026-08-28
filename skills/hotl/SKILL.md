---
name: hotl
description: アプリ開発ワークフロー human-on-the-loop を実行・再開する。「新しいアプリを作りたい」「開発を進めて」「続きから」「要件を承認します」「進捗を教えて」等で起動。ヒアリング→要件定義→人間の承認→仕様化→設計→開発を、承認後は自律的に進める。
---

# HOTL Orchestrator

このスキルはステートマシンである。プロジェクトの state ファイルを読み、現在フェーズの playbook を Read して実行する。
承認ゲート（要件承認）以降は人間をブロックせず自律的に開発を完走する。

**パス規約**: `playbooks/...` `templates/...` は、この SKILL.md と同じディレクトリ（スキルディレクトリ）からの相対パス。成果物（`docs/...`）はターゲットプロジェクトルートからの相対パスで、正式な一覧は state.json の `artifacts` を正とする。

**時刻**: state.json・log.md に書くタイムスタンプはすべて `date +"%Y-%m-%dT%H:%M:%S%z"` の実行結果を使う。自分で推測した時刻を書いてはならない。

## エージェント構成とコンテキスト分離

原則: **フェーズ間の受け渡しは docs/ の成果物ドキュメントのみ**。会話履歴を下流フェーズに持ち込まない。レビュー・検証は必ず作成者と別コンテキストで行う。

| 役割 | 実行場所 | 渡すもの |
|---|---|---|
| オーケストレーション・報告・承認ゲート | メインループ | state + log |
| ヒアリング・要件執筆 | メインループ | 会話 + hearing-notes |
| 要件レビュー | サブエージェント（fresh context） | requirements + チェックリストのみ |
| 仕様化 / 設計 | サブエージェント（各1体） | 上流ドキュメントのみ |
| 実装ループ | メインループ | design + tasks + リポジトリ |
| 最終受け入れ検証 | サブエージェント（fresh context） | requirements の受け入れ基準 + 成果物のみ |

- モデルは指定せずセッションモデルを継承する。チェックリスト適用のみの機械的レビューは低 effort でよい
- サブエージェント（Task / Agent ツール）が使えない環境では、**同じ入力制約を守って**インラインで代替する

## Step 1: ランタイム検出

`/workspace/group` が存在すれば **nanoclaw**、なければ **Claude Code**。
最初に `playbooks/reporting.md` を Read し、以後の報告・質問・承認の方法はすべてそれに従う。

## Step 2: プロジェクト特定

- **Claude Code**: カレントディレクトリがプロジェクト。`docs/hotl.state.json` を探す
- **nanoclaw**: `/workspace/group/projects/*/docs/hotl.state.json` を glob
  - 1件 → それを使う
  - 複数 → ユーザーの発言から対象を推定。特定できなければどれか確認する
  - 0件 → 新規開発の意図が読み取れるなら Step 3 へ（プロジェクト名を kebab-case で決め `projects/<app-name>/` を作成）。「続きから」等で新規の意図が読み取れない場合は、対象プロジェクトが見つからない旨を報告し、新規開発かを確認する

## Step 3: ブートストラップ（state ファイルが無い場合のみ）

1. プロジェクト直下に `docs/` を作成
2. `templates/state.json` を元に `docs/hotl.state.json` を生成（`project` と各タイムスタンプを埋める。`phase` は `"hearing"`）
3. git repo でなければ `git init`。`git config user.name` が未設定ならリポジトリローカルに `user.name` / `user.email` を設定する（例: `hotl` / `hotl@localhost`。これが無いと以後の全 commit が失敗する）
4. `docs/log.md` を作成し、開始エントリを追記
5. Step 5 へ（hearing から開始）

## Step 4: 状態読み込みと整合性チェック

`docs/hotl.state.json` を Read する。

- **承認済みハッシュの照合**: `approval.approved` が true の場合、`shasum -a 256 docs/requirements.md | cut -d' ' -f1`（`shasum` が無い環境は `sha256sum`。先頭フィールドがハッシュ）で現在値を計算し `approval.document_sha256` と比較する
- **不一致の場合、自律続行してはならない**: `approval.approved` を false に戻し、旧承認記録を log.md に退避してから、「承認後に要件が変更されている」ことを報告し、`phase` を `requirements` にして承認ゲートを再実行する
- **イテレーション**: `phase` が `done` のプロジェクトに新しい要望が来たら、`approval` をリセットし（`approved: false`、旧記録は log.md へ退避）、`phase` を `hearing` に戻して（`phase_history` に追記）差分ヒアリングから同じ流れを回す。**イテレーションでは各フェーズとも既存成果物の差分更新**として実行する（テンプレートからの再生成をしない）

## Step 5: フェーズ実行

`phase` に対応する playbook を Read して、その内容に従って実行する:

| state.phase | playbook |
|---|---|
| hearing | `playbooks/01-hearing.md` |
| requirements | `playbooks/02-requirements.md` |
| awaiting_approval | `playbooks/02-requirements.md` — ただし**このターンを起動したユーザーメッセージを「承認の判定と記録」節で判定することから始める**。ゲートの再提示はしない |
| specification | `playbooks/03-specification.md` |
| design | `playbooks/04-design.md` |
| development | `playbooks/05-development.md` |
| done | 完了報告のみ（新しい要望があれば Step 4 のイテレーション開始） |

## Step 6: フェーズ遷移ルール（唯一の遷移手順）

**すべての phase 変更はこの手順で行う**。playbook 側は「Step 6 を実行（次 phase: X）」とだけ指示する。commit や報告を playbook 側で重複して行わない。

1. `docs/hotl.state.json` を更新: `phase` を次へ、`phase_history` の現エントリに `completed_at`、次エントリを追加、`updated_at` 更新
2. git repo なら関連成果物をまとめて commit（メッセージ: `hotl: <旧phase> -> <新phase>`）
3. `reporting.md` の書式で報告（log.md への追記を含む）

**ターンを終了してよいのは `hearing`（質問の返信待ち）と `awaiting_approval`（承認待ち）のみ。**
`specification` / `design` / `development` は自律区間であり、フェーズ完了後そのまま同一ターン内で次フェーズの playbook を Read して続行する。途中でターンを終えてはならない。

## Step 7: 割り込みと途中介入

実行中にユーザーの指示が来た場合の扱いは `reporting.md` の「割り込みへの対応」に従う。
停止指示以外で作業を止めない。方針変更はドキュメントと state に反映し、log.md に記録してから続行する。
**ただし要件レベルの変更（要件の追加・削除・意味の変更）は例外**: 承認済み要件が無効になるため、reporting.md の case 3 に従って要件を更新し、承認ゲートに戻る（ここだけはブロックする）。
