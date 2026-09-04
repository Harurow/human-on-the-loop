# human-on-the-loop 開発ガイド

このリポジトリは、AI エージェントが自律的にアプリ開発を行うワークフローフレームワーク（Claude Code スキル `hotl`）。

- フレームワークに手を入れる前に **[PRINCIPLES.md](PRINCIPLES.md) を必ず読む**（思想 P1〜P8 と変更プロセス）
- 実体は `skills/hotl/`（SKILL.md = ステートマシン、`playbooks/` = フェーズ手順、`templates/` = 成果物雛形）と `skills/hotl-pm/`（任意・マルチプロジェクトの旗振り）。`install.sh` がターゲットの `.claude/skills/` に配置する（`--pm` で旗振りも）
- 変更後は PRINCIPLES.md「フレームワーク自体の変更プロセス」に従い、**fresh context の敵対的レビュー → 自律修正のループを PASS（CRITICAL/MAJOR ゼロ）まで回し、PASS 後に使う側の視点のレビューを1回行う**こと（レビュアーは既定モデル）
- ランタイムは Claude Code のみ（nanoclaw 対応は 2026-08 に撤去済み。再導入しない）
