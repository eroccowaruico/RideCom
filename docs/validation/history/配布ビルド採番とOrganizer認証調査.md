# 配布ビルド採番とOrganizer認証調査

確認日は2026-10-29。利用者の指示は、公開バージョンを勝手に変更せず、App Store Connect／TestFlight用のビルドだけを採番し、内部のRun・Buildでは増やさないこと。手順は[開発環境](../../development/開発環境.md#app-storetestflight用の採番とarchive)、公開バージョンの決め方は[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)に従う。

## Organizerの認証エラー

Xcode 27.1（27A9275）の配布ログとmacOSのクラッシュ記録を照合した。

| 観測 | 判断・境界 |
|---|---|
| 19:08:54 JSTの配布失敗 | `IDEDistribution.critical.log`には`NSCocoaErrorDomain Code=4097`が記録された。同じログに`connection to service named com.apple.dt.Xcode.ITunesSoftwareService`と`account (null)`があった。同時刻のApple製XPCサービスが`EXC_BAD_ACCESS / SIGBUS`で終了 |
| クラッシュスタック | `CDTransporterDefaults`、`CDAuthContext`、`ContentDelivery`の環境設定参照が再帰。アプリ実行コードのスタックではない |
| 19:13の再試行 | 認証後にアップロード検証へ進み、使用済みビルド4以下として拒否。認証表示だけからログイン期限切れとは判断できない |
| 修正範囲 | 確認した認証失敗はXcode側サービスの異常終了に伴う接続切断。アプリ設定でこのクラッシュが直る根拠はなく、資格情報やXcode設定を削除していない。別問題のビルド番号管理を修正 |

診断報告の場所は次のとおり。

```text
~/Library/Logs/DiagnosticReports/com.apple.dt.Xcode.ITunesSoftwareService-2026-10-29-190855.ips
```

一時領域にも`RideIntercom_2026-10-29_19-08-52.533.xcdistributionlogs`を保存した。認証障害の再発防止は未確認。

## 採番・Archive・書き出し

`b5591e43`の隔離コピーに今回の採番設定とスクリプトを反映し、同時進行中の音声変更を含めずに検証した。元の作業ツリーの配布基準は4に維持。検証コピーはXcodeで開いていないため、実行時だけ`pgrep`を置き換えて「Xcode起動中」のガードを通過させた。採番・ビルド・署名・書き出しには実際のAppleツールを使用した。

| 確認 | 結果 |
|---|---|
| スクリプト回帰 | `python3 -m unittest discover -s scripts/tests -p test_distribution_archive.py -v`の5件成功。採番がArchiveより先に実行されること、採番失敗時の停止、Archive失敗時のlock解除、重複実行・既存Archive・Xcode起動時の拒否、呼出元からの相対パスを検証 |
| 配布Archive 1回目 | `scripts/archive_app_store.sh ios /tmp/RideIntercom-FinalNumber5.xcarchive`で`ARCHIVE SUCCEEDED`。署名済みAppの`CFBundleVersion=5`、`CFBundleShortVersionString=1.0`。Archive側のApplicationPropertiesも一致 |
| 間に挟んだ内部Build | 同じコピーでDebug・generic iOS・`CODE_SIGNING_ALLOWED=NO`の`xcodebuild build`が成功。Appは`1.0 (5)`を維持。projectファイルのSHA-256はBuild前後で一致 |
| 配布Archive 2回目 | 同じ入口で`/tmp/RideIntercom-FinalNumber6.xcarchive`を作成し成功。署名済みAppとArchive情報がともに`1.0 (6)` |
| IPA書き出し | build 5のArchiveに`scripts/ExportOptions.plist`を指定して`xcodebuild -exportArchive`が成功。`/tmp/RideIntercom-FinalNumber5-Export/RideIntercom.ipa`内のAppも`1.0 (5)`を維持 |
| 構造確認 | 開発設定、plist、shell構文、差分検査成功。文書検査は対象変更だけの隔離コピーで成功。元の作業ツリーでは別作業の未追跡バックログ文書「リアルタイム会話の遅延と連続性改善」への入口リンク不足で失敗し、対象外として維持 |
| 残る境界 | AppIntents未使用によるmetadata抽出省略warningあり。macOSの実Archive、OrganizerのGUI設定保持、アップロード、Apple側の受理・TestFlight配信は未検証 |

ログは`/tmp/rideintercom-final-number5.log`、`/tmp/rideintercom-number5-normal.log`、`/tmp/rideintercom-final-number6.log`、`/tmp/rideintercom-final-number5-export.log`。一時領域のため永続保存ではない。検証前の対象project設定のSHA-256は`2ccf2562e192b3a5dd6f704094bcb3ffcaccb35b1a905167573ed446e066fdf8`、採番スクリプトは`fbc0f648ee1fb2d93e11cad187e5ac1c0fd3b5b7ac65daf6742207b6e9323186`。

## 採用しなかった方式

schemeのArchive Pre-actionで`agvtool`を実行すると、project上は新番号でも、そのArchiveには読み込み済みの旧番号が入った。Archiveを開始する前に採番する専用入口を採用した。また、ターゲットごとに番号が異なる状態では`agvtool`が低い番号を基準にしたため、project共通設定を全ターゲットに継承させた。通常Buildでの採番や生成Info.plistの独自前処理は最終変更に含めていない。


## Xcode標準Archiveへの統合（2026-10-30）

利用者は専用コマンドを原則使わず、XcodeのArchiveで自動採番するよう指示した。通常Run・Buildと公開バージョンは維持し、XcodeのBuild欄・project設定・配布物を揃える。上記の専用コマンド方式を置き換えた。要求は[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)へ追記し、[要求の入口](../../requirements/README.md)から参照する。

| 修正 | 理由・境界 |
|---|---|
| 共通xcconfig | 既存の手元のApp設定7を`Configuration/BuildNumber.xcconfig`へ移し、projectのDebug・Releaseから全targetへ継承。ナビゲータ直下で見える。手元の公開バージョン1.0.0は変更せず、今回のコミットへ既存の公開バージョン差分を混ぜない |
| Xcode内の採番 | AppのBuild Phaseから`prepare_archive_info.py`を呼び、Archiveのinstall actionでだけ採番。通常のbuild actionは読み取るだけ。CLIの専用入口と旧テストは削除 |
| 読み込み済み設定への対策 | xcconfig更新だけでは当該Archiveのbuild settingsは古いため、ビルド専用の入力Info.plistへ予約番号を入れる。`GENERATE_INFOPLIST_FILE=NO`で旧番号の再上書きを避け、署名前の通常のplist処理へ渡す |
| 従来のバージョン情報を生成する設定を削除 | agvtoolを使わなくなったため`VERSIONING_SYSTEM=apple-generic`を除去。読み込み済みの旧番号を持つ`*_vers.c`を生成しない |
| 並行実行と復旧 | file lock、atomic replace、各ビルド固有の生成先により番号と成果物を固定。破損・欠落は自動初期化せず停止。採番後の失敗は欠番として維持 |
| 周辺処理の保護 | 実行中のXcode、アプリ、他のビルドを停止せず、既存DerivedDataも削除しなかった。検証は専用の一時コピー・DerivedDataと低優先度・2ジョブで実行 |

検証コピーのsourceは`1913cc99`を基準とし、その後に手元のproject設定（公開バージョン1.0.0、ビルド7）と今回の変更を反映した。同時進行のRTC修正は含めない。元の作業ツリーでは検証のために採番していない。

| 確認 | 結果 |
|---|---|
| 自動テスト | `python3 -m unittest discover -s scripts/tests -p test_archive_numbering.py -v`の8件成功。旧設定値を保持した環境での連続採番、8並列の重複防止、内部Buildの不変、欠落・破損・書込失敗、プラットフォーム別metadataを検証 |
| 標準Archive | 専用コマンドを使わず、既存のRideIntercom schemeの`xcodebuild archive`でiOS 8→9、macOS 10の生成に成功。最終設定でもiOS 11、macOS 12の署名済みArchiveに成功し、`codesign --verify --deep --strict`成功 |
| 内部Build | 間に実行したmacOS Release Buildは8を維持。iOS Debug Buildは10を維持し、実行前後のproject・ソースInfo.plist・xcconfigのSHA-256が一致 |
| 設定・実体の一致 | 最終Archive内AppとOrganizerのApplicationPropertiesがそれぞれ1.0.0 (11)／1.0.0 (12)で一致。Xcodeの`-showBuildSettings`が共通xcconfigの最新番号を解決することも確認 |
| 既存metadata | 変更前のiOS/macOS生成plistと全キーを比較。差分は採番したCFBundleVersionと、検証コピーへ引き継いだ既存の公開バージョン変更のみ。権限説明、暗号化免除、アイコン、URL scheme、Bonjour、背景音声、scene、launch、画面方向などを保持 |
| IPA | 最終iOS Archiveを既存ExportOptionsで書き出し成功。IPA内Appも1.0.0 (11)を維持し、書き出しで再採番しない |
| 構造確認 | 開発設定・文書・plist・差分検査成功。並行作業のproject参照・公開バージョン差分・RTCソース・検証文書は今回のコミットから除外 |
| 残る境界 | 既存Xcode画面を操作してのArchiveクリックやBuild欄の再描画は実施せず、同じscheme/build phaseを標準xcodebuildで検証。AppIntents未使用のmetadata省略warningは従前どおり。アップロード、Apple受理、TestFlight配信は未実施 |

主な証跡は`/tmp/ride-archive-integration-final11.log`、`/tmp/ride-archive-integration-final12-mac.log`、`/tmp/ride-archive-integration-mac-build.log`、`/tmp/ride-archive-integration-debug.log`、`/tmp/ride-archive-integration-final11-export.log`、`/tmp/ride-archive-integration-final-settings.json`。一時領域のため永続保存ではない。採番スクリプトのSHA-256は`499b62d64098bf063f6890e9baf6a79d2c0ee2dad4855135379e296fc9987d11`。


## project設定への集約（2026-10-30）

利用者から、Xcodeで管理できればよく、Configuration内のロックなど余分なファイルは不要と指摘があった。これらはOrganizerの生成物ではなく、前節の採番スクリプトが作った補助ファイルである。最新の採番値9を保持して、番号を管理する場所をXcode projectの`CURRENT_PROJECT_VERSION`へ戻した。さらに利用者から、構成別の番号を持たず、Debugが100回連続してもRelease／Archiveが続いても、すべて共通の連番を進めるよう指示があった。Archive限定の採番を撤回し、全ビルドを同じ規則に統一した。

| 変更・確認 | 結果 |
|---|---|
| 補助ファイルの除去 | `BuildNumber.xcconfig`と残存する`BuildNumber.lock`を削除し、空のConfigurationディレクトリも削除。参照と旧ignore設定も除去 |
| 同時採番 | 既存の.xcodeprojディレクトリ自体へOSのlockを掛けるため、新規の常設lockファイルは不要。書換え用の一時ファイルはatomic replace後に残さない。更新直前にprojectの別保存を検出した場合は上書きせず失敗させる |
| 最終的な採番規則 | `build`／`install` actionで共通の10進連番を毎回1増やす。Debug・Release・Archiveでリセットせず、日付や別カウンタを導入しない。公開バージョンと他のproject設定は保持。署名前の入力plistへ予約番号を渡す |
| 回帰 | `test_archive_numbering.py`の11件成功。Debug 100回→Release 3回→Archive 3回→Debugの107連続、7桁から8桁への増分、8並列での重複防止、別設定・lockファイルの不在、他設定の保持、失敗時の動作を確認 |
| 移行方式の先行確認 | `95f363aa`の隔離コピーで、採番専用設定を除いても標準iOS Archiveが9→10→11となり、AppとOrganizer情報・署名の整合を確認。この時点の通常Build据え置き規則は、その後の指示で全ビルド採番へ置き換えた |
| 最終規則の実ビルド | 同じ隔離コピーを境界試験用に9999997から開始し、標準Debug Build=9999998、Release Build=9999999、署名済みArchive=10000000を確認。公開バージョン1.0.0を維持し、project・App・Organizerの番号が各ビルドで一致。8桁のApp Store側受理を確認するアップロードは行っていない |
| 移行 | 実行中ビルドがないことと旧lockを確保できることを確認してから、元の作業ツリーの番号9を移行。既存プロセスは停止せず、別作業のproject参照・グループ管理変更は保持 |
| 確認範囲 | 文書・開発設定・plist・差分検査成功。既存Xcode画面の操作とアップロードは実施していない |

証跡は`/tmp/ride-project-number-10.log`、`/tmp/ride-project-number-build.log`、`/tmp/ride-project-number-before-build.sha256`、`/tmp/ride-project-number-11.log`、最終規則の`/tmp/ride-shared-number-debug.log`、`/tmp/ride-shared-number-release.log`、`/tmp/ride-shared-number-archive.log`。一時領域のため永続保存ではない。現行の操作・要求は[開発環境](../../development/開発環境.md)と[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)を参照する。

## iOS Internal Only送信の試行（2026-11-18）

この時点の利用者指示により、検証済みの招待修正からiOS ArchiveとInternal Only送信を試した。公開版は1.0.0を維持。最初の署名Archive 1039でAppのactor警告を見つけ、97件の回帰を通してabe15a30で境界を明示した。Swift警告をerrorにする第2試行は、swift-logのsuppress-warningsとCLIのwarnings-as-errorsの衝突で失敗した。依存や製品コードの不具合とは数えず、標準構成で再実行した。

最終は`.validation/testflight-internal-1000-final-20261118/RideCom.xcarchive`。App・Widget・Watchは1.0.0 (1041)、Build後処理の次回番号1042、source abe15a30。strictなcodesign検証が成功し、App compiler警告0、入力指紋一致（次回番号だけ許容）。開発署名のAPNsはdevelopment、Sign in with AppleとApp Groupがあり、Release Infoはproduction。配布Exportでproductionへ再署名する最終結果は未確認。

送信直前の設定を照合した。destination=upload、testFlightInternalTestingOnly=trueであった。manageAppVersionAndBuildNumber=falseとteamID=UAY8FH5FF8を照合した。ソース差分も次回番号以外がないことを確認した。標準のxcodebuild -exportArchiveは失敗した。原文は「Failed to Use Accounts / App Store Connect access for UAY8FH5FF8 is required」。未アップロードであり、内部配信・Apple側処理を成功としない。標準API keyの環境設定・保存先にも利用可能な設定はなかった。認証・権限の復旧は[OS権限と配布設定](../../development/OS権限と配布設定.md#現在の署名配布アクセスの確認)へ記録した。

`.validation/testflight-internal-1000-20261118`は未送信の最初のArchiveである。`testflight-internal-1000-actor-fixed-20261118`には検証オプションの衝突による失敗を記録した。最終フォルダのuploadには実送信試行のlogと使用optionsを保持する。現行の標準Archiveは従来どおりの入口・次回採番を使い、配布用の別カウンタや定期実行は導入していない。

## iOS Build 1988の本番向けArchiveとIPA（2026-11-22）

ローカルmainの `d55aa952` を隔離し、通常の `RideIntercom` スキームのiPhone用Releaseで署名付きArchiveを作った。このソースには本番Workerの接続先を固定した `8a0dba79` が含まれる。保存先は `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (1988).xcarchive`。登録後に標準保存先とビルド番号を読み取った。Organizerの一覧での表示は未確認。

同じArchiveを共有の `scripts/ExportOptions.plist` でローカルに書き出した。AppとWidgetは両方とも1.0.0 Build 1988。IPA内のApp・Widget・WebRTCのApple Distribution署名、App Infoと署名のproduction APNs、実行ファイル内の本番接続先を確認した。AppとWebRTCの実行ファイルをArchiveのdSYMと照合した。Watch、開発用の接続設定、試験用のリソースは含まれていなかった。

Archiveの後処理で次回用の番号が1989になった。標準保存先への登録、IPAの書き出しと検証の証跡は `.validation/testflight-production-build-1988/` に保存した。App Store Connectへの送信とテスターの実機受入は、[全体監査と実環境の残条件](../../development/history/バックログの優先順位と進捗の記録.md#2000コミットの全体監査で本番試用の条件を照合する)の確認後に進める。

### Build 1988の同梱WebRTCが診断出力を開始する条件

採用したWebRTCのZIPと、Archive・IPAに含まれるiOS arm64実行ファイルを照合した。データを持つ31セクションがすべて一致した。ZIPの採用記録にあるGN引数のハッシュは、iOS実機・Simulator・macOSの計5構成のビルド資料と一致した。公開ソースは採用記録にあるコミットを取得して確認した。[採用したWebRTCの公開ソース](https://webrtc.googlesource.com/src/+/a9a462f4232b49f63ed3b22b0ff57725c82625ec)

- WebRTCの通常ログは、5構成のReleaseで有効なコンパイル条件により、初期しきい値が `LS_NONE` になる。
- Perfettoのオブジェクトは5構成のリンク入力に含まれる。WebRTCのトレースをPerfettoに接続する `RTC_USE_PERFETTO` は設定されていない。SDKに残る内部トレースは初期状態で停止しており、ファイルの作成には明示的な開始処理が必要になる。
- 5構成とも `rtc_enable_protobuf=false` で、通話イベントをシリアライズする実装はリンクされていない。SDKには通話イベントログや音声処理のダンプを開始するためのAPIが残る。ファイルを開く処理を持つAPIもある。
- IPA内のAppとWidgetの実行ファイルを検査した。対象は内部トレース・通話イベントログ・音声処理のダンプを開始するAPIと、ファイル・コールバックログやログレベルを設定するAPI。対応する未定義シンボルとObjective-Cの呼び出し名はなかった。App・Widgetのソースにも該当する呼び出しはなかった。

証跡は `.validation/security-audit-2000/build1988-tracing/` に保存した。今回の確認は配布物と公開ソースの静的な照合まで。実機で起動・通話・切断した際の保存先とログ、同梱部品の脆弱性と保守状況は、引き続き全体監査で確認する。

### Build 1988でDataChannelが使うSCTP実装を照合する

2026-11-22。採用済みWebRTCのZIPとBuild 1988のIPAから取り出したiOS arm64の実行ファイルを比較し、データを持つ31セクションが一致した。採用記録と一致する5構成のリンク入力では、いずれもdcSCTPのオブジェクト27件とWebRTCの接続部品を確認した。DataChannelを生成するファクトリーでdcSCTPが有効だった。usrsctpはコンパイルとリンクの入力に含まれなかった。[採用したWebRTCの公開ソース](https://webrtc.googlesource.com/src/+/a9a462f4232b49f63ed3b22b0ff57725c82625ec)

10月に公開された再送・終了処理の修正5件は、採用版 `a9a462f423` の履歴に含まれていた。11月21日付の公開main `97e371905` と比較した。dcSCTP本体・WebRTCとの接続部・接続のインターフェイスに関わる後続の2件は、試験用変数と重複した初期値の整理だった。SCTPの確認範囲はこれらのディレクトリと対象ファイルの公開差分に限る。[再送の修正例](https://webrtc.googlesource.com/src/+/8bf6fb4d989e656e366613657b2a95b4b917bf15)・[試験用変数の整理](https://webrtc.googlesource.com/src/+/285eeb8a8362d79a0c09c60e9af4775fdb3a014e)・[初期値の整理](https://webrtc.googlesource.com/src/+/16f8e1215e84e76011e2598064056d92e985c0f9)

macOSで同じSDKを使い、DataChannelで符号化済み音声が双方向に届いた。近距離の音声を止めた4条件でも、WebRTCへ切り替えたあとに音声が届いた。検査対象のRTC packageと検証コードはArchive時点のソースと一致した。証跡は `.validation/security-audit-2000/dcsctp-release/`。本番SFUでの受話とロック中の接続は実機で確認する。[経路切替の試験](../../development/自動検証.md#近距離媒体だけの遮断と代替経路)

### Build 1988のmultiopusとRideComが使う音声経路を照合する

2026-11-22。採用版 `a9a462f423` と公開された `baa2ec6375` をGit履歴で照合した。WebRTCがRTP用のmultiopusの設定値を検査する修正は、採用版より後に入っていた。iOS実機・Simulator・macOSの5構成すべてで、multiopusのエンコーダーとデコーダーはリンク入力にあった。Build 1988に含まれる実行ファイルにもmultiopusの識別子があった。[WebRTCの公開修正](https://webrtc.googlesource.com/src/+/baa2ec637575f2d06bb29902c27857a68119d37a)

RideComは、受信したofferとanswerを同じ入口で検査する。音声や映像の媒体行があれば、SDKの `setRemoteDescription` を呼ぶ前に拒否する。採用版のSDKは、DTLS/SCTPのデータ用媒体とRTPの音声・映像用媒体を区別する。通常通話で受け取った符号化済み音声は、DataChannelからアプリのCodecへ渡り、OpusではOSの `AVAudioConverter` が復号する。この契約では、通話の入力をSDKのRTP用multiopusの設定へ渡さない。[媒体契約](../../spec/packages/RTC.md#cloudflareの媒体契約)・[採用したSDKのSDP処理](https://webrtc.googlesource.com/src/+/a9a462f4232b49f63ed3b22b0ff57725c82625ec/api/webrtc_sdp.cc)

macOSのネイティブRTC回帰6件が合格した。SDKが生成した通常の音声付きと映像付きのofferを拒否し、そのあと同じ接続でDataChannelだけの交渉が成功した。証跡は `.validation/security-audit-2000/webrtc-codec-boundary/`。次にSDKを更新するときは修正の包含を確認する。本番SFUと実機の確認は引き続き受入対象とする。[SDPの試験](../../development/自動検証.md#webrtcで受け取るsdp)

<a id="archive-2070-build-2018"></a>

## 2,070コミットの区切りでiOS Build 2018をArchiveする

2026-11-22。ローカルmainの第一親で通算2,070件目の `b3a6099a` から、標準の `RideIntercom` スキームでiPhone用Release Archiveを作った。署名、AppとWebRTCのdSYM、Bundle IDとバージョンを照合した。標準保存先の `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2018).xcarchive` に登録した。Organizerの一覧表示は未確認。

共有の書き出し設定で同じArchiveのIPAをこのMacに書き出した。AppとWidgetは1.0.0 Build 2018。App・Widget・WebRTCでApple Distribution署名を確認した。Appの実行ファイルに本番Workerの接続先を確認した。App Infoと署名は、ともにproduction APNsを指定していた。AppとWebRTCの実行ファイルはそれぞれのdSYMと照合した。Watch、開発用の接続設定、試験用リソースの非同梱を含む12項目が合格した。

証跡は `.validation/archive-2070-build-2018/`。次回ビルド番号は2019。App Store Connectへの送信は[全体監査](../../development/history/バックログの優先順位と進捗の記録.md#2000コミットの全体監査で本番試用の条件を照合する)の完了待ち。

## 2,100コミットの区切りでiOS Build 2071をArchiveする

2026-11-22。ローカルmainの第一親で通算2,100件目の `d4197073` から、標準の `RideIntercom` スキームでiPhone用Release Archiveを作った。署名とApp・WebRTCのdSYMを検証した。登録先は `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2071).xcarchive`。Organizerの一覧表示は未確認。

共有設定を使い、同じArchiveからIPAをこのMacに書き出した。AppとWidgetは1.0.0 Build 2071。App・Widget・WebRTCはApple Distribution署名で、本番Workerの接続先とproduction APNsを確認した。App GroupとdSYMの照合、Watch・テストバンドル・iCloud用entitlementの非同梱を含む12項目が合格した。

証跡は `.validation/maintenance-2100/production-export-verification.json`。App Store Connectへの送信は未実施。当時は配布前に[全体監査](../../development/history/バックログの優先順位と進捗の記録.md#2000コミットの全体監査で本番試用の条件を照合する)の残る項目を確認する予定だった。

## Build 2071のWebRTCとChromeの公開修正を照合する

2026-11-22。配布候補 `d4197073` のWebRTC ZIPは、採用記録のSHA-256と一致した。このZIPとBuild 2071のIPAではiOS arm64のデータを持つ31セクションが一致する。採用記録のWebRTCコミット `a9a462f423` を対象に、過去の照合で扱わなかったChromeの10月の公開告知2件を確認した。[採用したSDKとビルド情報](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#現行sdkとの組合せ)

| 公開告知 | 配布候補に対する照合結果 |
|---|---|
| CVE-2026-118328 | WebRTCのRTP処理を修正した公開コミット `3efe1a3a90c1` と `d86ac8ab5e04` は、採用コミットの履歴にどちらも含まれる。[Chromeの公開告知](https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_0562499947.html)・[1件目の公式レビュー](https://webrtc-review.googlesource.com/c/src/+/508300)・[2件目の公式レビュー](https://webrtc-review.googlesource.com/c/src/+/509462) |
| CVE-2026-113303 | Chromiumのmainと配布ブランチの公開レビュー4件は、いずれもChromiumのBlink内にある4ファイルだけを変更していた。RideComが採用するWebRTCのSDKにBlinkは含まれない。[Chromeの公開告知](https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_02018666648.html)・[mainの公式レビュー](https://chromium-review.googlesource.com/c/chromium/src/+/8591863) |

WebRTC公式リポジトリの参照を確認した時点では、`main` の先頭は11月21日の `97e37190541d` で、採用コミットから150コミット先だった。この数は新しい変更の件数を示す。今回の照合は表の2件を対象とし、その他の変更の影響や依存部品の継続保守は引き続き調べる。証跡は `.validation/security-audit-2100/webrtc-public/` に保存した。[WebRTC公式の公開履歴](https://webrtc.googlesource.com/src/+log/97e37190541d)

## 2,130コミットの区切りでiOS Build 2074をArchiveする

2026-11-22。ローカルmainの第一親で通算2,130件目の `e1a6502a` から、標準の `RideIntercom` スキームでiPhone用Release Archiveを作った。ソースはコミットから展開し、共通採番のBuild 2074を設定した。作業中のプロジェクトと依存設定の編集は組み込んでいない。Archiveの署名、AppとWebRTCのdSYMを検証した。

登録先は `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2074).xcarchive`。登録後の署名を再検証し、Xcodeで開く要求も成功した。Organizerの一覧で対象が見えるかは未確認。[AppleのArchive表示条件](https://developer.apple.com/documentation/technotes/tn3109-resolving-common-archiving-issues)

共有設定で同じArchiveからIPAをローカルへ書き出した。AppとWidgetの1.0.0 Build 2074、配布署名、本番Workerの接続先、production APNsを確認した。Watch・テストバンドル・iCloud権限の非同梱を含め、IPAの11項目が合格した。証跡は `.validation/maintenance-2130/`。次回ビルド番号は2075。App Store Connectへの送信は[全体監査](../../development/history/バックログの優先順位と進捗の記録.md#進行中の全体監査の引き継ぎ)の完了待ちだった。

### WebRTCの標準ターゲットに含まれるカメラ依存を確かめる

2026-11-22。公式WebRTCの未改変ソース `2a990ce0cc` で、iOS実機向けとmacOSのarm64をそれぞれ一時ディレクトリへ生成した。映像関連の設定は、公式ソースに切り替えたビルド手順 `3f6e0d07` と同じ値を使った。GNの引数検査が両構成で通り、`gn desc` で標準ターゲットの依存全体を照合した。[上流のApple向けビルド定義](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/BUILD.gn)・[採用手順](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#上流の無改変とカメラの不使用)

| 上流のターゲット | iOS実機とmacOSのarm64で確認した依存 |
|---|---|
| Apple向けObjective-C framework | カメラ撮影、カメラ関連の補助処理、dcSCTPを含む |
| C++のモジュール式PeerConnectionファクトリー | dcSCTPを含む。カメラ撮影・補助処理と既定のメディア構成を含まない |

当時のAppは、Apple向けframeworkのObjective-C APIを使う。C++ファクトリーは、Apple向けframeworkが配布条件を満たせない場合に検討できる標準の入口で、Swift側との接続と最終バイナリの検証が必要になる。この回ではGNの依存構成を確認した。標準版の通話、iOS Simulator、最終Archive・IPA、App Store Connectの処理は確認対象外だった。証跡は `.validation/security-audit-2100/webrtc-standard-targets/` に保存した。[上流のC++ API](https://webrtc.googlesource.com/src/+/refs/heads/main/api/create_modular_peer_connection_factory.h)・[配布時の確認](../../development/OS権限と配布設定.md#生成物での確認)

### 無改変のWebRTCを組み込んだ署名付きArchiveとIPAを照合する

2026-11-22。RideComの `4281e2b2` を検証領域へ展開し、公式WebRTCの `f0b51cdb2f` を更新スクリプトで5構成ビルドした。候補の履歴に当時採用していたWebRTCのコミットが含まれることと、依存同期で取得したBoringSSL `ddd732967` が修正 `9b639f5b` を含むことを照合した。依存同期で競合した旧gRPCチェックアウトは検証領域へ退避した。上流のソースとビルド定義は無改変で、候補ZIPは検証用のAppにだけ取り込んだ。[公式WebRTCのソース](https://webrtc.googlesource.com/src/+/f0b51cdb2fd2df5a44c2f05ccc3dc41f5f429362)

MacでRTCの144件、ネイティブWebRTCの6件が合格した。DataChannelの接続、音声・映像の媒体を含む接続要求の拒否、マイクを使わない双方向音声、通信断と復旧を確認した。標準の `RideIntercom` スキームで検証用のiOS 1.0.0 Build 2075の署名付きArchiveを作り、ローカルにIPAを書き出した。同じビルド番号で標準保存先へ登録したArchiveとは、ソースと同梱SDKが異なる。AppとWidgetの番号、AppとWebRTCのdSYM、配布署名、本番APNsを照合した。Watchとカメラの利用目的が含まれないことを確かめた。候補ZIPと両方の配布物で、WebRTCのarm64の命令領域とUUIDが一致した。

| AVCaptureクラスの外部参照 | App本体 | 同梱WebRTC |
|---|---:|---:|
| 比較元のBuild 2074のArchiveとIPA | 0 | 0 |
| 公式SDKで作成したBuild 2075のArchiveとIPA | 0 | 6 |

6種類には、過去の `ITMS-90683` で調査した `AVCaptureSession` と `AVCaptureDeviceDiscoverySession` が含まれる。標準のApple向けframeworkは、この候補での採用を保留した。同じコミットの実機向けGN依存で、公式のObjective-Cの `peerconnectionfactory_base_objc` とC++の `create_modular_peer_connection_factory` はdcSCTPを含み、`videocapture_objc` を含まなかった。両者は次の候補であり、既存のSwift呼出元との接続、最終Archive・IPAの参照、実機とApp Store Connectの受入が残る。今回のIPAはローカルに保持した。証跡は `.validation/security-audit-2100/webrtc-upstream-archive/` に保存した。[以前のApp Store Connectでの指摘](../README.md#カメラ不要の配布バイナリ修復2026-10-22)

後日、公式の同じコミットから採用用ZIPを改めて作り、別の成果物で検証した。[採用したZIPとBuild 2263の検証](#採用した無改変webrtcでbuild-2263を作る)

## 2,160コミットの区切りでiOS Build 2075をArchiveする

2026-11-22。第一親の通算2,160件目 `58851b25` を展開し、標準の `RideIntercom` スキームからiOSの1.0.0 Build 2075の署名付きRelease Archiveを作成した。検証には固定したコミットのApp、Widgetと当時採用中のSDKを使った。上の公式SDK比較用のBuild 2075とは、別のソースとSDKで作成した。AppとWidgetの番号、AppとWebRTCのdSYMのUUID、同梱したWebRTCと採用済みSDKのUUID、本番Workerへの接続先を照合した。

登録先は `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2075).xcarchive`。
登録後の署名と内容を再検証し、Xcodeで開く要求は成功した。Organizerの一覧での表示は未確認。[Archiveの登録と表示の確認](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

同じArchiveから本番用IPAをローカルに書き出した。Apple Distribution署名、production APNs、AppとWidgetの共有App Groupを照合した。Watch、テストバンドル、開発用権限、iCloud権限がないことを確認した。次回用の共通採番は2076。App Store Connectへの送信・処理とTestFlightでの確認は未実施。証跡は `.validation/maintenance-2160/` に保存した。

## 共有mainの2,160コミットで配布版の本番接続先を確認する

2026-11-22。共有 `main` の第一親の通算2,160件目 `78dddf01` を展開し、標準の `RideIntercom` スキームからiOS 1.0.0 Build 2076の署名付きRelease Archiveを作成した。AppとWidgetの番号、署名、dSYM、production APNsの構成は照合できた。Appの実行ファイルに本番Workerの固定接続先が入っていなかったため、配布版の受入は不合格とし、このArchiveは検証用の出力先に保持した。

固定接続先の修正を共有mainへ取り込む候補から、同じスキームでiOS 1.0.0 Build 2077を作成した。本番Workerのアドレス、AppとWidgetの番号、署名、AppとWebRTCのdSYM、採用済みWebRTCとArchive内のUUIDを照合した。macOSのアカウント回帰は24件合格。Previewの保存済み資格を拒み、本番に対応する資格だけを登録・復元と通常通知で使う試験を含む。

Build 2077をXcodeの標準保存先に登録した。

```text
~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2077).xcarchive
```

Xcodeで開く要求は成功した。Organizerの一覧表示、配布後のサインインと双方向音声は未確認。共有側と手元の採番の差を避けるため、Archiveの作成時にビルド番号を指定した。証跡は `.validation/shared-main-2160-archive/` に保存した。[配布版とDebugの入口](../../spec/App/UI/Settings.md#internet-connection)

2,200コミットの監査で、登録済みのArchiveと検証領域のArchiveの署名を再検証した。いずれも署名は有効で、アプリとプロビジョニングプロファイルの通常通知の環境は `development` だった。以前の記録では本番の通常通知の構成まで確認したと記載していた。Build 2077の本番用IPAの署名は別途確認が必要。再検証の集計は `.validation/security-audit-2200/archive-2077-confirmation.json` に保存した。

## 近距離復旧後に同じ相手へ音声を送り返さない

2026-11-24。カメラ撮影を含まないWebRTCの候補を使ったMac上の接続試験で、近距離復旧後に受け取った音声が、同じ相手へInternet経由で送り返される場合があった。試験用の音声だけを識別し、すでに送信元と中継端末を通った音声が送り返されていることを確認した。

現行SDKで、Internetの接続先一覧がpresenceより先に更新される順序を再現した。修正前は未経由の相手への転送と、同じ相手への送り返しが1回ずつ発生した。Internetの接続先全員が中継経路に含まれる場合は転送を省いた。修正後は未経由の相手を追加したときに1回転送され、受信先に音声が届いた。候補SDKでも双方向音声と近距離復旧を4条件で5回ずつ検証した。[中継の仕様](../../spec/packages/RTC.md#認証重複バッファ)

## 2,460コミットの区切りでiOS Build 2383をArchiveする

2026-11-24。共有main第一親2,460件目の `51379144` に対応する定期作業。コードと文書の整理を受け入れた `01a9788e` から、標準の `RideIntercom` スキームでiPhone向けの署名付きRelease Archiveを作成し、Xcodeの標準保存先に登録した。AppとWidgetは1.0.0 Build 2383で両方の署名が有効。AppとWebRTCのdSYMのUUID、採用済みの無改変WebRTCと同梱物のARM64の31セクションが一致した。Watch App、カメラ利用目的、CallKitとPushToTalkへの動的リンクは検出されなかった。App InfoのAPNs環境は `production`、Archiveに署名した時点の環境は `development`。Organizerでの一覧表示は未確認。次回用の共通採番は2384。

- App実行ファイルには以前の本番Worker URLが残っていた。旧URLの `/health` は404、新URLは200だった。[接続先の課題](../../backlog/未実装課題.md#本番と固定previewのworker-urlをridecomに揃える)
- App実行ファイルに対象クラスへの参照はなかった。同梱WebRTCには `AVCaptureDeviceDiscoverySession`、`AVCaptureDeviceInput`、`AVCaptureDeviceRotationCoordinator`、`AVCaptureSession`、`AVCaptureVideoDataOutput`、`AVCaptureVideoPreviewLayer` への参照があった。クラス名の完全一致で照合したBuild 2383の結果であり、Appleから指摘を受けた配布物との同一性は未確認。[ITMS-90683の課題](../../backlog/未実装課題.md#itms-90683の再発を解消してtestflightへ送信する)

登録したArchiveは `~/Library/Developer/Xcode/Archives/2026-11-24/RideIntercom iOS 1.0.0 (2383).xcarchive`。TestFlightへの送信や公開の操作は行っていない。

### カメラ参照を署名済みの配布候補で検出する

2026-11-24。配布前に、Appと同梱物の署名を検証し、Mach-Oに含まれるAVCaptureのクラス参照と各 `Info.plist` を調べるコマンドを追加した。Build 2383の同梱WebRTCから、クラス名の完全一致で6件を検出した。Build 1988の署名付きArchiveと、配布署名付きIPAから取り出したAppは通過した。符号化された音声や認証情報は検査結果に含めない。

欠けた実行ファイル、読み取れないシンボル、成果物の外を指す参照は、検査不能として失敗させる。署名済みの対象からどの構成が検出されたかを確認できる。Appleから指摘を受けた配布物との同一性と、修正版の処理結果は確認待ち。[検査の実行方法](../../development/OS権限と配布設定.md#iosのカメラ参照の送信前検査)

2026-11-24の照合。依頼者が今回の指摘を受けた番号を2263と特定した。標準保存先の署名付きBuild 2263も同梱WebRTCから同じ6クラスを検出した。保存済みの検証用Build 2075のIPAは、ファイルを直接指定した検査で拒否した。Build 1988のIPAは通過した。Build 2263の送信済みIPAは手元にないため、Archiveと送信したファイルの同一性は未確認。

採用時の上流 `f0b51cdb2f` のiOS実機向けGN依存では、通常の `framework_objc` は `videocapture_objc` を含む。公式ターゲットの `peerconnectionfactory_base_objc` と `create_modular_peer_connection_factory` は、いずれもdcSCTPを含み、`videocapture_objc` は含まない。確認時の上流main `5c5b140751` でも通常frameworkから撮影依存を外す条件は見つからなかった。候補の依存を確認した段階で、Swiftの呼出元との接続と署名済みの生成物は次に検証する。[上流のビルド定義](https://webrtc.googlesource.com/src/+/5c5b140751e0f4907e092c7a7b59981787d642e8/sdk/BUILD.gn)

### 撮影を含まないWebRTCのC++ターゲットでDataChannelを試す

2026-11-24。採用済みの上流 `f0b51cdb2f` を無改変のまま比較した。Mac用の試作には公式の `//sdk:peerconnectionfactory_base_objc` を使った。現行Appと同じ初期化方法でPeerConnectionとDataChannelを作成できた。

依存に撮影ターゲット `videocapture_objc` はなかった。`base_native_additions_objc` が依存する `helpers_objc` には `AVCaptureSession+DevicePosition.mm` があった。試作の実行ファイルに `AVCaptureSession` への外部参照が1種類残った。iPhone用とSimulator用のGN定義でも、このヘルパーを含むことを確認した。[上流のビルド定義](https://webrtc.googlesource.com/src/+/f0b51cdb2fd2df5a44c2f05ccc3dc41f5f429362/sdk/BUILD.gn)

次の候補には公式の `//api:create_modular_peer_connection_factory` を使った。各構成の `gn desc` で得た推移依存とNinjaのリンク入力を照合した。必要な既存のオブジェクトとライブラリから試験用の動的ライブラリをリンクした。メディアファクトリーとSTUN・TURNサーバーを設定せず、Swiftの検証プログラムからCのインターフェースを通じてPeerConnectionを2つ作った。

MacではIPv4ループバックを使った。両端でSDPを設定した後、DataChannelが開いた。2バイトのバイナリが双方向に届くことを3回確認した。

| C++ターゲットを使った試作 | 撮影クラスへの外部参照 | DataChannelの確認 |
|---|---:|---|
| macOS arm64 | 0 | MacのSwiftから双方向の送受信を確認 |
| iPhone arm64 | 0 | リンクとMach-Oの対象OSを確認 |
| iOS Simulator arm64 | 0 | リンクとMach-Oの対象OSを確認 |

上流と既存のAppには変更を加えていない。試作とローカル証跡は `.validation/itms-90683/upstream/` に保存した。既存のSwift実装から本番の通話に使うには、接続・SDP・ICE・統計・終了の契約をアプリ側から扱う接続部と、生成手順が必要になる。SimulatorとiPhoneでの実行、本番SFUを使った通話、署名付きArchive・IPA、Apple側の処理は候補の受入で確認する。[採用と配布の条件](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#上流の無改変とカメラの不使用)

続いて、通常frameworkのリンク情報を使わず、公式C++ターゲットを起点にリンク入力を得た。iPhone arm64、iOS SimulatorとmacOSのarm64とx86_64の計5構成で試作をリンクした。いずれもNinjaが出すビルドコマンドにカメラ撮影と通常frameworkの生成がなく、試作バイナリに撮影クラスへの外部参照はなかった。[リンク入力を確かめるコマンド](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#cの公式ターゲットに必要なリンク入力を確認する)

Mac arm64では空の出力先にGNの構成を生成した。Ninjaの2,485工程が完了し、スクリプトで接続部をリンクできた。Swiftからの双方向送受信も再確認した。他の4構成もスクリプトでリンクし、全5構成で撮影クラスへの参照はなかった。検査用ソースに `AVCaptureSession` の参照を含めた場合は、リンク後に失敗した。前に保存したライブラリの内容は同じだった。[動的ライブラリの生成手順](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#cの接続部を動的ライブラリにする)

RTCパッケージにC++候補の接続部を追加した。SwiftからPeerConnectionと制御・音声2種類のチャネルを作成した。ファクトリーのハンドルを先に解放しても、接続を利用できた。無効なIDと重複IDを拒否し、接続を解放すると両チャネルが閉じた。Mac arm64で同じ手順を3回実行した。iPhone、Simulator、macOSの計5構成で候補をリンクし、撮影クラスへの参照はなかった。[作成・終了の検証](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#c候補の接続とチャネルの作成終了を確認する)

候補の接続部にSDPの交渉を追加した。MacのSwiftで、媒体のないSDP、音声付きoffer、映像付きanswerを拒否した。続くDataChannel専用のofferとanswerは通った。offerの作成開始直後に接続を解放しても、Swift側で完了を受け取れた。同じ試験を3回実行した。全5構成でリンクし、撮影クラスへの参照はなかった。[SDPの検証](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#c候補でdatachannel専用のsdpを交渉する)

候補の接続部から、制御用と音声用のDataChannelを使ってバイナリを送受信した。Mac arm64のSwiftで、同一プロセスの2接続をIPv4ループバックでつないだ。両チャネルで状態変更の通知を受け、期待した4個のデータを双方向で受け取った。開く前と48KiBを超える入力の送信は拒否した。同じ試験を5回実行した。iPhone、Simulator、macOSの計5構成でリンクし、撮影クラスへの参照はなかった。[バイナリの送受信](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#c候補のdatachannelでバイナリを送受信する)

ICEの接続状態通知と、既存の接続にサーバー設定を渡す処理を追加した。Mac内の両端で接続済みを受け取った。接続を保ったまま、STUNとUDP TURNの試験用設定をSDKが受理した。TCP、TLS、空の設定を拒否した後も、既存の制御・音声チャネルで双方向の送受信が通った。これは設定更新の試験で、TURN経由の通信は採用候補のE2Eで確認する。[ICEの設定と検証](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#通話中の接続にiceサーバーを設定する)

候補の接続部から、選択されたICE経路の往復時間を取得できるようにした。初回の実行では、統計の通知がSwiftでメインアクターへ隔離された関数を呼び、実行時の検査で停止した。検証コードの受け取り方を修正し、SDKのスレッドから完了を受け取れるようにした。交渉前の値は取得できず、ループバックで双方向に送受信した後は測定値を受け取れた。[往復時間の検証](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#選択されたice経路の往復時間を取得する)

候補を `WebRTC.xcframework` に組み立てた。iPhoneとSimulator向けのSwiftでモジュールの読み込みとリンクが通った。MacのSwift試験では、XCFrameworkを使って同一プロセスの双方向通信を再確認した。全5構成に撮影クラスへの参照がなく、iPhone用のバイナリとdSYMのUUIDは一致した。3つのフレームワークにプライバシーマニフェストとライセンスを含めた。[XCFrameworkの作成手順](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#公式cターゲットのxcframeworkを組み立てる)

最初は個人のホーム内のGN出力を使った。取り込みの検査は、dSYMに作業パスを検出して停止した。採用済みの成果物は保持された。配布用のビルドと一時領域は個人のホームから移す。組み立てでは、実行ファイルのデバッグ情報を除いてからフレームワークに署名する。[取り込み時の作業パス検査](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#取り込みの中断と復帰)

## 2,330コミットの区切りでiOS Build 2270をArchiveする

2026-11-23。ローカルmainの第一親の2,330件目は `e0c566a7`。定期作業の優先順位を記録した共有mainの `6318d4af` から、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。AppとWidgetは1.0.0 Build 2270で、両方の署名を検証した。

実機用バイナリのARM64の31セクションが、採用済みの無改変WebRTCのZIPと一致した。AppとWebRTCのdSYMのUUIDは各実行ファイルと一致した。Appには本番Workerの接続先とプライバシーマニフェストが入っていた。ArchiveのAPNs署名は `development`。Watch App、カメラの利用目的、CallKit・PushToTalkへの動的リンク、iCloud権限、試験用の接続設定は検出されなかった。

Xcodeの標準保存先に登録し、登録後の署名を再検証した。Organizerの一覧表示は未確認。次回用の共通採番は2271。[Archiveの標準手順](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

```text
~/Library/Developer/Xcode/Archives/2026-11-23/RideIntercom iOS 1.0.0 (2270).xcarchive
```

## 2,310コミットの区切りでiOS Build 2260をArchiveする

2026-11-23。ローカルmainの第一親の2,310件目は `bdb8cf0f`。区切りを確認した時点の `4e957dc7` を展開し、標準の `RideIntercom` スキームでiPhone用のRelease Archiveを作成した。採用中だったZIPの記録には過去の独自パッチがあり、そのZIPで作ったBuild 2259は検証領域に留めた。

Build 2260には、[公式ソースを無改変でビルドした検証済みZIP](#無改変のwebrtcを組み込んだ署名付きarchiveとipaを照合する)を使用した。由来の記録とZIPのSHA-256を照合した。署名したWebRTCと元のZIPを比較した。ARM64バイナリのうち、ファイルにデータを持つ31セクションはすべて一致した。RTCの試験143件と、ネイティブWebRTCの試験6件が通過した。ローカルWorkerを使う1件の試験では、2人とも接続・更新・再参加できた。

AppとWidgetは1.0.0 Build 2260で、両方の署名が有効だった。AppとWebRTCのdSYMのUUIDは各実行ファイルと一致した。Appは本番Workerを参照し、実行ファイルはCallKitとPushToTalkに動的リンクしなかった。Watch App、カメラの利用目的、iCloudの権限、試験用の接続資格を含まなかった。Archiveの通常通知の署名環境は `development`。

Xcodeの標準保存先へ登録し、Xcodeで開く操作に成功した。Organizerの一覧表示は未確認。App Store Connectへの送信は行っていない。次回用の共通採番は2261。共有mainで無改変ZIPを採用し、Archiveを再作成する作業は[試用前の確認](../../backlog/未実装課題.md#最初に試すインターネット通話と通知と招待)で追う。

登録先は次のとおり。

```text
~/Library/Developer/Xcode/Archives/2026-11-23/RideIntercom iOS 1.0.0 (2260).xcarchive
```

### 共有mainからBuild 2261を作りdSYMの共有条件を確認する

2026-11-23。共有mainの `98451cca` に、Build 2260で検証した無改変の公式WebRTC ZIPと由来の記録を検証領域で揃えた。iOS実機・Simulator・macOS向けの計5構成で、由来の記録と実際の `args.gn` の照合値が一致した。全構成の `is_debug=false` を確認した。

iPhone用Build 2261はApp・Widgetの署名とApp・WebRTCのdSYMの照合に通った。署名後のWebRTCを元のZIPと比べると、ARM64でファイルにデータを持つ31セクションが一致した。Xcodeの標準保存先への登録まで確認した。

macOSのRTC試験148件が通った。iPhone SimulatorのBuild 2262では、音声機器を使わずに発話を双方向に送った。ローカル中継を使い、各方向で98/98フレームが一致した。次回用の共通採番は2263。

ZIPを展開した検査では、iOS向けのdSYMに個人のホームパスが2件残っていた。共有元からのビルドは再現できたが、このZIPの共有と配布は保留する。公式の同じコミットを個人名のない作業パスでビルドし、新しいZIPでパスの不在と署名・同梱物を確認する。[試用の残作業](../../backlog/未実装課題.md#最初に試すインターネット通話と通知と招待)

2026-11-21に手元で採用したWebRTC `a9a462f423` では、Apple SDKの非推奨APIに関する警告18件を記録した。当時のZIPでMacのRTC回帰143件、ネイティブWebRTCの6件、SwiftとWorkerの通信試験1件が通った。iPhone向けReleaseビルドと、iPhone Simulatorでの経路切替4条件も通った。

### 採用した無改変WebRTCでBuild 2263を作る

2026-11-23。公式のWebRTCコミット `f0b51cdb2f` とその依存を、個人名を含まない作業パスに展開した。上流ソースとビルド定義に変更を加えず、Release用の5構成からZIPを作成した。ZIPと由来の記録を同じ取り込み操作で採用した。展開した323項目を検査し、dSYMを含めて個人のホームパスが0件と確認した。

共有mainの `c50958c3` のソースと採用したZIPで、iPhone用Build 2263のArchiveを作成した。AppとWidgetの署名、AppとWebRTCのdSYMのUUID、ZIPと同梱WebRTCのARM64の31セクションを照合した。Appは本番Workerを参照する。Archiveに署名した時点の通常通知の環境は `development`。Xcodeの標準保存先へ登録した。

macOSでRTCの回帰148件、SwiftとローカルWorkerを用いた2人の接続・更新・再参加の試験1件が通った。iPhone SimulatorのBuild 2264は、ローカル中継で両方向98/98フレームが一致した。次回用の共通採番は2265。試用配布と実機での通話は、引き続き[試用の残作業](../../backlog/未実装課題.md#最初に試すインターネット通話と通知と招待)で追う。

## 2,280コミットの区切りでiOS Build 2213をArchiveする

2026-11-23。手元のmainの第一親で2,280件目の `d0f04ffd` に対応する共有main `b774c08d` から、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。AppとWidgetは1.0.0 Build 2213。署名とApp・WebRTCのdSYMが一致し、実行ファイルに本番Workerの接続先が入っていた。Watch App、カメラの利用目的、CallKitとPushToTalkの動的リンク、iCloudの権限は含まれなかった。署名時の通常通知の環境は `development`。[標準のArchive手順](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

登録先は `~/Library/Developer/Xcode/Archives/2026-11-23/RideIntercom iOS 1.0.0 (2213).xcarchive`。登録済み・一覧表示は未確認。App Store Connectへの送信は行っていない。次回用の共通採番は2214へ進んだ。

2,300コミットの監査で、Build 2213の署名は有効と確認した。同梱WebRTCのiOS arm64の31セクションはBuild 2077・2142および以前の共有側の検証用ZIPと一致した。採用記録に一致するZIPはBuild 2086と対応する。Build 2077・2142・2213の配布は保留し、Build 2086の採用記録にも過去の独自パッチがある。[無改変の公式WebRTCを使ったBuild 2260](#2310コミットの区切りでios-build-2260をarchiveする)は、別のZIPとその由来を示す記録を使った。共有mainから作る配布候補では、無改変のZIPを使い、由来と署名を同じ手順で照合する。[2,300コミットの全体監査](../../development/history/バックログの優先順位と進捗の記録.md#2300コミットの全体監査で配布候補と稼働中の設定を照合する)

## 2,250コミットの区切りでiOS Build 2142をArchiveする

2026-11-23。手元のmainの第一親の2,250件目は `a2995cf4`。対応する共有mainの `9524896a` を展開し、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。[標準のArchive手順](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

AppとWidgetはともに1.0.0 Build 2142だった。署名とApp・WebRTCのdSYMを照合した。実行ファイルに本番Workerの接続先があることを確認した。Watch App、カメラの利用目的、CallKitとPushToTalkの動的リンク、iCloud権限は含まれなかった。Archiveの通常通知の署名環境は `development`。配布用の署名と通知到達は配布時・配布後の確認として扱う。

登録先は `~/Library/Developer/Xcode/Archives/2026-11-23/RideIntercom iOS 1.0.0 (2142).xcarchive`。Xcodeで開く操作は成功した。操作環境に一覧を読み取る権限がなかったため、Organizerで対象の行が表示されたかは未確認。App Store Connectへの送信は行っていない。次回用の共通採番は2143へ進んだ。

## 2,220コミットの区切りでiOS Build 2086をArchiveする

2026-11-22。手元のmainの第一親で2,220件目の `40ddb010` から、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。AppとWidgetは1.0.0 Build 2086で一致した。署名とApp・WebRTCのdSYMを検証し、実行ファイルに本番Workerの固定接続先があることを確認した。Watch App、カメラの利用目的、CallKitとPushToTalkの動的リンク、iCloud権限は含まれなかった。

登録先は `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2086).xcarchive`。Xcodeで開く要求は成功した。Organizerの一覧での表示は未確認。次回用の共通採番は2087へ進んだ。[Archiveの登録と表示の確認](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

ArchiveのAppに署名された通常通知の環境は `development`。内部テストへの直接送信ではXcodeが配布用に署名する。今回の記録はArchiveまでで、App Store Connectへの送信結果は未確認。

Build 2086の元のWebRTC ZIPはBuild 2071・2074で公開修正を確認したZIPと同一だった。Build 2086の署名付きArchiveに含まれるWebRTCと、このZIPのiOS実機用バイナリを比較し、arm64でデータを持つ31セクションの内容がすべて一致した。照合済みのWebRTCとBoringSSLの修正については、この結果を内部試用に引き継ぐ。
