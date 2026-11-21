# 通話操作の参照

`CallControl` は通話操作を現在のログイン世代・接続世代・グループに結び付ける値と変換を持つ。Foundationだけを使用する。世代を発行し、現在値との一致と操作の可否を判定する責務は利用側にある。参照の値は本人・通話先の認証資格に使わない。

| 契約 | 入力と結果 |
|---|---|
| `CallReference` | `accountAccessID` と `connectionGeneration` はUUID、`groupID` はUUIDまたは欠落。欠落は通話前のマイク設定などに使う待機状態。比較には3項目をすべて使う |
| 操作の文字列 | `accountAccessID`、`connectionGeneration`、`groupID` の順に `UUID.uuidString` を `|` で連結する。待機状態では3項目目を `idle` にする。進行中の参照はUTF-8で110バイト |
| `CallSurfaceReference` | 表示した進行中の通話専用。`CallReference` の `displayedCall` は `groupID` がある場合だけ値を返す。`callReference` で3項目を保った元の値へ戻る。文字列の読取では110バイト、区切られた3項目、各UUIDを照合し、待機状態・欠落・不正形式を拒否する |
| 共有JSON | 進行中の参照は `accountAccessID`、`connectionGeneration`、`groupID` の3つのUUID値を持つオブジェクトとして符号化する。`groupID` が欠落したJSONは拒否する |

`swift test --package-path RideIntercom/packages/CallControl` で文字列の固定例、待機状態の境界、不正な参照、JSON形式を確認する。利用側はこの値を用いて、サインアウトや再接続、別通話の後に届いた操作が現在の通話を変えないことを確かめる。
