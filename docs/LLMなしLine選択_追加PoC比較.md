# LLMなしLine選択 追加PoC比較

**文書ステータス：固定seed比較・Blind一次評価完了**

**作成日：2026年8月13日**

**関連Issue：#24 / Epic #27**

## 1. 結論

比較した4方式はすべて採用基準に届かなかった。後続の統合PoCへ渡せる適格な選択方式はない。

診断上の最良方式は `similarity_weighted_top_n` で、履歴なし・固定3 seedの表示許容率は82.41%だった。事前基準90%に7.59ポイント不足する。類似度が高いLineを選びやすくしても、abstraction EmbeddingのTop 5だけでは「近すぎる」Lineを十分に避けられない。

一方、Issue #23の `combined_v1` を適用した後は、選択結果の致命的事実不整合が全方式0件になった。Approved状態、180日再利用、直近Meaning、禁止属性、事実整合の違反も0件で、同じseedの再現率は100%だった。非LLMガードと決定的乱択の技術的成立は確認できたが、選択品質は未達である。

Issue #22の候補集合安定性未達も解消していないため、`similarity_weighted_top_n` はIssue #25で診断比較にだけ使用し、本番候補とは扱わない。

## 2. 比較条件

| 項目 | 条件 |
|---|---|
| Entry | 固定合成日記36件 |
| 入力候補 | Issue #22 `abstraction_only_v2` 代表反復のTop 5 |
| Blind品質 | Issue #22で方式・Theme・類似度を伏せて評価済みの180候補 |
| 事実整合 | `grounding-guard-v1` / `grounding-attributes-v1` |
| seed | 2719001 / 2719002 / 2719003 |
| 履歴シナリオ | 履歴なし、Top 1再利用済み、Top 3再利用済み、Top 1と同じMeaningが直近、全Top 5再利用済み |
| 閾値 | cosine similarity 0.45 |
| 比較実行 | 36 Entry × 4方式 × 5シナリオ × 3 seed = 2,160件 |
| Line評価LLM | 0回 |
| 外部API | 0回、0円 |

元の候補成果物から、本文・評価理由・Provider名を除いた固定スナップショットを `data/evaluations/ruby_selection_inputs_v1.json` に保存した。候補ID、類似度、Blind評価ラベル、元成果物のSHA-256だけを保持する。

## 3. 比較方式

1. `top1`: ガード後の最上位1件を固定選択する。
2. `uniform_top_n`: ガード後の上位5件から一様乱択する。
3. `similarity_weighted_top_n`: 上位5件から `similarity + 0.01` を重みにして乱択する。
4. `threshold_uniform`: similarity 0.45以上の候補から一様乱択する。

乱数seedは、設定seed、Entry ID、履歴シナリオ、方式名からCRC32で決定する。同じ版・入力・seedなら同じLineまたはSILENCEになる。

## 4. 適用順

全方式で次の順を固定した。

1. Approved状態
2. 同一Lineの180日再利用禁止
3. 同一Meaningの直近利用禁止
4. 明示的禁止属性
5. `combined_v1`事実整合ガード
6. 方式固有の品質条件と選択

候補がすべて除外された場合は `all_candidates_filtered`、閾値を満たさない場合は `strategy_quality_condition_unmet` として、どちらも技術エラーではなくSILENCEへ分岐する。候補外Lineの追加検索はしない。

## 5. Blind品質

履歴なし36件を固定3 seedで選んだ、各方式108表示を集計した。`threshold_uniform`だけ1 Entryが全seedで閾値未達となり、105表示で評価した。

| 方式 | 表示許容率 | just right | too close | too far | 明らかな無関連 | 致命的事実不整合 | 履歴なしSILENCE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Top 1固定 | 61.11% | 60 | 39 | 9 | 2.78% | 0 | 0% |
| 上位5件一様 | 76.85% | 64 | 25 | 19 | 0.93% | 0 | 0% |
| 類似度重み付き | **82.41%** | 59 | 18 | 31 | 1.85% | 0 | 0% |
| 閾値0.45以上 | 78.10% | 55 | 19 | 31 | 2.86% | 0 | 2.78% |

Top 1固定は「近すぎる」が39 / 108件あり、最も低品質だった。一様乱択と重み付き乱択は近すぎる出力を減らしたが、too farを増やした。類似度だけではobserbing distanceを直接制御できない。

事前基準との比較では、全方式が致命的不整合0件、明らかな無関連5%以下、not_obserbing 10%以下を満たした。しかし表示許容率90%以上を満たす方式はなかった。結果を見て基準は下げない。

## 6. 履歴・SILENCE・多様性

| 方式 | 全5シナリオSILENCE率 | 3 seedのEntry当たり平均出力種類 | ルール違反 |
|---|---:|---:|---:|
| Top 1固定 | 21.11% | 1.0000 | 0 |
| 上位5件一様 | 21.11% | 2.3333 | 0 |
| 類似度重み付き | 21.11% | 2.3333 | 0 |
| 閾値0.45以上 | 33.33% | 2.0000 | 0 |

全Top 5を再利用済みにしたシナリオは、全方式・全Entry・全seedでSILENCEになった。これは期待した意味的分岐である。閾値方式は履歴制約との組み合わせで候補不足が増え、SILENCE上限25%も超えた。

状態、再利用、直近Meaning、禁止属性、事実整合の選択後違反はそれぞれ0件だった。同一seedの2回実行は2,160 / 2,160件一致した。

## 7. 性能・費用

Ruby選択を決定性確認のため2回実行した総時間は399.666msだった。これは固定36件のローカル完全実行で、本番DBアクセス時間を含まない。

- リアルタイムLine評価LLM: 0回
- 追加外部API: 0回
- 追加token: 0
- Issue #24追加費用: 0円
- Epic #27累積費用: 547.8733円

## 8. 判定

| 基準 | 最良結果 | 判定 |
|---|---:|---|
| 表示許容率90%以上 | 82.41% | 未達 |
| 致命的事実不整合0件 | 0件 | 達成 |
| 明らかな無関連5%以下 | 0.93%〜2.86% | 達成 |
| not_obserbing 10%以下 | 0% | 達成 |
| SILENCE 25%以下 | 3方式21.11% | 達成 |
| 同一seed再現率100% | 100% | 達成 |
| 状態・履歴・禁止・事実整合違反0件 | 0件 | 達成 |

`recommended_strategy=null`、`all_strategies_rejected=true` とする。統合PoCでは診断最良の `similarity_weighted_top_n` を使い、方式全体の不採用状態を保持したままbaselineとの差を測る。

## 9. 再現方法

`poc/ai_line_selection` で実行する。

```powershell
bundle exec ruby bin\ai_line_selection plan-ruby-selection
bundle exec ruby bin\ai_line_selection compare-ruby-selection
bundle exec rake test
```

Issue #22の生結果から固定入力を再生成する場合は次を使う。

```powershell
bundle exec ruby bin\ai_line_selection export-selection-inputs `
  --results results\abstraction_embedding_<timestamp>_<suffix> `
  --export data\evaluations\ruby_selection_inputs_v1.json
```

実行結果の `summary.json` と `selections.jsonl` は `results/ruby_selection_<timestamp>_<suffix>/` に生成され、Git管理しない。
