# Rails / Docker 統合確認結果

## 1. 結論

Issue #79として、Rails / Docker環境をfresh clone相当の空volumeから再構築し、本実装を開始できる再現性と安全性を確認した。Epic #71の環境導入範囲は完了可能と判断する。

統合確認は`scripts/verify-docker-environment.ps1`を正本とし、Pull RequestごとにGitHub Actionsのfresh checkoutでも実行する。Rails、Ruby、PostgreSQLをホストへ直接導入せず、Railsに関するすべてのコマンドをDockerコンテナ内で実行する。

## 2. 確認条件

- 実施日: 2026-08-14
- Rails: 8.1.3.1
- Ruby: 4.0.6
- 開発DB image: `pgvector/pgvector:0.8.1-pg18-bookworm`
- ローカル確認時のPostgreSQL: 18.2
- pgvector利用可能版: 0.8.1
- DB状態: freshなdevelopment / test Database、`vector` extension未導入
- 実行境界: 専用Compose project、専用named volume、検証専用の非秘密値

開発imageが取得するPostgreSQL 18系のpatch versionはimage更新時点に従う。既存Amazon RDSは18.3である。いずれも設計どおり18系であり、pgvector 0.8.1を利用可能である。

## 3. 結果

| 確認項目 | 結果 |
|---|---|
| development image build | 成功 |
| development / test DB create | 成功 |
| migration / `db:prepare` | 成功 |
| PostgreSQL 18系への接続 | 成功 |
| pgvector 0.8.1の利用可否確認 | 成功 |
| Rails `/up` | HTTP 200 |
| Rails test | 成功 |
| RuboCop | 違反0件 |
| Brakeman | warning 0件 |
| bundler-audit / importmap audit | 成功 |
| production target build | 成功 |
| staging / production config validation | `backend`のみ、DB containerなし |
| production image内容 | `.env`、Rails key、`docs/`、`poc/`なし |
| production image ENV | DB / Rails / AIの秘密値・秘密変数なし |
| Git追跡ファイル | 実env file、Rails key、代表的な秘密signatureなし |
| README / docsのローカルリンク | 解決成功 |
| GitHub Actions | `docker`、`security`、`lint`、`test`をマージ前に確認 |

`vector` extensionは、環境確認によって自動作成していない。既存RDSのDatabase、DB User、extensionも変更していない。

## 4. 再現方法

PowerShell 7とDockerを利用できるfresh cloneのリポジトリルートで実行する。

```powershell
./scripts/verify-docker-environment.ps1
```

スクリプトはプロセスIDを含む専用Compose projectを既定で使用する。検証終了時には、そのprojectが作成したcontainer、network、named volume、検証用imageだけを削除する。開発者の通常の`obserbing` projectと既存volumeは変更しない。

個別の開発コマンドは[Rails / Docker 開発手順](Rails_Docker開発手順.md)を参照する。

## 5. 意図的に残す未決定事項

次は環境導入Epicの不具合ではなく、後続のAWS詳細設計または機能実装で決める。

- EC2上でのDocker Compose最終採用、container自動起動、Web server構成
- image registry、build / deploy / rollback方式
- DNS、TLS証明書、APIサブドメイン
- AWS Secrets Manager、SSM Parameter Store、Rails credentialsの役割分担
- obserbing専用RDS Database、DB User、`vector` extensionの実作成
- Rails業務モデル、API、認証、管理画面、AI Provider接続
- React Native / Expoアプリケーション

これらを推測で固定せず、現時点のstaging / production定義は外部RDSとimmutable imageを受け取るportableな実行インターフェースに留める。
