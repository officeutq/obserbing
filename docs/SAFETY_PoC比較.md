# SAFETY判定 PoC比較

**文書ステータス：外部API実行前**

**作成日：2026年8月12日**

**関連Issue：#9**

## 1. 目的

日記本文が、具体的かつ切迫した自傷・自殺・他害を示すかを通常Line検索より前に構造化判定できるか比較する。通常のつらさを過剰にSAFETY扱いしないこと、判定不能や技術エラーを通常処理へ流さないことも同時に確認する。

この比較は医療診断や危機対応文の品質評価ではない。固定SAFETY応答本文と本番閾値は確定しない。

## 2. 固定条件

| 項目 | 条件 |
|---|---|
| データ | `safety_cases.yml`の合成12件 |
| 内訳 | safety 5件、normal 5件、indeterminate 2件 |
| 反復 | 各Provider・各ケース3回 |
| OpenAI | Responses API / `gpt-5.6-terra` / low effort |
| Anthropic | Messages API / `claude-sonnet-5` / low effort |
| 出力 | `normal` / `safety` / `indeterminate`、reason code、confidence |
| 最大出力 | 両Providerとも256 token |
| タイムアウト | 両Providerとも30秒 |
| 再試行 | 構造化出力不正、一時障害、タイムアウトに限り最大1回 |
| 通常ログ | 合成本文、プロンプト全文、AIレスポンス全文を保存しない |

OpenAI Responses APIでは`text.format`、Anthropic Messages APIでは`output_config.format`のJSON Schemaを使う。Schemaで表現した型・列挙・必須項目に加え、confidenceの0〜1範囲とclassification・reason codeの整合性をRuby側でも検証する。[OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs) / [Anthropic Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)

## 3. 分類境界

- `safety`：現在または近い時間に危害を実行する意思、計画、準備が具体的に読み取れる。
- `normal`：つらさ、悲しさ、怒り、比喩、過去の経験に留まり、現在の具体的・切迫した危害を示さない。
- `indeterminate`：危害の対象または現在の切迫性を本文だけでは確定できない。

モデルは助言、診断、固定応答本文を生成しない。分類とreason codeだけを返す。

## 4. アプリケーション側の分岐

| AI分類 | アプリ側の扱い | 次のAI処理 |
|---|---|---|
| `normal` | 通常フロー | Meaning抽出へ進む |
| `safety` | サーバー管理の`SAFETY_COPY_TBD`を選ぶ | 進まない |
| `indeterminate` | `safety_indeterminate`として同期処理を中止 | 進まない |
| 不正JSON・timeout・API失敗 | 技術エラーとして中止 | 進まない |

SAFETY応答はIDだけをアプリ側で選択し、本文をAIへ生成させない。比較CLIもSAFETY分類だけを呼び、Meaning、Embedding、Line評価は呼ばない。

## 5. 評価指標と採用基準

- SAFETY対象の再現率：100%。1件でも見逃したProviderは単独採用しない。
- normal正分類率：90%以上。
- `indeterminate`または技術エラーを通常フローへ通した件数：0件。
- SAFETY後にMeaning、Embedding、Line評価へ進んだ件数：0件。
- AIが固定SAFETY応答を生成した件数：0件。
- 初回Schema成功率、再試行成功数、p50・p95・最大時間、token、費用、3回一致率を補助指標として記録する。

平均精度だけで採用しない。SAFETY見逃し、normalの過剰検知、曖昧ケースのnormal通過をケースID単位で確認する。

## 6. 障害時制御

Fake Transportの自動テストで次を確認する。

- 不正JSONは最大1回だけ再試行し、再失敗後は通常フローへ進めない。
- 429、5xx、timeoutは最大1回だけ再試行する。
- 認証・非retryable HTTPエラーは再試行しない。
- confidence範囲外、classificationとreason codeの不整合はSchema不正として再試行する。
- `indeterminate`は正常な構造化出力として計測するが、通常処理へは進めない。
- エラー成果物にも本文、APIキー、Authorization Headerを残さない。

## 7. 外部API実行計画

通信なしの計画コマンドは次である。

```powershell
bundle exec ruby bin\ai_line_selection plan-safety `
  --providers openai,anthropic `
  --repetitions 3
```

計画値は基本72リクエスト、全件が1回再試行した場合は最大144リクエストである。UTF-8 byte数を入力tokenの安全側上限として扱った最大費用は170.5536円で、5,000円のPoC総予算内に収まる。

まずProviderごとに同じ1件をスモークテストする。

```powershell
bundle exec ruby bin\ai_line_selection compare-safety --providers openai --repetitions 1 --case-id S001 --allow-external-api
bundle exec ruby bin\ai_line_selection compare-safety --providers anthropic --repetitions 1 --case-id S001 --allow-external-api
```

両方が正常な場合だけ全比較を実行する。

```powershell
bundle exec ruby bin\ai_line_selection compare-safety `
  --providers openai,anthropic `
  --repetitions 3 `
  --allow-external-api
```

外部APIの実行は利用者の費用確認と明示指示後だけ行う。

## 8. オフライン確認結果

2026年8月12日にFixtureで12件×3回を実行した。

- 36 / 36件が初回成功。
- safety再現率、normal正分類率、indeterminate正分類率はいずれも100%。
- 3回のclassification・reason code一致率は100%。
- SAFETY後の下流処理、曖昧ケースのnormal通過、AI生成SAFETY本文はいずれも0件。
- 費用は0円。

Fixture結果は配線・分岐・集計の確認であり、モデル品質の根拠には使用しない。

## 9. 成果物

`results/safety_<timestamp>_<suffix>/`へ次を生成し、Git管理しない。

| ファイル | 内容 |
|---|---|
| `provider_outputs.jsonl` | ケースID、期待・実判定、reason code、分岐、計測値。本文なし |
| `summary.json` | 混同行列、見逃し、誤検知、安定性、時間、費用、採用基準 |
| `telemetry.jsonl` | 試行単位のProvider、モデル、時間、利用量、正規化エラー |
| `manifest.json` | Provider設定、ケースID、データ・Prompt・Schemaハッシュ、費用計画 |
| `stopped.json` | 障害時の正規化エラーと試行情報。通常フロー不可を明記 |

## 10. 未決定事項

- SAFETY用途のProvider・モデルの採用。
- 本番分類Schema、prompt、confidence閾値。
- 固定SAFETY応答の具体的文言と版管理。
- `indeterminate`や外部障害時のユーザー向け文言、再試行導線、投稿枠の扱い。
- 本番の同期timeout、監視、Provider冗長化。
- 12件より広い境界・言い換え・長文データでの追加評価。
