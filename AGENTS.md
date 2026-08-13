# GitHub運用ルール

- `officeutq/obserbing` にIssueを作成するときは、必ずGitHub Project「OBSERBING BOARD」に追加する。
  - Project: https://github.com/users/officeutq/projects/8
- ステータスの指定がない場合は `Todo` に設定する。
- Issue作成時は、内容に合う既存ラベルを1つ以上付与する。
  - 例：ドキュメント作業は `documentation`、明確な作業項目は `task`、AI関連は `ai` を付与する。
- Issue作成後、プロジェクトへの追加、ステータス、ラベルを確認してから完了を報告する。

## Issue実装時のGit運用

- Issueの実装を開始する前に、最新の `main` から作業ブランチを作成する。
- ブランチ名は原則として `codex/issue-<Issue番号>-<短い説明>` とする。
- 原則として、1つのIssueにつき1つのブランチを使用する。
- `main` へ直接コミット・プッシュしない。
- 実装後は関連するテストを実行し、作業ブランチをプッシュする。
- `main` 向けのPull Requestを作成し、本文に `Closes #<Issue番号>` を記載する。
- Pull Requestへのラベル付与とGitHub Projectへの追加は不要とする。
