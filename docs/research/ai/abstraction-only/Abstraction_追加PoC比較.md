# Abstraction追加PoC比較

**文書ステータス：実API比較・Codex一次評価完了**

**作成日：2026年8月13日**

**関連Issue：#21 / Epic #27**

## 1. 結論

後続のEmbedding候補検索へ渡す生成候補として`abstraction-only-v2`を採用する。

既存の合成日記36件とLine 120件の計156件を、Entry / Lineで区別しない同一Prompt・同一Schemaにより各3回、合計468回生成した。OpenAI `gpt-5.6-terra`の初回Schema成功率は100%、再試行は0回だった。

方式名とbaseline / 候補の配置を伏せたCodex一次評価では、候補の利用可能率は156 / 156件、3反復の意味的同等率も156 / 156件だった。原文にない数量、人物、物、出来事、因果、診断、感情・人物像固定、不要な固有名詞は0件だった。人へ確認を回す低確信・致命的違反ケースは0件である。

候補には具体性を残しすぎた2件、意味を削りすぎた1件があるが、いずれも条件付きで検索表現として利用可能と判断した。後続Issueでは平均値だけでなく、これらのIDを検索結果と合わせて追跡する。

これは合成156件に対するPoC候補であり、本番Prompt、Schema、Provider、モデルの正式採用ではない。

## 2. 目的

日記とLineの検索入力を、同程度の抽象度を持つ1つの短い`abstraction`にそろえられるか検証する。初回Meaning Structureの`abstraction`またはLineの既存`meaning`をbaselineとし、新しい対称Promptとの差を比較する。

検証対象は次である。

- EntryとLineに同じ抽象化規則を適用できるか。
- themes / structureを出力・検索入力から除外できるか。
- 原文の具体的事実を保持しすぎず、新事実を追加しないか。
- 診断、感情・人物像固定、不要な固有名詞を追加しないか。
- 3回の文字列が違っても、意味関係を安定して保てるか。
- Line側を事前生成し、Entry側だけを投稿時生成へ分離できるか。

## 3. 固定データとbaseline

| データ | 件数 | baseline | 実行上の位置づけ |
|---|---:|---|---|
| 合成日記 | 36 | `entries.yml`の`expected.abstraction` | 投稿時に生成する想定 |
| 既存Line | 120 | `lines.yml`の`meaning` | 事前生成する想定 |
| 合計 | 156 | 初回データを変更せず参照 | 各3回生成 |

Lineの内訳はApproved 96件、Candidate 12件、Retired 12件である。本Issueでは状態別に生成と版管理ができることを確認するため全120件を対象にした。後続の検索対象はApproved 96件だけとし、Candidate / Retiredを検索へ混ぜない。

固定データのSHA-256は次のとおりである。

| データ | SHA-256 |
|---|---|
| Entry | `8ca60da809022778f2f1474f2c20525748b1da7f90fec52d565a0ef58cd8e181` |
| Line | `c2c4814d0f159daf989a21e17413b008a822533ee5c843fbda00d658cfff4232` |

既存本文、baseline、初回Meaning Structureは変更していない。

## 4. 対称な出力規則

EntryとLineのどちらにも、入力を`text` 1つとして渡し、同じPrompt・Schemaを使う。モデルへsource typeを伝えない。

出力は次の2項目だけである。

```json
{
  "schema_version": "abstraction-only-v2",
  "abstraction": "短い関係概念"
}
```

規則は次で固定した。

- 表層Themeではなく、関係、変化、両立、緊張、ずれ、留保、反復を短い名詞句で表す。
- 目安8〜30文字、Schema上限60文字とする。
- themes、structure、説明、候補を出力しない。
- 数量、人物、物、場所、時刻、固有名詞、個別出来事を不要に複製しない。
- 原文にない事実、因果、意図、感情、評価を追加しない。
- 診断、助言、励まし、称賛、人物像固定を行わない。
- 比喩の具体物ではなく、その比喩が示す関係を抽出する。

## 5. Prompt反復

### 5.1 `abstraction-only-v1`

初版はEntry / Line共通規則と、事実・診断・固定化の禁止を定義した。全件実行後、代表反復で次の3件が原文の単独状態を「孤独」と固定した。

| ID | v1代表出力 | 問題 |
|---|---|---|
| E026 | 孤独の静けさと自覚 | 「静かでよかった」「声が未共有」を孤独感へ固定 |
| L081 | 孤独の中の応答可能性 | 一人分の場を孤独感へ固定 |
| L086 | 孤独による感覚の近接 | 一人の夜を孤独感へ固定 |

また、L111の3反復のうち1件が「物質への一時的な環境の残留」となり、他2件と意味的に同等でなかった。事前基準は感情・人物像固定0件のためv1を見送った。

### 5.2 `abstraction-only-v2`

v1を上書きせず、次を追加した別Prompt・別Schemaとして作成した。

- 「一人」「誰にも会わない」「静けさ」「未共有」は、それだけで「孤独」「寂しさ」「孤立」を意味しない。
- 感情が明示されない限り、単独、静けさ、未共有など観察できる関係のまま表す。
- 小さな出来事への肯定的評価は、それだけで達成・成功を意味しない。

問題4件を各3回スモークした後、全156件を再実行した。代表出力は次のように改善した。

| ID | v2代表出力 |
|---|---|
| E026 | 静けさと声の未共有への気づき |
| L081 | 単独の場における応答の余地 |
| L086 | 単独の夜における音の近接 |
| E034 | 小さな出来事による一日の評価変化 |

## 6. 実行条件

| 項目 | 条件 |
|---|---|
| 生成Provider / model | OpenAI Responses API / `gpt-5.6-terra` |
| 推論設定 | low effort |
| 生成反復 | 156件×3回、計468回 |
| 最大出力 | 256 token |
| タイムアウト | 30秒 |
| 再試行 | 構造化出力不正、一時障害、timeoutに限り最大1回 |
| 意味類似度の診断 | OpenAI `text-embedding-3-small`、1,536次元 |
| Embedding入力 | 生成468表現＋baseline 156表現、計624表現を1回 |
| 為替換算 | 1 USD = 150円 |

実API前の最大計画は基本469リクエスト、全処理が1回再試行した場合938リクエスト、最大897.2442円で、Epicの5,000円上限内だった。

公式料金の参照先は[OpenAI GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra)と[OpenAI text-embedding-3-small](https://developers.openai.com/api/docs/models/text-embedding-3-small)である。

## 7. オフライン確認

Fixture / Fake Transportと自動テストで次を確認した。

- EntryとLineを同じ操作、Prompt、Schemaへ渡す。
- Schema versionと出力長をRuby側でも検証する。
- 外部APIは`--allow-external-api`なしでは実行できない。
- `plan-abstraction`は外部通信せず、件数、再試行込み上限、最大費用を返す。
- 出力件数不足、版不一致、未知IDを一次評価適用時に拒否する。
- 代表反復とレビュー状態を版付きデータへエクスポートできる。
- 通常ログとGit管理するテレメトリに入力本文、Prompt全文、APIレスポンス全文、APIキーを残さない。

## 8. 実API結果

| 指標 | v1 | v2 |
|---|---:|---:|
| 対象 | 156件 | 156件 |
| 生成実行 | 468 | 468 |
| 再試行込みリクエスト | 468 | 468 |
| 初回Schema成功率 | 100% | 100% |
| 再試行成功 | 0 | 0 |
| 文字列完全一致率 | 14.74% | 13.46% |
| pairwise cosine平均 | 0.8363 | 0.8299 |
| cosine 0.85以上のID率 | 35.90% | 35.26% |
| 最小cosine | 0.3561 | 0.3744 |
| 出力文字数最小 / p50 / p95 / 最大 | 5 / 12 / 16 / 18 | 7 / 13 / 16 / 22 |
| p50 | 1.342秒 | 1.439秒 |
| p95 | 2.628秒 | 3.399秒 |
| 最大 | 6.788秒 | 6.564秒 |
| 生成費用 | 82.2951円 | 102.6027円 |
| 意味診断Embedding費用 | 0.0269円 | 0.0278円 |
| 全件比較費用 | 82.3220円 | 102.6305円 |

文字列完全一致は低いが、これは短い日本語の言い換えをすべて不一致にする診断値である。Embedding cosineも、明らかに同じ関係の表現で低値になる例があったため、自動合否には使わず、0.85未満をCodex確認へ回すtriageに限定した。

## 9. Blind一次評価

各IDの第1反復とbaselineをA / Bへ固定seedで入れ替え、Provider、モデル、baseline / 候補の配置を隠して全156組をCodexが評価した。配置は全項目の確認後に開示した。第2・第3反復は3表現の意味的同等性評価に使った。

Codex一次評価は人間評価と区別して`judge=codex_preliminary`として保存した。低確信、方式間の致命的な割れ、致命的違反だけを人へ回す規則を適用した結果、人確認対象は0件だった。

### 9.1 代表表現

| 指標 | baseline | v2候補 |
|---|---:|---:|
| 評価件数 | 156 | 156 |
| 利用可能率（2以上） | 99.36% | 100% |
| 平均利用可能性（1〜3） | 2.9295 | 2.9744 |
| 利用困難（1） | 1 | 0 |
| 条件付き（2） | 9 | 4 |
| 利用可能（3） | 146 | 152 |
| 抽象度一致率 | 99.36% | 100% |
| 原文にない数量・人物・物・出来事・因果 | 0 | 0 |
| 診断・感情や人物像固定・不要な固有名詞 | 0 | 0 |
| 具体性の保持過多 | 0 | 2 |
| 意味削減 | 10 | 1 |

候補の条件付き4件はE017、E035、L078、L115である。

- E017：戻りたいという記述を「後悔」と抽象化しており、利用可能だが感情ラベルは境界的。
- E035：景色の変化は保持するが、距離感の変化を削っている。
- L078：「物理的到来」という表現が硬く、比喩を残しすぎる。
- L115：閉店後の暗さと帰路を保持し、検索表現として具体性がやや高い。

これらは致命的違反ではないが、後続の検索結果で候補集合を歪めないかID単位で追跡する。

### 9.2 3反復の意味的同等性

| 指標 | v2候補 |
|---|---:|
| 意味的に同等 | 156 / 156 |
| 意味的同等率 | 100% |
| 高確信 | 145 |
| 中確信 | 11 |
| 低確信 | 0 |
| 人確認対象 | 0 |

cosine値が低い例でも、E026の「静けさと声の未共有への気づき」「他者不在と自己内の声の認識」「静かな単独時間と声の未共有」のように、同じ関係を別語彙で表していた。数値だけで不一致とせず実表現を確認した。

## 10. Entry / Lineの実行分離

| 指標 | Entry | Line |
|---|---:|---:|
| ID数 | 36 | 120 |
| 生成実行 | 108 | 360 |
| p50 | 1.414秒 | 1.450秒 |
| p95 | 3.685秒 | 3.273秒 |
| 最大 | 4.476秒 | 6.564秒 |
| 生成費用 | 24.0624円 | 78.5403円 |

Line 120件の生成は事前処理であり、投稿時レイテンシや1投稿費用へ含めない。投稿時はEntry abstractionを1回生成する想定で、今回の平均実測費用は約0.2228円だった。実際の統合費用はIssue #25でSAFETYとEntry Embeddingを接続して再計測する。

## 11. 採用基準との対応

| 基準 | v2結果 | 判定 |
|---|---:|---|
| 初回Schema成功率99%以上 | 100% | 達成 |
| 1回再試行後Schema成功率100% | 100% | 達成 |
| 原文にない具体的事実 | 0件 | 達成 |
| 診断・感情や人物像固定・不要な固有名詞 | 各0件 | 達成 |
| Blind利用可能率90%以上 | 100% | 達成 |
| 3回の意味的同等率85%以上 | 100% | 達成 |

全事前基準を満たしたため、`abstraction-only-v2`をIssue #22のEmbedding候補集合比較へ渡す。

## 12. 版付き成果物

採用候補は`data/abstractions/abstraction_only_v2.yml`へ、Entry 36件、Line 120件を同じID順で保存した。本文、themes、structureは含めず、source type、元のLine状態、代表abstraction、レビュー状態、利用可能性だけを持つ。

| 成果物 | SHA-256または識別子 |
|---|---|
| Prompt v2 | `79c2cf9feaab5b7fe3a798fe45f0c5a3aac38d81fe6552911ac040ca38d75381` |
| Schema v2（正規化JSON） | `4f3138b41511817b741f8c8fbf3f2e365bafb53b6fb001e6f1505385d0649403` |
| 採用候補データ | `2617134aa9f09ed08f594983910528112e462747d92bfaf3e697e420cf393c08` |
| Codex一次評価 | `reviews/abstraction_only_v2_codex_preliminary.yml` |

各実行の生出力、テレメトリ、Blind mapping、一次評価サマリーは`results/abstraction_<version>_<timestamp>_<suffix>/`へ保存し、Git管理しない。

## 13. 費用

全件比較はv1が82.3220円、v2が102.6305円だった。v1のEntry / Lineスモーク1.0326円、v2の問題4件スモーク2.6558円を含むIssue #21の外部API総費用は188.6409円である。外部API到達前に停止した契約エラーとFixtureは0円だった。

Issue #20までの251.6394円と合わせても、Epic #27の累積は440.2803円で、5,000円上限内である。

## 14. 再現方法

通信なしの計画を確認する。

```powershell
bundle exec ruby bin\ai_line_selection plan-abstraction `
  --version abstraction-only-v2 `
  --provider openai `
  --embedding-provider openai-small `
  --repetitions 3
```

実API比較を実行する。

```powershell
bundle exec ruby bin\ai_line_selection compare-abstraction `
  --version abstraction-only-v2 `
  --provider openai `
  --embedding-provider openai-small `
  --repetitions 3 `
  --allow-external-api
```

一次評価を適用し、版付き成果物を出力する。

```powershell
bundle exec ruby bin\ai_line_selection apply-abstraction-preliminary `
  --results results\abstraction_abstraction_only_v2_<timestamp>_<suffix> `
  --judgments reviews\abstraction_only_v2_codex_preliminary.yml `
  --export data\abstractions\abstraction_only_v2.yml
```

## 15. 未決定事項

- abstraction-only入力によるEmbedding候補集合の品質、Top N、閾値。
- 条件付き4件と具体性保持過多2件が検索順位へ与える影響。
- 実利用分布、長文、複数の意味関係、表記揺れ、多言語での再評価。
- 本番Provider、モデル、Prompt、Schema、timeout、再試行方針。
- Line更新時の事前生成・人間レビュー・Embedding更新の運用。
- Rails / React Nativeへの組み込み。

本PoCはLine本文を自由生成せず、既存Lineの検索キー候補だけを生成する。
