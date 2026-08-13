# B-v2 Band-passオフライン検証

## 結論

Issue #46より前に、B-v2の検索条件を次のとおり固定する。

- profile: `b-v2-profile-primary-secondary-v1`
- Embedding: OpenAI `text-embedding-3-small` / 1536次元 / cosine / `b-v2-openai-small-dual-cosine-v1`
- `A_min = 0.45`
- `S_max = 0.55`
- `Top N = 20`

abstractionは適格下限、surfaceはtoo-close除外上限として別々に適用する。両者を「高いほど良い」単一スコアへ統合せず、候補不足時にも閾値を自動緩和しない。

## 入力とAPI制約

外部API、Embedding API、abstraction生成は0回である。36 Entry × 3反復・Approved 96 Lineの保存済み`abstraction_only_v2`候補集合、保存済みraw-text Embedding診断、`reflective-distance-v1`ラベル、#42の版付きprofile成果物を使用した。Line本文・status・Approved集合は変更していない。

#42のprofile出力は10対象だけなので、閾値の直接調整には使わず、版と表現契約の出所確認に限定した。候補回収とラベル感度は36 Entryの旧保存profileで診断し、少数subsetへの過適合を避けた。

## オフライン感度

保存されたProvider候補集合にはabstraction cosineがある。一方、raw-text Providerベクトルは保存されておらず、全候補のsurface cosineを再構成できなかった。この不足をAPIで補わず、全候補の相対感度にはNFKC後の文字bigram cosineを診断proxyとして使った。proxy値を実行時のProvider cosineへ変換してはいない。

`A_min=0.45`、surface proxy上限0.12での比較は次のとおりである。

| Top N | 平均適格候補 | p50 | p95 | 候補0枠 | ラベル済みacceptable率 | direct restatement | too-far + unrelated | acceptable analogical |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 2.8519 | 3 | 5 | 5 | 65.66% | 17 | 17 | 43 |
| 10 | 3.9259 | 3 | 9 | 5 | 65.35% | 18 | 17 | 44 |
| 20 | 4.0463 | 3 | 9 | 5 | 65.35% | 18 | 17 | 44 |

`A_min=0.40`では候補0枠が0になるがtoo-far / unrelatedを多く残し、0.50では候補0が30 / 108へ急増した。0.45は橋の弱い候補を抑えつつ、診断上のSILENCE見込みを5 / 108（4.63%）に留める中間点である。Top 20はTop 10からの増分は小さいが、profile変更後も閾値適用前のanalogical候補回収余地を確保するため採用した。

## S_maxの判断

保存済みOpenAI raw-text診断は、各EntryのTop-1だけを保持していた。36件のp50は0.5446、p95は0.6805であり、`S_max=0.55`なら16件が上限を超える。`reflective-distance-v1`ラベルと結合できた22件のうち、上限超過はtoo-close 10件・just-right 3件だった。0.60ではtoo-close 4件・just-right 2件しか除外できず、B-v1のtoo-close 29件を30%以上削減する仮説として弱いため0.55を選んだ。

これは全候補surface cosineによる完全なオフライン検証ではない。証拠制約は明記したまま、#46では固定値を結果に合わせて変更せず、実Provider surface cosineで108枠を測る。証拠不足が比較妥当性へ影響する場合は#48で`further_selection_poc_required`の理由になり得る。

## 固定成果物

機械可読条件は`b_v2_band_pass_criteria_v1.yml`、75条件の感度結果は`b_v2_band_pass_offline_v1.json`へ保存した。固定済み`b-v2-band-pass-design-v2` / `b-v2-pre-evaluation-criteria-v2`は変更していない。
