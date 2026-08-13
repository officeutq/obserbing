# B-v2 帯域感度追補診断

## 結論

Issue #59のpost-hoc follow-up診断は **`selector_review_needed`** と判断する。

固定値`A_min=0.45 / S_max=0.55 / Top N=20`は最良ではなかった。全825設定の最良一点は`0.425 / 0.425 / Top 10`で、acceptableは51/108（47.22%）から69/108（63.89%）へ16.67ポイント改善した。したがって、今回の証拠だけでband-pass思想自体を否定するのは妥当ではない。

一方、全体最良から2ポイント以内の4近傍連結領域はTop 10の2セルだけであり、広い安定領域とはいえない。さらに最良設定でも、既知のacceptable候補が存在する100枠のうち31枠をuniform selectorが選び損ねた。この値は未評価の適格候補を悪いと仮定しない下限値である。よって、帯域だけを変更して実API PoCを再実行する前に、保存成果物を使ったselectorのオフライン再検討を優先する。

この追補はEpic #40の`architecture_rejected`および固定済みGate A結果を変更しない。

## Entry Embedding補完

#46のEntry原文36件と保存済みabstraction 108件をそのまま使用し、`text-embedding-3-small / 1536 dimensions / cosine`で144入力を1バッチ処理した。実行前に`line_index.json`が指定SHA256と一致することを確認し、Line Embeddingは再生成していない。

| 項目 | 実績 |
|---|---:|
| Entry raw text | 36 |
| Entry abstraction | 108 |
| 合計Embedding入力 | 144 |
| APIリクエスト（再試行込み） | 1 |
| input tokens | 3,627 |
| 推定費用 | 0.0109円 |
| hard cost limit | 100円 |
| 生成pair | 10,368（108 × 96） |

費用はOpenAI公式の`text-embedding-3-small`価格である$0.02 / 1M input tokensと、事前固定した1 USD = 150 JPYで算出した。Entry vector本体はGitへ保存せず、hashだけを残した。全pairの`entry_id / repetition / line_id / abstraction_similarity / surface_similarity`を持つCSVを、以後の再解析の正本とした。

Embedding補完後、SAFETY、abstraction、Line profile、Line Embedding、その他LLMを呼び出した回数はすべて0回である。帯域スイープと品質評価も外部API 0回で実行した。

## 固定条件とスイープ

profile、96 Approved Line、guard / policy、embeddingモデル、cosine、selector versionを#46から変更せず、selector strategyを`uniform`に固定した。

- `A_min`: 0.350〜0.600、0.025刻み（11値）
- `S_max`: 0.350〜0.700、0.025刻み（15値）
- `Top N`: 5 / 10 / 20 / 40 / 96（5値）
- 合計: 825設定、89,100 outcome選択

補完vectorで現設定を再生した結果、#46の108枠について選択Line、SILENCE、eligible件数がすべて一致した。現設定は105表示、SILENCE 3である。

## 現設定・最良一点・最良近傍

| 指標 | 現設定 0.45 / 0.55 / Top 20 | 最良一点 0.425 / 0.425 / Top 10 |
|---|---:|---:|
| acceptable | 51 / 108（47.22%） | 69 / 108（63.89%） |
| 3反復すべてacceptable | 4 / 36（11.11%） | 15 / 36（41.67%） |
| eligible p50 / p95 | 6 / 14 | 7 / 9 |
| SILENCE | 3 / 108（2.78%） | 4 / 108（3.70%） |
| just_right | 51 | 69 |
| too_close | 19 | 7 |
| too_far | 28 | 22 |
| not_obserbing | 7 | 6 |
| analogical_transfer | 31 | 44 |
| same_domain | 20 | 25 |
| direct_restatement | 19 | 7 |
| weak_connection | 28 | 22 |
| unrelated | 7 | 6 |

現設定はacceptableと3反復率による順位で391 / 825、acceptable percentileは53.94%だった。

「安定領域」は、全体最良acceptable率から2ポイント以内のセルをTop Nごとに4近傍で連結して事前定義した。最大領域は次の2セルである。

| Top N | A_min | S_max | acceptable |
|---:|---:|---:|---:|
| 10 | 0.425 | 0.400 | 67 / 108（62.04%） |
| 10 | 0.425 | 0.425 | 69 / 108（63.89%） |

近傍最良が一点だけではないことは確認できたが、2セルは「広く安定した帯」と呼ぶには狭い。

## acceptable率マトリクス（Top 10の主要範囲）

単位は%。完全な11 × 15 × 5パネルは`b_v2_band_sensitivity_heatmaps_v1.json`へ保存した。

| A_min \ S_max | 0.375 | 0.400 | 0.425 | 0.450 | 0.475 |
|---:|---:|---:|---:|---:|---:|
| 0.375 | 60.19 | 59.26 | 60.19 | 61.11 | 61.11 |
| 0.400 | 61.11 | 57.41 | 60.19 | 60.19 | 61.11 |
| 0.425 | 59.26 | 62.04 | **63.89** | 61.11 | 60.19 |
| 0.450 | 52.78 | 57.41 | 57.41 | 57.41 | 55.56 |
| 0.475 | 59.26 | 62.04 | 61.11 | 59.26 | 58.33 |

acceptable 60%以上は全825設定中27設定（Top 5: 7、Top 10: 14、Top 20/40/96: 各2）だった。55%以上は181設定あり、帯域変更による改善領域は存在する。ただし60%台前半では凹凸があり、63.89%付近のplateauは狭い。

## Top Nの影響

各Top Nの最良acceptable率は次のとおりだった。

| Top N | 最良acceptable率 | 最良設定 |
|---:|---:|---|
| 5 | 62.04% | 0.475 / 0.400 |
| 10 | **63.89%** | 0.425 / 0.425 |
| 20 | 61.11% | 0.475 / 0.400 |
| 40 | 61.11% | 0.475 / 0.400 |
| 96 | 61.11% | 0.475 / 0.400 |

現行の`A_min=0.45 / S_max=0.55`だけを固定してTop Nを変えると、Top 5は53.70%、Top 10は50.93%、Top 20/40/96は47.22%だった。候補数を広げてもuniformは良いLineを優先しないため、候補集合の拡大がそのまま品質改善にならず、選択の希釈が生じている。

## too-close / too-far

全設定でtoo-close率とtoo-far率には-0.429の相関があり、一方を減らすと他方が増えやすい構造的トレードオフは残る。

- `A_min`を1段上げた750比較のうち、too-farは589比較で減少、90比較で増加、71比較で不変だった（平均-3.456表示）。
- `S_max`を1段緩めた770比較のうち、too-closeは462比較で増加、25比較で減少、283比較で不変だった（平均+1.413表示）。

したがって、abstraction下限とsurface上限は意図した方向に効いている。ただし最良一点では現設定よりtoo-closeが19→7、too-farが28→22と両方減っており、改善が単なる入れ替えだけだったわけではない。

## selector診断

全設定で実際に選択された固有587 pairの品質ラベルを揃えた。既存143 pairの評価を保持し、新規444 pairを`reflective-distance-v1`でCodex暫定評価した。新規評価はすべて`judge=codex_provisional / provisional=true`で、人間評価とは区別している。新規444 pair中64 pairはlow-confidenceである。

最良設定では適格候補occurrenceの75.47%に品質ラベルがあり、既知のacceptable候補がある枠は100 / 108だった。uniformがそのacceptable候補を選ばなかった枠は31 / 100（31.00%）である。未ラベル候補を不許容とみなしていないため、このselector改善余地は下限値である。

この結果は「帯域内に良いLineがない」よりも、「良いLineが含まれていてもuniformが取り逃す」問題が残っていることを示す。よって最終診断は`selector_review_needed`とする。

## 次の一手

新しい実API実行はまだ行わず、今回の全pair similarityと既存品質ラベルを固定して、軽量selectorをオフライン比較する。

候補は、品質ラベルを本番入力へ直接使わない前提で、abstraction順位、surface中央寄せ、帯域端からの距離、domain多様性等の観測可能な特徴を組み合わせた決定的selectorである。目的は、uniformの31枠の取り逃しを再現可能なルールでどこまで減らせるかを検証することにある。

444件はCodex暫定評価であり、64件のlow-confidenceを含む。この制約を残したままselector候補を絞り、次の実API再PoCを行う場合には低確信pairの人間確認を優先する。

## 成果物

- `data/evaluations/b_v2_entry_embedding_completion_v1.json`
- `data/evaluations/b_v2_band_sensitivity_codex_review_v1.yml`
- `data/evaluations/b_v2_band_sensitivity_conclusion_v1.yml`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_pair_similarities_v1.csv`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_selections_v1.csv`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_mechanical_v1.jsonl`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_pair_judgments_v1.csv`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_quality_v1.jsonl`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_heatmaps_v1.json`
- `data/evaluations/b_v2_band_sensitivity_v1/b_v2_band_sensitivity_analysis_v1.json`

Entry vectorはGitへ保存していない。pair similarity CSVと各source hashを再解析の正本とする。
