# iOS音声E2Eと通話障害修復

## 対象と境界

2026-10-22。iPhone同士で切断・無音となる報告を受け、iOSを主対象とする実発話E2Eを単体・結合テストから独立させた。MacとiPhone Simulatorの別アプリプロセス間で、異なる合成発話が通信先の実出力engineまで届くことを判定する。実行入口・通信境界・資源の所有と再利用は[音声E2Eテスト](../../development/音声E2Eテスト.md)を参照する。

物理iPhoneはこの調査環境に接続されておらず、報告された2台の現物での復旧は未確認。Simulatorでの修復と実機での完了を同一視しない。ハードウェアAECの品質、Bluetooth、ロック中、実Cloudflareの運用は別の確認範囲である。

## 要求との対応

| 要求 | 実装・確認先 | 完了の境界 |
|---|---|---|
| 片側iPhone Simulatorで発話・受話と通信 | 専用XCTestの別プロセス2端末、Local / WebRTC、異なる発話WAVと相手の出力render照合 | 人の環境音を使わず再現可能な発話を通す。マイク音響・AEC性能は未評価 |
| 音声plugin・codec・設定を含むE2E | `audio_e2e_matrix.py`、実AudioUnit状態・Codec能力・SessionManager操作のassertion | codec非対応時のfallbackを成功codecと混同しない。物理デバイス選択は実機で確認する |
| 短いリリースサイクル・AIなし | `audio_e2e.py`のquick、build cache、run内の設定切替 | 起動・判定・証跡回収・終了処理をCLIだけで実行。初回OS権限は開発環境の準備 |
| サーバーはモック可 | localhost Worker / WebSocket / native WebRTC SFU | 実Cloudflareの運用結果は主張しない |
| 単体・結合と分離 | `RideIntercomAudioE2ETests`と共有scheme `RideIntercomAudioE2E` | 通常Appテストと別の入口・結果bundle |
| Mac残存とSimulator増殖を解消 | 所有journal・排他・同一UUIDの再利用・終了時cleanup | SIGTERMの実ランナー試験と終了後資源の再列挙で確認 |
| 報告されたiPhone2台の通話復旧 | 実機用arm64 build、[実機確認待ち](../未確認事項.md) | 実機未接続。修正版の導入・双方向発話・接続維持の確認が残る |

## 再現した障害と修正

| 境界 | 調査で確認した問題 | 修正・回帰 |
|---|---|---|
| Local接続 | 両端から同時に招待可能で、接続試行が競合する | peer IDで招待開始側を一意に決める。実delegate queueを使う回帰で片側だけの招待を確認 |
| RTC再試行 | 接続待ちの途中で2秒ごとに再prepareされ、nativeの招待timeoutより先に接続を壊す | 成否が決まるまで次の再試行を発火させない。進行中の接続が次のretry intervalを越えて維持される回帰 |
| iOS音声session | 標準call設定のfarFieldInputを含むsetCategoryがSimulatorでOSStatus -50 | 専用Bluetooth収録向けoptionを共通既定から除外。4 profileを実iOS AVAudioSessionで設定する事前試験 |
| VoiceProcessingIO | 稼働中のRemoteIO / VoiceProcessingIO切替で-10849 | I/O mode変更時だけcaptureをstop/startしtap形式も更新。発話の有無によるduckingではI/O modeを変えない |
| Hardware tap / RTC境界 | 要求したtapサイズより大きい約100msのPCMが届き、RTCの8KiB上限を越えて破棄される | Mixer sinkで20ms以下に分割し、sequenceとcapture時刻を保持 |
| App送信待ち | 100msのtapから作る5 packetを単一slotで上書きし発話が欠落 | 最新100ms相当の5 packetまで保持し、古い予約を破棄。burst・mute・非協調backendの回帰 |
| 再生overflow | AVAudioPlayerNode.stop/playが同期的にhardware latencyを照会してmain側を停止し、player clockもリセットする | bufferのinterruptsで次のrender境界から置き換え、clockを維持。overflow時の新音声到達とclock進行を実renderで確認 |
| AAC-ELD v2 | converter作成は成功してもmono実encodeが'bada'で失敗し、既定設定の送信packetがゼロ | 短いPCMの実encode/decodeを能力判定に使い、非対応なら既存PCM fallbackを適用。AAC自体の成功とは数えない |
| Opus | packetごとのprimingにより末尾6.5msを失う | priming分を含めてdecodeし先頭の遅延を除去。16/24/48kHzの末尾発話を回帰で保護。bitrateをconverterへ直接設定し、magic cookieも保持 |
| 設定変更 | codec / format変更で通信session全体を作り直し、再認証・再接続待ちになる | RTCに接続中の音声policy更新を追加。peer・relay epoch・replay windowを維持し、App command queueは連続変更を集約 |
| 診断 | Local routeのcodec能力が初期codecに固定される | 転送能力と現在の音声policyを分離。OSのcodec能力はCodec packageの実変換検査で判定 |

package側の修正・回帰を先に完了してから、App側の利用経路を更新した。テスト専用の発話入力、資源管理、サーバーモックは製品コードに混ぜていない。

## 自動検証の証跡

| 検証 | 確認した結果 | 証跡 |
|---|---|---|
| RTC | 56件 + native WebRTC 2件成功 | `/tmp/rideintercom-rtc-final.log` |
| SessionManager | 35件成功 | `/tmp/rideintercom-output-interrupt-final.log` |
| AudioMixer | 25件成功 | `/tmp/rideintercom-mixer-interrupt-final.log` |
| Codec | 17件成功。実encode/decode・末尾保持・不正envelope・bitrateによる実圧縮量の変化を含む | `/tmp/rideintercom-codec-final.log` |
| App通信キュー | 11件成功 | `/tmp/rideintercom-live-policy-app-green.log` |
| App単体・結合全体 | Mac 112件、iPhone Simulator 112件成功。失敗・skipなし | `/tmp/RideIntercomAudioE2E/app-final` |
| 実機用ビルド | generic iOS / arm64のDebug build成功。署名・インストール・実機実行は含まない | `/tmp/rideintercom-device-build-final.log` |
| スクリプト | 46件成功。プロセス終了、SIGTERM、排他、再利用、全設定の測定回収を含む | `/tmp/rideintercom-python-final46.log` |
| 既定設定の連続発話 | Mac / iPhone Simulatorとも30秒成功 | `/tmp/RideIntercomAudioE2E/default-profile` |
| WebRTC quick | 5設定を両側で完了。出力muteで実renderがゼロ、復帰で相手の発話を再確認 | `/tmp/RideIntercomAudioE2E/quick-both-routes/webrtc-*.xcresult` |
| full両通信経路 | 32設定 × 2端末 × 2経路 = 128測定成功。Local約540秒、WebRTC約473秒。全体約17分 | `/tmp/RideIntercomAudioE2E/full-both-routes` |
| quick両通信経路（session組み合わせ追加前） | 5設定 × 2端末 × 2経路 = 20測定成功。再利用buildで約192秒。設定適用・source不変・測定回収・終了処理まで成功 | `/tmp/RideIntercomAudioE2E/quick-final` |
| iOS speaker切替を含む最新quick | 5設定 × 2端末 × 2経路 = 20測定成功。再利用buildで約234秒。source不変・全測定回収・cleanup成功 | `/tmp/RideIntercomAudioE2E/quick-ios-speaker` |
| iOS全session組み合わせを含む最新full | 33設定 × 2端末 × 2経路 = 132測定成功。Local約540秒、WebRTC約486秒、全体約1050秒。source不変・全測定回収・cleanup成功 | `/tmp/RideIntercomAudioE2E/full-ios-settings-final` |
| 実ランナーのSIGTERM | 実E2E開始後に終了シグナルを送信。非ゼロ終了、Mac host不在、同一SimulatorのShutdownを確認 | `/tmp/RideIntercomAudioE2E/interruption-proof/interruption-verification.json` |

`quick-both-routes`のLocal側は発話判定の閾値で失敗した結果を保持する。全runを成功とは扱わない。判定器は、遅延・gain・周波数特性・非線形変形に対する既知発話の一致と、無音・別話者・雑音の拒否を個別に検査する。スペクトル時間変化の相関は到達判定であり、聴感品質の点数ではない。

初回fullは端末・経路ごとに28発話区間と4無音区間を完了した。発話一致の最小値はLocalのMac 0.609 / iOS 0.516、WebRTCのMac 0.596 / iOS 0.646。最大peakは0.702で、いずれも判定条件を満たした。各端末・経路で16設定がAAC指定からPCMへfallbackした結果であり、AAC encodeの成功とは扱わない。`measurements-verified.json`に128件を再集計し、設定ID・端末・通信経路の欠落と重複がないことを確認した。

初回full実行後にLocal routeの静的codec能力表示、測定結果の追加項目・assertion、runnerのsource照合と測定回収を追加した。この時点ではquickと対象回帰で確認し、その後、以下の設定組み合わせも追加して最新fullを実行した。

設定画面と旧speakerDefault profileの試験を照合した。この試験だけでは、Stream mode + speakerと、明示echo希望なしのBurst mode + speakerを証明できない。マトリクス検査を先に失敗させ、Settingsと同じ操作関数と6通りのsession組み合わせをE2Eへ追加した。

追加後の`full-ui-settings`は、MacにもiOSのbuilt-in-speakerを要求する誤ったテスト条件で失敗した。Mac側がassertionで先に終了し、その後iOS側で受信ゼロを検出したもので、iOS側の入力・送信は継続していた。誤判定を実機の音声停止修復とは扱わず、6通りのスピーカー経路はiOSで検証し、Mac側は実system default出力を使うよう修正した。WebRTC側の続行はSIGTERMで止め、専用ホストとSimulatorのcleanupまで完了した。

修正後のquickは両経路で成功し、Stream mode + speakerへの復帰区間は両端末の送受信が410 packet以上、相手発話一致が0.781以上だった。この設定網羅の追加では製品sourceは変更していない。

33設定の最新fullは`full-ios-settings-final`で成功した。各端末・経路で29発話区間と4無音区間を完了し、132件すべての設定ID・端末・通信経路を照合した。発話一致の最小値はLocalのMac 0.590 / iOS 0.636、WebRTCのMac 0.660 / iOS 0.638。最大peakは0.868。各端末・経路で17設定がAAC指定からPCMへのfallbackだった。`source-manifest.json`はbuild開始から受入まで不変であり、現在のSwift・スクリプト・project・fixtureとも一致する。

## 資源の後片付け

過去の専用Simulatorが21台残っていたため、名称と停止状態を確認して当該テスト端末だけを削除した。削除対象一覧は`/tmp/rideintercom-retired-test-simulators.json`。通常のiPhone Simulatorと、所有を断定できないRecovery端末は削除していない。

E2Eはjournalで所有する1台を再利用する。成功・失敗・timeout・SIGINT・SIGTERMでは専用Mac hostを完全な実行ファイルpathで照合して終了し、Simulatorを停止する。SIGKILL等で後処理できなかった場合は次回起動で回収する。任意のアプリ名killや全Simulator停止はしない。通常検証の`validate.py`にもMac host終了と一時Simulator削除を追加した。

最終quick後も同じUUIDの専用Simulatorが1台だけ存在してShutdownとなり、E2EとApp単体テストのMac hostが残っていないことを確認した。証跡は`quick-final/final-resources.json`。最新full終了後も同じ1台がShutdownでMac host不在であることを再確認し、`full-ios-settings-final/final-resources.json`に保存した。同時点のdevicectl列挙でも物理iPhoneは0台だった。

証跡は`/tmp`上のローカル保存であり、永続保管やCIへのアップロードはしていない。build cacheは短い反復のため保持する。

## 48 kHzの音声機器を指定して近距離通話を測る

2026-11-21。48 kHzで入出力できる機器が2つあり、Macの既定の入出力から対象が決まらず、Simulatorの音声設定で試験が止まった。機器の名前を指定して試験用Simulator 2台の入力と出力を設定した。各Simulatorの元の選択を復元し、試験で追加した2台を削除した。[音声機器の指定方法](../../development/音声E2Eテスト.md#実行)

`a3f39a91` のソースで、保存済みグループを開き、両端のInternet接続の応答を待ったまま近距離通信を始めた。Release-Validationで既定のAAC設定を使い、6秒間の相手の発話を両端が連続して出力した。証跡は `.validation/security-audit-1900/current-clearance/named-audio-local/`。

WebRTCの1回目はSimulatorの起動完了を待つ段階で止まった。再実行では同じソースと音声設定で、ローカルの試験用サーバーを介して接続した。両端が相手の発話を連続して出力した。証跡は `.validation/security-audit-1900/current-clearance/named-webrtc-retry/`。

収録から出力までの実測値に、位置合わせの計測余裕10 msを加えて125 msの上限と照合した。近距離は両方向、WebRTCはAからBの方向が上限を超えた。

| 経路 | 方向 | 実測値 | 計測余裕を加えた判定値 |
|---|---|---:|---:|
| 近距離 | BからA | 123.04 ms | 133.04 ms |
| 近距離 | AからB | 125.46 ms | 135.46 ms |
| WebRTC | BからA | 114.79 ms | 124.79 ms |
| WebRTC | AからB | 126.71 ms | 136.71 ms |

各方向で収録時刻と長さが一意に一致する596〜600 packetを照合した。送出から受信までの中央値はどの方向も0.7 ms未満だった。再生予約完了から描画予定時刻までの中央値は近距離が37.51 msと40.45 ms、WebRTCが29.31 msと40.59 msだった。いずれもBからA、AからBの順である。近距離の実波形はA側31箇所、B側29箇所で一致し、いずれも描画予定の1.00 ms後に出力された。WebRTCでは描画予定時刻までを照合した。

実機2台を使う試験、設備のない場所の無線、固定Previewでの音声と画面ロック中の復旧は引き続き確認する。[試用の条件](../../backlog/未実装課題.md#最初に試すインターネット通話と通知と招待)

## Appleログインと音声機器を使わずWebRTCの発話を往復させる

2026-11-23。共有側ではAudio Checkの検証結果を記録する呼び出しが現行の型と合わず、音声E2Eをビルドできなかった。手元で直していた呼び出しを共有側へ反映し、iOS Simulatorの試験用Appと事前試験5件が通った。実出力を使う2台の試験は、音声初期化を同時に行う場合も、片側ずつ行う場合も、Simulatorの `AURemoteIO::Initialize` の応答待ちで停止した。

音声機器を使わない経路を同じ音声E2Eのschemeに追加した。iOS Simulatorで製品の通話処理と標準WebRTCを2つ起動し、ローカルWorkerを経由して別々の発話を相手へ送った。両端でグループ認証が成立し、受信したPCM16は両方向とも98/98フレームが元の発話と一致した。確認したのは送信から相手の受信まで。音声出力と遅延を測る試験は前段の音声初期化を引き続き確かめる。[再実行の手順](../../development/音声E2Eテスト.md#音声機器を使わずにwebrtcの発話を往復させる)

固定PreviewではInternetとTURNの有効化、およびSFUとTURNのシークレットの登録を確認した。Appleログインから独立した試用資格2件の登録を固定Previewに限って試したところ、接続済みの管理APIはHTTP 403を返した。登録一覧は追加されず、試験資格2件はどちらも固定PreviewでHTTP 401となった。実SFUを通る双方向の発話と、TURNが必要な経路は引き続き[実環境の確認](../未確認事項.md#確認待ちの振り分け)で追う。

## 固定Previewの実SFUで両方向の発話を確認する

2026-11-23。管理APIで試験資格を直接登録する方法から切り替え、共有mainの `ddef7493` を既存のGitHub連携から固定Previewに配置した。固定Previewに2人分の短期試験設定が反映され、本番には設定が入っていないことを確認した。試験資格2件で固定Previewの応答はいずれもHTTP 200だった。[試験手順](../../development/Cloudflare試用手順.md#appleログインなしで固定previewの音声を測る)

iOS Simulatorの同じ試験から、2つのWebRTC接続で異なる約2秒の発話を送った。固定Previewの実Cloudflare SFUを通り、片方向は98/98、もう片方向は97/98フレームが送信したPCM16と一致した。事前のローカル試験は両方向98/98、Workerは全131件が成功した。実中継の試験は1回で合格し、試験が始まる前と通話を終了した後の稼働セッション数はどちらも0だった。予約された利用枠は1,200参加者秒だった。実際の請求額とは別に扱う。

今回の判定は、固定Previewにつながった双方が相手の発話データを受信できたかで行った。物理端末の音声入出力、背景での再接続、制限回線で実際に使われるTURN経路は[実環境の確認](../未確認事項.md#確認待ちの振り分け)に残す。この試験に使った短期設定を取り下げる。

## 採用した無改変WebRTCで固定Previewの発話を往復させる

2026-11-23。共有mainの `06269fbb` から、採用済みの公式WebRTCを使って実行した。同じソースでWorkerの132件が通り、iPhone Simulatorのローカル中継では両方向98/98フレームが一致した。

短期の音声試験設定を共有mainの `77340baf` から固定Previewに反映した。本番に試験設定がないことと、固定Previewで2人分の資格がHTTP 200になることを確認した。音声機器を使わず、約2秒の異なる発話を各方向へ送る試験を1回実行した。

実Cloudflare SFUを経由した受信は、片方向が98/98、もう片方向が98/98フレームで送信したPCM16と一致した。稼働セッション数は試験の前後とも0件。予約された利用枠は1,200参加者秒。試験後は `TEST_PREVIEW_MEDIA_TRIAL` の設定を取り下げた。

この試験は、共有ソースと実中継で双方向に音声データが届くことを対象とした。通常のAppleログイン、実機の音声出力やロック中の動作、制限回線におけるTURN経由の通話は[実環境の確認](../未確認事項.md#確認待ちの振り分け)で追う。

## UDP TURNを経由した音声の判定をローカルで確かめる

2026-11-23。iPhone Simulatorの音声試験に、UDP TURNの選択を判定する入口を加えた。試験のネットワーク設定はテストターゲットが持つ。製品の候補選択は従来どおり。[TURNの仕様](../../spec/packages/RTC.md#turn資格のlifecycle)

通常のローカル中継では両方向98/98フレームが一致した。ループバックだけで動くPion TURN 4.1.4を使った試験では、送信前後の両方で、左右の接続がUDP TURNを選んだ。双方向の発話も各98/98フレームが一致した。[試験の入口と判定方法](../../development/音声E2Eテスト.md#udp-turnを経由する発話を検証する)

固定Previewの実TURN、資格更新後の同一接続、実回線の制限は[実環境の確認](../未確認事項.md#確認待ちの振り分け)で追う。

## 固定Previewで両端のUDP TURNを通る発話を確かめる

2026-11-23。共有mainの `2d7f02c2` と同じテストターゲットで、固定Previewの `10a4c8c5` を使った。試験設定は固定Previewに限り、資格は2人分ともHTTP 200。本番は実効設定に試験用の項目がなかった。

`--turn-relay` で1回試し、発話の前後で両端ともUDP TURNを選んだ。固定PreviewのCloudflare TURNとSFUを経由し、一方は97/98、もう一方は98/98フレームが送信と一致した。試験用通話室の稼働セッション数は実行の前後とも0件で、予約は1,200参加者秒。この試験の設定を固定Previewから取り下げる。

実回線の制限、TURN資格更新後の接続継続と実機のロック中の動作は[実環境の確認](../未確認事項.md#確認待ちの振り分け)で追う。

## ミュートで待機したRTCが後参加の発話を受け取る

2026-11-23。iPhone Simulatorの試験で、片側だけを接続し、20秒間ミュートで待機した。この間、相手の参加と受話はなかった。待機側の接続を開始し直さず、もう片側を参加させた。ミュート中は後参加側から待機側に25/25フレームが届き、待機側から送信を試みた発話は相手に届かなかった。ミュート解除後は両方向とも73/73フレームが送信内容と一致した。既定の同時参加は両方向98/98だった。

フレームは実際の送信時に付く連番で照合する。先に送信を試みたミュート側のフレームは送信されず、ミュート解除後に最初の連番から始まる。[試験手順](../../development/音声E2Eテスト.md#ミュートで待機して後から参加した相手の声を受け取る)

共有mainから試験差分を適用したコピーで再現した。待機試験はBuild 2281、同時参加はBuild 2282。SwiftLintも通過した。

中継はローカルの試験用Worker。固定Previewの実中継、実機の長時間ロック中の待機、通話が切れた後の再接続は[検証待ち](../未確認事項.md#ios背景実行の調査と受入マトリクス)で追う。
