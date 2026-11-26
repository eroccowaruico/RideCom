# 通知Appの接続と認可の検証

2026-10-31、`71527487062db6c207fa59e70e41cad1c3f6d54d`から隔離した`RideIntercom-notification-app`でApp側だけを実装した。server APIは並行工程の`de94ebef5c43890cd88ab3417525029bd65636be`の契約に合わせ、server/packageは変更していない。現行契約は[通知仕様](../../spec/App/通知仕様.md)、実環境での送受信等は[未確認事項](../未確認事項.md#通常通知の受入)を参照する。

| 対象 | 条件 |
|---|---|
| 外部I/O | URLProtocolのHTTPmock、端末内の一時鍵と既存offline App harnessを使用。実OS許可、実APNs、Cloudflare、実マイク・スピーカーを使用しない |
| HTTP契約 | 固定device/grant/callのfield、native bearer、可変長token、requestID/期限/状態を確認。名前・自由text・group情報を送らず、acceptedをdeliveredとして扱わない |
| 認可 | 保存した直接相手の鍵とprincipal、用途を区切った署名、取消とrevision、一覧外/group-only拒否を確認。既知の別端末のcounter・取消を区別し、選択相手と異なるcapabilityの宛先を拒否。正しいWorker形のJWTは受領でき、claims一致だけではserverの署名・active grant検証を省略しない |
| 共通操作 | 利用者のtap後のGETと再解決から共通CallActionsへ実際に渡し、モデル置換後の遅延tapを拒否。新しい通話先への切替を通知専用に実装しない |
| 端末OFF | 解除失敗後の再試行、PUT待ち中のOFF、再ON前後の古いcleanup、新しいPUTの前にDELETEが完了する順序を確認 |
| 前面 | OFF・ログイン終了・recipient不一致を端末内で表示抑止し、到着しただけではネットへ照会しない |
| プライバシー | 通常groupのgrant送信/受理拒否、対象principalが一致する単一peerの1対1接続だけで交換。新grantの保存失敗はbest-effort取消1回 |

最終証跡は専用の`.validation/notification-final`に保存した。

| 最終検証 | 結果 |
|---|---|
| macOS | 通知30件と通話・直接招待・アカウント関連を含む8 suite、96件成功。失敗・skip・runtime warningなし。`macos.xcresult`と`macos-summary.log` |
| iOS | generic iOS Simulator向けApp build成功。Simulatorを起動せず、実OS許可を出していない。`ios-build.log` |
| 翻訳 | 追加29keyのcompiled英日を確認し、既存catalog項目が意味・値とも不変。`localization.json`。rootへの手渡しは追加key JSONだけとし、catalog全体を上書きしない |
| ソース・資源 | 330のsource/configurationファイルが検証前後一致。project-owned build番号以外の変更なし。専用DerivedDataを排他し、所有Mac hostの残存なし。`source-before.json`・`source-after.json`・`cleanup.json` |
| 文書 | link・navigation・Settings coverage・diff check成功 |

先行の失敗・空のmethod選択を成功件数へ数えていない。実OS・実環境での送受信と、その受入を代替した結果ではない。server/packageを変更せず、ここでは再実行していない。

## 取消済み行の容量回復

公開前レビューで、削除した異なる相手の取消済み行が256枠に残ることを確認した。同principalの再追加は元から同じ行を再利用するが、取消済み行を回収すると発行revisionまで戻るため、既存アカウントDefaultsの単一counterへ引き継ぐ変更を追加した。日時・新protocol・端末間同期・別queueは追加していない。

256行の回収と新しい許可、同principal再追加と保存再読取後のrevision維持、取消失敗行の保持を先に失敗させた。符号・破損・counter上限時の失敗と発行済みgrant取消、回収時の保存に失敗した場合のメモリ・ディスク保全も確認した。先行96件の結果はその時点の証跡として保持し、追加修正の最終結果は`.validation/notification-capacity-final`へ分けて保存した。

追加5テストを含む関連8 suite・101件が成功し、失敗・skip・runtime warningはない。generic iOS build・既存catalogと英日追加29key・文書検査も成功。検証前後330のsource/configuration入力が一致し、所有host残存はなく、Simulatorは起動していない。


## 前景の通話中通知を静かにする

利用者の前提は、通常のAPNsとUserNotificationsを使い、CallKit・VoIP Push・AppleのPushToTalk frameworkを使わないこと。2026-11-17、この前提を要求・仕様・Markdown・HTMLへ明記した。Appだけを変更し、前景の表示判断を`AppNotificationBridge.presentationOptions(for:)`へ集約した。接続待ち・音声の一時停止を含む通話中は`[.list]`、未接続は`[.banner, .list, .sound]`を返す。到着だけでは通話・画面を変えず、表示判断のネット照会は行わない。

| 検証 | 証跡・結果 |
|---|---|
| 変更前の失敗再現 | `.validation/notification-foreground-suite-red-20261117`。関連43テストを実行し、追加した表示テストで5件の期待不一致。通話中もバナー・音を返し、通知センターへの指定がないことを再現。空のmethod選択やコンパイル失敗は再現の成功に数えない |
| macOS最終回帰 | `.validation/notification-foreground-macos-final-20261117/app.xcresult`。NotificationClientTests・NotificationPermissionTestsの47件成功。失敗・skip・runtime warningは0 |
| iOS Simulator最終回帰 | `.validation/notification-foreground-ios-final-20261117/ui.xcresult`。同じ47件成功。失敗・skip・runtime warningは0。所有Simulatorを終了済み |
| 確認した経路 | App所有者・現在アカウント・端末受信ONの検証、待機→音声準備完了→デバイス変更による音声停止→切断の表示判断を確認した。到着による通話先・画面の変更とHTTP照会がないことを確認し、既存の登録・取消・署名付き許可・タップ処理の回帰 |
| テストの修正 | 先行green実行では、追加テストの`endAccountAccess()`が非同期の端末登録解除を残し、次の既存テストへ混ざった。サインアウト済みアカウントを観測開始前に作る独立fixtureへ直し、両OSの最終回帰を再実行した |
| 定義とHTML | 要求・通知仕様・通知設計・HTML見本・残課題・未確認事項を対応付けた。文書リンク、String Catalog、diff、HTMLの主要コンテナの対応とID重複を検査 |

検証はAppホスト内の実モデルと、HTTP・音声・接続を置き換えた既存harnessによる表示オプションの判断である。実APNs・OSの許可や実際の通知音／バナー／通知センター、バックグラウンドでの転送、端末ロック、Watchは未受入。HTMLのブラウザー描画も未検証。背景のpassive・音なし、名前の解決、通信の通知は通知拡張の未実装工程として保持する。ビルド番号の自動更新は番号だけの独立コミットに分けた。


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
| 検証環境 | 先のUI 2回は、既存の一覧操作を終えた後にSimulatorの向きの再指定・App終了の処理を待ち、通知の試験まで到達せず中断した。単独の試験で切断まで操作し、これらの後処理を省いた。通常DebugのmacOS Appビルドと、Debug-Validationのテストターゲットのビルドは成功（`.validation/call-notification-current-call-mac-build-20261119`）。初回は通常Debugをテストにも指定し、既存の検証用fixtureが見つからず停止した。正規構成で再実行し、既存の非同期sleepとApp Intentsメタデータの警告を確認した |
| 定義 | 通知仕様、通知と操作の流れのMarkdown・HTML、およびマニュアルを照合。HTMLの構造・アンカーを検査し、Chromeの印刷描画で通知操作の説明と見本を確認 |

入力指紋は採番以外一致。実APNsによる転送とOS上での通知操作、実端末のロック解除・コールド起動は[実環境の受入](../未確認事項.md#通常通知の受入)に残る。

## 背景に届く通知の音と割り込みレベル（2026-11-19）

操作直後に別Appへ移っても会話を遮らないよう、受信時にAppが前面になくても、元の通常APNsアラートだけで静かに届くかを先に試した。Appleの仕様では、通知拡張が結果を返せない場合は元のアラートを表示する。このため、元を音なしのpassiveにし、拡張が端末で待機中と確認できた場合だけactiveと音を設定する案を試験した。[通知拡張の仕様](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)、[passiveの仕様](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/passive)。

専用のAppと同梱した通知拡張をiOS 27.2 Simulatorでビルドし、XCUITestで通知を許可した。Appが共有領域に書く状態を変え、別Appを開いた後に `simctl push` でアラートを注入した。最初の試行はAppが背景へ移りきる前に注入し、OSの配信済み通知を取得できなかった。移行から5秒待った試行で以下の5件を取得した。

| 注入した通知 | OSの配信済み内容 |
|---|---|
| 現行の呼び出し相当（active、default sound） | active・音の指定あり |
| 元のアラートだけ（passive、音の指定なし） | passive・音の指定なし |
| passiveにmutable-contentを付けた3件（接続中、待機中、状態なし） | いずれも元のpassive・音の指定なし。拡張の実行記録は0 |

ローカル注入で拡張が起動しないことは[AppleのSimulatorリリースノート](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)の制約と一致する。元のアラートが静かに残ることまで確認した。待機中に音を付ける案には実APNs Sandboxと署名の確認が要る。背景の呼び出しの製品payloadは現行のまま。証跡は `.validation/background-notification-extension-probe-20261119` の `permission.xcresult`、`observations.json`、`mutable-os.log`、試験用ソース。専用Simulatorは回収済み。

グループ招待は端末の通話状態によらず静かに届ける契約のため、同じ試験を根拠に、Workerの固定アラートへpassiveを指定した。1回の通知、音の指定なし、暗号文を含めないこと、呼び出しと別のcategory、既存の受信箱と取消を維持した。最初の確認で招待のpayloadに指定が欠けることをローカルWorkerで再現し、変更後に通常の呼び出しを含む全82件と型検査が成功した。再点検では割り込みレベルの既定をWorkerの用途別payloadに置き、受信箱・宛先の認可と通話処理から独立していることを確認した。証跡は同ディレクトリの `group-server-red.log` と `group-server-final.log`。

続くApp工程で、前面の受信時に未接続ならバナーを要求する差を再現した。現在のアカウント宛てのグループ招待は、接続状態にかかわらず `AppNotificationBridge` から `[.list]` を返す。受信箱の取り込みを引き続き依頼し、表示中の画面と通話を維持する。最初の66件では未接続の表示検査1件が失敗し、修正後はiOSとmacOSで各66件が成功した。他アカウント宛ての通知拒否、受信・タップの画面遷移、暗号文の保存・受領も回帰した。失敗・skip・実行時警告は0。対象のAppコードと検証結果は両OSとも採番以外で一致した。試験ログは `.validation/group-invitation-passive-app-{red,final}-20261119` と `.validation/group-invitation-passive-mac-final-20261119`。ビルド後採番1226。

通知の仕様、デザインのMarkdownとHTML、使い方、AppleとCloudflareを設定した後の受入順を同じ操作に揃えた。HTMLはChromeで描画して確認した。グループ招待の実APNsは配布署名と端末の設定を揃えて受け入れる。呼び出しの待機中の音を通知拡張で付ける案も、同じAPNs Sandboxで検証する。

## マイク許可を待つ間に期限が切れた呼び出し

2026-11-22。ローカルmainの統合コミット `633e3f37` で、macOSの関連103件とiPhone Simulatorの初回マイク許可・拒否を再確認した。続いて、呼び出しを開いた後にマイク許可を止め、試験の時計をサーバーの期限より先へ進めた。修正前は、期限を過ぎても許可すると接続を始めた。

通知を照合したときの期限を同じ通話開始操作へ渡した。期限内の許可で接続し、期限切れならユーザー一覧を開く。許可待ちの操作を取り消した後は接続しない。画面も変わらない。4条件を含む関連61件が、macOSとiPhone 17 Pro Simulatorの両方で通った。証跡はそれぞれ `.validation/shared-main-integration/`、`.validation/notification-permission-expiry/`。実際にAPNsを使う端末間の受入は[未確認事項](../未確認事項.md#通常通知の受入)で追う。

## マイク許可を待つ間に受信許可を取り消す

2026-11-22。通知を開き、マイクの許可を保留した。修正前は、その間に送り主からの受信許可を取り消しても接続が始まった。受信を許可し直した場合にも、すでに開いた通知から接続した。

接続直前に、通知を開いたときと同じ受信許可がこの端末で有効か確かめる。受信許可の取り消し、再発行、端末の通知無効化の3条件で、古い通知から接続せず画面も保つことを確認した。架空の送り主を使った関連95件が、macOSとiPhone 17 Pro Simulatorの両方で通った。証跡は `.validation/notification-permission-revocation/`。[通知仕様](../../spec/App/通知仕様.md#送信結果tap保持する情報)

## 共有版で通常通知を開いてからマイク許可を待つ

2026-11-25。共有main `43312a91` で通知を開き、マイクの許可を保留した。修正前は、許可する前に接続と通話画面の表示を始めていた。修正後は、呼び出しを開いてからマイクの許可を待つ。接続直前に、同じ開始操作が継続中であること、サーバーが返した期限内であること、端末の通知と送り主からの受信許可が引き続き有効であることを確かめる。

期限内の許可で接続が始まり、期限切れでは未接続のままユーザー一覧へ進んだ。マイクの使用を拒否した場合は、設定で許可するよう案内する状態になった。操作を取り消した場合は、接続せず画面も切り替わらなかった。受信許可の取り消しと再発行、端末通知の無効化と再有効化でも同じ結果だった。

通知応答と既存の受信許可・音声開始を含む関連56件が、macOSとiPhone Simulatorでそれぞれ通った。修正前は `.validation/20261125-161700-219719/`、修正後は `.validation/20261125-162026-876562/` と `.validation/20261125-162123-333574/`。

[通知仕様](../../spec/App/通知仕様.md#送信結果tap保持する情報)、[設計](../../design/通知の設計.md#応答の操作)、[HTML見本](../../design/通知見本.html)の条件を照合した。実機の通知からOSの許可を開く操作と通話は[通常通知の受入](../未確認事項.md#通常通知の受入)に残る。ユーザー一覧や招待から通話を始める場合のマイク許可は[共通の製品要求](../../requirements/製品要求.md#利用者に提供すること)に従って別途確認する。

同日、ユーザー一覧と招待からの操作も共通の許可判定につないだ。許可後に開始した通話の照合と、通知の期限による一覧への遷移も確認した。[共有版のマイク許可](複数端末の経路断と自動復旧.md#共有版で新規通話の開始をマイクの許可まで待つ)・[開始結果の照合](../../development/history/バックログの優先順位と進捗の記録.md#通常換算2625コミットで通話開始の結果を照合する)

## 呼び出し通知を開いたときに接続できない理由を示す

2026-11-26。端末宛ての合成通知で、インターネット設定がオフの場合と回線が使えない場合を試した。修正前は理由の案内が出なかった。修正後は送り主を照会せず、ユーザー一覧に進み、設定をオンにする案内と回線への接続を促す案内をそれぞれ選んだ。

照会中に設定をオフにした場合、すぐにオンに戻した場合、回線を失った場合に、照会を取り消して通話を始めないことを確認した。案内後に設定をオンにしたか回線が戻った場合は、古い理由を消し、通話を始めなかった。接続待ちや音声停止を含め、先に通話があればその通話を開いた。期限切れの通知を通信可能な状態で開いたときは案内が出なかった。

macOSとiPhone Simulatorで通知と許可の試験が各69件通った。iPhone SimulatorではXCUITestも1件通った。Standardの設定画面で合成通知の接続操作を試した。インターネットがオフの案内が日本語で表示された。「閉じる」で一覧へ戻り、通話は始まらなかった。応答の入力だけを一時的に用意し、試験後にソースから取り除いた。Simulatorの停止も確認した。

日本語の表示文、Markdown、HTMLの内容を照合した。実際のAPNs通知から開いた画面は[通常通知の受入](../未確認事項.md#通常通知の受入)で確認する。次回用Buildは2880。

証跡は修正前が `.validation/20261126-132918-139542/`。修正後のmacOSは `.validation/20261126-134053-873643/`、iPhone Simulatorは `.validation/20261126-133907-645981/`。試験用入力の差分は `.validation/notification-connection-notice-ui.904lixwl/fixture.diff` に保存した。[通知仕様](../../spec/App/通知仕様.md#責務と入口)・[表示見本](../../design/通知見本.html#internet-unavailable)

## 通話設定がオフでも通知を拒否した端末の通知先を解除する

2026-11-26。通知先の登録済み端末でインターネット通話をオフにし、OSの通知許可を拒否へ変えた。回線を使える場合と回線断から復旧した場合を試した。修正前はどちらも端末側で受信を止めた。Workerへの解除は保留されたままだった。

修正後は、OSが回線を利用できると報告し、現在もOSで通知を許可していなければ、既存の端末資格でその端末の通知先を解除する。回線断中は保留し、通話設定がオフのままでも復旧後に解除した。回線を使える状態で通話設定を切り替えても、待機していた解除は登録の中止後に一度だけ送った。OSの許可が戻った場合は、通話設定がオフの間は解除と登録を保留した。回線復旧の直後に通話設定をオンにした場合も、OSへの登録要求は1回だった。

[通知の仕様](../../spec/App/通知仕様.md#端末の登録取消)、[通知の設計](../../design/通知の設計.md#通知の許可を求める時点)、[HTML見本](../../design/通知見本.html#permission)に同じ条件を記した。

共有スキームでMacの70件とiPhone Simulatorの69件が合格した。MacではローカルWorkerを使い、解除済みの通知先を遅れて届いた登録要求が復活させないことも確認した。証跡は修正前の `.validation/20261126-162448-469267/`、修正後のMacが `.validation/20261126-162836-673321/`、iPhone Simulatorが `.validation/20261126-162915-915177/`。次回用Buildは2924。実際のOS設定とAPNsは[通常通知の受け入れ](../未確認事項.md#通常通知の受入)で確かめる。
