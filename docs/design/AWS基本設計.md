# AWS基本設計

**文書ステータス：現行基本設計**

**作成日：2026年8月14日**

**関連Issue：#67**

## 1. 文書の目的

本書は、obserbingの初期本番環境をAWS上に構築するための確定方針、システム境界および詳細設計へ送る事項を定義する。

本書ではAWSリソースを作成せず、EC2、ネットワーク、TLS、秘密情報、監視、デプロイ等の具体設定値を推測で確定しない。

## 2. 上位ドキュメントとの関係

文書の優先順位は[ドキュメント索引](../README.md)に従う。

- プロジェクト概要と技術方針：[ルートREADME](../../README.md)
- 上位要件：[要件定義書](../requirements/要件定義_v1_0.md)
- Railsアプリケーションの責務：[Rails基本設計](Rails基本設計.md)
- AI処理全体：[AI基本設計](AI基本設計.md)
- 開発運用：[AGENTS.md](../../AGENTS.md)。プロダクト仕様ではない

本書は上位要件、Rails基本設計およびAI基本設計を変更しない。SAFETYの判定規則や応答内容をAWS層で追加せず、必要な可用性、秘密保持および通信経路を提供する。

## 3. 初期本番アーキテクチャ概要

初期本番環境はAWS EC2 + DockerをRails実行基盤、Amazon RDS for PostgreSQLをDB基盤とする。ECS / Fargateは初期本番環境では採用しない。

```text
React Native / Expo
  │ HTTPS
  ▼
APIサブドメイン（DNS上の公開境界）
  │ DNS → Elastic IP
  ▼
EC2
  └─ Docker
     └─ Rails（REST JSON API / 管理画面）
           │ PostgreSQL接続
           ▼
Amazon RDS for PostgreSQL（既存インスタンスを共有）
  ├─ corporate_site_database / corporate_site_user
  └─ obserbing_database / obserbing_app_user
```

HTTPSの終端位置、Web server / reverse proxy、VPC / SubnetおよびSecurity Groupの具体構成は未決定である。ネイティブアプリはEC2のIPアドレスを直接API URLにせず、DNS名を安定した公開境界とする。

## 4. EC2

- RailsはEC2上のDockerコンテナとして実行する。
- ECS / Fargateを初期本番の前提にしない。
- EC2固有のファイル配置、メタデータまたは手作業へRailsコンテナを過度に依存させない。
- OS patch、Docker runtime、時刻同期、容量、再起動、障害復旧およびアクセス経路は運用設計の対象とする。
- EC2インスタンスタイプ、台数、CPU architecture、OSおよびストレージ構成は未決定である。

負荷見積り、RDSとの接続要件および選択するarchitectureでコンテナが動作することを確認してから具体構成を決める。

## 5. Docker

- Rails用Dockerfileはモノレポの`backend/`へ置く。
- Railsコンテナのビルド対象は原則`backend/`とし、`poc/`と`docs/`を本番コンテナへ含めない。
- 開発・本番で可能な限り同一Dockerfileを利用する。
- 設定と秘密情報はimageへ埋め込まず、実行環境から注入する。
- コンテナは将来ECR + ECS / Fargate等へ移行できる可搬性を維持する。

本番でDocker Composeを使うか、本番用composeファイルを持つか、imageをどこへ保存するか、ECRを初期から使うか、EC2起動時にどう自動起動するかは未決定である。

## 6. Elastic IP

- EC2へElastic IPを割り当て、APIサブドメインのDNSから名前解決する構成を初期基本案とする。
- Elastic IPはDNSの接続先であり、ネイティブアプリのAPI URLとして直接配布しない。
- EC2交換時のElastic IP再関連付け、切替手順および復旧時の責任者を運用設計する。

Elastic IP、EC2、将来のALB等を切り替えてもクライアントのAPI URLを極力変更しないことを目的とする。

## 7. DNS / APIサブドメイン

株式会社オフィスUTQのコーポレートサイト用ドメイン配下に、obserbing API用サブドメインを設ける。

```text
https://obserbing-api.officeutq.co.jp/api/v1
```

これは設計上の例であり、実際のサブドメイン名は未決定である。API URLのpathはRails基本設計に従い`/api/v1`とする。

DNS名を公開境界にすることで、EC2からALB / ECS等へ移行してもネイティブアプリ側の接続先変更を抑える。DNS zone、record type、TTL、変更権限、切替・rollback手順は既存ドメイン管理状況を確認して詳細設計する。

## 8. HTTPS / TLS

- 本番APIと管理画面はHTTPSのみで公開する。
- 平文HTTPでアプリケーションデータや認証情報を送受信しない。
- HTTPを公開する必要がある場合のHTTPS redirectや証明書更新用経路は詳細設計する。
- TLS証明書の取得・更新・失効、秘密鍵の保管、対応protocol / cipherおよび終端位置を運用可能な形で決める。

Caddy、nginx等のWeb server / reverse proxy、TLS証明書の具体的取得方式および終端構成は未決定である。

## 9. RDS PostgreSQL共有方針

本番DBはAmazon RDS for PostgreSQLを使用する。初期MVPではコストを抑えるため、株式会社オフィスUTQのコーポレートサイトが既に利用するRDS PostgreSQLインスタンスを共有する。

共有するのはRDSインスタンスというインフラ境界であり、アプリケーションのDatabase、DB Userおよびデータ責務は分離する。obserbingのアプリケーションコードはコーポレートサイトのDatabaseやテーブルへ依存しない。

同一インスタンスを共有するため、CPU、メモリ、ストレージ、connection、メンテナンス、backup operationおよび障害の影響範囲を共有する。この制約を初期MVPでは許容するが、既存インスタンスの仕様、余力、PostgreSQL version、接続上限、バックアップおよび保守条件を本番投入前に確認する。

## 10. obserbing専用Database / DB User

RDS内の論理構成は次を基本とする。

```text
Amazon RDS PostgreSQL
├─ corporate_site_database
│  └─ corporate_site_user
└─ obserbing_database
   └─ obserbing_app_user
```

- `obserbing_database`とobserbing専用DB Userを作る。
- 専用DB Userにはobserbing用Databaseに必要な最小権限だけを付与する。
- コーポレートサイト側のDatabaseやテーブルへアクセスできることを前提にしない。
- 接続先、資格情報、migration用権限および通常実行時権限を環境設定として分離できるようにする。
- Database名、User名、owner、schema、role構成および権限付与SQLは詳細設計で決める。

専用DB Userを設けることは、同一RDSインスタンスの性能・保守・障害ドメインまで分離するものではない。

## 11. pgvector

obserbingではLine候補検索にpgvectorを利用する予定とし、ローカルと本番のPostgreSQLで利用できる構成を目指す。

- extensionの提供可否、対応versionおよび有効化権限を既存RDSで確認する。
- extensionを有効にするDatabase、実施主体、変更手順およびrollback可否を詳細設計する。
- Rails通常実行Userへextension管理権限を恒常的に与えることを前提にしない。
- Embeddingのmodel、dimensions、version、正規化および距離方式が一致するデータだけを比較する。
- index方式とparameterは現時点で固定せず、AI基本設計と実データ規模に基づく性能検証後に決める。

pgvector extensionの有効化方式、権限、HNSW / IVFFlat等のindex方式およびparameterは未決定である。

## 12. ネットワーク / Security Groupの基本方針

- インターネットから到達させる入口はAPI・管理画面に必要なHTTPS経路へ限定する。
- EC2からRDSへの接続は、obserbingの実行に必要な送信元・portへ限定する。
- RDS共有環境の既存通信を壊さず、obserbingからコーポレートサイトDBへ到達できることをアプリケーション要件にしない。
- 管理用接続、デプロイ、監視および外部Providerへのegressを用途ごとに整理し、最小権限と監査可能性を確保する。
- 開発・検証・本番の通信境界を混在させない。

既存VPC / Subnetを利用するか新規作成するか、public / private配置、routing、Security Groupの具体値、SSHを許可するかSSM Session Manager中心にするかは未決定である。既存RDSの配置と変更制約を確認したうえで決める。

## 13. 秘密情報管理

- DB password、Rails secret、Provider API key、管理者資格情報、TLS秘密鍵等をGit、Docker image、Compose定義の平文、通常ログまたは配布アプリへ含めない。
- 実行主体だけが必要な秘密へアクセスできるよう、最小権限で注入する。
- 秘密情報の作成、更新、失効、緊急rotation、監査および担当者変更の手順を設ける。
- 本番と開発の秘密情報を分離する。

AWS Secrets Manager、SSM Parameter Store、Rails credentialsおよびEC2上の実行時設定の役割分担は未決定である。料金、rotation要件、権限境界およびデプロイ方式を確認して選択する。

## 14. ログ・監視

- 本番ログ、APM、例外通知、reverse proxyログおよびAI処理ログへ日記原文を出力しない。
- Entry profile全文、Embedding、AIへのprompt本文およびresponse本文を不要に保存しない。
- 管理画面の日常的な分析で日記原文を表示しない。
- 秘密情報、認証token、DB接続文字列および個人へ再結合できる不要な識別子をmaskする。
- Rails / container / EC2 / RDS / TLS / DNS / 外部Providerの障害を切り分けられる最小限のメタデータを収集する。
- RailsのCorrelation IDと、本文を含まない処理種別、版、latency、成功・失敗、retry、利用量を関連付ける。
- 個人へ再結合できるログは個別データとしてアクセス、保持および削除連動を設計する。

CloudWatch Logs、metrics、alarm、dashboard、APM、保持期間、通知先、費用上限および障害対応Runbookの具体構成は未決定である。

## 15. バックアップ

- RDSのAWS側バックアップを利用する。
- 削除済みデータがバックアップに残る期間は、AWSで設定されたバックアップ保持期間に従う。
- アプリ独自の追加保持期間を設けない。
- backup、snapshot、保持期間、暗号化、復元試験、アクセス権および削除手順を既存共有RDSの運用と整合させる。
- obserbingの復元要件を追加しても、コーポレートサイト側の復元・保守要件を損なわないよう共有責任を明確にする。

具体的な自動backup設定、snapshot運用、RPO / RTO、復元先および復元試験頻度は、既存RDS構成を確認して詳細設計する。

## 16. バックアップ復元時の削除済み個人データ再生成防止

バックアップ復元によって、復元時点より前にユーザーが削除したTRACE、アカウントおよび再結合可能な個人データを再び有効にしないことを必須のシステム不変条件とする。

通常運用では、TRACE削除時に紐付く個別分析データを、アカウント削除時に再結合可能な個人データを通常DBから即時削除する。バックアップ内の削除済みデータは第15章の保持期間に従うため、復元時に通常DBへ戻っても有効化されない制御を別途必要とする。

復元手順は、少なくとも次を満たす必要がある。

- 復元DBをそのまま利用者向けに公開しない。
- 削除済み主体・データを識別し、再有効化を防止する工程を公開前に完了する。
- 対策の実行結果を日記原文なしで検証・監査できるようにする。
- TRACE削除では紐付く個別分析データ、アカウント削除では再結合可能な個人データ全体を対象にする。
- 個人へ再結合できない匿名集計と個別データの境界を維持する。

削除記録の別系統保持、tombstone、復元後reconciliation等の具体方式は未決定である。要件定義書はこの方式を設計事項としているが、本Issueでは方式を推測で固定しない。本番開始前に、通常DBと同時に巻き戻らない削除証跡の保護、保持期間、権限、障害時手順および復元試験を詳細設計で確定する。

## 17. デプロイ方針

- RailsをDocker imageとしてbuildし、EC2上のcontainerとして実行する。
- 開発・本番で可能な限り同一Dockerfileを使用する。
- build時に秘密情報をimageへ含めない。
- migration、application起動、health check、rollbackおよび互換性確認を分離して実行できるようにする。
- デプロイ中もDB schemaと稼働中アプリの互換性を壊さない手順を詳細設計する。
- 実行したcommit、image、設定版およびmigration状態を追跡可能にする。

Docker imageの保存先、ECRの初期利用、GitHub Actions等のCI/CD、本番Docker Compose、EC2への配置方法、無停止要件およびEC2起動時のcontainer自動起動方式は未決定である。

## 18. 障害時の考え方

- 外部AI API、Rails、Docker、EC2、DNS / TLS、RDS / pgvectorの障害を区別し、意味的なSILENCEへ置き換えない。
- 日記原文や秘密情報を障害調査ログへ追加しない。
- EC2の交換、Elastic IPの再関連付け、container再起動、DB接続復旧および資格情報失効の手順を事前に定める。
- 共有RDSの障害・maintenance・資源逼迫が両システムへ影響し得ることを運用上の制約として監視する。
- backupからの復元時は、第16章の削除済みデータ再有効化防止を完了するまで公開しない。
- 障害中の投稿件数、重複request、処理途中のEntry / Traceおよび遅延した外部応答はRailsのtransaction・idempotency設計に従う。

可用性目標、RTO / RPO、on-call、alert通知、復旧優先順位、maintenance windowおよび縮退方針は未決定である。

## 19. 将来のECS / Fargate移行

初期本番ではECS / Fargateを採用しないが、次の境界を維持して将来移行を可能にする。

- ネイティブアプリはDNS名をAPI境界とし、EC2のIPへ依存しない。
- Railsは可搬なDocker imageとしてbuildする。
- 秘密情報と環境設定をimageやEC2固有ファイルへ埋め込まない。
- 永続データをcontainer local filesystemへ依存させない。
- health check、graceful shutdown、ログ出力およびWorker分離をcontainer実行環境から扱えるようにする。

ECR、ECS、Fargate、ALB、Service Discovery、Auto Scalingおよび移行時期は将来の比較対象であり、本書で採用を確定しない。

## 20. 将来の専用RDS分離

初期は既存RDSインスタンスを共有するが、obserbing専用Database・専用DB Userを境界とし、アプリケーションコードからコーポレートサイトDBへの依存を持たせない。これにより、将来の専用RDS移行時に接続先変更とデータ移行を主な変更点にできるようにする。

専用RDSへの移行判断では、次を評価する。

- CPU、メモリ、storage、IOPSおよびconnectionの競合
- maintenance、backup、restoreおよび障害ドメインの分離要求
- pgvectorのversion、extension、indexおよび性能要件
- セキュリティ、権限、監査およびnetwork境界
- 可用性、RPO / RTOおよびコスト

移行時期、移行方式、停止時間、同期、rollbackおよび接続先切替は未決定である。

## 21. コスト方針

- 初期MVPでは既存RDSインスタンスを共有し、専用RDSの固定費を抑える。
- EC2 + Dockerを初期実行基盤とし、ECS / Fargateを初期から導入しない。
- 運用可能性、Privacy by Design、バックアップ、監視および障害復旧に必要な要件を、コスト削減を理由に省略しない。
- EC2、storage、data transfer、Elastic IP、RDS追加負荷、backup、logs、secret管理、image registryおよび外部AI費用を分けて可視化する。
- 共有RDSが既存システムへ与える負荷と、専用RDSへ分離する費用を定期的に比較できるようにする。

予算、具体的なinstance size、契約方式、費用alertおよび専用RDSへの移行thresholdは未決定である。

## 22. 未決定事項

- EC2インスタンスタイプ、台数およびstorage
- CPU architecture（x86_64 / ARM64）
- Amazon Linux / Ubuntu等のOS
- Web server / reverse proxy（Caddy / nginx等）
- TLS証明書の具体的取得・更新・終端方式
- VPC / Subnetを既存利用するか新規作成するか
- public / private配置、routingおよびSecurity Groupの具体値
- SSHを許可するか、SSM Session Manager中心にするか
- AWS Secrets Manager / SSM Parameter Store / Rails credentialsの役割分担
- CloudWatch Logs、metrics、alarm、APMおよび保持期間の具体構成
- Docker imageの保存先
- ECRを初期から利用するか
- GitHub Actions等によるCI/CD
- 本番でDocker Composeを使用するか、本番用composeファイルを持つか
- EC2起動時のcontainer自動起動方式
- RDS既存インスタンスの仕様、余力、PostgreSQL versionおよび運用制約
- RDS上でのpgvector extensionの有効化方式・権限
- pgvector index方式、parameter、性能基準および再index手順
- backup、snapshot、RPO / RTOおよび復元試験の具体設定
- バックアップ復元時の削除済みデータ再有効化防止方式
- 可用性目標、障害対応、連絡経路および運用Runbook
- APIサブドメインの正式名称、DNS record、TTLおよび変更手順
- 専用RDSへ分離する条件、時期および移行方式

これらは詳細設計または本番準備Issueで決定する。未決定事項をAWSの既定値、手作業または実装者の推測へ委ねない。
