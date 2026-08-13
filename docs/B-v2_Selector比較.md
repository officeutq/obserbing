# B-v2 Selector比較

## 結論

Issue #46で使用するselectorを`b-v2-selector-v1 / uniform`として固定する。適格候補をLine IDで安定sortし、`SHA256(base_seed | entry_id | repetition)`の先頭64 bitから作るseedで一様抽選する。

selectorの前にstatus、profile / Embedding版、Line承認policy、Entry runtime policy、履歴・再利用を適用する。適格候補が0件ならSILENCEとし、閾値やpolicyを緩和しない。リアルタイムLine評価LLMは0回である。

## 比較方式

- uniform random
- abstraction similarity weighted random（weight 0.75〜1.0）
- domain diversity補助付きrandom（domain影響最大1.20、hard include / excludeなし）

36 Entry × 3反復の保存済み候補から、#43の`Top N=20 / A_min=0.45`と診断surface proxyを適用した。品質比較は固定済み`reflective-distance-v1`ラベルを持つ候補に限定し、ラベルはselectorへ渡していない。

## 結果

3方式はいずれも、72 Line・36 SILENCE、acceptable 46 / 72（63.89%）、acceptable analogical 29、同一入力・候補・seed再現率100%、rule違反0件で同じ結果になった。候補数が小さく、bounded weightの差が今回のseedで選択結果を変えなかったためである。

このSILENCE率33.33%はラベル済み候補だけに絞った比較上の値であり、#46の本統合SILENCE予測には使わない。

## 採用理由

重み付けによる品質改善を確認できない状態で複雑さを持ち込まず、適格帯域のどの候補も選べるuniformを採用する。最高類似候補への偏りを増やさないため、too-close回避というB-v2の設計意図とも整合する。domainは結果分析と将来の選択分布改善へ残すが、今回のselectorには使用しない。

外部API、Line評価LLM、Lineプール変更、Gate基準変更はいずれも0である。機械可読条件は`b_v2_selector_criteria_v1.yml`、比較結果は`b_v2_selector_comparison_v1.json`へ保存した。
