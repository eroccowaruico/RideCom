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

## 本番のApple登録入口とMacの署名を確かめる

2026-11-24。合成の端末UUIDで、本番のApple登録に必要な確認要求を1回実行した。HTTP 200を受け、端末UUID、確認要求とnonceの形式、5分の有効期限がAppの期待と一致した。有効期限後に確認要求を削除する処理をコードで照合した。実際のApple認証・端末資格の発行・通話の入室は未確認。

通常のMac Release Build 2459を標準構成でビルドした。本番Workerの接続先、通常の保存先、署名とプロファイルのApple認証権限を確認した。iPhoneのBuild 2440と2454のArchiveでは通常の保存先、署名のアプリ識別子とKeychainの利用範囲が一致した。iPhone 12 miniでは既存のTestFlight Build 2440の起動を照会できた。上書きやログイン操作は未実施。[実機の準備](../../development/自動検証.md#ios実機の準備とロック中の検証を分ける)

MacとiPhone Simulatorのローカル中継ではWebRTCで双方の発話が届いた。遅延は両方向とも125 msの基準を超えた。[両端の音声と遅延の測定](複数端末の経路断と自動復旧.md#近距離とwebrtcの全音声設定で両端の発話を測る)

## 通知の停止と鍵の不備で保存済み招待の配信を保留する

2026-11-23。保存済みの合成招待があるローカルWorkerで、APNsの署名鍵を読み込めない状態でも受信箱がHTTP 200で暗号文を返すことを再現した。修正後は、通知停止、鍵の未設定、鍵の形式不正のどの場合も、通知先の登録、呼出し、招待の送信・取得・追加端末への照会と未受領の確定はHTTP 503だった。代替APNsへの要求は増えず、再開後にも停止中に拒否した新規送信の記録はなかった。

停止中も確認済みの受領結果を取得でき、未受領の招待を破棄できた。設定を戻すと、期限内の招待を同じ送信IDで受領でき、通知の再送はなかった。試験は合成データ、ローカルのSQLite、代替APNsを使用した。[Workerの停止条件](../../spec/server/通知.md#登録済みの相手への暗号化したグループ招待の送受信)

同日、通知許可証の鍵についても、鍵が空、JSONとして不正、署名鍵として読み込めない場合を確認した。修正前は不正な鍵でも受信箱の取得がHTTP 200だった。修正後は各条件で503を返し、代替APNsへの送信は増えなかった。端末Bearerによる取消・破棄・確定済み結果の確認はできた。正しい鍵に戻すと、保留していた期限内の招待を同じ送信IDで受領できた。
