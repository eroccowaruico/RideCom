# 通信診断とTURN資格の検証

検証日: 2026-10-21。対象: `codex/restore-dev-calls`。RTC `ace2042` / 再接続競合 `2a26eb2`、Worker `3f0cb3c` / 並行回収 `d1d5177`。Appと文書はこの記録を含む後続コミット。

## 指示と変更

パッケージ要求が満たされているかを実装で確認し、現実的に品質へ結びつく未達を実装する指示。調査時点では通信診断の接続とTURN資格lifecycleが未実装だった。RTCとWorkerを先に検証・コミットし、その後Appの表示と要求状態を更新した。

恒久要求は[パッケージ要求](../../requirements/パッケージ要求.md)へ残す。満たした項目を消すという従来の文書管理方針は、今回の指示に合わせて実装状態を更新する方針へ変更した。

## 採用した改善と限界

| 対象 | 結果 |
|---|---|
| 診断 | EventSourceのoverflow/expiry、ICE RTT、DataChannel送信待ち、認証済み観測経路をreport化 |
| 取得不能 | Multipeerの非公開統計、SCTP損失率はnilと理由を通知。推定値を正常としない |
| TURN | 事前の利用枠確認、所有者と試行ID、発行・更新・切断/期限/未成立の回収、失効再試行 |
| 再接続競合 | 旧session DELETE待ち中の切断で、新資格を不要に再発行する問題を先行テストで再現して修正 |
| 複数回収 | 未成立TURN資格の失効をroom上限内で並行化。API遅延を端末数だけ加算しないことを先行テストで検証 |
| App | DiagnosticsのNetworkへ共通reportを表示。古いreport、未取得、切断後を区別 |
| 費用 | TURNは既定無効。短期資格・参加者秒はbyte課金の硬い上限ではない。公開abuse・実請求監視は残る |
| 未確認 | 実Cloudflare、制限回線、実TURNの長時間更新・失効反映、実機音響・ロック・Bluetooth |

## 根拠と再実行

Cloudflareの[資格生成・失効・更新](https://developers.cloudflare.com/realtime/turn/generate-credentials/)を確認。長期秘密はWorkerのみ、端末は短期iceServersだけ受け取る。Apple HIGのAccessibility / Layout / SF Symbolsを確認し、Diagnosticsは既存GroupBoxと標準Textで表示する。

| 検査 | 証跡 |
|---|---|
| RTCの先行失敗 | /private/tmp/rtc-diagnostics-red.log、rtc-turn-red.log、rtc-reconnect-red.log |
| RTC本体 | /private/tmp/rtc-network-final.log：初回51件成功、native2件成功。競合修正後は /private/tmp/rtc-network-regression.log でRTC52件・native2件の全体回帰成功 |
| Worker | 型検査 /private/tmp/turn-cleanup-types.log。並行回収追加後16件成功 /private/tmp/turn-cleanup-green.log。先行失敗 /private/tmp/turn-cleanup-red.log |
| Swift–Workerペア | /private/tmp/turn-pair.log：HTTP/WS・lease継続・再参加が成功。外部SFUはmock |
| Appの先行失敗 | /private/tmp/rtc-app-red.xcresult |
| macOS App単体 | /private/tmp/rtc-app-green.xcresult：63テスト成功（パラメータ展開後66回）。失敗・skipなし |
| iOS Simulator UI | /private/tmp/rtc-network-ios-ui/ios-tests.xcresult：4件成功、失敗・skipなし。iPhone 17 Pro / iOS 26.4.1。文字拡大・ダーク表示のNetwork到達、設定・接続操作、起動を確認 |
| 文書・検証基盤 | /private/tmp/rtc-network-scripts/results.tsv。全段階exit 0。リンク・到達性・空階層・設定とスクリプト回帰17件成功 |

再実行は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path RideIntercom/packages/RTC`、`npm --prefix server run type-check`、`npm --prefix server test`、`npm --prefix server run test:pair`。App/UIと文書・開発設定は` scripts/validate.sh `の対応modeを使う。


Appの再実行例:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RideIntercom.xcodeproj -scheme RideIntercom \
  -destination 'platform=macOS,arch=arm64' -only-testing:RideIntercomTests \
  -derivedDataPath /private/tmp/rtc-app-validation/DerivedData \
  -resultBundlePath /private/tmp/rtc-app-rerun.xcresult
VALIDATION_DIR=/private/tmp/rtc-network-ui-rerun scripts/validate.sh ios-ui
VALIDATION_DIR=/private/tmp/rtc-network-scripts-rerun scripts/validate.sh scripts
```

結果ディレクトリは毎回新しい名前を使う。ツールチェーン・依存版・Simulator IDは各validationディレクトリのenvironment.txt / simulator-id.txt、UI操作の添付はxcresultへ保存する。`/private/tmp`の証跡は一時保存であり、必要なら別途保存する。この変更で全9パッケージを再実行したとは扱わない。音声系の既存結果は各履歴を参照する。

ツールチェーンはXcode 27.1 (27A9275)、Swift 6.4、macOS 27.0.1、Node 26.12.0 / npm 11.20.0。今回依存版の更新はない。XcodeのAppIntents metadata extraction skipped警告とSimulatorのSDK build記録診断が残るが、コンパイル・テストは成功。警告ゼロとは記録しない。UI添付画面でNetworkの折返し・スクロール到達を確認した。実機VoiceOver操作や全サイズの表示確認を代替しない。

## 自端末の音声を渡した経路

2026-11-20のRTCパッケージ検証。3台の代替transportでRouteManagerと認証・中継を実行した。近距離で全員をカバーするとLocalだけ、1台を別の近距離網へ移すとLocalとInternetの両方へ最後の音声を渡した。両方の場面で受信側2台に音声packetが届いた。受信・中継と制御では自端末の送信記録を作らず、切断後は消去された。追加前は経路の記録が得られず同じテストが失敗した。

- 回帰は `swift test --package-path RideIntercom/packages/RTC --no-parallel --skip WorkerPairTests` でRTCTests 140件、RTCNativeWebRTCTests 5件が合格。Workerペアは別工程。
- ローカル証跡は `.validation/tx-dispatch-1402/` の `red.log`・`green-focused.log`・`rtc.log`。
- この記録が示すのはRTCから各経路に渡した時点。backendの受付、実サービス・実機の相手への到着と実出力、Appの表示は別の確認を要する。

Build 1404のApp検証では、DiagnosticsのTXからRTCを展開して、通話前のLocal／Internet分岐が現れることをiOS Simulatorで確認した。通話の診断snapshotを渡すApp試験では、近距離でカバーしたときにInternetがIdleとなること、混在で2経路へ渡した記録、期限を過ぎた記録と別グループの観測を有効表示しないことを確認した。混在入力を描画し、通常文字と最大文字で経路名・状態・送信待ちを読めることを確認した。証跡は `.validation/tx-dispatch-1402/app-green/app.xcresult` と `tx-dispatch-standard.png`・`tx-dispatch-accessibility.png`。物理端末と実サービスを使った通話中の表示確認は残る。

Appの回帰はiOS Simulatorで23件、macOSで21件が合格した。

## 自端末の音声を経路が受け付けた結果

2026-11-20のRTCパッケージ検証。Localは送信条件を満たして1件以上のUDP送信を開始できたか、InternetはDataChannelが送信を受け付けたかを、最後の自端末音声について記録する。同じ音声に対し、相手到着は受信側の観測を要する。送信を優先する順序と、Internetの不要な音声コピーを省く条件を維持した。

- 既存実装ではRTCのreportとnative WebRTC送信から受付結果が得られず、追加した両テストが失敗した。変更後は閉じたDataChannelの不受付と、開いた両端での受付・packet受信を確認した。
- 実QUIC・UDPとローカルのnative WebRTCを使い、UDPを経路の途中で遮断した場合もLocalの送信受付を観測した。同じ区間の新しい音声はInternet経由で相手に届き、近距離復旧後はLocalだけに渡した。実機・本番SFUでの観測は残る。
- `swift test --package-path RideIntercom/packages/RTC --no-parallel --skip WorkerPairTests` で140件、native WebRTC 5件が合格。Workerペアは別工程。証跡は `.validation/tx-accept-1405/red.log`・`green-focused.log`・`rtc.log`。

AppはBuild 1407のiOS Simulatorで23件、Build 1408のmacOSで22件が合格。受け付けた経路と不受付の経路を同時に表示でき、受付情報のないreportは未計測として扱う。Simulatorで通話前のRTCを展開し、受付結果を与えた描画で通常文字と最大文字の読みやすさを照合した。macOSではRTCからAppへ認証済み音声を渡す既存試験も実行した。証跡は `.validation/tx-accept-1405/app-red/`・`app-green/`・`mac-green/`。

## Networkで認証済みの中継順を読む（2026-11-20）

Build 1465のiOS Simulatorで、画面を320pt幅に置き、近距離で2台の中継を経た相手とInternetで直接届いた相手の観測値を入力した。標準文字では相手の長い名前を2行で省略し、最大のアクセシビリティ文字では、経路名・短縮ID・時刻が横の3列に押し込まれ、`Stale`まで途中で分かれた。変更前の描画は `.validation/isolation-labels-1460/network-baseline` に保存した。

Pathsでは、相手名、Local／Internetと経路種別、送信元から自端末までの矢印、最後の観測時点を縦に配置する。Networkの表示が既存のRTC観測値をその順序のまま使い、15秒を超えた観測値は `Stale` と表示する。到着の観測は認証済みデータを対象とし、音声の復号と出力はRXで確認する。[表示仕様](../../spec/App/UI/Diagnostics.md#network診断)、[デザイン定義](../../design/詳細画面/診断と詳細画面の構成.md#network)、[HTML見本](../../design/詳細画面/詳細画面見本.html)。

Build 1466のiOS 27.2 Simulatorでは診断のページ切替と回転、最大文字での操作を含む11テスト・15実行が成功した。続くBuild 1467では、最大文字の経路を1行1IDと下向きの矢印で描き、通常文字と最大文字の320pt幅で相手名、全ID、順序、`Stale`を確認した。7テストが成功し、両Buildとも失敗・skip・実行時警告は0。Chromeの390px幅でもHTML内の直接・中継・古い観測の3例を確認した。証跡は `.validation/isolation-labels-1460/network-final`。

Appの描画には既存RTC契約と同じ観測値を入力した。RTC側では、近距離とInternetの混在で、中継を経て受信した相手の経路をreportに含めることを既存の `localOnlyMemberKeepsTalkingAcrossMixedRoutesAndGatewayDeparture` が検証している。実無線での照合は[画面デザインの実環境受入](../未確認事項.md#画面デザインの実環境受入)へ残し、計測カードの狭い幅での省略は[Networkの表示差](../../backlog/画面実装とデザイン見本の差分.md#network)へ記録した。
