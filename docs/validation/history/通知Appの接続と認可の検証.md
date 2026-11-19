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


## 通知のマニュアルと実装状態の整合

2026-11-17、通知マニュアルに残る廃止済みの端末OFF・手動確認ボタンと、最初の1対1の接続だけで許可を交換する旧案内を修正した。OS設定でのON／OFF、前面復帰での自動登録・取消再試行、直接招待の登録時の許可交換と1対1での再交換、古い通知の一覧への復帰へ揃えた。通常APNs／UserNotificationsと不使用のframework、前景の通話中の表示判断と背景の未対応も明記し、操作の流れの現行表に残る旧action・電話型表示の記述を訂正した。

文書のみの変更で、現行の通知仕様・`CallNotifications`・`AdvancedCallNotificationStatusSection`・通知のMarkdown／HTMLと照合した。前節のmacOS／iOS Simulator各47件は今回変えていない通知処理の証跡として参照し、再実行や実OS／APNs受入の成功へ読み替えていない。文書リンク・diff検査成功。

## 送り主を照会できない通知から今の通話を開く

2026-11-19、接続待ち・音声の一時停止を含む通話中に、通常通知の「接続」や本体のタップで今の通話を表示するようにした。宛先と受信設定を端末内で確認し、通話中なら照会しない。未接続で始めた照会の途中に通話が始まった場合も、表示するのは今の通話。未接続のまま送り主を確認できなければ、ユーザー一覧を開く。

| 検証 | 証跡・結果 |
|---|---|
| 変更前 | `.validation/call-notification-current-call-red-20261119`で49件を実行。追加した3ケースに7件の期待不一致。HTTP 410・503、照会を待つ間に通話を開始、別の宛先の通知で、通話を開かずユーザー一覧に遷移する動作を確認 |
| App回帰 | `.validation/call-notification-current-call-green-20261119`。iPhone Simulatorで通知、署名付き許可、1対1の66件成功。接続待ちと機器変更による音声停止、照会中の接続開始、別宛先、未接続での期限切れ、ログイン世代の変更を確認。失敗・skip・実行時警告は0 |
| iPhoneの画面 | `.validation/call-notification-current-call-sheet-focused-20261119`。Standardでグループを選び、通話シートを閉じ、送り主を照会できない通知の応答入口を検証ボタンから呼んだ。同じグループ名で通話シートが再表示され、切断の確認後にグループ一覧へ戻り、通話のアクセサリが消えることを確認。XCUITest 1件成功。失敗・skip・実行時警告は0。応答の入力だけを検証用とし、実際の通話シート・切断・一覧には製品Appを使用。検証用の差分は同所に保存し、製品ソースから撤去 |
| 検証環境 | 先のUI 2回は、既存の一覧操作を終えた後にSimulatorの向きの再指定・App終了の処理を待ち、通知の試験に到達する前に中断した。単独の試験で切断まで操作し、これらの後処理を省いた。通常DebugのmacOS Appビルドと、Debug-Validationのテストターゲットのビルドは成功（`.validation/call-notification-current-call-mac-build-20261119`）。初回は通常Debugをテストにも指定し、既存の検証用fixtureが見つからず停止した。正規構成で再実行し、既存の非同期sleepとApp Intentsメタデータの警告を確認した |
| 定義 | 通知仕様、通知と操作の流れのMarkdown・HTML、およびマニュアルを照合。HTMLの構造・アンカーを検査し、Chromeの印刷描画で通知操作の説明と見本を確認 |

入力指紋は採番以外一致。実APNsによる配送とOS上での通知操作、実端末のロック解除・コールド起動は[実環境の受入](../未確認事項.md#通常通知の受入)に残る。

## 背景に届く通知の音と割り込みレベル（2026-11-19）

操作直後に別Appへ移っても会話を遮らないよう、受信時にAppが前面になくても、元の通常APNsアラートだけで静かに届くかを先に試した。Appleの仕様では、通知拡張が結果を返せない場合は元のアラートを表示する。このため、元を音なしのpassiveにし、拡張が端末で待機中と確認できた場合だけactiveと音を設定する案を試験した。[通知拡張の仕様](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)、[passiveの仕様](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/passive)。

専用のAppと同梱した通知拡張をiOS 27.2 Simulatorでビルドし、XCUITestで通知を許可した。Appが共有領域に書く状態を変え、別Appを開いた後に `simctl push` でアラートを注入した。最初の試行はAppが背景に落ち着く前に注入し、OSの配信済み通知を取得できなかった。移行から5秒待った試行で以下の5件を取得した。

| 注入した通知 | OSの配信済み内容 |
|---|---|
| 現行の呼び出し相当（active、default sound） | active・音の指定あり |
| 元のアラートだけ（passive、音の指定なし） | passive・音の指定なし |
| passiveにmutable-contentを付けた3件（接続中、待機中、状態なし） | いずれも元のpassive・音の指定なし。拡張の実行記録は0 |

ローカル注入で拡張が起動しないことは[AppleのSimulatorリリースノート](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)の制約と一致する。元のアラートが静かに残ることまで確認した。待機中に音を付ける案には実APNs Sandboxと署名の確認が要る。背景の呼び出しの製品payloadは現行のまま。証跡は `.validation/background-notification-extension-probe-20261119` の `permission.xcresult`、`observations.json`、`mutable-os.log`、試験用ソース。専用Simulatorは回収済み。

グループ招待は端末の通話状態によらず静かに届ける契約のため、同じ試験を根拠に、Workerの固定アラートへpassiveを指定した。1回の通知、音の指定なし、暗号文を含めないこと、呼び出しと別のcategory、既存の受信箱と取消を維持した。最初の確認で招待のpayloadに指定が欠けることをローカルWorkerで再現し、変更後に通常の呼び出しを含む全82件と型検査が成功した。再点検では割り込みレベルの既定をWorkerの用途別payloadに置き、受信箱・宛先の認可と通話処理から独立していることを確認した。前景でApp自身が返す表示オプションは次のApp工程で揃える。証跡は同ディレクトリの `group-server-red.log` と `group-server-final.log`。
