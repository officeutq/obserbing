# AI追加PoC計画

**文書ステータス：実験前計画**

**作成日：2026年8月13日**

**関連Epic：#27**

**関連Issue：#19〜#26**

## 1. 目的

初回AI PoCで本番採用を見送った`selected-v1`を変更せず、別候補`abstraction-only-v1`がobserbingの一行選定として成立するかを再現可能に比較する。

本書は、追加PoCの実装、実API実行および結果閲覧より前に、比較方式、固定データ、評価方法、採用基準、停止条件、乱数、費用上限を固定する。実験結果に合わせて本書の基準を変更しない。やむを得ず変更する場合は、変更前の結果を無効化し、計画版を更新してから全条件を再実行する。

## 2. 背景

初回PoC `selected-v1`は、独立SAFETY再現率100%、Recall@50 95.60%、Blind許容率96.88%、1投稿あたり推定費用2.2756円を達成した。一方、次の事前基準が未達だったため本番採用を見送った。

- 通常日記4 / 36件、10 / 108回のSAFETY過剰遮断
- Recall@20 79.46%
- 3回の最終選択一致率72.22%
- 通常フローp95 15.09秒
- 日記にない数量を具体化した致命的なLine誤選定1件

初回PoCの条件と結果は次を正とし、本追加PoCから書き換えない。

- [AI一行選定 PoC計画](AI_PoC計画.md)
- [AI一行選定 PoC結果](AI_PoC結果.md)
- [Embedding候補検索 PoC比較](Embedding_PoC比較.md)
- [Line候補評価 PoC比較](Line評価_PoC比較.md)
- [SAFETY判定 PoC比較](SAFETY_PoC比較.md)
- [SAFETY追加PoC比較](SAFETY_追加PoC比較.md)
- [Abstraction追加PoC比較](Abstraction_追加PoC比較.md)
- [統合PoC比較](統合_PoC比較.md)

## 3. 検証仮説

obserbingの目的は、日記に最も正確に一致する唯一のLineを当てることではない。次を満たすLineを一つ置き、投稿者自身が意味を考えられる余地を残すことである。

- 日記と完全に無関係ではない
- 日記を直接言い換えない
- 助言、診断、励まし、称賛をしない
- 少し距離がある
- 日記にない具体的事実を持ち込まない

日記とLineのEmbedding入力を同程度の`abstraction`だけにそろえ、Approved、再利用、直近利用、禁止属性、事実整合をRubyで制御すれば、リアルタイムLine評価LLMを省略しても、許容できる候補集合からLineまたはSILENCEを決定できると仮定する。

新方式は実験候補`abstraction-only-v1`と呼ぶ。`selected-v2`のような採用済みと読める名称は使わない。

## 4. 比較するアーキテクチャ

### 4.1 baseline `selected-v1`

```text
SAFETY
→ themes / structure / abstractionを含むMeaning Structure
→ Meaning Structure Embedding
→ Approved Line上位50件
→ 上位20件をClaudeで4軸評価
→ Ruby最終選定
→ Line / SILENCE
```

baselineの品質・性能・費用は、2026年8月13日に完了した初回統合PoCの公表済み結果を使用する。追加PoCのために既存コード、設定、データ、結果を変更しない。比較上どうしても再実行が必要な場合だけ、別の結果ディレクトリへ保存する。

### 4.2 新候補 `abstraction-only-v1`

```text
SAFETY
→ 日記のabstractionのみ生成
→ 日記abstractionをEmbedding
→ 事前生成済みLine abstraction Embeddingと類似検索
→ Approved・再利用・直近利用・禁止属性・事実整合で除外
→ 候補群からRubyで選択
→ Line / SILENCE
```

通常投稿の外部AI APIは、SAFETY、日記abstraction、Entry Embeddingの3処理を基本とする。Line abstractionとLine Embeddingは事前生成し、投稿ごとのレイテンシから分離する。リアルタイムLine評価LLMは呼び出さない。

## 5. スコープ

- 追加PoCの事前基準と再現条件の固定
- SAFETY分類境界の追加検証
- 日記とLineの対称なabstraction-only表現生成
- abstraction-only Embedding候補集合の比較
- リアルタイムLLMを使わない事実整合ガード
- Top 1、一様乱択、類似度重み付き乱択、閾値集合選択の比較
- `abstraction-only-v1`の統合評価
- baselineとのBlind品質、安全性、安定性、性能、費用比較

## 6. スコープ外

- Rails / React Nativeへの本番組み込み
- DB migration
- `pgvector`の大規模性能評価
- 不足領域分析とCandidate生成を行うバッチLLM PoC
- 本番Provider、モデル、契約、Prompt、Schema、閾値の正式採用
- 初回PoC結果、既存データ、`selected-v1`の改変・削除
- 実ユーザーの日記利用
- AIによるLine本文の自由生成と自動Approved化

## 7. 固定データと版管理

### 7.1 初回比較母集団

初回PoCと直接比較する母集団を次で固定する。

| データ | 固定条件 |
|---|---|
| 日記 | `data/entries.yml`の既存36件 |
| Line | `data/lines.yml`の既存120件 |
| 検索対象 | Approved 96件 |
| 検索対象外 | Candidate 12件、Retired 12件 |
| 独立SAFETY | `data/safety_cases.yml`の既存12件 |
| 反復 | 同じ日記を3回 |

Issue #19の実装時に、上記ファイルのSHA-256、件数、全IDを計画成果物へ記録する。後続Issueはこの値を照合してから実行する。

固定値は`poc/ai_line_selection/config/additional_poc.yml`に保存し、自動テストで照合する。2026年8月13日時点のSHA-256は次のとおりである。

| データ | SHA-256 |
|---|---|
| `entries.yml` | `8ca60da809022778f2f1474f2c20525748b1da7f90fec52d565a0ef58cd8e181` |
| `lines.yml` | `c2c4814d0f159daf989a21e17413b008a822533ee5c843fbda00d658cfff4232` |
| `safety_cases.yml` | `dc2c15e3dcbb031c5e36187a660d2baccd49807605ef62691c017e2920b85556` |

IDはEntry `E001`〜`E036`、Line `L001`〜`L120`、SAFETY `S001`〜`S012`を重複なしで固定する。

### 7.2 追加診断データ

次は既存データを変更せず、`additional-v1`として別ファイル・別集計にする。

- 短文、文学的表現、否定、引用、過去、第三者言及を含むSAFETY境界ケース
- Themeは違うが抽象的には関連するLine
- 少しずれているが考えるきっかけになるLine
- 数量、人物、物、出来事、因果を含む事実不整合ペア
- 完全に無関係なLine
- 適切な候補がなくSILENCEになるべきケース

追加診断データの結果を初回36件の平均へ混ぜない。

### 7.3 バージョン

最低限、次の版をmanifestへ記録する。

- Entry / Line / SAFETYデータのSHA-256
- abstraction Schema / Prompt / 正規化版
- Embeddingモデル / 次元数 / 入力生成版
- SAFETY Schema / Prompt / 境界定義版
- 事実整合属性 / Rubyルール版
- 候補取得件数 / 類似度閾値 / 選択方式 / seed
- Provider / モデル / 推論設定 / 料金表確認日

## 8. 比較条件

### 8.1 Providerとモデル

アーキテクチャ差を先に測るため、初回PoCの個別候補を出発点にする。

| 処理 | 初期比較条件 | 位置づけ |
|---|---|---|
| SAFETY | OpenAI `gpt-5.6-terra`、low | 境界定義差を先に比較するPoC候補 |
| abstraction | OpenAI `gpt-5.6-terra`、low | Entry / Lineの対称Promptを比較するPoC候補 |
| Embedding | OpenAI `text-embedding-3-small`、1,536次元 | Meaning Structure入力との差を分離するPoC候補 |
| Line選択 | Ruby | リアルタイムLine評価LLMを使用しない |

これは本番採用ではない。2026年8月13日に確認した公式料金は、`gpt-5.6-terra`が入力$2.00、cached input $0.20、出力$12.00 / 100万token、`text-embedding-3-small`が入力$0.02 / 100万tokenである。実行直前にも公式料金を再確認し、料金表版を成果物へ記録する。

- [OpenAI GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [OpenAI text-embedding-3-small](https://developers.openai.com/api/docs/models/text-embedding-3-small)

### 8.2 abstraction

- EntryとLineで同じ抽象化規則を使用する
- 出力は1つの短い`abstraction`と版情報だけにする
- themes / structureをEmbedding入力へ含めない
- 原文の数量、人物、物、出来事、因果を不要に複製しない
- 原文にない事実、診断、感情・人物像、固有名詞を追加しない
- Line側は事前生成、Entry側はリアルタイム生成として時間を分ける

### 8.3 Embedding候補集合

入力表現差を分離するため、最初に同じモデル・次元数・cosine類似度で比較する。

- baseline入力：themes / structure / abstractionを含むMeaning Structure
- 新候補入力：abstractionのみ
- Top N：1、5、10、20、50
- 絶対類似度閾値：0.35、0.45、0.55
- 検索対象：Approved 96件だけ
- Candidate / RetiredはEmbedding生成前と検索条件の両方で除外する

絶対閾値で候補が空になる場合はSILENCE候補として記録し、都合よくTop 1へフォールバックしない。閾値の適否は最終Line品質、候補集合品質、SILENCE率で判断する。

### 8.4 Ruby選択方式

事実整合と業務ルール適用後の同一候補集合に対し、次を比較する。

1. `top1`：類似度最上位を選ぶ
2. `uniform_top_n`：上位5件から一様乱択する
3. `similarity_weighted_top_n`：上位5件から類似度を重みにして乱択する
4. `threshold_uniform`：選定した絶対閾値以上、最大20件から一様乱択する

重みは負値を避けるため、候補集合内の最小類似度を引いた値に`0.01`を加えて正規化する。同点はLine ID昇順で安定化する。

### 8.5 random seed

乱択は次の固定seedセットを使用する。

```text
2719001
2719002
2719003
```

各選択の実seedは、`SHA-256(base_seed | entry_id | strategy_id | repetition)`の先頭64 bitから生成する。同じデータ、設定、base seedでは同じ結果を返す。seedの追加・差し替えは結果閲覧後に行わない。

### 8.6 再利用・直近利用

履歴なしに加え、次の固定シナリオを用意する。

- Top 1 Lineが同一ユーザーへ直近表示済み
- Top 5のうち複数Lineが直近表示済み
- 同一Meaning Cluster相当が直近利用条件へ抵触
- 全候補が再利用・禁止条件で除外される

禁止条件違反を避けるために候補外Lineを追加検索せず、候補がなくなった場合はSILENCEとする。

## 9. SAFETY境界

候補境界を次で固定し、Issue #20で初回境界と比較する。

- `safety`：現在または近い時間に、危害の意思、計画、準備、対象、実行状況のいずれかが具体的に読み取れる
- `indeterminate`：危害を示唆する材料が存在するが、対象、現在性、具体性、切迫性の不足により`safety`か`normal`か確定できない
- `normal`：つらさ、曖昧さ、短さ、比喩だけで、危害を示唆する材料自体がない。否定、引用、過去、第三者言及は文脈を評価する

「文章が曖昧」という理由だけで`indeterminate`にしない。`safety`、`indeterminate`、不正JSON、timeout、API失敗は通常フローへ通さない。本番SAFETY仕様と固定応答文は本PoCで確定しない。

## 10. 事実整合ガード

意味的に少し遠いLineは許容するが、日記にない具体的事実の導入は許容しない。Issue #23で次を単独・組み合わせ比較する。

- Line本文を汎用化した影版。既存Lineは変更しない
- 数量、具体人物、特定物、特定出来事、場所・時刻、強い因果の事前属性
- 文字・構造から決定的に抽出できる具体性フラグ
- Entry側の対応フラグとのRuby互換判定

E033 / L102とE024 / L077を必須回帰ペアとする。一方、E032 / L102のように日記側に対応する数量がある適合ケースを誤除外しない。

## 11. 人間Blind評価

### 11.1 評価単位

- 各方式の第1反復を主Blind評価対象にする
- 方式名、Provider、モデル、類似度、選択順位を隠す
- 同じEntryに対するbaselineと新候補は、評価順を固定seedで入れ替える
- SAFETY、SILENCE、技術エラーも結果として残し、Lineだけの母数へ隠さない

### 11.2 評価項目

- 距離：`too_close / just_right / too_far / not_obserbing`
- 許容可否
- 明らかに無関係か
- 致命的な事実不整合があるか
- 助言、診断、励まし、称賛、人物像固定などの致命的違反があるか
- 確信度と理由

Codex一次評価は`judge=codex_preliminary`として人間評価と分離する。低確信、方式間で判断が割れるケース、致命的違反候補だけを人が対話確認し、`judge=human`として残す。

## 12. 事前採用基準

### 12.1 最終品質

| 指標 | 基準 |
|---|---:|
| 表示LineのBlind許容率 | 90%以上 |
| baselineに対する許容率の非劣性幅 | -7 percentage points以内 |
| 致命的な事実不整合 | 0件 |
| その他の致命的なプロダクト違反 | 0件 |
| 明らかに無関係なLine | 表示Lineの5%以下 |
| `not_obserbing` | 表示Lineの10%以下 |
| 既存36件のSILENCE率 | 25%以下 |

許容率は表示Lineを分母とするが、全36件のLine / SILENCE / SAFETY / 技術エラー内訳を併記して母数の偏りを隠さない。SILENCEで品質問題を隠す方式は採用しない。

### 12.2 SAFETY

| 指標 | 基準 |
|---|---:|
| safety再現率 | 100% |
| safety / indeterminateの通常フロー通過 | 0件 |
| 既存通常36件の過剰遮断 | 0件 |
| 危害材料のない追加normalケースの`indeterminate` | 0件 |
| 追加normalケースの正分類率 | 95%以上 |
| 3回の分類一致率 | 95%以上 |

SAFETY見逃しが1件でもあれば、その候補境界の統合評価を停止する。

### 12.3 abstraction

| 指標 | 基準 |
|---|---:|
| 初回Schema成功率 | 99%以上 |
| 1回再試行後Schema成功率 | 100% |
| 原文にない具体的事実の追加 | 0件 |
| 診断・感情や人物像の固定・不要な固有名詞 | 各0件 |
| Blind利用可能率 | 90%以上 |
| 3回の意味的同等率 | 85%以上 |

文字列完全一致は診断指標とし、言い換えでも同じ抽象関係なら不一致扱いしない。

### 12.4 候補集合とRuby制御

| 指標 | 基準 |
|---|---:|
| 1件以上の許容候補を含むEntry | 95%以上 |
| Candidate / Retired混入 | 0件 |
| 固定abstractionからの検索決定性 | 100% |
| 反復abstractionによるTop 20 Jaccard平均 | 0.80以上 |
| 同一seedの最終選択再現率 | 100% |
| status・再利用・直近利用・禁止属性違反 | 各0件 |

Recall@N、MRR、Theme一致は診断指標とし、期待Theme不一致だけで候補を不正解にしない。

### 12.5 性能・費用

| 指標 | 基準 |
|---|---:|
| 通常フロー全体p95 | 6秒以内 |
| リアルタイムLine評価LLM | 0回 |
| 外部AI API基本回数 | 1投稿あたり3回以下 |
| 1投稿あたり推定AI費用 | 5円以下、かつbaseline比30%以上削減 |
| Epic #27の追加実API総費用 | 5,000円以内 |

平均値だけでなくp50、p95、最大値、timeout、再試行、Rate Limitを処理別に記録する。

## 13. baselineとの比較方法

### 13.1 集計母数

1. **End-to-End母数**：既存36件すべて。Line、SILENCE、SAFETY、技術エラーを比較する。
2. **表示Line母数**：実際にLineが表示されたケース。Blind品質を比較する。
3. **共通到達母数**：両方式がLine選択段階へ到達した同じEntry。ペア差を確認する。
4. **追加診断母数**：新規境界ケース。baselineとの主非劣性判定へ混ぜない。

### 13.2 判断順

1. SAFETY見逃しと致命的事実不整合の必須条件を確認する。
2. Blind許容率と非劣性を確認する。
3. 無関連、距離分布、SILENCE、利用可能性を確認する。
4. 安定性、レイテンシ、API回数、費用を比較する。
5. Recall@N、MRR、Theme一致で失敗原因を診断する。

### 13.3 最終判断

Issue #26で次のいずれかを選ぶ。

- `abstraction-only-v1`を詳細設計候補にする
- baseline方式を候補として維持する
- 両者の一部を組み合わせた追加PoCを行う
- どちらも見送る

方式候補の決定と、本番Provider・モデル・契約の正式採用を混同しない。

## 14. 実施順序と依存関係

```text
#19 計画・基準固定
 ├─ #20 SAFETY
 ├─ #21 abstraction生成 ─→ #22 Embedding検索 ─┐
 └─ #23 事実整合ガード ─────────────────────┤
                                               ↓
                                  #24 Ruby選択方式
                                               ↓
                                  #25 新方式の統合PoC
                                               ↓
                                  #26 baseline比較・判断
```

#20、#21、#23は#19完了後に独立して開始できる。#22は#21、#24は#22と#23、#25は#20〜#24、#26は#19と#25に依存する。

## 15. 外部APIと費用ゲート

外部APIを利用できるのは、次を満たす実行コマンドだけとする。

- Fixture / Fake Transportの自動テストが成功している
- 送信対象が合成データだけである
- Provider、モデル、料金表、リクエスト数、最大費用を通信なしで計画済みである
- APIキーをOS環境変数またはGit管理外の`.env`から読む
- `config/poc.yml`の`external_api.enabled=false`を維持する
- 実行コマンドに`--allow-external-api`を明示する
- 予算80%で警告し、100%で後続リクエストを停止する
- 日記、Prompt、AIレスポンス、APIキーを通常ログへ出力しない

利用者は2026年8月13日にEpic #27で必要な有料API実行を包括承認している。上記ゲートと5,000円上限内の実行について、個別の再確認は行わない。対象データ、Provider、目的、予算上限が本書から拡大する場合は、この承認の範囲外とする。

## 16. 成果物とログ

Git管理するもの:

- 計画、比較条件、集計結果、採否、失敗例を記載したMarkdown
- 合成データ、Schema、Prompt、設定、テスト
- 個別本文や秘密情報を含まない再現用manifestの例

Git管理しないもの:

- `.env`、APIキー、Authorization Header
- `results/`配下のProvider出力、Blind mapping、本文入り評価票
- 実ユーザーの日記またはそれに由来するデータ

通常ログへ記録できるのは、Entry ID、Line ID、処理種別、版、Provider、モデル、時間、token、費用、候補件数、正規化エラー、選択・除外理由コードである。

## 17. 停止条件

次のいずれかが発生した場合は、該当候補の外部API実行または統合実行を停止し、技術エラーとして記録する。

- SAFETY見逃し
- Candidate / Retiredの検索対象混入
- 候補外Line IDまたは禁止条件違反の採用
- APIキー、Authorization Header、日記本文の通常ログ出力
- 再試行後のSchema不正、timeout、Rate Limit、5xx
- 費用上限到達
- データ、Prompt、Schema、設定、seedのmanifest不一致

品質基準未達は技術エラーとして隠さず、方式見送りまたは追加PoCの判断材料として最後まで集計する。ただしSAFETY見逃しのある候補を通常統合フローへ進めない。

## 18. Epic完了時に判断すること

Epic #27の完了時点で、次を判断可能にする。

- abstraction-only表現が日記とLineの検索キーとして成立するか
- 高性能なリアルタイムLine評価LLMを省略できるか
- どのRuby候補選択方式が品質・多様性・再現性を両立するか
- 事実不整合を非LLMガードだけで0件にできるか
- SAFETY過剰遮断を見逃しなしで改善できるか
- baselineに対して品質を保ちながら速度・費用を改善できるか
- 詳細設計、ハイブリッド追加PoC、または全見送りのどれへ進むか

本番Provider、モデル、契約、Prompt、Schema、閾値はEpic完了時にも未確定でよい。
