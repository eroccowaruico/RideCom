# Cloudflare試用手順

初めて設定する人は[Apple・Cloudflareの設定と受入順](#利用者が行うapplecloudflareの設定と受入順)から始める。必要な公開設定と秘密の名前・取得元は[環境別の設定表](#管理画面とプレビューの設定)、実配置を最後に確認した範囲は[確認状況](#外部設定の確認状況)を参照する。

## 管理画面とプレビューの設定

Cloudflareのアカウントを選び、Realtime → Serverless SFUでApp ID / App Secretを取得する。Workers & Pages → Create application → GitHubから本リポジトリを選ぶ場合は、Worker名を`rideintercom`、root directoryを`server`、build commandを空欄にする。Worker名は`server/wrangler.toml`の`name`と揃える。

| 配置先 | 配置方法 | 設定と接続先 |
|---|---|---|
| Production | `npm --prefix server run deploy`。GitHub連携のdeploy commandは`npx wrangler deploy` | 通常のWorker URL。現行の`vars.SERVICE_ENABLED`はfalse |
| 試用プレビュー | `npm --prefix server run preview`。作業branchごとに作成・更新 | Preview URL。`previews.vars`と`previews.durable_objects.bindings`を使用。各プレビューのSQLite DOはProductionと別namespace |

表はWorkerの実行時設定。新しいPreviewへの継承は **Previews Base**、稼働中の試用先は対象の **Preview**、本番は **Production** を選ぶ。下記の用途に必要な項目をSettings → Runtime variables and secretsで設定する。repoで定義済みの通常変数は対象の構成と照合する。

| 名前 | 種類 | 値 |
|---|---|---|
| CLOUDFLARE_SFU_APP_ID | VariableまたはSecret | SFU App ID |
| CLOUDFLARE_SFU_APP_SECRET | Secret | SFU App Secret |
| CLIENT_TOKENS_JSON | Secret（旧手動試用だけ） | 試用資格の登録用`client-tokens.json`の内容。native Apple登録には不要 |
| APPLE_CLIENT_ID | Variable | Appの`com.yowamushi-inc.RideIntercom.RideIntercom`。repoへ設定済み |
| DEVICE_IDENTITY_SIGNING_KEY | Secret | 環境ごとに生成し安全に保管したEC P-256秘密鍵のJWK JSON（kty・crv・x・y・dを含む）。端末証明と用途別通知許可の署名に使用し、継続して保持する |
| APPLE_CLIENT_SECRET | Secret | AppleのSign in with Apple鍵で発行するclient-secret JWT。削除時のApple認可取消用。APNsのp8とは別 |
| APNS_PRIVATE_KEY | Secret | Appleで作成するAPNs用p8（PKCS8 P-256）。対象環境・topicへの送信権限がある鍵 |
| APNS_KEY_ID / APNS_TEAM_ID | Secret | 上記APNs鍵のKey IDとTeam ID |
| APNS_TOPIC | Variable | Appの`com.yowamushi-inc.RideIntercom.RideIntercom`。両環境へ設定済み |
| APNS_ENVIRONMENT | Variable | Productionは`production`、PreviewはDebug向けの`sandbox`。TestFlightからPreviewを使うときはそのPreviewも`production`へ合わせる |
| APPLE_AUTH_ENABLED | Variable | 両環境の既定false。Apple App ID・profile・証明署名鍵が揃った環境だけtrueにする |
| DEVICE_ATTESTATION_ENABLED | Variable | 両環境の既定false。App連携と対象の署名・配布環境の受入が揃った環境で有効化する |
| DEVICE_ATTESTATION_MAC_POLICY | Variable | 既定は空。有効化する環境でApp ID（App ID Prefixと `APPLE_CLIENT_ID`）、App Attestの `environment`、Appleの `validationCategory`、 `bundleVersion` をJSONで指定する。キー名は `appID`、 `environment`、 `validationCategory`、 `bundleVersion`。開発署名カテゴリ3でビルド番号なしを照合する場合は `bundleVersion: null`。[Macの端末鍵登録](../spec/server/Worker.md#macの端末鍵登録) |
| NOTIFICATIONS_ENABLED | Variable | 両環境の既定false。APNs鍵・profile・topic・環境が揃った環境だけtrueにする |
| SERVICE_ENABLED | Variable | 音声SFUの入口。Productionの既定false、Previewはtrue。通知の有効化とは別にSFU資格と費用上限を確認する |

`CLIENT_TOKENS_JSON`は手動発行した利用キーのSHA-256と識別名を対応付ける招待制試用用のregistry。実機の端末IDを事前収集するものではない。下記スクリプトで生成し、JSONを手書きしない。native Apple認証による自動登録・資格発行は実装済みで、下記のApple設定と環境別secret・有効化が必要。旧registryを公開Appへ埋め込まない。

Baseの値は新しいプレビューへ引き継がれる。既存プレビューのsecretはBaseの後続変更では更新されないため、そのプレビューを選んで更新する。プレビュー側だけに登録した資格はProductionへ反映されない。両端末のAppには同じPreview URLを設定する。`SERVICE_ENABLED = "true"`などの通常変数と6つのDO bindingは`wrangler.toml`の`previews`へ定義済み。SFUの値・資格はファイルやGitへ埋め込まず、Baseから継承する。

Cloudflareプラグインからは、その接続に許可された範囲で設定・メトリクスを確認できる。読取り成功はプレビューの作成権限を保証しない。CLIでプレビューを配置する場合は下記の依存導入と`wrangler login`の後、`npm --prefix server run preview`をリポジトリrootで実行する。固定名で手動試用する場合は`npm --prefix server run preview -- --name trial`と指定できる。

GitHub連携ではSettings → Builds → Branch controlのEnable Preview BuildsをONにし、Preview commandを`npx wrangler preview`にする。作業branchへのpushでそのbranch専用のプレビューへ配置する。Production branchは`main`、既存のdeploy commandは`npx wrangler deploy`のまま維持し、プレビューのために本番の配置経路を置き換えない。root directoryは`server`、build commandは空欄。Productionの資格は本番を有効化するときに本番用の値を登録する。

[公式プレビュー設定](https://developers.cloudflare.com/workers/previews/configuration/)と[GitHub連携](https://developers.cloudflare.com/workers/ci-cd/builds/)を参照する。

## 固定プレビューの継続運用

開発先はmain、配置用の固定branchは`preview`とする。2026-10-30に設定した接続先は`https://preview-rideintercom.analog.workers.dev`。検証済みmainをpreviewへ反映し、作業用`codex/`branchを固定URLとして使わない。branchの同期とCloudflare側のbuild・配置成功は別々に確認する。

このMacの`Configuration/Debug.local.xcconfig`と`server/.trial-credentials/`はmainの作業領域で保持する。Debug用の値だけであり、Release・Archive・通常の自動検証には実資格を入れない。秘密値はGitや引継ぎ文書へ転記しない。

Cloudflare設定チャットから引き継いだ残件は、実SFU/TURNを通した双方向音声、実費用・停止運用、およびbuild監視pathと旧作業branchの自動build設定の確認。固定URLの作成・HTTP認証成功だけでは音声受入完了にしない。本番を含む監視pathの変更は当時の自動承認審査で拒否されており、変更済みと扱わない。実サービスの実行条件は[開発方針](../policies/開発方針.md#実サービスを使う検証の費用制約)に従う。

## Apple登録入口の保護

削除時のApple認可取消には、AppleのSign in with Apple private keyから発行した有効なclient-secret JWTを環境別secret `APPLE_CLIENT_SECRET`へ登録する。client ID・team ID・key ID・有効期限をApple側設定と合わせ、期限前に更新する。Workerへ登録する値は署名済みJWT。署名に使ったAppleのprivate keyは発行担当が保管する。[Appleの認可取消とclient secret](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)値を通常変数・Git・ログへ入れない。未設定でもBearerによるアカウントデータ削除は利用できるが、Apple再認証付きの取消は503となる。実Apple受入は別途行う。

`APPLE_AUTH_ENABLED`はProduction/Previewとも既定でfalseのままにする。AppのInternet登録は端末証明の発行も必要なため、有効化する際は環境専用のP-256 private JWKをsecret `DEVICE_IDENTITY_SIGNING_KEY`へ登録する。未設定では証明発行が503となり、Appは新資格を回収して登録を完了させない。既存のLocal通話はこの設定を待たない。秘密鍵を通常変数・Git・ログへ入れない。証明の契約と鍵変更時の再取得は[Worker仕様](../spec/server/Worker.md#ユーザーと端末の署名付き証明)を参照する。合わせて`APPLE_CLIENT_ID`と、`APPLE_ENROLLMENT_IP_LIMIT`・`APPLE_ENROLLMENT_GLOBAL_LIMIT`の両bindingを配置する。`wrangler.toml`は送信元別30回/60秒、全体300回/60秒を指定し、Productionのnamespace 1001/1002とPreviewの1003/1004を分ける。同じCloudflareアカウントの別Workerでこのnamespaceを共用しない。

登録制限の429には60秒待って新たに認証を準備する。409 / `device_limit_reached`は登録8端末の上限であり、単なる待機では解除されない。利用できる他端末でInternet資格をサインアウト・失効するか、その資格の期限を待つ。既存端末の再認証は上限でも可能。`/api/auth/session`のGET/DELETEは登録頻度制限から独立している。保存済み資格の値やApple tokenを診断へ貼らない。

制限はlocation単位の近似値であり、費用上限ではない。[APIと保持範囲](../spec/server/Worker.md#apple認証と端末資格)と[実配置の確認待ち](../validation/未確認事項.md#appleログインの実受入)を参照する。

## 初期設定と試用

リポジトリrootで行うローカル検証。ここまでにアカウントの操作はない。

```sh
npm --prefix server ci
npm --prefix server run type-check
npm --prefix server test
node --test scripts/Cloudflare/*.test.mjs
```

### 固定Previewで試す場合

対象アカウントのRealtime → Serverless SFUでSFU AppのIDとSecretを用意する。[公式SFU API](https://developers.cloudflare.com/realtime/sfu/api/)

以下のCLIはすべて `server/` で実行する。初回は `npx wrangler login`、続いて `npx wrangler whoami` とダッシュボードでアカウント、Worker名 `rideintercom`、対象Preview名 `preview` を照合する。複数のアカウントが表示される場合は対象のAccount IDを指定してから進める（Wranglerの `CLOUDFLARE_ACCOUNT_ID`）。固定Previewが未作成なら、[管理画面とプレビューの設定](#管理画面とプレビューの設定)でPreviews Baseを準備してから `npx wrangler preview --name preview` で作成する。

既存の固定PreviewのSFU資格を**新規登録または更新するときだけ**、次を一つずつ実行して対話入力する。各操作は指定Previewの新しい配置を作る。登録済みなら名前と対象を照合し、Appの接続確認へ進む。

```sh
npx wrangler preview secret put CLOUDFLARE_SFU_APP_ID --name preview
npx wrangler preview secret put CLOUDFLARE_SFU_APP_SECRET --name preview
```

通常のAppは[Apple経由でInternet登録](#利用者が行うapplecloudflareの設定と受入順)する。下記の端末トークンは旧方式を明示して試用する場合だけ使う。

### 旧手動トークンによる新規の試用

リポジトリrootで、例のURLを実際に試すPreviewのHTTPS originへ置き換える。この手順は新しい試用registryを用意する場合のもの。既存registryに追加する際は、現在有効な全端末を含む、その環境の管理用原本を先に確認する。一部しか含まないJSONで置き換えると、省かれた端末はその資格で次回の認証ができなくなる。

```sh
node scripts/Cloudflare/issue-device.mjs https://rideintercom.example.workers.dev my-mac
node scripts/Cloudflare/issue-device.mjs https://rideintercom.example.workers.dev my-phone
cd server
npx wrangler preview secret put CLIENT_TOKENS_JSON --name preview < .trial-credentials/client-tokens.json
```

### Productionを公開するとき

本番用SFU資格を対象WorkerのProductionへ登録し、[Worker設定](../../server/wrangler.toml)の `vars.SERVICE_ENABLED` を有効にする変更をレビューする。通常変数は次の配置でも同じ値になるよう構成ファイルと揃える。GitHub連携で当該コミットが配置された場合は、その配置番号を確認する。手動配置を選んだ場合のみリポジトリrootで `npm --prefix server run deploy` を実行する。

旧手動試用の疎通確認には、対象環境のURLで発行した端末ファイルを使い、リポジトリrootで `node scripts/Cloudflare/check-service.mjs server/.trial-credentials/my-mac.json` を実行する。

発行ファイルはdirectory0700/file0600で生成しgitignore対象。端末へ渡すのは各device JSONのWorker URLとaccessTokenだけ。JSONはAppへの自動インポート形式ではなく、Settingsへ手入力するための保存形式。registryにはtokenのSHA-256だけを保存する。revoke時は対象hashをregistryから削除しsecretを再登録。稼働中のWSは既存lease終了まで残り得る。ファイルやsecretをログ・チャット・リポジトリへ貼らない。

`v1` migrationは未デプロイ開発用namespaceを前提にSQLite DOを作る。既に同名Worker/旧KV DOをデプロイしていた場合は、既存migrationを書き換えて適用せず、新しい試用Worker名とnamespaceで開始する。既存データの移行・削除はこの手順に含めない。

## Appでの試用と記録

実サービスを使う前に、[開発方針](../policies/開発方針.md#実サービスを使う検証の費用制約)に従い、単体・結合を含むローカル検証をすべて成功させる。以降の手順は明示的な実サービス確認用であり、通常テストや設定マトリクスから大量実行しない。目的・人数・時間・回数を先に決め、短い疎通から進める。

Debugで手動試用する場合は、前述の端末JSONから、このcheckoutの[Configuration](../../Configuration/README.md)の`Debug.local.xcconfig`へ接続先hostとplatform別tokenを用意する。通常のXcode Run・Buildが対象端末の値を生成Info.plistへ取り込み、AppはKeychain未設定時の既定値として読む。Settingsへの手入力や保存は不要。既定値はKeychainへ自動保存せず、保存済み設定を優先する。Release・Archive・隔離された検証buildへは含めない。秘密ファイルはgitignore対象で、GitHub経由では配布されない。

unit / UI / 音声E2Eのcurrent-process compositionは、XCTestの環境変数または`RIDEINTERCOM_LOCAL_TESTING=1`でInternet資格を無効にする。UI testはこのflagをlaunch environmentへ渡す。ローカルfixtureを使うテストはstoreを明示注入する。外部費用のない自動試験と、Debugの手動試用を混同しない。

| 操作 | 確認すること |
|---|---|
| Settings → Internet Connection → Configure | 同じWorker origin、端末ごとのaccess tokenを保存 |
| Settings → Local Network OFF | Internetを明示選択。近距離経路の成功をSFU成功と誤認しない |
| groupを作成し既存招待URLを共有 | 両端末が同じgroup secretを持つ |
| Connect、双方向発話、mute | SFU APIの成功だけで音声成功と判定しない |
| 20分以上継続 | leaseを跨いでsessionIdが変わらず手動再接続不要かを確認 |
| 一時的WS切断、端末終了 | media継続/WS再接続と、期限切れのchannel閉鎖を別々に確認 |
| 料金計測 | Cloudflare実egress / requests / duration / CPUと [費用試算](Cloudflare費用試算.md) の仮定を比較 |

## TURN有効化

TURNによる中継を試す環境でのみ、Cloudflare RealtimeでTURN keyを作り、Key IDを `CLOUDFLARE_TURN_KEY_ID`、対応するAPI tokenを `CLOUDFLARE_TURN_API_TOKEN` として同じWorker環境のruntime secretへ登録する。対象が固定Previewなら `server/` で以下を実行する。

```sh
npx wrangler preview secret put CLOUDFLARE_TURN_KEY_ID --name preview
npx wrangler preview secret put CLOUDFLARE_TURN_API_TOKEN --name preview
```

固定Previewでは `previews.vars`、本番では本番用の2つのsecretと `vars` を使う。対象側だけで `TURN_ENABLED = "true"` を設定し、該当する配置方法を使う。診断で短命資格の取得とrelay経路での双方向音声を順に確かめる。資格取得に失敗したら対象環境のIDとtokenの組を確認する。中継の有効化を取り消す場合は同じ環境のフラグを元に戻して再配置する。[TURN資格の契約](../spec/server/Worker.md#turn資格の契約)

## 検証環境の間接依存

| 依存 | 採用 / 理由 |
|---|---|
| Miniflare | 安定版4.20260730.0を維持。npm latestはこの版、5系列はbeta |
| undici | Miniflare 4配下を7.30.1へoverride。7系列の修正版。HTTP/WSのaudit指摘を解消 |
| sharp | Miniflare 4配下を0.35.5へoverride。libheif/librsvgのaudit指摘を解消 |
| 根拠 / 検証 | 2026-10-21 npm registryの版・依存、npm audit。lockfile同期、ci、型検査、Worker9件、Swiftペア成功 |
| override除去条件 | 安定版Miniflareが修正版を宣言したら通常依存へ戻し、同じWorker/ペア試験を通す |

例: [undici advisory](https://github.com/advisories/GHSA-w293-vg96-wgc3)、[sharp advisory](https://github.com/advisories/GHSA-wq5f-xc86-pv6w)。これらはローカル開発・検証ツールの依存であり、Worker bundleへそのまま配布するものではない。

## 利用者が行うApple・Cloudflareの設定と受入順

Internet通話にはApple登録とSFU、通常通知にはApple登録とAPNs、TURNは中継を受け入れる場合に設定する。App・serverのコードと公開値はrepoへ置き、アカウント固有の鍵・profile・商品を外部で設定する。Apple側の正本は[OS権限と配布設定](OS権限と配布設定.md#identifierとapple-developerでの設定)。本節は実施順を示し、portalや実配置が設定済みであるとは扱わない。

開始前に、対象のApple Team、AppのBundle ID、署名済みAppのAPNs環境、CloudflareのAccount ID・Worker名・Preview名またはProduction・両端末の接続先URLを照合する。APNs鍵を作る担当にはApple DeveloperのAccount HolderまたはAdmin権限が必要。Apple側の設定とCloudflare側の配置を別の人が担当する場合もこの組を共有し、秘密値は承認された保管先から登録する。[Appleの鍵作成権限](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens)・[CloudflareのPreviewの分離](https://developers.cloudflare.com/workers/previews/)

| 順 | 設定する場所 | 行うこと・確認する出力 |
|---|---|---|
| 1 | Apple Developer | App IDへSign in with Apple・Push Notifications・App Groupsを設定し、App／Widget／Watchのprofileを揃える。APNs鍵を取得し、Apple認可取消用client-secretも用意する。詳細はApple側正本を参照 |
| 2 | Cloudflareの対象WorkerのProduction／Previews Base | 上表の環境別secretを登録し、公開値をwrangler.tomlへ合わせる。Baseの変更は既存Previewへ遡及しないので、既存Previewにも必要なsecretを設定する |
| 3 | Worker配置 | repoの6 bindingを配置する。SIGNALING_ROOM・USAGE_GUARDはv1、APPLE_AUTH_ATTEMPT・USER_ACCOUNTはv2、NOTIFICATION_INDEXはv3、APP_ATTEST_KEY_INDEXはv4のSQLite migration。適用済みmigrationの履歴を保持し、Wranglerの配置で未適用分を反映する。手動で別名DOやQueueを増設しない |
| 4 | 環境の有効化 | native資格発行はAPPLE_AUTH_ENABLED、通知と暗号文受信箱の作成はNOTIFICATIONS_ENABLED、音声SFUはSERVICE_ENABLEDを個別に有効化する。secretやApple profileの不足をフラグで迂回しない |
| 5 | 2端末のApp | 同じWorker URLへApple経由でInternet登録する。署名・Info・serverでAPNs環境を一致させる。Debugはdevelopment→sandbox、Release／TestFlight Internal Onlyはproduction→production。OSの通知許可も確認する |
| 6 | 新しい相手へのグループ招待 | 未登録の相手への招待を名前付きで保存し、OS共有で相手に渡す。相手の登録とグループ保存、署名付き返信と、送り手の返信待ちが消えるところまで確認する。[実環境受入](../validation/未確認事項.md#新規相手招待の実環境受入) |
| 7 | 登録済み相手へのグループ自動配送 | 登録済みの相手と認証済み個別接続で用途別許可を交換し、招待を保存する。送信側のpending→queued、相手の保存後のreceivedを確認する。前面・背景で音やバナーを出さず通知センターに届くこと、通知を開いても現在の通話を維持すること、通知許可がない場合の前面復帰での受取を確認する。同じアカウントの追加端末への配送も試す。[実環境受入](../validation/未確認事項.md#登録済み相手へのグループ自動配送の実環境受入) |
| 8 | 1対1の呼び出し | 呼び出しの到着では通話を始めないこと、未接続で有効な呼び出しの通知本体や「接続」を開くと1対1の通話を始めること、別の通話中には今の通話が開くことを確認する。[通常通知の受入](../validation/未確認事項.md#通常通知の受入) |
| 9 | Internetの音声 | 同じWorkerで登録した2端末をInternet経路でつなぎ、相手の声の実出力と経路断後の双方向再開を確認する。接続先URLの作成や資格の受付とは別に受け入れる。[背景通話の受入](../validation/未確認事項.md#ios背景実行の調査と受入マトリクス) |

グループ鍵・名前は端末で暗号化されるため、group専用のserver secretを作らない。用途別grantは既存のDEVICE_IDENTITY_SIGNING_KEYで発行する。通常のAPNsとUserNotificationsだけを使い、CallKit・VoIP Push・Apple PushToTalk・silent pushの設定を追加しない。

secretは対象の環境を選んで入力する。CLIを使う場合は`server/`で、今後作成するPreviewに渡す値を`npx wrangler preview base-config secret put SECRET_NAME`、既存の固定Previewへは`npx wrangler preview secret put SECRET_NAME --name preview`で設定する。固定Previewへの設定は新しい配置を作る。Productionの`npx wrangler secret put SECRET_NAME`もその場で新しいバージョンを配置する。対象環境と配置するコードを照合し、値は対話入力へ渡す。実値はGit・通常変数・ログへ置かない。[Workersのsecret設定](https://developers.cloudflare.com/workers/configuration/secrets/)、[Previewsの設定](https://developers.cloudflare.com/workers/previews/configuration/)

登録済み相手への配送は、ローカルWorkerとAppの送受信・ファイル保存・ACKまで[検証済み](../validation/history/招待返信の手動共有.md#登録済みの相手への自動配送をappへ接続2026-11-18)。同じアカウントの追加端末では、個人招待の交換なしで、元の招待と同じグループを保存できることも[ローカルで検証済み](../validation/history/招待返信の手動共有.md#新端末で個人招待を交換せずグループを保存する)。配置後は表の実APNs・実機・実SFUの受入へ進む。

### 設定が合わないときの戻し方

| 確認点 | 次へ進める状態 | 中断した場合の再開位置 |
|---|---|---|
| 署名と通知環境 | 署名済みAppのTeam・Bundle ID・APNs環境に、対象Workerのtopic・環境・鍵の許可が対応する | 不一致の箇所を直し、同じ署名成果物とWorkerで照合し直す |
| Worker配置 | 対象の配置番号とコードが一致し、6つのDO bindingとv4までのmigrationが揃う | 失敗した配置の記録から未適用分を確認する。既存namespaceと適用済みmigrationを保持して同じ環境から再開する |
| 機能の有効化 | 同じWorkerで端末登録を完了し、通知なら対象端末へ到達、Internet通話なら両端で受話できる | 登録失敗はApple登録の工程、登録成功後の通知失敗はAPNs設定、音声だけの失敗はSFU・必要に応じてTURNから再開する |

Debug端末で届きTestFlightで届かない場合は、署名済みAppのentitlement、Workerの `APNS_ENVIRONMENT`、topic、鍵が許可する環境をこの順で照合する。Debug用の共有Previewをsandboxのまま利用中なら、TestFlight用には別のPreviewとproduction APNsを組み合わせる。対象が一致するまで次の受入へ進めず、鍵を作り直す前に不一致を直す。[署名成果物での確認](OS権限と配布設定.md#生成物での確認)・[AppleのAPNs鍵の環境とtopic](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)

設定変更前に対象の配置番号と変更予定の公開値・secret名を控える。有効化直後に失敗した場合は、その環境で変更したフラグを直前の値へ戻して配置し、他の機能が以前どおり使えるか確認する。秘密値の置換はコードの再配置だけで戻ると想定せず、対象環境用の有効な値を管理元から再登録する。DOのmigrationと保存データは保持する。作業記録には環境、配置番号、成功した段階、次に確認する項目を残す。

## 外部設定の確認状況

2026-11-19、Cloudflareの読取APIで、Productionの`rideintercom`と固定`preview`の配置番号382を確認した。表はその時点の公開値・binding・secret名を示す。端末鍵索引のv4以降の実配置、Previews Baseの現在値、配置ソースとGitの一致、Appleの実署名・端末許可、実APNsと実SFUは引き続き受入対象。

| 項目 | Production | 固定Preview |
|---|---|---|
| APNsとAppleの公開値 | APNS_ENVIRONMENTはproduction。APNS_TOPICとAPPLE_CLIENT_IDはApp IDと一致 | APNS_ENVIRONMENTはsandbox。APNS_TOPICとAPPLE_CLIENT_IDは同じApp ID |
| Durable Objects | 5 binding、migration v3 | 5 binding、migration v3 |
| 現在の設定 | secret名一覧は空。SFU App IDのbindingも未登録 | SFU App IDと`CLOUDFLARE_SFU_APP_SECRET`、旧手動試用の`CLIENT_TOKENS_JSON`を確認 |
| Apple・通知で残る設定 | `DEVICE_IDENTITY_SIGNING_KEY`とAPNsの3項目を登録。Apple認可取消には`APPLE_CLIENT_SECRET`も登録 | 同じ項目をsandbox用に登録。既存の固定Previewを対象にする |
| SFUで残る設定 | `CLOUDFLARE_SFU_APP_ID`と`CLOUDFLARE_SFU_APP_SECRET`を登録し、SERVICE_ENABLEDを有効にする | SERVICE_ENABLEDはtrue。登録済み設定で実SFUを通る双方向音声を受け入れる |
| 現在の有効化フラグ | APPLE_AUTH_ENABLED・NOTIFICATIONS_ENABLED・SERVICE_ENABLED・TURN_ENABLEDはfalse | APPLE_AUTH_ENABLED・NOTIFICATIONS_ENABLED・TURN_ENABLEDはfalse。SERVICE_ENABLEDはtrue |

Apple登録と通知は鍵・プロフィール・APNsの環境を揃えてから、対象環境でAPPLE_AUTH_ENABLEDとNOTIFICATIONS_ENABLEDを有効にする。TestFlightで固定Previewを使う場合は、production APNsに対応する設定と署名を同じPreviewへ揃える。

照合結果は `.validation/notification-cloudflare-state-20261119/settings.json` に保存した。Worker管理APIは読取だけを実行した。[検証記録](../validation/history/Cloudflare検証.md#productionと固定previewの読取2026-11-19)
