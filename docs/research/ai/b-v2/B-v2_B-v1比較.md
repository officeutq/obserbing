# B-v2 / B-v1比較

## 結論

Issue #47では、Issue #46のB-v2保存結果と、Issue #38で`reflective-distance-v1`により確定したB-v1 `abstraction-only-v1-diagnostic`の保存結果を、外部APIを追加実行せず比較した。

B-v2はdirect restatement / too-closeを29件から19件へ34.48%削減し、1投稿費用を0.5510円から0.4239円へ下げた。一方、acceptableは54件から51件へ減り、too-far + unrelatedは25件から35件へ増えた。3反復すべてacceptableのEntryも10件から4件へ減少した。つまり、surface上限は近すぎるLineを抑えたが、現Lineプールでは適切な距離のLineへ十分置換できず、遠すぎる側へ移った傾向がある。

この文書はGate Aの入力を提供する。3値の最終判定はIssue #48で固定済み基準により行い、Gate Bの製品品質基準はここでは判定しない。

## 比較結果

| 指標 | B-v1 | B-v2 | 差 |
|---|---:|---:|---:|
| outcome | 108 | 108 | 0 |
| acceptable | 54（50.00%） | 51（47.22%） | -3件 / -2.78pt |
| direct_restatement / too-close | 29 | 19 | -10件 / 34.48%削減 |
| too-far + unrelated | 25 | 35 | +10件 / +9.26pt |
| unrelated | 9 | 7 | -2件 |
| acceptable analogical_transfer | 35 | 31 | -4件 / 保持率88.57% |
| analogical_transfer内acceptable率 | 100% | 100% | 0pt |
| 3反復すべてacceptableのEntry | 10 / 36（27.78%） | 4 / 36（11.11%） | -6件 |
| semantic SILENCE | 0 | 3（2.78%） | +3件 |
| p95 | 5.48768秒 | 6.23389秒 | +0.74621秒 |
| 1投稿費用 | 0.5510円 | 0.4239円 | -0.1271円 |
| 通常外部API / 投稿 | 3 | 3 | 0 |
| リアルタイムLine評価LLM | 0 | 0 | 0 |
| SAFETY過剰遮断 | 0 | 0 | 0 |
| 技術エラー | 0 | 0 | 0 |
| user_fact_assertion | 0 | 0 | 0 |
| explicit_contradiction | 0 | 0 | 0 |
| advice_or_diagnosis | 0 | 0 | 0 |
| 未解決low-confidence | 0 | 8 | +8 |

## Gate Aへ渡す解釈

- acceptableの改善幅は-2.78ポイントであり、B-v1から改善していない。
- direct restatement / too-closeの34.48%削減は、固定基準の30%以上削減に相当する。
- too-far + unrelatedは35件・32.41%で、固定上限30件を超える。
- unrelated単独は7件で、固定上限12件以内である。
- acceptable analogical_transferは31件で、最低32件およびB-v1比90%保持にわずかに届かない。relation内のacceptable率は100%である。
- 3反復すべてacceptableのEntryは4 / 36で、最低18件に届かない。
- SILENCE、1投稿費用、投稿時API回数、リアルタイムLine評価LLM、SAFETY、policy必須不適合、技術エラーは基準内である。
- p95は6.23389秒で6秒上限を0.23389秒超える。
- 現在のlow-confidence 8件は暫定acceptable 7件、不許容1件である。全件を許容に確定しても52 / 108、全件を不許容に確定すると44 / 108であり、Gate Aの最低76件に届かない。

## 比較上の制約

両方式は同じ固定合成Entry 36件、各3反復、108 outcome、`reflective-distance-v1`、現Approved 96 Lineを比較軸とする。一方、同時刻に同一API状態で走らせたhead-to-headではなく、異なるIssueで保存された正規化結果同士の比較である。Provider側の時間変動、実行順、個別レイテンシ条件は統制されていないため、特に速度差をモデル固有の差と過大解釈しない。

B-v1のlow-confidence 13表示はプロダクトオーナーにより確定済みだが、B-v2の8種類はCodex暫定判断のまま残る。このラベル確定度の差も品質比較上の制約である。ただし前述の範囲分析により、8件の人間判断がGate Aのacceptable条件を反転させることはない。

Gate Bのacceptable 80%以上（目標90%）や3反復すべてacceptable 60%以上（目標75%）は、Gate A通過後に方式を固定しLineプールを改善した段階の製品品質基準である。現96 Lineを使うGate Aと混同しない。

機械可読な再計算結果は`poc/ai_line_selection/data/evaluations/b_v2_vs_b_v1_comparison_v1.json`を正とする。入力hashと現Lineプールhashを同成果物に記録している。
