# B-v2 Epic結果

## 最終結論

Epic #40では、`b-v2-band-pass-design-v2`を固定したうえで、表現方式、band-pass、policy、selector、本統合実API、B-v1比較、Gate A、Lineプール改善への遷移をIssue #42〜#49で検証した。

Gate Aの最終判定は`architecture_rejected`である。現方式はtoo-close削減、無関係Line、安全、SILENCE、費用、API回数では有効な部分があったが、acceptable改善、too-far抑制、反復一貫性、analogical保持、p95を同時に満たせなかった。このため現方式を固定baselineとするLineプール改善Epicには進まない。

## Issue別結果

| Issue | 結果 |
|---|---|
| #42 | single enumとprimary + secondaryを比較し、小規模実APIスモーク後に`b-v2-profile-primary-secondary-v1`を採用。60有効出力、初回schema成功率100%、費用12.1248円。 |
| #43 | 保存成果物でabstraction下限 + surface上限をオフライン検証し、`A_min=0.45`、`S_max=0.55`、`Top N=20`、`text-embedding-3-small` / 1536 / cosineを固定。保存vector制約により文字bigram proxy診断であることを明記。 |
| #44 | `b-v2-guard-policy-v1`としてLine承認policyと投稿時業務ルールを分離。独立した比喩・別具体例を許容し、user fact断定・明示矛盾・版不一致・status・履歴再利用を制御。 |
| #45 | uniform、abstraction weighted、bounded domainを比較し、`b-v2-selector-v1 / uniform`を固定。seed再現率100%、rule違反0、リアルタイムLine評価LLM 0回。 |
| #46 | 現Approved 96 Lineを変えず36 Entry × 3反復を実APIで完走。105 Line、3 SILENCE、acceptable 51 / 108。 |
| #47 | B-v1と同一rubricで比較。acceptable -2.78pt、too-close -10件、too-far + unrelated +10件、1投稿費用 -0.1271円、p95 +0.74621秒。 |
| #48 | 固定済みGate Aの25条件を機械評価し、14 PASS / 11 FAIL。棄却下限2件が発火し`architecture_rejected`。 |
| #49 | Lineプール改善Epicを作成せず、現構成を`rejected_experiment_not_gate_b_baseline`として再現用snapshot化。 |

## 固定した実験構成

- abstraction + domain: `b-v2-profile-primary-secondary-v1`
- Embedding: OpenAI `text-embedding-3-small`、1536次元、cosine
- band-pass: `A_min=0.45`、`S_max=0.55`、`Top N=20`
- grounding / policy: `b-v2-guard-policy-v1`
- selector: `b-v2-selector-v1 / uniform`
- seed: `SHA256(base_seed|entry_id|repetition)`先頭64bit
- SAFETY: `additional-v3`
- rubric: `reflective-distance-v1`
- Lineプール: 現Approved 96件、Epic中の追加・削除・本文変更なし

## 本統合108枠

| 指標 | 結果 |
|---|---:|
| acceptable | 51 / 108（47.22%） |
| 3反復すべてacceptable | 4 / 36（11.11%） |
| semantic SILENCE | 3 / 108（2.78%） |
| distance | just_right 51 / too_close 19 / too_far 28 / not_obserbing 7 / SILENCE 3 |
| relation | analogical_transfer 31 / same_domain 20 / direct_restatement 19 / weak_connection 28 / unrelated 7 / SILENCE 3 |
| acceptable analogical_transfer | 31 |
| user_fact_assertion | 0 |
| explicit_contradiction | 0 |
| advice_or_diagnosis | 0 |
| SAFETY過剰遮断 | 0 |
| 技術エラー | 0 |
| p95 | 6.23389秒 |
| 1投稿費用 | 0.4239円 |
| 通常外部API | 3回 / 投稿 |
| リアルタイムLine評価LLM | 0回 |

low-confidenceは8種類・8表示で、Codex暫定は許容7件、不許容1件である。全件を不許容にすると44 / 108、全件を許容にすると52 / 108であり、どちらでもGate A結果は変わらない。

## API予算

- Issue #42: 12.1248円（上限500円）
- Issue #46: 69.3504円（上限1,500円）
- Epic #40合計: 81.4752円（上限2,000円）
- #43〜#45、#47〜#49: 0円・外部API 0回

#42では60有効出力に加え、Providerが`uniqueItems` schemaを拒否した1回を費用台帳へ含めた。#46では旧既定SAFETY設定で無効になった13回を保存して費用へ含め、preflight追補コミット後に対象13枠だけを`additional-v3`で再実行した。秘密情報、Provider生レスポンス、request IDは成果物に保存していない。

## Gate A

全25条件のPASS / FAILは[B-v2 Gate A判定](B-v2_Gate_A判定.md)を正とする。主要FAILはacceptable 51 < 76、改善-2.78pt < +20pt、too-far + unrelated 35 > 30、acceptable analogical 31 < 32、3反復全許容4 < 18、low-confidence 8 > 0、p95 6.23389秒 > 6秒である。

棄却下限は、acceptable改善が+10ポイント未満、および有効実行のp95運用上限違反が発火した。絶対製品品質80%未達だけで棄却したものではない。

## 次の扱い

Lineプール改善Epicは作成しない。次に検討するなら、現B-v2と別versionの選定方式PoCを先に設計し、結果前に評価基準を固定する。方式がGate Aを通過してから、方式を固定しLineプールだけを変更するEpicへ進む。

Gate Bは未起動であり、本番採用判断も行っていない。現B-v2の`architecture_rejected`は、今回検証した具体的構成への判断であり、abstractionやband-passという発想一般を否定するものではない。
