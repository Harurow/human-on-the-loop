# ADR（Architecture Decision Record）

フレームワークの**振る舞いを決める判断**を1件1ファイルで残す。目的は「同じ論点を毎回ゼロから議論し直さない」こと。

## なぜ要るか

2026-09-05 の敵対的レビュー43〜51周で、MAJOR 21件のうち12件が「前の周の修正が原因」だった。指摘は3箇所（承認判定と「本文待ち」・検証の周回とキャップ・PM の区切り）に集中し、**周ごとに逆方向の修正を交互に適用していた**（例: 「本文待ち」中の起動メッセージの扱いは45→46→47→50周で緩和と制限を往復）。原因は、決定の**理由と却下した案**がどこにも残っていなかったこと。fresh context のレビュアーは経緯を知らないので、退けた案を何度でも提案してくる。

## 使い方

- **レビュアーには ADR を渡さない**（変更の経緯を渡すと敵対的レビューの質が落ちる。PRINCIPLES 手順3）
- 指摘を受け取った側（修正する人）が ADR と照合し、次のどれかに分岐する:
  1. **ADR と矛盾しない** → 通常どおり修正する
  2. **ADR の決定と矛盾するが、ADR の「再検討の条件」を満たす** → 新しい ADR を書いて旧 ADR を Superseded にする（決定を変えたこと自体を残す）
  3. **矛盾していて条件も満たさない** → **修正しない**。該当 ADR の「再指摘の履歴」に1行足し、レビューの対応記録に「却下＋根拠」として残す
- **振る舞いを決める判断をしたら ADR を1枚書く**（PRINCIPLES 手順1）。書式は既存ファイルに倣う

## 一覧

| ID | 決定 | 状態 |
|---|---|---|
| [001](001-approval-gate-judgment.md) | 承認の判定は「明示的な同意 × 現在の提示より後」に限る | Accepted |
| [002](002-pending-body-vs-reconfirm.md) | 「本文待ち」と「再確認中」を用途で分ける | Accepted |
| [003](003-verification-cycle-counting.md) | 周は役割ごとの完了記録で数え、受け入れ検証だけ不合格回数でキャップする | Accepted |
| [004](004-passing-round-minor-disclosure.md) | 全合格の周に出た MINOR はタスク化せず開示に固定する | Accepted |
| [005](005-selection-ui-scope.md) | 選択式で聞くのは「返信を待ってターンを終了する場面」だけ | Accepted |
| [006](006-human-input-routing-table.md) | 人間の入力の経路は SKILL.md の1表を正とする | Accepted |
| [007](007-pm-chunk-boundaries.md) | PM の委譲は区切り単位。検証はサブエージェント不可なら検証チャンクに分ける | Accepted |
| [008](008-ledger-commit-discipline.md) | 台帳（docs/）は更新のたび commit し、WIP の破棄は実装ファイルに限る | Accepted |
| [009](009-review-loop-protocol.md) | レビューは回帰集を通してから新規探索。PASS 周の MINOR は反映しない | 一部 Superseded by 011 |
| [010](010-c-locale-for-scripts.md) | シェルスクリプトはロケールを C に固定する | Accepted |
| [011](011-bounded-review-rounds.md) | レビューは最大2周。合格条件は「回帰 NG ゼロ かつ CRITICAL ゼロ」 | 一部 Superseded by 014 |
| [012](012-transactional-state-update.md) | 複数ファイルの状態更新は「更新開始/更新完了」で囲み、再開時は冪等にやり直す | Accepted |
| [013](013-diff-update-review-scope.md) | 差分更新時の要件レビューは「変更部分に起因する指摘」に限定する（入力は全文） | Accepted（58周で決定の形を修正） |
| [014](014-tiered-review.md) | レビューは変更の段階（A 軽微 / B 局所 / C 構造）で手順を変える | Accepted |
| [015](015-priority-driven-order.md) | 優先度 must / should / could をタスク順の唯一の根拠にし、自律判断は次の報告で開示する | Accepted |
