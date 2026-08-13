# ドキュメント索引

本書をobserbingのドキュメント体系の正本とする。仕様、設計、評価基準、調査・意思決定履歴、旧仕様、開発運用の参照先を分離し、文書の位置づけと優先順位を定義する。

## 文書の位置づけ

1. 上位仕様
   - [ルートREADME](../README.md)：プロジェクト概要と技術方針
   - [要件定義書](requirements/要件定義_v1_0.md)：現行の上位要件
2. 基本設計・詳細設計
   - [`docs/design/`](design/)：上位仕様を実現する現行設計
   - [AI基本設計](design/AI基本設計.md)
   - [B-v2 AI選定基本設計](design/ai/B-v2_AI選定基本設計.md)
   - 今後作成する`Rails基本設計.md`等もこの配下へ置く
3. 現行評価基準
   - [`docs/evaluation/`](evaluation/)：現在も有効な評価基準・ルーブリック
   - [Reflective Distance 評価ルーブリック](evaluation/Reflective_Distance_評価ルーブリック.md)
4. 調査・意思決定履歴
   - [`docs/research/`](research/)：PoC、比較、調査、診断、採否判断、Gate判定、Epic結果
   - 不採用だった実験も削除またはarchiveせず、意思決定履歴として保持する
5. 旧仕様
   - [`docs/archive/`](archive/)：現在の設計へ完全に置換され、通常の調査履歴として参照する必要もない旧仕様
6. 開発運用
   - [ルートAGENTS.md](../AGENTS.md)：Issue、branch、PR等の開発運用ルール
   - `AGENTS.md`はプロダクト仕様ではない

## 優先順位

同じ論点に矛盾がある場合は、次の順序と扱いに従う。

- 上位仕様を優先する。
- designは上位仕様に従う。
- researchのPoC結果は、上位仕様またはdesignへ正式反映されるまでは現行仕様として扱わない。
- archiveは新規設計の正本として扱わない。
- 同一レイヤーで矛盾する場合は勝手に解釈せず、未決定事項として扱う。

**「PoCで良い結果が出た」ことと「現行仕様として採用された」ことは別である。**

## ディレクトリ構成

```text
docs/
├─ README.md
├─ requirements/
├─ design/
│  └─ ai/
├─ evaluation/
├─ research/
│  └─ ai/
│     ├─ initial-poc/
│     ├─ abstraction-only/
│     └─ b-v2/
└─ archive/
```

## 現行仕様・設計・評価基準

### requirements

- [要件定義書](requirements/要件定義_v1_0.md)

### design

- [AI基本設計](design/AI基本設計.md)
- [B-v2 AI選定基本設計](design/ai/B-v2_AI選定基本設計.md)

### evaluation

- [Reflective Distance 評価ルーブリック](evaluation/Reflective_Distance_評価ルーブリック.md)

## 調査・意思決定履歴

### initial-poc

初回AI PoCの事前計画、個別比較、統合結果、採否判断を保持する。

- [AI一行選定 PoC計画](research/ai/initial-poc/AI_PoC計画.md)
- [AI一行選定 PoC結果](research/ai/initial-poc/AI_PoC結果.md)
- [Embedding候補検索 PoC比較](research/ai/initial-poc/Embedding_PoC比較.md)
- [Line候補評価 PoC比較](research/ai/initial-poc/Line評価_PoC比較.md)
- [SAFETY判定 PoC比較](research/ai/initial-poc/SAFETY_PoC比較.md)
- [統合PoC比較](research/ai/initial-poc/統合_PoC比較.md)

### abstraction-only

追加PoC、abstraction-only方式、Reflective Distance再評価の履歴を保持する。

- [AI追加PoC計画](research/ai/abstraction-only/AI_追加PoC計画.md)
- [AI追加PoC結果](research/ai/abstraction-only/AI_追加PoC結果.md)
- [SAFETY追加PoC比較](research/ai/abstraction-only/SAFETY_追加PoC比較.md)
- [Abstraction追加PoC比較](research/ai/abstraction-only/Abstraction_追加PoC比較.md)
- [Abstraction Embedding追加PoC比較](research/ai/abstraction-only/Abstraction_Embedding_追加PoC比較.md)
- [Line事実整合ガード 追加PoC比較](research/ai/abstraction-only/Line事実整合ガード_追加PoC比較.md)
- [LLMなしLine選択 追加PoC比較](research/ai/abstraction-only/LLMなしLine選択_追加PoC比較.md)
- [Abstraction Only 統合PoC比較](research/ai/abstraction-only/Abstraction_Only_統合PoC比較.md)
- [Abstraction Only ライブ統合追補](research/ai/abstraction-only/Abstraction_Only_ライブ統合追補.md)
- [Reflective Distance 再評価](research/ai/abstraction-only/Reflective_Distance_再評価.md)

### b-v2

Epic #40、Issue #59、#61等のB-v2検証、比較、Gate、follow-up診断を保持する。

- [B-v2 Profile表現比較](research/ai/b-v2/B-v2_Profile表現比較.md)
- [B-v2 Band-passオフライン検証](research/ai/b-v2/B-v2_Band-passオフライン検証.md)
- [B-v2 Grounding / Policy再設計](research/ai/b-v2/B-v2_Grounding_Policy再設計.md)
- [B-v2 Selector比較](research/ai/b-v2/B-v2_Selector比較.md)
- [B-v2 本統合実API PoC](research/ai/b-v2/B-v2_本統合実API_PoC.md)
- [B-v2 / B-v1比較](research/ai/b-v2/B-v2_B-v1比較.md)
- [B-v2 Gate A判定](research/ai/b-v2/B-v2_Gate_A判定.md)
- [B-v2 Lineプール改善移行判断](research/ai/b-v2/B-v2_Lineプール改善移行判断.md)
- [B-v2 Epic結果](research/ai/b-v2/B-v2_Epic結果.md)
- [B-v2 帯域感度追補診断](research/ai/b-v2/B-v2_帯域感度追補診断.md)
- [B-v2 軽量selectorオフライン比較](research/ai/b-v2/B-v2_軽量selectorオフライン比較.md)

## archive

archiveの条件と現在の収録状況は[archive README](archive/README.md)を参照する。
