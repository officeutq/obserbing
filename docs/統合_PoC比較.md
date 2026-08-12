# 統合PoC比較

**文書ステータス：外部API実行前**

**作成日：2026年8月12日**

**関連Issue：#10**

## 1. 目的

個別PoCで採用候補となったSAFETY、Meaning Structure、Embedding、Line評価を一つの処理へ接続し、同じ合成データで品質、安定性、速度、利用量、費用を計測する。本番採用を確定する試験ではなく、Railsへ組み込む前の統合判断材料を作る。

## 2. 統合する候補

| 処理 | PoC採用候補 | 採用理由 |
|---|---|---|
| SAFETY | OpenAI `gpt-5.6-terra` | safety再現率100%、normal正分類率100%、3分類36 / 36件正解 |
| Meaning Structure | OpenAI `gpt-5.6-terra` | 検索利用可能率100%、診断・人物像固定・不要な固有名詞0件、比較相手より高速・低費用 |
| Embedding | OpenAI `text-embedding-3-small`、1,536次元、Meaning Structure入力 | Recall@20 95.14%、Recall@50 98.96%、対象外Line混入0件 |
| Line評価 | Anthropic `claude-sonnet-5` | Blind評価の許容36 / 36件、致命的違反0件、最終選択一致率94.44% |

統合チェーン名は`selected-v1`とする。候補検索はApproved 96件だけを対象に上位50件を取得し、上位20件だけをLine評価へ渡す。CandidateとRetiredはEmbedding生成前に除外する。

## 3. 処理フロー

通常投稿は次の順で同期実行する。

1. OpenAIでSAFETYを分類する。
2. `safety`なら固定応答へ分岐し、後続処理を実行しない。
3. `indeterminate`、不正JSON、timeout、API障害なら技術エラーとして停止する。SILENCEへ変換しない。
4. `normal`ならOpenAIでMeaning Structureを抽出する。
5. Meaning StructureをOpenAIでEmbedding化する。
6. 事前生成したLine Embeddingから上位50件を検索し、上位20件をAnthropicで4軸評価する。
7. Rubyの`balanced`ポリシーが候補IDと数値を検証し、最終Lineまたは意味上のSILENCEを確定する。

Line 96件のEmbeddingは統合実行の先頭で1回だけ一括生成し、投稿ごとのレイテンシから分離する。

## 4. 固定条件とリクエスト数

- 合成日記：36件
- 通常フロー反復：各3回、計108回
- 独立SAFETYケース：12件を各3回、計36回
- 通常フローの外部API呼び出し：1投稿あたり4回
- Line Embedding一括生成：1回
- 基本リクエスト数：469回
- 各処理で最大1回再試行した場合の上限：938回
- 円換算：150円/USD
- 総予算上限：5,000円

2026年8月12日時点の料金表と、入力をUTF-8バイト数のままtoken相当として過大評価し、最大出力tokenまで使い切る安全側の計算では、全リクエストが1回ずつ再試行した場合の上限は**2,569.5535円**である。実行直前に公式料金を再確認し、利用者の明示承認後だけ`--allow-external-api`を付ける。

## 5. 評価項目

### 品質・安全性

- SAFETY再現率100%、normal正分類率90%以上
- SAFETYまたは判定不能ケースの通常フロー通過0件
- 全処理の初回Schema成功率99%以上、再試行後100%
- Recall@20 85%以上、Recall@50 95%以上
- Candidate / Retired混入、候補外ID、重複ID、範囲外スコア受理が各0件
- 同じ日記3回の最終選択一致率80%以上
- Blind評価の「ちょうどいい」または「許容」80%以上、致命的違反0件

### 性能・費用

- 通常フロー全体のp50、p95、最大値
- 各AI処理のp50、p95、最大値、再試行回数
- 1投稿あたり推定AI費用5円以下
- PoC総費用5,000円以下

Line評価の個別PoCではp95が10.13秒であり、通常フロー全体の目標6秒は未達になる可能性が高い。未達の場合は品質不合格と混同せず、非同期化、モデル変更、候補数削減、timeout設計の追加検証として記録する。

## 6. 人による確認

各日記の第1反復、計36件をモデル名を伏せた評価票へ出力する。CodexがBlind一次評価を行い、`judge=codex_preliminary`、確信度、理由を記録する。低確信ケースだけを人が対話確認し、人の判定は`judge=human`として分離する。AIの判定を人間評価として集計しない。

## 7. 実行方法

通信せずに件数と費用上限を確認する。

```powershell
bundle exec ruby bin\ai_line_selection plan-integrated
```

Fixtureで全配線と失敗時の分岐を確認する。Fixtureの検索品質はAI品質の判断に使わない。

```powershell
bundle exec ruby bin\ai_line_selection run-integrated `
  --mode fixture `
  --repetitions 3 `
  --safety-repetitions 3
```

実APIは費用条件を利用者が確認し、明示承認した後だけ実行する。

```powershell
bundle exec ruby bin\ai_line_selection run-integrated `
  --mode selected `
  --repetitions 3 `
  --safety-repetitions 3 `
  --allow-external-api
```

実行後、Codex一次評価を取り込み、低確信ケースだけを対話確認する。

```powershell
bundle exec ruby bin\ai_line_selection apply-integrated-preliminary `
  --results results\integrated_<timestamp>_<suffix> `
  --judgments preliminary.json

bundle exec ruby bin\ai_line_selection review-integrated `
  --results results\integrated_<timestamp>_<suffix>
```

## 8. 成果物と停止条件

`results/integrated_<timestamp>_<suffix>/`へ`summary.json`、`provider_outputs.jsonl`、`candidate_sets.jsonl`、`safety_gate.jsonl`、`telemetry.jsonl`、`human_evaluation.csv`、`blind_mapping.csv`、`manifest.json`を生成する。成果物はGit管理しない。

SAFETY見逃し、対象外Line混入、候補外ID、秘密情報のログ出力、再試行後の外部障害、総予算超過があれば停止する。技術エラーは`stopped.json`へ記録し、意味上のSILENCEと区別する。

2026年8月12日のFixture全件リハーサルは通常108回、独立SAFETY 36回を完走し、技術エラー0件、SAFETY後の後続処理0件、最終選択一致率100%だった。これは配線の確認結果であり、統合AI品質の評価結果ではない。
