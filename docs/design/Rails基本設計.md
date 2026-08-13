# Rails基本設計

**文書ステータス：現行基本設計**

**作成日：2026年8月14日**

**関連Issue：#67**

## 1. 文書の目的

本書は、obserbingの上位要件とAI基本設計をRails本実装へ接続するために、Railsアプリケーションの責務、境界および実装前に固定する基本方針を定義する。

本書では具体的なController名、Service Object名、Active Recordモデル、migration、ジョブ基盤およびコード構造までは確定しない。それらは本書の責務境界を維持したうえで詳細設計する。

## 2. 上位ドキュメントとの関係

文書の優先順位は[ドキュメント索引](../README.md)に従う。

- プロジェクト概要と技術方針：[ルートREADME](../../README.md)
- 上位要件：[要件定義書](../requirements/要件定義_v1_0.md)
- AI処理全体：[AI基本設計](AI基本設計.md)
- B-v2の現行処理骨格：[B-v2 AI選定基本設計](ai/B-v2_AI選定基本設計.md)
- AWS上の実行・運用基盤：[AWS基本設計](AWS基本設計.md)
- 開発運用：[AGENTS.md](../../AGENTS.md)。プロダクト仕様ではない

本書は上位要件とAI基本設計を変更しない。SAFETY、Line選定、SILENCEおよびAIの具体的な判断規則は、要件定義書とAI基本設計を正とし、本書で独自仕様を追加しない。

## 3. Railsアプリケーションの役割

Railsは、次を同一アプリケーション内で提供するサーバーサイドの正本とする。

- React Native / Expo向けREST JSON API
- 運営者向けRails Views / Hotwire管理画面
- 認証、利用権、投稿上限および状態遷移を含む業務ルール
- AI Provider、Embedding Providerその他の外部サービスを統括するAIオーケストレーター
- 入出力検証、LineまたはSILENCEの最終決定および永続化

React NativeからAI ProviderやEmbedding Providerへ直接接続しない。外部サービスの資格情報、Adapter、エラー正規化および利用量管理はRails側に閉じる。

## 4. モノレポ内でのRailsの位置づけ

obserbingは次の概念構成を持つモノレポとする。

```text
obserbing/
├─ backend/          # Ruby on Rails
├─ mobile/           # React Native / Expo
├─ poc/              # PoC・検証コード
├─ docs/             # 要件・設計・research等
├─ compose.yml       # ローカル開発環境
├─ README.md
└─ AGENTS.md
```

Railsアプリケーションはリポジトリルートではなく`backend/`へ置き、Railsから見たアプリケーションルートも`backend/`とする。React Native / Expoは`mobile/`へ置く予定とする。

`poc/`は本番Rails実装と分離して維持する。PoCコードの直接移植を前提にせず、上位仕様または現行設計へ正式採用された責務、方式および境界だけを本番実装へ反映する。

環境導入時の基準バージョンはRuby 4.0.6、Rails 8.1.3.1とし、`latest`等の可変指定を使わず具体版を固定する。

## 5. ディレクトリ構成

本書で固定する配置境界は次のとおりとする。

| 配置 | 役割 | Rails本番成果物との関係 |
|---|---|---|
| `backend/` | Railsアプリケーション、Rails用Dockerfile | Railsコンテナの原則的なビルド対象 |
| `mobile/` | React Native / Expoアプリケーション | RailsとはAPI契約を介して連携 |
| `poc/` | PoC・比較・検証コード | Rails本番コンテナへ含めない |
| `docs/` | 要件、設計、評価基準、調査履歴 | Rails本番コンテナへ含めない |
| `compose.yml` | ローカルのRails・PostgreSQL構成 | リポジトリルートへ置く |

`backend/`内部のレイヤー構成、名前空間およびファイル単位の配置は詳細設計で決める。本書はRailsの既定構成を不必要に崩すことも、特定のアーキテクチャパターンを先に固定することもしない。

## 6. React Native APIと管理画面の境界

| 境界 | React Native / Expo | Rails管理画面 |
|---|---|---|
| 提供方式 | REST JSON API | Rails Views / Hotwire |
| 主な利用者 | アプリ利用者 | 権限を持つ運営者 |
| 認証 | ネイティブアプリ向け認証契約 | 管理者向け認証・認可 |
| 表示責務 | WRITE、TRACE、設定、課金等の利用者体験 | Line、Candidate、Gap、運用状況等の管理 |
| AI接続 | 直接接続しない | Railsのサーバー側機能を経由する |

両者は同一Railsアプリケーションの業務データを扱うが、入口、認証方式、認可およびレスポンス形式を分離する。管理画面をネイティブアプリへ含めず、管理画面の日常的な分析では日記原文を表示しない。

管理画面の画面一覧、操作権限、監査対象および個別データへの例外的アクセス手順は詳細設計で決める。

## 7. API基本方針

- React Native向けAPIはREST JSONとする。
- API名前空間は`/api/v1`とする。
- 本番通信はHTTPSのみとする。
- ネイティブアプリはEC2のIPアドレスではなく、DNSで管理するAPIサブドメインを接続先とする。
- 破壊的な契約変更はAPI versioningにより管理し、既存アプリ版との互換性を考慮する。
- Railsは入力形式、認証・認可、状態遷移および外部処理の構造化出力をサーバー側で検証する。
- OpenAPIの管理方式、エンドポイント、HTTP status、エラー形式、Idempotency Keyおよびクライアント再送契約はAPI詳細設計で決める。

APIサブドメインの例は`https://obserbing-api.officeutq.co.jp/api/v1`とするが、実際のホスト名は未決定である。

## 8. Railsの責務

Railsが最終決定権を持つ責務は次のとおりとする。

- Account、端末資格情報および管理者の認証・認可
- Plan、Subscription Entitlementおよび一日投稿上限の判定
- Entry入力、文字数、状態およびAPI入出力の検証
- SAFETY処理の開始と結果検証。判定内容は上位設計に従う
- AI処理順序、Provider Adapterおよび外部障害の統括
- Approved状態、policy、履歴、再利用条件等の決定的な適用
- LineまたはSILENCEの最終決定
- Entry、Trace、投稿件数、個別分析データおよび必要な監査情報の永続化
- TRACE削除、アカウント削除および関連データ削除の整合性
- 利用量、費用、処理バージョンおよび本文を含まない運用メタデータの管理

主要な投稿ユースケースは次の順序を持つ。

```text
認証
↓
投稿可能判定
↓
SAFETY
↓
abstraction + domain
↓
Embedding
↓
Line候補検索
↓
Rails policy / 履歴条件
↓
LineまたはSILENCE確定
↓
Entry / Trace / 投稿件数等の永続化
```

SAFETY対象時、技術エラー時および正常処理後に候補がない場合の分岐は異なる。具体的な契約は要件定義書とAI基本設計に従う。

### 8.1 主要な概念モデル

次は要件を整理する概念であり、同名のActive Recordモデルや一対一のテーブルを確定するものではない。

| 概念 | 主な役割 |
|---|---|
| Account | 匿名アカウントと利用者データの帰属 |
| Device Credential | 有効端末の識別と引き継ぎ |
| Phone Recovery | 任意の電話番号認証と復旧 |
| Plan | 利用プランの定義 |
| Subscription Entitlement | ストア購入状態に基づく利用権 |
| Daily Post Usage | サーバー管理の一日投稿件数 |
| Entry | 入力された日記本文 |
| Trace | Entryと確定したLineまたはSILENCEの痕跡 |
| Line | 運営者が管理する一行と状態 |
| Silence Line | 候補不成立時に用いるSILENCE表現 |
| Meaning Structure | 個別分析に用いる意味構造の概念 |
| Meaning Cluster | 意味上の集約単位 |
| Gap Event | 個別の候補不成立事象 |
| Gap Cluster | 匿名化条件を満たすGapの集約単位 |
| Line Candidate | バッチ生成後、人間の承認前にある候補 |
| Aggregate Statistics | 個人へ再結合できない集計情報 |

実装時には、削除境界、更新整合性、アクセス頻度および監査要件からRailsモデル候補と永続化方式を決める。

## 9. AIサブシステムとの責務分担

[AI基本設計](AI基本設計.md)に従い、AIは分類・構造化・ベクトル生成等の限定された出力を返し、Railsが処理を統括する。

| AIサブシステム | Rails |
|---|---|
| SAFETYの構造化分類 | Schemaと状態を検証し、上位仕様どおり分岐する |
| abstraction + domain生成 | 版とSchemaを検証し、検索入力として管理する |
| Embedding生成 | 用途、件数、次元、モデル・版の整合性を検証する |
| Line側profile・Embedding事前生成 | Approved公開条件と検索可能状態を管理する |
| Candidate生成 | Candidateとして保存し、人間承認なしにApprovedへしない |
| Provider固有応答 | Adapterで共通結果・共通エラーへ正規化する |

RailsはApproved状態、ベクトル互換性、policy、履歴、再利用条件および候補集合を検証し、最終Lineを決定する。正常処理後の適格候補0件だけをSILENCEとし、外部API障害や不正出力をSILENCEへ置き換えない。

Provider、model、閾値、selector、domain taxonomyおよび本番Lineプールは本書で確定しない。

## 10. PostgreSQL / pgvectorとの関係

- Railsの主DBはPostgreSQLとする。
- 環境導入時のPostgreSQLは18系、pgvectorは0.8系とする。
- Line候補検索に必要なベクトルを同じデータ整合性境界で扱えるよう、pgvectorを利用可能な構成とする。
- ローカルDBはPostgreSQLとpgvectorを利用できる別コンテナとする。
- 本番DBはAmazon RDS for PostgreSQLを使用し、初期は既存コーポレートサイト用RDSインスタンス内の専用Database・専用DB Userを利用する。
- 確認済みの既存RDSはPostgreSQL 18.3で、`pg_available_extensions`の`vector`は`default_version = 0.8.1`である。
- `corporate_production` Databaseには`vector` extensionを導入せず、obserbing専用Databaseでのみ利用する。
- Database、DB User、extensionの作成・変更は、明示的な実施Issueの範囲で行う。
- RailsアプリケーションからコーポレートサイトのDatabaseやテーブルへ依存しない。
- 異なるEmbeddingモデル、次元、正規化版のベクトルを比較しない。
- Entry・Traceに結び付くprofile、EmbeddingおよびGap Event等を個別ユーザーデータとして削除連動させる。

pgvector extensionの有効化、権限、索引方式、索引パラメータ、検索クエリおよび性能基準の確定は、RDS環境と実データ規模を確認したうえで詳細設計する。

## 11. ローカルDocker開発方針

ローカルの基本構成は、リポジトリルートの`compose.yml`で管理する。

```text
Docker Compose
├─ backend
│  └─ Rails
└─ db
   └─ PostgreSQL + pgvector
```

- Rails用Dockerfileは`backend/`へ置く。
- Railsコンテナのビルド対象は原則`backend/`とする。
- PostgreSQLはRailsとは別コンテナとする。
- React Native / Expoは原則Dockerへ入れず、ホストOS上で開発する。
- `poc/`と`docs/`をRails本番コンテナへ含めない。
- 開発時は必要に応じて`backend/`をRailsコンテナへbind mountする。
- 将来Workerが必要になった場合にサービスを追加できる構成とする。

開発・本番で可能な限り同一Dockerfileを利用し、RailsコンテナをEC2固有の実行方式へ過度に依存させない。本番でDocker Composeを使うかは[AWS基本設計](AWS基本設計.md)の未決定事項とする。

## 12. 設定・秘密情報の基本方針

- Provider API key、DB password、Rails secret、管理者資格情報等をGit管理対象へ含めない。
- 秘密情報は実行環境からRailsへ注入し、通常ログ、例外メッセージ、HTTPレスポンスおよびビルド成果物へ出力しない。
- 環境ごとにDB、外部Provider、API URL、機能版および運用設定を分離する。
- Providerとmodelを処理用途ごとに設定で切り替えられる境界を維持する。
- 秘密情報を参照できる主体と権限を最小化し、更新・失効手順を詳細設計する。

AWS Secrets Manager、SSM Parameter Store、Rails credentialsおよび開発用環境変数の役割分担は未決定である。

## 13. ログ・Privacy by Designの基本方針

- 本番のアプリケーションログ、APM、例外通知およびアクセスログへ日記原文を出力しない。
- 不要なAI処理ログへ日記原文、プロンプト本文、AIレスポンス本文、Entry profile全文またはEmbeddingを保存しない。
- 管理画面の日常的な分析で日記原文を表示しない。
- 運用ログはCorrelation ID、処理種別、版、時間、利用量、成功・失敗、正規化した理由コード等の必要最小限にする。
- AccountやEntryへ再結合できる運用メタデータは個別データとして扱い、アクセス制御、保持期間および削除連動を設計する。
- TRACE削除時は、紐付くEntry、Trace、個別profile、Embedding、Gap Eventその他の個別分析データを通常DBから即時削除する。
- アカウント削除時は、再結合可能な個人データを通常DBから即時削除する。
- 匿名集計は個人へ再結合できない条件を満たすものだけとし、単にAccount IDを外した個別データを匿名集計とみなさない。
- バックアップ復元後も削除済み個人データを再び有効にしないことをシステム不変条件とする。

削除の具体的な外部キー、非同期処理、監査証跡、匿名化条件および復元後の抑止方式は、要件を弱めずに詳細設計する。

## 14. バックグラウンド処理の考え方

投稿応答に必須でない処理は、同期処理から分離できるよう設計する。候補は次のとおりである。

- Line登録・変更後のprofileおよびEmbedding事前生成
- Gap Eventの集約、Gap Cluster分析およびLine Candidate生成
- 利用量・費用・匿名統計の集計
- 外部サービスとの状態同期や再確認が必要な処理
- 通知、保守、再計算等の将来処理

バッチ生成したLineはCandidateに留め、人間の承認なしにApprovedへしない。ジョブの実行基盤、キュー、永続化、優先度、再試行、冪等性、排他、失敗隔離およびスケジュールは未決定である。将来Workerを分離しても、Webと同じコード・設定契約を利用できる構成を目指す。

## 15. トランザクション設計で今後詰める項目

次は上位要件を満たす必要があるが、具体方式を本書では確定しない。

- 同時投稿時にも一日投稿上限を超過させない判定・予約方式
- EntryとTraceが正常保存された場合だけ投稿件数を1件として確定する方式
- 通信・システムエラー時に投稿件数を増やさない方式
- TRACE削除後も当日の投稿件数を戻さないデータ境界
- 同一リクエストの再送によるAI処理、保存および課金集計の重複防止
- SAFETY、Line、SILENCEおよび技術エラーごとの保存単位
- Entry、Trace、選択結果、個別AI profile、Embedding、Gap Event間の整合性
- TRACE削除・アカウント削除時の関連データ削除と監査の原子性
- 外部AI処理中の競合、タイムアウト、キャンセルおよび結果の遅延到着

DBトランザクションの範囲と、外部AI API呼び出しの前後に置く状態・予約の具体方式は詳細設計で決める。[AI基本設計](AI基本設計.md)が求める「外部呼び出しを待つ間に長時間DBトランザクションを保持しない」という制約を満たしつつ、短いトランザクションの分割、ロック、予約および最終確定の方式を比較する。

## 16. エラー状態の基本分類

| 分類 | 例 | 基本的な扱い |
|---|---|---|
| 入力エラー | 形式、文字数、必須項目の不正 | AI処理を開始せず、API契約に従って返す |
| 認証・認可エラー | 無効資格情報、権限不足 | 個人情報を漏らさず処理を拒否する |
| 利用不可 | 投稿上限、利用権、無効状態 | 上位要件に従って静かに案内する |
| SAFETY分岐 | 上位仕様の対象条件 | 通常Line選定を止め、固定応答へ分岐する |
| SAFETY判定不能 | 不正出力、タイムアウト等 | 通常選定へ進めず技術エラーとする |
| AI技術エラー | Provider障害、Schema不正、Embedding不整合 | SILENCEへ置き換えず技術エラーとする |
| DB技術エラー | PostgreSQL / pgvector障害、整合性違反 | Ruby総当たり等へ暗黙退避せず中止する |
| 意味的候補不成立 | 正常処理後の適格候補0件 | SILENCEとする |
| 競合・重複 | 同時投稿、同一リクエスト再送 | 詳細設計する冪等性・排他契約で処理する |

ユーザー向け文言、HTTP status、再試行可否、投稿枠の扱いおよびクライアント再送方式はAPI・エラー詳細設計で決める。

## 17. テスト方針の基本原則

- 要件の受け入れ条件をAPI・業務ルールのテストへ対応付ける。
- React Native向けAPIの認証、認可、入力検証、versioningおよびエラー契約を検証する。
- Plan、利用権、一日投稿上限、同時実行および冪等性を境界値で検証する。
- AI Provider Adapterは実APIに依存しない契約テストを基本とし、構造化出力不正、timeout、retryおよび版不整合を検証する。
- SAFETYとSILENCEを混同せず、上位仕様に定義された分岐を検証する。
- PostgreSQL / pgvectorの互換性、検索条件および版分離は、実際のDB機能を用いる結合テストを持つ。
- TRACE削除、アカウント削除、匿名集計境界およびバックアップ復元後の再有効化防止を検証する。
- 本番相当ログへ日記原文や秘密情報が出ないことを検証する。
- 管理画面の認可、Candidate承認、状態遷移および監査要件を検証する。

具体的なテストフレームワーク、fixture / factory、外部サービスstub、CI環境および性能試験データは実装・テスト詳細設計で決める。PoCの評価結果を書き換えたり、本実装の自動テストの代わりにしたりしない。

## 18. 今後の詳細設計項目

- `backend/`内部の構造と依存方向
- APIエンドポイント、OpenAPI、認証方式、error schema、Idempotency Key
- 管理画面の画面、認証・認可、監査、個別データアクセス手順
- Railsモデル候補、DB schema、外部キー、削除cascade、保持期間
- 投稿上限予約、最終確定、同時実行、外部AI処理を含むトランザクション設計
- AI Adapterのインターフェース、共通結果型、共通エラー型
- Entry profile、Embedding、Line profileおよび選択Traceの保存契約
- pgvectorのextension、index、query、version移行および性能試験
- バックグラウンドジョブの基盤、冪等性、再試行、排他および監視
- 秘密情報の環境別注入、更新および失効
- Privacy by Designに基づくログ、削除、匿名化およびバックアップ復元対策
- テスト構成、CI、デプロイ前検証および運用Runbook

## 19. 未決定事項

- `backend/`内部のアーキテクチャと命名
- 認証、Device Credential、Phone Recoveryおよび管理者認証の具体方式
- APIエンドポイント、error schema、Idempotency KeyおよびOpenAPI運用
- 概念モデルとActive Recordモデル・テーブルの対応
- DBトランザクションの具体範囲と投稿枠予約・ロック方式
- 外部AI API呼び出し前後の状態管理と遅延結果の扱い
- バックグラウンドジョブ基盤、キューおよびWorker分離時期
- Provider / model、閾値、selector、domain taxonomyおよび本番Lineプール
- pgvector extension、索引、パラメータ、距離方式および性能基準
- 秘密情報管理手段の役割分担
- ログ保持期間、APM、監視、アラートおよび運用メタデータの削除連動
- 匿名集計条件とバックアップ復元時の削除済みデータ再有効化防止方式
- 本番でのDocker Compose利用、Web server、TLS、デプロイおよびコンテナ自動起動方式

これらは未決定であることを実装上の暗黙値で埋めず、該当する詳細設計またはIssueで決定する。
