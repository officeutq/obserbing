# obserbing（オブザービン）

> **Be, not a wannabe.**

`observe`（観察）と `being`（存在）を組み合わせた、
「存在を観察する存在」という意味の名前です。

## 概要

obserbingは、そのとき考えていることを静かに書き残すためのアプリです。

ユーザーが言葉を書くと、obserbingはその内容を評価・診断・指導せず、あらかじめ用意された多数の一行の中から、その言葉にわずかに関係する一行を一つだけ選んで置きます。

答えを返すことや会話を続けることではなく、書いた言葉と一行を、そのときの自分の痕跡として残すことを目的としています。

## 基本体験

**書く。**<br>
**一行が置かれる。**<br>
**痕跡として残る。**

1. **WRITE** — 今考えていることを書く
2. **OBSERVE** — obserbingが内容を静かに観察する
3. **ONE LINE** — 一行だけが置かれる
4. **TRACE** — 書いた言葉と一行が痕跡として残る

## 大切にしていること

- 評価しない
- 診断しない
- 助言しない
- 意味を決めつけない
- 習慣化や継続を煽らない
- ユーザーと適切な距離を保つ

obserbingが意味を与えるのではなく、ユーザー自身がいつか意味を見つけるための余白を残します。

## 技術構成（予定）

| 領域 | 採用技術・方針 |
|---|---|
| 対象OS | iOS / Android |
| モバイル | React Native / TypeScript（`mobile/`） |
| 開発・ビルド | Expo Development Build / EAS Build |
| サーバー | Ruby 4.0.6 / Rails 8.1.3.1（`backend/`） |
| API | REST JSON / OpenAPI / `/api/v1` |
| 管理画面 | Rails Views / HotwireによるWebアプリ |
| ローカル開発 | Docker Compose（Rails + PostgreSQL / pgvector） |
| データベース | PostgreSQL 18系 / pgvector 0.8系 |
| アプリ内課金 | StoreKit / Google Play Billing |
| 課金管理 | RevenueCat / `react-native-purchases` |
| インフラ | AWS EC2 + Docker / Amazon RDS for PostgreSQL |
| リポジトリ構成 | モノレポ |

iOSとAndroidは同時に開発し、審査、課金設定、テストおよびリリースは、それぞれの進捗に合わせて進めます。

Railsはモバイル向けREST APIと、運営者向けWeb管理画面を同じアプリケーション内で提供します。管理画面はネイティブアプリに含めません。

モノレポではRailsを`backend/`、React Native / Expoを`mobile/`、PoCを`poc/`へ分離します。初期本番はRailsをEC2上のDockerコンテナで実行し、既存RDS PostgreSQLインスタンス内のobserbing専用Database・専用DB Userを使用します。ネイティブアプリはEC2のIPではなく、HTTPSのAPIサブドメインへ接続します。

既存Amazon RDSのPostgreSQL server versionは18.3、利用可能なpgvectorの`default_version`は0.8.1です。`corporate_production` Databaseには`vector` extensionを導入せず、将来作成するobserbing専用Databaseでのみ利用します。Database、DB User、extensionの作成・変更は、明示的な実施Issueの範囲でのみ行います。

### AI

AIプロバイダーおよび使用モデルは未定です。

日本語性能、SAFETY精度、構造化出力、Embedding精度、応答時間、費用、データ保持方針を比較評価したうえで決定します。
Rails側では、AIプロバイダーおよびモデルを設定によって切り替えられる構成とします。

一行選定は、SAFETY判定後にEntryの`abstraction + domain`を生成し、事前生成済みのLine profileと2種類のEmbeddingから「本質的には近く、表面は近すぎない」band-pass候補を作り、Railsのpolicy・履歴条件を適用して選択する方式を基本骨格とします。リアルタイムLine評価LLMは使用せず、候補がなければSILENCEとします。

具体的な`A_min / S_max / Top N / selector`、本番Provider / model、domain taxonomy、`pgvector`設定およびLineプールは未確定です。次フェーズでLineプールをブラッシュアップし、その版を固定してからband-passとselectorを再キャリブレーションします。

## ドキュメント

- [ドキュメント索引](docs/README.md)
- [要件定義書](docs/requirements/要件定義_v1_0.md)
- [Rails基本設計](docs/design/Rails基本設計.md)
- [AWS基本設計](docs/design/AWS基本設計.md)
- [AI基本設計](docs/design/AI基本設計.md)
- [B-v2 AI選定基本設計](docs/design/ai/B-v2_AI選定基本設計.md)
- [Reflective Distance 評価ルーブリック](docs/evaluation/Reflective_Distance_評価ルーブリック.md)

PoC、比較、診断、Gate判定、Epic結果などの調査・意思決定履歴は[ドキュメント索引](docs/README.md)に集約する。
