# B-v2 Profile表現比較

## 目的

Issue #42では、EntryとLineを同じ検索空間へ置くための`abstraction + domain`表現を比較する。ここで決めるのは後続PoC用の暫定profile版であり、本番Provider、model、taxonomy、B-v2採否ではない。

## Phase 1: オフライン設計比較

外部APIを使わず、次の4案を責務・検証可能性・版管理の観点で比較した。

| 案 | 判断 | 理由 |
|---|---|---|
| 固定単一enum | Phase 2へ | 最小で安定性を測りやすく、domain filterの基準になる |
| `primary + secondary`固定enum | Phase 2へ | 主領域を保ちながら、analogical transferを損なわない補助情報を持てる |
| 自由記述domain | 見送り | 表記揺れがあり、検索・集計・版管理に不向き |
| 優先順位のない複数domain | 見送り | 主従がなく、重みやfilterの意味が曖昧になる |

taxonomyは両候補で共通の固定enumとする。`unknown`は判断材料不足、`other`は既存分類に収まらない場合に限定する。候補間の差をdomain表現だけに寄せるため、abstractionの長さ・禁止事項は揃えた。

## Phase 2: 実APIスモークの固定条件

実行前条件は`b-v2-profile-preflight-v1`へ固定した。対象はEntry 6件とLine 4件、候補2版、各3反復で通常60リクエストである。失敗リクエストは最大1 retry、retry込み最大120リクエスト、実使用50,000 token、500円をhard limitとする。

実行はOpenAI Responses API / `gpt-5.6-terra` / reasoning low / `store=false`へ固定する。入力はリポジトリ内の合成データだけであり、APIキー、認証ヘッダー、Provider生レスポンス、request IDを成果物へ保存しない。

初回実行では単一domain版30件の完了後、`primary + secondary`版のSchemaにある`uniqueItems`がProvider非対応で停止した。要件自体は変えず、重複禁止を既存のローカルcontract validationへ移した。実行済み30件・11,384 token・5.3757円は破棄せず、修正と残り30件の再開条件を`b-v2-profile-preflight-v1.1`へ実API再開前に固定した。

## 評価項目

- 初回Schema成功率とretry後の完了
- abstraction・primary domainの3反復安定性
- primary / secondaryの入替
- `unknown / other`率
- abstraction品質、domain妥当性、元文にない事実追加
- domain追加前の保存済みabstractionからの劣化
- latency、token、cost

## 実行結果

2候補を各30件、計60件取得した。Provider requestは、互換性エラー1件を含む61回、実使用26,006 token、推定12.1248円である。成功した60件はすべて初回Schema成功で、retry成功は0件だった。全成功件のp95は2,809.81msである。

| 指標 | 単一domain | primary + secondary |
|---|---:|---:|
| 成功出力 | 30 | 30 |
| 初回Schema成功率 | 100% | 100% |
| abstraction完全一致率（対象単位） | 10% | 10% |
| primary完全一致率（対象単位） | 90% | 80% |
| primary / secondary入替 | 0 | 2対象 |
| unknown / other | 0% | 0% |
| p95 | 2,389.56ms | 3,697.52ms |
| 推定費用 | 5.3757円 | 6.7491円 |

完全一致率が低いのは、同じ構造を異なる短文で表したケースが多いためであり、それだけで品質不良とはしない。Codex一次評価では60出力すべてのdomainを許容し、元文外の事実追加と重大なabstraction劣化はいずれも0件とした。一方、`E023`と`L102`はprimary / secondaryの順序が反復内で入れ替わり、主従判断をlow confidenceとして残した。

## #43へ渡す暫定決定

`b-v2-profile-primary-secondary-v1`を#43用の暫定profileとする。primaryが10対象中8対象で一致し、補助領域をselectorのdomain diversityへ渡せるためである。この判断は本番Provider、model、taxonomyの正式採用ではない。`E023`と`L102`の人間判断によっては単一domain方式へ戻す余地があるが、後続PoCは停止しない。

全60件の正規化出力は`b_v2_profile_smoke_outputs_v1.jsonl`、集計と一次判断は`b_v2_profile_smoke_v1.yml`に保存した。固定済みGate A、Lineプール、既存abstraction成果物は変更していない。
