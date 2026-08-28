---
name: hotl
description: アプリ開発ワークフロー human-on-the-loop を実行・再開する。「新しいアプリを作りたい」「開発を進めて」「続きから」「要件を承認します」「進捗を教えて」等で起動。ヒアリング→要件定義→人間の承認→仕様化→設計→開発を、承認後は自律的に進める。
---

# HOTL Orchestrator

このスキルはステートマシンである。プロジェクトの state ファイルを読み、現在フェーズの playbook を Read して実行する。
承認ゲート（要件承認）以降は人間をブロックせず自律的に開発を完走する。

**パス規約**: `playbooks/...` `templates/...` は、この SKILL.md と同じディレクトリ（スキルディレクトリ）からの相対パス。成果物（`docs/...`）はターゲットプロジェクトルートからの相対パス（一覧は state.json の `artifacts` に列挙）。**Step 2 でプロジェクトを特定したら、以後のコマンド・相対パスはすべてプロジェクトルートを cwd として実行する**（nanoclaw では `projects/<app>/` へ cd）。

**時刻**: タイムスタンプは必ず `date` コマンドの実行結果を使い、推測で書かない。state.json は `date +"%Y-%m-%dT%H:%M:%S%z"`（ISO8601）、log.md の見出しは `date +"%Y-%m-%d %H:%M"`。

## エージェント構成とコンテキスト分離

原則: **フェーズ間の受け渡しは docs/ の成果物ドキュメントのみ**。会話履歴を下流フェーズに持ち込まない。レビュー・検証は必ず作成者と別コンテキストで行う。

| 役割 | 実行場所 | 渡すもの |
|---|---|---|
| オーケストレーション・報告・承認ゲート | メインループ | state + log |
| ヒアリング・要件執筆 | メインループ | 会話 + hearing-notes |
| 要件レビュー | サブエージェント（fresh context） | requirements + チェックリストのみ |
| 仕様化 / 設計 | サブエージェント（各1体） | 各 playbook が指定するドキュメントのみ |
| 実装ループ | メインループ | design + tasks + リポジトリ |
| 最終受け入れ検証 | サブエージェント（fresh context） | requirements の受け入れ基準 + 成果物のみ |

- モデルは指定せずセッションモデルを継承する。チェックリスト適用のみの機械的レビューは低 effort でよい
- サブエージェント（Task / Agent ツール）が使えない環境では、**同じ入力制約を守って**インラインで代替する

## 共通手順: 承認リセット

承認済み要件を無効化する場面（要件変更・矛盾発見・イテレーション開始）では、必ず次の3点をセットで行う:

1. state.json の `approval.approved` を false にし、旧承認記録（承認者・日時・ハッシュ）を log.md に退避する
2. `docs/requirements.md` の承認記録節を「未承認」に戻す（これに伴い requirements.md への書き込み禁止も解除される）
3. Step 6 を実行して phase を戻す（要件変更・矛盾発見 → `requirements`、イテレーション → `hearing`）

## Step 1: ランタイム検出

`/workspace/group` が存在すれば **nanoclaw**、なければ **Claude Code**。
最初に `playbooks/reporting.md` を Read し、以後の報告・質問・承認の方法はすべてそれに従う。

## Step 2: プロジェクト特定

- **Claude Code**: カレントディレクトリがプロジェクト。`docs/hotl.state.json` を探す
- **nanoclaw**: `/workspace/group/projects/*/docs/hotl.state.json` を glob。1件 → それ。複数 → ユーザーの発言から推定し、特定できなければ確認
- **state が見つからない場合（ランタイム共通）**:
  - 新規開発の意図が明確に読み取れる → Step 3 へ（nanoclaw ではプロジェクト名を kebab-case で決め `projects/<app-name>/` を作成）
  - 「続きから」「進捗を教えて」等で新規の意図が読み取れない → **ブートストラップしてはならない**。対象プロジェクトが見つからない旨を報告し、新規開発かどうかを確認する

## Step 3: ブートストラップ（state ファイルが無い場合のみ）

1. プロジェクト直下に `docs/` を作成
2. `templates/state.json` を元に `docs/hotl.state.json` を生成（`project` と各タイムスタンプを埋める。`phase` は `"hearing"`）
3. git repo でなければ `git init`。`git config user.name` が未設定ならリポジトリローカルに `user.name` / `user.email` を設定する（例: `hotl` / `hotl@localhost`。これが無いと以後の全 commit が失敗する）
4. `docs/log.md` を作成し、開始エントリを追記
5. Step 5 へ（hearing から開始）

## Step 4: 状態読み込みと整合性チェック

`docs/hotl.state.json` を Read し、次を順に確認する:

- **承認済みハッシュの照合**: `approval.approved` が true の場合、`shasum -a 256 docs/requirements.md | cut -d' ' -f1`（`shasum` が無い環境は `sha256sum`。先頭フィールドがハッシュ）で現在値を計算し `approval.document_sha256` と比較する。**不一致なら自律続行してはならない**: 「承認後に要件が変更されている」ことを報告し、**承認リセット**（次 phase: `requirements`）を行って承認ゲートを再実行する
- **自律区間の不変条件**: `phase` が `specification` / `design` / `development` なのに `approval.approved` が true でないのは不正状態（承認前に自律区間へ入っている）。**承認リセット**（次 phase: `requirements`）でゲートからやり直す
- **イテレーション**: `phase` が `done` のプロジェクトに新しい要望が来たら、**承認リセット**（次 phase: `hearing`）で差分ヒアリングから同じ流れを回す。**イテレーションでは各フェーズとも既存成果物の差分更新**として実行する（テンプレートからの再生成をしない）

## Step 5: フェーズ実行

`phase` に対応する playbook を Read して、その内容に従って実行する:

| state.phase | playbook |
|---|---|
| hearing | `playbooks/01-hearing.md` |
| requirements | `playbooks/02-requirements.md` |
| awaiting_approval | `playbooks/02-requirements.md` — このターンを起動したユーザーメッセージを「承認の判定と記録」節で**判定することから始める**（判定の前にゲートを再提示して往復を浪費しない。判定の結果として必要な再提示は行う）。`approval.approved` が既に true なら承認手続きの途中中断なので、再判定せず残りの手順（log 記録 → Step 6 遷移）を完了させる |
| specification | `playbooks/03-specification.md` |
| design | `playbooks/04-design.md` |
| development | `playbooks/05-development.md` |
| done | 完了報告のみ（新しい要望があれば Step 4 のイテレーション開始） |

## Step 6: フェーズ遷移ルール（唯一の遷移手順）

**すべての phase 変更はこの手順で行う**（承認リセットの phase 戻しを含む）。playbook 側は「Step 6 を実行（次 phase: X）」とだけ指示する。commit や報告を playbook 側で重複して行わない。

1. `docs/hotl.state.json` を更新: `phase` を次へ、`phase_history` の現エントリに `completed_at`、次エントリを追加、`updated_at` 更新
2. git repo なら関連成果物をまとめて commit（メッセージ: `hotl: <旧phase> -> <新phase>`）
3. `reporting.md` の書式で報告（log.md への追記を含む）

**ターンを終了してよい場面**は次のみ:

- `hearing`: 質問の返信待ち
- `awaiting_approval`: 承認待ち
- `done` 到達時の最終報告
- 停止指示への応答（reporting.md 割り込み case 1）
- 全残タスクが人間の入力（API キー等）待ちでブロックされた場合

`specification` / `design` / `development` は自律区間であり、上記以外ではフェーズ完了後そのまま同一ターン内で次フェーズの playbook を Read して続行する。

## Step 7: 割り込みと途中介入

実行中にユーザーの指示が来た場合の扱いは `reporting.md` の「割り込みへの対応」に従う。
停止指示以外で作業を止めない。方針変更はドキュメントと state に反映し、log.md に記録してから続行する。
**ただし要件レベルの変更（要件の追加・削除・意味の変更）は例外**: **承認リセット**（次 phase: `requirements`）を行い、要件を更新して承認ゲートに戻る（ここだけはブロックする）。
