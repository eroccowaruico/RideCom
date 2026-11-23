# Cloudflare試用手順

初めて設定する人は[Apple・Cloudflareの設定と受入順](#利用者が行うapplecloudflareの設定と受入順)から始める。必要な公開設定と秘密の名前・取得元は[環境別の設定表](#管理画面とプレビューの設定)、実配置を最後に確認した範囲は[確認状況](#外部設定の確認状況)を参照する。

## 管理画面とプレビューの設定

Cloudflareのアカウントを選び、Realtime → Serverless SFUでApp ID / App Secretを取得する。Workers & Pages → Create applicationからGitHubの `eroccowaruico/RideCom` を選ぶ。Worker名は `server/wrangler.toml` の `name` と同じ `ridecom` にする。Git連携を設定する場合は[ビルド設定の復元手順](#workers-buildsの設定を復元する)に従う。

| 配置先 | 配置方法 | 設定と接続先 |
|---|---|---|
| Production | `npm --prefix server run deploy`。GitHub連携のdeploy commandは`npx wrangler deploy` | 通常のWorker URL。現行の`vars.SERVICE_ENABLED`はtrue |
| 試用プレビュー | `npm --prefix server run preview`。作業branchごとに作成・更新 | Preview URL。`previews.vars`と`previews.durable_objects.bindings`を使用。各プレビューのSQLite DOはProductionと別namespace |

表はWorkerの実行時設定。新しいPreviewへの継承は **Previews Base**、稼働中の試用先は対象の **Preview**、本番は **Production** を選ぶ。下記の用途に必要な項目をSettings → Runtime variables and secretsで設定する。repoで定義済みの通常変数は対象の構成と照合する。

| 名前 | 種類 | 値 |
|---|---|---|
| CLOUDFLARE_SFU_APP_ID | Variable | SFU App ID。Productionは`vars`、固定Previewは`previews.vars`へ環境別に設定 |
| CLOUDFLARE_SFU_APP_SECRET | Secret | SFU App Secret |
| CLOUDFLARE_TURN_KEY_ID | Variable | TURN Key ID。Productionは`vars`、固定Previewは`previews.vars`へ環境別に設定 |
| CLOUDFLARE_TURN_API_TOKEN | Secret | TURN資格発行・失効用のAPI token |
| APPLE_CLIENT_ID | Variable | Appの`com.yowamushi-inc.RideIntercom.RideIntercom`。repoへ設定済み |
| DEVICE_IDENTITY_SIGNING_KEY | Secret | 環境ごとに生成し安全に保管したEC P-256秘密鍵のJWK JSON（`kty`、`crv`、`x`、`y`、`d`を含む）。端末証明と用途ごとの通知許可の署名に使用し、継続して保持する |
| INVITATION_RELAY_KEY_SEED | Secret | 個人招待の受諾とグループ招待の送信・取消をiOSの背景転送に預ける環境で設定する。環境ごとのランダムな32 byteをpaddingなしbase64urlで表す。公開鍵の発行と使用期限は[Worker仕様](../spec/server/Worker.md#招待を預けるサービスの暗号化公開鍵)に従う |
| APPLE_SIGN_IN_PRIVATE_KEY | Secret | AppleのSign in with Apple用`.p8`全文。Workerが削除時のApple認可取消に必要な短期client-secret JWTを自動生成する。APNsのp8とは別 |
| APPLE_SIGN_IN_KEY_ID | Variable | 上記Sign in with Apple鍵のKey ID。Productionは`vars`、Previewは`previews.vars`へ設定する |
| APPLE_TEAM_ID | Variable | Sign in with AppleとAPNsで共通のApple Developer Team ID。Productionは`vars`、Previewは`previews.vars`へ設定し、環境内で1つに集約する |
| APNS_PRIVATE_KEY | Secret | Appleで作成するAPNs用p8（PKCS8 P-256）。対象環境・topicへの送信権限がある鍵 |
| APNS_KEY_ID | Variable | 上記APNs鍵のKey ID。Productionは`vars`、Previewは`previews.vars`へ設定する |
| APNS_TOPIC | Variable | Appの`com.yowamushi-inc.RideIntercom.RideIntercom`。両環境へ設定済み |
| APNS_ENVIRONMENT | Variable | TestFlightが接続する本番は `production`。開発署名で使う固定Previewは `sandbox` |
| APPLE_AUTH_ENABLED | Variable | Apple App ID・profile・証明署名鍵が揃った環境で `true` にする |
| DEVICE_ATTESTATION_ENABLED | Variable | 両環境の既定false。App連携と対象の署名・配布環境の受入が揃った環境で有効化する。確認要求の発行と鍵登録には、下記の照合設定と `APP_ATTEST_KEY_INDEX` の設定も必要。[有効化条件](../spec/server/Worker.md#端末鍵登録の確認要求) |
| DEVICE_ATTESTATION_MAC_POLICY | Variable | 既定は空。有効化する環境では、App ID（App ID Prefixと `APPLE_CLIENT_ID`）をJSONに指定する。同じJSONにApp Attestの `environment`、Appleの `validationCategory` と `bundleVersion` を含める。キー名は `appID`、 `environment`、 `validationCategory`、 `bundleVersion`。開発署名カテゴリ3でビルド番号なしを照合する場合は `bundleVersion: null`。[Macの端末鍵登録](../spec/server/Worker.md#macの端末鍵登録) |
| NOTIFICATIONS_ENABLED | Variable | APNs鍵・profile・topic・環境を揃えてから `true` にする |
| SERVICE_ENABLED | Variable | 音声SFUの入口。SFU資格と費用上限を確認して有効にする。停止中も既存の通話終了とICE接続準備の取消には、回収に必要なSFU・TURNの資格を使う。[TOMLの環境別設定](../spec/server/Worker.md#設定値) |

Baseの値は新しいプレビューへ引き継がれる。既存プレビューのsecretはBaseの後続変更では更新されないため、そのプレビューを選んで更新する。プレビュー側だけに登録した資格はProductionへ反映されない。検証端末ごとに固定Previewへ接続するDebugビルドを入れ、Appleで認証する。通常変数と6つのDO bindingは`wrangler.toml`の`previews`に定義する。固定Previewでは配置が参照するSFU App IDと、そのIDに対応するSecretを照合する。

Cloudflareプラグインからは、その接続に許可された範囲で設定・メトリクスを確認できる。読取り成功はプレビューの作成権限を保証しない。試用を始めるときは[固定Previewの利用開始手順](#固定previewを作り直せる条件)に従う。手動で配置する場合も、再作成したブランチと同じコミットから固定Previewを指定して `npm --prefix server run preview -- --name preview` を実行する。

### Workers Buildsの設定を復元する

Git連携の再構築に使う値は [server/cloudflare-builds.toml](../../server/cloudflare-builds.toml) に置く。自動ビルドはCloudflareに保存した設定を読む。`wrangler.toml` は配置時に読み、互換日付・ルート・実行時の変数を管理する。[Workers Buildsの設定](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/)

| 対象 | Cloudflareで変更する場所 | いつ反映されるか |
|---|---|---|
| 本番のGit連携とビルド | WorkerのSettings → Builds。Root directoryは `server`、Build commandは `npm ci`、Deploy commandは `npx wrangler deploy`。`SKIP_DEPENDENCY_INSTALL=1` はBuild variables and secretsに登録する | 次回の本番ビルド |
| 今後作るPreviewのビルド設定 | Builds APIでWorkerの `previews_base_config` を更新する。`root_directory` は `/server`、`build_command` は `npm ci`、`deploy_command` は `npx wrangler preview`。`environment_variables` に `SKIP_DEPENDENCY_INSTALL=1` を設定する | 作成時に各Previewへコピーされる |
| 作成済みの固定 `preview` のビルド設定 | Builds APIの一覧で `fixed_preview.branch` に一致するPreviewを特定し、そのPreviewだけを指定する `PATCH` の `settings` に上記と同じ値を渡す | 次回の固定Previewビルド。Previewと保存データはそのまま使う |

固定Previewを復旧するときは、更新前後に同じPreviewのビルド設定を読み戻す。Previews Baseの変更は新規作成用で、既存Previewのビルド設定へは通常反映されない。設定だけの修正は対象の固定Previewに適用する。その環境で試用を始める際は[固定Previewの利用開始手順](#固定previewを作り直せる条件)に従う。Builds APIでの更新には、ユーザーに紐づくAPIトークンの `Workers Builds Configuration: Edit` が必要。ビルドがWorkerを配置するためのトークンとは用途が異なる。[Builds APIの権限](https://developers.cloudflare.com/workers/ci-cd/builds/api-reference/#create-an-api-token)・[Previewの個別更新](https://developers.cloudflare.com/workers/ci-cd/builds/api-reference/#update-a-preview)

2026-11-23の読取りでは、本番は復元用の値と一致した。新規Previewのビルド設定はRoot directoryが `/`。既存の固定Previewは `/` のままで、Build commandと `SKIP_DEPENDENCY_INSTALL` が未設定だった。固定Previewは自動の依存関係インストール中にリポジトリルートのPython設定を検出し、Wranglerの起動前に失敗する。復旧の確認では、先に個別設定を読み戻し、対象コミットのビルドが `server` で依存関係を導入して成功したことを確かめる。次に固定Previewの最新配置がそのコミットと一致し、目的のURLで応答することを確認する。[依存関係の自動インストール](https://developers.cloudflare.com/workers/ci-cd/builds/build-image/#skip-dependency-install)

固定 `preview` を共有mainの `1bf40108` から作り直し、Previews Baseの `/server`、`npm ci`、`SKIP_DEPENDENCY_INSTALL=1` を引き継いだ。Cloudflareで配置コミットと互換日付 `2026-11-17` を照合した。独自ドメインと `workers.dev` はどちらも `/health` が200、資格なしの `/api/status` が401だった。

本番と固定PreviewのWorkers Buildsは、ビルドのルート `server` にある `server/.node-version` からNode.jsのバージョンを選ぶ。ダッシュボードの `NODE_VERSION` に別のバージョンを重ねて指定しない。配置を受け入れる際は、両環境のビルド記録で指定したNode.jsのバージョンが使われたことを確認する。[Workers BuildsでのNode.jsの指定方法](https://developers.cloudflare.com/workers/ci-cd/builds/build-image/#overriding-default-versions)

[公式プレビュー設定](https://developers.cloudflare.com/workers/previews/configuration/)と[GitHub連携](https://developers.cloudflare.com/workers/ci-cd/builds/)を参照する。

## 固定プレビューの継続運用

開発先はmain、配置用の固定branchは`preview`とする。固定Previewの独自ドメインは `https://preview.workers.ridecom.yowamushi-inc.com`。動作確認には `https://preview-ridecom.analog.workers.dev` も使える。検証済みmainをpreviewへ反映し、作業用`codex/`branchを固定URLとして使わない。branchの同期とCloudflare側のbuild・配置成功は別々に確認する。

### Worker名の変更後に本番と固定Previewの設定を照合する

2026-11-23。Worker名の変更後に本番と固定Previewを読み直した。両環境の新しい `workers.dev` URLで `/health` は200、旧URLは404だった。Gitの `main` と `preview` の両ビルドは `c966938d` で成功していた。本番の独自ドメインは本番への割り当てとヘルス応答200を確認した。固定Previewの独自ドメインは照会時に名前解決できなかった。当初の誤記のホストはCloudflare上で本番に割り当てられていた。

Durable Objectsは両環境で6クラスずつあり、binding名とクラス名は設定ファイルと一致した。全12件の名前空間がCloudflareにあり、両環境が共有する名前空間は0件だった。固定Previewのmigrationは `v4`。Worker名をリポジトリ側で揃える変更では、既存のbindingとmigrationを使う。[Previewの資源分離](https://developers.cloudflare.com/workers/previews/resources/)

SFU App IDとTURN Key IDはPreviews Baseと固定Previewで一致し、本番とは異なった。旧手動資格と短期試験設定は本番・固定Previewの双方で未設定。Apple認証は固定Previewでも有効と設定されていたが、Appleの署名用secretが登録されていないため、通常登録は試用前に別途確認する。固定PreviewのAPNs環境はsandboxで、通知は無効だった。

Observabilityの親設定、ログ、トレース、WorkerのLogpushは両環境で無効。転送先とTail Workerは0件だった。Previews Baseでは親・ログ・トレースが有効だった。本番・固定Previewの個別設定は保存と呼出ログが有効、クエリ除去は無効であり、設定ファイルとは異なった。監視設定の差は[既存の課題](../backlog/未実装課題.md#cloudflareのobservability設定変更に対応する)で追う。アカウント全体のLogpush一覧は取得権限がなかった。

2026-11-23。Preview専用の基点に `preview.workers.ridecom.yowamushi-inc.com` を指定すると、Cloudflareが固定名 `preview` を付け、`preview.preview.workers.ridecom.yowamushi-inc.com` が生成された。既存の `workers.ridecom.yowamushi-inc.com` をProduction and Previewに変更し、本番と目的の固定Preview URLの割当を確認した。両方の `/health` はHTTPSで200を返した。固定Previewでは、手元のDNSに残る変更前の結果を避けるため、公開DNSで取得したアドレスを使い、TLSの証明書も検証した。この基点と両環境の有効化は `server/wrangler.toml` の `routes` に記録する。[Previewのカスタムドメイン](https://developers.cloudflare.com/workers/previews/custom-domains/#enable-custom-domain-preview-urls)

### 本番と固定Previewの監視設定を反映する

Workers LogsとIssuesは両環境で有効、トレースは固定Previewで有効にする。ログとトレースのサンプリング率は100%。呼出ログとエクスポートの扱いは[Workerの設定仕様](../spec/server/Worker.md#設定値)に従う。[Previewのログとトレース](https://developers.cloudflare.com/workers/previews/test-and-debug/)・[Issues](https://developers.cloudflare.com/workers/observability/issues/)

変更は `server/wrangler.toml` の該当環境に入れる。共有mainと固定 `preview` の配置成功後、Cloudflareで両方の実効設定を個別に読み戻す。ログとIssuesの有効化、トレースの環境別の差、100%のサンプリング率、クエリ除去、エクスポートなしを照合する。固定Previewで観測を再現するときは合成データを使う。元に戻す場合は、戻す項目だけを同じ設定ファイルで前の値に合わせて配置し、両環境の実効設定を再確認する。

このMacの開発設定はGit管理外の `Configuration/Debug.local.xcconfig` で扱う。Debug用の値だけであり、Release・Archive・通常の自動検証には実資格を入れない。秘密値はGitや引継ぎ文書へ転記しない。

Cloudflare設定チャットから引き継いだ残件は、実SFU/TURNを通した双方向音声、実費用・停止運用、およびbuild監視pathと旧作業branchの自動build設定の確認。固定URLの作成・HTTP認証成功だけでは音声受入完了にしない。本番を含む監視pathの変更は当時の自動承認審査で拒否されており、変更済みと扱わない。実サービスの実行条件は[開発方針](../policies/開発方針.md#実サービスを使う検証の費用制約)に従う。

### サーバー変更のあるpushにビルドを絞る設定案

2026-11-21。読み取りAPIで `rideintercom` 本番の対象ブランチが `main`、ビルドの作業ディレクトリが `/server` であることを確認した。Build watch pathsのIncludesが `*`、Excludesが空であることを確認した。6時から12時までの本番配置25件をCloudflare Buildsが記録したGitコミットと照合した。24件のコミットは `server/` に差分がなく、25件が参照した `server/` のツリーは2種類だった。[配置回数の点検](history/バックログの優先順位と進捗の記録.md#本番workerの配置をgitの差分と照合する)

設定変更を適用できる場合、対象Workerの **Settings → Build → Build watch paths** で、本番のIncludesをリポジトリルートからの `server/*` にする。次の通常のpushでは、Cloudflare Buildsで本番のビルドを確認する。`server/` に触れない小さな変更ならビルドは起動しない。`server/` を変更すると、従来のブランチとコマンドでビルドが起動する。固定 `preview` は別に確認する。配備に使うファイルを `server/` の外へ追加したときは、そのパスもIncludesへ加える。失敗時はIncludesを `*` に戻し、通常のビルドが再開することを確認する。連携元が大きなpushを送った場合など、Cloudflareはパス判定を省略する条件がある。[CloudflareのBuild watch paths](https://developers.cloudflare.com/workers/ci-cd/builds/build-watch-paths/)

## Apple登録入口の保護

削除時にApple認可を取り消すには、AppleのSign in with Apple用の鍵を環境別に登録する。`.p8`全文はSecretの `APPLE_SIGN_IN_PRIVATE_KEY`、Key IDは通常の変数 `APPLE_SIGN_IN_KEY_ID` に登録する。Team IDはAPNsと共通の通常Variable `APPLE_TEAM_ID`を使う。Workerは`APPLE_CLIENT_ID`と組み合わせ、有効期間5分のclient-secret JWTを必要時に生成し、残り1分で自動更新する。期限付きJWTの手動作成・登録・更新は行わない。[Appleの認可取消とclient secret](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens) `.p8`を通常変数・Git・ログへ入れず、APNs用の鍵と取り違えない。3項目のどれかが未設定でもBearerによるアカウントデータ削除は利用できるが、Apple再認証付きの取消は503となる。実Apple受入は別途行う。

旧`APPLE_CLIENT_SECRET`から本番を止めずに移行するには、次の順に進める。

1. 新しい`.p8`をSecretへ、Key IDとTeam IDを変数へ登録する。
2. この実装のWorkerを配置する。
3. Appleとの実際のコード交換と認可取消を確認する。
4. 旧Secretを削除する。

旧Workerは新しい3項目を参照しないため先行登録できる。新Workerは旧secretへフォールバックしないため、配置前に3項目を揃える。

Cloudflareへ手動登録する値は、各サービスの長期鍵・ID・API tokenに限る。APNsのprovider JWTは既存実装が`.p8`から生成して50分未満で自動更新し、TURNの短期資格は通話leaseに合わせてTURN APIから生成・更新・失効する。端末資格や招待など製品の安全性に必要な期限は維持するが、期限付きの派生値を運用者が定期交換する手順は設けない。長期鍵の漏えい・担当変更・provider側の失効時は、期限更新ではなく鍵のローテーションとして扱う。

環境専用のP-256 private JWKを端末証明のsecret `DEVICE_IDENTITY_SIGNING_KEY`へ登録してから、Apple登録を有効にする。未設定では証明発行が503となり、Appは新資格を回収して登録を完了させない。既存のLocal通話はこの設定を待たない。秘密鍵を通常変数・Git・ログへ入れない。証明の契約と鍵変更時の再取得は[Worker仕様](../spec/server/Worker.md#ユーザーと端末の署名付き証明)を参照する。合わせて`APPLE_CLIENT_ID`と、`APPLE_ENROLLMENT_IP_LIMIT`・`APPLE_ENROLLMENT_GLOBAL_LIMIT`の両bindingを配置する。`wrangler.toml`は送信元別30回/60秒、全体300回/60秒を指定し、Productionのnamespace 1001/1002とPreviewの1003/1004を分ける。同じCloudflareアカウントの別Workerでこのnamespaceを共用しない。

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

以下のCLIはすべて `server/` で実行する。初回は `npx wrangler login` でログインする。続いて `npx wrangler whoami` とダッシュボードでアカウント、Worker名 `ridecom`、対象Preview名 `preview` を照合する。複数のアカウントが表示される場合は対象のAccount IDを指定してから進める（Wranglerの `CLOUDFLARE_ACCOUNT_ID`）。試用時は[固定Previewの利用開始手順](#固定previewを作り直せる条件)を先に完了する。

固定PreviewのSFU App IDとTURN Key IDは `server/wrangler.toml` の `previews.vars` で指定する。CloudflareのPreviews BaseにあるシークレットはPreviewを作成する際に取り込まれる。既存の固定Previewに足りないシークレットは、そのPreviewを対象に登録する。標準の対話入力で登録した後、最新配置でシークレットの型を照合する。[CloudflareのPreviewシークレット](https://developers.cloudflare.com/workers/previews/configuration/#secrets)

```sh
npx wrangler preview secret put CLOUDFLARE_SFU_APP_SECRET --name preview
npx wrangler preview secret put CLOUDFLARE_TURN_API_TOKEN --name preview
npx wrangler preview secret put APNS_PRIVATE_KEY --name preview
npx wrangler preview secret put DEVICE_IDENTITY_SIGNING_KEY --name preview
```

通常のAppは[Apple経由でInternet登録](#利用者が行うapplecloudflareの設定と受入順)する。

### 共有mainから固定Previewと通話試験を用意する

共有 `main` にWorkerの実装、固定Previewの公開設定、試験条件を置く。環境ごとの鍵はCloudflareのPreviews Baseで管理する。端末資格、招待リンク、グループの共有鍵、アカウントや通話の保存データはCloudflareまたは試用端末で扱う。

1. [固定Previewの利用開始手順](#固定previewを作り直せる条件)に従い、今回検証する共有mainのコミットから新しい配置を用意する。[Cloudflareの自動作成](https://developers.cloudflare.com/workers/ci-cd/builds/api-reference/#manage-previews)・[シークレットの継承](https://developers.cloudflare.com/workers/previews/configuration/#secrets)
2. 最新配置のコミット、SFUとTURNの参照先、SFU・TURN・端末証明のシークレットの型を管理APIで照合する。資格が揃った配置で、[外部設定の受入順](#利用者が行うapplecloudflareの設定と受入順)に従い固定PreviewのApple登録、通話、TURNを有効にする。
3. 固定Preview内の試験データには下記の破棄方針を適用する。開発署名のAppを2台とも固定Previewに向け、それぞれ試験用のAppleアカウントで登録する。Aが試験用グループを作り、Bに招待リンクを送り、Bが参加する。試験のたびに同じ操作で登録とグループを用意できる。リンクと共有鍵はAppがその都度生成する。
4. 両端でInternet経路の受話を確認し、制限回線で試す場合は試験時間帯のPreview用TURNキーの転送量も照合する。実際に相手の発話が両端で聞こえ、再接続後にも新しい発話を互いに受け取れたかを[検証記録](../validation/history/Cloudflare検証.md)に残す。[TURNの計測項目](https://developers.cloudflare.com/realtime/turn/analytics/)
5. 試験を終えたら両端の通話を終了する。今回作った招待・グループ・端末登録は試験データとして回収する。外部サービスの通話資源はそのサービス側でも終了を確かめる。回収した項目と、失効・削除後の状態を何で確認したかを検証記録に残す。途中で止まった場合も同じ範囲を確認する。試験専用データの回収方法や対象を特定できなければ、[固定Previewの残作業](../backlog/未実装課題.md#最初に試すインターネット通話と通知と招待)に戻す。

過去の試験グループや招待リンクを前提にせず、手順3から新しく作った状態で比較する。[試験データと判定の再現条件](../policies/開発方針.md#試験データを作り直し同じ条件で判定する)に従い、実行したmainのコミット、手順・入力の変更点、両端での合否を記録する。

固定Preview内の端末登録・グループ・通話の接続管理を含む試験データは破棄してよい。再作成時は残存件数にかかわらず旧状態を破棄し、同じ固定名で試験に必要な状態を新しく作る。消失の了承を再度求める必要はない。対象ブランチと環境を照合し、共有mainの履歴、Previews Baseの資格と外部サービスの資源を保つ。

#### 固定Previewを作り直せる条件

**固定Previewの試用・E2Eを始めるたびに、リモートの `preview` ブランチを共有mainから作り直し、再デプロイしてから接続する。** 前回と同じコミットを試す場合もこの手順を使う。

1. 検証済みの `origin/main` のコミットを特定し、下表の入力をそろえる。管理画面で変更した設定の取り込みを依頼されている場合は先に保存する。別の試験や再作成が進行中なら、担当と切り替え時点を合わせる。
2. 対象が固定名 `preview` であることと、ブランチ固有の作業が保全されていることを確認する。リモートに旧ブランチがあれば削除する。Cloudflare側でも旧Previewの削除完了を確認する。ブランチ削除に連動せず旧環境が残る場合は、その固定Previewだけを削除する。旧環境がなくなったら、手順1のコミットから同名のリモートブランチを作成する。
3. 今回の再デプロイが成功し、固定Previewの稼働中の配置が今回のビルドと対象コミットに対応することを照合する。検証記録に対象コミットと新しい配置の識別情報を残してから試験を始める。配置に失敗した場合や新旧を区別できない場合は試験を保留する。

再作成に必要な入力は次の3か所からそろえる。

| 入力元 | 再現する内容 |
|---|---|
| 共有mainの対象コミット | Worker、依存関係のロックファイル、Previewの通常変数・binding・migration、固定名を指定する配置手順 |
| 管理されたPreview用の資格 | Previews Baseと発行元の手順から、対象環境の参照先と対応する資格を用意する。旧配置にしかない設定は、現行方式でも必要な場合に限り供給元と手順に反映する。秘密値は記録しない |
| 新しく用意する試験データ | 空の状態から今回の端末登録・グループ・招待を用意し、試験後に回収する。使用する接続先と合否の条件をそろえる |

構成の変更時は、対象コミットを空の作業場所に展開して依存を復元し、Workerをビルドしてローカル試験を通す。管理側では、作成時に使う設定と固定Previewの実効設定を照合する。設定の有無、既存配置への再デプロイ、既存端末での通話は、それぞれその工程の結果として記録する。

試験資格の登録でHTTP 403が出たら、Cloudflare管理APIでの設定更新と、試験端末からWorkerへの認証を区別する。実中継試験の準備は、共有mainで採用した試験方式が使う資格と、対象のPreviewに必要なSFU・TURNの設定を照合する。供給元に必要な設定がなければ先に補う。既存Previewに継承されていなければ、配置担当が共有mainから固定ブランチを作り直す。再作成後は最新配置を特定し、試験資格が通ることと実中継で両方向の音声が届くことを個別に判定する。

通話の実環境試験では、今回の配置に対して[試験の準備から回収まで](#共有mainから固定previewと通話試験を用意する)を実行し、初期状態、両端の通話結果と回収結果を残す。

### Appleログインなしで固定Previewの音声を測る

CLIとSimulatorは固定Previewの独自ドメイン `https://preview.workers.ridecom.yowamushi-inc.com` を使う。Workerはこの接続先で試験用の資格を受け付ける。試験前に対象URLの配置と公開応答を照合する。

実中継を使う試験は、ローカルで発話の往復を確認してから明示的に実行する。対象は固定Previewの1グループ、参加者2人、各約2秒の発話を1回。Appleによる新規登録の試用は、開発署名のAppで行う別の工程として扱う。

1. `node scripts/Cloudflare/prepare-preview-media-trial.mjs` を実行する。返るディレクトリには、試験の照合値を入れた `grant.toml` と、端末側の試験資格を入れた `credentials.json` がある。
2. `grant.toml` の1行を `server/wrangler.toml` の `[previews.vars]` に加え、試験設定を含む共有mainのコミットを対象に[固定Previewの利用開始手順](#固定previewを作り直せる条件)を実行する。配置を読み戻し、公開先とコミット、設定の有無を照合する。試験資格と通話鍵はローカルの `credentials.json` で扱う。
3. 下のコマンドで測定する。出力先には新しいディレクトリを指定する。資格2件の受付、両方向の発話フレームの一致、試験後の通話数と利用枠を確認する。

   ```sh
   python3 scripts/Cloudflare/run-preview-media-trial.py "$TRIAL_DIR/credentials.json" --output "$OUTPUT_DIR"
   ```

   UDP TURNを確認する場合は、先に[ローカルのTURN試験](音声E2Eテスト.md#udp-turnを経由する発話を検証する)を通す。固定Previewの試験コマンドに `--turn-relay` を付け、送信の前後に両端で選ばれた経路がUDP TURNであることも判定する。

   後から参加した相手の声を受け取る条件を確認する場合は、先に[接続待ちのローカル試験](音声E2Eテスト.md#ミュートで待機して後から参加した相手の声を受け取る)を通す。固定Previewでは `--wait-for-peer` を指定する。先に接続する側がミュートのまま20秒待ち、相手の参加後に声を受け取る。続けてミュート解除後の双方向の発話を測る。同じ2人が同じ通話で行う。

4. `TEST_PREVIEW_MEDIA_TRIAL` の行を削除して同じ経路で配置する。同じコマンドの `--output` に代えて `--check-revoked` を指定し、両方の資格が401になることを確認する。最後にローカルの資格を回収する。

`TEST_PREVIEW_MEDIA_TRIAL` は音声の試験時だけ固定Previewに設定する。試験用の資格は発行から最大20分だけ有効。[Workerの制約](../spec/server/Worker.md#apple認証と端末資格)と[実サービス検証の費用制約](../policies/開発方針.md#実サービスを使う検証の費用制約)を適用する。

### Productionを公開するとき

本番用SFU資格を対象WorkerのProductionへ登録し、[Worker設定](../../server/wrangler.toml)の `vars.SERVICE_ENABLED` を有効にする変更をレビューする。通常変数は次の配置でも同じ値になるよう構成ファイルと揃える。GitHub連携で当該コミットが配置された場合は、その配置番号を確認する。手動配置を選んだ場合のみリポジトリrootで `npm --prefix server run deploy` を実行する。

`v1` migrationは未デプロイ開発用namespaceを前提にSQLite DOを作る。既に同名Worker/旧KV DOをデプロイしていた場合は、既存migrationを書き換えて適用せず、新しい試用Worker名とnamespaceで開始する。既存データの移行・削除はこの手順に含めない。

## Appでの試用と記録

実サービスを使う前に、[開発方針](../policies/開発方針.md#実サービスを使う検証の費用制約)に従い、単体・結合を含むローカル検証をすべて成功させる。以降の手順は明示的な実サービス確認用であり、通常テストや設定マトリクスから大量実行しない。目的・人数・時間・回数を先に決め、短い疎通から進める。

Debugは固定Previewが既定。Apple登録はアプリ内の接続シートから行う。

単体テスト、UIテスト、音声E2Eでは、テスト中のプロセスに構成を組み立てる。このときXCTestの環境変数または`RIDEINTERCOM_LOCAL_TESTING=1`でInternet資格を無効にする。UI testはこのflagをlaunch environmentへ渡す。ローカルfixtureを使うテストはstoreを明示注入する。外部費用のない自動試験と、Debugの手動試用を混同しない。

| 操作 | 確認すること |
|---|---|
| Settings → Internet Connection → Configure | 同じ固定Previewに向く開発署名のAppで、有効な端末資格を確認する。資格がなければAppleで登録する |
| Settings → Local Network OFF | Internetを明示選択。近距離経路の成功をSFU成功と誤認しない |
| groupを作成し既存招待URLを共有 | 両端末が同じgroup secretを持つ |
| Connect、双方向発話、mute | SFU APIの成功だけで音声成功と判定しない |
| 20分以上継続 | leaseを跨いでsessionIdが変わらず、手動で再接続する必要がないことを確認 |
| 一時的WS切断、端末終了 | media継続/WS再接続と、期限切れのchannel閉鎖を別々に確認 |
| 料金計測 | Cloudflare実egress / requests / duration / CPUと [費用試算](Cloudflare費用試算.md) の仮定を比較 |

## TURN有効化

TURNによる中継を試す環境でのみ、Cloudflare Realtimeで環境ごとに別のTURN keyを作る。Previewは `rideintercom-turn-preview`、Productionは `rideintercom-turn-production` とし、同じkeyを共有しない。環境を示さない自動生成名のkeyはWorkerからの参照を確認できない限り再利用せず、未参照を確認してから削除する。

Dashboardでkeyを作成するときは、登録より先に、その画面で表示されたKey IDとAPI tokenの組を環境名付きで秘密管理先へ保存する。API tokenを後から再表示できず、保存済みの値も確認できない場合は、そのkeyをWorkerへ登録せず削除して作り直す。Key IDは `CLOUDFLARE_TURN_KEY_ID` の通常Variableへ登録する。対応するAPI tokenは `CLOUDFLARE_TURN_API_TOKEN` のSecretとして同じ環境へ登録する。秘密値であるAPI tokenをrepo、作業記録、チャット、コマンド引数へ残さない。

対象が固定Previewなら `server/` で以下を実行する。

```sh
npx wrangler preview secret put CLOUDFLARE_TURN_API_TOKEN --name preview
```

固定Previewでは`previews.vars`と対象PreviewのSecret、本番では`vars`と本番Secretを使う。keyを作成して秘密管理先に保存し、対象環境にID VariableとAPI token Secretを登録するまで `TURN_ENABLED` はfalseを保つ。最後に対象側だけで `TURN_ENABLED = "true"` を設定し、該当する配置方法を使う。診断で短命資格の取得とrelay経路での双方向音声を順に確かめる。資格取得に失敗したら対象環境のIDとtokenの組を確認する。中継の有効化を取り消す場合は同じ環境のフラグを元に戻して再配置する。[TURN資格の契約](../spec/server/Worker.md#turn資格の契約)

## 検証環境の間接依存

| 依存 | 採用 / 理由 |
|---|---|
| Miniflare | 安定版4.20260730.0を維持。npmのlatestタグも4.20260730.0、5系列はbeta |
| undici | 直接使うMiniflare 4と、Wrangler配下のMiniflare 5 betaの両方を7.30.2へoverride。7.29.1は[応答の処理で起こる停止](https://github.com/nodejs/undici/security/advisories/GHSA-xjj6-f33q-929c)の影響を受け、7.30.1は[キャッシュ設定時の情報の混在](https://github.com/nodejs/undici/security/advisories/GHSA-mqg3-3v4r-cm32)の影響を受ける |
| sharp | Miniflare 4配下を0.35.5へoverride。libheif/librsvgのaudit指摘を解消 |
| 根拠 / 検証 | 2026-11-21に公開アドバイザリーが示す影響範囲・修正バージョンと、lockfileの各階層で選ばれたパッケージのバージョンを照合。Workerの型検査・回帰とSwiftペアで確認する |
| override除去条件 | 直接・間接のMiniflareで対応する依存がすべて修正版に解決されることを確認する。該当設定を外した状態で同じWorker／ペア試験を通す |

undiciとsharpはローカル開発・検証や配備に使うNode.js側の依存で、Worker本体に同梱しない。sharpの採用は2026-10-21時点の公開情報、lockfile更新、型検査、Worker9件とSwiftペアで確認した。[sharpの公開アドバイザリー](https://github.com/advisories/GHSA-wq5f-xc86-pv6w)

## 利用者が行うApple・Cloudflareの設定と受入順

Internet通話にはApple登録とSFU、通常通知にはApple登録とAPNs、TURNは中継を受け入れる場合に設定する。App・serverのコードと公開値はrepoへ置き、アカウント固有の鍵・profile・商品を外部で設定する。Apple側の設定については[OS権限と配布設定](OS権限と配布設定.md#identifierとapple-developerでの設定)。本節は実施順を示し、portalや実配置が設定済みであるとは扱わない。

TestFlightに配布するAppは本番Workerを使う。固定Previewは開発署名での試用に使う。TestFlightでは同じビルドを2台に入れ、Internet通話と圏外の近距離通話から試す。通話の設定は端末登録・端末証明とSFUを先に揃える。通常通知のAPNsと、招待の背景転送用の鍵は、後続の各工程で照合する。[2端末の試用条件](../backlog/未実装課題.md#最初に試すインターネット通話と通知と招待)

配布用Releaseは本番、開発署名のDebugは固定Previewを選ぶ。既存ビルドが参照する旧URLと新URLは[Worker URLの切り替え](../backlog/未実装課題.md#本番と固定previewのworker-urlをridecomに揃える)で扱う。Internet通話を試すときは、両端末で接続先と、その環境で使える端末資格・端末証明を確認する。揃っていれば通話を試し、不足する端末だけでApple登録や証明の取得を済ませる。初回登録の成否を調べる場合は、その結果を通話の合否と分けて記録する。[配布版とDebugの画面](../spec/App/UI/Settings.md#internet-connection)

開始前に対象のApple Team、AppのBundle ID、署名済みAppのAPNs環境を照合する。CloudflareのAccount ID、Worker名、対象のPreview名またはProduction、両端末の接続先URLも照合する。APNs鍵を作る担当にはApple DeveloperのAccount HolderかAdminの権限が必要。Apple側の設定とCloudflare側の配置を別の人が担当する場合もこの組を共有し、秘密値は承認された保管先から登録する。[Appleの鍵作成権限](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens)・[CloudflareのPreviewの分離](https://developers.cloudflare.com/workers/previews/)

| 順 | 設定する場所 | 行うこと・確認する出力 |
|---|---|---|
| 1 | Apple Developer | App IDへSign in with Apple・Push Notifications・App Groupsを設定し、配布するAppとWidgetのprofileを揃える。APNs用の鍵とApple認可取消用の鍵・IDは各工程の前に管理元で用意する。詳細は上記のApple Developerでの設定手順を参照 |
| 2 | Cloudflareの対象WorkerのProduction／Previews Base | 上表の環境別secretを登録し、公開値をwrangler.tomlへ合わせる。Baseの変更は既存Previewへ遡及しないので、既存Previewにも必要なsecretを設定する |
| 3 | Worker配置 | repoの6 bindingを配置する。SQLiteのmigrationは、v1がSIGNALING_ROOMとUSAGE_GUARD、v2がAPPLE_AUTH_ATTEMPTとUSER_ACCOUNT。v3はNOTIFICATION_INDEX、v4はAPP_ATTEST_KEY_INDEX。適用済みmigrationの履歴を保持し、Wranglerの配置で未適用分を反映する。手動で別名DOやQueueを増設しない |
| 4 | 環境の有効化 | native資格発行はAPPLE_AUTH_ENABLED、通知と暗号文受信箱の作成はNOTIFICATIONS_ENABLED、音声SFUはSERVICE_ENABLEDを個別に有効化する。secretやApple profileの不足をフラグで迂回しない |
| 5 | Internet通話 | 同じTestFlightビルドを入れ、本番Workerの有効な端末資格と端末証明が揃った2台で、Internet経路を使って相手の声を互いに聞く。経路が一時的に切れた後の双方向再開も確認する。[背景通話の受入](../validation/未確認事項.md#ios背景実行の調査と受入マトリクス) |
| 6 | 圏外の近距離通話 | 通信できる間に相手の登録と鍵の共有を済ませる。セルラーとアクセスポイントを使えない状態で、近距離無線を有効にする。近距離で通話を始め、双方で相手の声を聞く。[圏外通話の条件](../requirements/製品要求.md#利用者に提供すること) |
| 7 | 1対1の呼び出し | 署名、App Info、WorkerでAPNs環境を揃える。Debugはdevelopment署名とsandbox APNs、TestFlightはproductionを使う。OSで通知を許可し、通常通知が1回届くことを確認する。到着時は通話状態を維持する。未接続で通知本体や「接続」を開くと1対1の通話に入る。別の通話中は今の通話が開く。[通常通知の受入](../validation/未確認事項.md#通常通知の受入) |
| 8 | 新しい相手へのグループ招待 | 未登録の相手への招待を名前付きで保存し、OS共有で相手に渡す。相手の登録とグループ保存、署名付き返信と、送り手の返信待ちが消えるところまで確認する。[実環境受入](../validation/未確認事項.md#新規相手招待の実環境受入) |
| 9 | 登録済み相手へのグループ招待の自動送信 | 登録済みの相手と認証済み個別接続で用途別許可を交換し、招待を保存する。送信側のpending→queued、相手の保存後のreceivedを確認する。前面・背景で音やバナーを出さず通知センターに届くこと、通知を開いても現在の通話を維持すること、通知許可がない場合の前面復帰での受取を確認する。同じアカウントの追加端末への転送も試す。[実環境受入](../validation/未確認事項.md#登録済み相手へのグループ自動配送の実環境受入) |

グループ鍵・名前は受取端末の鍵で暗号化する。用途別grantはDEVICE_IDENTITY_SIGNING_KEYで発行する。iOSに預ける送信・取消・受諾の要求全体は、別途、そのWorker宛てに暗号化する。通常のAPNsとUserNotificationsだけを使い、CallKit・VoIP Push・Apple PushToTalk・silent pushの設定を追加しない。

secretは対象の環境を選んで入力する。CLIを使う場合は`server/`へ移動する。今後作成するPreviewの値は`npx wrangler preview base-config secret put SECRET_NAME`で設定する。既存の固定Previewには`npx wrangler preview secret put SECRET_NAME --name preview`を使う。固定Previewへの設定は新しい配置を作る。Productionの`npx wrangler secret put SECRET_NAME`もその場で新しいバージョンを配置する。対象環境と配置するコードを照合し、値は対話入力へ渡す。実値はGit・通常変数・ログへ置かない。[Workersのsecret設定](https://developers.cloudflare.com/workers/configuration/secrets/)、[Previewsの設定](https://developers.cloudflare.com/workers/previews/configuration/)

背景転送の初回設定では、環境ごとに別の値を安全な実行環境で生成し、既存のシークレット保管先と対象環境のSecretへ登録する。その後、端末証明にサービスの公開鍵が含まれ、その接続先で背景要求を受け付けることを試験用端末で確認する。未設定時は通常の認証付き同期を利用できる。区間ごとの鍵の更新は同じ設定値からWorkerが行う。期間をまたいでも、鍵の定期更新を人が操作する必要はない。

登録済み相手への転送は、ローカルWorkerとAppの送受信・ファイル保存・ACKまで[検証済み](../validation/history/招待返信の手動共有.md#登録済みの相手への自動配送をappへ接続2026-11-18)。同じアカウントの追加端末では、個人招待の交換なしで、元の招待と同じグループを保存できることも[ローカルで検証済み](../validation/history/招待返信の手動共有.md#新端末で個人招待を交換せずグループを保存する)。配置後は表の実APNs・実機・実SFUの受入へ進む。

固定Previewを更新する前に、稼働中のバージョンのSFU App IDと対応するSecret、Apple登録・通知・招待の鍵を配置単位で照合する。2026-11-21の固定PreviewのSFU App IDは、Previews Baseと本番のどちらとも異なる。固定Previewで使う組を承認済みの設定から確認し、配置前後に照合する。稼働中のバージョンはWorkers Buildsの対象コミット・結果と、固定Previewの配置の表示を照合する。[確認記録](history/バックログの優先順位と進捗の記録.md#固定previewの開発署名とtestflight向けの配布署名を照合する)

実環境の受入は[最新の配置で確認した試用条件](#最新の配置で確認した試用条件)を参照する。固定Previewの通話は端末証明の鍵の反映とApple登録の有効化から始める。

### 設定が合わないときの戻し方

| 確認点 | 次へ進める状態 | 中断した場合の再開位置 |
|---|---|---|
| 署名と通知環境 | 署名済みAppのTeam・Bundle ID・APNs環境に、対象Workerのtopic・環境・鍵の許可が対応する | 不一致の箇所を直し、同じ署名成果物とWorkerで照合し直す |
| Worker配置 | 対象の配置番号とコードが一致し、6つのDO bindingとv4までのmigrationが揃う | 失敗した配置の記録から未適用分を確認する。既存namespaceと適用済みmigrationを保持して同じ環境から再開する |
| 機能の有効化 | 同じWorkerで端末登録を完了し、通知なら対象端末へ到達、Internet通話なら両端で受話できる | 登録失敗はApple登録の工程、登録成功後の通知失敗はAPNs設定、音声だけの失敗はSFU・必要に応じてTURNから再開する |

Debug端末に届き、TestFlightで届かない場合は、TestFlightの接続先が本番Workerかを先に確認する。次に署名済みAppのentitlement、本番Workerの `APNS_ENVIRONMENT`、topic、鍵が許可する環境をこの順で照合する。対象が一致するまで次の受入へ進めず、鍵を作り直す前に不一致を直す。[署名成果物での確認](OS権限と配布設定.md#生成物での確認)・[AppleのAPNs鍵の環境とtopic](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)

設定変更前に対象の配置番号と変更予定の公開値・secret名を控える。有効化直後に失敗した場合は、その環境で変更したフラグを直前の値へ戻して配置し、他の機能が以前どおり使えるか確認する。秘密値の置換はコードの再配置だけで戻ると想定せず、対象環境用の有効な値を管理元から再登録する。DOのmigrationと保存データは保持する。作業記録には環境、配置番号、成功した段階、次に確認する項目を残す。

## 外部設定の確認状況

### 最新の配置で確認した試用条件

2026-11-21の22時台（JST）に、Cloudflareの読取APIで本番と固定Previewの稼働配置を確認した。設定値は登録の有無・有効状態・環境の一致に変換した。SFU App IDは環境ごとに異なり、対応するSecretが両方の配置にある。

Previews Baseには端末証明とAPNsの鍵がある。固定Previewの稼働配置では両方の鍵が未反映だった。手元と配備用`preview`ブランチの `wrangler.toml` は、どちらも `previews.vars` でApple登録を無効、APNsをsandboxに設定している。稼働配置の同じ項目も一致した。[CloudflareのPreview設定](https://developers.cloudflare.com/workers/previews/configuration/#secrets)

本番の公開ヘルスチェックはHTTP 200で、プロトコル番号が一致した。資格なしの状態取得はHTTP 401で拒否された。稼働配置のSFU App IDとTURN Key IDは、同じアカウントの実リソースと照合した。端末証明とAPNsは設定を確認済み。Appleログイン、双方向受話、APNsの端末到達は試用端末で確認する。

| 試用の条件 | 本番 | 固定Preview |
|---|---|---|
| 端末登録 | Apple登録は有効。端末証明の署名鍵を確認済み | `DEVICE_IDENTITY_SIGNING_KEY` を配置へ反映してから、Apple登録を有効にする |
| 通常通知 | 通知は有効。APNsの鍵とproduction環境を確認済み | 通知フラグは有効で、APNsはsandbox。開発署名の端末で試す前に `APNS_PRIVATE_KEY` を配置へ反映する |
| 招待の背景転送 | `INVITATION_RELAY_KEY_SEED` の反映が残る | `INVITATION_RELAY_KEY_SEED` の反映が残る |
| TURN | 有効化フラグ、資格用ID、Secretを確認済み | 無効。relay経路を試す時点で環境に合う資格を揃える |
| ログとトレース | Observability、ログ、トレース、Workers Logpushは無効 | Observability、ログ、トレース、Workers Logpushは無効 |

ログ・トレースの永続化と呼出ログの個別フラグは両環境で有効と表示された。親のObservabilityとログ・トレースは無効で、転送先とTail consumerは空だった。クエリの除去設定とアカウント全体の転送は今回の観測で未確認。実Apple登録と両端の受話、APNsの端末到達、招待の到着確認は、配置後に対象端末で試す。[試用の順番と合否](#利用者が行うapplecloudflareの設定と受入順)

設定の照合結果は `.validation/security-audit-1900/current-clearance/live-configuration-20261121.json` に保存した。

#### 稼働中のWorkerをGitのコミットと照合する

2026-11-21。Cloudflareの読取APIで、本番は配置中のバージョン1331が全リクエストを処理する設定であり、同じバージョンに紐付いた成功ビルドは `main` の `ecc925f4` と確認した。固定Previewの配置1135は、配置の記録と固定Previewのビルド履歴が `preview` の同じコミットを指していた。[稼働バージョン](https://developers.cloudflare.com/workers/versions-and-deployments/)・[バージョンからビルドを照会するAPI](https://developers.cloudflare.com/api/resources/workers_builds/methods/get_builds_by_version/)

このコミットと全体監査で固定した `f566e6b3` の `wrangler.toml` は一致した。`f566e6b3` には招待・通知処理の整理と依存の更新が追加されている。稼働中の本番で端末証明とproduction APNsのSecret、固定Previewでsandbox APNsとApple登録の無効化を再確認した。固定Previewの端末証明とAPNsのSecretは未反映だった。両環境とも招待を背景で転送するためのSecretは未反映だった。[全体監査の記録](history/バックログの優先順位と進捗の記録.md#2000コミットの全体監査で本番試用の条件を照合する)

`ecc925f4` のWorkerを取り出し、Node.js 26.13.1で型検査とローカルの回帰116件を通した。英大文字を含む一時パスで型lintの2件が失敗したため、小文字のパスで再実行した。Gitとの照合結果は `.validation/security-audit-2000/live-worker-provenance.json` に保存した。TestFlightは本番Workerを使う。双方向の受話、通常通知と招待の到達は実機で確認する。

#### 2026-11-22の稼働配置と手元の差

本番の全トラフィックを処理するバージョンは、`main` の `291b5bac` に紐付くCloudflareの成功ビルドと一致した。固定Previewは、現在の配置時刻が重なる `preview` の成功ビルドが1件で、同じコミットだった。固定Previewでバージョンからビルドを直接引くAPIは対応する結果を返さなかった。手元の `bf44b1e1` と稼働中のコミットで `wrangler.toml` は一致し、手元には背景転送による個人削除や依存の更新がある。両コミットのWorkerを取り出し、Node.js 26.13.1で型検査と回帰を通した。稼働中のWorkerは116件、ローカルmainのWorkerは117件が合格した。[バージョンとビルドの照会](https://developers.cloudflare.com/api/resources/workers_builds/methods/get_builds_by_version/)

両環境の `/health` は200、資格なしの `/api/status` は401だった。本番ではApple登録が有効で、端末証明の鍵とproduction APNsの鍵がある。固定PreviewはApple登録が無効で、sandbox APNsの設定と端末証明・APNsの鍵の未反映を確認した。SFUは別々の設定を使う。背景転送用の鍵は両環境とも未設定で、ロック中の転送を試す前に対象環境への反映が必要となる。

同日にTestFlightの本番設定を再確認した。Build 1988のIPAで本番Workerの接続先、Apple Distribution署名とproduction APNsを照合した。本番のWorker設定と固定Previewの配置1153を手元の `wrangler.toml` と照合し、両環境でAPNs環境とApple登録の有効状態が一致した。固定PreviewでApple登録と通常通知を試すには、対象のPreviewの配置に端末証明とAPNsの鍵を反映し、Apple登録を有効にする。あとからPreviews Baseへ登録した鍵は、作成済みのPreviewに自動で反映されない。[Previews Baseと各Previewの鍵](https://developers.cloudflare.com/workers/previews/configuration/#secrets)・[Build 1988の配布確認](../validation/history/配布ビルド採番とOrganizer認証調査.md#ios-build-1988の本番向けarchiveとipa2026-11-22)

両環境でObservabilityの親設定、ログ、トレース、WorkerのLogpushは無効。TailとObservabilityの転送先は空だった。永続化と呼出ログの個別フラグは有効だった。アカウント全体のWorker Logpushの照会は権限不足で、クエリ除去の設定と過去のログ・バックアップに残るデータも未確認。読み取った結果は `.validation/security-audit-2000/live-worker-20261122/` に保存した。[Cloudflareのログ設定](https://developers.cloudflare.com/workers/observability/logs/workers-logs/)

手元の `wrangler.toml` では、稼働中の設定に合わせてWorkerのObservabilityとLogpushを無効と明示した。Previewには本番と同じ値が適用される。次の配置後は両環境の管理画面でこの二項目と、ログ・トレース、転送先の実効設定を照合する。[Workerの配置仕様](../spec/server/Worker.md#設定値)

#### Cloudflareが保持するWorkerログを件数で照合する

2026-11-22の3時50分（JST）までの7日間を、読み取り専用のSQL APIで確認した。`logs.workersLogs` を `scriptName` で絞り、`rideintercom` と `preview-rideintercom` の各完全一致で件数だけを集計した。両方とも0件だった。このデータセットにはPreview IDと環境を識別する列がないため、結果は照会した名前と期間に限る。ログ本文は取得しなかった。[SQLのログデータセット](https://developers.cloudflare.com/analytics/sql-api/datasets/#log-datasets)・[Workers Logsの保持上限](https://developers.cloudflare.com/workers/observability/logs/workers-logs/#limits)

読み取りAPIで、アカウントのOpenTelemetry転送先、メトリクスのエクスポート設定、Workers Issuesの通知設定はいずれも0件だった。アカウントのWorkers Trace Events用Logpushジョブ一覧は、既存の接続で照会できなかった。この照会では過去の外部転送先・バックアップやクエリ除去の設定は観測していない。証跡は `.validation/security-audit-2000/workers-log-retention/` に保存した。[Logpushの一覧API](https://developers.cloudflare.com/api/resources/logpush/subresources/jobs/methods/list/)

#### Logpushが転送を試みた記録を照合する

2026-10-25の4時から2026-11-22の4時まで（JST）の28日間を、アカウント単位のGraphQL集計で照会した。データセット `logpushHealthAdaptiveGroups` が有効で、参照可能な期間に全範囲が含まれることを確認した。7日ずつ4区間に分け、成功と失敗のどちらも対象にした。どの区間にも転送の試行を示す集計行はなかった。[Logpushの転送状況](https://developers.cloudflare.com/logs/logpush/logpush-health/)・[データセットの参照条件](https://developers.cloudflare.com/analytics/graphql-api/features/discovery/settings/)

この集計で確認できる範囲は対象期間内の記録。アカウントのジョブ一覧には `Logs Write` が必要で、一覧は今回の読み取りの対象外とした。証跡は `.validation/security-audit-2000/logpush-health/` に保存した。[Logpush APIの権限](https://developers.cloudflare.com/logs/logpush/permissions/)

#### 現在のログ転送を読み取り権限内で照合する

2026-11-22。本番と固定Previewの設定を個別に読み取り、Worker単位のLogpush、Observability、ログ、トレースがすべて無効であることを確認した。ログとトレースの転送先およびTail Workerは両環境で0件だった。Cloudflareでは、Workers Trace Eventsの転送にはWorker側の有効化も必要。アカウント単位の集計では、同日10時から14時40分（JST）までに転送を試みた記録は0件だった。[Worker側の有効化条件](https://developers.cloudflare.com/workers/observability/logs/logpush/#enable-logging-on-your-worker)・[Logpushの転送状況](https://developers.cloudflare.com/logs/logpush/alerts-and-analytics/)

アカウント全体とデータセット別のジョブ一覧はどちらも `Logs Write` が必要。既存の接続では、データセット別の一覧もHTTP 403だった。本サービスは本番の運用を始める前で、上記の集計に転送試行はなかった。過去の本番利用者ログの保持は対象外として調査を終了した。本番提供の開始時やログ・転送の有効化時に、読み取れる実効設定を確認する。証跡は `.validation/security-audit-2100/live-log-readback/` に保存した。[ジョブ一覧の権限](https://developers.cloudflare.com/logs/logpush/permissions/)

#### トランクから配置したWorkerのログ設定を読み戻す

2026-11-22。共有 `main` と固定 `preview` の `e3702d42` で、Workers Buildsの本番と固定Previewが各1件成功した。本番は全トラフィックを処理するバージョンとビルドの対応、固定Previewは最新配置のタグで同じコミットを確認した。Wranglerの配置用データと稼働後の管理APIでは次の差があった。

| 確認項目 | 配置設定 | 本番・固定Previewの読み取り結果 |
|---|---|---|
| WorkerのObservabilityとLogpush、ログとトレースの取得 | 無効 | 無効 |
| ログとトレースの転送先 | 0件 | 0件 |
| 呼出ログ、ログ保存、トレース保存 | 無効 | 有効 |
| URLのクエリ除去 | 有効 | 無効 |

固定Previewで上の4項目だけを設定する管理APIの更新はHTTP 403で拒否された。ログ取得は無効だった。ログ取得を始める際は、対象環境で個別設定を照合する。[Workerの設定項目](https://developers.cloudflare.com/api/resources/workers/)

#### SQLiteの復旧範囲を確認する

2026-11-22。本番のWorker設定と固定Previewの最新配置から、各6件のDurable Objectのbindingを名前空間一覧と照合した。12件ともSQLiteで、本番と固定Previewに共用の名前空間はなかった。配置元 `1adc77da` と配布候補 `d4197073` の定義も、両環境で同じ6種類をSQLiteへ割り当てていた。[名前空間の一覧API](https://developers.cloudflare.com/api/go/resources/durable_objects/subresources/namespaces/methods/list/)

Cloudflareの過去時点への復旧（PITR）は、SQLiteのテーブルとキー・値を含め、過去30日以内を復旧対象とする。RideComの削除APIの応答は稼働中の保存と資格の回収を示す。Cloudflareが持つ復旧用データの物理削除まではこの応答で確認できない。[CloudflareのSQLite復旧仕様](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/#pitr-point-in-time-recovery-api)・[RideComの削除契約](../spec/server/Worker.md#アカウントの端末登録削除)

固定した両ソースのWorker、運用スクリプト、GitHub ActionsにSQLiteの復旧APIを呼び出す箇所はなかった。復旧用データの内容と、復旧後に過去の資格を再利用できないことは未確認。アカウント全体のWorkers Trace Events用Logpushジョブ一覧は、既存の接続の権限では今回も取得できなかった。証跡は `.validation/security-audit-2100/sqlite-retention/` に保存した。

稼働用Workerへ過去時点に戻す処理が加わることを防ぐため、通常のコミット時の検査でCloudflareの復旧APIへの参照をエラーにする。[Workerの構文検査](自動検証.md#プログラムのlintと型検査)

##### Workerの配置を戻す場合に保存状態を維持する

CloudflareのWorkerロールバックでは、以前に配置したWorkerバージョンへ切り替え、接続先の保存内容を維持する。ロールバック先の設定・資格・名前空間と、現在の保存形式を読めることを確認する。既に停止した入口や外部送信が古い設定で再開する場合は、その配置を使わない。[Cloudflareのロールバック仕様](https://developers.cloudflare.com/workers/versions-and-deployments/rollbacks/)

2026-11-22。同じローカルSQLiteを維持したままWorkerのコードを更新し、旧版に戻す両方向を試した。削除したアカウントの2端末はセッション照会、通話サービスの状態取得、通知された招待の一覧、招待応答の受付開始で拒否された。有効な別アカウントのセッションと通話サービスの状態取得は成功した。証跡は `.validation/security-audit-2100/worker-code-rollback/` に保存した。

現行の運用で扱うのは、最新の保存状態を維持したWorkerの切替まで。削除前のSQLiteを稼働中の保存へ戻す運用は保留する。その方式を検討するときは、利用者がいない隔離環境で、復旧の影響を受けない失効記録などを使って旧資格を拒否できることを確かめる。通話・通知・招待の入口に加え、復旧で戻った予約やアラームから送信されないことと、削除していないアカウントへの影響を検証する。[アカウント削除の受入条件](../backlog/未実装課題.md#アカウント削除のサービス範囲と別端末への反映)

#### 稼働配置と手元の停止フラグを照合する

2026-11-22。本番Workerの設定と固定Previewの最新配置を管理APIで読み取った。本番のApple登録、通常通知、Internet通話、TURN、端末審査の各フラグは手元の本番設定と一致した。本番のSFUとTURNの参照先は両方とも存在し、通知・端末証明・Apple認可取消の署名鍵も登録済みだった。観測はリソースと鍵の登録の有無に限る。背景転送の鍵は両環境とも未設定だった。[Cloudflareのプレビュー設定](https://developers.cloudflare.com/workers/previews/configuration/)

配置前の固定Previewの `41d1019f` では、`SERVICE_ENABLED` と `NOTIFICATIONS_ENABLED` はどちらも `true` だった。指定されたSFU Appは見つからず、sandbox APNsと端末証明の鍵も配置に含まれていなかった。共有 `main` の `previews.vars` で両方を `false` にし、固定PreviewではInternet通話と通常通知を停止する。配置後は最新配置の2項目を読み戻す。再開時は固定Preview用のSFUと対応する資格、sandbox APNsと端末証明の鍵を同じ配置に揃え、端末登録・双方向通話・通常通知の到達を確認する。[環境別の設定値](../spec/server/Worker.md#設定値)

2026-11-22。停止設定の `1fa64f8f` は本番と固定Previewに配置され、通話・通常通知のフラグは本番で有効、固定Previewで無効と読み戻した。指定のSFU AppとTURN KeyはCloudflareに存在し、Previews Baseでは両方のIDと4点のシークレットの登録を確認した。固定Previewの稼働配置には古いSFU Appの参照があり、TURNの参照とシークレット、sandbox APNs・端末証明の鍵がなかった。両IDを共有 `main` の設定に記載し、対応するシークレットが固定Previewの配置に揃ってから有効化する。

2026-11-22。本番と固定Previewの `a6e827b8` で `/health` はHTTP 200。本番のSFUとTURNの参照先が存在し、シークレットの登録の有無と通話・TURNの有効化を管理APIで確認した。架空の端末IDによるApple登録の開始では、本番がHTTP 200と有効期限内のチャレンジを返し、固定PreviewはHTTP 503を返した。固定PreviewのSFUとTURNの参照は指定値と一致した。既存の試用端末資格2件は認証を通り、通話停止を示すHTTP 503を返した。固定PreviewにTURN・sandbox APNs・端末証明のシークレットを反映し、SFUの組を照合してから実媒体を試す。Appleのサインイン完了、実SFUとTURNを通した双方向音声、TestFlightの端末操作は今回の測定に含めていない。

APNsの環境やトピックを変更する場合は、古い設定で登録した宛先への送信が止まることと、現在の設定で再登録した端末にだけ届くことを確認する。固定Previewの開発署名にはsandbox、本番のTestFlightにはproductionを使う。[APNsの接続先](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)・[送信先を照合する仕様](../spec/server/通知.md#費用悪用を抑える境界)

#### 文書だけのpushがビルドと配置に届くことを確認する

2026-11-22。Workers Buildsのトリガーを読み取った。`main` を対象に含み、ビルドのルートは `server`。変更を監視するパスは `*` の1件で、除外は0件だった。共有 `main` と固定 `preview` の `ab08011f` はバックログの文書2点だけを変更し、前回確認した固定Previewの `1adc77da` から `server` の変更はなかった。このコミットを使う本番向けと固定Previewのビルドは各1件が成功した。[Workers Buildsの監視パス](https://developers.cloudflare.com/workers/ci-cd/builds/build-watch-paths/)

固定Previewの最新配置が `ab08011f` に一致した。通話と通常通知の稼働フラグはどちらも有効のままだった。本番では単一のバージョンに100%を配分していることまでは確認したが、このビルドとの対応は確認できなかった。文書だけのpushでも固定Previewは配置を更新する。送信前の監査では文書の差分と、送信した履歴で自動配置され得るWorkerを照合する。証跡は `.validation/security-audit-2100/docs-push-build-boundary/` に保存した。[監査で保留する操作](history/バックログの優先順位と進捗の記録.md#進行中の全体監査の引き継ぎ)

### 過去の配置の確認記録

2026-11-19、Cloudflareの読取APIで、Productionの`rideintercom`と固定`preview`の配置番号382を確認した。表はその時点の公開値・binding・secret名を示す。端末鍵索引のv4以降の実配置、Previews Baseの現在値、配置ソースとGitの一致、Appleの実署名・端末許可、実APNsと実SFUは引き続き受入対象。

| 項目 | Production | 固定Preview |
|---|---|---|
| APNsとAppleの公開値 | APNS_ENVIRONMENTはproduction。APNS_TOPICとAPPLE_CLIENT_IDはApp IDと一致 | APNS_ENVIRONMENTはsandbox。APNS_TOPICとAPPLE_CLIENT_IDは同じApp ID |
| Durable Objects | 5 binding、migration v3 | 5 binding、migration v3 |
| 現在の設定 | Apple登録、SFU、TURN、APNsのProduction用ID Variableと認証Secretを登録済み | APNsのKey ID・共通Team IDを`previews.vars`、`APNS_PRIVATE_KEY`を固定PreviewのSecretへ登録済み。環境はsandbox |
| Apple・通知で残る設定 | Apple登録と通知は有効。実Apple登録とAPNsを通じた通知の送受信を受け入れる。期限付きclient-secret JWTは登録しない | 再配置後のSecret bindingとAPNsを通じた通知の送受信を受け入れる |
| SFUで残る設定 | SERVICE_ENABLEDとTURN_ENABLEDはtrue。実SFUとrelay経路の双方向音声を受け入れる | SERVICE_ENABLEDはtrue。登録済み設定で実SFUを通る双方向音声を受け入れる |
| 現在の有効化フラグ | APPLE_AUTH_ENABLED・NOTIFICATIONS_ENABLED・SERVICE_ENABLED・TURN_ENABLEDはtrue。DEVICE_ATTESTATION_ENABLEDはfalse | NOTIFICATIONS_ENABLED・SERVICE_ENABLEDはtrue。APPLE_AUTH_ENABLED・TURN_ENABLED・DEVICE_ATTESTATION_ENABLEDはfalse |

Apple登録と通知は鍵・プロフィール・APNsの環境を揃えてから、対象環境でAPPLE_AUTH_ENABLEDとNOTIFICATIONS_ENABLEDを有効にする。

2026-11-21、現行のProductionと固定Previewを含む3つのPreviewを読取APIで再確認した。全環境で `TURN_ENABLED=false` だった。`CLOUDFLARE_TURN_KEY_ID` と `CLOUDFLARE_TURN_API_TOKEN` のbindingなしを確認した。用途不明のTURN key `lively-bar-4bf6`（ID `17dfb79b3f05d349aa02155b021a49f5`）は未参照と判断して削除した。新しいPreview／Production用keyは未作成であり、上記の取得・保存順を満たすときに別々に作成する。

照合結果は `.validation/notification-cloudflare-state-20261119/settings.json` に保存した。Worker管理APIは読取だけを実行した。[検証記録](../validation/history/Cloudflare検証.md#productionと固定previewの読取2026-11-19)
