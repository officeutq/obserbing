# Line候補評価 PoC比較

**文書ステータス：実API比較・Blind評価完了**

**作成日：2026年8月12日**

**関連Issue：#8**

## 1. 目的

Embeddingで取得した同一のLine候補集合を複数LLMへ渡し、obserbingに必要な「関連しているが、直接答えてはいない距離」を評価できるか比較する。AI単独の推奨と、Railsへ移植する決定ルールを分離し、SILENCE、閾値感度、再現性、速度、費用も測定する。

## 2. 固定条件

| 項目 | 条件 |
|---|---|
| Meaning | 合成データの固定Meaning Structure。Issue #6のProvider差を混ぜない |
| Embedding | Issue #7採用候補の`text-embedding-3-small`、1,536次元、Meaning Structure入力 |
| 検索対象 | `status = approved`の96件だけ |
| LLM投入 | 各日記の上位20候補 |
| Line評価候補 | OpenAI `gpt-5.6-terra`、Anthropic `claude-sonnet-5` |
| 反復 | 36件 × 2 Provider × 3回 |
| 出力 | JSON Schemaによる4軸評価、全候補ID、AI推奨IDまたは`SILENCE` |
| 推論量 | 両Providerとも`low` |
| 最大出力 | 両Providerとも4,096 token |
| タイムアウト・再試行 | 30秒、Rate Limit・5xx・Timeout・構造不正に最大1回 |

Line評価LLMへ渡す候補は`id`、本文、Embedding類似度だけとする。合成データに付けた`directness`、Theme、Meaning、status、review_statusは正解用メタデータであり、LLM入力へ含めない。

## 3. 評価軸

- `relevance`：日記のMeaning Structureとの関連性
- `directness`：答え、助言、指示、断定への近さ
- `space`：投稿者が自分で意味を見つける余地
- `obserbing_fit`：関連しているが直接答えず、観察のきっかけだけを置く一行としての適合度

診断、説教、励まし、称賛、過剰な共感、人格・感情の断定、「あなたは」で始まる分析、名言調、意味を完成させすぎる文は不適合要因とする。

## 4. AI判定とRails相当制御

LLMは各候補の4軸に加えて、独立した`recommended_line_id`を返す。Rubyの`FinalSelector`は同じ4軸から閾値と重みで最終LineまたはSILENCEを確定する。この二つを別々に保存し、一致率と差分ケースを集計する。

初期のbalanced制御は次のとおり。

| 軸 | 採用条件 |
|---|---:|
| relevance | 0.30以上 |
| directness | 0.75以下 |
| space | 0.45以上 |
| obserbing_fit | 0.60以上 |

最終スコアはrelevance 35%、directnessの目標値0.35への近さ15%、space 25%、obserbing_fit 25%とする。閾値の材料を得るため、permissive・balanced・conservativeの3条件で、選択LineとSILENCE件数の変化を同じ出力から再計算する。

## 5. 厳格検証とSILENCE

次は技術エラーとして実験を停止し、SILENCEへ変換しない。

- 候補IDの欠落、重複、候補外ID
- AI推奨が候補外ID
- 4軸の欠落、型不正、0〜1範囲外
- 不正JSON、認証、Rate Limit、5xx、Timeout、モデル不一致

スキーマとID契約を満たした出力に対し、適格候補がないと判断した場合だけ意味的なSILENCEとする。これにより「選べなかった」と「処理に失敗した」を区別する。

## 6. 人間評価の省力化

人間評価は各Providerの第1反復だけを対象とし、残り2回は再現性指標へ使う。Provider名を伏せた72出力に対して、Codexが次を一次評価する。

- 距離：`too_close` / `just_right` / `too_far` / `not_obserbing`
- 許容可否
- 致命的違反の有無
- 確信度と理由

Codex一次評価は`judge=codex_preliminary`として記録し、人間評価と混同しない。低確信または判断が割れる行だけ`needs_human_review=true`とし、対話CLIで人が確認する。人による上書きは`judge=human`、`human_reviewed=true`として残す。

## 7. 実行前計画

通信なしで次を実行する。

```powershell
cd C:\dev\obserbing\poc\ai_line_selection
bundle exec ruby bin\ai_line_selection plan-line-evaluation `
  --providers openai,anthropic `
  --embedding-provider openai-small `
  --repetitions 3
```

2026年8月12日の計画値は次のとおり。

| 区分 | 通常リクエスト | 全件1回再試行の上限 | 費用上限見積もり |
|---|---:|---:|---:|
| Embedding | 2 | 4 | 0.0638円 |
| OpenAI Line評価 | 108 | 216 | 2,042.8362円 |
| Anthropic Line評価 | 108 | 216 | 1,777.4154円 |
| 合計 | 218 | 436 | 3,820.3154円 |

費用上限は入力本文・プロンプト・JSON SchemaのUTF-8 byte数を1 byteあたり最大1 token相当とみなし、さらにProvider内部プロンプト用の予備2,048 tokenを各リクエストへ加え、全出力が4,096 token、全リクエストが1回再試行する条件を重ねた保守値である。実費予測ではない。設定済みのPoC総予算5,000円以内だが、利用者の明示承認までは実APIを呼ばない。

## 8. 実行・評価コマンド

Fixtureによる配線確認は外部通信を行わない。

```powershell
bundle exec ruby bin\ai_line_selection compare-line-evaluation `
  --providers fixture `
  --embedding-provider fixture `
  --repetitions 1
```

実API比較は明示フラグがある場合だけ通信する。

```powershell
bundle exec ruby bin\ai_line_selection compare-line-evaluation `
  --providers openai,anthropic `
  --embedding-provider openai-small `
  --repetitions 3 `
  --allow-external-api
```

Codex一次評価後、低確信ケースだけを対話確認する。

```powershell
bundle exec ruby bin\ai_line_selection review-line-evaluation `
  --results results\line_evaluation_<timestamp>_<suffix>
```

## 9. 公式API前提

- OpenAIはResponses APIのStructured Outputsを使い、`reasoning.effort=low`、`store=false`、Toolsなしとする。[OpenAI gpt-5.6-terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra) / [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- AnthropicはMessages APIの`output_config.format`へJSON Schemaを指定し、`output_config.effort=low`、Toolsなしとする。[Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) / [Effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- 料金は2026年8月12日時点でOpenAIが入力$2・cached入力$0.20・出力$12 / 100万token、Claude Sonnet 5が入力$2・cache hit $0.20・出力$10 / 100万tokenとして固定した。[OpenAI pricing](https://developers.openai.com/api/docs/pricing) / [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)

## 10. 実API結果

2026年8月12日に利用者の明示承認後、Embedding 2件とLine評価216件を実行した。Line評価は両Providerとも108/108件が初回成功し、再試行・技術エラー・候補ID違反・数値範囲違反は0件だった。本比較の実費推定は391.6766円、Schema互換性診断とProvider別スモークを含む総額は395.5281円だった。

実行前のSchema診断では、OpenAIが`schema_version`に明示的な`type`を要求し、Anthropicが配列の`maxItems`と数値の`minimum` / `maximum`を未対応として拒否した。共通Schemaから未対応制約を外し、候補数、全候補IDの完全一致、数値0〜1をRuby側で再試行付き検証する構成にした。両Providerの1件スモーク成功後に全件を実行した。

| 指標 | OpenAI `gpt-5.6-terra` | Anthropic `claude-sonnet-5` |
|---|---:|---:|
| 実行成功 | 108 / 108 | 108 / 108 |
| 初回Schema成功率 | 100% | 100% |
| AI推奨とRuby選択の一致率 | 98.15% | 100% |
| 3回の最終選択一致率 | 47.22%（17 / 36） | 94.44%（34 / 36） |
| Line評価p50 | 6,460.52ms | 8,471.08ms |
| Line評価p95 | 8,462.12ms | 10,128.26ms |
| 最大 | 16,778.31ms | 11,641.11ms |
| Line評価実費推定 | 170.3559円 | 221.3091円 |
| Blind評価の許容率 | 97.22%（35 / 36） | 100%（36 / 36） |
| `just_right` | 35 / 36 | 36 / 36 |
| 致命的違反 | 1件 | 0件 |

両Providerの第1反復で同じLineを選んだのは24 / 36件（66.67%）だった。Blind評価はCodexが72出力を一次評価し、低確信2件だけを利用者が確認した。判定主体は`codex_preliminary` 70件、`human` 2件として分離記録した。利用者確認では、次の2件はいずれも`just_right`かつ許容可となった。

- 「一緒に笑った時間は、次の約束を要求しない。」は「考えさせられる素晴らしいLine」と評価された。
- 「予想は、未来より今の輪郭を映す。」は現行でも良いが、「予想」より「想像」のほうが自然という改善意見があった。比較データを事後変更せず、Line文言レビューの候補として記録する。

## 11. AI単独とRuby制御の差

OpenAIでは108回中2回だけAI推奨とRuby選択が異なった。E011の第2反復はAI `L028`に対しRuby `L032`、E022の第2反復はAI `L071`に対しRuby `L095`だった。Anthropicは108回すべて一致した。

OpenAIの唯一の致命的違反はE024だった。日記には箱がないのに、`L077`「捨てなかった箱は、まだ決めていない時間を守る。」を選んだ。OpenAIは同候補へrelevance 0.90、directness 0.34、space 0.82、obserbing_fit 0.90を付け、AI推奨とRuby選択がともに`L077`になった。RubyのID・範囲・閾値制御は技術的不正を防ぐが、LLMが全軸を高く誤評価した意味的不適合は防げない。

この失敗から、次のPrompt版では「日記やMeaningにない具体的な人物・物・出来事を持ち込む候補」のrelevanceとobserbing_fitを明示的に下げる必要がある。必要なら`groundedness`を独立軸として追加比較する。実験後にPromptだけを変更すると今回の結果を再現できなくなるため、本Issueの`draft-1`は変更せず次版候補とする。

## 12. 軸・重み・閾値の材料

第1反復でRubyが選んだLineの4軸は次の範囲だった。

| Provider | relevance 平均 / 最小 | directness 平均 / 最大 | space 平均 / 最小 | obserbing_fit 平均 / 最小 |
|---|---:|---:|---:|---:|
| OpenAI | 0.9494 / 0.88 | 0.2594 / 0.58 | 0.7972 / 0.57 | 0.9158 / 0.82 |
| Anthropic | 0.9172 / 0.85 | 0.2042 / 0.30 | 0.8297 / 0.80 | 0.8911 / 0.85 |

permissive・balanced・conservativeの3条件で、36件すべての選択LineとSILENCE件数は変わらなかった。balancedで適格になった候補数はOpenAIが平均9.58件（2〜17件）、Anthropicが平均6.78件（2〜15件）だった。最上位候補が各閾値から十分離れており、今回の通常ケースだけでは閾値と重みの優劣を決められない。

実ProviderのSILENCEは両社とも0件だった。適切な候補がないケースを含まないためであり、技術エラーとSILENCEの分離、全候補不適格時の`no_qualified_candidate`はFixtureと契約テストで確認した。次の閾値検証では、関連候補なし、近すぎる候補だけ、遠すぎる候補だけ、具体物を持ち込む候補だけの境界ケースを追加する。

## 13. 採用判断

Issue #8のLine候補評価PoCでは、`claude-sonnet-5`・`low` effort・4軸構造化出力を採用候補とする。これはLine候補評価用途だけの判断であり、SAFETY、Meaning、本番全体のProviderを確定しない。

採用理由は次のとおり。

- Blind評価で36 / 36件が許容、致命的違反0件だった。
- 3回の最終選択一致率94.44%で、目安の80%を満たした。
- AI推奨とRuby選択が108 / 108回一致した。
- Schema成功率100%、技術エラー0件だった。

OpenAIはp50・p95と費用で優位だったが、最終選択一致率47.22%で目安未達、致命的な意味的不適合が1件あったため、現行Prompt・軸では採用候補から外す。

ただしAnthropicのLine評価p95も10.13秒で、通常フロー全体6秒の初期目標を満たさない。正式採用は、境界ケースによるSILENCE・groundedness検証、Prompt次版比較、同期処理の待ち時間設計を終えた後に判断する。balancedの閾値と現行重みは暫定値のままとし、本Issueでは確定しない。
