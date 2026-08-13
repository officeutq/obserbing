# Reflective Distance 再評価

**文書ステータス：Codexオフライン一次評価完了・低確信ケースは人間確認待ち**

**評価版：`reflective-distance-reassessment-v1`**

**作成日：2026年8月13日**

**関連Issue：#38（Epic #27完了後の追補）**

## 1. 結論

Issue #36で保存された108表示を、外部AI APIを一切呼ばず、`reflective-distance-v1`でゼロベース再評価した。暫定許容は54 / 108（50.00%）、`analogical_transfer`は35件で、35件すべてを許容とした。旧基準で致命的事実不整合だったE001 / L083は、ユーザーの事実を断定しない別領域への類推として許容へ変更した。

同じ基準で`selected-v1`も再評価した。旧Blind評価32表示は9 / 32（28.13%）、保存済みLine到達98表示は27 / 98（27.55%）だった。母数、SAFETY停止Entry、反復ごとの選択分布が異なるため厳密な同条件比較ではないが、新基準では`abstraction-only-v1-diagnostic`が`selected-v1`の98表示より22.45ポイント高い。方式間の相対評価はabstraction-only側へ変わった。

ただし、abstraction-onlyは固定した90%基準を満たさない。低確信13表示をすべて許容へ変更しても最大60 / 108（55.56%）である。評価思想と旧fatalの解釈を見直す根拠は生じたが、Epic #27の方式不採用を覆す根拠にはならない。Epic #27はreopenしない。

## 2. 事前固定とアンカリング回避

個別結果を見る前に[Reflective Distance 評価ルーブリック](Reflective_Distance_評価ルーブリック.md)を作成し、コミット`51b398f`で固定した。Entry本文とLine本文だけを入力にした99種類の一意ペアの判断をコミット`ccd13e9`、保存済みbaseline 98表示を完全被覆する6ペアの追加をコミット`6794b76`で固定した。その後にだけ旧ラベルを結合した。

新評価中は次を入力から除外した。

- 旧`acceptable`、旧`distance`、`fatal_grounding_mismatch`
- Theme、Embedding similarity
- Provider、モデル、旧judge

同じEntry / Lineが反復された場合は、同一のテキスト判断を各表示へ再利用した。Codex評価は`judge=codex_reassessment`とし、人間評価とは区別する。

## 3. 新ルーブリックの要点

中心となる問いは「一見すると少し違うLineから、短く考えることで日記との構造的・関係的な接続を自分で発見できるか」である。

| relation type | 扱い |
|---|---|
| `same_domain` | 同じ領域で、言い換えにならず小さな発見距離を作るなら許容 |
| `analogical_transfer` | 別領域でも構造・緊張・対比・変化等を対応付けられれば許容 |
| `direct_restatement` | 意味をほぼ完成させて余白を奪うため`too_close`・不許容 |
| `weak_connection` | 接続に大きな解釈上の補修が必要なため`too_far`・不許容 |
| `unrelated` | 合理的な接続がなく`not_obserbing`・不許容 |

具体的な人物、物、数量、場所、出来事がLineにあること自体は違反にしない。Lineがそれをユーザーの現実として断定・前提化した場合だけ`user_fact_assertion=true`とする。日記との明示的矛盾、助言・診断・人格や感情の断定、完全な無関連は独立した不適合条件とする。

## 4. abstraction-only 108表示の再集計

| 指標 | 新評価 |
|---|---:|
| evaluated | 108 |
| 一意なEntry / Line | 84 |
| acceptable | 54（50.00%） |
| `just_right` | 54 |
| `too_close` | 29 |
| `too_far` | 16 |
| `not_obserbing` | 9 |
| `analogical_transfer` | 35 |
| analogical transferのacceptable | 35 / 35（100%） |
| `same_domain` | 19 |
| `direct_restatement` | 29 |
| `weak_connection` | 16 |
| `unrelated` | 9 |
| `user_fact_assertion` | 0 |
| `explicit_contradiction` | 0 |
| `advice_or_diagnosis` | 0 |
| `clearly_unrelated` | 9（8.33%） |
| low confidence | 13表示・10種類 |

低確信を除いた95表示では47件許容、49.47%だった。低確信10種類の暫定判断をすべて反転させても90%へ到達しないため、人間確認の結果は今回の方式採否を変えない。

## 5. 旧評価からの変化

旧評価はOpenAI一次評価にE001 / L083のCodex重要ケース補正を適用した最終版を使った。

| 変化 | 件数 |
|---|---:|
| `acceptable`または`distance`が変化 | 38 / 108 |
| `acceptable`が変化 | 30 / 108 |
| `distance`が変化 | 32 / 108 |
| old `too_close` → new acceptable | 5 |
| old `too_far` → new acceptable | 0 |
| old fatal → new `analogical_transfer` | 1 |
| old acceptable → new unacceptable | 28 |

old `too_close`から許容へ変わった5表示は、E012 / L036が1表示、E022 / L053が3表示、E029 / L095が1表示である。旧評価では近すぎるとされたが、新評価ではそれぞれ逆説や時間の再配置による発見距離が残ると判断した。

old `too_far`から許容へ変わった表示は0件だった。新基準は「別領域だから遠い」という判定を禁止したが、旧`too_far`の各ペアを本文だけで再評価した結果、構造的な橋が十分だったものはなかった。

旧許容から新不許容へ28件変わった主因は、具体一致の不足ではなく、直接言い換えまたは弱い接続である。新基準は類推を救済すると同時に、正確でも近すぎて発見の余白がないLineを高評価にしない。

## 6. 代表ケース

### E001 / L083：旧fatalから類推へ

Entry：

> 二つの案のどちらを選んでも、選ばなかった方が気になりそうだ。

Line：

> 選んだ一人にも、選ばなかった誰かの気配がある。

新評価は`acceptable=true / just_right / analogical_transfer / user_fact_assertion=false / confidence=high`とした。「案」から「人物」へ領域は変わるが、選んだ側にも選ばなかった側の不在が残る構造を保つ。Lineは「あなたが誰かを選んだ」と述べておらず、独立した一般表現であるため、ユーザー事実の捏造ではない。

### E033 / L102：数量はユーザー事実ではない

Entry：

> もっとできたはず、という言葉だけはいつも準備がいい。

Line：

> 終えた三つより、始めなかった一つは声が大きい。

新評価は`acceptable=true / just_right / analogical_transfer / user_fact_assertion=false / confidence=high`とした。三つと一つはユーザーが実際に行った数量の断定ではなく、達成より未達が強く残る構造を見せる独立した具体例である。旧baselineのfatalは解除する。

### E024 / L076：一見遠いが構造が接続する

Entry：

> 終わったことに名前をつけると、まだ続いていた部分まで終わる気がする。

Line：

> 終わった線の先にも、同じ紙が続いている。

命名された終わりと、その外に残る連続性を、線と紙へ転写している。具体領域は異なるが、境界と継続の構造が短い内省で見えるため`analogical_transfer`として許容した。

### 新基準でも明確にNG

- E006 / L044：相反する根拠の釣り合いと、仕事の区切りを光で測ることに合理的接続がなく、`unrelated / not_obserbing`。
- E002 / L073：返答前に希望を見失うことと、名前によって終わりの輪郭が濃くなることに接続がなく、`unrelated / not_obserbing`。
- E001 / L001：「選ばなかった方が残る」というEntryをほぼそのまま比喩化し、発見距離が小さすぎるため`direct_restatement / too_close`。

今回の表示群には、ユーザー事実断定、明示的矛盾、助言・診断に該当するLineはなかった。新基準のNGは主に直接言い換え、弱い接続、完全な無関連である。

## 7. selected-v1の同基準比較

`selected-v1`の既存成果物から、旧Blind評価の32表示に加え、Lineまで到達した98表示すべてをAPI再実行なしで復元した。

| 対象 | acceptable | `just_right` | `too_close` | analogical | same domain |
|---|---:|---:|---:|---:|---:|
| 旧Blind標本 | 9 / 32（28.13%） | 9 | 23 | 3 | 6 |
| 保存済みLine到達全件 | 27 / 98（27.55%） | 27 | 71 | 10 | 17 |
| abstraction-only Issue #36 | 54 / 108（50.00%） | 54 | 29 | 35 | 19 |

旧基準の`selected-v1` 96.88%と新基準のabstraction-onlyを直接比較していない。両方式を同じ新ルーブリックで評価した。`selected-v1`はEntryに合うLineを高率で選んでいたが、新基準では71 / 98が意味を完成させすぎる`direct_restatement`となった。

それでも比較には制約がある。abstraction-onlyは通常Entry 36件×3反復、selected-v1はSAFETY停止後の33 Entryに対する98表示で、選択分布も異なる。22.45ポイント差は新基準下の保存結果の差であり、統制された新実験の差ではない。

## 8. 人間確認待ち

次の10種類、13表示は`confidence=low`である。括弧内はCodexの暫定判断で、採否の確定を人間に強制しない。

| Pair | 表示数 | 暫定判断 | 確認したい境界 |
|---|---:|---|---|
| E004 / L092 | 2 | 不許容・`weak_connection` | 当日直前と待ち時間終端の接続が十分か |
| E005 / L117 | 1 | 許容・`analogical_transfer` | 湯気の時間が現在の通過を十分照らすか |
| E008 / L021 | 1 | 不許容・`weak_connection` | 聞くことと残る声の対応が成立するか |
| E013 / L012 | 1 | 許容・`analogical_transfer` | 説明できない進捗を形成途中と読めるか |
| E019 / L074 | 1 | 許容・`same_domain` | 配置変更と空いた場所の知覚を接続できるか |
| E023 / L073 | 1 | 許容・`same_domain` | 削除と命名を終わりの輪郭で結べるか |
| E023 / L118 | 1 | 不許容・`weak_connection` | 写真削除と景色の反復に十分な橋があるか |
| E025 / L027 | 2 | 不許容・`weak_connection` | 共有したい余韻と次を要求しない共有が接続するか |
| E030 / L065 | 2 | 許容・`analogical_transfer` | 年の短縮感を慣れの遅れで照らせるか |
| E034 / L088 | 1 | 許容・`same_domain` | 共有されない出来事をEntryから導けるか |

## 9. 採用判断への影響

今回生じた見直し根拠は二つある。

1. 具体語の不一致をfatalに直結させる旧grounding評価はobserbingの価値を取りこぼす。将来の評価・ガードでは`analogical_transfer`と`user_fact_assertion`を分離する必要がある。
2. 同じ新基準ではabstraction-onlyがselected-v1より高く、方式間の相対評価は変わる。abstraction-onlyが「近すぎないLine」を多く出す特徴は次方式の部品候補になる。

一方、abstraction-onlyの50.00%は90%基準を大きく下回り、候補集合Jaccard 0.672という既存の不安定性も変わらない。したがって`abstraction-only-v1`を詳細設計候補へ昇格せず、Epic #27の方式不採用判断は維持する。次へ進むなら、新評価基準を事前固定した別Epicで、類推を残しながら直接言い換え・弱い接続・無関連を減らす方式を検証する。

## 10. 外部APIと成果物

外部AI API、Embedding API、SAFETY、abstraction、Line再選定の呼び出しはすべて0回である。生成スクリプトは既存JSONL / CSV / YAMLを読み、ローカル集計するだけで、HTTPクライアントやProvider Adapterを使用しない。

既存成果物と当時の判断文書は変更していない。新規成果物は次の通りである。

- `reflective_distance_rubric_v1.yml`：事前固定ルーブリック
- `reflective_distance_codex_judgments_v1.csv`：旧ラベルを見ずに作成した一意ペア判断
- `reflective_distance_display_pairs_v1.csv`：108表示とbaseline 98表示の版付き対応表
- `reflective_distance_previous_labels_v1.csv`：再評価後に結合した旧ラベル
- `reflective_distance_reassessment_v1.yml`：集計・差分・代表ケース・低確信一覧

ローカルの既存生成果物がある環境では次で再生成できる。必要ファイルがなければ停止し、APIで補完しない。

```powershell
ruby script\generate_reflective_distance_reassessment.rb
```
