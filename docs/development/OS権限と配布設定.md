# OS権限と配布設定

## 設定の責任と状態を分ける

本書は[開発環境](開発環境.md)のOS・署名・配布設定を補う。宣言があること、profileに許可されていること、利用者のOS許可、server有効化、商品販売は別の状態である。署名なしbuildとfixture試験だけで外部サービスの利用可能とは判断しない。

| 領域 | リポジトリの設定 | 外部で成立させること |
|---|---|---|
| Appleログイン | 全通話で認証必須。AppのiOS/macOS entitlementにSign in with Apple | 対象App IDのcapabilityと、そのcapabilityを含む両OSのprofile。実Apple認証・取消・復帰 |
| 近距離通信 | `NSBonjourServices`は近距離のQUIC制御用の`_ride-control._udp`と、音声用の`_ride-audio._udp`。ローカルネットワーク説明を日英で同梱 | 各端末でローカルネットワークを許可。固定BonjourとUDP unicastなのでmulticastの制限付きentitlementは追加しない |
| 本体のマイク・継続音声 | 日英のマイク説明、macOS audio-input、Appのaudio background mode。端末本体の通話・Audio Check前に明示要求し、許可後は同じ操作を続行 | 各端末のマイク許可。実Bluetooth・中断・ロック中通話の受入。本体はカメラ、連絡先、位置情報、Watchマイクを要求しない |
| Mac sandbox | Appはsandboxとnetwork client/serverを有効。UDPの送受信に両方向が必要 | 通常sandboxの実起動と実通信。自動unitでsandboxを無効にした結果とは区別 |
| Widgetの選択用共有 | AppとWidgetに同じApp Group。Widgetは資格を持たず、Appが投影を書きextensionは読む | 両App IDへのgroup割当と両profileのgroup許可。署名済みの実App/extension間で共有できること |
| 通知 | AppだけPush entitlement。通常のalert/soundと利用者tapを使用。背景remote-notificationを要求しない | Push capability、APNs環境、server topic、provider鍵、利用者の通知許可を一致させる |
| 招待・削除の背景更新 | iOS本体のInfoで `fetch` と同期用のタスクIDを1つ宣言する。App起動時に同じIDを登録する | 背景更新が利用できる端末で、iOSが実行を許可した時刻と、通常グループ・個人招待の返信および個人削除の進行を照合する。[通信仕様](../spec/App/通信仕様.md#iosが背景更新を許可したときの招待と個人削除) |
| Watchの開発・検証 | iPhone依存の単一Watch App、対応bundle ID、専用AppIcon。Watch音声用のマイクと近距離通信の説明をWatch側に同梱する。WatchにはPushを付与しない。通常のiOS ReleaseはWatchを同梱しない | 開発・検証用のWatch App IDとprofile、iPhoneとのペアリングと操作の手渡し。[Watchの現行動作と実機の受入条件](../spec/App/Watch操作.md)を確認する |
| CarPlay Widget | 27.0以降のWidget背景IntentとApp本体の共通操作を使用。CallKit・専用CarPlay entitlement・VoIP Pushは追加しない | タッチ対応車での実操作、iPhoneロック・cold launch・新規マイク開始・Widget更新。非タッチ車はボタン非対応 |
| 状態表示 | iPhone/iPadの任意Live Activity、Mac Widgetを実装。対応端末のDynamic Islandとロック画面を使用 | OSによる表示・消去・ロック解除・手渡しを受入。Mac自身からのLive Activityは提供しない。iPhone由来のMac表示とMac native上部表示を混同しない |
| 購入 | 公開`StoreProductCatalog.production`は未設定。商品が未設定の間は引き続き商用条件を適用しない | 商品・価格・契約・Family Sharing・審査・販売許可。ローカルStoreKit fixtureは販売設定ではない |

## IdentifierとApple Developerでの設定

Apple DeveloperのCertificates, Identifiers & Profilesで、既存の登録を確認してから不足を設定する。以下は必要な登録先を示し、portalの現在の登録状況を確認済みとするものではない。

| 登録先 | Identifier | 設定 |
|---|---|---|
| Identifiers → App IDs | `com.yowamushi-inc.RideIntercom.RideIntercom` | Sign in with Apple、Push Notifications、App Groups。iOS/macOSで必要なprofileを別々に確認 |
| Identifiers → App IDs | `com.yowamushi-inc.RideIntercom.RideIntercom.Widgets` | App Groupsだけ。Appleログイン・Push・マイクをextensionへ追加しない |
| Identifiers → App IDs | `com.yowamushi-inc.RideIntercom.RideIntercom.watchkitapp` | Watch App用の明示ID。親Appのbundle IDを`WKCompanionAppBundleIdentifier`へ指定済み |
| Identifiers → App Groups | `group.com.yowamushi-inc.RideIntercom.CallWidgets` | AppとWidgetの両IDへ割り当てる。macOSでも`group.`形式は使用できるが、そのgroupを含むprofileが必要 |
| Profiles | 上記のApp/Widget/Watch IDと実際の配布先 | capability変更後に再生成／ダウンロードし、XcodeのSigning & Capabilitiesで正しいteamとprofileを選択。自動管理の場合も取得結果を検証 |
| Keys → Apple Push Notifications service | 通知provider用のkey | 対象topicと環境への送信権限を確認する。p8はWorker secret `APNS_PRIVATE_KEY`へ、Key IDは通常Variable `APNS_KEY_ID`へ設定する。Team IDは共通の`APPLE_TEAM_ID`を使い、p8をApp・Git・ログへ置かない |
| Keys → Sign in with Apple | AppのApple認可取消用のkey | 初回に、対象App IDの`.p8`をWorkerのSecret `APPLE_SIGN_IN_PRIVATE_KEY`へ登録する。同時にKey IDを通常の変数 `APPLE_SIGN_IN_KEY_ID`へ登録する。Team IDは共通の`APPLE_TEAM_ID`を使う。Workerが短期client-secret JWTを生成・更新し、APNs鍵と取り違えない |

2026-10-31の読取監査では、既存profileファイル6件のうち現App IDに一致する4件（iOS用3、macOS用1）は期限内だった。この4件はいずれもSign in with Appleと今回のApp Groupを含まなかった。Widget/Watchの上記IDに一致するprofileはローカル一覧に見つからなかった。これは**インストール済みprofileの不足**であり、Developer portalに登録がないと断定しない。portalは未照会である。Apple Development／Apple Distribution／Developer ID Applicationのidentityは読み取りで確認した。鍵のunlock、Apple ID再認証、profile取得・署名は実行していない。

## APNs環境を一つの設定から渡す

グループ招待の送信中や、個人招待の明示登録後の返信中にiOSの背景へ移る場合は、UIKitの有限の背景実行時間を使用する。このAPIへの追加のCapability・通知種別・Cloudflare設定は不要。グループ招待のアラートは、以下の通常APNsの設定で配信する。[Appleの背景実行時間](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)。

| 項目 | 値・契約 |
|---|---|
| Build Setting | `RIDEINTERCOM_APNS_ENVIRONMENT`。Debugは`development`、Releaseは`production` |
| App Info | `RideIntercomAPNsEnvironment`へ同じ変数を展開 |
| iOS entitlement | `RideIntercom/RideIntercom.entitlements`の`aps-environment`へ同じ変数を展開 |
| macOS entitlement | `RideIntercom/RideIntercom-macOS.entitlements`の`com.apple.developer.aps-environment`へ同じ変数を展開。SDK条件でファイルを切り替える |
| 登録先 | AppはInfoの`development`をserverの`sandbox`、`production`を`production`へ対応付ける |
| 通常Archiveの作成 | schemeのReleaseを使い、Infoの値は `production`。Archive時の署名が開発用profileであれば、実entitlementは `development` になり得る。標準保存先への直接作成、実署名と同梱物の検証結果を記録する |
| TestFlightと公開配布 | 配布署名を付けた段階で、実entitlementとInfoがともに `production` であることを確認する。IPAならPayload内のAppを調べ、内部テストへ直接送る場合はXcodeの配布署名と検証を使う。値が食い違う成果物は配布を保留する |
| Releaseの開発署名試用 | development profileで試用する場合は、単一Build Settingを`development`へ明示上書きし、App Infoと署名を一緒に合わせる。公開Archiveと混同しない |

APNsの実行に必要なserver設定は`NOTIFICATIONS_ENABLED`、`APNS_TOPIC`、`APNS_ENVIRONMENT`、`APNS_KEY_ID`、共通の`APPLE_TEAM_ID`。secretは`APNS_PRIVATE_KEY`と既存の`DEVICE_IDENTITY_SIGNING_KEY`である。topicはWidget/WatchではなくAppの`com.yowamushi-inc.RideIntercom.RideIntercom`とする。[通知server仕様](../spec/server/通知.md)に従い、topicは両環境へ上記の確定値を設定した。TestFlight Internal Onlyを含むTestFlightは本番Workerとproduction APNsを使う。開発署名で試す固定Previewはsandbox APNsを使う。環境別のWorker設定、通知用binding/migration、App側登録・取消が揃った後、明示された実サービス受入で確認する。通知の有効化で音声サービス・購入商品を同時に有効化しない。

## 商品と配布の残設定

[利用権仕様](../spec/App/利用権仕様.md)に従い、App Store Connectで対象のアプリを開く。In-App Purchasesで個人向けの1週間の商品（自動更新なし）を設定する。Subscriptionsで月額の自動更新商品と購読グループを設定する。月額のFamily Sharingは商品側で有効にする方針で、週券は対象外。商品ID・価格・試用日数・地域・契約／税務／銀行情報・審査用説明の設定と受入を完了し、販売開始の明示許可があるまで公開catalogへIDを入れない。今回の商品設定・販売開始は未実施であり、未設定を購入済みに見せない。

App Privacy、プライバシーポリシーURL、年齢区分、審査連絡先、配布地域、TestFlightの配布先もApp Store Connect側の設定である。端末内の名前・group情報、serverが保持するアカウント／端末識別子・通知先・通知grant、短時間の通話中継、診断の実運用を確認して回答する。既存PrivacyInfo.xcprivacyのRequired Reason API宣言や、ローカル設定試験を「収集なし」の証拠にしない。

### App Storeの配信地域

RideComは中国本土のApp Storeで新規配信しない。フランスは、追加の手続きが必要になる可能性を考慮して配信対象から外す。フランスへの配信を検討する場合は、[配布時の暗号化申告](開発環境.md#配布時の暗号化申告)も見直す。

2026年11月23日、依頼者からApp Store Connectで中国本土とフランスの両方を配信対象から外したと報告を受けた。

配信地域を変更するときは、App Store ConnectでRideComを開き、「価格および配信状況」で対象地域を選ぶ。保存後に配信地域の一覧を開き直し、変更した地域と既存のほかの地域の選択を確認する。[Appleの配信地域の設定手順](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store/)

## 生成物での確認

`python3 scripts/check_platform_configuration.py`は設定を読み取って検査する。対象はOS別entitlement、App Group、日本語・英語の権限説明、Watchのアイコン、埋め込んだproduct、近距離設定。通常のRideIntercomスキームのArchiveがReleaseを選び、ReleaseでAPNsがproduction、Debugでdevelopmentになることも検査する。CLIの開発設定検査（`scripts/check_development_setup.py`）からも実行する。Xcodeの通常build phaseには組み込まない。portalやOS許可は変更しない。

Watchの埋込製品と依存ターゲットの除外は、Xcodeプロジェクト内で空白区切りの文字列または配列として保存される。構造検査は両形式から値を読み取り、通常配布用の `Release` だけで除外する条件を確認する。

Xcodeで通常のRelease Archiveを生成し、Organizerから実際の配布先へexportした**最終artifact**を確認する。iOSは展開したPayload内、macOSは.app内のInfo.plistを使用する。

TestFlightの内部・外部テストには本番用のRelease Archiveを使う。Appは本番Workerに接続し、Apple Distributionで署名したIPAのAPNs環境はproductionとする。固定Previewの試用には開発署名のDebugを使う。既存Archiveを選ぶ場合は、接続先を本番に固定した変更（`8a0dba79`）を含むコミットから作成したことを検証記録と照合する。Build 1962は接続先の固定前に作ったため、TestFlightの候補から外す。[環境別の試用手順](Cloudflare試用手順.md#利用者が行うapplecloudflareの設定と受入順)・[Build 1962の確認記録](history/バックログの優先順位と進捗の記録.md#build-1962で更新したwebrtcと配布署名を照合する)

TestFlightの内部・外部テストと公開配布では、書き出した成果物に含まれるWebRTCが本番用ビルドであることを確認する。[WebRTCの配布条件と照合手順](BuildWebRTC/WebRTCビルドスクリプト.md#testflightと公開版には本番用webrtcを使う)

```sh
codesign --verify --deep --strict /path/to/RideIntercom.app
codesign -d --entitlements - /path/to/RideIntercom.app
codesign -d --entitlements - /path/to/RideIntercom.app/PlugIns/RideIntercomWidgets.appex
plutil -extract RideIntercomAPNsEnvironment raw /path/to/RideIntercom.app/Info.plist
```

macOSではWidgetが`Contents/PlugIns`、Infoが`Contents/Info.plist`にある。AppとWidgetのentitlementに同じApp Groupがあることを確かめる。Appleログイン・APNs・音声権限がAppだけにあることを確認する。APNsのdevelopment/productionがApp Infoと対応することも確かめる。raw profile、証明書、device token、鍵を検証記録へ貼らない。

Watchの配布は保留中。通常のiOS ReleaseはWatchの依存と埋め込みを除外し、Watchの共有schemeはRun・Testを残す。iOS ReleaseのArchiveとexport後のPayloadで、AppとWidgetの`CFBundleVersion`を照合する。どちらの生成物でも番号が一致し、`Watch/RideIntercomWatch.app`を含まないことを確かめる。開発・検証構成のiOS Appでは引き続きWatchを組み込み、組み込んだ場合はその`CFBundleVersion`とAppIconを確認する。[Watchの公開条件](../requirements/製品要求.md#利用者に提供すること)

RideCom はカメラを使わず、カメラの利用目的を追加しない。送信前に[WebRTCの配布条件](BuildWebRTC/WebRTCビルドスクリプト.md#上流の無改変とカメラの不使用)に従って撮影機能の除外を確認する。通常の配布時に App Store Connect で対象ビルドの処理結果を確認する。カメラに関する通知が届いた場合に、その内容と対象の成果物を照合する。[以前の配布結果](../validation/README.md#カメラ不要の配布バイナリ修復2026-10-22)

### iOSのカメラ参照の送信前検査

配布を準備する担当者は、送信に使う署名付きのiOS Archiveを指定し、リポジトリのルートから検査する。書き出したIPAを使う場合は、そのIPAを直接検査する。取り出したAppを確認するときは同じコマンドに指定できる。

```sh
python3 -m scripts.check_release_camera /path/to/RideIntercom.xcarchive
python3 -m scripts.check_release_camera /path/to/RideIntercom.ipa
python3 -m scripts.check_release_camera /path/to/Payload/RideIntercom.app
```

検査はAppの署名を確かめ、Appと同梱物にあるMach-Oの全アーキテクチャから所定のAVCaptureクラスへの参照を探す。各 `Info.plist` の `NSCameraUsageDescription` も調べる。IPAのPayloadは一時領域で検査し、終了時に取り除く。音声のためにAVFoundationをリンクしているだけなら、このクラス検査では検出されない。

終了コードが1か2なら対象の送信を止める。App Store Connectの処理結果は別に確認する。

| 終了コード | 検査結果 |
|---|---|
| `0` | 検査を通過した |
| `1` | カメラ参照や利用目的を検出した |
| `2` | 署名、構成、読み取りなどの検査を完了できなかった |

### 配布用プロファイルを更新した後の確認

配布用プロファイルを更新したときは、TestFlightからインストールした端末で次の順に確認し、結果を1項目ずつ記録する。

1. 配布物の固定接続先を本番Workerと照合し、Appleログインで端末を登録
2. OSのマイク、ローカルネットワーク、通知の許可
3. App Groupの候補表示
4. 削除・サインアウト後に古いWidget操作を拒否すること
5. 実APNsの受信と取消
6. ロック中の継続

Watchの操作は、Watchを組み込んだ開発・検証構成で確認する。

Mac nativeの任意MenuBarExtraは後続のApp工程で[実装](../spec/App/システム表示と通話操作.md#macメニューバー)した。実メニュー・VoiceOverの受入は別に記録する。

根拠：Appleの[ローカルネットワーク](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)、[Mac App Group](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)、[APNs登録](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[APNs環境](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment)、[アイコンasset](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。

## MacのSDKプライバシーリソース

管理WebRTC artifactの二重配置は[独立artifact工程](../validation/history/WebRTCマニフェスト配置の修正.md)で修正した。App buildでも標準の`WebRTC.framework/Resources/PrivacyInfo.xcprivacy`への同梱と元のmanifest内容を確認済み。更新時は[WebRTC組み立て・検証手順](BuildWebRTC/WebRTCビルドスクリプト.md#sdkプライバシーマニフェストの配置)を適用し、配布前には署名済み最終artifactとArchiveのprivacy reportを別に受け入れる。

設定・配置の実施順とCloudflareへ渡す全変数は[Cloudflareの設定と受入順](Cloudflare試用手順.md#利用者が行うapplecloudflareの設定と受入順)を参照する。APNs鍵の形式と環境／topicの権限はAppleの[provider tokenの仕様](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)に従う。

## 現在の署名・配布アクセスの確認

2026-11-18、iOSの1.0.0 (1041)を標準Release Archiveで作成した。App・Widget・Watchの番号一致、strictな署名検証、Appのcompiler警告0を確認。開発署名の実entitlementにはSign in with Apple、App Group、developmentのAPNsが含まれ、get-task-allowはtrueだった。これは開発署名のArchiveであり、productionの最終配布署名はExportで確認する。InfoはReleaseのproductionのまま維持する。

Internal Only指定の送信は、Xcodeが「App Store Connect access for UAY8FH5FF8 is required」で拒否し、未送信。通常のAPI key設定も見つからなかった。配布する際はXcode → Settings → Accountsで、このチームと対象AppへApp Store Connectアクセスを持つApple Accountの認証・権限を確認する。開発署名を作れることと、App Store Connectへ送信できることを分けて扱う。認証復旧後に同じArchiveを再使用できる。詳細と保存先は[配布の検証記録](../validation/history/配布ビルド採番とOrganizer認証調査.md)を参照する。

2026-11-21、Build 1903の標準Archiveを共有の `scripts/ExportOptions.plist` でこのMacに書き出した。IPAのApple Distribution署名、AppのInfoと署名にあるAPNs環境がproductionで一致すること、AppとWidgetのビルド番号を確認した。TestFlightの送信権限と処理状況、テスターへの配布とインストールは引き続き確認する。[確認記録](history/バックログの優先順位と進捗の記録.md#全体監査の候補検査とiphone試用の配布用書き出し)

2026-11-22、本番接続先を固定したソースからiOS Build 1988を作成し、Xcodeの標準保存先に登録した。書き出したIPAでApple Distribution署名、本番Workerの接続先、production APNsを照合した。Organizerの一覧表示は未確認。App Store Connectへの送信と処理、テスターが配布後にインストールできるかの確認が残る。[Build 1988の確認記録](../validation/history/配布ビルド採番とOrganizer認証調査.md#ios-build-1988の本番向けarchiveとipa2026-11-22)

2026-11-22、通算2,070コミットの区切りでiOS Build 2018を作成し、Xcodeの標準保存先に登録した。IPAでApple Distribution署名、本番Workerの接続先とproduction APNsを照合した。Organizerの一覧表示とTestFlightでの配布は確認待ち。[Build 2018の確認記録](../validation/history/配布ビルド採番とOrganizer認証調査.md#archive-2070-build-2018)
