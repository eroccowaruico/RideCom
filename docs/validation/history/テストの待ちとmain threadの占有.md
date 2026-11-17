# テストの待ちとmain threadの占有

2026-11-17。2026-11-15の`scripts/validate.sh macos`（649件）で1回だけ失敗した`CommandSchedulingTests.reconnectAfterOverflowAppliesSettingsRequestedDuringFailure`を調べ、テスト共通の待ち（`AppTestSupport.waitUntil`）を直した。製品側の変更はない。

## 失敗の内容

再接続後の`routes.last == [.webRTC]`と`localMuteValues.last == true`が不成立で、テストは1.004秒で終わっていた。同じ日の他の全体実行3回と、このsuiteだけの連続15回は成功していた。失敗時の作業差分は`GroupRepository`の整理だけで、この試験が使う`RideIntercomCallSessionAdapter`とコマンドキューには差分がなかった。

## 原因

`waitUntil`は、条件を10ミリ秒おきに確かめ、開始からの実時間が上限（既定1秒）を超えたらやめていた。Appのテストはほぼすべてmain actorで動き、並列に実行しても1本のmain threadを分け合う。別のテストがmain threadを1秒以上使い続けると、待っている処理が1度も進まないまま、待ちだけが時間切れになる。

| 確認 | 結果 |
|---|---|
| 再現テスト（`TestWaitTests.aWaitThatTheMainThreadKeptFromRunningStillSeesTheAwaitedWork`） | main threadを1.2秒占有した後に完了する処理を待つ。直す前は1.202秒で待ちが切れ、処理が進む前に検査して失敗した。直した後は成功 |
| 失敗した試験の経路（コードの読み） | この試験の手順で2つの検査が成立しなくなるのは、再接続後の`startMedia`が実行される前に検査した場合である。試験は切断の完了を待ってから再接続するため、通常の実行では再接続が捨てられる順序にならず、成功を繰り返している |

## 直した内容

`waitUntil`の上限を、実時間ではなく条件を確かめた回数（上限÷10ミリ秒）で数える。確かめるたびにmain actorへ順番を返すので、main threadが占有されていた時間は待った時間に入らない。占有のない実行では、上限はこれまでと同じ長さになる。`waitUntil`は170か所で使っており、同じ原因の時間切れはすべての箇所で起きなくなる。

## 検証

| 対象 | 結果 |
|---|---|
| `TestWaitTests`（2件）と`CommandSchedulingTests`（7件） | 成功 |
| `scripts/validate.sh macos` | 全段階passed |

## 確かめていないこと

2026-11-15の失敗そのものは再現していない。1.004秒という所要時間と、再現テストで確かめた仕組みからの推定である。同じ試験が再び失敗した場合は、待ちの時間切れではないので、失敗した実行の`macos-tests.log`で`stopConnection`から次の`startMedia`までの順序を確認する。
