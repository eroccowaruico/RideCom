# 通知Appの接続と認可の検証

2026-10-31、`71527487062db6c207fa59e70e41cad1c3f6d54d`から隔離した`RideIntercom-notification-app`でApp側だけを実装した。server APIは並行工程の`de94ebef5c43890cd88ab3417525029bd65636be`の契約に合わせ、server/packageは変更していない。現行契約は[通知仕様](../../spec/App/通知仕様.md)、実配送等は[未確認事項](../未確認事項.md#通常通知の受入)を参照する。

| 対象 | 条件 |
|---|---|
| 外部I/O | URLProtocolのHTTPmock、端末内の一時鍵と既存offline App harnessを使用。実OS許可、実APNs、Cloudflare、実マイク・スピーカーを使用しない |
| HTTP契約 | 固定device/grant/callのfield、native bearer、可変長token、requestID/期限/状態を確認。名前・自由text・group情報を送らず、acceptedをdeliveredとして扱わない |
| 認可 | 保存した直接相手の鍵とprincipal、用途を区切った署名、取消とrevision、一覧外/group-only拒否を確認。既知の別端末のcounter・取消を区別し、選択相手と異なるcapabilityの宛先を拒否。正しいWorker形のJWTは受領でき、claims一致だけではserverの署名・active grant検証を省略しない |
| 共通操作 | 利用者のtap後のGETと再解決から共通CallActionsへ実際に渡し、モデル置換後の遅延tapを拒否。新しい通話先への切替を通知専用に実装しない |
| 端末OFF | 解除失敗後の再試行、PUT待ち中のOFF、再ON前後の古いcleanup、新しいPUTの前にDELETEが完了する順序を確認 |
| 前面 | OFF・ログイン終了・recipient不一致を端末内で表示抑止し、到着だけのネット照会を行わない |
| プライバシー | 通常groupのgrant送信/受理拒否、対象principalが一致する単一peerの1対1接続だけで交換。新grantの保存失敗はbest-effort取消1回 |

最終証跡は専用の`.validation/notification-final`に保存した。

| 最終検証 | 結果 |
|---|---|
| macOS | 通知30件と通話・直接招待・アカウント関連を含む8 suite、96件成功。失敗・skip・runtime warningなし。`macos.xcresult`と`macos-summary.log` |
| iOS | generic iOS Simulator向けApp build成功。Simulatorを起動せず、実OS許可を出していない。`ios-build.log` |
| 翻訳 | 追加29keyのcompiled英日を確認し、既存catalog項目が意味・値とも不変。`localization.json`。rootへの手渡しは追加key JSONだけとし、catalog全体を上書きしない |
| ソース・資源 | 330のsource/configurationファイルが検証前後一致。project-owned build番号以外の変更なし。専用DerivedDataを排他し、所有Mac hostの残存なし。`source-before.json`・`source-after.json`・`cleanup.json` |
| 文書 | link・navigation・Settings coverage・diff check成功 |

先行の失敗・空のmethod選択を成功件数へ数えていない。実OS・実配送と、その受入を代替した結果ではない。server/packageを変更せず、ここでは再実行していない。

## 取消済み行の容量回復

公開前レビューで、削除した異なる相手の取消済み行が256枠に残ることを確認した。同principalの再追加は元から同じ行を再利用するが、取消済み行を回収すると発行revisionまで戻るため、既存アカウントDefaultsの単一counterへ引き継ぐ変更を追加した。日時・新protocol・端末間同期・別queueは追加していない。

256行の回収と新しい許可、同principal再追加と保存再読取後のrevision維持、取消失敗行の保持を先に失敗させた。符号・破損・counter上限時の失敗と発行済みgrant取消、回収保存失敗時のメモリ・ディスク保全も確認した。先行96件の結果はその時点の証跡として保持し、追加修正の最終結果は`.validation/notification-capacity-final`へ分けて保存した。

追加5テストを含む関連8 suite・101件が成功し、失敗・skip・runtime warningはない。generic iOS build・既存catalogと英日追加29key・文書検査も成功。検証前後330のsource/configuration入力が一致し、所有host残存はなく、Simulatorは起動していない。


## 前景の通話中通知を静かにする

2026-11-17、通常のAPNsとUserNotificationsを使い、CallKit・VoIP Push・AppleのPushToTalk frameworkを使わない利用者の前提を要求・仕様・Markdown・HTMLへ明記した。Appだけを変更し、前景の表示判断を`AppNotificationBridge.presentationOptions(for:)`へ集約した。接続待ち・音声の一時停止を含む通話中は`[.list]`、未接続は`[.banner, .list, .sound]`を返す。到着だけでは通話・画面を変えず、表示判断のネット照会は行わない。

| 検証 | 証跡・結果 |
|---|---|
| 変更前の失敗再現 | `.validation/notification-foreground-suite-red-20261117`。関連43テストを実行し、追加した表示テストで5件の期待不一致。通話中もバナー・音を返し、通知センターへの指定がないことを再現。空のmethod選択やコンパイル失敗は再現の成功に数えない |
| macOS最終回帰 | `.validation/notification-foreground-macos-final-20261117/app.xcresult`。NotificationClientTests・NotificationPermissionTestsの47件成功。失敗・skip・runtime warningは0 |
| iOS Simulator最終回帰 | `.validation/notification-foreground-ios-final-20261117/ui.xcresult`。同じ47件成功。失敗・skip・runtime warningは0。所有Simulatorを終了済み |
| 確認した経路 | App所有者・現在アカウント・端末受信ONの検証、待機→音声準備完了→デバイス変更による音声停止→切断の表示判断、到着による通話先・画面の変更とHTTP照会がないこと、既存の登録・取消・署名付き許可・タップ処理の回帰 |
| テストの修正 | 先行green実行では、追加テストの`endAccountAccess()`が非同期の端末登録解除を残し、次の既存テストへ混ざった。サインアウト済みアカウントを観測開始前に作る独立fixtureへ直し、両OSの最終回帰を再実行した |
| 定義とHTML | 要求・通知仕様・通知設計・HTML見本・残課題・未確認事項を対応付けた。文書リンク、String Catalog、diff、HTMLの主要コンテナの対応とID重複を検査 |

検証はAppホスト内の実モデルと、HTTP・音声・接続を置き換えた既存harnessによる表示オプションの判断である。実APNs・OSの許可や実際の通知音／バナー／通知センター、背景配送、端末ロック、Watchは未受入。HTMLのブラウザー描画も未検証。背景のpassive・音なし、名前の解決、通信の通知は通知拡張の未実装工程として保持する。ビルド番号の自動更新は番号だけの独立コミットに分けた。
