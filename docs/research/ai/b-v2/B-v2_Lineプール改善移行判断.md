# B-v2 Lineプール改善移行判断

## 結論

Issue #48のGate Aは`architecture_rejected`である。このためIssue #49では、現B-v2方式をGate B用の固定baselineとして採用せず、Lineプール改善Epicも作成しない。Gate Bは未起動・未評価である。

Lineプール改善だけで今回の方式問題を解消できると仮定せず、先に別版の選定方式PoCが必要である。現方式の構成値は再現と失敗分析のためにsnapshotとして残すが、`gate_b_architecture_baseline`とは呼ばない。

## 再現用snapshot

| 項目 | 値 |
|---|---|
| status | `rejected_experiment_not_gate_b_baseline` |
| profile | `b-v2-profile-primary-secondary-v1` |
| Embedding | `b-v2-openai-small-dual-cosine-v1` |
| Provider / model | OpenAI / `text-embedding-3-small` |
| dimensions / distance | 1536 / cosine |
| A_min | 0.45 |
| S_max | 0.55 |
| Top N | 20 |
| selector | `b-v2-selector-v1 / uniform` |
| seed | `SHA256(base_seed\|entry_id\|repetition)`先頭64bit |
| domain taxonomy | `b-v2-profile-primary-secondary-v1` |
| guard / policy | `b-v2-guard-policy-v1` |
| Approved Line | 96件 |
| Approved 96 canonical hash | `2f418244d710d1d2ce1853febc74c82f4817ee8b6d9c7d5e3e779465a7fcd9b9` |
| `lines.yml` hash | `c2c4814d0f159daf989a21e17413b008a822533ee5c843fbda00d658cfff4232` |

canonical hashは、Approved LineをID順に並べ、各要素を`id`、`text`、`status`のキー順で持つ配列としてRuby `JSON.generate`し、そのUTF-8 byte列へSHA-256を適用する。`Bv2LinePoolTransition`と自動テストにより再計算できる。

## 将来のLineプール改善Epicを許可する条件

現在のLineプール改善Epicは作成しない。将来進めるには、少なくとも次を満たす別版の選定方式PoCが必要である。

1. 現方式と区別できる新しいversionと仮説を定義し、結果を見る前に評価基準を固定する。
2. acceptable改善の棄却下限未達と、too-far / weak connection増加を設計上扱う。
3. 3反復一貫性とEnd-to-End p95を改善対象に含める。
4. 選定方式変更とLineプール変更を同じ比較へ混ぜない。
5. 新方式が固定済みGateで`architecture_candidate`になった後にだけ、Lineプールのみを変える別Epicを作る。

low-confidence 8種類の人間評価は、将来の評価データとして追加できる。ただし、今回のbest caseは52 / 108でGate A最低76件に届かないため、移行判断を保留する理由にはしない。`reflective-distance-v1`を今回の結果に合わせて書き換えず、将来の別rubric版を検討するときの証拠にする。

## Gate Bの位置づけ

固定済みGate Bの基準は将来参照用に保持するが、今回は評価しない。Gate Bは、新方式がGate Aで`architecture_candidate`になり、その方式を固定してLineプールだけを改善した後に適用する。Gate B合格もholdoutや実データ相当評価を省略した本番採用確定ではない。

機械可読な判断、構成snapshot、hash算出法、将来条件は`poc/ai_line_selection/data/evaluations/b_v2_line_pool_transition_v1.json`を正とする。外部API実行とLineプール変更はいずれも0回である。
