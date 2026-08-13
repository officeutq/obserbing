# B-v2 Grounding / Policy再設計

## 結論

B-v1の`combined_v1`は継承しない。B-v2では「Line自体を承認する責務」と「投稿時にEntry・履歴と照合する責務」を分離し、`b-v2-guard-policy-v1`として#46前に固定する。

独立した一般表現、比喩、別の具体例、analogical transferは、Line内の人物・物・数量がEntry本文に存在しないという理由だけでは除外しない。除外するのは、Lineがそれらをユーザーの事実として断定・前提化する場合、Entryと明示的に矛盾する場合、助言・診断として作用する場合である。

## Line承認時

Line登録・変更時に、次を禁止する。

- 助言・診断
- 命令的な指示
- 人格・感情の固定
- ユーザーへ向けた未根拠断定
- 明示的な有害・禁止表現

一般表現、比喩、別具体例、ユーザーへ帰属しない人物・物・数量は許容する。現Approved 96 Lineは既存review済み集合をそのまま使用し、ID・本文・statusのcanonical hashを固定した。本文、status、承認集合は変更していない。

## 投稿時

次の順で決定的に適用する。

1. `status=approved`
2. profile / Embedding版の一致
3. Line承認policy
4. Entryとの明示矛盾
5. ユーザー事実の断定・前提化
6. 履歴・再利用

同じEntry / Lineペアは再利用せず、ユーザーの直近12表示に含まれるLineも除外する。idempotency retryは新規選択せず保存済みoutcomeを返す。候補0件でも閾値・policyを自動緩和しない。

profile / Embedding版の不一致、policy claim type不正、データ欠損は技術エラーであり、SILENCEに変換しない。すべての処理が正常に完了した後、適格候補が0件の場合だけ`no_eligible_candidate_after_policy`によるsemantic SILENCEとする。

## 回帰条件

旧fatalだった`E001 / L083`と`E033 / L102`は、ユーザー事実の断定ではなく独立したanalogical expressionであるため許容する。これは個別pairを特例許可する実装ではなく、「独立Line内の具体をEntry事実と同一視しない」という責務分離の回帰例である。

## 実行制約

外部APIは0回、Lineプール変更は0件、固定済みGate基準の変更は0件である。機械可読な責務・版・履歴ルールは`b_v2_guard_policy_v1.yml`へ保存した。
