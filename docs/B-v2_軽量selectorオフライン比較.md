# B-v2 軽量selectorオフライン比較

## 結論

Issue #61の最終診断は **`selector_gain_insufficient`** とする。

主帯域`A_min=0.425 / S_max=0.425 / Top N=10`では、`bounded_domain_diversity`が暫定1位になった。しかしuniformに対する改善はacceptable 1件、既知acceptable候補の取り逃し1件に留まり、事前固定した最低改善幅を満たさなかった。neighbor帯域でも同じselectorが1位だったが、改善はacceptable 2件、取り逃し2件である。

したがって、今回固定した類似度・rank・domainだけのbounded reweightingを、そのまま実API再PoCへ進める根拠は不足している。既存Epic #40の`architecture_rejected`とGate A結果は変更しない。

## 比較条件

Issue #59で保存した10,368 pairを使用し、外部APIを呼ばずに比較した。

- 主帯域: `A_min=0.425 / S_max=0.425 / Top N=10`
- neighbor帯域: `A_min=0.425 / S_max=0.400 / Top N=10`
- profile / Line pool / policy / seed / history: #46・#59から固定
- Reflective Distanceラベル: 評価だけに使用
- selector入力: abstraction similarity、surface similarity、rank、domain、policy eligibility、seedのみ
- weight: 0.75〜1.25、最大比1.666667
- 外部API: 0回

品質ラベルを含むcandidateをselectorへ渡すと例外にする実装と自動テストを追加した。両帯域のuniform選択は、Issue #59の108枠とLine、SILENCE、eligible件数まですべて一致した。

## 比較selector

| selector | 固定方式 |
|---|---|
| `uniform` | 全候補weight 1.0 |
| `abstraction_bounded_weighted` | 候補内abstraction similarityを正規化 |
| `surface_band_center` | 候補内surface最小値とS_maxの中央へ寄せる |
| `dual_margin_band_center` | abstraction下限marginとsurface上限marginの調和平均 |
| `rank_fusion` | abstraction降順rank 60% + surface昇順rank 40% |
| `bounded_domain_diversity` | abstraction 80% + 候補内domain希少度20% |

方式、weight、評価順、CV、診断閾値、Blind抽出規則は品質集計前のコミット`6a692e5`で固定した。結果を見て方式やweightを追加・変更していない。

## 主帯域の結果

分母はSILENCEを含む108枠。取り逃しは、既知acceptable候補が存在する100枠に対する件数である。

| selector | acceptable | 3反復すべてacceptable | too-close | too-far | not_obserbing | analogical | same-domain | 取り逃し | SILENCE |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `bounded_domain_diversity` | **70（64.81%）** | **16/36（44.44%）** | 7 | 22 | 5 | 46 | 24 | **30/100** | 4 |
| `uniform` | 69（63.89%） | 15/36（41.67%） | 7 | 22 | 6 | 44 | 25 | 31/100 | 4 |
| `rank_fusion` | 68（62.96%） | 14/36（38.89%） | 8 | 22 | 6 | 43 | 25 | 32/100 | 4 |
| `abstraction_bounded_weighted` | 67（62.04%） | 13/36（36.11%） | 8 | 25 | 4 | 43 | 24 | 33/100 | 4 |
| `surface_band_center` | 67（62.04%） | 13/36（36.11%） | 6 | 26 | 5 | 42 | 25 | 33/100 | 4 |
| `dual_margin_band_center` | 64（59.26%） | 10/36（27.78%） | 8 | 26 | 6 | 39 | 25 | 36/100 | 4 |

relation_typeでは、上表のtoo-close / too-far / not_obserbingがそれぞれdirect_restatement / weak_connection / unrelatedと同数である。

uniformの主診断だった31/100の取り逃しは、最良方式でも30/100までの1件減に留まった。事前基準は10件以上の削減であり未達である。

## neighbor帯域

neighborでも`bounded_domain_diversity`が1位で、selector順位のSpearman相関は0.885714だった。

| selector | acceptable | 3反復すべてacceptable | 取り逃し |
|---|---:|---:|---:|
| `bounded_domain_diversity` | **69（63.89%）** | **14/36（38.89%）** | **28/97** |
| `rank_fusion` | 68（62.96%） | 14/36（38.89%） | 29/97 |
| `uniform` | 67（62.04%） | 13/36（36.11%） | 30/97 |
| `surface_band_center` | 66（61.11%） | 12/36（33.33%） | 31/97 |
| `abstraction_bounded_weighted` | 65（60.19%） | 11/36（30.56%） | 32/97 |
| `dual_margin_band_center` | 63（58.33%） | 9/36（25.00%） | 34/97 |

勝者自体は再現したが、事前基準のacceptable +3ポイント、取り逃し7件削減には届かなかった。

## Entry単位6-fold CV

Entry番号を6で割った固定foldを使い、各foldで30 Entryをdev、6 Entryをholdoutとした。selector式やweightの学習・調整は行っていない。

- 主帯域のdev winner: 6/6 foldで`bounded_domain_diversity`
- holdout acceptableがuniformより改善: 2/6 fold
- 同率: 3/6 fold
- 悪化: 1/6 fold
- holdout取り逃しがuniform以下: 5/6 fold

dev順位は安定したが、holdout改善は2/6 foldに留まった。このCVは同じ36合成Entryを分割したpost-hoc安定性確認であり、未知のユーザー入力への一般化性能を証明しない。

## low-confidence感度

主帯域の`bounded_domain_diversity`は暫定ラベル込みで70件、uniformは69件だった。しかし、どちらかの選択がlow-confidenceである13枠を除くと、両者とも58件で差は0だった。

neighborではlow-confidence 11枠を除外後も59対58で1件差が残った。主帯域の小さな改善はlow-confidence判断で反転し得るため、Codex暫定acceptable率だけで採用判断はしない。

## 再現性・偏り・計算コスト

全selector・両帯域でseed再現率は100%だった。主帯域の最大Line選択数はuniform、`bounded_domain_diversity`とも5/104表示（4.81%）で、bounded weightingによる極端な集中は生じていない。

108選択のローカル計算は全方式で約2〜4ms、1選択あたり約0.018〜0.039msだった。外部API費用は0円である。絶対時間は実行環境依存であり、方式間の桁が同じことを確認する診断値として扱う。

## Blind人間評価パケット

主帯域の上位3方式、`bounded_domain_diversity / uniform / rank_fusion`で選択Lineが分かれた全17ケースをBlind packetにした。24件を目標としていたが、条件に該当するケースが17件だったため、追加の非分岐ケースで水増ししていない。

- provisional acceptableが分かれるケース: 8件
- low-confidenceを含むケース: 5件
- packetに表示するもの: Entry本文、Line本文、○/×欄
- 隠すもの: selector名、Line ID、similarity、Codex判定、既存ラベル

人間評価の完了はIssue #61の完了条件にしない。mappingはBlind packetと分離して保存している。

## 診断基準との比較

| 条件 | 実績 | 基準 | 判定 |
|---|---:|---:|---|
| 主帯域acceptable改善 | +0.93pt | +5pt以上 | FAIL |
| 主帯域取り逃し削減 | 1件 | 10件以上 | FAIL |
| neighbor acceptable改善 | +1.85pt | +3pt以上 | FAIL |
| neighbor取り逃し削減 | 2件 | 7件以上 | FAIL |
| neighbor順位 | 1位 | 2位以内 | PASS |
| holdout改善fold | 2/6 | 4/6以上 | FAIL |
| holdout取り逃し非悪化fold | 5/6 | 4/6以上 | PASS |
| 最大Line share増加 | 0pt | +5pt以下 | PASS |

以上から`selector_gain_insufficient`とする。

## 次の推奨

今回の6方式を使った実API再PoCは行わない。まず17件のBlind packetを人間評価し、1件差の暫定順位がプロダクト判断でも維持されるかを確認する。

人間差分を反映しても改善が小さい場合、similarity・rank・domainの単純なbounded reweightingを増やし続けない。別Issueで、品質を直接リークしない第3の観測可能特徴、またはLineプール側の改善条件を基本設計から検討する。今回の結果だけで既存Gate AやEpic #40をreopenしない。

## 成果物

- `data/evaluations/b_v2_lightweight_selector_criteria_v1.yml`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_selections_v1.csv`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_comparison_v1.json`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_cross_validation_v1.json`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_conclusion_v1.json`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_blind_human_review_v1.csv`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_blind_mapping_v1.yml`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_timing_v1.json`
- `data/evaluations/b_v2_lightweight_selector_v1/b_v2_lightweight_selector_manifest_v1.json`

全成果物は保存済みpairのオフライン処理だけで生成し、外部APIは0回である。
