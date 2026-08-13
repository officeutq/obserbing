# Abstraction Only 統合PoC比較

**文書ステータス：実API出力リプレイ完了・ライブ追補あり**

**作成日：2026年8月13日**

**関連Issue：#25 / Epic #27**

> APIクレジット追加後の36件×3反復ライブ統合はIssue #36で完了した。最新の実測結果は[Abstraction Only ライブ統合追補](Abstraction_Only_ライブ統合追補.md)を参照する。本書はIssue #25時点のリプレイ結果として保持する。

## 1. 結論

`abstraction-only-v1`は採用しない。Issue #22の候補集合安定性、Issue #24の表示品質に加え、統合後も固定基準を満たさなかった。

通常36件×3反復の108出力を接続した結果、Blind表示許容率は70.37%、Top 20候補集合Jaccard平均は0.6397だった。どちらも固定基準の90%、0.80に未達である。さらに、Issue #23のガード後にも致命的事実不整合が2件見つかった。

一方、SAFETYの既存通常日記過剰遮断は0件、構造化出力初回成功率は100%、同一seedのRuby選択再現率は100%、リアルタイムLine評価LLMは0回だった。p95は5.12991秒の推定で6秒基準内だが、Entry Embeddingをバッチ実測から按分した値であり、本番単件レイテンシではない。

## 2. 統合方式の位置づけ

Issue #20〜#24で固定基準を満たしたのはSAFETY、abstraction、事実整合ガードの3 / 5要素だった。EmbeddingとRuby選択は不適格だったため、正式な候補チェーンは構築できない。

それでも失敗の重なり方を確認するため、次を `abstraction-only-v1-diagnostic` として接続した。

1. SAFETY `additional-v3`
2. abstraction `abstraction-only-v2`
3. `text-embedding-3-small`による代表Line abstraction検索
4. `grounding-guard-v1` / `combined_v1`
5. `similarity_weighted_top_n`
6. 候補なしの場合はSILENCE

これは診断専用であり、`abstraction-only-v1`を採用候補へ昇格させるものではない。

## 3. 実行方法とAPI残高

Fixtureでは36件×3反復の全配線を実行し、SAFETY・技術エラー・SILENCEが別状態で記録されること、1投稿当たりSAFETY・abstraction・Entry Embeddingの3 API段階になることを確認した。

その後、同じ条件で実APIを開始したが、最初のLine事前EmbeddingでOpenAIから `insufficient_quota / credit_balance_exhausted` が返った。再試行を含む利用tokenと費用は0だった。APIクレジット購入は実験実行とは別の請求設定変更になるため行っていない。

統合評価自体は、すでに課金実行済みの次の実API生結果をEntry ID・反復番号で接続して完了した。

- Issue #20: SAFETY `additional-v3` 完了216出力
- Issue #21: `abstraction-only-v2` 完了468出力
- Issue #22: abstraction Embedding 108候補集合とBlind候補評価

この方式を「実API出力リプレイ」と呼ぶ。Provider出力、token、レイテンシ、費用は実測値を再利用し、新しいAPI結果を生成したようには扱わない。

## 4. 比較条件

| 項目 | 条件 |
|---|---|
| Entry | 固定合成日記36件 |
| 反復 | 各3回 |
| Line | Approved 96件 |
| Line索引 | 代表Line abstraction、事前生成 |
| 検索 | cosine Top 20、選択対象Top 5 |
| ガード | `grounding-guard-v1` / `grounding-attributes-v1` |
| 選択 | 類似度重み付き、固定seed 2719001〜2719003 |
| 品質評価 | Issue #22の方式Blindラベル + 未評価/低確信14組のCodex一次評価 |
| リアルタイムLine評価LLM | 0回 |

未評価11組と低確信3組だけを再評価した。最終108組の評価カバレッジは100%、低確信残りは0件である。

## 5. SAFETY・構造化出力

| 指標 | 結果 |
|---|---:|
| 通常日記のSAFETY正解 | 108 / 108 |
| 既存通常日記の過剰遮断 | 0 |
| SAFETYによる下流停止 | 0 |
| abstraction初回Schema成功 | 100% |
| abstraction再試行成功 | 0件（再試行不要） |
| abstraction完全一致安定 | 4 / 36（11.11%） |

追加SAFETY境界の危険・判定不能ケースはIssue #20で全216 / 216件正解済みであり、通常36件の平均へ混ぜず診断参照とした。

## 6. 候補・選択安定性

| 指標 | 結果 | 基準 | 判定 |
|---|---:|---:|---|
| Top 20 Jaccard平均 | 0.6397 | 0.80以上 | 未達 |
| Top 20 Jaccard最小 | 0.1429 | 参考 | — |
| 選択Lineの3反復完全一致 | 1 / 36（2.78%） | 参考 | 不安定 |
| 同一候補・同一seedのRuby再現 | 100% | 100% | 達成 |
| 状態・再利用・禁止・ガード後違反 | 0 | 0 | 達成 |
| SILENCE | 0 / 108 | 25%以下 | 達成 |

Ruby乱択自体は決定的だが、生成abstractionによって候補集合が変わり、さらに反復ごとに異なる固定seedを使うため最終Lineはほぼ一致しない。検索の上流不安定性を乱数の決定性では解消できない。

## 7. Blind品質

| 指標 | 結果 | 基準 | 判定 |
|---|---:|---:|---|
| 表示許容 | 76 / 108（70.37%） | 90%以上 | 未達 |
| just right | 54 / 108 | 参考 | — |
| too close | 26 / 108 | 参考 | — |
| too far | 26 / 108 | 参考 | — |
| not obserbing | 2 / 108（1.85%） | 10%以下 | 達成 |
| 明らかな無関連 | 6 / 108（5.56%） | 5%以下 | 未達 |
| 致命的事実不整合 | 2 / 108 | 0 | 未達 |

事実不整合は次の2件だった。

- E019 / L074: 部屋の配置変更はあるが、Lineの「空になった場所」は存在しない。
- E026 / L021: 声への気づきはあるが、Lineの「会話のあと」は存在しない。

Issue #23の回帰語彙は数量・箱などの既知ペアを検出したが、場所の空状態と会話イベントを属性化していなかった。静的語彙ガードは未知の具体的主張を完全には一般化できない。

## 8. レイテンシ

| 指標 | 結果 |
|---|---:|
| p50推定 | 2.64309秒 |
| p95推定 | 5.12991秒 |
| 最大推定 | 6.98013秒 |
| Line索引事前生成 | 1.80230秒（投稿外） |
| Entry Embeddingバッチ | 1.33384秒 / 108件 |

SAFETYとabstractionは各実API呼び出しの実測時間を使用した。Entry EmbeddingはIssue #22で108件を1バッチ送信した総時間を108分割して加えた。したがってp95基準達成は参考値であり、単件API呼び出しの保証ではない。

## 9. API利用量・費用

通常フローの意味上のAPI段階は1投稿当たり3回である。

1. SAFETY
2. abstraction
3. Entry Embedding

Line Embeddingは投稿前処理で、リアルタイムLine評価LLMは0回である。

| 項目 | 結果 |
|---|---:|
| 接続した実API入力token | 157,312 |
| 接続した実API出力token | 7,367 |
| 接続部分の実測費用 | 59.4016円 |
| 1投稿当たり概算 | 約0.5500円 |
| Issue #25の追加課金 | 0円 |
| Epic #27累積 | 547.8733円 |

59.4016円はIssue #20〜#22ですでに累積計上済みの一部なので、重複加算しない。実API再試行の上限見積もりは1,031.353円で5,000円以内だったが、残高不足により新規課金は発生しなかった。

料金表は2026年8月13日にOpenAI公式ページを再確認した。`gpt-5.6-terra`は短文で入力$2.00・キャッシュ入力$0.20・出力$12.00 / 100万token、`text-embedding-3-small`は入力$0.02 / 100万tokenとしている。

- https://developers.openai.com/api/docs/models/gpt-5.6-terra
- https://developers.openai.com/api/docs/models/text-embedding-3-small

## 10. 完了条件

| 完了条件 | 結果 |
|---|---|
| 同じ36件で全段階を統合評価 | 実API出力リプレイで完了 |
| Line評価LLM 0件 | 達成 |
| 基準をケースID付きで判定 | 達成 |
| SAFETY・技術エラー・SILENCEを別集計 | 達成 |
| baseline比較用の品質・性能・費用データ | 達成 |

## 11. 再現方法

Fixture:

```powershell
bundle exec ruby bin\ai_line_selection run-abstraction-only-integrated `
  --mode fixture --repetitions 3
```

実API出力リプレイ:

```powershell
bundle exec ruby bin\ai_line_selection replay-abstraction-only-integrated `
  --safety-results results\safety_boundary_additional_v3_candidate_full_<...> `
  --abstraction-results results\abstraction_abstraction_only_v2_<...> `
  --embedding-results results\abstraction_embedding_<...> `
  --reviews data\evaluations\integrated_replay_codex_review_v1.yml `
  --repetitions 3
```

生結果は `results/` に置きGit管理しない。版付き集計は `data/evaluations/abstraction_only_integrated_v1.yml`、追加判断は `data/evaluations/integrated_replay_codex_review_v1.yml` に保存する。
