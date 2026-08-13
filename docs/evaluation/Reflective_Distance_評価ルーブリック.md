# Reflective Distance 評価ルーブリック

**文書ステータス：再評価前に固定**

**版：`reflective-distance-v1`**

**作成日：2026年8月13日**

**関連Issue：#38（Epic #27完了後の追補）**

## 1. 評価目的

obserbingのLineは、日記の正確な説明や答えではない。評価の中心は、Lineを見た瞬間には少し違って見えても、短い内省によって日記との本質的な接続を投稿者自身が発見できるかである。

具体領域の一致を正解条件にしない。人物、物、数量、場所、出来事などが日記にないという理由だけで、Lineを事実不整合にしない。別領域の具体例を通じて構造を照らす`analogical_transfer`と、存在しない出来事をユーザーの現実として断定する`user_fact_assertion`を別々に判定する。

機械可読な正本は`poc/ai_line_selection/data/evaluations/reflective_distance_rubric_v1.yml`とする。本ルーブリックは個別の再評価結果を見る前に固定し、再評価中に変更しない。

## 2. 中心となる問い

> 一見すると少し違うLineから、短く考えることで日記との構造的・関係的な接続を自分で発見できるか。

接続の軸には、構造、関係、緊張、対比、変化、留保、反復、不在、選択などを含む。Themeや単語の一致は判定根拠にしない。

## 3. relation type

| 種別 | 定義 | 原則distance |
|---|---|---|
| `same_domain` | 同じ具体領域に留まりつつ、単純な言い換えではない接続がある | `just_right` |
| `analogical_transfer` | 別の具体領域へ移りながら、構造や関係を対応付けられる | `just_right` |
| `direct_restatement` | 日記をほぼ言い換えるか、意味を完成させて発見の余白を奪う | `too_close` |
| `weak_connection` | 接続を説明するために大きな補修が必要で、短い内省では橋が見えにくい | `too_far` |
| `unrelated` | 短く考えても合理的な構造的・意味的接続がない | `not_obserbing` |

`analogical_transfer`では、日記側とLine側の役割を対応付けられるかを確認する。Line中の具体例をユーザーの事実として扱わずに対応関係を説明できれば、具体語の不一致はマイナスにしない。

## 4. 不適合条件

- `user_fact_assertion`：日記に根拠のない人物、出来事、数量、感情、動機、性格、状況を、ユーザー自身の現実として断定または前提化する。
- `explicit_contradiction`：日記に明示された事実とLineが矛盾する。
- `advice_or_diagnosis`：助言、指示、診断、人格・感情断定、励まし、称賛、説教、説得、強い誘導を行う。
- `clearly_unrelated`：構造や関係など、合理的に説明できる接続がない。

具体語を含む一般論、比喩、独立した情景、類推は、それだけでは`user_fact_assertion`ではない。ユーザーに結び付ける表現や、ユーザーの現実として扱う文法・文脈があるかを判定する。

いずれかの不適合条件が真なら`acceptable=false`、`distance=not_obserbing`とする。`clearly_unrelated=true`の場合は`relation_type=unrelated`も必須とする。

## 5. acceptableとdistance

`acceptable=true`は次をすべて満たす場合に限る。

- `distance=just_right`
- `relation_type`が`same_domain`または`analogical_transfer`
- 4つの不適合条件がすべて偽
- 接続を見つけるための小さな距離があり、結論を決め切らず、投稿者側に意味発見の余地が残る

`too_close`は正確さの不足ではなく、近すぎて余白がないことを示す。`too_far`は具体領域の違いではなく、接続に大きな解釈上の補修が必要なことを示す。完全に接続がなければ`not_obserbing`とする。

## 6. 評価手順

1. Entry本文とLine本文だけを読む。IDは照合用に保持してよい。
2. 旧ラベル、Theme、Embedding similarity、Provider、モデル、旧judgeを見ない。
3. 不適合条件を互いに独立して判定する。
4. Entry側とLine側の構造・関係をそれぞれ短く言語化する。
5. 別領域なら、ユーザー事実を捏造せずに役割を対応付けられるか確認する。
6. 言い換え、適切な距離、弱い接続、無関係の順に分類する。
7. 理由には、成立した接続または不成立理由を具体的に記す。
8. genuinely ambiguousなケースは`confidence=low`として人間確認へ回し、無理に確定扱いしない。

## 7. 記録項目

各ペアに次を記録する。

- `acceptable`
- `distance`: `too_close` / `just_right` / `too_far` / `not_obserbing`
- `relation_type`: `same_domain` / `analogical_transfer` / `direct_restatement` / `weak_connection` / `unrelated`
- `user_fact_assertion`
- `explicit_contradiction`
- `advice_or_diagnosis`
- `clearly_unrelated`
- `confidence`: `high` / `medium` / `low`
- `reason`

## 8. 固定条件

- judgeは`codex_reassessment`とし、人間評価と区別する。
- 新基準でも表示許容率90%以上を比較用の閾値として保持する。
- 外部AI API、Embedding API、SAFETY、abstraction、Line再選定を実行しない。
- 旧成果物と当時の判断を変更・削除しない。
- 再評価完了後にのみ旧ラベルを結合し、変化を集計する。
