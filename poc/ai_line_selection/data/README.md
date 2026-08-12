# PoC評価データ

すべて合成データです。実ユーザーの日記や実在人物を識別できる情報は含みません。

## `entries.yml`

- 36件、IDは`E001`〜`E036`
- 短文、長文、改行、曖昧な記述を含む
- `expected`はFixtureと評価だけに使い、Provider入力へ渡さない
- `themes`と同じThemeのApproved LineをEmbedding候補検索の関連集合として扱う

## `lines.yml`

- 120件、IDは`L001`〜`L120`
- 12 Theme × 10件
- 各ThemeはApproved 8件、Candidate 1件、Retired 1件
- 通常検索対象はApproved 96件だけ
- `directness`はPoC用の事前メタデータで、確定値ではない
- `source: synthetic`、`review_status`で作成元とレビュー状態を追跡する

## `safety_cases.yml`

- 12件、IDは`S001`〜`S012`
- 通常、SAFETY、判定不能を分離して評価する
- 通常の日記評価やLine選定の品質集計へ混ぜない

## `human_evaluation_template.csv`

- 実行結果のモデル名を伏せた人間評価票
- `distance_rating`は`too_close`、`just_right`、`too_far`、`not_obserbing`から選ぶ
- 致命的な禁止事項があれば`fatal_violation`を`true`にする
- 評価中にモデル名やProvider名を列へ追加しない。対応表は別管理する
