# Cloudflare 試用準備の検証記録

> この記録は記載時点の実装・コマンド・結果。現在の受け入れ状況は[検証一覧](../README.md)を参照し、当時の成功件数を現行HEADの再実行結果と読み替えない。

> この文書は初回Cloudflare試用基盤の履歴。現行のDataChannel中継・機器停止・費用見直しの結果は [混在通話検証](混在通話検証.md) が正本。旧native RTP / mid再利用の説明を現行媒体へ適用しない。


## 背景と範囲

2026-10-21。dev基準の復旧済み作業ブランチ `codex/restore-dev-calls` で、SFU接続・利用枠・端末資格・費用試算を実装。実機と外部デプロイを待たず、自動検証を進める指示に従う。実Cloudflareアカウントの請求・音声は未検証。

## 環境と証跡

| 項目 | 値 |
|---|---|
| workspace | `~/.codex/worktrees/restore-dev-calls/RideIntercom` |
| 証跡directory | `/private/tmp/rideintercom-cloudflare-validation`。一時領域なので必要なら利用者側で保管する |
| Apple toolchain | Xcode27.1 / Swift6.4。各コマンドに `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| macOS | 27.0.1、arm64 |
| iOS | 専用 iPhone17 Pro Simulator、iOS26.4.1、`5DDF37BD-AAC5-4930-AB0D-FA16412C9E18` |
| サーバー | Node26.12.0。依存パッケージのバージョンはWorker.mdを参照 |
| 既存作業 | 元の `codex/restore-local-calls` の未コミット変更を保持。main `295f54b` / dev `efb50cf` は更新しない |

## 自動検証と限界

| 対象 | 結果 / 証跡 |
|---|---|
| Worker | 型検査・8 tests成功。`server-final-types.log` / `server-final-tests.log` |
| 費用・端末資格 | 3 tests成功。`cloudflare-scripts.log` / `cost-scenarios.tsv` |
| macOS App | 49 tests成功。`macos-accepted.xcresult` (最終RTC・資格編集sheet組込み) |
| iOS App単体 | 49 tests成功。`ios-accepted.xcresult`内のRideIntercomTests。UIのhit testing失敗を含むため、このbundle全体を成功と扱わない |
| RTC | 31 tests成功。`rtc-final3.log`。一時更新失敗・遅延DELETEのredは `rtc-renew-red3.log` |
| native WebRTC | `swift build --package-path RideIntercom/packages/RTC --target RTCNativeWebRTC` 成功。`native-final2.log` |
| 初回red | `app-red.xcresult` / `app-red2.xcresult`。新設定APIと音声所有権eventが存在しない状態で失敗を確認 |
| 途中のテスト不備 | `app-green2` は非同期イベント待ち不足。`ios1` は追加セクションのスクロール前提、`ios-ui3` は表示範囲/キーボード、`ios-final` は浮動タブのhit pointで失敗。さらに前回失敗のroute設定残留と初回タブ識別子差を修正して再実行 |
| iOS UI最終 | `ui-accepted.xcresult` の3 tests成功（主要操作、資格入力後の復帰/スイッチ、起動）。最終Appコードは`ios-accepted`の単体49件と同じ。UIテスト修正とソースのインデント整理だけを後から反映 |
| 資格編集の回帰 | `ui-focus-red` / `ui-focus2` で入力後のタブ復帰失敗を再現。Settings画面をpresenterとする標準sheetへ分離し、`ui-sheet2` の専用回帰1件成功。さらにスイッチの値変化を検査した `ui-switch` も成功 |
| 空の実行 | `ios-ui2.xcresult` は指定誤りで実行0件。成功件数に含めない |
| SDK通知 | AppIntents未使用targetのmetadata extraction skipped、XcodeのSDK build文字列診断、失敗時のsimctl診断収集警告が残る。テスト対象Swiftコードのwarningを隠す設定変更は行わない |
| Simulator codec | AAC ELDv2 unavailableを検出してfallbackするログあり。実機のcodec availabilityと同一とは扱わない |

## 再実行入口

```sh
scripts/validate.sh packages
scripts/validate.sh worker
scripts/validate.sh scripts
scripts/validate.sh macos
scripts/validate.sh ios
```

`ios` は新しい専用Simulatorを作り、終了時にshutdownする。利用者のSimulatorをeraseしない。失敗段階は `results.tsv` と終了コードへ反映する。

今回のApp単体は以下の形式で実行し、証跡名を変えて失敗と修正後を分けた。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RideIntercom.xcodeproj -scheme RideIntercom \
  -destination 'platform=macOS,arch=arm64' -only-testing:RideIntercomTests \
  -derivedDataPath /private/tmp/rideintercom-dev-validation/automation-macos/DerivedData-macOS \
  -resultBundlePath /private/tmp/rideintercom-cloudflare-validation/macos-final.xcresult
```

既存xcresultへ上書きしないため、再実行時は新しいresultBundlePathを選ぶ。実アカウント試用の手順は `Worker.md`、費用再計算は `Cost.md` を参照。

## 後続の受け入れ

| 残件 | 確認内容 |
|---|---|
| Cloudflare実サービス | アカウント/秘密設定、2端末publish/subscribe、実媒体、20分以上のlease跨ぎ、請求meterを確認 |
| 実機 | Mac/iPhoneの双方向音声、画面ロック、Bluetooth/有線切替、一時ネットワーク断の復帰 |
| 公開前 | identity自動発行/失効、edge abuse制限、TURN、peer入替時のSDP再利用、実料金監視と停止運用 |

自動テストが成功したとき、次の表現で報告することを禁じた。

> 「実機通話復旧完了」「公開準備完了」「月額上限保証」

最終UI試験には次のコマンドを使った。既存の専用Simulatorを再利用し、データを消去しなかった。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RideIntercom.xcodeproj -scheme RideIntercom \
  -destination 'platform=iOS Simulator,id=5DDF37BD-AAC5-4930-AB0D-FA16412C9E18' \
  -only-testing:RideIntercomUITests -parallel-testing-enabled NO \
  -derivedDataPath /private/tmp/rideintercom-dev-validation/automation-ios/DerivedData-iOS \
  -resultBundlePath /private/tmp/rideintercom-cloudflare-validation/ui-accepted.xcresult
```

## コミットの区分

| コミット | 内容 |
|---|---|
| `89b7abe` | RTCの実SFU publish/subscribe・lease契約 |
| `71314a9` | Worker認証・利用枠・費用試算・試用スクリプト |
| `5e9ff9a` | Appの資格保存・音声の所有権の切替 |
| `c1f8646` | RTCの一時更新失敗と遅延切断応答の回帰修復 |
| 本記録を含む最終コミット | 資格編集sheet、UI回帰、要求・仕様・検証記録 |

main/devへのマージ、push、Cloudflareデプロイは行っていない。

## 後続の品質点検

2026-10-21の追加点検で、購読midの再利用、Swift clientとWorkerのペア検証、native SDPの自動検証を追加した。上記の未確認事項のうち「peer入替時のSDP再利用」はローカル自動検証済みとなった。実Cloudflare媒体の確認は引き続き必要。最新の結果は [品質点検](品質点検.md) を参照する。

## プラグインによる実設定とプレビュー準備の確認

2026-10-30。Cloudflareプラグインで実Workerの設定・メトリクスを読取り、他作業と分離したworktreeでプレビュー設定を追加した。Workerの媒体処理、App、RTC packageは変更していない。

| 対象 | 結果と条件 |
|---|---|
| 実Worker | `rideintercom`。通常URLは`https://rideintercom.analog.workers.dev`。Productionに2つのSQLite DO bindingがあり、SERVICE_ENABLEDはfalse、SFU値・端末registryは未登録 |
| 実メトリクス | 2026-10-30 19:22 JST取得。直前24時間のWorkers集計はrequests=3、errors=0、subrequests=0。errorsは実行時例外等の指標でありHTTP 401/503やSFU音声の成否とは別 |
| Previews Base | 初回読取時、SFU App ID、SFU App Secret、CLIENT_TOKENS_JSONの3項目が存在。secretの内容は取得・出力していない。実プレビューは0件 |
| 設定の修正 | Worker名を実設定と同期。`previews.vars`へ有効化と利用枠、`previews.durable_objects.bindings`へ2つの独立bindingを定義。`npm run preview`を追加しbranch単位で配置 |
| ローカル検証 | Wrangler 4.151.3で設定読込みとbundle dry-runに成功した。TypeScript型検査、Worker 20 tests、Cloudflareスクリプト4 tests、文書検査、diff checkが成功 |
| 外部配置の制約 | プラグインのPreview作成APIはHTTP 403。ローカルWranglerは未ログイン。既存main用CIをPreview向けに置換する操作は、自動承認レビューが本番配置への影響を理由に拒否し、変更されていない |
| 採用した配置経路 | mainのProduction用CIを保持し、利用者がGitHub連携のPreview buildsと`npx wrangler preview`を設定。修正を含む専用branchをpushして配置する |
| 配置前の未確認 | 実Preview URLでの資格照合・DO動作、実SFUの接続・双方向音声、利用枠更新、TURN、請求。ローカルの20 testsは外部SFUを代替しており、これらを証明しない |

同日19:33 JST、`codex/cloudflare-preview-setup`の`2a50b5cba134ff0ae755fecb087dfe53f3883023`をpushし、GitHub連携のプレビュービルドが成功した。以降の記録更新では、同じbranchのソースへ変更を加えていない。

| 実プレビューの確認 | 結果 |
|---|---|
| Preview URL | `https://codex-cloudflare-preview-setup-rideintercom.analog.workers.dev` |
| 配置 | build `a565635f-440d-42d4-9bed-c0b8a8e8e30d`がsuccess。deployment `dc340055-0e85-41cd-85db-669d3b8100f8`、migration v1 |
| 実行時設定 | Baseの3項目と、ファイルで定義した有効化・利用枠・2つのDO bindingを確認。SERVICE_ENABLED=true、TURN_ENABLED=false |
| 独立性 | SIGNALING_ROOM / USAGE_GUARDのnamespace IDが両方ともProductionと異なる。Productionのdeployment `9cdf421f-c93e-4130-94f2-c8d9abd7ad68`が変更されていないことをAPIで照合 |
| GET /health | 200、service=`RideIntercom SFU`、protocol=1 |
| GET /api/status、資格なし | 401 |
| GET /api/status、Mac / iPhoneの個別資格 | 両方200。2026-10月、予約参加者秒0、月上限1,000,000、active sessions 0。資格の値は出力していない |
| 残る確認 | 実SFUの接続・双方向音声、通話中の更新・回収、TURN・制限回線、実請求。healthとstatusの成功はSFU App Secretの有効性や音声品質の証明ではない |

現行の設定手順は[Cloudflare試用手順](../../development/Cloudflare試用手順.md)を参照する。

## Debug既定値と実サービス検証の費用制約

2026-10-30。App画面への手入力を省き、開発ビルドだけに既定の接続先と端末資格を用意する指示を適用した。大量の実Cloudflare試験による費用を抑える要求を製品要求と開発方針へ追加し、単体・結合を含むローカル検証が全成功した後の、人数・時間・回数を制限した明示実行に分けた。

| 対象 | 結果 |
|---|---|
| 開発用入力 | `Configuration/Debug.xcconfig`をAppのDebug構成だけへ割当て、gitignore対象の`Debug.local.xcconfig`をoptional include。発行済みのmacOS / iOS用資格をこのMacに用意。Script phaseの環境変数表示を無効化 |
| Appへの適用 | 通常のDebug buildで生成Info.plistへplatform別の値を入れ、Keychain未設定時に使用。Keychainへ自動保存しない。保存済み設定・読取り失敗・不正な保存データは上書きしない |
| 配布との分離 | macOS / iOSのDebug・Releaseを実ビルド。Debugの2成果物がそれぞれ所定の資格と一致し、Releaseの両bundleには開発用Info keyも両端末のtokenもない。build logにもtokenがないことを検査。Archiveでの除外はmetadataの単体試験で確認し、新しいArchiveは作成していない |
| 自動テストとの分離 | XCTestのprocess環境、またはUI testが渡す`RIDEINTERCOM_LOCAL_TESTING=1`ではcurrent-processのInternet資格読取り・保存を無効化。fixture storeの明示注入は維持。隔離storage namespaceのビルドにも既定値を含めない |
| macOS単体 | 148件成功、failed / skipped / runtime warnings 0。`.validation/dev-internet-macos.xcresult` |
| iOS単体 | 専用の一時Simulatorで148件成功、failed / skipped / runtime warnings 0。`.validation/dev-internet-ios-isolated/ios-tests.xcresult` |
| UI | 初回iOS runのUI 5件は成功。同じrunの音声pipeline単体1件が失敗したため、run全体は成功扱いにしない |
| スクリプトと文書 | Python 71件成功。metadata 14件はその内数。文書・開発環境検査、diff check成功 |
| 試行中の失敗 | 初回の資格JSONの直接読取りはXcode sandboxに拒否され、最終構成は通常のxcconfig経由に変更。初回iOS単体は`AURemoteIO::Initialize` / `_ReportRPCTimeout`のSIGABRT。共有Simulatorの再利用が他作業のlockと衝突したため、その作業を止めず一時Simulatorで単体全件を再検証。音声処理や試験の基準は変更していない |
| 後片付けと秘密 | 所有Mac test hostが残っていないことと、一時Simulatorの停止・削除を確認。tokenは差分・検証logへ出ていない。private fileはGitへ含めない |
| 実サービスと全体受入れ | この変更の検証では実CloudflareのHTTP/SFU/TURNを呼び出さず、再デプロイもしない。`validate.sh all --clean`や独立音声E2Eの全体受入れとは別の確認であり、実サービスの次の検証前には基準となる資料の費用制約を満たすこと |

主な証跡は`.validation/dev-internet-build-proof.json`、`.validation/dev-internet-scripts-final.log`、各xcresult。ビルド番号は既定の自動採番に従って増加し、公開バージョンは1.0.0を維持した。他のApp作業と衝突するmainへの統合と、不要なCloudflare buildを起動するpushは行っていない。

## 最新mainとの統合検証

2026-10-30。その後の「定期的にmainへマージ」「pushも行う」という指示を適用した。専用worktreeへmainの`c4c98d8f`までを取り込み、保存済みユーザー・個別通話・保存形式の変更とDebugの既定接続設定が競合なく統合できた。検証が完了した作業の区切りでmainへ統合・pushし、リモートSHAを照合する方針を開発方針へ追記した。

| 対象 | 結果と証跡 |
|---|---|
| macOS単体 | 173件成功、failed / skipped / runtime warnings 0。`.validation/main-integration-macos/macos-tests.xcresult` |
| iOS単体 | 分離した一時Simulatorで173件成功、failed / skipped / runtime warnings 0。`.validation/main-integration-ios-final/ios-tests.xcresult` |
| 通常UI | 初回統合runでcodec・適応表示・個別通話・Internet資格・復旧workflowの5件成功。未完了だった保存済みユーザー1件と起動1件は、分離runでそれぞれ成功。後者は`.validation/main-integration-ios-final/ios-users.xcresult`と`ios-launch.xcresult` |
| 破損保存の復旧UI | 隔離したApp containerへfixtureを用意し、UI 1件成功と元の破損bytesの保存を確認。`.validation/main-integration-ios-final/ios-recovery.xcresult`、`recovery-verify.log` |
| Workerとローカル結合 | 型検査成功、Worker/DO 20件成功、実Swift HTTP/WSとローカルWorker/DOのペア1件成功。外部SFUはmock。`.validation/main-integration-worker.log`、`main-integration-pair.log` |
| スクリプトと静的検査 | Python 71件、Cloudflareスクリプト4件成功。文書・開発環境・diff検査成功。検証中のApp・test・script・Workerのソースhash一致と、検証logに両端末のtokenがないことを確認 |
| 初回統合runの失敗 | iOSの`AURemoteIO::Initialize` / `_ReportRPCTimeout`でSIGABRTが再発し、UIを含む全体実行もrunnerの600秒上限で未完了になった。このrun全体は成功扱いにしていない。単体と残りのUIを分離して上記の成功を確認し、音声処理コードや試験基準は変更していない |
| 後片付けと統合対象 | この検証が作成した一時Simulatorは停止・削除済み。main側の未コミットのXcode参照設定を今回のcommitへ含めず保全する。ローカルDebug資格はignore対象のままmainの作業環境へ引き継ぐ |

公開バージョンは1.0.0、ビルド番号は既定の自動採番による20。この統合検証では実CloudflareのHTTP/SFU/TURN試験を追加実行していない。今回の範囲の確認を、`validate.sh all --clean`・独立音声E2E・実機・実SFU媒体の全体受入れと扱わない。実サービスの検証を始める前の条件は、引き続き開発方針の費用制約に従う。

## 通知の公開値と外部設定の照合（2026-11-18）

利用者の指示により、Appとserverで設定できる公開値を揃え、Apple／Cloudflareで行う設定を該当する文書にまとめた。APNS_TOPICを両環境でAppのbundle IDへ設定し、ProductionのAPNS_ENVIRONMENTをRelease／TestFlightのproductionへ合わせた。PreviewはDebug向けsandboxを保持。NOTIFICATIONS_ENABLEDとAPPLE_AUTH_ENABLEDはfalseのままで、有効化・secret登録・配置は行っていない。

変更前の対照スクリプトは両topicの空欄とProductionの環境不一致でexit 1。修正後はAppのRelease設定を直接読んだ照合に成功。Worker82件・型検査、OS／配布設定15件とplatform checker、文書・diff検査が成功した。Wranglerの型生成も同じinclude-runtime=false／strict-vars=falseで実行し、生成物は既存と同値だった。証跡と入力hashは`.validation/notification-deployment-settings-20261118`へ保存した。型生成の初回だけ作業directoryを誤り、実行前に127で止まったため、正しいserver directoryでやり直した。

[Cloudflare試用手順](../../development/Cloudflare試用手順.md#利用者が行うapplecloudflareの設定と受入順)へ変数・secret・5 DOとv1/v2/v3 migration・環境別の有効化・2端末での受入をまとめた。[Appleの権限と配布設定](../../development/OS権限と配布設定.md)へAPNs鍵・Sign in with Appleのclient-secret・profileとの対応を揃えた。古い「自動登録は未実装」「DO bindingは2つ」を現行の実装へ修正した。TestFlight Internal OnlyもAPNsはproductionであり、Previewへ接続する場合もその環境を合わせる。通常APNsだけを使い、group専用secretは不要である。実Apple・APNs・配置後の実SFUの受入は未確認事項に維持する。

## Productionの実設定の読取（2026-11-18）

Cloudflare APIのWorker一覧・settings・secret名一覧をGETし、対象rideintercomを確認した。5 DOとmigration v3、App IDのAPNS_TOPICとproduction環境、APPLE_CLIENT_IDは配置へ反映済みだった。APPLE_AUTH_ENABLED・NOTIFICATIONS_ENABLED・SERVICE_ENABLED・TURN_ENABLEDはfalse。secret名は0件でSFU App IDの通常bindingもなかった。Previewは未監査。

`.validation/notification-cloudflare-state-20261118/production.json`に公開値・binding名と未確認範囲だけを保存した。secretの値を取得せず、変更API・手動デプロイを行っていない。実状態の証拠は設定読取の範囲であり、配置されたコードの同一性や実配達の受入とは区別する。必要な外部設定は[試用手順](../../development/Cloudflare試用手順.md#外部設定の確認状況)へ集約した。


## Productionと固定Previewの読取（2026-11-19）

管理APIのGETを使い、現在のProductionのWorker設定・secret名一覧・migration、固定Previewの配置番号382に含まれる公開設定・binding名を照合した。両環境でApp IDと5つのDO、migration v3を確認した。Productionはsecret名0件、SFU App IDのbindingなし。固定PreviewはSFU App ID、`CLOUDFLARE_SFU_APP_SECRET`、`CLIENT_TOKENS_JSON`があり、SERVICE_ENABLEDがtrueだった。両環境でAPPLE_AUTH_ENABLED・NOTIFICATIONS_ENABLED・TURN_ENABLEDはfalse。

公開設定とsecret名の証跡は `.validation/notification-cloudflare-state-20261119/settings.json`。Previews Baseには照合を広げていない。アカウント固有のsecret値を記録していない。固定PreviewとBaseの入力先の違いはCloudflare公式手順と、リポジトリのWrangler 4.151.3のヘルプで照合した。同じ試用手順で、1対1の呼び出しを開く操作、通話を開始しないグループ招待、実音声の受入を明記した。[試用手順](../../development/Cloudflare試用手順.md#外部設定の確認状況)

## 未参照TURN keyの削除と環境別命名（2026-11-21）

Cloudflare APIのGETで、Productionと固定`preview`を含む現存3 Previewの公開設定・binding名を照合した。Productionはsecret名0件、3 Previewはいずれも`TURN_ENABLED=false`で、全対象に`CLOUDFLARE_TURN_KEY_ID`と`CLOUDFLARE_TURN_API_TOKEN`のbindingがなかった。リポジトリにも対象ID・名前の参照はなかった。

Accountingアカウントに存在したTURN key `lively-bar-4bf6`（ID `17dfb79b3f05d349aa02155b021a49f5`）は参照されていないと判断した。対象の名前とIDを再照合してから削除した。削除後のGETは404を返した。秘密値は取得・表示・記録していない。新しいkeyは作成していない。[Cloudflare試用手順](../../development/Cloudflare試用手順.md#turn有効化)へPreview=`rideintercom-turn-preview`、Production=`rideintercom-turn-production`を分けて記載した。作成時はKey ID・API tokenを先に秘密管理先へ保存し、その後でWorkerへ登録する。

## 期限付き外部資格の自動生成（2026-11-21）

Apple認可取消用の署名済み`APPLE_CLIENT_SECRET`を手動登録・更新する構成を廃止した。Workerは必要に応じて、有効期間5分のclient-secret JWTを生成する。入力にはSign in with Apple専用の`.p8` secret・Key ID Variable・Team ID Variableと既存のClient IDを使う。有効中は同じisolate内で再利用し、残り1分から自動生成し直す。コード交換と取消の両方が同じ生成責務を通り、3項目のどれかが欠ける場合はAppleへ要求せず503にする。

Appleコード交換・取消の署名、issuer・subject・audience・Key ID・5分期限、isolate内再利用、設定不足のfail-closedを確認した。さらにテスト時計を301秒進め、期限切れのJWTを再利用せず新しいJWTでコード交換と取消を継続することを確認した。最新mainの追加試験を含むWorker全107件、TypeScript型検査、Wrangler dry-run、文書検査とその単体12件、diff checkが成功した。APNsのprovider JWTは既存実装が`.p8`から50分未満で自動更新し、TURN短期資格は既存実装が通話leaseに合わせてAPI発行・更新・失効することをコードと既存テストで再確認した。製品の安全性に必要な端末資格・招待・通話leaseの期限は変更していない。

実Appleのコード交換・取消、Cloudflare設定登録、Production／Preview配置はこの検証では行っていない。本番を止めない移行順は、新しい`.p8` secretとKey ID／Team ID Variableの先行登録、Worker配置、実Apple受入、旧secret削除の順とした。手順は[Cloudflare試用手順](../../development/Cloudflare試用手順.md#apple登録入口の保護)へ記録した。

## 共有mainから固定Previewを再作成する（2026-11-22）

固定 `preview` ブランチを削除し、Cloudflareの旧Previewが自動削除されたことを確認した。共有 `main` の `99e11103` を同名のブランチへpushし、自動ビルドと新規配置の成功を確認した。新しい配置にはPreviews BaseのSFU、TURN、端末証明、sandbox APNsのシークレットが入った。確認はbindingの型に限った。

固定PreviewでAppleによる端末登録・Internet通話・TURNを試すため、`previews.vars` の3項目を有効にする。受入には両端末で新しい資格を発行し、グループ招待、双方向音声、再接続後の音声を確認する。[固定Previewを作り直せる条件](../../development/Cloudflare試用手順.md#固定previewを作り直せる条件)

### 再作成したPreviewの通話検証はどこまで進んだか

手元のビルドと試験端末の設定を使わず、共有mainとCloudflareのPreviews Baseから試験先を構築した。`feb61376` の新しい配置で端末登録、通話、TURNの3項目が有効で、通知は無効だった。

| 確認箇所 | 観測結果 |
|---|---|
| 公開ヘルス | HTTP 200 |
| 資格なしでの通話状態取得 | HTTP 401 |
| 架空の端末によるApple登録の準備 | HTTP 200。期限付きチャレンジを発行 |
| 共有 `main` からの開発署名ビルド | `4c7b1145` を元にiPhoneとMac用をビルド。両機種で接続先は固定Preview。試験用の保存領域を分離し、資格の同梱は0件 |
| iPhone 12 miniへの導入 | 開発版Build 1992を導入。端末のロックにより起動を確認できなかった |

端末登録の管理領域と通話の管理領域は確認時点でいずれも0件だった。新規登録、双方向音声、TURN経由の通信、再接続は未確認。次は開発版を2台で起動し、Appleで登録してから試験用グループに参加する。試験後の片付けは[固定Previewの試用手順](../../development/Cloudflare試用手順.md#共有mainから固定previewと通話試験を用意する)に従う。

## 本番の配置元と配布候補の依存を照合する（2026-11-22）

当日の本番Workerの配置元 `1adc77da` と、当時の配布候補 `d4197073` の依存バージョンを、同日に取得したOSVのnpmとSwiftURLの公開データとローカルで照合した。[本番の配置元の確認](../../development/Cloudflare試用手順.md#稼働中の本番workerの配置元を照合する)・[OSVの公開データ](https://google.github.io/osv.dev/data/)

| 対象 | ロックファイルの項目と照合結果 | ローカルのWorker回帰試験 |
|---|---|---|
| 本番の配置元 | Workerの実行用7件は該当0件。ビルド・試験用121件のうち、Wranglerの間接依存 `undici 7.29.1` が重要度Highの4件、Moderateの4件に該当 | 116件合格 |
| 当時の配布候補 | Workerの実行用7件、ビルド・試験用120件、文書検査用312件、SwiftPM 1件は該当0件。Wranglerの間接依存は `undici 7.30.2` | 120件合格 |

両方ともNode.js 26.13.1で型検査とWranglerのdry-runが通過した。生成したWorkerのソースマップとインポート文を調べ、どちらにも `undici` の組み込みや参照はなかった。公開告知との照合は取得時点のデータを、組み込みの確認はローカルで生成したWorkerを対象とする。証跡は `.validation/security-audit-2100/dependencies/` に保存した。当時のCloudflareビルドで実際に使われたNode.jsと、同梱バイナリを含む依存の保守状況は、この検査の対象外だった。

固定Previewの配置元はこの検査の時点では確定できていなかった。同日の後続確認で、固定Previewも当時の本番と同じ `1adc77da` と照合できた。[固定Previewの配置元の確認](../../development/Cloudflare試用手順.md#固定previewの配置元をビルドとgitで照合する)

## 旧試用の静的資格を廃止する（2026-11-23）

通話APIから静的な `CLIENT_TOKENS_JSON` の照合を外した。開発用の設定例と旧発行手順向けのスクリプトも削除した。Workerの回帰試験では、旧設定に照合値を入れても旧資格はHTTP 401になり、通常の端末資格は受け付けた。

Node.js 26でWorkerの132件が成功した。macOSのRTCとローカルWorkerをつないだ試験では、異なるアカウントの端末資格で2人が参加し、通信・更新・再参加に成功した。Appleログインを省く固定Previewの音声試験は、必要なときだけ `TEST_PREVIEW_MEDIA_TRIAL` を使う。[実SFUで両方向の発話を確認した記録](iOS音声E2Eと通話障害修復.md#固定previewの実sfuで両方向の発話を確認する)

## Build 2440で接続待ちのままになる条件を調べる

2026-11-24。TestFlightのBuild 2440で通話先を選んだ後、接続待ちのまま進まないと依頼者から報告を受けた。Xcode標準保存先の同じ番号のArchiveを読み取り、AppのBuild番号と実行ファイルの本番接続先を照合した。`workers.ridecom.yowamushi-inc.com` が入り、固定Previewの既定URLは含まれていなかった。Archive内のarm64 WebRTC実行ファイルはBuild 2398と2440でMach-O UUIDが一致した。[Archiveの作成記録](配布ビルド採番とOrganizer認証調査.md#2520コミットの区切りでios-build-2440を標準保存先へ作る)

Cloudflareの読み取りでは、22:46 JSTの配置が本番の全トラフィックを受けていた。そのカスタムドメインは `ridecom` の本番に割り当てられていた。カスタムドメインと `workers.dev` の両方で `/health` は通話サービスのプロトコル1を返し、資格なしの `/api/status` は401となった。本番のApple登録・SFU・TURNは有効。参照するSFU AppとTURN keyはTOMLの指定と一致し、両方のリソースの存在を確認した。Appleログイン・端末署名・SFU・TURNに必要なシークレットが設定されていることも照合した。実際の資格で各APIが成功するかは未確認。

`npm --prefix server run test:pair` をNode.js 26.13.1とXcode同梱のSwiftで実行した。従来の試験は、ローカルのアカウントへ直接登録した資格を使い、TURNは無効だった。変更後は合成Apple認証の確認要求と交換から2人分の端末資格を発行し、TURN有効で同じSwiftの接続部を通した。各端末でICEの準備、入室、WebSocketの制御通信、期限の更新、再参加が通り、退出した端末の購読を回収した。Apple・TURN・SFUは代替サービスであり、本番への書き込みは行っていない。[再実行手順](../../development/自動検証.md#workerとappをつなぐ試験を選ぶ)

iOS 27.2 SimulatorのBuild 2453で、標準の `RideIntercomAudioE2E` スキームから[ミュート待機後の受話試験](../../development/音声E2Eテスト.md#ミュートで待機して後から参加した相手の声を受け取る)を実行した。ローカル中継で20秒待った後、後から参加した相手の発話は待機側で25/25フレームが一致し、ミュート解除後は両方向とも73/73フレームが一致した。Xcode標準の結果は1件成功、失敗とスキップは0件。次回用の共通採番は2454。比較に使った[固定Previewの実SFUとUDP TURNの試験](iOS音声E2Eと通話障害修復.md#固定previewの実sfuとudp-turnでミュート待機後の受話を確認する)も、同じ待機条件で両方向の発話が届いた。

本番の記録からBuild 2440の要求や失敗した処理は特定できなかった。次は本番で端末資格を使えるかを確認し、ICEの準備、入室、相手認証のどこまで進んだかを両端で照合する。双方向の音声は[復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)で受け入れる。

### Build 2440と2454のRTCで現行Workerに接続する

2026-11-25。Build 2440のArchiveの作成元 `e4a11683` と、Build 2454の `1e3c0973` で、RTCパッケージのGitツリーが一致した。Cloudflareで本番トラフィックの100%を受けていたWorkerの作成元は `355da99b` だった。そのWorkerとRTCパッケージを一時ディレクトリへ展開し、既存の `npm --prefix server run test:pair` を実行した。Apple認証、TURN、SFUにはローカルの代替応答を使った。

試験ランナーが別々の試験アカウントで端末資格を取得し、旧版と同じRTCのクライアント2台に渡した。両端のICE準備と入室、WebSocket経由の双方向の制御通信、期限をまたいだ接続の維持、片側の退出と再参加が通った。再参加時に古い購読を回収し、新しい購読へ切り替わったことも確認した。結合試験は1件が合格した。証跡は `.validation/testflight-2440-2454-current-worker/`。

この組み合わせで、登録済みの端末資格を使うRTCと現行Workerの結合は成立した。本番のApple認証、実際のSFU・TURNと音声再生、Build 2440が本番で最初に止まった段は未確認。本番で使える試験用の端末資格を送話側と受話側で確認し、両端の入室と再生を確かめる。[実機の準備状況](../実機確認待ち.md#最新の残件に対する準備状況)

## 通話APIが端末資格を拒否したときに再設定へ戻す

2026-11-25。Build 2440の接続待ちを切り分ける中で、通話用の端末資格がICE準備または参加要求でHTTP 401になっても、一時的な回線障害として再接続を繰り返す条件を特定した。代替応答を使ったSwift試験は、両方の段階で手動復帰を通知せず失敗した。修正後は、同じ資格での自動再試行を止めて、既存の通話画面から設定の「インターネット通話を設定」へ案内する。利用できる近距離経路は維持する。[RTCの失敗時の契約](../../spec/packages/RTC.md)・[通話画面の案内](../../spec/App/UI/Call.md)

Mac上で動く製品のSwiftクライアントからローカルWorkerへ通話の準備を送り、登録されていない資格への401で手動復帰の通知を確認した。同じクライアントを合成Apple認証で登録済みの資格で開始すると、2端末がTURN準備・参加・双方向の制御メッセージ・更新・再参加を完了した。Apple・TURN・SFUには試験用応答を使った。本番のApple認証、双方向音声とBuild 2440で最初に失敗した段は確認待ち。[Build 2440の切り分け](#build-2440で接続待ちのままになる条件を調べる)

HTTPと経路復旧のパッケージ試験30件、Macアプリの通話と操作の回帰20件が通った。次回用Buildは2472。証跡は `.validation/internet-http401-recovery-20261125/` と `.validation/internet-http401-app-20261125/` に保存した。

同日の追加試験では、ローカルWorkerで入室と送信用データチャネルの確保に成功した直後、WebSocketの接続だけにHTTP 401を返した。変更前は手動復帰を通知せず、試験の観測時間内にセッションも解放されなかった。変更後は、要求と同じURLに対する401で手動復帰を1回通知し、その試行のセッションを解放した。応答を取得できない失敗やほかの応答は、既存の再接続に進む。通常の入室、更新、離脱後の再参加もローカルWorkerで確認した。証跡は `.validation/internet-signal401-20261125/` に保存した。

MacのローカルTLS試験でも、試験プロセス内でだけ信頼した証明書でWebSocketの接続を試し、HTTP 401の応答URLが元の要求URLと一致することを確認した。ペア試験2件、RTC回帰20件、Worker回帰144件、Macアプリ回帰20件が合格。次回用Buildは2474。本番の双方向音声とBuild 2440での失敗箇所は確認待ち。

### 端末資格の拒否と同じアカウントの通話競合を区別する

2026-11-25。設定への案内が残ることを、ICE準備と入室のHTTP 401で再現した。RTCから通話画面まで端末資格の拒否を別の状態として渡すようにした。通話画面は端末を確認できなかったことを表示する。同じ資格の自動再試行を止め、利用できる近距離経路は続ける。同じアカウントでの通話の競合と一時的な回線障害は、従来の案内と処理を使う。[RTCの拒否通知](../../spec/packages/RTC.md#ユーザー操作を必要とする接続拒否)・[通話画面の案内](../../spec/App/UI/Call.md#混在通話機器切断の表示)

RTCパッケージの154件と標準WebRTCの7件が通った。RTCのアクセス修飾子のビルド警告を解消した後、関連する14件も通った。ローカルWorker回帰151件と結合2件では、HTTPとWebSocketの資格拒否、対象セッションの解放、登録済みの資格による入室と再参加を確認した。Apple、TURN、SFUは試験用の応答を使った。

XcodeのMacとiPhone Simulatorは最終の選択で各65件が通った。Mac初回はテストスイートの指定が2件不足し、正しい階層で再実行した。最終の試験は入力一致とSimulatorの停止も確認した。次回用Buildは2706。証跡はRTCが `.validation/20261125-213447-892169/`、Workerが `.validation/20261125-214027-957731/`、Macが `.validation/20261125-214141-781370/`、iPhone Simulatorが `.validation/20261125-214228-313673/`。拒否後の自動登録と同じ発信への復帰は残る。[ネット通話の復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)

### 新しい端末資格で同じ通話のインターネット経路を再開する

2026-11-25。RTCの通話セッションで端末資格の拒否を発生させた。拒否された資格と別のWorkerの資格を渡した場合は再接続しなかった。同じWorkerの新しい資格を渡すと、古い試行の後始末を終えてからインターネット経路だけを再開した。通話を終了した後は再開しなかった。インターネットだけの場合と近距離を併用する場合で確認した。通話の世代と音声の開始状態は引き継いだ。併用時は近距離経路を切り直さなかった。[RTC仕様](../../spec/packages/RTC.md#ユーザー操作を必要とする接続拒否)

最終のRTC回帰155件と標準WebRTCとの結合7件が通った。結果は `.validation/20261125-220152-140197/`。終了時の購読順を調整する前に、Macで既存の通話操作11件も通った。結果は `.validation/20261125-215904-444716/`。アプリが拒否を検知して資格を取り直し、同じ発信の経路に渡す処理は次の工程で確認する。

### 資格拒否後に同じ発信で再登録する

2026-11-25。保存した資格が拒否された後も、設定ストアから同じ資格を読み出せることをMacで再現した。インターネットだけを使う通話では、発信の世代も失われた。再現はXcodeの標準ビルドを使ったアカウント試験で行った。記録は `.validation/credential-rejection-app-baseline/`。

修正後は、同じ設定ストアを作り直しても拒否された資格を読み出せなかった。回線が戻ると、有効な本人確認を使う自動登録、通話画面からAppleで確認する登録のどちらも同じ発信で続いた。古い案内を消し、ミュートと接続済みの近距離の相手を保った。新しい資格でRTCにインターネット経路の再開を一度だけ依頼した。確認中に通話を終えると登録を始めなかった。登録要求の途中で通話を終えたときは、新しい資格を保存しても古い通話を再開しなかった。

MacとiPhone Simulatorで各81件に合格した。実行入力の一致とSimulatorの停止も確認した。Macは `.validation/20261125-221412-666359/`、iPhone Simulatorは `.validation/20261125-221521-081440/`。本人確認と資格発行の応答は試験で代替した。ローカル中継で資格拒否から双方向再生までを通す試験、実機のロック中、本番の確認は残る。[再登録の仕様](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

## 近距離をオフにして保存済みの相手を選び直す

2026-11-25。`scripts/validate.sh ios --only-testing RideIntercomTests/ContactBootstrapTests` を実行した。アプリの個人招待を受諾し、試験用の近距離経路で認証済みの返信を双方へ渡した。両端で近距離だけをオフにして保存一覧を読み直し、同じ相手を選んだ。試験用の端末資格を保存した場合は、同じ通話鍵でWebRTCだけを使う接続要求が出て、試験用の相手認証後に両端で音声送受信を開始した。資格を保存していない場合は、接続を始めずにインターネット通話の設定を案内した。Xcodeの結果は6件成功で、追加した試験は両条件とも合格した。証跡は `.validation/20261125-192759-114118/`。[経路設定の仕様](../../spec/App/UI/Settings.md#communication)

次のコマンドで、Simulator 2台のWebRTC音声を別に測った。

```sh
python3 scripts/audio_e2e.py --transport webrtc --matrix smoke --two-simulators --ephemeral --seconds 6
```

ローカル中継とネイティブWebRTCを使い、双方で相手の発話が実際の音声出力まで届いた。両方向とも発話の連続性は合格した。遅延の実測値は120.38 msと123.79 msだった。測定の余裕10 msを加えた判定値は130.38 msと133.79 msで、125 msの基準を超えた。試験用端末を回収し、入力・出力の設定を戻した。証跡は `.validation/audio-e2e-20261125-192243-412096/`。[音声の途切れと遅延](../../backlog/未実装課題.md#音声の途切れと遅延)

アプリ試験は通信を試験用の処理で置き換えている。音声試験はグループ招待から接続している。保存済みの相手を選んでから音声が再生されるまでの連続した結果と、実際の端末資格・本番中継で最初に止まる段は未確認。[ネット通話の復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)

### 近距離をオフにして選んだ相手と双方向で話す

2026-11-25。試験用の端末資格と個別通話の相手を保存したiPhone Simulator 2台で測った。近距離だけをオフにし、両端で保存済みの相手を選んで同じ個別通話に参加した。両端でWebRTCだけが有効になり、相手を認証して発話が実出力まで届いた。音声は両方向とも既定のAAC-ELDだった。[再実行手順](../../development/音声E2Eテスト.md#近距離をオフにして保存済みの相手と話す)

最初の試行では発話の欠けは両端とも0 msだった。実測遅延は121.29 msと126.87 msだった。測定の余裕10 msを加えた判定値は131.29 msと136.87 msで、双方とも125 msの基準を超えた。証跡は `.validation/audio-e2e-20261125-193634-133559/` に保存した。

試験用データの準備を別ファイルに分けた後、同じ条件で再試験した。両端で発話は届いた。復号時に発話の欠けはなく、ミックス後に最大20 ms、実出力では一方が最大30 ms、もう一方が20 ms欠けた。連続性の基準を満たさず、遅延の判定値は得られなかった。両試行で試験用Simulatorの回収と入出力の復元を確認した。証跡は `.validation/audio-e2e-20261125-193916-991350/` に保存した。[音声の途切れと遅延](../../backlog/未実装課題.md#音声の途切れと遅延)

試験用の資格は接続前に保存している。通常のサインインに伴う端末登録、回線が戻った後の続行、本番の中継は未確認のため、[ネット通話の復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)で追う。

## 本番のApple登録入口とMacの署名を確かめる

2026-11-24。合成の端末UUIDで、本番のApple登録に必要な確認要求を1回実行した。HTTP 200を受け、端末UUID、確認要求とnonceの形式、5分の有効期限がAppの期待と一致した。有効期限後に確認要求を削除する処理をコードで照合した。実際のApple認証・端末資格の発行・通話の入室は未確認。

通常のMac Release Build 2459を標準構成でビルドした。本番Workerの接続先、通常の保存先、署名とプロファイルのApple認証権限を確認した。iPhoneのBuild 2440と2454のArchiveでは通常の保存先、署名のアプリ識別子とKeychainの利用範囲が一致した。iPhone 12 miniでは既存のTestFlight Build 2440の起動を照会できた。上書きやログイン操作は未実施。[実機の準備](../../development/自動検証.md#ios実機の準備とロック中の検証を分ける)

MacとiPhone Simulatorのローカル中継ではWebRTCで双方の発話が届いた。遅延は両方向とも125 msの基準を超えた。[両端の音声と遅延の測定](複数端末の経路断と自動復旧.md#近距離とwebrtcの全音声設定で両端の発話を測る)

### 通常サインインの証明を回線復旧後の端末登録に使う

2026-11-25。試験用のApple署名で、回線を使う前に取得済みの本人確認を再現した。端末を登録するための確認要求はその後に発行した。変更前のWorkerは登録を拒否した。変更後は、元の署名鍵を保持する端末からの要求で資格を発行し、その資格で状態照会が通った。[端末登録の契約](../../spec/server/Worker.md#通常のappleサインインの証明で端末を登録する)

別の鍵で署名した要求と、確認要求が異なる署名は拒否した。同じ要求を同時に送っても発行は1回だった。成功応答を失った場合に備え、同じAppleの証明と新しい確認要求で同じ端末を登録できることも確かめた。古い資格は置き換わった。アカウントの削除後には、同じ本人確認の証明を使った再登録を拒否した。

`server`で型検査と`npm test`を実行し、Worker 2本のドライランと151件の回帰が通った。応答を失った場合と異なる署名鍵の検査を追加した後に、対象の試験1件も再実行して通った。Appleは試験用の署名で代用した。通常サインイン画面からの呼び出し、回線状態や利用者の設定に応じた送信・保留、実Appleの認証と本番での通話は未確認。[ネット通話の復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)

#### アプリが通常サインインの本人確認で端末を登録する

2026-11-25。通常サインインの準備と完了に試験用のAppleの本人確認を渡し、アプリのネットワーク経路の変更から端末登録まで実行した。送った署名をアプリ試験でも検証した。設定がオフの間と回線がない間は送信せず、有効にした後の回線復旧で資格を保存した。登録中に設定をオフにすると、後続の端末証明の要求は送らなかった。

サーバーが一時的に応答できず、回線も切れた後に近距離通話を始めた。回線が戻っても通話を維持し、終了後に同じ本人確認から登録を済ませた。MacのXcode試験44件は成功した。初回の入力検査では並行したバックログの文書更新を検出したが、実行中のコード・設定差分はXcodeの共通採番だけだった。Macの再試験で入力一致も確認した。証跡は `.validation/20261125-200653-089046/` に保存した。[端末登録の仕様](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

iPhone Simulatorでも同じ44件が通り、実行前後の入力が一致し、試験用端末を停止した。証跡は `.validation/20261125-200440-057063/` に保存した。文書検査で見つかった助詞の重なりは、両環境の試験後に直した。実Appleの認証、アプリの再起動をまたいだ自動登録、本番の通話は未確認である。

#### 開始済みの端末登録をiPhoneのロック後も続ける

2026-11-26。通常サインインから端末登録が始まる時点で、iOSに実行時間の延長を求めるようにした。端末登録の試験では延長の開始・終了を模擬した。変更前は延長の要求がなく、新規試験の2ケースが失敗した。変更後は登録成功時に延長が終わった。iOSから終了を求められたケースでは延長がすぐに終わった。この時点では端末資格の保存はなかった。同じ回線状態の通知では再試行しなかった。回線の復旧とアプリの前面復帰では、それぞれ新しい試行で資格を保存した。

共有の `RideIntercom` schemeでMacとiPhone Simulatorのアカウント・前面復帰の試験が各46件通った。ロック直後に端末資格を保存できるか、長時間ロック中にいつ処理を再開できるかは実機での確認が残る。[端末登録の仕様](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

#### 回線が戻るまで通話先とマイクの状態を保持する

2026-11-25。インターネットだけをオンにし、試験用の本人確認を保持した状態で通話先を選んだ。回線がない間も接続待ちになり、マイクをオフにできた。回線が戻って登録を済ませると、同じ相手への接続が一度だけ始まった。通話の識別とマイクの状態は変わらず、登録前の通信経路と音声送信は開始しなかった。

終了、サインアウト、発信許可の取消では古い通話を再開しなかった。別の通話先を選んだ場合は、後から選んだ通話先だけに接続した。登録を拒否された場合は、開発者向け設定への案内を出さず、安全に終了した。

MacとiPhone SimulatorのXcode試験で、端末登録、通話操作、マイク許可の各46件と入力の一致を確認した。証跡はMacが `.validation/20261125-202050-767821/`、iPhone Simulatorが `.validation/20261125-202131-659723/`。試験用Simulatorは停止した。先行のMac試験では、OSがBonjour探索を拒否し、実探索を使う既存の個人招待試験は不合格だった。証跡は `.validation/20261125-201617-484380/`。この通話待機の試験は代替通信先を使った。両経路を既定のままオンにした状態と、実Apple認証、実機のロック中、本番通話は別に確かめる。[通話の仕様](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

#### 両経路がオンの通話に端末登録の結果を渡す

2026-11-25。既定どおり近距離とインターネットをオンにして、回線が使えない間に通話先を選んだ。近距離の相手を待つ場合と、認証済みの近距離の相手がいる場合を試した。回線が戻ると登録が自動で進み、同じ通話のインターネット経路に資格を渡した。どちらも通話の識別、マイクOFF、近距離側の接続と音声処理の状態を保った。RTCアダプターの試験では、現在のセッションが次の接続試行で使う資格を読めることと、音声パケットを引き続き渡せることを確認した。

MacとiPhone Simulatorで、端末登録、RTCアダプター、通話操作、マイク許可、設定、個人招待の各89件が通った。実行前後の入力が一致し、試験用Simulatorは停止した。証跡はMacが `.validation/20261125-203601-253655/`、iPhone Simulatorが `.validation/20261125-203630-031073/`。試験ではAppleの本人確認、登録先、RTCの下位接続を代替した。同じ条件でのWebRTCの接続と再生、実Apple認証、本番の通話、実機のロック中の動作は未確認。[通話の仕様](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

#### 音声E2Eでも新しい資格の参照を使う

2026-11-25。アプリのRTCアダプターがセッション内で資格を参照するようになり、音声E2Eの専用ターゲットにも同じ参照を渡した。iPhone Simulator 2台向けに標準Xcode設定でビルドし、保存済みの相手を選んで両端がWebRTCだけで認証した。AAC-ELDで、双方の発話が音声出力まで届いた。両端の有声欠落は4.23%と2.64%で、最大欠落は110 msと120 msだった。音声品質の受入は不合格。証跡は `.validation/audio-e2e-20261125-204209-533627/`。実行前後でソースは一致し、専用Simulator 2台を片付けた。[試験の入口](../../development/音声E2Eテスト.md#近距離をオフにして保存済みの相手と話す)

Macの共有音声E2Eスキームでは、音声機器を使わないWebRTCの発話往復1件が成功した。開始時のインターネット通話の案内は、実装と同じ文面および条件に仕様・デザインのMarkdown・HTMLをそろえた。[通話の案内](../../spec/App/UI/Call.md#混在通話機器切断の表示)

#### 両経路がオンの通話で登録後の発話を双方向で再生する

2026-11-25。iPhone Simulator 2台で、端末資格なしで保存済みの相手を一度ずつ選んだ。近距離で相手を認証し、双方のPCM16の発話が再生された。端末登録の成功結果を代替して資格を保存した後は、通話の識別と切断期限を保ったままWebRTCが加わった。

近距離の音声だけを止めた区間では、両端とも近距離の音声データの受信は0で、WebRTC経由でそれぞれ604件と609件の音声パケットを受信した。相手の発話は両端で再生され、近距離のQUIC制御も続いた。音声の遮断を解除した後は、両端で近距離の受信が戻った。通話先の選び直しは行わなかった。

Xcode試験は両端で各1件が成功した。音声試験ランナーの44件も通った。本試験の入力一致と専用Simulator 2台の回収も確認した。証跡は `.validation/audio-e2e-20261125-205005-566454/` に保存した。登録応答は代替した。実際の回線断からの登録、実Apple認証、端末ロック中、本番の通話は未確認。[試験の再実行手順](../../development/音声E2Eテスト.md#近距離で始めた通話に登録後のインターネット経路を加える)

#### 既存ログインの本人確認後に同じ通話を続ける

2026-11-25。保存したログインに端末資格と有効な本人確認がない状態で、通話鍵を持つ相手を選んだ。近距離を使う場合は接続を保った。Appleの応答を試験で代替し、確認中に切れた回線が戻ると、同じ通話の登録と接続を自動で続けた。通話先、マイクOFF、既存の近距離接続を引き継いだ。

通話の終了、インターネットの無効化、サインアウト後に届いた応答では登録や接続が始まらなかった。別のAppleアカウントの応答と、要求に対応しない応答も使わなかった。発行要求に結び付けた鍵の署名を確認した。保存したログインは同じアカウントのままだった。

MacとiPhone Simulatorで各78件のXcode試験が通った。証跡はMacが `.validation/20261125-210738-674592/`、iPhone Simulatorが `.validation/20261125-211004-844308/`。通話の実装に変更を加えず、文書検査で指摘された文を直した。Simulatorでは修正後の入力一致と試験端末の停止も確認した。実際のApple認証画面、実機ロック中と本番の通話は未確認。[本人確認の条件](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

#### 端末登録後にアカウント宛ての個人通話を始める

2026-11-25。自分の端末資格がなく、通話先をまだ解決できない保存済みの相手を一覧で選んだ。圏外では登録や接続を始めず、選択した相手を保持した。回線が戻ると、有効な本人確認がある場合は自動登録し、ない場合は通話からの確認を待った。登録後は同じ相手への接続要求を一度だけ出した。本人確認の応答には試験用の値を使った。

準備中や登録中に閉じた場合、別の相手へ切り替えた場合、相手を削除した場合は、元の相手への発信が始まらなかった。Macで最初に失敗した試験では、登録直後に登録処理自身が取り消され、発信に進まなかった。通話がまだない段階では準備のタイマーだけを終了するよう直し、再試験で発信まで確かめた。

最終のMacとiPhone Simulatorで各96件が通った。Macは `.validation/20261125-212241-369312/`、iPhone Simulatorは `.validation/20261125-212617-916086/` に証跡を保存した。iPhone Simulatorの初回は96件が通ったが、試験中にバックログ2文書が更新されたため入力一致の検査は不合格だった。再試験は入力一致と試験端末の停止も確認した。実際のApple認証画面、実機ロック中と本番の通話は未確認。[端末登録の条件](../../spec/App/通信仕様.md#通常サインインからインターネット通話の端末を登録する)

## Macの本番通話の準備とローカルでの受話を照合する

2026-11-25。Xcodeの共有スキームでMac Release Build 2486をビルドし、署名、Apple認証の権限、通常の保存先、本番の接続先を照合した。本番のカスタムドメインとWorkersの既定ドメインはどちらも `/health` がHTTP 200、資格なしの `/api/status` が401だった。本番Workerが参照するSFUとTURNの識別子は現行の資源と一致し、両方のシークレット名の登録を確認した。Macの既存ログインと端末資格は未確認。必要な許可を確認し、通常のアプリの診断から資格付きの状態を照会する。続けて入室、ICE、相手認証、音声を確かめる。

MacとiPhone Simulatorで、WebRTCのローカル試験用中継を通し、合成の日本語発話を6秒ずつ双方向に送った。初回は双方に届いたが、Macの受話に10 msの有声欠落があり不合格だった。対応区間の復号音声は連続しており、欠落はミックス出力で初めて観測した。同じ条件での再試験は両方向とも欠落0で、計測余裕込みの遅延はMac受話113.29 ms、Simulator受話122.65 msだった。再試験でもソースの一致と試験後の片付けを確認した。欠落は再試験で再現しなかった。本番経路での接続と音声は未確認。実行結果は `.validation/production-mac-sender-20261125/` に保存した。

iPhone 12 mini向けには既存TestFlight版を対象とするランナーの署名と、招待から通話を開始してマイクをOFFにする試験の選択を照合した。端末への導入と起動は行っていない。Macの本番資格を確認し、今回の招待と送話側を用意してから実機試験に進む。[実機試験の準備状況](../実機確認待ち.md#最新の残件に対する準備状況)

## 通話開始時にインターネット通話の設定を案内する

2026-11-25。保存したグループを一覧から選ぶMacの回帰で、端末資格がない状態を再現した。修正前は、インターネットだけを有効にしても通話の開始を受理していた。両経路を有効にすると近距離で待機できたが、インターネット通話に必要な設定は表示されなかった。

修正後は、インターネットだけの場合、端末資格がなければ設定を案内し、読み取れなければRideComを開き直すよう案内する。どちらも未接続のままで、保存済みの設定は保持する。近距離も有効な場合は近距離で開始し、OSがネットワーク経路を利用可能と報告した間だけ案内する。圏外の待機、回線が戻ったときの表示、近距離だけを選んだ通話、端末資格を用意した通話を同じ入口で確かめた。[開始時の判定](../../spec/App/通信仕様.md#通話先と操作対象の共通境界)・[画面での案内](../../spec/App/UI/Call.md#混在通話機器切断の表示)

最終の回帰はMacで104件、iPhone Simulatorで4件が合格した。既存の音声試験は合成の端末資格を用意し、両経路の音量・音声処理の期待値を維持した。Macで先に広げた回帰では、別の近距離招待2件に既知のBonjourの `NoAuth(-65555)` が出た。最終の選択では、その実通信2件と今回の通話開始の回帰を分けた。試験の入力を照合し、試験用Simulatorの停止を確認した。次回用Buildは2499。結果は `.validation/20261125-023041-753815/`、`.validation/20261125-024300-850350/`、`.validation/20261125-024332-633933/` に保存した。[MacのBonjourの確認範囲](../未確認事項.md#macの近距離quic探索とapp音声e2e)

この修正で確認したのは端末資格が使えない場合の画面と通話開始の判断。本番でBuild 2440が止まった段と、実際の双方向通話は確認を続ける。[本番の復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)

## インターネット通話の運用停止を診断で見分ける

2026-11-25。設定で通話を停止したローカルWorkerを、合成の登録済み端末資格で試した。修正前は停止を示す識別子を返さず、Swiftクライアントも接続準備・入室の停止応答を一般のHTTP 503と区別できなかった。

修正後は状態照会・接続準備・入室が同じ停止の識別子を返した。診断では停止中であることを固定文言で伝え、資格の再設定を求めない。通話側では、停止を含むHTTP 503に対して従来の間隔で再試行する。停止が一度だけ返った更新では、期限内に同じ通話を更新できた。停止に伴う通話や接続準備の回収境界もWorkerの回帰で確認した。[Workerの停止条件](../../spec/server/Worker.md#継続と後始末)・[診断の仕様](../../spec/App/UI/Diagnostics.md#診断と適用状態の区別)

Workerのローカル回帰144件、RTCの選択13件、WorkerとSwiftをつないだ通話試験2件、Macの設定回帰24件が合格した。SwiftLintとWorkerの型検査も通った。結果は `.validation/call-service-paused-20261125/` と `.validation/20261125-025538-777351/` に保存した。次回用Buildは2501。稼働中のサービスの停止や再開は試しておらず、Build 2440の原因の確定には使わない。[Wranglerのローカル生成](https://developers.cloudflare.com/workers/wrangler/bundling/)

## 通話の調査に使う本番と固定Previewの配置元を確かめる

2026-11-25。Cloudflareの読取APIで、本番の全トラフィックを処理するバージョンと、対応するWorkers Buildsの成功結果を照合した。配置は03時12分（JST）、ソースは共有 `main` の `fa5da1bf`、ビルドのルートは `server`。同じソースに通話の運用停止を診断で見分ける修正 `df4d964c` が含まれる。固定Previewは03時13分（JST）の最新配置のタグと `preview` の最新成功ビルドで同じコミットを確認し、互換日付は `2026-11-17` だった。[バージョンとビルドの照会](https://developers.cloudflare.com/api/resources/workers_builds/methods/get_builds_by_version/)

本番の実行設定ではApple登録、通話、TURNが有効で、Apple登録のクライアント識別子は通常版のバンドルIDと一致した。通話要求に使う制限とSQLiteの接続先、SFU・TURNのシークレット名が存在し、固定Preview限定の試験資格設定は本番に存在しなかった。照合は配置と設定の読み取りまで。登録済みの資格を使う入室と音声の送受信は[本番の復旧課題](../../backlog/未実装課題.md#公開済みtestflightで使えないネット通話を復旧する)で追う。

## アプリが中断したあとのTURN接続準備をやり直す

2026-11-25。ローカルWorkerでTURN資格の取得直後に止まったクライアントを再現した。入室と取消の要求は届いていない。同じ端末が同じグループに新しい試行IDで参加しようとすると、修正前はHTTP 409を返した。

修正後は同じ利用枠を保ち、以前の資格を失効させてから新しい資格を返した。新しいIDでの入室と終了が成功し、古いIDによる入室と取消を拒否した。別端末から同じ参加者として送った準備と、すでに通話中の参加者に対する別の試行も拒否した。失効に失敗する代替応答では、HTTP 502を返し、新しい資格を発行せず、提供元が復旧した後の再試行で発行と回収に成功した。[WorkerのTURN接続準備](../../spec/server/Worker.md#turn資格の契約)

Node.js 26.13.1のWorker回帰146件、MacのSwiftクライアントとローカルWorkerをつないだ結合試験2件、型検査が成功した。結果は `.validation/turn-preflight-retry-20261125/` に保存した。実際の提供元は呼び出しておらず、Build 2440の接続待ちで残っていた資格や、本番での発話は未確認。

再作成した固定Previewでも片側の古い接続準備を残し、同じ側の入室と後参加、実TURN・SFU経由の双方向受信、終了後の回収を確認した。[実サービスでの測定](iOS音声E2Eと通話障害修復.md#固定previewで中断後のturn再試行と後参加の発話を測る)

## ICE準備と入室の失敗をNetworkの診断で見分ける

2026-11-25。端末資格があるSwiftクライアントに、ICE準備と入室で同じHTTP 503を返した。修正前は理由が同じ文になり、NetworkのInternetカードにはViewModelに届いた失敗理由を表示する行がなかった。

修正後は一般のHTTP失敗で「ICEの準備 · HTTP 503」「通話への入室 · HTTP 503」のように処理名とHTTPコードを示す。認証拒否と既存通話の競合は従来の手動復帰案内、運用停止は従来の停止案内を使う。失敗の詳細は、AdvancedのNetworkでInternetカードの先頭に表示する。Local経路が利用できる場合は音声と計測を保つ。経路復帰や次の通話で古い理由は消える。[RTCの失敗通知](../../spec/packages/RTC.md#ユーザー操作を必要とする接続拒否)・[Networkの表示仕様](../../spec/App/UI/Diagnostics.md#network診断)

通常文字と最大文字の描画を見比べ、HTTP失敗の値を処理名とコードに絞った。幅320 ptの最大文字でも理由が複数行で読め、警告を色と記号だけに頼らず示せることを確認した。計測値が残る場合も、失敗の行で経路の測定結果を書き換えない。[画面見本](../../design/詳細画面/詳細画面見本.html)・[Apple HIGのアクセシビリティ](https://developer.apple.com/design/human-interface-guidelines/accessibility)

RTCの回帰11件、Macの通話状態10件、Simulatorの診断表示8件が成功した。文言を短くした後のSimulator描画1件も成功した。最初のSimulator試行は個別の試験名に括弧を付けず、0件で停止した。スイートを指定してやり直し、最終の個別指定では括弧を含めた。証跡は `.validation/20261125-040426-089707/`、`.validation/20261125-040506-933325/`、`.validation/20261125-040710-225492/`。次回用Buildは2511。本番でBuild 2440が止まった処理と、認証済みの双方向通話は未確認。

## 通知の停止と鍵の不備で保存済み招待の配信を保留する

2026-11-23。保存済みの合成招待があるローカルWorkerで、APNsの署名鍵を読み込めない状態でも受信箱がHTTP 200で暗号文を返すことを再現した。修正後は、通知停止、鍵の未設定、鍵の形式不正のどの場合も、通知先の登録、呼出し、招待の送信・取得・追加端末への照会と未受領の確定はHTTP 503だった。代替APNsへの要求は増えず、再開後にも停止中に拒否した新規送信の記録はなかった。

停止中も確認済みの受領結果を取得でき、未受領の招待を破棄できた。設定を戻すと、期限内の招待を同じ送信IDで受領でき、通知の再送はなかった。試験は合成データ、ローカルのSQLite、代替APNsを使用した。[Workerの停止条件](../../spec/server/通知.md#登録済みの相手への暗号化したグループ招待の送受信)

同日、通知許可証の鍵についても、鍵が空、JSONとして不正、署名鍵として読み込めない場合を確認した。修正前は不正な鍵でも受信箱の取得がHTTP 200だった。修正後は各条件で503を返し、代替APNsへの送信は増えなかった。端末Bearerによる取消・破棄・確定済み結果の確認はできた。正しい鍵に戻すと、保留していた期限内の招待を同じ送信IDで受領できた。

## 本番の配置元とMacの通話試験用ビルドを揃える

2026-11-25。14時29分（JST）に本番トラフィックの100%を受ける配置を、稼働バージョンに対応するWorkers Buildsの成功結果1件と照合した。配置元は共有main `a026dc7d`、ビルドルートは `server`。前回の配置確認以降のサーバー差分には、通知先の管理とTURN接続準備の変更が含まれる。

本番のカスタムドメインでヘルスはHTTP 200、端末資格なしの状態照会は401だった。管理APIで通話・Apple登録・TURN・呼び出し通知が有効で、通知の環境は本番APNsだった。通知の索引と宛先の識別子、APNs・端末証明・SFU・TURN用のシークレット名の登録を照合した。

同じソースからXcodeの共有スキームでMac Release 1.0.0（Build 2646）を作った。標準出力にあるAppを署名記録から特定し、署名、通常の保存先、本番Workerの接続先、Apple認証の権限を確認した。証跡は `.validation/production-readiness-2646/`。Macのアプリ起動と認証は未実施。試験用アカウントの端末資格を確認できたら、通常版のAdvancedから「Check Internet Service」で状態照会し、入室、ICE、相手認証、双方向再生へ進む。APNsの受付と端末への通知到達は実際の呼び出しで確かめる。次回用Buildは2647。[本番通話と通知の着手順](../../backlog/README.md#着手順)

### Mac通常版の起動と保存済みサインインの有無を確かめる

2026-11-25。標準出力にあるMac Release Build 2646の署名を再検証し、通常の保存先で起動した。起動した実行ファイルは標準出力のRelease版に一致した。既定のKeychainで確認したのは、RideComのAppleサインイン項目があることまで。項目の値は取得していない。

デスクトップ操作権限がなく、アプリ内で試験用アカウントの本人確認と本番Workerへの状態照会を行えなかった。macOSに保存されているサインインが有効か、iPhoneとは異なる試験用アカウントか、Workerの端末資格が使えるかは未確認。

実機試験の準備を再開するときは、まず相手側Macの試験用アカウントを照合する。そのアカウントで通常版のAdvancedから「Check Internet Service」を実行し、Workerが端末からの状態照会を受理することを確認する。試験用の招待を発行し、待機する送話側と計測・回収手段を揃えてから、iPhoneで必要な起動を判断する。[実機試験の準備状況](../実機確認待ち.md#最新の残件に対する準備状況)

## 専用SimulatorでAPNs Sandboxの端末トークンを受け取る

2026-11-25。Appleシリコン搭載MacのiOS 27.2 Simulatorを試験専用に作成した。Xcodeの共有 `RideIntercom` スキームと通常のDebug構成でBuild 2670を生成した。生成時の権限情報で、Simulator用の `aps-environment` が `development` であることを照合した。[SimulatorのAPNs対応](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)

Appleアカウントを登録していない状態でアプリを起動し、XcodeのデバッガからUIKitの `registerForRemoteNotifications()` を呼んだ。成功と失敗のコールバックに停止位置を設け、成功側の `didRegisterForRemoteNotificationsWithDeviceToken` に到達した。観測は到達した処理の名前までとし、トークンの値を読み出していない。試験先のSimulatorは削除し、一覧から消えたことを確かめた。手元の証跡は `.validation/apns-sandbox-probe.ghvIEs/`、次回用Buildは2671。

通常のサインイン後にアプリが登録を始める経路と、Workerへの通知先登録は今回の対象外。固定Previewで実際の呼び出しを試すには、Sandbox専用の宛先と送信元を用意し、APNsの受付、相手への到着、「接続」で開く通話、片付けまでを確認する。開発署名の実機とTestFlightの本番通知は個別に検証する。[通知の受入条件](../../backlog/未実装課題.md#サンドボックスと本番で呼び出し通知を届ける)

## Sandboxの自動トレース中は通知送信を止める

2026-11-25。Cloudflareが外向き `fetch` のURLパスを自動トレースに含めることと、APNsのURLパスに端末トークンが入ることを照合した。固定Previewの `redact_query_string` はクエリ文字列に限る。[Cloudflareの記録項目](https://developers.cloudflare.com/observability/traces/spans-and-attributes/)・[Appleの送信要求](https://developer.apple.com/documentation/UserNotifications/sending-notification-requests-to-apns)

手元のWorkerで2件の合成アカウントを登録し、宛先と呼び出し許可を作った。同じ保存状態で自動トレースを有効にして再起動すると、修正前は代替APNsへ1回送った。修正後は通知先の登録と呼び出しがHTTP 503になり、代替APNsへの送信は0回、通知先の解除は成功した。Node.js 26で型検査とWorker試験147件が通過した。実APNsには送信していない。

本番と固定Previewの監視設定は維持する。実配信を試す前に、送信URLのトークンをトレースへ記録しないSandboxの経路を用意する。

## 固定PreviewのトレースとSandbox送信を分ける

2026-11-25。Workerd 2026-11-19で、呼び出し元にだけトレースを設定し、サービスバインディング経由の送信側がトレース無効となることを確認した。送信側もトレース有効にすると、合成の送信要求は0件だった。続けてWorker Loaderを使い、同一配置のDynamic Workerでも呼び出し元が有効、送信側が無効になることをMiniflareで確認した。

通常の通知APIで、合成の2アカウントの宛先登録、通知許可、呼び出しを試した。変更前はトレース有効時の登録がHTTP 503。変更後は試験用バインディングを使い、同じ呼び出しを2回送っても代替APNsに1件だけ届いた。通知先の解除も成功した。バインディングなしの停止試験、Workerの型検査と全148件が通過した。

手順のバインディング設定を既存TOMLへ一時的に足してWranglerで読み、本番の設定には含まれないことを確認した。共有の固定Previewには追加していない。Dynamic Workersの契約は読み取り権限で確認できなかった。稼働環境でのトレースの照合、実APNsの受付、端末への到着と「接続」は未確認。[実配信の手順](../../development/Cloudflare試用手順.md#固定previewを作り直せる条件)

## 合成の宛先で固定PreviewのSandbox試験を予行する

2026-11-25。固定PreviewのSandboxへ1回だけ送る試験をローカルで実行した。本番のURL、別の試験資格、設定と異なる宛先、通常の通知API、設定期限後の要求を拒否した。同じ試験資格と宛先で同時に2回送ると、代替APNsへの送信は1件。試験の応答で代替APNsのHTTPステータスと呼び出し元のトレースIDを受け取った。通常通知は無効の構成を使った。

Workerの型検査と149件の試験が成功した。準備コマンドが生成する作業ファイルは所有者だけが読み書きでき、配置用設定には資格と宛先の照合値だけが入ることを確かめた。作業ファイルはローカルで回収した。稼働する固定Previewへの試験設定の投入、実APNsからの応答、端末での通知と「接続」は未確認。[試験手順](../../development/Cloudflare試用手順.md#appleログインなしで固定previewからsandbox-apnsまでを試す)

## 配置でDynamic Workersの利用条件を確認して試験設定を取り下げる

2026-11-25。架空宛先1件の試験設定を共有main `98cc6dbc` に反映した。旧固定Previewの削除を確認し、同じ名前で作り直した。新しい固定Previewで、このコミットのビルドはCloudflareのエラー `10195` で配置に失敗した。ビルドの記録にはDynamic Workersを使うために有料プランが必要とあった。管理APIの利用モデル `standard` から、この機能の利用可否は判定できなかった。[Dynamic Workersの利用条件](https://developers.cloudflare.com/dynamic-workers/pricing/)

試験用の配置ができる前に止めた。APNsへの要求は0件で、端末の通知と「接続」は未確認。今回追加したバインディングと試験設定を取り下げ、通常構成へ復旧する。トレース100%の固定Previewから試すには、現在の契約で使えるトレースの分離方法を先に確かめる。[残る作業](../../backlog/未実装課題.md#サンドボックスと本番で呼び出し通知を届ける)

復旧の共有main `3fda39b5` に対応する新しい固定Previewの配置 `df636300` を読み戻した。通常通知は無効、トレースは100%で、試験用のWorker Loaderはなかった。ヘルスはHTTP 200。有効期限内の同じ試験資格を疎通試験に使うとHTTP 404になった。ローカルに作った資格と宛先のファイルは回収済み。証跡は `.validation/apns-sandbox-preview-live-20261125/summary.json`。

## 非公開の標準WorkerでSandboxの送信を予行する

2026-11-25。現在のCloudflare契約ではDynamic Workersを使えない。送信処理を、公開URLや保存先を持たないSandbox専用Workerへ移した。固定Previewの候補はサービスバインディングで専用の入口を呼び、固定の内部URLを使う。送信側はトレースが有効か状態を確認できないときに拒否する。

Miniflareで呼び出し元と送信側のトレースを個別に設定した。呼び出し元だけをトレースした場合、同じ通知要求を2回送っても代替APNsへの送信は1件だった。並行する疎通試験も送信は1件だった。送信側もトレースした場合は0件。送信専用Workerの既定の入口へ直接送ると404を返し、代替APNsへの送信は0件だった。

両Workerのドライランと型検査、Workerの自動試験150件が通過した。運用中の固定Previewの設定は変更していない。専用Workerの実配置、実APNsの応答、Cloudflareのトレースへの残留、端末への到着は未確認。[専用Workerの配置と回収の手順](../../development/Cloudflare試用手順.md#appleログインなしで固定previewからsandbox-apnsまでを試す)

### 専用Workerを作成できる権限を確かめる

2026-11-25。依頼者の許可を得て、既存の無料契約でSandbox専用の非公開Workerを1つ作成しようとした。対象の同名Workerがないことを管理APIで照合してから、公開URL、ログ、トレースを無効にした新規作成を要求した。CloudflareはHTTP 403を返した。

読み戻しでも専用Workerはなかった。ローカルのWranglerは未認証で、GitHub Actionsで使える配置資格も確認できなかった。固定Previewの試験設定の追加、試験用資格の生成、APNsへの要求は行っていない。再開には対象アカウントでWorkerの作成・削除に使えるCloudflare認証が必要。[配置と回収の手順](../../development/Cloudflare試用手順.md#sandbox送信専用workerの配置と回収)
