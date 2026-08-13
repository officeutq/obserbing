# AI Line Selection PoC

RailsやReact Nativeへ依存せず、obserbingの一行選定フローを比較検証するRuby CLIです。

Issue #6のMeaning Structure比較、Issue #7のEmbedding候補検索比較、Issue #8のLine候補評価比較、Issue #9のSAFETY判定比較に加え、Issue #10では個別PoCの採用候補を一つのフローで評価する統合CLIを追加しています。Providerやモデルの正式採用、本番プロンプト、本番閾値を決める実装ではありません。

Epic #27では、初回PoCを変更せず、日記とLineのEmbedding入力を`abstraction`だけにそろえてリアルタイムLine評価LLMを省略する実験候補`abstraction-only-v1`を追加比較します。事前条件と採用基準は[AI追加PoC計画](../../docs/AI_追加PoC計画.md)、機械可読な固定値は`config/additional_poc.yml`を参照してください。

## 必要環境

- Ruby 3.3以上（開発時：3.4.7）
- Bundler 4以上

```powershell
cd C:\dev\obserbing\poc\ai_line_selection
bundle install
```

## APIキー

実API比較には`OPENAI_API_KEY`と`ANTHROPIC_API_KEY`が必要です。

ローカルでは`.env.example`を`.env`へコピーして設定できます。`.env`はGit管理外です。OS環境変数に同名の値がある場合はOS側を優先し、`.env`で上書きしません。

`doctor`はキーの値を表示せず、Providerごとの`configured: true/false`だけを返します。

```powershell
bundle exec ruby bin\ai_line_selection doctor
```

設定ファイルの`external_api.enabled`は`false`のままです。実APIを呼べるのは各`compare-*`または`run-integrated --mode selected`へ`--allow-external-api`を明示したときだけで、通常の`run`、`evaluate`、`prepare`、料金計画、テストからは呼べません。

## オフライン実行

Fixture Adapterで代表ケースを最後まで実行します。Fixtureはオーケストレーション検証用であり、AI品質の評価結果ではありません。

```powershell
bundle exec ruby bin\ai_line_selection run --entry-id E001
bundle exec ruby bin\ai_line_selection evaluate --repetitions 1
```

Provider非依存の送信要求を準備し、入力を伏せた要約だけを表示します。ネットワーク通信は行いません。

```powershell
bundle exec ruby bin\ai_line_selection prepare --entry-id E001 --operation meaning
```

既存の外部接続直前境界も残しています。次はネットワーク通信前に意図的に停止し、終了コード`2`を返します。

```powershell
bundle exec ruby bin\ai_line_selection run --entry-id E001 --adapter pending_external
```

## SAFETY判定比較

合成12件（safety 5、normal 5、indeterminate 2）をOpenAI `gpt-5.6-terra`とAnthropic `claude-sonnet-5`で各3回比較します。モデルは分類、reason code、confidenceだけを返し、固定SAFETY応答本文はAIに生成させません。

まず通信なしでリクエスト数と費用上限を確認します。

```powershell
bundle exec ruby bin\ai_line_selection plan-safety --providers openai,anthropic --repetitions 3
```

Fixtureで分類後の分岐と集計を確認できます。これはモデル品質評価には使いません。

```powershell
bundle exec ruby bin\ai_line_selection compare-safety --providers fixture --repetitions 3
```

実API比較は費用条件の確認と明示指示後だけ実行します。

```powershell
bundle exec ruby bin\ai_line_selection compare-safety `
  --providers openai,anthropic `
  --repetitions 3 `
  --allow-external-api
```

`safety`はサーバー管理の`SAFETY_COPY_TBD`へ分岐し、それ以降のAI処理を止めます。`indeterminate`、不正JSON、timeout、API失敗も通常フローへ流さず停止します。詳細は[SAFETY判定 PoC比較](../../docs/SAFETY_PoC比較.md)を参照してください。

2026年8月12日の実API比較では、両Providerともsafety再現率100%、normal正分類率100%、想定外のnormal通過0件でした。OpenAI `gpt-5.6-terra`は3分類すべて36 / 36件正解、Anthropic `claude-sonnet-5`は曖昧2ケースを各3回とも安全側の`safety`へ分類して30 / 36件正解でした。速度と費用も含め、SAFETY用途のPoC採用候補はOpenAIとします。本番正式採用には境界ケースを増やした追加評価が必要です。

### SAFETY追加境界比較

Epic #27では、危害を示唆する材料がない曖昧・短文・文学的表現を`normal`とし、危害材料はあるが具体性や切迫性が不足する場合だけ`indeterminate`とする境界を比較します。初回Promptは変更せず、既存36日記・初回12 SAFETY・追加24件の計72件を使います。実API比較の採用候補は`additional-v3`です。

```powershell
bundle exec ruby bin\ai_line_selection plan-safety-boundary `
  --boundary additional-v3 `
  --dataset candidate-full `
  --providers openai `
  --repetitions 3

bundle exec ruby bin\ai_line_selection compare-safety-boundary `
  --boundary additional-v3 `
  --dataset candidate-full `
  --providers openai `
  --repetitions 3 `
  --allow-external-api
```

`candidate-full`は既存36日記、初回12 SAFETY、追加24境界ケースの計72件です。`additional`は追加24件だけを比較します。2026年8月13日の実API比較では、`additional-v3`が72件×3回の216実行を全件正しく分類し、SAFETY見逃し、通常投稿の過剰遮断、曖昧ケースのnormal通過をすべて0件にしました。実行条件と採用基準は[AI追加PoC計画](../../docs/AI_追加PoC計画.md)、結果は[SAFETY追加PoC比較](../../docs/SAFETY_追加PoC比較.md)を参照してください。

## Abstraction-only表現比較

既存日記36件とLine 120件へ同じPrompt・Schemaを適用し、themes / structureを含まない短い`abstraction`だけを各3回生成します。意味類似度Embeddingは言い換えを確認対象へ振り分ける診断に限定し、意味的同等性は実表現をBlindレビューします。

```powershell
bundle exec ruby bin\ai_line_selection plan-abstraction `
  --version abstraction-only-v2 `
  --provider openai `
  --embedding-provider openai-small `
  --repetitions 3

bundle exec ruby bin\ai_line_selection compare-abstraction `
  --version abstraction-only-v2 `
  --provider openai `
  --embedding-provider openai-small `
  --repetitions 3 `
  --allow-external-api
```

2026年8月13日の実API比較では、468生成がすべて初回Schema成功し、Codex一次評価の利用可能率と3反復の意味的同等率はいずれも100%、新事実・診断・感情固定・不要な固有名詞は0件でした。採用候補`abstraction-only-v2`のEntry 36件・Line 120件は`data/abstractions/abstraction_only_v2.yml`へ版付きで保存しています。詳細は[Abstraction追加PoC比較](../../docs/Abstraction_追加PoC比較.md)を参照してください。

## Abstraction Embedding追加比較

Issue #22では、Meaning Structure baseline、`abstraction-only-v2`のLine代表1表現、Line 3表現のベクトル重心を同じEmbedding条件で比較します。3反復入力は`data/abstractions/abstraction_only_v2_repetitions.yml`に保存され、本文、request ID、token情報を含みません。

通信なしで計画を確認します。

```powershell
bundle exec ruby bin\ai_line_selection plan-abstraction-embedding `
  --provider openai-small
```

実Embedding比較を実行します。

```powershell
bundle exec ruby bin\ai_line_selection compare-abstraction-embedding `
  --provider openai-small `
  --allow-external-api
```

方式名・Theme・類似度を伏せたTop 5候補をCodex一次評価します。

```powershell
bundle exec ruby bin\ai_line_selection plan-candidate-quality `
  --provider openai `
  --results results\abstraction_embedding_<timestamp>_<suffix>

bundle exec ruby bin\ai_line_selection evaluate-candidate-quality `
  --provider openai `
  --results results\abstraction_embedding_<timestamp>_<suffix> `
  --allow-external-api
```

評価はEntry単位で保存されます。timeoutやRate Limitで停止した場合、同じコマンドは完了済みEntryと費用を読み取り、未完了Entryだけを再開します。実測結果と判断は[Abstraction Embedding追加PoC比較](../../docs/Abstraction_Embedding_追加PoC比較.md)を参照してください。

## Meaning実API比較

比較条件は次で固定しています。

| Provider | API / モデル | 構造化出力 | 推論設定 |
|---|---|---|---|
| OpenAI | Responses API / `gpt-5.6-terra` | `text.format`のJSON Schema | `reasoning.effort=low` |
| Anthropic | Messages API / `claude-sonnet-5` | `output_config.format`のJSON Schema | `output_config.effort=low` |

- 合成日記：同じ36件
- 繰り返し：各3回
- プロンプト：`prompts/meaning.md`
- Schema：`schemas/meaning.json`
- 最大出力：両Providerとも1,024 token
- Tools、Web検索、ファイル入力：なし
- 再試行：構造化出力不正または一時障害に限り最大1回。認証エラーは再試行しない
- 基本リクエスト上限：1コマンド216件（36件 × 3回 × 2 Provider）。再試行は別カウント
- 総予算上限：5,000円

有料APIを使うため、まずProviderごとに同じ1件をスモークテストします。

```powershell
bundle exec ruby bin\ai_line_selection compare-meaning --providers openai --repetitions 1 --entry-id E001 --allow-external-api
bundle exec ruby bin\ai_line_selection compare-meaning --providers anthropic --repetitions 1 --entry-id E001 --allow-external-api
```

両方が正常だった場合だけ、全比較を実行します。

```powershell
bundle exec ruby bin\ai_line_selection compare-meaning --providers openai,anthropic --repetitions 3 --allow-external-api
```

比較は、認証エラー、再試行後のRate Limit・5xx・タイムアウト、重大なSchema不正、モデル不一致、出力量または費用の異常、予算超過のいずれかで停止します。

### タイムアウト

Fixture処理の従来値3秒は変更していません。実ProviderのMeaning比較だけ、両社共通で30秒へ固定しました。構造化出力Schemaの初回処理やlow effortの推論を含む外部通信を3秒で打ち切ると、モデル品質ではなくネットワーク待ち時間を比較する可能性が高いためです。比較結果にはp50、p95、最大値を残し、この値の見直し材料にします。

### 料金

利用量はAPIレスポンスのInput / Output Tokenを使い、`config/poc.yml`に固定した料金表と150円/USDのPoC換算値でUSD・JPYを推定します。料金表の確認日は2026-08-12です。実行前に必ず各Providerの公式料金を再確認してください。

## Embedding候補検索比較

原文、Meaning Structure、正規化テキストを、候補件数20・50・100で比較します。固定Meaning正解を使うため、Issue #6のMeaning Provider差は混ざりません。Candidate 12件とRetired 12件はEmbedding生成前に除外し、Approved 96件だけを検索します。

まず外部通信なしで料金計画を確認します。

```powershell
bundle exec ruby bin\ai_line_selection plan-embedding --providers openai-small,openai-large
```

Fixtureによる全件比較も外部通信を行いません。Fixtureは配線と再現性の確認専用で、本番品質の判定には使いません。

```powershell
bundle exec ruby bin\ai_line_selection compare-embedding --providers fixture
```

実API比較は明示承認後だけ実行します。

```powershell
bundle exec ruby bin\ai_line_selection compare-embedding `
  --providers openai-small,openai-large `
  --allow-external-api
```

比較結果にはRecall@20 / 50 / 100、期待候補順位、Top 1 Theme不一致、Candidate / Retired混入、API時間、検索時間、利用token、費用、次元数、`pgvector`保存量を記録します。条件と採用基準は[Embedding候補検索 PoC比較](../../docs/Embedding_PoC比較.md)を参照してください。

2026年8月12日の実API比較では、`text-embedding-3-small`・1,536次元・Meaning Structure入力をPoC採用候補としました。Recall@20は95.14%、Recall@50は98.96%、Candidate / Retired混入は0件です。候補取得件数は50件、後段のLLM投入上限は20件を維持します。本番正式採用は統合PoCと`pgvector`性能試験後に判断します。

## Line候補評価比較

Issue #7で採用したEmbedding条件から同じ上位20候補を作り、OpenAI `gpt-5.6-terra`とAnthropic `claude-sonnet-5`へrelevance、directness、space、obserbing_fitの4軸評価を依頼します。合成データの`directness`等の正解用メタデータはLLMへ送りません。

まず通信なしでリクエスト数と費用上限を確認します。

```powershell
bundle exec ruby bin\ai_line_selection plan-line-evaluation `
  --providers openai,anthropic `
  --embedding-provider openai-small `
  --repetitions 3
```

Fixtureによる全配線確認も外部通信を行いません。

```powershell
bundle exec ruby bin\ai_line_selection compare-line-evaluation `
  --providers fixture `
  --embedding-provider fixture `
  --repetitions 1
```

実API比較は利用者が費用条件を確認した後、明示フラグ付きで実行します。

```powershell
bundle exec ruby bin\ai_line_selection compare-line-evaluation `
  --providers openai,anthropic `
  --embedding-provider openai-small `
  --repetitions 3 `
  --allow-external-api
```

結果にはAI自身の推奨とRubyのbalanced最終選択を分けて保存します。permissive・balanced・conservativeの閾値感度、SILENCE、3回の最終選択一致率も集計します。候補欠落・重複・候補外ID・数値範囲外などの技術エラーはSILENCEへ変換せず停止します。

人の確認は全反復を対象にしません。各Providerの第1反復をCodexがBlind一次評価し、`judge=codex_preliminary`、確信度、理由をCSVへ記録します。低確信行だけを次のコマンドで対話確認し、人の判定は`judge=human`として分離します。

```powershell
bundle exec ruby bin\ai_line_selection review-line-evaluation `
  --results results\line_evaluation_<timestamp>_<suffix>
```

詳細は[Line候補評価 PoC比較](../../docs/Line評価_PoC比較.md)を参照してください。

2026年8月12日の実API比較では、`claude-sonnet-5`をLine評価のPoC採用候補としました。Blind評価は許容36 / 36件、致命的違反0件、3回の最終選択一致率94.44%でした。`gpt-5.6-terra`は許容35 / 36件、致命的違反1件、最終選択一致率47.22%で採用基準未達でした。両モデルともLine評価だけでp95が6秒を超えたため、本番正式採用、同期処理設計、閾値、重みは未確定です。

## 統合PoC

個別PoCの採用候補を`SAFETY → Meaning → Embedding → 上位50件検索 → 上位20件Line評価 → Ruby最終選定`の順で接続します。通常36件を各3回、独立SAFETY 12件を各3回実行します。

まず通信なしで基本469リクエスト、各処理1回再試行時の最大938リクエスト、費用上限を確認します。

```powershell
bundle exec ruby bin\ai_line_selection plan-integrated
```

Fixtureによる全件リハーサルは外部通信を行いません。検索品質の判断には使いません。

```powershell
bundle exec ruby bin\ai_line_selection run-integrated `
  --mode fixture `
  --repetitions 3 `
  --safety-repetitions 3
```

実APIは利用者の明示承認後だけ実行します。

```powershell
bundle exec ruby bin\ai_line_selection run-integrated `
  --mode selected `
  --repetitions 3 `
  --safety-repetitions 3 `
  --allow-external-api
```

外部障害や不正出力は技術エラーとして停止し、意味上のSILENCEへ変換しません。実行条件、採用基準、人間評価手順は[統合PoC比較](../../docs/統合_PoC比較.md)を参照してください。

2026年8月13日の実API評価では、独立SAFETY再現率100%、Recall@50 95.60%、Blind許容率96.88%、1投稿あたり2.2756円を達成しました。一方、通常日記4 / 36件のSAFETY過剰遮断、Recall@20 79.46%、最終選択一致率72.22%、全体p95 15.09秒、致命的なLine誤選定1件により、`selected-v1`の現状採用は見送ります。詳細は[統合PoC比較](../../docs/統合_PoC比較.md)、全体の採用判断と追加検証項目は[AI一行選定 PoC結果](../../docs/AI_PoC結果.md)に記録しています。

## 生成物

実行結果は`results/<operation>_<timestamp>_<suffix>/`へ作成され、Git管理されません。

| ファイル | 内容 |
|---|---|
| `summary.json` | Provider別の成功率、再試行、レイテンシ、Token、費用、3回一致率 |
| `provider_outputs.jsonl` | 合成入力に対する構造化出力と実行メタデータ |
| `telemetry.jsonl` | 本文・プロンプト・Meaning本文を含まない試行単位のメタデータ |
| `human_evaluation.csv` | Provider名を伏せた人間評価票 |
| `blind_mapping.csv` | Blind IDとProvider・モデルの対応表 |
| `manifest.json` | 実験条件、料金表、Prompt / Schemaハッシュ |

Line比較の`results/line_evaluation_<timestamp>_<suffix>/`には、固定候補の`candidate_sets.jsonl`、AIとRuby選択を分離した`provider_outputs.jsonl`、低確信確認用`human_evaluation.csv`、Provider対応を隔離した`blind_mapping.csv`も保存します。

SAFETY比較の`provider_outputs.jsonl`にはケースID、期待・実判定、分岐、計測値だけを保存し、合成本文も含めません。`stopped.json`は不正JSONや外部障害を通常フローへ通さなかったことを記録します。

人間評価票では、検索利用可能性（3段階）、診断、根拠のない感情・人物像の固定、不要な固有名詞を評価します。CLIは定量結果だけを集計し、人間評価前に勝者を決めません。

### 対話型Blind評価

216行のCSVを直接編集する代わりに、36件の日記ごとに2 Providerの代表出力をA/B表示して評価できます。各Providerの第1反復だけを人間評価し、残りの反復は自動計算済みの再現性評価に使います。

```powershell
bundle exec ruby bin\ai_line_selection review-meaning `
  --results results\meaning_20260812T065638Z_5ac4
```

各画面ではA/Bそれぞれの利用可能性を1〜3で入力します。問題がなければ問題選択でEnterを押すだけです。問題がある場合だけ、対象を`a`、`b`、`both`から選び、次の記号で種類を入力します。

- `d`：診断の混入
- `f`：根拠のない感情・人物像の固定
- `p`：不要な固有名詞

複数ある場合は`d,p`のように入力します。入力時に`/q`を指定すると、そこまでの評価を保存して終了します。再び同じコマンドを実行すると未評価の日記から再開します。

評価中はProvider名を表示しません。全36件の完了後だけProvider対応を開示し、次を`interactive_human_evaluation_summary.json`へ自動集計します。

- Provider別の利用可能性平均・分布・2以上の割合
- 診断、感情・人物像固定、固有名詞の件数
- 事前目標の達成状況
- A/Bで利用可能性が高かった回数と同点数

回答は`interactive_human_evaluation.csv`へ1件ごとに保存されます。どちらも`results/`配下のためGit管理されません。集計は勝者を自動決定せず、定量性能と合わせて人が採用判断します。

Codex等による事前評価を使う場合は、評価行へ`judge`、`confidence`、`reason`、`human_reviewed`を保存します。高確信の行は対話画面でスキップでき、低確信の行だけを人が評価できます。最終集計はProvider別の結果と併せて、Codex判定数と人間確認数も分離して表示し、AI判定を人間評価として扱いません。

## テスト

### 事実整合ガード追加PoC

元の日記・Lineを変更せず、数量・人物・物・出来事・場所/時刻・強い因果の不整合を、影版・事前属性・静的検出・組み合わせで比較します。外部APIは呼びません。

```powershell
bundle exec ruby bin\ai_line_selection plan-grounding-guard
bundle exec ruby bin\ai_line_selection compare-grounding-guard
```

結果と採用判断は [Line事実整合ガード 追加PoC比較](../../docs/Line事実整合ガード_追加PoC比較.md) を参照してください。

### LLMなしLine選択追加PoC

Issue #22の固定Top 5とIssue #23の事実整合ガードを使い、Top 1、一様乱択、類似度重み付き乱択、閾値集合を固定seedで比較します。Line評価LLMと外部APIは呼びません。

```powershell
bundle exec ruby bin\ai_line_selection plan-ruby-selection
bundle exec ruby bin\ai_line_selection compare-ruby-selection
```

結果と採用判断は [LLMなしLine選択 追加PoC比較](../../docs/LLMなしLine選択_追加PoC比較.md) を参照してください。

### Abstraction Only統合追加PoC

候補コンポーネントを診断チェーンとして接続し、Fixture、実API、既存実API出力の再現可能なリプレイを分離して実行します。実APIモードはSAFETY、abstraction、Entry Embeddingだけを投稿時に呼び、Line評価LLMは呼びません。

```powershell
bundle exec ruby bin\ai_line_selection plan-abstraction-only-integrated --mode diagnostic --repetitions 3
bundle exec ruby bin\ai_line_selection run-abstraction-only-integrated --mode fixture --repetitions 3
```

結果と不採用判断は [Abstraction Only 統合PoC比較](../../docs/Abstraction_Only_統合PoC比較.md) を参照してください。

```powershell
bundle exec rake test
```

テストはFake Transportだけを使い、外部APIを呼びません。タイムアウト、429、5xx、認証エラー、JSON不正、必須項目欠落、型違反、再試行成功、再試行失敗をオフラインで確認します。

## 秘密情報とログ

- `.env`、`tmp/`、`results/`、`vendor/bundle/`はGit対象外です。
- 通常ログへ日記本文、Meaning全文、プロンプト本文、AIレスポンス本文を出しません。
- ログに残すのはProvider、モデル、Request ID、Token、レイテンシ、推定費用、試行回数、正規化エラーだけです。
- APIキーやAuthorization Headerはログ、生成物、CLI出力へ出しません。
- `provider_outputs.jsonl`と人間評価票は合成データだけを扱い、通常ログから分離します。

上位の実験条件と採用基準は[AI PoC計画](../../docs/AI_PoC計画.md)を参照してください。
