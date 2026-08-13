# B-v2 本統合実API PoC

## 結論

Issue #46では、固定合成Entry 36件を3反復した108枠について、現Approved 96 Lineを変更せずB-v2を実APIで接続した。108枠はすべて正常EntryとしてSAFETYを通過し、105枠でLineを表示、3枠で意味上のSILENCEとなった。

`reflective-distance-v1`によるCodex暫定評価のacceptable outcomeは51 / 108（47.22%）である。8種類・8表示はlow-confidenceで人間確認が必要だが、全8件が反転してもGate Aのacceptable最低76件には届かず、後続のGate判定が反転する余地はない。

本Issueでは結果に合わせた基準、しきい値、rubric、baseline、Lineプールの変更を行っていない。最終判定はIssue #48で固定済みGate Aを用いて行う。

## 固定構成

- profile: `b-v2-profile-primary-secondary-v1`
- Embedding: OpenAI `text-embedding-3-small`、1536次元、cosine、`b-v2-openai-small-dual-cosine-v1`
- band-pass: `A_min=0.45`、`S_max=0.55`、`Top N=20`
- policy: `b-v2-guard-policy-v1`
- selector: `b-v2-selector-v1 / uniform`
- rubric: `reflective-distance-v1`
- リアルタイムLine評価LLM: 0回

## 実行結果

| 項目 | 結果 |
|---|---:|
| 正常outcome | 108 / 108 |
| Line表示 | 105 |
| semantic SILENCE | 3 / 108（2.78%） |
| acceptable | 51 / 108（47.22%） |
| 3反復すべてacceptableのEntry | 4 / 36（11.11%） |
| p50 | 3.42627秒 |
| p95 | 6.23389秒 |
| 最大 | 7.75923秒 |
| 正常系外部API | 1投稿3回 |
| リアルタイムLine評価LLM | 0回 |
| 技術エラー | 0 |
| 1投稿費用 | 0.4239円 |
| Issue #46 API費用 | 69.3504円 |
| Epic #40 API累計 | 81.4752円 |

費用には、後述するSAFETY設定不整合で破棄した13回の呼び出しも含めた。Line事前profile 96回とLine一括Embedding 1回を含む実呼び出しは合計434回、総tokenは167,603であり、Issue上限1,500円およびEpic上限2,000円の範囲内である。

## Reflective Distance分布

### distance

| distance | 表示数 |
|---|---:|
| just_right | 51 |
| too_close | 19 |
| too_far | 28 |
| not_obserbing | 7 |
| semantic_silence | 3 |

### relation_type

| relation_type | 表示数 |
|---|---:|
| analogical_transfer | 31 |
| same_domain | 20 |
| direct_restatement | 19 |
| weak_connection | 28 |
| unrelated | 7 |
| semantic_silence | 3 |

analogical_transfer 31件はすべてCodex暫定評価でacceptableである。必須不適合は`user_fact_assertion=0`、`explicit_contradiction=0`、`advice_or_diagnosis=0`、既存正常EntryのSAFETY過剰遮断0、技術エラー0だった。`clearly_unrelated`は7件、未解決low-confidenceは8種類・8表示である。

## 人間確認対象

次の8種類はCodex暫定判断の確信度をlowとした。Entry本文、Line本文、暫定ラベルと理由は`b_v2_integrated_evaluation_v1.json`に保存している。

- E007 / L066: acceptable / analogical_transfer
- E008 / L107: unacceptable / weak_connection
- E011 / L085: acceptable / analogical_transfer
- E019 / L013: acceptable / analogical_transfer
- E021 / L031: acceptable / same_domain
- E024 / L004: acceptable / analogical_transfer
- E032 / L043: acceptable / analogical_transfer
- E035 / L095: acceptable / analogical_transfer

暫定acceptableは7件、不許容は1件である。全件が逆方向に反転した場合でもacceptableは44〜52件の範囲であり、Gate A最低76件へ到達しない。このため人間確認は品質学習用の証拠として残すが、Epic #40の進行は停止しない。

## SAFETY設定不整合と再開

初回実行で13枠が旧既定SAFETY prompt/schemaによって`indeterminate`になった。これは採用済み境界の結果ではなく実装設定の不整合であるため、`b_v2_integrated_preflight_v1_1.yml`をAPI再実行前に追加コミットし、次の条件で修復した。

- 採用済み`additional-v3` prompt/schemaのみへ設定を修正
- 該当13枠だけを再実行
- 初回13件を`b_v2_integrated_invalid_safety_outputs_v1.jsonl`へ保持
- 初回分を含むtoken・費用をhard limitへ算入
- しきい値、criteria、rubric、Provider/model、Lineプールは不変

修復後の108枠はすべて`normal`であり、SAFETY過剰遮断は0件だった。

## 成果物

- `b_v2_integrated_preflight_v1.yml`: 初回実行前preflight
- `b_v2_integrated_preflight_v1_1.yml`: SAFETY対象再実行前の追補preflight
- `b_v2_integrated_line_profiles_v1.jsonl`: 96 Lineの正規化profile
- `b_v2_integrated_outputs_v1.jsonl`: 108枠の正規化出力
- `b_v2_integrated_invalid_safety_outputs_v1.jsonl`: 破棄した13件の追跡記録
- `b_v2_integrated_codex_judgments_v1.csv`: 新規80種類のCodex暫定判断
- `b_v2_integrated_evaluated_outcomes_v1.jsonl`: 108枠の最終追跡表
- `b_v2_integrated_evaluation_v1.json`: 品質・速度・費用集計と人間確認対象
- `b_v2_integrated_live_v1.json`: API実行集計
- `b_v2_integrated_manifest_v1.json`: 固定入力hashと実行条件
- `b_v2_integrated_artifact_manifest_v1.yml`: 保存元とhash

外部APIは統合処理と対象13枠の修復にだけ使用した。Reflective Distance評価・集計では外部AI API、Embedding API、SAFETY API、abstraction生成、Line再選定を0回に維持した。
