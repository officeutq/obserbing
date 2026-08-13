# Rails / Docker 開発手順

## 1. この文書の対象

この文書は、`backend/`のRailsアプリケーションをDocker Composeで開発・検査する手順を定義する。コマンドは、特記がない限りリポジトリルートで実行する。

必要なものはGitと、Docker Composeを利用できるDocker環境である。Ruby、Rails、PostgreSQLをホストOSへ直接インストールする必要はない。

## 2. 環境変数と秘密情報の境界

| 配置・入口 | 用途 | Git管理 |
|---|---|---|
| ルート`.env.example` | ローカルRails / PostgreSQL用の変数名と例 | 管理する |
| ルート`.env` | ローカルRails / PostgreSQLの実値 | 管理しない |
| ルート`.env.staging.example` / `.env.production.example` | staging / productionの実行インターフェース | 管理する |
| ルート`.env.staging` / `.env.production` | 環境ごとの実値を一時的に渡す場合のローカルファイル | 管理しない |
| `poc/ai_line_selection/.env.example` | AI PoC用API keyの変数名 | 管理する |
| `poc/ai_line_selection/.env` | 明示承認されたPoCだけで使うAPI key | 管理しない |
| `backend/config/master.key` | ローカルのRails credentials復号鍵 | 管理せず、Docker buildにも含めない |

PoCの`.env`をルートへコピーしない。Rails本体はPoCの環境変数を読み込まず、PoCもRails本体の`.env`を設定入口にしない。AI Provider接続をRailsへ実装するときは、別Issueで変数名と注入境界を決める。

AI API key、DB password、`DATABASE_URL`、Rails master key、認証ヘッダーを、Git、Dockerfile、Compose定義、Docker image、通常ログへ保存しない。staging / productionでAWS Secrets Manager、SSM Parameter Store、Rails credentialsのどれを使うかは未決定であり、この環境変数例は最終的な秘密情報管理方式を指定しない。

## 3. 初回セットアップと起動

ローカル用テンプレートをコピーし、`.env`の`POSTGRES_PASSWORD`をローカル専用値へ変更する。

PowerShell:

```powershell
Copy-Item .env.example .env
```

macOS / Linux / Git Bash:

```bash
cp .env.example .env
```

イメージを構築し、DBを起動する。

```bash
docker compose build backend
docker compose up -d db
```

development / test用Databaseを作成し、migrationを適用する。

```bash
docker compose run --rm backend bin/rails db:create
docker compose run --rm backend bin/rails db:migrate
```

Railsを起動する。Railsコンテナのentrypointでも`db:prepare`を実行するため、2回目以降の起動は既存Databaseへ未適用migrationだけを反映する。

```bash
docker compose up -d backend
docker compose ps
```

`http://localhost:3000/up`がHTTP 200を返せば起動完了である。ポートを変える場合は`.env`の`RAILS_PORT`を変更する。

ログを追う場合:

```bash
docker compose logs -f backend
```

## 4. Railsコマンド

起動中のコンテナでコマンドを実行する場合:

```bash
docker compose exec backend bin/rails routes
docker compose exec backend bin/rails console
```

Railsを常駐起動していない状態で一度だけ実行する場合:

```bash
docker compose run --rm backend bin/rails runner 'puts Rails.version'
```

DB状態の確認とmigration:

```bash
docker compose run --rm backend bin/rails db:migrate:status
docker compose run --rm backend bin/rails db:migrate
docker compose run --rm backend bin/rails environment:verify
```

`environment:verify`はPostgreSQL 18系、pgvector 0.8.1の利用可否、現在の`vector` extension導入状態を読み取り専用で確認する。extensionは自動作成しない。

## 5. test・lint・security check

CIと対応する検査をローカルで実行する。

```bash
docker compose run --rm backend bin/rails db:test:prepare
docker compose run --rm backend bin/rails test
docker compose run --rm backend bin/rubocop
docker compose run --rm backend bin/brakeman --no-pager
docker compose run --rm backend bin/bundler-audit
docker compose run --rm backend bin/importmap audit
```

外部AI APIを使うテストはRailsの標準検査へ混ぜない。PoCの実API実行は、PoC側の手順と費用条件に従い、明示承認がある場合だけ行う。

Pull Requestでは`.github/workflows/ci.yml`の`security`、`lint`、`test`がすべて成功したことを確認する。

## 6. 停止とローカルデータ

コンテナとネットワークを停止・削除する。通常はDBデータを保持するnamed volumeを削除しない。

```bash
docker compose down
```

ローカルDBを完全に作り直す必要がある場合だけ、対象がローカル開発環境であることを確認してから`docker compose down --volumes`を実行する。この操作はローカルDBデータを削除する。

## 7. staging / production実行定義

`compose.staging.yml`と`compose.production.yml`は、同じ`backend/Dockerfile`のproduction imageを使い、PostgreSQLコンテナを起動せず、環境ごとの外部Amazon RDSへ接続する。stagingでもRailsは`RAILS_ENV=production`で動かし、デバッグ用の独自Rails環境は増やさない。

テンプレートの構造だけを検査する例:

```bash
docker compose --env-file .env.staging.example -f compose.staging.yml config --services
docker compose --env-file .env.production.example -f compose.production.yml config --services
```

どちらも`backend`だけを出力する。実値を入れたenv fileに対して`docker compose config`を実行すると、展開された秘密値が標準出力へ表示され得るため、通常ログや共有端末へ出力しない。

`BACKEND_IMAGE`には、環境へ昇格する同一成果物のimmutableなdigest参照を渡す。`DATABASE_URL`と`RAILS_MASTER_KEY`は実行環境から注入する。EC2上でComposeを最終採用するか、env fileを使うか、image registry、DNS/TLS、デプロイ、自動起動をどう構成するかはAWS詳細設計で決定する。

## 8. 統合確認

PowerShell 7を利用できる環境では、fresh clone相当の空volumeを使った一連の確認を次で実行できる。

```powershell
./scripts/verify-docker-environment.ps1
```

GitHub Actionsでも同じスクリプトをfresh checkoutから実行する。確認範囲と残課題は[Rails / Docker 統合確認結果](Rails_Docker統合確認結果.md)を参照する。
