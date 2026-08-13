# Embedding候補検索 PoC比較

**関連Issue：#7**

**更新日：2026年8月12日**

**状態：実API比較完了・PoC採用候補決定**

## 1. 目的

合成日記36件とLine 120件を固定し、Embeddingの入力形式とモデルだけを変えて、期待テーマを持つApproved Lineを上位候補へ残せるか比較する。Embedding類似度は最終Lineを決めるためではなく、後段のルールとLLM評価へ渡す候補を絞るために用いる。

Meaningモデルの差を混ぜないため、この比較では`entries.yml`の固定された期待Meaningを使用する。Issue #6のProvider出力は使用しない。本番相当のMeaning出力との結合は統合PoCで別に評価する。

## 2. 固定条件

- Entry：合成データ36件
- Line：120件中Approved 96件だけをEmbedding生成・検索対象とする
- 除外：Candidate 12件、Retired 12件はEmbedding生成前に除外する
- 正解集合：Entryの期待Themeと同じThemeを持つApproved Line
- 類似度：cosine similarity
- 候補取得件数：20、50、100。Approvedは96件のため、100指定時は最大96件
- 事前基準：Recall@20 85%以上、Recall@50 95%以上、Candidate / Retired混入0件
- 入力生成版：`embedding-text-v1`

入力形式は次の3種類を同じデータで比較する。

| 形式 | Entry | Line |
|---|---|---|
| `original` | 日記原文 | Line本文 |
| `meaning_structure` | themes、structure、abstractionのJSON | theme、meaningのJSON |
| `normalized_text` | Meaning各値をNFKC・空白正規化して連結 | theme、meaning、本文をNFKC・空白正規化して連結 |

## 3. モデル候補

| 比較名 | モデル | 次元数 | 標準入力料金（100万token） | 位置づけ |
|---|---|---:|---:|---|
| `openai-small` | `text-embedding-3-small` | 1,536 | $0.02 | 費用優先の第一候補 |
| `openai-large` | `text-embedding-3-large` | 1,536 | $0.13 | 品質差を確認する比較候補 |
| `fixture` | `offline-hash-embedding-v1` | 64 | $0 | 配線・再現性確認専用。本番候補外 |

OpenAI Embeddings APIは文字列配列を一括入力でき、`text-embedding-3`系では出力次元数を指定できる。レスポンスの`usage.prompt_tokens`を実利用量として記録する。[OpenAI Embeddings API](https://developers.openai.com/api/reference/resources/embeddings/methods/create)、[smallモデル料金](https://developers.openai.com/api/docs/models/text-embedding-3-small)、[largeモデル料金](https://developers.openai.com/api/docs/models/text-embedding-3-large)

両実モデルを1,536次元にそろえるのは、モデル差と保存サイズ差を分離し、`pgvector`の`vector`型HNSW上限2,000次元以内で比較するためである。largeの既定次元を使う比較は、このPoCで1,536次元版が基準未達または品質差の判断に不足した場合だけ追加する。

## 4. 実行方法

費用計画だけを表示するコマンドはネットワーク通信を行わない。

```powershell
cd C:\dev\obserbing\poc\ai_line_selection
bundle exec ruby bin\ai_line_selection plan-embedding --providers openai-small,openai-large
```

2026年8月12日時点の固定データでは、基本12リクエスト、各リクエスト1回再試行時は最大24リクエストである。UTF-8 byte数をtoken数の安全側上限として計算した費用上限は合計1.4988円である。

オフライン比較は外部通信なしで実行できる。

```powershell
bundle exec ruby bin\ai_line_selection compare-embedding --providers fixture
```

実API比較は`--allow-external-api`がない限り送信前に停止する。再実行する場合も利用者の明示承認後にだけ次を実行する。

```powershell
bundle exec ruby bin\ai_line_selection compare-embedding `
  --providers openai-small,openai-large `
  --allow-external-api
```

## 5. オフライン事前確認

Fixtureで全件を実行し、入力形式ごとに次を確認した。Fixtureは文字・単語ハッシュであり、数値は実Embedding品質を示さない。

| 入力形式 | Recall@20 | Recall@50 | Top 1 Theme不一致 | 判定 |
|---|---:|---:|---:|---|
| 原文 | 21.88% | 52.95% | 33 / 36 | 本番候補外 |
| Meaning Structure | 21.88% | 58.68% | 32 / 36 | 本番候補外 |
| 正規化テキスト | 84.38% | 100.00% | 15 / 36 | 本番候補外。実モデル比較の有力入力 |

全形式でCandidate / Retired混入は0件、同一データの順位は再実行で一致した。正規化テキストはFixtureでも相対的に良いが、Recall@20が事前基準をわずかに下回り、かつ意味モデルではないため採用しない。

## 6. 記録する指標

実行結果はGit管理外の`poc/ai_line_selection/results/embedding_<timestamp>_<suffix>/`へ保存する。

- `manifest.json`：モデル、料金表、入力生成版、Entry / Line ID、候補件数、実行前費用計画
- `entry_results.jsonl`：Entry別のRecall、期待候補順位、Top 1候補、ステータス混入件数
- `summary.json`：Recall@20 / 50 / 100、MRR、検索時間、API時間、次元数、保存量、利用token、費用、候補別の採否理由
- `telemetry.jsonl`：リクエスト単位の成功、再試行、時間、利用量、費用。本文とベクトル値は記録しない

## 7. 実API比較結果

2026年8月12日に、利用者の明示承認後、2モデル×3入力形式を実行した。12リクエストはすべて初回成功し、再試行は0件、合計実費推定は0.2865円だった。Candidate / Retired混入は全条件で0件だった。

| モデル | 入力形式 | Recall@20 | Recall@50 | Top 1 Theme不一致 | 実費推定 |
|---|---|---:|---:|---:|---:|
| small | 原文 | 47.05% | 75.52% | 9 / 36 | 0.0108円 |
| small | Meaning Structure | 95.14% | 98.96% | 1 / 36 | 0.0116円 |
| small | 正規化テキスト | 87.33% | 99.13% | 1 / 36 | 0.0158円 |
| large | 原文 | 54.34% | 81.25% | 9 / 36 | 0.0703円 |
| large | Meaning Structure | 95.83% | 99.48% | 1 / 36 | 0.0755円 |
| large | 正規化テキスト | 86.81% | 97.40% | 1 / 36 | 0.1025円 |

Meaning Structureは両モデルで事前基準を満たした。smallに対するlargeの改善はRecall@20で0.69ポイント、Recall@50で0.52ポイントに留まり、費用は約6.5倍だった。smallのMeaning StructureはMRR 0.9815、largeは0.9792であり、最上位の期待候補順位でもlargeの優位は見られなかった。

smallのMeaning Structureでは、Line一括生成が1,878 token・0.0056円・1,690.12ms、Entry 36件の一括生成が1,996 token・0.0060円・1,132.70msだった。Rubyによる96件の完全cosine検索はp95 61.3745msだった。API時間はバッチ条件、検索時間はPoC Ruby実装の値であり、1投稿ずつの本番API時間やPostgreSQL性能を示す値ではない。

Recall@20が85%未満だったのはE013、E016、E017、E022の4件だった。ただし全件で最上位候補は期待Themeと一致しており、候補集合内の同Theme Lineをどこまで残すかでRecallが下がった。候補取得を20件へ縮小する根拠としては弱いため、初期値は50件を維持する。

唯一のTop 1 Theme不一致はE011だった。期待Themeは「距離・信頼」だが、Top 1はTheme「関係」のL028だった。L028の意味は「省略と沈黙」で日記内容と意味的に接続しており、Theme一致だけを正解とする指標が関連候補を過小評価する例である。このケースからも、類似度またはTheme一致だけで最終Lineを決めない。

## 8. `pgvector`採用判断の前提

このIssueではDB migrationを作らない。実モデル比較で候補を絞った後、Rails組み込み時に次を検証する。

- `vector(1536)`とcosine distanceを初期候補とする
- Lineの`status = approved`をEmbedding生成前とDB検索条件の両方で強制する
- モデル名と`embedding-text-v1`を保存し、新旧版を同じ検索へ混在させない
- 1ベクトルの概算保存量は`4 × dimensions + 8` byte。1,536次元では6,152 byteで、96件は590,592 byte（インデックスを除く）
- まず完全検索で正解順位を固定し、Line数を増やした性能試験でのみHNSWを比較する
- HNSWでは速度とRecallのトレードオフ、フィルタ後の取得件数、`ef_search`を実データ規模で測定する

`pgvector`は完全近傍検索とHNSW / IVFFlatを提供し、`vector`型のHNSWは最大2,000次元、保存量は`4 × dimensions + 8` byteとされている。[pgvector公式README](https://github.com/pgvector/pgvector)

## 9. 採用判断

Issue #7のPoC採用候補は、`text-embedding-3-small`・1,536次元・Meaning Structure入力とする。候補取得件数は50件、後段のLLM投入上限は現行の20件を維持する。

見送り理由は次のとおり。

- 原文：両モデルともRecall@20、Recall@50が事前基準未達
- 正規化テキスト：基準は満たすが、Meaning StructureよりRecall@20が低く、入力tokenと費用も多い
- `text-embedding-3-large`：品質差が小さく、smallの約6.5倍の費用に見合う優位がない
- Fixture：意味Embeddingではなく、配線確認専用

これは本番正式採用ではない。次をすべて満たした後に本番採用を判断する。

- Recall@20、Recall@50、ステータス除外の事前基準を満たす
- 50件以下で95%以上の平均Recallを確保できる
- 1,536次元で`pgvector`候補構成に収まる
- 実利用量、API時間、検索時間が記録できる
- Top候補の失敗例を確認し、類似度だけで最終決定しない前提を維持できる

類似度は「近すぎる」「直接的すぎる」「余白がない」「直近利用・再利用禁止」を判断できない。したがって、最良Embedding候補であっても、後段のRailsルールとLine複数軸評価を省略しない。
