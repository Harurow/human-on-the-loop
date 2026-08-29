# human-on-the-loop 開発ガイド

このリポジトリは、AI エージェントが自律的にアプリ開発を行うワークフローフレームワーク（Claude Code スキル `hotl`）。

- フレームワークに手を入れる前に **[PRINCIPLES.md](PRINCIPLES.md) を必ず読む**（思想 P1〜P7 と変更プロセス）
- 実体は `skills/hotl/`: SKILL.md = ステートマシン、`playbooks/` = フェーズ手順、`templates/` = 成果物雛形。配布単位はこのディレクトリ1つで、`install.sh` がターゲットの `.claude/skills/hotl` に配置する
- 変更後は PRINCIPLES.md「フレームワーク自体の変更プロセス」に従い、**fresh context の敵対的レビュー → 自律修正のループを PASS（CRITICAL/MAJOR ゼロ）まで回す**こと
- ランタイムは Claude Code のみ（nanoclaw 対応は 2026-08 に撤去済み。再導入しない）
