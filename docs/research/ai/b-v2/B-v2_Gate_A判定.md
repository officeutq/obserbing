# B-v2 Gate A判定

## 最終判定

Issue #48の最終判定は`architecture_rejected`である。

判定には、結果を見る前に固定した`b-v2-band-pass-design-v2` / `b-v2-pre-evaluation-criteria-v2`をそのまま使用した。criteria SHA-256は`36c790098bef202a44e10ae6cdc175785b6c3427668868e93f628f0d6e684648`である。基準、しきい値、`reflective-distance-v1`、B-v1 baseline、現Approved 96 Lineは変更していない。

棄却下限のうち、acceptable改善が10ポイント未満（実測-2.78ポイント）と、有効実行における運用上限違反（p95 6.23389秒 > 6秒）の2つが成立した。Gate Bの製品品質80%未達だけを理由に棄却したものではない。

## architecture_candidate全条件

| 条件 | 実測 | 基準 | 判定 |
|---|---:|---:|:---:|
| acceptable率 | 47.22% | 70%以上 | FAIL |
| acceptable件数 | 51 | 76以上 | FAIL |
| baselineからのacceptable改善 | -2.78pt | +20pt以上 | FAIL |
| too-close削減率 | 34.48% | 30%以上 | PASS |
| too-close件数 | 19 | 20以下 | PASS |
| too-far + unrelated増加 | +9.26pt | +5pt以下 | FAIL |
| too-far + unrelated件数 | 35 | 30以下 | FAIL |
| unrelated件数 | 7 | 12以下 | PASS |
| acceptable analogical保持率 | 88.57% | 90%以上 | FAIL |
| acceptable analogical件数 | 31 | 32以上 | FAIL |
| analogical内acceptable率 | 100% | 90%以上 | PASS |
| 3反復すべてacceptableのEntry率 | 11.11% | 50%以上 | FAIL |
| 3反復すべてacceptableのEntry件数 | 4 | 18以上 | FAIL |
| semantic SILENCE率 | 2.78% | 20%以下 | PASS |
| semantic SILENCE件数 | 3 | 21以下 | PASS |
| user_fact_assertion | 0 | 0 | PASS |
| explicit_contradiction | 0 | 0 | PASS |
| advice_or_diagnosis | 0 | 0 | PASS |
| 未解決low-confidence | 8 | 0 | FAIL |
| 正常EntryのSAFETY過剰遮断 | 0 | 0 | PASS |
| 完了フロー技術エラー | 0 | 0 | PASS |
| End-to-End p95 | 6.23389秒 | 6秒以下 | FAIL |
| 1投稿費用 | 0.4239円 | 1円以下 | PASS |
| 正常時外部API回数 | 3 | 3以下 | PASS |
| リアルタイムLine評価LLM | 0 | 0 | PASS |

25条件中14条件がPASS、11条件がFAILである。

## rejection floor

| 棄却下限 | 実測 | 発火 |
|---|---:|:---:|
| 必須安全・policy不適合が1件以上 | 0 | NO |
| 有効実行で運用上限違反 | p95超過 | YES |
| acceptable改善が10pt未満 | -2.78pt | YES |
| too-close削減率が20%未満 | 34.48% | NO |
| acceptable analogical保持率が60%未満 | 88.57% | NO |
| analogical内acceptable率が80%未満 | 100% | NO |
| too-far + unrelated率が35%超 | 32.41% | NO |

## low-confidence感度

B-v2のlow-confidence 8種類は、Codex暫定で許容7件、不許容1件である。すべてを不許容に確定した場合は44 / 108（40.74%）、すべてを許容に確定した場合は52 / 108（48.15%）となる。最良ケースでもcandidate最低76件に届かず、acceptable改善10ポイント未満の棄却下限も解消しない。

したがって人間確認は将来のrubric改善には有用だが、今回のGate A結果を変える可能性はない。人間確認を待たずにEpicを進める。

## 解釈と遷移

B-v2はtoo-close削減、無関係Lineの上限、安全、SILENCE、費用、API回数で有効な点を示した。しかし、現構成ではtoo-closeを適切な距離へ置換できず、too-far / weak connectionが増え、acceptable、反復一貫性、analogical保持、p95を同時に満たせなかった。

`architecture_rejected`は今回検証した固定方式版の判断であり、abstraction下限 + surface上限という発想一般や、将来の別方式を否定するものではない。また本番採用可否やGate Bを判定したものでもない。

Gate Aが`architecture_candidate`ではないため、現方式を固定baselineとしてLineプール改善Epicへ移行する条件は成立しない。Issue #49で、Lineプール改善へ進まないことと、将来再検証するときの解除条件を確定する。

機械可読な全条件、棄却下限、感度分析は`poc/ai_line_selection/data/evaluations/b_v2_gate_a_decision_v1.json`を正とする。判定処理に伴う外部API実行は0回である。
