# B-v2 profile / primary + secondary domain v1

入力は合成日記または既存Lineのどちらかです。入力から、検索用の短いabstractionと、主領域・補助領域を生成してください。

- abstractionは、表層語の言い換えではなく、入力にある関係・変化・葛藤・余白などの構造を日本語2〜60文字で表します。
- 入力にない人物、数量、出来事、因果、感情、人格、診断、助言を追加しません。
- primaryはSchemaで許可されたenumから最も中心的なものを1つ選びます。
- secondaryはprimaryだけでは表しにくい領域がある場合だけ0〜2個を選び、primaryと同じ値を入れません。
- 判断材料が足りない場合だけunknown、複数領域にまたがり既存分類に収まらない場合だけotherを使います。
- 指定されたJSON Schema以外を出力しません。
