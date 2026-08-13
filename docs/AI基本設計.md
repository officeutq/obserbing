# obserbing AI基本設計

**文書ステータス：基本設計（初回PoC結果反映）**

**作成日：2026年8月12日**

---

# 1. 目的

本書は、obserbingの要件をAI、Embedding、RailsおよびPostgreSQLによってどのように実現するかを定義する。

本書が扱うのは、AI処理の構成、責務分担、処理フロー、障害時の制御、運用、PoCおよびモデル選定方針である。プロダクトの人格、体験、禁止事項およびデータ保持要件そのものは再定義しない。

AIの目的は、ユーザーへ自由文章を生成することではなく、日記の意味を限定的に理解し、登録済みLineの中から適切な距離を持つ候補を評価することである。最終判断と状態変更はRailsが担う。

---

# 2. 上位ドキュメントとの関係

本書の上位仕様は次の2文書とする。

- [README](../README.md)：プロジェクト概要と技術構成の方針
- [要件定義書](要件定義_v1_0.md)：プロダクトが実現すること、守る要件および制約

要件と本書の役割は次のとおり分離する。

| 文書 | 主な責務 |
|---|---|
| README | プロジェクトと技術構成の概要 |
| 要件定義書 | What / Why、プロダクト要件、禁止事項、受入条件 |
| 本書 | How、AI処理方式、Railsとの責務分担、運用・PoC方針 |

次の事項は要件定義書を正とし、本書では実現方式だけを扱う。

- obserbingの人格、基本原則、最上位要件
- Lineの再利用およびMeaning Clusterの直近利用に関する条件
- obserbing distance、SAFETYおよびSILENCEのプロダクト上の意味と対象条件
- Gap、Coverage、Distance、Diversityおよび余白の要件
- Privacy by Design、削除、匿名集計の要件
- AI生成Lineに対するHuman in the Loop

上位文書と本書に矛盾がある場合は上位文書を優先し、本書を更新する。

---

# 3. AIアーキテクチャ概要

AI処理を、応答特性と責務が異なる次の3系統に分離する。

1. **リアルタイムLLM**：投稿リクエスト内でSAFETY判定、Meaning Structure抽出、Line候補評価を行う。
2. **Embedding**：Meaning StructureとLineをベクトル化し、意味的な候補絞り込みやGap集約を補助する。
3. **バッチLLM**：Gap分析やLine Candidate生成など、ユーザーを待たせない処理を非同期に行う。

Railsは全処理のオーケストレーターであり、AIへの入力を組み立て、出力を検証し、禁止条件と状態遷移を適用して、結果を確定する。AI Providerへ直接接続するのはRails側のAdapterだけとし、React NativeからAI APIを呼び出さない。

```mermaid
flowchart TB
    Mobile["React Native / TypeScript"] -->|"REST JSON"| Rails["Rails API"]
    Admin["Rails管理画面"] --> Rails

    subgraph AI["AI処理"]
        RT["リアルタイムLLM<br/>SAFETY・意味抽出・候補評価"]
        EMB["Embedding<br/>候補検索・類似判定"]
        BATCH["バッチLLM<br/>Gap分析・Candidate生成"]
    end

    Rails --> RT
    Rails --> EMB
    Rails --> BATCH
    Rails --> DB[("PostgreSQL")]
    EMB -. "候補：pgvector" .-> DB
    BATCH --> Admin
```

PostgreSQL上のベクトル検索には`pgvector`を有力候補とするが、採用はPoCおよび詳細設計で確定する。バックグラウンドジョブの実行基盤もRailsのジョブ抽象を介し、具体製品は本書では決定しない。

---

# 4. AIとRailsの責務分担

## 4.1 基本原則

- **AI**：自然言語の意味理解、曖昧さを含む分類・評価、候補への相対的なスコア付けを担う。
- **Rails**：認証、利用権、明確な禁止条件、状態管理、入力・出力検証、永続化、最終決定を担う。

AI出力は事実や命令ではなく、検証が必要な評価値として扱う。AIにDB更新、公開状態の変更、利用権判定を直接行わせない。

## 4.2 責務一覧

| 処理 | AI | Rails | 理由 |
|---|---|---|---|
| 日記の意味理解 | Meaning Structure候補を抽出 | スキーマ検証、保存可否を判断 | 自然言語理解はAI向きだが、保存形式はシステム契約であるため |
| SAFETY | 構造化された判定候補を返す | 不正・判定不能を含めて分岐を確定 | 高リスク分岐を未検証の出力だけで確定しないため |
| Line候補の意味評価 | 複数軸をスコアリング | 候補集合を制限し、最終候補を確定 | AIに禁止候補を選択させないため |
| 利用プラン・投稿上限 | なし | 判定・同時実行制御 | 明確な業務ルールであるため |
| Lineの状態 | なし | Candidate / Approved / Retiredを管理 | 公開状態は監査可能な状態遷移であるため |
| 再利用・直近利用制御 | なし | 要件定義書の条件を適用 | 正確な履歴照合が必要なため |
| SILENCE | 通常候補の不成立を示す評価材料 | SILENCEへの分岐と文言を確定 | SILENCEはシステム上の最終応答であるため |
| Entry / TRACE / Gap保存 | なし | トランザクションで保存 | 整合性と削除要件を保証するため |
| Candidate生成 | 候補本文と付随評価を生成 | Candidateとして保存し、公開しない | Human in the Loopを強制するため |
| 認証・課金・権限 | なし | 全て担当 | AIに権限判断を委ねないため |

---

# 5. リアルタイムLLM

## 5.1 責務

リアルタイムLLMは、投稿リクエストの応答時間内で次を行う。

- SAFETY分類
- Meaning Structure抽出
- RailsとEmbeddingが絞り込んだLine候補の評価
- obserbing distanceに関する複数軸のスコアリング

Line本文の自由生成は行わない。通常応答として返せるのは、Railsが許可したApproved LineのIDに限る。

## 5.2 設計方針

- 処理種別ごとに入力・出力スキーマを分離する。
- 構造化出力を利用し、Railsで型、必須項目、列挙値、数値範囲、候補IDを検証する。
- プロンプト、スキーマ、評価ロジックにはそれぞれバージョンを持たせる。
- 温度等の生成パラメータは処理別設定とし、PoCで決定する。
- 同じ投稿の再送ではIdempotency Keyを用い、異なるLineを返したり二重保存したりしない。
- プロバイダーやモデルの選定は設定に閉じ込め、ドメイン処理から具体名を参照しない。

## 5.3 呼び出し回数の初期案

通常投稿では、次の4呼び出しを基本案とする。

1. SAFETY分類：1回
2. Meaning Structure抽出：1回
3. Embedding生成：1回
4. Line候補一括評価：1回

SAFETY対象と確定した場合は1回で終了する。候補ごとにLLMを呼び出さず、許容件数の候補を1リクエストで評価する。

SAFETY分類とMeaning Structure抽出の統合は呼び出し回数を削減できる一方、失敗原因の分離、タイムアウト制御、スキーマの単純性を損なう可能性があるため、PoCの比較項目とする。

---

# 6. Embedding

## 6.1 用途

Embeddingは最終決定ではなく、広い候補集合を意味的に絞り込むために用いる。

- Entry由来のMeaning Structureのベクトル化
- Approved Lineのベクトル化
- Line候補の近傍検索
- GapEventの類似判定とGapCluster形成の補助
- Meaning Cluster形成の補助

## 6.2 ベクトル化対象

日記原文をそのまま検索キーとして保存するのではなく、原則として、Meaning Structureから生成した検索用の正規化テキストをEmbedding対象とする。これにより、固有名詞等の私的情報を減らし、表層語より意味構造へ検索を寄せる。

ただし、原文、Meaning Structureおよび両者の組み合わせのどれがLine選択品質に優れるかはPoCで比較する。いずれの場合も、Entry由来のベクトルは個別ユーザーデータとして削除対象に含める。

## 6.3 Line Embeddingのライフサイクル

- HumanまたはAI Candidateとして作成した時点では、通常検索へ公開しない。
- Approvedへの変更時、または検索対象フィールドの更新時にEmbeddingを生成する。
- 検索時はDB条件でも`Approved`だけに限定する。
- Retiredへ変更した時点で通常検索から除外する。過去TRACEが参照するLineは維持する。
- Embeddingにはモデル識別子とベクトル生成バージョンを関連付ける。
- モデル変更時は再計算ジョブを実行し、新旧ベクトルの切り替えを完了するまで検索バージョンを混在させない。

## 6.4 検索基盤

PostgreSQLと`pgvector`による近似近傍検索を第一候補とする。データ量、検索精度、インデックス更新、運用負荷をPoCで確認し、必要な場合にのみ外部ベクトルDBを比較する。

---

# 7. バッチLLM

## 7.1 責務

バッチLLMはユーザーの同期応答から切り離し、次を行う。

- GapCluster単位の不足領域分析
- Coverage、Distance、Diversity、SILENCE傾向の解釈補助
- Lineライブラリの偏り分析
- 管理者レビュー用のLine Candidate生成

## 7.2 実行方針

- Railsのジョブとして冪等に実行できる単位へ分割する。
- 集約対象期間、GapCluster、使用モデル、プロンプトバージョンを実行記録へ残す。
- 同一対象・同一バージョンの重複実行を防止する。
- 個々の日記原文をバッチLLMへ渡さず、削除可能なMeaning Structureまたは十分に匿名化された集約情報を使用する。
- 生成物は必ずCandidateとして保存し、自動でApprovedへ遷移させない。

分析は「集約対象期間 × GapCluster」、Candidate生成は「GapCluster × 生成バージョン」を基本的な実行単位候補とする。バッチの頻度、対象件数、入力データの匿名化境界およびCandidate生成数は詳細設計で決定する。

---

# 8. 日記投稿時の処理フロー

## 8.1 シーケンス

```mermaid
sequenceDiagram
    actor User as User
    participant App as React Native
    participant API as Rails API
    participant AI as AI Adapter
    participant Vec as Embedding / Vector Search
    participant DB as PostgreSQL

    User->>App: 日記を投稿
    App->>API: POST Entry（Idempotency Key付き）
    API->>DB: 認証・利用権・投稿枠を確認／予約
    DB-->>API: 投稿試行を許可
    API->>AI: SAFETY分類
    AI-->>API: 構造化判定

    alt SAFETY対象
        API->>API: 固定SAFETY応答を選択
        Note over API,DB: SAFETY時のEntry・TRACE保存と投稿件数は詳細決定前
        API-->>App: 固定SAFETY応答
    else 通常
        API->>AI: Meaning Structure抽出
        AI-->>API: 構造化Meaning
        API->>Vec: Meaning Embedding生成・候補検索
        Vec-->>API: Approved Line候補
        API->>DB: 再利用・状態・直近利用条件で除外
        DB-->>API: 評価可能な候補
        API->>AI: 候補を一括評価
        AI-->>API: 候補別スコア
        API->>API: 検証・最終決定
        alt 適切な候補あり
            API->>API: Lineを確定
        else 適切な候補なし
            API->>API: SILENCEを確定
        end
        API->>DB: 最終トランザクションで保存
        DB-->>API: 保存完了・投稿件数確定
        API-->>App: ONE LINE
    end
    App-->>User: 結果表示
```

## 8.2 処理別設計

| # | 処理 | 担当 | 主な入力 | 主な出力 | 実行 | 保存 | AI呼出し |
|---:|---|---|---|---|---|---|---:|
| 1 | 入力・認証検証 | Rails | Credential、日記、Idempotency Key | 正規化済み入力 | 同期 | なし | 0 |
| 2 | 投稿枠確認・予約 | Rails | Account、Plan、当日利用状況 | 投稿試行の許可 | 同期 | 本文を含まない予約メタデータ候補 | 0 |
| 3 | SAFETY分類 | リアルタイムLLM + Rails | 日記原文、分類スキーマ | normal / safety / indeterminate | 同期 | 最終確定までメモリ上 | 1 |
| 4 | Meaning抽出 | リアルタイムLLM + Rails | 日記原文、抽出スキーマ | Meaning Structure | 同期 | 最終確定までメモリ上 | 1 |
| 5 | Embedding生成 | Embedding Adapter | 検索用Meaning | ベクトル | 同期 | 最終確定までメモリ上 | 1 |
| 6 | Line近傍検索 | Rails + Vector Search | ベクトル、Approved条件 | Line候補集合 | 同期 | なし | 0 |
| 7 | 禁止候補除外 | Rails | 候補、利用履歴、状態 | 評価可能候補 | 同期 | なし | 0 |
| 8 | 候補評価 | リアルタイムLLM + Rails | Meaning、候補Line | 候補別評価JSON | 同期 | 最終確定までメモリ上 | 1 |
| 9 | Line / SILENCE確定 | Rails | 検証済み評価、設定 | 応答対象、Gap理由 | 同期 | なし | 0 |
| 10 | 保存・件数確定 | Rails | Entry、Meaning、Embedding、応答、分析情報 | TRACE等 | 同期 | 1トランザクション | 0 |
| 11 | Gap集約 | Rails Job | 保存済みGapEvent | GapCluster・集計 | 非同期 | 集約結果 | 別途 |

通常系のAI API呼び出しは初期案で合計4回、SAFETY系は1回である。リトライは別カウントとし、コスト計測へ含める。

## 8.3 保存と投稿件数の整合性

外部AI APIの待機中にDBトランザクションを保持し続けない。並行投稿による上限超過を防ぐため、本文を含まない短命な「投稿枠予約」を概念として設ける案を採用する。

1. 短いトランザクションで投稿枠を確認し、Idempotency Keyに対する予約を作る。
2. AI処理はトランザクション外で行う。
3. 成功時に短い最終トランザクションでEntry、Meaning Structure、Embedding、TRACE、必要なGapEventを保存し、予約を投稿済み件数へ確定する。
4. 失敗時は予約を解放または期限切れにし、投稿済み件数を増やさない。

最終トランザクションが失敗した場合は全てをロールバックし、投稿済み件数を増やさない。保存完了後にクライアントとの通信だけが失敗した場合は、同じIdempotency Keyへの再送に保存済みの同一結果を返し、AI再実行と二重計上を防ぐ。

予約を専用テーブル、ロックまたは別方式のどれで実装するかはDB詳細設計へ送る。

---

# 9. Meaning Structure

## 9.1 役割

Meaning Structureは、日記原文を表示用に再表現するものではなく、検索と評価に必要な意味構造を限定的に表す中間データである。

| 概念 | 役割 |
|---|---|
| 日記原文 | ユーザーが書いた一次情報。TRACE表示の正本 |
| Meaning Structure | Entry単位の意味構造。検索・評価の中間表現 |
| Theme | Line等へ付与する比較的粗い分類・編集メタデータ |
| Meaning Cluster | 類似するMeaning StructureやGapを束ねる集合 |

Meaning StructureはAI出力であっても個別ユーザーデータであり、匿名集計とは扱わない。Entryまたはアカウント削除時には、関連Embeddingおよび個別GapEventとともに削除する。

## 9.2 利用方法

- リアルタイム検索：検索用テキストを組み立て、Embeddingを生成する。
- Line評価：日記原文の露出を必要最小限にするため、候補評価では原則Meaning Structureを使用する。原文が必要な評価項目はPoCで確認する。
- Gap分析：個別GapEventの特徴量として利用し、その後GapClusterへ集約する。
- 監査・再現：スキーマ、プロンプト、モデルの各バージョンを関連付ける。

## 9.3 構造例

次は検討用の例であり、確定スキーマではない。

```json
{
  "schema_version": "draft-1",
  "themes": ["選択", "不確実性"],
  "structure": "選択によって別の可能性を失うことへのためらい",
  "abstraction": "決定と喪失可能性の同居"
}
```

診断、感情の断定、人物像の固定化、不要な固有名詞の保持を避ける。必須項目、最大長、列挙値および多値表現はPoC後の詳細設計で確定する。

---

# 10. Line候補検索

## 10.1 多段階検索

大量のLineを毎回LLMへ渡さず、次の順で候補を削減する。

```mermaid
flowchart LR
    All["Approved Line集合"] --> Vector["Embedding近傍検索"]
    Vector -->|"PoC初期値：50〜100件程度"| Rules["Rails禁止条件フィルター"]
    Rules -->|"LLM投入上限内"| Eval["LLM一括評価"]
    Eval --> Final["Rails最終決定"]
    Final --> Line["Line"]
    Final --> Silence["SILENCE"]
```

件数は性能要件ではなくPoC開始時の仮値であり、品質、トークン量、応答時間およびコストを見て決定する。

PoCの初期案では、Embedding検索で50〜100件程度を取得し、Railsの禁止条件適用後に最大20〜50件程度をLLMへ渡す。条件適用後の件数が上限未満なら残った候補だけを渡す。最終値は固定せず、正解候補の再現率とリアルタイム性能の両方で決める。

## 10.2 検索条件

- 検索クエリとDB条件の両方でApprovedのみを対象にする。
- Candidateは管理画面のレビュー対象であり、通常検索インデックスへ含めない。
- Retiredは通常検索から除外し、過去TRACEからの参照だけを維持する。
- Railsで要件定義書の再利用、直近利用、状態およびその他の禁止条件を適用してからLLMへ渡す。
- LLMへ渡す候補IDはRailsが発行した許可リストと照合し、リスト外IDを無効とする。

Embedding類似度は「意味が近い」ことを示すが、「近すぎない」「余白がある」「obserbingらしい」ことを保証しない。そのため類似度だけでは最終決定せず、LLMの複数軸評価とRailsのルールを組み合わせる。

---

# 11. obserbing distance評価

obserbing distanceの意味と品質要件は要件定義書を参照する。本書では、候補ごとの曖昧な評価をLLMが構造化し、Railsが検証・集約する方式を採る。

## 11.1 評価軸候補

- `relevance`：Meaning Structureとの意味的接続
- `directness`：言い換え、回答、指示への近さ
- `space`：ユーザーが意味を接続できる余白
- `obserbing_fit`：人格・文体・禁止事項への適合

評価軸、尺度、重み、合格閾値はPoCで調整する。全ての軸で「高いほど良い」とは限らず、例えば`directness`は高すぎる候補を避けるために使う。

次は検討用の出力例であり、確定スキーマではない。

```json
{
  "schema_version": "draft-1",
  "candidates": [
    {
      "line_id": 123,
      "relevance": 0.72,
      "directness": 0.31,
      "space": 0.86,
      "obserbing_fit": 0.91
    }
  ]
}
```

Railsは候補ID、重複、欠落、数値範囲およびスキーマバージョンを検証し、禁止条件を再確認した後、設定で管理する選択式により最終候補を決める。合格候補がなければSILENCEへ分岐する。

## 11.2 最終決定方式の比較

| 方式 | メリット | デメリット |
|---|---|---|
| AIが最終決定 | 実装が単純で、文脈をまとめて判断しやすい | 禁止条件、説明可能性、再現性、異常出力への統制が弱い |
| Railsが全て決定 | 再現性と監査性が高い | 曖昧な距離感を固定式だけで表すことが難しい |
| AIが評価しRailsが最終制御 | 意味評価とルール統制を分離できる | スコア設計とPoCが必要 |

現在方針として、3つ目の構成を採る。

---

# 12. SAFETY処理

SAFETYの対象条件と表示要件は要件定義書を正とする。

## 12.1 処理位置

SAFETY分類は、投稿上限確認後、Meaning Structure抽出およびLine検索より前に行う。対象時に不要な検索や通常Line選択を停止し、日記原文を追加のAI処理へ送る範囲を最小化するためである。

## 12.2 構造化判定

判定結果は少なくとも次を区別できる構造とする。

- `normal`
- `safety`
- `indeterminate`

分類理由は自由文章ログに残さず、必要な場合は限定された理由コードとして扱う。Railsはスキーマ、列挙値、信頼度表現および処理バージョンを検証する。

## 12.3 分岐と失敗

- `safety`：通常Line検索とSILENCEを停止し、サーバー管理の固定応答へ分岐する。
- `normal`：Meaning Structure抽出へ進む。
- `indeterminate`、JSON不正、タイムアウト、API失敗：通常Line選択へ進めない。

判定不能をSILENCEへ置き換えると、SAFETY判断を回避したまま通常体験を完了させることになるため採用しない。同期処理を技術エラーとして終了する初期方針とし、ユーザー向け文言、投稿枠の扱い、再試行導線はプロダクト判断を含むため未決定事項とする。

固定SAFETY応答はAI生成せず、Rails側で内容とバージョンを管理する。固定文言そのものは別途策定する。

---

# 13. SILENCEフォールバック

SILENCEの意味、文言方針およびTRACE上の扱いは要件定義書を参照する。

Railsは、SAFETY分類、Meaning抽出、Embedding検索、禁止条件除外および候補評価が正常終了したうえで、適切な通常Lineが成立しない場合にSILENCEを選択する。

主な技術的分岐理由は次のとおりとする。

- 検索候補がない。
- 禁止条件適用後の候補がない。
- 候補はあるが、検証済み評価が合格条件を満たさない。
- 評価結果に選択可能な候補IDがない。

外部API障害や不正JSONは「意味的に適切なLineがない」状態ではないため、原則としてSILENCEへフォールバックしない。障害をSILENCEとして集計するとGap分析も汚染するため、技術エラーと意味的な不成立を別の理由コードで管理する。

SILENCEの選択はRailsが行い、発生時は削除可能な個別GapEventへ理由を記録する。SILENCE文言の選択方法と再利用制御は詳細設計へ送る。

---

# 14. Gap改善サイクル

## 14.1 処理全体

```mermaid
flowchart TB
    Event["GapEvent<br/>個別・削除可能"] --> Aggregate["Embedding類似判定・集約"]
    Aggregate --> Cluster["GapCluster"]
    Cluster --> Analyze["Coverage / Distance / Diversity<br/>SILENCE傾向の分析"]
    Analyze --> Need["不足領域判定"]
    Need --> Batch["バッチLLM"]
    Batch --> Candidate["Line Candidate"]
    Candidate --> Admin["管理画面"]
    Admin --> Review{"人間によるレビュー"}
    Review -->|"採用"| Approved["Approved Line"]
    Review -->|"修正して採用"| Edited["修正Line"]
    Edited --> Approved
    Review -->|"却下"| Rejected["却下記録"]
    Approved --> Embed["Line Embedding生成"]
    Embed --> Search["通常検索対象へ反映"]
```

## 14.2 リアルタイムとバッチの境界

リアルタイム処理では、Line不成立の事実と理由を個別GapEventとして記録するところまでを行う。類似Gapの集約、傾向分析、不足領域判定およびCandidate生成はバッチで行い、投稿応答を待たせない。

GapEventには、原文ではなく、検索に用いたMeaning Structure参照、Embedding参照、候補件数、除外後件数、最良評価、SILENCE理由等の必要最小限を保持する。Entry削除時は個別GapEventも削除する。

GapClusterや統計を個人へ再結合できない集計情報として残すための匿名化条件は、要件定義書に従って詳細設計する。単にAccount IDを外しただけの個別データは匿名集計とみなさない。

## 14.3 Candidateと承認

- バッチLLMの出力はスキーマ検証後もCandidateとしてのみ保存する。
- 管理者が採用、修正して採用、却下を行う。
- 承認操作を監査ログへ記録する。
- Approved遷移後にEmbeddingを生成し、生成成功後に通常検索へ反映する。
- Candidate生成とApproved公開を同一ジョブで行わない。

---

# 15. AI Provider Adapter

## 15.1 目的

Railsのドメイン処理を特定ProviderのSDK、モデル名、リクエスト形式およびエラー形式から分離する。処理用途ごとにAdapterインターフェースを定義し、設定でProviderとモデルを切り替える。

責務の分割例を次に示す。

```text
Ai::SafetyClassifier
Ai::MeaningExtractor
Ai::LineEvaluator
Ai::EmbeddingClient
Ai::CandidateGenerator
```

各インターフェースは、Provider固有のレスポンスではなく、アプリケーション共通の型付き結果または共通エラーを返す。

## 15.2 共通契約

Adapterは次を吸収する。

- 認証とAPIエンドポイント
- Provider固有の構造化出力指定
- タイムアウト、Rate Limit、5xx等のエラー正規化
- Token使用量、Request ID、モデル識別子の取得
- 共通スキーマへの変換
- Provider別の料金計算に必要な利用量

用途ごとの設定は、例えば`real_time.safety`、`real_time.meaning`、`real_time.line_evaluation`、`embedding`、`batch.candidate_generation`のように独立させる。同じProviderまたは同じモデルを使うことを前提にしない。

自動的な別Providerへの切り替えは、日記が新たな第三者へ送信されること、出力差、重複課金を伴う。利用規約、データ保持方針、運用承認を満たすProviderだけを事前設定し、処理別の切替条件を明示する。無条件の自動フォールバックは採用しない。

---

# 16. エラー・タイムアウト

## 16.1 基本方針

- 同期処理にはリクエスト全体の時間予算と、AI呼び出し単位のタイムアウトを設ける。
- 同期リトライは時間予算内で原則1回までの初期案とし、具体値はPoCで決定する。
- バッチ処理は指数バックオフとジッターを用い、最大試行回数を設定する。初期案は合計3回とする。
- リトライ可能性を共通エラー種別で表し、同じIdempotency Keyによる二重保存を防ぐ。
- 外部API障害を意味的なSILENCEとして処理しない。

## 16.2 エラー別の初期方針

| エラー | 同期リトライ | 同期処理 | SILENCE可否 | 備考 |
|---|---|---|---|---|
| タイムアウト | 時間予算内で1回候補 | 中止 | 不可 | Provider処理が継続している可能性を考慮 |
| 5xx | 1回候補 | 再失敗で中止 | 不可 | サーキットブレーカーを検討 |
| Rate Limit | `Retry-After`が時間予算内なら1回候補 | 超過時は中止 | 不可 | 利用量アラート対象 |
| JSON不正 | 同一処理を1回再要求する候補 | 再失敗で中止 | 不可 | Railsで厳格に検証 |
| 必須フィールド欠落 | JSON不正と同じ | 再失敗で中止 | 不可 | 欠落を補完して推測しない |
| SAFETY判定不能 | 原則1回まで | 通常処理へ進めず中止 | 不可 | 固定SAFETY応答へも自動分岐しない |
| Meaning抽出失敗 | 1回候補 | 中止 | 不可 | 不正なMeaningで検索しない |
| Embedding失敗 | 1回候補 | 中止 | 不可 | 未検証のキーワード検索へ自動退避しない |
| Line評価失敗 | 1回候補 | 中止 | 原則不可 | Rails単独選択はPoCで品質確認後に再検討 |

リトライ回数、タイムアウト秒数、サーキットブレーカー、ユーザー向けエラー表示およびクライアント再送方式は、PoC・API詳細設計で確定する。

---

# 17. AI利用ログ・監視

## 17.1 ログ方針

日記本文、Meaning Structure全文、AIへのプロンプト本文およびAIレスポンス本文を通常のアプリケーションログ、APM、例外通知へ出力しない。Provider SDKのデバッグログも本番では無効化またはマスキングする。

運用ログには、次のメタ情報だけを必要最小限で記録する。

- 内部Correlation ID / AI Request ID
- Provider、モデル識別子、処理種別
- プロンプト・スキーマ・Adapterのバージョン
- 開始時刻、処理時間、試行回数
- Input / Output TokenまたはEmbedding利用量
- 成功 / 失敗、正規化したエラー種別
- 検索候補件数、禁止条件適用後の候補件数
- 選択Line IDまたはSILENCE理由コード
- API料金推定値と料金表バージョン

AccountやEntryへ結び付けられる運用メタデータは個人へ再結合可能なデータとして扱い、削除連動または短期保持を設計する。保持期間、アクセス権、Line IDを含むログの粒度はセキュリティ・プライバシー詳細設計で確定する。

## 17.2 監視

処理種別、Provider、モデル別に次を集計する。

- 成功率、タイムアウト率、Rate Limit率
- JSONスキーマ検証失敗率
- p50 / p95 / p99応答時間
- SAFETY判定不能率
- Meaning抽出失敗率、Embedding失敗率、Line評価失敗率
- SILENCE率と技術エラー率（混同しない）
- 1投稿あたり呼び出し回数、Token量、推定コスト

急増、継続的な失敗、予算超過をアラート対象とする。具体的な閾値と監視サービスは運用設計で決定する。

---

# 18. コスト管理

AI呼び出しごとに利用量レコードを作り、投稿単位、日次、月次へ集計できる構成とする。本文は含めない。

最低限、次を計測する。

- 処理種別ごとの呼び出し回数とリトライ回数
- Input / Output Token
- Embedding対象量と呼び出し回数
- Provider / モデル / 料金表バージョン
- 呼び出し単位および投稿単位の推定コスト
- 日次・月次の合計と平均
- Plan別の投稿件数と推定AIコスト（個別本文なし）
- 異常な呼び出し回数、Token量、失敗リトライの検出

料金は変更されるため、利用時点の単価または料金表バージョンを保持し、後日の集計が現在の単価で変化しないようにする。サブスクリプション価格との採算判断は別文書で行う。

---

# 19. PoC

## 19.1 目的

アプリ全体を実装する前に、**obserbingの一行選定が技術的に成立するか**を検証する。

具体的には、Meaning Structure、Embeddingによる候補絞り込み、obserbing distance評価およびRails相当の最終制御を組み合わせたとき、品質・応答時間・安定性・コストが実用候補になるかを確認する。

## 19.2 データセット

- サンプル日記：30〜50件程度
- Line：100〜500件程度
- SAFETY評価用の独立したテストケース
- 同じ入力を複数回試す再現性評価ケース

サンプル日記は合成または本検証用に明示的に用意したデータを優先し、実ユーザーの日記を流用しない。

## 19.3 比較項目

| 系統 | 主な比較項目 |
|---|---|
| リアルタイムLLM | 日本語理解、SAFETY、Meaning抽出、Line評価、JSON成功率、応答時間、コスト |
| Embedding | 人間が期待する候補の再現率、順位、検索時間、ベクトルサイズ、コスト |
| バッチLLM | 不足領域の解釈、Candidate品質、多様性、レビュー負荷、コスト |

人間評価では、少なくとも「近すぎる」「ちょうどいい」「遠すぎる」「obserbingらしくない」を使用する。併せて、JSON出力成功率、p50 / p95応答時間、APIコスト、選択結果の再現性を測定する。

## 19.4 実施手順

1. 評価用日記、Line、期待する禁止候補、評価票を固定する。
2. 比較対象ごとに入力形式、出力スキーマ、候補集合を可能な範囲で揃える。
3. Meaning抽出だけ、Embedding検索だけ、候補評価だけを個別評価する。
4. 多段階フローを結合し、通常系、候補不足、SAFETY、外部API失敗を実行する。
5. 同じ条件を複数回実行し、品質と再現性を記録する。
6. モデル名を伏せた状態で複数人が結果を評価できる形を優先する。
7. 品質、レイテンシ、安定性、プライバシー条件、コストを総合して採用候補を決める。

## 19.5 採用判断

平均点だけでなく、致命的な禁止候補の選択、SAFETY見逃し、構造化出力失敗、遅延の裾、再現性の低さを個別に評価する。採用基準値はテスト実施前に決め、結果を見て都合よく変更しない。

PoCでは実接続用の本番実装、正式契約、DB migration、アプリUI実装および本番プロンプト確定を行わない。

初回PoCの実施結果と採用判断は[AI一行選定 PoC結果](AI_PoC結果.md)を参照する。

---

# 20. AIモデル選定基準

リアルタイムLLM、Embedding、バッチLLMを独立して評価する。

| 観点 | リアルタイムLLM | Embedding | バッチLLM |
|---|:---:|:---:|:---:|
| 日本語性能 | 重要 | 重要 | 重要 |
| Line選定品質 | 最重要 | 候補再現率として重要 | Candidate品質として重要 |
| SAFETY判定精度 | 最重要 | 対象外 | 補助評価のみ |
| 構造化JSON精度 | 最重要 | API形式の安定性 | 重要 |
| Embedding精度 | 対象外 | 最重要 | 対象外 |
| 応答速度 | 最重要 | 重要 | 優先度は相対的に低い |
| API料金 | 重要 | 重要 | 重要 |
| Rate Limit / 安定性 | 最重要 | 重要 | 重要 |
| データ保持・学習利用 | 必須条件 | 必須条件 | 必須条件 |
| APIの扱いやすさ | 重要 | 重要 | 重要 |
| 障害時の切替容易性 | 重要 | 重要 | 重要 |

Providerおよびモデル名は本書では確定しない。入力データがモデル学習へ利用されない契約・設定、保持期間、リージョン、削除・監査情報も機能品質と同等の選定条件とする。

## 20.1 初回PoC結果に基づく判断

2026年8月12日〜13日の実API PoCでは、SAFETYとMeaning StructureはOpenAI `gpt-5.6-terra`、EmbeddingはOpenAI `text-embedding-3-small`の1,536次元・Meaning Structure入力、Line評価はAnthropic `claude-sonnet-5`を個別PoC候補とした。バッチLLMは未評価であり、候補を選定していない。

これらを接続した`selected-v1`は、通常日記のSAFETY過剰遮断、Recall@20、選択安定性、同期レイテンシおよび致命的なLine誤選定が事前基準を満たさなかった。そのため、各候補は本番正式採用とせず、追加PoC後に再判定する。Adapter分離、構造化出力の二重検証、状態分離、ログ制限、Line Embeddingの事前計算とバージョン管理は維持する。

評価条件、計測値、失敗例、追加検証項目は[AI一行選定 PoC結果](AI_PoC結果.md)を正とする。

## 20.2 追加PoC結果に基づく判断

2026年8月13日の追加PoCでは、リアルタイムLine評価LLMを使わない`abstraction-only-v1`を検証した。SAFETY `additional-v3`、abstraction `abstraction-only-v2`、事実整合ガード`combined_v1`は個別基準を満たした。一方、abstraction EmbeddingはTop 20候補集合安定性、Ruby選択はBlind表示品質の基準を満たさなかったため、統合結果は`abstraction-only-v1-diagnostic`として扱う。

APIクレジット追加後のライブ診断統合では、既存通常日記のSAFETY過剰遮断0件、リアルタイムLine評価LLM 0回、1投稿約0.551円、p95 5.48768秒を実測した。しかし重要ケース補正後のBlind許容率74.07%、baseline差-22.81ポイント、致命的事実不整合1件、Top 20 Jaccard平均0.672で事前基準を満たさなかった。`selected-v1`も初回PoCの必須基準未達が残るため、どちらも現状のまま詳細設計候補または本番採用方式にしない。

Provider、モデル、契約、プロンプトおよび本番閾値は引き続き未決定とする。追加PoCで有効だった3要素は次方式の部品候補として保持するが、正式採用を意味しない。次方式を検証する場合は、候補集合の上流安定化と、低遅延のgroundedness / obserbing distance評価を別Epicで事前定義する。

評価条件、比較値、採否およびEpic完了判断は[AI追加PoC結果](AI_追加PoC結果.md)、ライブ実測の詳細は[Abstraction Only ライブ統合追補](Abstraction_Only_ライブ統合追補.md)を正とする。

---

# 21. 未決定事項

次はPoCまたは詳細設計で決定する。

- 採用するAI Provider、モデルおよび契約
- `pgvector`の正式採用、インデックス方式、外部ベクトルDB比較の要否
- Meaning Structureの確定スキーマ、最大長、正規化方式
- Meaning抽出・Line評価で日記原文をどこまで使用するか
- プロンプト本文、生成パラメータおよびスキーマの確定版
- Embedding対象、類似度方式、取得件数、LLM投入件数
- obserbing distanceの軸、重み、合格閾値、同点処理
- SAFETY分類スキーマ、判定閾値、固定応答文
- SAFETY応答時のEntry / TRACE保存方式と投稿件数の扱い
- SILENCEの具体文言、選択方式、再利用制御
- AI障害時のユーザー向け文言とクライアント再試行方式
- 同期タイムアウト、リトライ、サーキットブレーカーの具体値
- Provider間フォールバックの対象、条件、プライバシー上の承認
- GapEventの確定項目、GapCluster集約方式、匿名化境界
- バッチの実行基盤、頻度、単位、Candidate生成数
- AI利用ログの保持期間、アクセス権、削除連動範囲
- 投稿枠予約の具体的なDB・ロック方式

---

# 22. 詳細設計・PoCへ送る事項

## 22.1 追加PoCへ送る事項

- SAFETY境界データの拡充と通常日記の過剰遮断対策
- Meaning抽出結果からEmbedding検索までのRecall@20低下原因の分解
- 入力にない数量、状況、因果関係を持つLineの除外方式
- Line評価の低遅延モデル、候補数、二段階評価および非同期UXの比較
- 修正後の統合フローについてJSON成功率、応答時間、コスト、再現性を再計測
- 実データ規模を想定した`pgvector`の性能評価
- 不足領域抽出とCandidate生成を行うバッチLLMの独立評価
- 外部API障害時に品質を損なわない代替方式の可否

## 22.2 詳細設計へ送る事項

- AdapterのRubyインターフェース、共通結果型、共通エラー型
- APIエンドポイント、Idempotency Key、投稿枠予約、最終トランザクション
- DBテーブル、外部キー、削除カスケード、Embeddingバージョン移行
- ジョブの冪等性、再試行、排他、実行履歴
- 構造化JSON SchemaとRailsバリデーション
- 監視メトリクス、アラート、利用量・料金集計
- Providerの資格情報管理、通信・保存時の保護、監査

本書の確定後も、要件定義書に属するプロダクト要件を本書へ複製せず、実現方式から要件定義書を参照する形を維持する。
