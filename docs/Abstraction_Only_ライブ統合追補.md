# Abstraction Only ライブ統合追補

**文書ステータス：有料実API再実行・Blind評価完了**

**作成日：2026年8月13日**

**関連Issue：#36、#25、#26、Epic #27**

## 1. 結論

APIクレジット追加後、`abstraction-only-v1-diagnostic`をOpenAI実APIで36件×3反復、一からライブ統合した。通常フロー108件とBlind品質評価36回を完走し、残高不足が解消されたこと、1投稿3 API段階、リアルタイムLine評価LLM 0回、p95 5.48768秒、通常フロー1投稿約0.551円を実測した。

一方、Codex重要ケース再評価後のBlind許容率は74.07%、Top 20候補集合Jaccard平均は0.672、致命的事実不整合は1件だった。固定基準の90%、0.80、0件を満たさない。リプレイ結果より品質と候補安定性は少し改善したが、`abstraction-only-v1`を不採用とした判断は変えない。

## 2. 実行条件

| 項目 | 条件 |
|---|---|
| Entry | 固定合成日記36件 |
| 反復 | 各3回、合計108通常フロー |
| Line | Approved 96件 |
| SAFETY | OpenAI `gpt-5.6-terra` / `additional-v3` |
| abstraction | OpenAI `gpt-5.6-terra` / `abstraction-only-v2` |
| Embedding | OpenAI `text-embedding-3-small`、1,536次元 |
| ガード | `grounding-guard-v1` / `combined_v1` |
| Ruby選択 | `similarity_weighted_top_n`、固定seed 3組 |
| Blind品質 | OpenAI `gpt-5.6-terra`、Entry単位で3 Lineを一括評価 |
| リアルタイムLine評価LLM | 0回 |

料金は実行日にOpenAI公式モデルページを開いて確認した。`gpt-5.6-terra`は入力$2.00、キャッシュ入力$0.20、出力$12.00 / 100万token、`text-embedding-3-small`は入力$0.02 / 100万tokenとして集計した。

- https://developers.openai.com/api/docs/models/gpt-5.6-terra
- https://developers.openai.com/api/docs/models/text-embedding-3-small

## 3. 実行経過と再開

最初のライブ試行ではLine EmbeddingとE001のSAFETYが成功した後、統合CLIがabstraction入力を`entry_text`で渡し、OpenAI Adapterが要求する`text`と一致しない配線バグで停止した。Providerエラーや残高不足ではなく、API送信前のローカル`KeyError`だった。

入力キーを修正して実API互換回帰テストを追加し、同じ結果ディレクトリから再開した。Line Embeddingは再利用し、通常フロー108件とBlind品質36回を完走した。完了した論理リクエストは361回だが、停止前に成功していたSAFETY 1回を含む実API成功呼び出しは362回である。

再開前の孤立成功分もテレメトリ台帳から利用量・費用へ含めるよう集計を修正した。実API側の再試行、Schema失敗、Rate Limit、認証エラーは0件だった。完了後は古い`stopped.json`を削除する。

## 4. SAFETY・構造化出力・エラー

| 指標 | 結果 | 基準 | 判定 |
|---|---:|---:|---|
| 既存通常日記normal | 108 / 108 | 過剰遮断0件 | 達成 |
| SAFETYによる下流停止 | 0 | 0 | 達成 |
| 完了フローの技術エラー | 0 | 0 | 達成 |
| 外部API初回Schema成功 | 100% | 99%以上 | 達成 |
| 外部API再試行 | 0 | 参考 | — |
| abstraction文字列完全一致 | 6 / 36（16.67%） | 診断 | 不安定 |

## 5. 候補集合とRuby選択

| 指標 | ライブ結果 | 基準 | 判定 |
|---|---:|---:|---|
| Top 20 Jaccard平均 | 0.6720 | 0.80以上 | 未達 |
| Top 20 Jaccard最小 | 0.2903 | 参考 | — |
| ガード除外 | 105候補 | 参考 | — |
| status混入 | 0 | 0 | 達成 |
| 選択Lineの3反復完全一致 | 1 / 36（2.78%） | 診断 | 不安定 |
| 同一候補・同一seedのRuby再現 | 100% | 100% | 達成 |
| 状態・履歴・禁止・ガード後違反 | 0 | 0 | 達成 |
| SILENCE | 0 / 108 | 25%以下 | 達成 |

Ruby選択自体は決定的だが、生成abstractionの揺らぎによって候補集合が変わるため、End-to-Endの最終Lineは安定しない。

## 6. Blind品質

OpenAI一次評価では81 / 108件を許容とした。ただしE001 / L083について`acceptable=true`と`fatal_grounding_mismatch=true`を同時に返し、理由では人物の具体化を指摘していた。この重要ケースだけをCodexで再評価し、`acceptable=false / not_obserbing / fatal=true`へ補正した。低確信ケースは0件だった。

| 指標 | OpenAI一次評価 | 重要ケース補正後 | 固定基準 | 判定 |
|---|---:|---:|---:|---|
| 表示許容 | 81 / 108（75.00%） | 80 / 108（74.07%） | 90%以上 | 未達 |
| just right | 67 | 66 | 参考 | — |
| too close | 31 | 31 | 参考 | — |
| too far | 10 | 10 | 参考 | — |
| not obserbing | 0 | 1（0.93%） | 10%以下 | 達成 |
| 明らかな無関連 | 4（3.70%） | 4（3.70%） | 5%以下 | 達成 |
| 致命的事実不整合 | 1 | 1 | 0 | 未達 |

致命的不整合はE001 / L083である。日記は「二つの案」の選択について述べるが、Lineは「選んだ一人」「選ばなかった誰か」と具体的人物へ置き換える。意味上の接点があっても、日記にない人物をその日の事実として持ち込むため表示不可とした。

## 7. レイテンシ

| 指標 | ライブ実測 | 基準 | 判定 |
|---|---:|---:|---|
| End-to-End p50 | 3.06231秒 | 参考 | — |
| End-to-End p95 | 5.48768秒 | 6秒以内 | 達成 |
| End-to-End最大 | 7.35767秒 | 参考 | 6秒超あり |
| SAFETY p95 | 2.41454秒 | 参考 | — |
| abstraction p95 | 2.33434秒 | 参考 | — |
| Entry Embedding p95 | 0.48771秒 | 参考 | — |
| Line Embedding事前生成 | 3.53147秒 | 投稿外 | — |

リプレイ時のp95推定5.12991秒に対し、単件APIを含むライブp95は357.77ms、6.97%遅かった。それでも固定6秒基準内だった。最大値は基準を超えるため、本番SLOやtimeout値は別途決める必要がある。

## 8. API利用量・費用

| 項目 | 結果 |
|---|---:|
| 論理完了リクエスト | 361 |
| 実API成功呼び出し | 362 |
| 再開前の孤立成功 | SAFETY 1回 |
| 入力token | 182,182 |
| 出力token | 19,181 |
| キャッシュ入力token | 0 |
| 今回実費推定 | 88.1341円 |
| 通常フロー1投稿費用 | 約0.5510円 |
| Epic累積 | 636.0074円 / 5,000円 |

通常フロー費用はbaseline `selected-v1`の2.2756円 / 投稿より75.79%低い。362回にはLine Embedding 1回、通常フロー325回、Blind品質36回、停止前に成功して再実行されたSAFETY 1回を含む。ローカル配線エラーはAPI呼び出しとして数えない。

## 9. リプレイとの差

| 指標 | 実API出力リプレイ | ライブ統合 | 差 |
|---|---:|---:|---:|
| 補正後Blind許容率 | 70.37% | 74.07% | +3.70ポイント |
| Top 20 Jaccard平均 | 0.6397 | 0.6720 | +0.0323 |
| 明らかな無関連 | 5.56% | 3.70% | -1.86ポイント |
| 致命的事実不整合 | 2 | 1 | -1 |
| p95 | 5.12991秒推定 | 5.48768秒実測 | +0.35777秒 |
| 1投稿費用 | 約0.5500円 | 約0.5510円 | ほぼ同じ |

生成出力の違いにより品質は少し改善したが、固定基準から見れば同じ失敗構造である。候補集合の揺らぎ、obserbing distanceの制御不足、未知の具体的主張を静的ガードだけで防げない点が再確認された。

## 10. 採用判断

`abstraction-only-v1`は採用しない。ライブ実行は次を確定した。

- SAFETY `additional-v3`は既存通常日記を過剰遮断しない。
- SAFETY・abstraction・Entry Embeddingの3 API通常フローはp95 6秒以内、1投稿1円未満で動く。
- Line評価LLM 0回でも実装・運用上の接続は成立する。
- しかし最終Line品質90%、候補Jaccard 0.80、事実不整合0件を同時に満たさない。

速度・費用の成立は、品質必須条件を上書きしない。`selected-v1`と追加方式をどちらも現状見送るIssue #26の結論、およびEpic #27の完了判断は維持する。

## 11. 再現方法と成果物

```powershell
bundle exec ruby bin\ai_line_selection run-abstraction-only-integrated `
  --mode diagnostic `
  --repetitions 3 `
  --results results\abstraction_only_integrated_live_20260813_issue36 `
  --allow-external-api
```

生結果は`results/`に置きGit管理しない。版付き要約は`data/evaluations/abstraction_only_integrated_live_v1.yml`、重要ケース補正は`data/evaluations/integrated_live_codex_review_v1.yml`に保存する。生結果のSHA-256は版付き要約から確認できる。
