# WebRTCビルドスクリプト

## 目的

RideComで使用するnative WebRTC SDKの `WebRTC.xcframework` を、`webrtc.googlesource.com/src` から自前ビルドするためのスクリプト群を定義する。

WebRTC本体とChromium依存ソースは巨大なため、`RideIntercom` repositoryには含めない。checkout、build output、SwiftPM artifactは明確に分離し、検証済みの `WebRTC.xcframework` またはzipだけをbinary targetの入力として扱う。

## スクリプト一覧

| スクリプト | 用途 | 通常実行 |
|---|---|---|
| `scripts/BuildWebRTC/update-webrtc-binary.sh` | branch解決、fetch/sync/build、隔離したRTC packageで検証・テスト、成功後の取り込みを一括実行する | 通常はこれだけを使う |
| `scripts/BuildWebRTC/doctor-webrtc-binary.sh` | 現在のWebRTC build/import状態を診断し、次に実行する具体コマンドを表示する | 失敗したら最初に使う |
| `scripts/BuildWebRTC/resolve-webrtc-branch.sh` | Chromium Dashboardからstable milestoneのWebRTC branch-headを取得する | 直接実行またはbuild scriptから自動実行する |
| `scripts/BuildWebRTC/build-current-webrtc-xcframework.sh` | 現在stableのWebRTC branchを自動取得して `WebRTC.xcframework` をビルドする | 上位スクリプトが内部で使う。buildだけを確認したい場合に使う |
| `scripts/BuildWebRTC/build-webrtc-xcframework.sh` | 指定されたbranch、platform、deployment targetでビルドする | 上位スクリプトが内部で使う。branchやplatformを固定したい場合に使う |
| `scripts/BuildWebRTC/verify-webrtc-xcframework.sh` | Info.plist、実バイナリのarchitecture、必須platform、iOS実機dSYMのUUID、public headersを検証する | 上位スクリプトが内部で使う。成果物だけを検証したい場合に使う |
| `scripts/BuildWebRTC/import-webrtc-xcframework.sh` | 検証済みzipをRTC package配下のbinary target入力へ取り込む | 上位スクリプトが内部で使う。既存zipだけを取り込み直す場合に使う |
| `scripts/BuildWebRTC/import_webrtc_artifact.py` | 同一filesystemでzipとmetadataを準備・検証し、directory単位で採用する | import shellから内部呼び出し。利用者の追加操作は不要 |
| `scripts/BuildWebRTC/webrtc_provenance.py` | 新規ビルドのupstreamのコミットとビルドツールのバージョン、対象別のGN設定とZIPの照合値を記録・検証する | buildとimportから内部呼び出し |
| `scripts/BuildWebRTC/clean-webrtc-build-resources.sh` | WebRTC build output、SwiftPM artifact、source checkoutを削除する | build後の容量整理に使う |

## 前提

| 項目 | 標準値 | 説明 |
|---|---|---|
| depot_tools | `../depot_tools` | repository親ディレクトリから見た既定位置。`fetch`、`gclient`、`gn`、`ninja` を提供する |
| WebRTC build root | `../webrtc-build` | repository親ディレクトリから見た既定位置。WebRTC source checkoutとbuild outputを置く |
| `RideIntercom` repository | current directory | スクリプトと仕様ドキュメントだけを置く |
| Xcode | `xcode-select -p` | 必要な場合だけ `DEVELOPER_DIR` で上書きする |
| Python | macOSの `/usr/bin/python3`（3.9以降） | ビルド情報の記録とZIPの取り込みに使う |

## 通常運用

WebRTC binaryを更新する通常手順は次の1コマンドだけとする。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/update-webrtc-binary.sh
```

このスクリプトは次の処理を順番に実行する。

| 順序 | 処理 | 失敗時の扱い |
|---|---|---|
| branch解決 | `WEBRTC_BRANCH` 未指定時にstable branch-headを取得する | 取得不能なら `WEBRTC_BRANCH=branch-heads/<number>` の指定を案内する |
| source取得 | `WEBRTC_BUILD_ROOT/src` がなければ `fetch --nohooks webrtc_ios` から開始する | `depot_tools` 不備なら設定値を案内する |
| sync/build | cleanなsourceをbranchへ切替え、`gclient sync`、`gn gen`、`ninja` でiOS/macOS sliceをビルドする | 中断する。旧出力の自動再組み立てで成功に置き換えない |
| 成果物検証 | Info.plistと実バイナリのarchitecture、必須slice、iOS実機dSYMのUUID、`WebRTC.h` のimport先を検証する | 欠落があれば採用しない。空のdirectoryも失敗 |
| 隔離取り込み | 一時directoryへRTC packageをコピーし、候補zipを取り込む | repository内の採用済みzipとmetadataは維持 |
| SwiftPM検証 | 一時packageで `RTCNativeWebRTC` をビルドする | 失敗時は旧成果物を維持 |
| テスト | 一時packageで `RTC` testsを実行する | 失敗時は旧成果物を維持 |
| 採用 | 採用先と同じfilesystemの隣接一時directoryへコピーし、そのコピーを検証する。SHA-256・日時を含むmetadataと一緒にdirectory単位で交換する | コピー・検証・metadata作成・交換の失敗では採用済みpairを維持。正常終了時は所有する一時pairだけを回収 |

通常の更新でsource checkoutや`out`全体を削除しない。tracked source変更があるcheckoutでは停止する。手動の `ASSEMBLE_ONLY` は残すが、更新処理の自動fallbackには使わない。異なるbranchの古い成果物を新branchとして採用することを避ける。

### TestFlightと公開版には本番用WebRTCを使う

次のTestFlightビルドから、内部・外部テストとApp Storeなどの公開配布には、本番用にビルドしたWebRTCだけを同梱する。現行スクリプトではWebRTCのビルドに `DEBUG=false` を指定し、配布に使うすべての構成の `args.gn` で `is_debug=false` を確認する。

自動テスト専用の成果物には、開発用にビルドしたWebRTCも使える。現行スクリプトでは `DEBUG=true` が開発用ビルドに当たる。自動テストの成果物を配布に使う場合は、配布用WebRTCの条件を確認する。

Archiveから書き出した配布物のWebRTCを、取り込み時のZIPとビルド記録に照合する。アプリ本体のRelease設定とは別に、WebRTC自体のビルド設定を確かめる。開発用のWebRTCが入っている場合や、対応するビルド記録を確認できない場合は送信を止め、本番用のWebRTCでArchiveを作り直す。

### 上流の無改変とカメラの不使用

RideComは音声通話に使うWebRTCを、カメラ撮影の実装とその専用依存をビルド対象から外して配布する。採用する上流コミットを固定し、公式のGN引数とターゲットで必要な部品を選ぶ。上流のソース、ビルド定義、依存部品への独自パッチは禁止する。

映像コーデックを無効にしても撮影の依存が残る場合は、カメラを含まない公式ターゲットを試し、既存のSwift呼出元からDataChannelを使えることを確かめる。公式の構成で両立できない場合は候補の採用を保留し、残る依存と試した構成、通話への影響を示して依頼者に判断を求める。[公式ターゲットの依存を比較した記録](../../validation/history/配布ビルド採番とOrganizer認証調査.md#webrtcの標準ターゲットに含まれるカメラ依存を確かめる)

SDK更新時はiOS実機・Simulator・macOSの各構成でGNの依存と生成バイナリを照合し、撮影実装とカメラAPIへの参照が除かれたことを確認する。公開ヘッダーに残る型名は、撮影実装のリンクやカメラAPIの呼び出しと区別する。RTCの接続試験では音声・映像トラックを含む入力の拒否とDataChannelの通過を確認し、双方向音声と経路切替を回帰テストで確かめる。配布前には署名済みRelease Archiveと書き出した配布物のApp・同梱SDKを照合し、撮影APIの参照とカメラ権限の要求がないことを確認する。[配布時の確認手順](../OS権限と配布設定.md#生成物での確認)

過去のZIPには撮影機能を外すパッチを使った記録がある。[現在のZIP](#現行sdkとの組合せ)の由来と、上記の条件を満たすかの検証結果は別々に記録する。

固定branchで再現する場合も、上位スクリプトに `WEBRTC_BRANCH` を渡す。

```bash
cd <RideIntercom repository>
WEBRTC_BRANCH=branch-heads/7727 \
scripts/BuildWebRTC/update-webrtc-binary.sh
```

### C++の公式ターゲットに必要なリンク入力を確認する

カメラを使わない候補では、上流の `//api:create_modular_peer_connection_factory` を使う。GNで生成済みの構成を1つ指定すると、次のコマンドがNinjaの依存関係からリンクに必要なパスを列挙する。

```bash
python3 scripts/BuildWebRTC/webrtc_modular_link_inputs.py \
  "${WEBRTC_BUILD_ROOT:-../webrtc-build}/src/out/ios-arm64-device" \
  --ninja "${DEPOT_TOOLS_DIR:-../depot_tools}/ninja"
```

出力の各行は、指定した構成のディレクトリを基準としたリンカー入力。アーカイブに含まれるオブジェクトと、単独でリンクするオブジェクトを二重に数えない。既知のカメラ依存や通常のObjective-C frameworkが対象に入る場合は、一覧を出力せずに失敗する。

このコマンドは依存を読み取る。コンパイルや採用済みXCFrameworkの更新は行わない。候補を組み立てた後は、全構成でカメラ参照をバイナリから検査する。最終のArchive・IPAでは既存の送信前検査も通す。[試作の実行と検査](../../validation/history/配布ビルド採番とOrganizer認証調査.md#撮影を含まないwebrtcのcターゲットでdatachannelを試す)

#### C++の接続部を動的ライブラリにする

候補をリンクするときは、上流のcheckoutと対象構成のGN出力を指定する。RideCom側のC++ソースと、生成する `.dylib` のパスも指定する。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 scripts/BuildWebRTC/build_webrtc_modular_library.py \
  "$webrtc_source" "$gn_output" "$adapter_source" "$output_dylib"
```

コマンドは上流の追跡ファイルに変更がないことを確かめる。Ninjaに渡す対象をC++ファクトリーの依存に絞る。RideCom側のC++ソースにはGNが生成したコンパイル設定を使う。ビルド経路に既知のカメラ依存がある場合や、リンク後に撮影クラスへの参照を検出した場合は失敗する。検査を通過したライブラリだけを指定先に置く。

#### C++候補の接続とチャネルの作成・終了を確認する

接続部のソースは `RideIntercom/packages/RTC/BuildSupport/ModularWebRTC/RideComRTC.cc`。CのヘッダーをSwiftから読み込める。Swiftからファクトリー、PeerConnection、IDを指定したDataChannelを作成する。制御チャネルは順序付きで、データを再送する。音声チャネルは順不同・再送なしで転送する。

Swift側は取得したハンドルを一度だけ解放する。同じハンドルの解放と別の操作を同時に呼ばない。ファクトリーのハンドルを解放した後も、作成済みの接続を利用できる。接続の解放でその配下のチャネルが閉じる。チャネルのハンドルは接続の解放後も解放できる。

macOS向けの出力名は `libRideComRTC.dylib` とし、出力したディレクトリでSwiftの検証プログラムを動かす。同一プロセスでチャネルの作成、無効なIDと重複IDの拒否、解放の順序を確かめる。

```bash
adapter_dir="$PWD/RideIntercom/packages/RTC/BuildSupport/ModularWebRTC"
library_dir="$(dirname "$output_dylib")"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc -swift-version 6 -I "$adapter_dir/include" -L "$library_dir" -lRideComRTC \
  -Xlinker -rpath -Xlinker @executable_path \
  "$adapter_dir/check_lifecycle.swift" -o "$library_dir/check-lifecycle"
"$library_dir/check-lifecycle"
```

この手順は候補の接続部を検証する。採用済みのAppでは、同梱WebRTCのObjective-C APIを使う。[現行SDKとの組合せ](#現行sdkとの組合せ)

#### C++候補でDataChannel専用のSDPを交渉する

ローカルSDPの作成を求めると、現時点の交渉状態に応じてofferかanswerを作成する。候補の収集状態を確認し、収集した候補を含むローカルSDPをコピーできる。呼出元はコピーした文字列を専用の関数で解放する。

受け取ったSDPには媒体行が1つ以上必要で、すべての媒体行を `m=application` に限る。条件を満たさないSDPは接続部で拒否し、SDKの交渉状態を保つ。SDKがローカルまたはリモートのSDPを処理した結果は、呼出元の関数へ一度返す。結果を受け取る関数から接続部を呼び直さない。[媒体とSDPの契約](../../spec/packages/RTC.md#cloudflareの媒体契約)

前節のSwiftのビルド手順で `check_negotiation.swift` を指定する。Mac上の2つの接続で、音声・映像付きSDPの拒否後に正常なofferとanswerが通ることを確かめる。offerの作成を始めてすぐに接続を解放した場合も、Swiftが完了を受け取ることを確かめる。

## 失敗時の入口

失敗時に手作業で原因を選ばない。まず診断スクリプトを実行する。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/doctor-webrtc-binary.sh
```

診断スクリプトは次を確認し、不足があれば `NEXT:` として次の具体コマンドを表示する。

| 確認 | 判断 |
|---|---|
| Xcode Developer directory | `DEVELOPER_DIR` がXcode本体を向いているか |
| depot_tools | `gclient` と `fetch` が存在するか |
| branch解決 | Chromium Dashboardからstable branchを取れるか |
| source checkout | `../webrtc-build/src` があるか |
| build output | iOS device、iOS simulator、macOS x64、macOS arm64のframeworkがあるか |
| xcframework | header検証に通る `WebRTC.xcframework` があるか |
| zip | `WebRTC-<branch>.xcframework.zip` があるか |
| 採用済みの組 | RTC package配下のZIPと採用記録があり、記録のSHA-256がZIPと一致するか |
| SwiftPM build | `RTCNativeWebRTC` がimport済みbinaryでビルドできるか |

ZIPと採用記録が揃わない場合は診断が失敗する。同じ採用時に生成した組を使う。診断と通常の自動検証は同じ処理でSHA-256を照合する。SwiftPMのビルドだけを省略する場合は、次のコマンドを使う。

```bash
cd <RideIntercom repository>
RUN_SWIFTPM_CHECK=false scripts/BuildWebRTC/doctor-webrtc-binary.sh
```

## 通常ビルド

`scripts/BuildWebRTC/build-current-webrtc-xcframework.sh` は下位スクリプトである。通常は `scripts/BuildWebRTC/update-webrtc-binary.sh` を使う。buildだけをやり直したい場合に限り、現在stableのWebRTC branch-headを自動取得して、iOS device、iOS simulator、macOSのsliceをビルドする。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/build-current-webrtc-xcframework.sh
```

出力先は次の通りとする。

| 出力 | パス |
|---|---|
| xcframework | `../webrtc-build/src/out/WebRTC.xcframework` |
| zip | `../webrtc-build/src/out/WebRTC-<branch>.xcframework.zip` |
| checksum | build scriptの最後に表示される `shasum -a 256` の値 |

## プロジェクトへの取り込み

`scripts/BuildWebRTC/import-webrtc-xcframework.sh` は下位スクリプトである。通常は `scripts/BuildWebRTC/update-webrtc-binary.sh` から自動実行される。検証済みzipだけをRTC package配下へ取り込む。WebRTC source checkoutとbuild outputはrepositoryへ入れない。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/import-webrtc-xcframework.sh
```

取り込み先は次の通りとする。

| 出力 | パス |
|---|---|
| binary target zip | `RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip` |
| metadata | `RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.metadata` |

### 取り込みの中断と復帰

| 条件 | 動作 |
|---|---|
| 既存成果物の更新 | macOSの`renamex_np(RENAME_SWAP)`でdirectoryを1回交換する。固定pathに旧zipと新metadataだけが残るような2段階の更新は避ける |
| 初回取り込み | `RENAME_EXCL`でdirectoryごと配置する。同時に別の取り込みが成立していれば上書きせず失敗する |
| filesystemが交換非対応・容量不足・コピー／検証失敗 | delete／moveによる代替更新を行わず停止する。採用済みzip・metadataを保持する |
| コピー元が後から変更された場合 | 取り込み用にコピーしたbytesを検証・hash化する。検証後にコピー元を読み直して採用しない |
| プロセスが交換前後に強制終了 | 固定の採用先には旧pairまたは新pairが残る。残った`.WebRTC.import-*`は候補として自動採用せず、次の取り込みを妨げない |
| 採用先がsymlink、または採用先に無関係なファイルがある | 事前と採用直前に検査し、既存内容を保持して停止する。検査直後の変更が交換後に旧directory側へ移った場合も、未知fileは再帰削除せず保存場所を表示する |
| 残留一時directory | 通常終了時は既知のzip／metadataと空directoryだけを回収する。強制終了後の残留物は実行中の取り込みがないことと内容を確認してから整理する |

これはプロセス中断と公開操作の整合性であり、電源断・媒体障害の耐久性や、別processが交換をまたいで2ファイルを個別に開く一連の読取りまでtransactionにする保証ではない。常設の履歴・復旧台帳・採用先symlinkは追加しない。

共有するSDKは、個人名を含まない作業パスでビルドする。既存の `WEBRTC_BUILD_ROOT` で作業場所を指定できる。取り込みはコピー済みのZIPを検査し、dSYMに個人のホームパスがあれば中止する。検出したパスは表示せず、採用済みのZIPと記録を保つ。

新規ビルドは、upstreamとdepot_toolsの完全なcommit、GN・Xcode・各SDKのバージョンを `.provenance.json` に記録する。同じファイルに、無改変のビルドであることと、各sliceの`args.gn`、生成したZIPのSHA-256も記録する。ビルド中にcheckoutやdepot_toolsのcommitが変わると更新を中止する。取り込みはコピーしたZIPを検証し、SHA-256と一致する記録を `WebRTC.xcframework.metadata` の `build_provenance` に移す。新しく取り込むZIPに無改変のビルド記録がない場合や、SHA-256が一致しない場合は、採用済みZIPとmetadataを維持する。`ASSEMBLE_ONLY=true` と既存ZIPの手動取り込みでは新規ビルドの記録を後付けしない。

特定のzipを取り込む場合は `WEBRTC_XCFRAMEWORK_ZIP` を指定する。

```bash
cd <RideIntercom repository>
WEBRTC_XCFRAMEWORK_ZIP=../webrtc-build/src/out/WebRTC-branch-heads-7727.xcframework.zip \
scripts/BuildWebRTC/import-webrtc-xcframework.sh
```

この方式の採用により、`RideIntercom/packages/RTC/Package.swift` は外部配布packageではなく、package内のlocal binary target `WebRTC` を参照する。

## branch固定ビルド

`scripts/BuildWebRTC/build-webrtc-xcframework.sh` は下位スクリプトである。特定のWebRTC branch-headでbuildだけを再現する場合は `WEBRTC_BRANCH` を明示する。

```bash
cd <RideIntercom repository>
WEBRTC_BRANCH=branch-heads/7727 \
scripts/BuildWebRTC/build-webrtc-xcframework.sh
```

`WEBRTC_BRANCH` を指定しない場合、`scripts/BuildWebRTC/build-webrtc-xcframework.sh` は `scripts/BuildWebRTC/resolve-webrtc-branch.sh` を呼び出してstable branch-headを取得する。

## platform指定

Appに採用する成果物はiOS device、iOS Simulator、macOSの全sliceを必須とする。`IOS`、`MACOS` はビルド対象を制御するが、片方だけの成果物は最終検証・取り込みには合格しない。

各構成は共通の手順で `gn gen`、GN設定の記録、`ninja` の順に実行する。OSごとの関数は、CPU・OSバージョン・ビルド対象を渡す。iOSでは実機とSimulatorの区別も渡し、実機向けだけにdSYMの生成を指定する。設定の生成や記録に失敗した構成はビルドを始めず、後続の構成と組み立ても止める。

全構成で `rtc_enable_protobuf=false` を指定し、SDKのイベントログをProtobufで出力する機能を外す。通話の接続と音声パケットの転送は、[RTCの媒体契約](../../spec/packages/RTC.md#cloudflareの媒体契約)に従う。映像 API の同梱は[上流の無改変とカメラの不使用](#上流の無改変とカメラの不使用)に従って判断する。

```bash
cd <RideIntercom repository>
IOS=true \
MACOS=true \
scripts/BuildWebRTC/build-current-webrtc-xcframework.sh
```

| 変数 | 標準値 | 対象 |
|---|---|---|
| `IOS` | `true` | iOS deviceとiOS simulator |
| `MACOS` | `true` | macOS universal binary |
| `ASSEMBLE_ONLY` | `false` | `true` の場合は既存の `src/out/*/WebRTC.framework` からxcframeworkとzipだけを作る |
| `RUN_SWIFTPM_VALIDATION` | `true` | `scripts/BuildWebRTC/update-webrtc-binary.sh` 用。`false` の場合は `RTCNativeWebRTC` build検証を省略する |
| `RUN_TESTS` | `true` | `scripts/BuildWebRTC/update-webrtc-binary.sh` 用。`false` の場合はRTC package testsを省略する |
| `IOS_DEPLOYMENT_TARGET` | `27.0` | iOS sliceのdeployment target |
| `MACOS_DEPLOYMENT_TARGET` | `27.0` | macOS sliceのdeployment target |

## 既存成果物からの再組み立て

途中で失敗し、iOS / macOSの `WebRTC.framework` が生成済みの場合は、再コンパイルせずにxcframeworkだけを組み立て直せる。

```bash
cd <RideIntercom repository>
ASSEMBLE_ONLY=true \
IOS=true \
MACOS=true \
scripts/BuildWebRTC/build-webrtc-xcframework.sh
```

この指定では `fetch`、`gclient sync`、`gn gen`、`ninja` を実行しない。既存の `../webrtc-build/src/out/*/WebRTC.framework` とiOS実機用の `ios-arm64-device/WebRTC.dSYM` を入力にする。dSYMがない旧出力は再組み立てだけでは修復できないため、同じsource revisionからiOS実機sliceを再ビルドする。

## iOSとmacOSの差分

| platform | WebRTC build target | framework構造 | スクリプトでの扱い |
|---|---|---|---|
| iOS device | `framework_objc` | `WebRTC.framework/Headers` | arm64 device sliceとしてxcframeworkへ追加する |
| iOS simulator | `framework_objc` | `WebRTC.framework/Headers` | x86_64とarm64を `lipo` で統合する |
| macOS | `mac_framework_objc` | `WebRTC.framework/Versions/A/Headers` | x86_64とarm64を `lipo` で統合する |

macOS sliceでは、配布済みbinaryと同様にpublic headersを欠く場合がある。`scripts/BuildWebRTC/build-webrtc-xcframework.sh` はmacOSの `gen/sdk/WebRTC.framework/Headers` を優先してpublic headersを補完し、`gen/sdk` が存在しない場合のみiOS device sliceをfallbackとして使う。その後 `scripts/BuildWebRTC/verify-webrtc-xcframework.sh` で必須headerと `WebRTC.h` がimportするheaderの存在を検証する。

## iOS配布用デバッグシンボル

iOS実機sliceは `enable_dsyms=true` でビルドする。生成された `WebRTC.dSYM` をxcframework内の `ios-arm64/dSYMs/WebRTC.framework.dSYM` へ同梱し、Info.plistの `DebugSymbolsPath` に `dSYMs` を登録する。XcodeがArchiveへコピーできる形でbinaryと一体管理する。SimulatorとmacOSのdSYM同梱は今回のiOS配布修復の対象外とする。

検証スクリプトはiOS実機dSYMの宣言・DWARFファイル・binaryとのUUID/architecture一致を必須とする。別sliceのファイルや空の代用品では通らない。AppのArchiveでも `dSYMs/WebRTC.framework.dSYM` が存在し、App内のWebRTC.frameworkとUUIDが一致することを確認する。再ビルド前のArchiveには新しいdSYMを流用せず、新Archiveを配布する。

## SDKプライバシーマニフェストの配置

| 対象 | 配置と扱い |
|---|---|
| iOS device / Simulator | `WebRTC.framework/PrivacyInfo.xcprivacy`を通常ファイルとして必須にする |
| macOS | `Versions/A/Resources/PrivacyInfo.xcprivacy`を必須にし、framework直下の`Resources`から同じ場所へ到達することを確認する |
| 組み立て時 | 既知のGN出力`Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy`だけを組み立て先で移動する。全sliceを先に検査し、既に正しい配置なら変更しない。元checkout・個別build出力・manifestのbytes・Mach-O・dSYMは変更しない |
| 自動修復しない状態 | manifest重複、欠損、壊れたplist、既知fieldの型違い、外部・循環・壊れたsymlink、resource sealを持つMac frameworkはエラーにする。未知の配置を推測して修復しない |
| 検証・取り込み | `verify-webrtc-xcframework.sh`が`webrtc_privacy.py`で配置を検査する。importは同じ検査に成功してからZIPとmetadataを更新し、失敗時はインストール済みartifactを保持する。verify/import自身は修復しない |

plist検査はリソースの形式確認であり、Appleの理由コード審査や最終Archiveのprivacy reportの代わりにはならない。Macで既知の配置ミスを直す際は再コンパイル・再署名を伴わず、元の署名状態を保持する。[修正と検証の記録](../../validation/history/WebRTCマニフェスト配置の修正.md)を参照する。

## 成果物検証

build後、binary targetへ差し替える前に必ず検証する。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/verify-webrtc-xcframework.sh \
  ../webrtc-build/src/out/WebRTC.xcframework
```

検証対象headerは次の通りとする。

| header |
|---|
| `WebRTC.h` |
| `RTCAudioSource.h` |
| `RTCAudioTrack.h` |
| `RTCConfiguration.h` |
| `RTCDataChannel.h` |
| `RTCDataChannelConfiguration.h` |
| `RTCIceCandidate.h` |
| `RTCIceServer.h` |
| `RTCMediaConstraints.h` |
| `RTCPeerConnection.h` |
| `RTCPeerConnectionFactory.h` |
| `RTCSessionDescription.h` |

## 後片付け

標準ではdry-runで削除対象だけを表示する。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/clean-webrtc-build-resources.sh
```

実際に削除する場合は `DRY_RUN=false` を明示する。

```bash
cd <RideIntercom repository>
DRY_RUN=false scripts/BuildWebRTC/clean-webrtc-build-resources.sh
```

| `CLEAN_MODE` | 削除対象 | 用途 |
|---|---|---|
| `build-output` | `../webrtc-build/src/out` | build outputだけを消し、source checkoutは残す |
| `swiftpm` | `RideIntercom/packages/RTC/.build/workspace-state.json`、`RideIntercom/packages/RTC/.build/artifacts/rtc/WebRTC`、`RideIntercom/packages/RTC/.build/artifacts/extract/rtc`、debug用 `WebRTC.framework`、WebRTC adapter build output、WebRTC関連の旧 `checkouts`、WebRTC関連の旧 `repositories` | SwiftPMが展開したWebRTC binary artifact、古い解決状態、旧remote package cacheを消す |
| `source` | `../webrtc-build` | WebRTC source checkout全体を消す |
| `all` | 上記すべて | ディスク容量を大きく空ける |

通常は `build-output` の削除に留める。source checkoutを残すと、次回は `gclient sync` と差分buildで済む可能性が高い。

## よくある確認

| 確認 | コマンド | 期待 |
|---|---|---|
| depot_tools確認 | `../depot_tools/gclient --version` | `gclient.py` のusageが表示される |
| branch自動解決 | `scripts/BuildWebRTC/resolve-webrtc-branch.sh` | `branch-heads/<number>` が表示される |
| shell構文確認 | `bash -n scripts/BuildWebRTC/build-webrtc-xcframework.sh` | 出力なしで終了する |
| 既存artifact検証 | `scripts/BuildWebRTC/verify-webrtc-xcframework.sh <WebRTC.xcframework>` | header欠落があれば失敗する |
| zipの作り直し | `scripts/BuildWebRTC/build-webrtc-xcframework.sh` | 既存zipを削除してから作成し、削除済みheaderがarchiveに残らない |

## 失敗時の判断

手作業でこの表から選ぶ前に、必ず `scripts/BuildWebRTC/doctor-webrtc-binary.sh` を実行する。表は診断結果の背景説明として使う。

| 症状 | 原因候補 | 対応 |
|---|---|---|
| `depot_tools was not found` | `DEPOT_TOOLS_DIR` が違う | `DEPOT_TOOLS_DIR=/path/to/depot_tools` を指定する |
| `failed to resolve current WebRTC branch` | Chromium Dashboardへ到達できない | `WEBRTC_BRANCH=branch-heads/<number>` を明示する |
| `RTCAudioSource.h file not found` | macOS sliceのpublic headers不足 | build後に `verify-webrtc-xcframework.sh` を実行し、不足が残る場合は成果物を採用しない |
| `gn gen` / `ninja` が失敗 | WebRTC branchとXcode/SDKの組み合わせ不整合 | branchを固定するか、対応するXcodeを `DEVELOPER_DIR` で指定する |
| ディスク容量不足 | WebRTC source treeまたはbuild outputが大きい | `clean-webrtc-build-resources.sh` で `build-output` または `source` を削除する |

## 採用条件

| 条件 | 完了基準 |
|---|---|
| build成功 | `WebRTC.xcframework` とzipが生成される |
| header検証成功 | `verify-webrtc-xcframework.sh` が成功する |
| checksum記録 | zipのSHA-256をbinary target更新時に記録する |
| repository保護 | WebRTC source treeと巨大なbuild outputをcommitしない |

## 取り込み方式の判断

| 方式 | 利点 | 注意点 |
|---|---|---|
| zipをrepositoryに含める | checkout後すぐにSwiftPMで解決できる。外部配布URLが不要 | dSYMを含むzip全体がGit repositoryへ追加される。更新のたびにbinary diffではなくzip全体が履歴に残る |
| zipをrelease等へ置く | repository本体を軽く保てる。SwiftPM checksumで固定できる | private配布、URL管理、checksum更新の運用が必要 |
| xcframework directoryをrepositoryに含める | 中身を直接確認しやすい | ファイル数が多く、symlinkやframework構造の差分管理が重い |

iOS実機dSYMの同梱でzip容量が増えるため、更新ごとに実サイズを確認する。更新頻度が上がる、またはartifactが大きくなる場合はrelease配布へ移す。
## 更新処理の回帰テスト

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -m unittest discover -s scripts/tests -v
```

| ケース | 確認 |
|---|---|
| 空のxcframework | headersが見つからないまま成功にしない |
| iOS実機dSYMの欠落・UUID不一致 | 宣言の欠落、DWARF欠落、別sliceのUUIDをそれぞれ拒否する |
| candidateのSwiftPM検証失敗 | 採用済みzipとmetadataが変わらない |

resolverはOSの証明書ストアを利用するcurlで公式Chromium Dashboardへアクセスする。証明書検証を無効化しない。
worktreeが通常checkoutと異なる場所にある場合は `DEPOT_TOOLS_DIR` と `WEBRTC_BUILD_ROOT` を明示する。

## 現行SDKとの組合せ

| 項目 | 採用内容 |
|---|---|
| 確認日 | 2026-11-23 |
| WebRTCのコミット | `f0b51cdb2fd2df5a44c2f05ccc3dc41f5f429362` |
| XcodeとSDK | Xcode 27.2（27B52）。iOS実機・iOS Simulator・macOSのSDKはいずれも27.2 |
| GN設定 | 全構成で `is_debug=false`。WebRTC本体の `treat_warnings_as_errors=false` と、イベントログのProtobufを外す `rtc_enable_protobuf=false` を指定する |
| 成果物 | iOS arm64、iOS Simulator arm64/x86_64、macOS arm64/x86_64 |
| 採用時の検証 | 5構成の実行ファイル、公開ヘッダー、プライバシーマニフェストとiOS実機用dSYMを照合。共有側のRTC回帰148件とSwift・Workerの通信試験1件が通過。iPhone Simulatorの試験で両方向98/98フレームが一致した |
| チェックサムとビルド情報 | ZIPと同じディレクトリの `WebRTC.xcframework.metadata`。上流コミット、depot_tools、GNとSDK、5構成の引数の照合値、ZIPのSHA-256を記録 |

署名したiPhone用Archiveと採用したZIPの照合は[Build 2263の検証](../../validation/history/配布ビルド採番とOrganizer認証調査.md#採用した無改変webrtcでbuild-2263を作る)を参照する。以前の採用記録と配布候補は同じ検証文書に残す。

ビルドで生じたvendor警告をゼロとは記録しない。`ASSEMBLE_ONLY=true` は生成済みの構成を使った組み立ての確認用とする。採用には通常ビルドで生成したZIPと対応する記録を使う。

## 掃除対象の検証

`clean-webrtc-build-resources.sh`はDRY_RUNの値を`true`/`false`だけに限定する。checkoutの`.gclient`、`src/.git`、`src/BUILD.gn`、またはRTCのPackage.swiftを確認する。ルート、利用者のホーム、リポジトリとその祖先、symlinkで外へ出る生成先は拒否する。dry runでも同じ条件を確認する。source checkoutを既に削除済みの場合は確認に失敗するため、そのrunのcleanupを繰り返して成功扱いにしない。

回帰試験は任意directoryのsentinel保持、symlinkによる逸脱拒否、DRY_RUNの綴り誤り拒否、検証済みcheckoutのoutだけ削除を確認する。利用者の既存checkoutはテストで削除しない。
