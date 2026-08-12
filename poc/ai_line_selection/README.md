# AI Line Selection PoC

RailsやReact Nativeへ依存せず、obserbingの一行選定フローを比較検証するRuby CLIです。

Issue #6ではMeaning Structure抽出に限り、OpenAIとAnthropicの実API比較を追加しています。SAFETY、Embedding、Line評価は引き続きFixture Adapterであり、外部APIを呼びません。Providerやモデルの正式採用、本番プロンプト、本番閾値を決める実装ではありません。

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

設定ファイルの`external_api.enabled`は`false`のままです。実APIを呼べるのは`compare-meaning`へ`--allow-external-api`を明示したときだけで、通常の`run`、`evaluate`、`prepare`、テストからは呼べません。

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

## 生成物

実行結果は`results/meaning_<timestamp>_<suffix>/`へ作成され、Git管理されません。

| ファイル | 内容 |
|---|---|
| `summary.json` | Provider別の成功率、再試行、レイテンシ、Token、費用、3回一致率 |
| `provider_outputs.jsonl` | 合成入力に対する構造化出力と実行メタデータ |
| `telemetry.jsonl` | 本文・プロンプト・Meaning本文を含まない試行単位のメタデータ |
| `human_evaluation.csv` | Provider名を伏せた人間評価票 |
| `blind_mapping.csv` | Blind IDとProvider・モデルの対応表 |
| `manifest.json` | 実験条件、料金表、Prompt / Schemaハッシュ |

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

## テスト

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
