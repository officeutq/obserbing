# AI Line Selection PoC

RailsやReact Nativeへ依存せず、obserbingの一行選定フローを比較検証するRuby CLIです。

現段階は、外部AI APIを呼び出す直前までを実装しています。HTTPクライアントやProvider SDKは含まれず、`pending_external` Adapterは送信要求を組み立てたあと、ネットワークアクセス前に必ず停止します。

## 必要環境

- Ruby 3.3以上（開発時：3.4.7）
- Bundler 4以上

```powershell
cd C:\dev\obserbing\poc\ai_line_selection
bundle install
```

## 実行

設定、スキーマ、データ件数、外部APIが無効であることを確認します。

```powershell
bundle exec ruby bin\ai_line_selection doctor
```

オフラインFixture Adapterで代表ケースを最後まで実行します。Fixtureはオーケストレーション検証用であり、AI品質の評価結果ではありません。

```powershell
bundle exec ruby bin\ai_line_selection run --entry-id E001
```

固定データセット全体をオフライン実行し、SAFETY一致率、候補再現率、選択テーマ一致率、p50 / p95を集計します。

```powershell
bundle exec ruby bin\ai_line_selection evaluate --repetitions 1
```

Provider非依存の送信要求を準備し、入力を伏せた要約だけを表示します。ネットワーク通信は行いません。

```powershell
bundle exec ruby bin\ai_line_selection prepare --entry-id E001 --operation safety
```

外部Adapter境界で停止することを確認できます。終了コードは意図的に`2`です。

```powershell
bundle exec ruby bin\ai_line_selection run --entry-id E001 --adapter pending_external
```

## テスト

```powershell
bundle exec rake test
```

## ディレクトリ

| パス | 内容 |
|---|---|
| `config/poc.yml` | 処理別Adapter、モデル、制限値、予算 |
| `data/` | 合成日記36件、Line 120件、SAFETY 12件 |
| `prompts/` | 処理別プロンプトdraft |
| `schemas/` | Provider共通の構造化出力Schema |
| `lib/ai_line_selection/adapters/` | Fixtureと外部接続直前の境界 |
| `tmp/telemetry.jsonl` | 本文を含まない実行メタデータ（Git対象外） |

## Provider Adapter契約

Adapterは`PreparedRequest`を受け、次を含む`AdapterResponse`を返します。

- Provider共通Schemaへ正規化した`data`
- Provider名、モデル、Request ID
- Input / Output利用量と推定費用

`OperationClient`はSchema、Embedding件数、候補ID許可リストを検証します。Provider固有の例外は、実Adapter追加時に共通エラーへ正規化します。

実Providerを追加する位置は`Adapters::PendingExternal#call`です。Provider選定、データ利用条件、予算承認が終わるまで実装しません。

## 秘密情報と生成物

- APIキーは`.env`または環境変数だけに置き、コミットしません。
- `.env`、`tmp/`、`results/`、`vendor/bundle/`はGit対象外です。
- 通常ログに日記本文、Meaning全文、プロンプト本文、AIレスポンス全文を出しません。
- 実API利用前に[AI PoC計画](../../docs/AI_PoC計画.md)の「外部API実行前ゲート」をすべて満たします。

## 現時点で未実装

- 外部Provider SDK / HTTP通信
- APIキーを使った認証
- Provider固有のレスポンス変換とエラー正規化
- 実Token・料金の取得
- 外部モデルによる比較実験と結果文書
