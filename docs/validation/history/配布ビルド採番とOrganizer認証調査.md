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

## 共有mainの2,160コミットで配布版の本番接続先を確認する

2026-11-22。共有 `main` の第一親の通算2,160件目 `78dddf01` を展開し、標準の `RideIntercom` スキームからiOS 1.0.0 Build 2076の署名付きRelease Archiveを作成した。AppとWidgetの番号、署名、dSYM、production APNsの構成は照合できた。Appの実行ファイルに本番Workerの固定接続先が入っていなかったため、配布版の受入は不合格とし、このArchiveは検証用の出力先に保持した。

固定接続先の修正を共有mainへ取り込む候補から、同じスキームでiOS 1.0.0 Build 2077を作成した。本番Workerのアドレス、AppとWidgetの番号、署名、AppとWebRTCのdSYM、採用済みWebRTCとArchive内のUUIDを照合した。macOSのアカウント回帰は24件合格。Previewの保存済み資格を拒み、本番に対応する資格だけを登録・復元と通常通知で使う試験を含む。

Build 2077をXcodeの標準保存先に登録した。

```text
~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2077).xcarchive
```

Xcodeで開く要求は成功した。Organizerの一覧表示、配布後のサインインと双方向音声は未確認。共有側と手元の採番の差を避けるため、Archiveの作成時にビルド番号を指定した。証跡は `.validation/shared-main-2160-archive/` に保存した。[配布版とDebugの入口](../../spec/App/UI/Settings.md#internet-connection)

2,200コミットの監査で、登録済みのArchiveと検証領域のArchiveの署名を再検証した。いずれも署名は有効で、アプリとプロビジョニングプロファイルの通常通知の環境は `development` だった。以前の記録では本番の通常通知の構成まで確認したと記載していた。Build 2077の本番用IPAの署名は別途確認が必要。再検証の集計は `.validation/security-audit-2200/archive-2077-confirmation.json` に保存した。

## 2,280コミットの区切りでiOS Build 2213をArchiveする

2026-11-23。手元のmainの第一親で2,280件目の `d0f04ffd` に対応する共有main `b774c08d` から、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。AppとWidgetは1.0.0 Build 2213。署名とApp・WebRTCのdSYMが一致し、実行ファイルに本番Workerの接続先が入っていた。Watch App、カメラの利用目的、CallKitとPushToTalkの動的リンク、iCloudの権限は含まれなかった。署名時の通常通知の環境は `development`。[標準のArchive手順](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

登録先は `~/Library/Developer/Xcode/Archives/2026-11-23/RideIntercom iOS 1.0.0 (2213).xcarchive`。登録済み・一覧表示は未確認。App Store Connectへの送信は行っていない。次回用の共通採番は2214へ進んだ。

## 2,250コミットの区切りでiOS Build 2142をArchiveする

2026-11-23。手元のmainの第一親の2,250件目は `a2995cf4`。対応する共有mainの `9524896a` を展開し、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。[標準のArchive手順](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

AppとWidgetはともに1.0.0 Build 2142だった。署名とApp・WebRTCのdSYMを照合した。実行ファイルに本番Workerの接続先があることを確認した。Watch App、カメラの利用目的、CallKitとPushToTalkの動的リンク、iCloud権限は含まれなかった。Archiveの通常通知の署名環境は `development`。配布用の署名と通知到達は配布時・配布後の確認として扱う。

登録先は `~/Library/Developer/Xcode/Archives/2026-11-23/RideIntercom iOS 1.0.0 (2142).xcarchive`。Xcodeで開く操作は成功した。操作環境に一覧を読み取る権限がなかったため、Organizerで対象の行が表示されたかは未確認。App Store Connectへの送信は行っていない。次回用の共通採番は2143へ進んだ。

## 2,220コミットの区切りでiOS Build 2086をArchiveする

2026-11-22。手元のmainの第一親で2,220件目の `40ddb010` から、標準の `RideIntercom` スキームでiPhone用の署名付きRelease Archiveを作成した。AppとWidgetは1.0.0 Build 2086で一致した。署名とApp・WebRTCのdSYMを検証し、実行ファイルに本番Workerの固定接続先があることを確認した。Watch App、カメラの利用目的、CallKitとPushToTalkの動的リンク、iCloud権限は含まれなかった。

登録先は `~/Library/Developer/Xcode/Archives/2026-11-22/RideIntercom iOS 1.0.0 (2086).xcarchive`。Xcodeで開く要求は成功した。Organizerの一覧での表示は未確認。次回用の共通採番は2087へ進んだ。[Archiveの登録と表示の確認](../../development/開発環境.md#xcode標準のバージョン管理とarchive)

ArchiveのAppに署名された通常通知の環境は `development`。内部テストへの直接送信ではXcodeが配布用に署名する。今回の記録はArchiveまでで、App Store Connectへの送信結果は未確認。

Build 2086の元のWebRTC ZIPはBuild 2071・2074で公開修正を確認したZIPと同一だった。Build 2086の署名付きArchiveに含まれるWebRTCと、このZIPのiOS実機用バイナリを比較し、arm64でデータを持つ31セクションの内容がすべて一致した。照合済みのWebRTCとBoringSSLの修正については、この結果を内部試用に引き継ぐ。
