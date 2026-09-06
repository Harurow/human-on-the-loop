# human-on-the-loop 開発ガイド

このリポジトリは、AI エージェントが自律的にアプリ開発を行うワークフローフレームワーク（Claude Code スキル `hotl`）。

- フレームワークに手を入れる前に **[PRINCIPLES.md](PRINCIPLES.md) を必ず読む**（思想 P1〜P8 と変更プロセス）
- 実体は `skills/hotl/`（SKILL.md = ステートマシン、`playbooks/` = フェーズ手順、`templates/` = 成果物雛形）と `skills/hotl-pm/`（任意・マルチプロジェクトの旗振り）。`install.sh` がターゲットの `.claude/skills/` に配置する（`--pm` で旗振りも）
- 変更後は PRINCIPLES.md「フレームワーク自体の変更プロセス」に従う。**まず `scripts/check-consistency.sh --tier` で段階を判定**: A 軽微＝機械チェックのみ／B 局所＝回帰（変更領域＋GATE/RESUME）1周のみ／C 構造＝フル手順（最大2周＋文面変更時の使う側＋ドライランは次の C とまとめて）。合格条件は「回帰 NG ゼロ かつ CRITICAL ゼロ」（MAJOR ゼロは条件にしない）
- **1周目の MAJOR は直す。2周目の MAJOR は直さず `plans/findings-ledger.md` と `plans/review-backlog.md` に記録**し、次の変更の入力にする（例外は CRITICAL と回帰 NG のみ）
- **修正の前に `plans/findings-ledger.md`（同じ領域の過去の対応とその後）と `adr/` に照合する**。過去に欠陥を生んだ対応の繰り返しは禁止。レビュアーの修正案はそのまま採用しない
- レビュアーには `plans/regression-scenarios.md` を渡し、**ADR・レビュー履歴・変更の経緯は渡さない**（敵対性が落ちる）
- 各周は `plans/review-log.md` に1行追記する
- ランタイムは Claude Code のみ（nanoclaw 対応は 2026-08 に撤去済み。再導入しない）
