# 音声E2Eテスト

MacとiPhone Simulator、またはiPhone Simulator 2台で別々のアプリプロセスを動かす。音声ファイルの発話が通信先の実AVAudioEngineのrender tapまで到達したかを波形で判定する。実装は専用の`RideIntercomAudioE2ETests`ターゲットと`RideIntercomAudioE2E` schemeに置き、通常の単体・結合テストとは独立させる。テストの起動・判定・証跡保存・終了処理にAIや画面操作は必要ない。

## 実行

Xcode、iOS Simulator runtime、プロジェクトの署名環境を[開発環境](開発環境.md)に従って準備する。初回のmacOS側のOS権限承認は開発環境の設定として済ませる。Simulatorのマイク権限は実行スクリプトで設定する。

ローカル音声、背景通話、固定Previewの音声試験は、Xcodeが利用可能と報告したiOSランタイムから、iPhone 17 Proをサポートする最新版を選ぶ。2台での音声試験は同じランタイムで揃える。

```sh
python3 scripts/audio_e2e.py
python3 scripts/audio_e2e.py --matrix full
```

MacのBonjour探索が`NoAuth`になる環境では、ネットワーク音声試験に`--two-simulators`を指定できる。iOS用のビルドを1回行い、端末ごとに別の役割と実行結果を割り当てる。コマンドは試験専用の2台を起動し、終了時に追加した端末を削除する。実出力の波形、継続性、遅延の判定は通常と同じ。単一端末で行う音声処理の試験ではこの指定を使わない。

試験は48 kHzの入出力に対応した同じ音声機器を、試験用Simulatorの入力と出力に一時的に設定する。自動で1台に絞れない場合は、`RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE` にMacで表示される機器の名前を指定する。音声E2E、iOSの音声UIテスト、背景通話の試験は `scripts/simulator_audio.py` の機器選択と復元を使う。指定に一致する機器が1台に決まらなければ、選択を変更する前に試験を中止する。試験終了時はSimulatorの選択を元に戻す。Macの既定の音声設定は変更しない。

生成されたxctestrunが参照するAppのInfo.plistを起動前に読み、保存先がXcodeの検証構成から取得した`RideIntercom.Validation.Xcode`と一致し、開発用の接続資格を含まないことを確認する。build引数だけを証拠にせず、通常のApp／StoreKit検証と[同じhost検査](自動検証.md#xcodeテストの起動前検査)を使う。不一致の場合は音声hostを起動しない。

通常は両通信経路の`quick`を実行する。`--transport local`は、Bonjourによる探索、QUICによる認証・制御、見つかった相手とのUDP音声に絞る。`--transport webrtc`はローカルのサーバーモックと実WebRTCに絞る。切り分け用の`--matrix smoke`は既定設定だけを測る。`--codec pcm16` / `--codec opus`と`--isolation off`は診断用の上書きであり、全設定を検証した実績にはしない。`--seconds`は各発話区間の秒数で、既定8秒。無音を測る区間は2秒。

### 音声機器を使わずにWebRTCの発話を往復させる

`RideIntercomAudioE2E` schemeで `AudioE2ETests/testWebRTCDuplexSpeechWithoutAudioHardware` を選び、iOS Simulatorで実行する。CLIではテストを指定する。

```sh
xcodebuild -scheme RideIntercomAudioE2E -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -only-testing:RideIntercomAudioE2ETests/AudioE2ETests/testWebRTCDuplexSpeechWithoutAudioHardware test
```

1台のSimulator内で、製品と同じ通話・WebRTC処理を2つ起動する。中継には既存のローカル試験用Workerを使い、参加者は試験用の通話鍵を共有して互いを確認する。異なる2つの発話ファイルを20 msごとのPCM16に分け、各方向で送信順と内容が一致したフレームを数える。両方向で送ったフレームの9割以上が一致すれば合格とする。Appleログインや音声機器の起動を必要とせず、音声の再生と遅延は上の2端末の試験で測る。実SFU・TURN経由の計測は[固定Previewの試用手順](Cloudflare試用手順.md#共有mainから固定previewと通話試験を用意する)に従う。

### UDP TURNを経由する発話を検証する

同じiPhone Simulator試験で、製品と同じネイティブWebRTCに、試験時だけリレー候補を使う設定を渡せる。送信の前後に、両端で選ばれたローカルICE候補の種別が `relay`、TURNサーバーまでの通信が `udp` であることを確認する。どちらかの統計を取得できない場合も不合格とする。出力するのは両端の合否とフレームの件数に限る。[WebRTC統計仕様](https://www.w3.org/TR/webrtc-stats/#dom-rtcicecandidatestats-relayprotocol)

UDP TURNサーバーを `127.0.0.1` に限定して起動する。試験用の利用者名は `relay-fixture`、パスワードは `loopback-fixture`。Xcodeの起動時に環境変数を渡す。

```text
TEST_RUNNER_RIDEINTERCOM_TEST_TURN_RELAY=1
TEST_RUNNER_RIDEINTERCOM_TEST_LOCAL_TURN_PORT=<ローカルTURNのポート>
```

音声試験は、そのポートと試験用の資格をローカルWorkerの応答へ設定する。固定Previewでの検証では[音声試験の手順](Cloudflare試用手順.md#appleログインなしで固定previewの音声を測る)から `--turn-relay` を指定する。ローカルのTURNサーバーを使う設定は渡さない。

### ミュートで待機して後から参加した相手の声を受け取る

ローカルの試験用Workerを使い、同じテストをCLIで実行する前に `TEST_RUNNER_RIDEINTERCOM_TEST_WAIT_FOR_PEER=1` を指定する。片側をミュートして接続を始め、Internet経路が使える状態で、相手と音声がない接続待ちを20秒間保つことを確認する。待機側の接続を開始し直さず、もう片側を参加させる。

後参加側の最初の25フレームが、待機側に23フレーム以上届くことを確かめる。待機側がミュート中に送信を試みたフレームは、相手に届かないことを確かめる。次に待機側のミュートを解除し、残りの発話が両方向に届くことを測る。受け取ったフレームは、実際の送信時に付く連番で照合する。この試験はローカル中継を使ったRTCの待機と受話を対象とする。実機の画面ロック中の動作は[受入マトリクス](../validation/未確認事項.md#ios背景実行の調査と受入マトリクス)で確認する。

### 保存済みグループから近距離通話を始める

Xcodeで共有スキーム `RideIntercomAudioE2E-LocalPair` と実行先 `My Mac` を選び、Product → Runを実行する。Mac上の既存ランナーが専用のiPhone Simulator 2台を用意する。保存済みグループから近距離通話を始め、両方向の発話を各6秒測定する。Xcodeのコンソールで合否と `.validation/` 内の保存先を確認する。試験を終えると音声機器の設定を戻し、試験用Simulatorを回収する。

CLIで同じ条件を実行するには、次のコマンドを使う。

```sh
python3 scripts/audio_e2e.py --transport local --matrix smoke --saved-group-start \
  --two-simulators --ephemeral --seconds 6
```

両端でInternetを無効にし、検証用のログイン、グループと鍵を保存する。Appleの資格照会が圏外エラーを返す条件でログインとグループを新しいモデルへ読み直し、保存済みグループを一覧から選ぶ操作で接続を始める。StoreKitの利用権判定には有効な利用権を入力する。近距離経路だけで互いを認証し、Appの音声許可が成立し、各端末の実出力にもう一方の発話が届くことを波形で判定する。

2台のiOS Simulatorでも`RideIntercomAudioE2E`の`testDuplexSpeechOverNetwork`を使う。両端で同じ`AUDIO_E2E_RUN`（グループのUUID）と`AUDIO_E2E_SCENARIOS`（`smoke`のJSON）を使い、`AUDIO_E2E_ROLE`には別々に`a`と`b`を指定する。両端で`AUDIO_E2E_TRANSPORT=local`と`AUDIO_E2E_SAVED_GROUP_START=1`を設定して一組で起動する。MacのBonjour探索が`NoAuth`になる環境は2台のSimulatorで確認できる。[検証環境と結果](../validation/history/近距離オフライン通信.md#保存したグループからinternetを無効にして近距離通話を始める)

#### Internetの応答を待たずに始める

```sh
python3 scripts/audio_e2e.py --transport local --matrix smoke --saved-group-start --unanswered-internet --seconds 6
```

近距離とInternetの両方を有効にし、通話用の接続資格にはローカルの試験用Workerを与える。Workerは端末を識別できる最初のICE設定要求を受け取るが、応答を返さない。両端の要求を観測してから測定区間へ進む。測定の前後に両端の要求が待機中で、利用できる経路が近距離だけであることを確認する。各端末で相手の発話がQUIC認証済みのUDP経路から実出力に届くことを既存の波形判定にかける。`smoke`の単一条件、6〜10秒で実行し、Internet側の要求が時間切れとなる前に測定する。

各端末で、復号・Mixer出力・native出力のWAVと`packet-timing`を成功時にも保存する。`received`の各`playoutReservation`が描画時計を取得した行を確認する。その行では、`renderAnchorHostTime + (startSample - renderAnchorSample) / sampleRate`が予約した先頭の予測描画時刻になる。復号WAVの対応位置をその前後のMixer・native出力の波形と照合する。録音は試験用発話を使い、判定値は従来どおり最終出力で求める。

接続直後から定常区間の開始までを、`startupReceived`、`startup-decoded.wav`、`startup-speech.wav`に保存する。呼び出し直後に既存の受信処理を観測し、最初の予約と再調整を残す。復号WAVの先頭は`startupFirstDecodedCaptureTime`。native出力のWAVでは、`startupRenderClock`の各ブロックが`startSample`（WAV内の先頭）、`frameCount`、`hostTime`（その先頭の単調時計時刻）を対応付ける。照合したサンプルの時刻は、そのブロックの`hostTime`にブロック内の位置を秒に換算して加える。音声エンジン起動時などの時計の飛びはWAVの連続したサンプル位置に現れないため、ファイル全体を先頭の時刻で換算しない。

定常区間も`steadyFirstDecodedCaptureTime`、`steadyRenderClock`を同じ`packet-timing`に保持する。対応先は`decoded.wav`と`speech.wav`。native出力のサンプル数とブロック位置を一度に確定し、最初のブロックがsample 0から始まり、最後まで全サンプルにブロックの時刻があることを試験で確認する。定常区間の予約から描画までの差は、同じ発話を復号WAVと最終WAVで照合して求める。連続性と125msの判定は、従来の最終出力の判定を使う。

端末2台を自動で用意するには、上のコマンドに`--two-simulators`を追加する。Xcodeから設定する場合は保存済みグループの設定に、両端で`AUDIO_E2E_UNANSWERED_INTERNET=1`と同じ`AUDIO_E2E_WORKER_URL`（例 `http://127.0.0.1:49152`、空きポートを選ぶ）を加える。役割`a`の試験がローカルWorkerを起動する。[測定結果](../validation/history/近距離オフライン通信.md#internetの応答がない間に保存済みグループの近距離音声を測る)

### 通話中に近距離音声を遮断する

近距離の音声を遮断する試験は `python3 scripts/audio_e2e.py --transport mixed --matrix smoke` で実行する。Debug-Validationで両経路を有効にし、同じ通話で初回の片方向遮断、近距離の双方向受話、両方向遮断中のInternet受話、近距離復帰後の双方向受話を照合する。両方向遮断中は近距離の媒体受信が0で、QUIC制御とWebRTC経由の相手の発話が届くことを確認する。4区間の両端それぞれで、同じ測定区間のDiagnosticsの送信受付、受信・復号・出力の状態を含むJSONと、実出力のWAVを保存する。最後に全媒体を遮断し、送信受付とQUIC制御が続く間に両端の受信・復号・出力がWaitingとなり、実出力が無音になることを確認する。全媒体遮断のJSONは別の添付に保存する。経路が戻っても、明示終了した端末の通話と出力は復活しないことを確認する。連続性と125ms基準は通常の音声試験で判定する。Macでローカルネットワーク許可を読み取れない場合の標準配置の実績は[QUIC移行の検証記録](../validation/history/近距離制御のQUIC移行.md#標準配置のmacとiphone-simulatorの音声測定)を参照する。

この開発機での両経路の実測は、build cache再利用時のquickが約3分54秒、fullが約17分30秒。初回buildやOS・機材の違いにより所要時間は変わる。測定結果は[検証記録](../validation/history/iOS音声E2Eと通話障害修復.md)を参照する。

| 範囲 | 測定する設定 |
|---|---|
| quick | 実AAC-ELDの符号化・復号、Opus、PCM16、48/24/16kHzを試す。送信・受信master・受信peerでのSoundIsolation、DynamicsProcessor、PeakLimiterも試す。さらにVADの3種類のpreset、ducking、音量、出力muteとStream mode + speakerへの復帰を試す |
| full | quickに加え、3種類のcodec指定と3種類のrateの組み合わせを試す。AAC/Opusのbit rateの下限と上限も各rateで試す。mode・speaker・明示echo cancellationの6通り、master/peer音量ゼロ、送信muteと復帰を試す |
| identity | 20秒以上の全文照合。既定設定、PCM16で送信Isolation無効、Opusで送信Isolation無効を比較。英語・日本語・間と相槌を含む会話を別runで実行する |

マトリクスの基準となる資料はリポジトリの`scripts/audio_e2e_matrix.py`にある。通信試験の両端に渡す設定を`scenarios.json`へ保存する。短い検証では既存のbuild productsを使い、設定区間ごとにアプリを再ビルドしない。

音声sessionはSettingsと同じMode・Use Speaker・Echo Cancellationの操作関数を使う。iOS側でBurst modeはspeakerと明示echo希望の4通り、Stream modeはspeaker ON/OFFの2通りを通す。MacはCoreAudio固有のデバイスIDを持ち、iOSのbuilt-in-speaker指定を持たないため、相手側として実system default出力を使う。表示用の値だけでなく、SessionManagerへ渡されたmode・speaker・echo希望と、OS操作が失敗していないことも検査する。物理機器が必要なBluetooth・有線デバイス選択はSimulatorの設定網羅に含めない。

### 通信音声のケースを選ぶ

設定や音声経路の変更に関係するケースを実行するときは、`--matrix`と`--scenario ID`を組み合わせる。例えば、PCM16の16kHz・Voice ChatだけをiPhone Simulator 2台で測る。

```sh
python3 scripts/audio_e2e.py --configuration Release --transport local --matrix quick \
  --scenario pcm16-16k-voicechat --saved-group-start --two-simulators --ephemeral
```

複数のIDは`--scenario`を繰り返す。選んだケースはマトリクスの順に実行する。未知のIDや重複ID、専用mode・`--transport mixed`・`--cleanup-only`との組合せは、Simulatorを準備する前に組み合わせをエラーとして報告する。指定を省くと従来どおりマトリクス全体を実行する。例えば出力ミュートからの復帰を検証するときは`output-mute`と`output-recovery`を両方選ぶ。 遅延の判定には、選んだ経路・ケースで両側の測定がそろい、発話と無音の条件が指定と一致することが必要。無音のケースだけを選んだときは `duplex-latency` を対象外（`not-applicable`）と記録する。発話を選んだ側の測定が欠けたら失敗とする。

`scenarios.json`に実行対象の設定を保存し、両端の測定が選んだ全ケースのIDと一致することを照合する。波形、連続性、遅延の基準は共通。Xcodeから同じ組合せを実行する場合は、そのJSONを両端の`AUDIO_E2E_SCENARIOS`に設定する。結果の範囲は選択したケースと経路に限定する。

## 通る経路と判定

合成発話WAVを次の経路に通す。

1. iOSの実capture clockとhardware formatで入力し、AudioCore、VADGateの順に通す。
2. AudioMixerの実AudioUnit chainを通して、Codecで符号化する。
3. RTCで認証・暗号化し、UDP datagramまたは再送なしのWebRTC DataChannelで送る。
4. 相手のCodecで復号し、peer、master、outputの順にmixerを通す。
5. SessionManagerの実出力engineを通してrender tapで受け取る。

iOS側は実`SystemAudioInputStreamBackend`でcaptureを起動し、音声処理・OS形式・callbackの時間間隔を使う。callbackのマイクsampleは直ちに破棄し、同じ形式と長さのfixture発話へ置き換える。Mac側は10msのfixture入力をuserInteractiveのstrict timerで供給する。capture時刻は各区間の開始を表し、区間の全sampleを取得し終えてから渡す。未来のsampleを先送りして遅延を小さく測らないことをMacの事前試験で確認する。人の発話やマイクに入った環境音を保存・送信しない。実機のマイク音響品質、スピーカーの空気振動、Bluetoothや無線干渉の試験は別に必要である。

VoiceProcessingIOについて、このE2Eが保証するのは有効化・無効化・mute・ducking・session profile変更時にOSのI/Oが動き続けること。fixtureはcapture callbackで差し替えるため、ハードウェア側のAECによるエコー低減量やマイク雑音除去の品質は測定しない。AppのAudioMixer上のSoundIsolation / DynamicsProcessor / PeakLimiterにはfixture発話自体を通す。

双方には異なる声・文章を渡す。従来の到達判定は、受信renderの750ms発話断片を異なる3箇所（計2.25秒）で照合する。8kHzへ変換した信号の周波数帯域ごとの時間変化を使い、音量・固定的な音色の変化を除いて相手の発話との相関が0.45を超え、自分の発話より0.10以上強く一致することを要求する。この判定だけでは良い断片を選べば合格するため、途中の途切れや音声の同一性を保証しない。

非mute区間には、録音全体の時間順を維持する連続性判定も必須とする。network試験では2秒の安定待ち後の録音に対し、繰り返し再生した基準音声との時間位置を全体で一度だけ決定する。区間ごとの遠い位置への再探索や時間伸縮は行わず、欠落・繰り返し・順序入れ替えを隠さない。音量と固定的な音色変化を除いた16帯域の時間変化を比較する。10ms特徴量で選んだ単一の全体offsetを、±15ms内の1ms RMS envelopeで精密化する。native codecの10ms未満の遅延を無音境界の欠落と誤認しないためであり、区間ごとの再整列や閾値の緩和は行わない。

| 指標 | 判定 |
|---|---|
| 全体の相関 | 0.65以上。低い場合は時間整合自体が弱いため、欠落率の厳密な解釈は避ける |
| 発話区間の一致 | 200ms窓を100ms刻みで評価し、相関0.65以上の窓が98%以上。局所の時間ずれ許容は±30ms |
| 発話中の低出力 | 基準の10ms RMSがピークの8%を超える部分を対象とし、推定音量比で補正した基準RMSの10%未満になる比率が0。共通解析器の旧基準1%以下だけでは受け入れず、実通信・単体native経路・codec・送信会話試験で0を追加要求する |
| 連続した低出力 | 上記の低出力が60msを超えて続かない |
| 測定不足 | 有効な発話が2秒未満、評価窓なし、実renderの長さ不足、非有限sampleは合格にしない |

この閾値はリポジトリの回帰検出基準であり、知覚品質の標準スコアや発話内容の文字認識率ではない。元音声の自然な間は低出力比率から除外する。無音・別話者・雑音に加え、100ms周期欠落、途中500msの無音、1秒の繰り返し、順序入れ替えを拒否し、固定遅延・音量変化・フィルター・非線形変形を許容できるか事前に試験する。mute区間は実renderの無音、その後は発話と連続性の復帰を確認する。

1ms RMS区間の境界は実sample rateから毎回求める。44.1kHzを毎区間44sampleへ切り捨てると20秒で約45msの解析時計誤差になるため、44/45sampleの区間で本来の時計を保つ。既知の固定offsetを持つ44.1kHz出力の正例と、欠落・重複の負例を同じ閾値で事前検査する。

双方向試験は最終出力に加え、復号直後と受信Mixer直後の同一性、送受信時刻、出力予約量を記録する。MacとそのSimulatorの共通host clockで相手のcaptureから最終renderまでの遅延を求め、一方が失敗しても他方の測定値を保存する。JSON traceの直列化・相槌解析・WAV保存は通話actor外で行い、証跡保存による音声待ちを作らない。

1台のMac上で動く2端末間の`packet-timing`では、RTCが音声連番を振り直すため、送信の`transmitted`と相手の`received`は`capture`で照合する。方向とシナリオごとに`capture`をマイクロ秒単位に丸め、各端のキーが一意であることを確認し、双方に記録のあるパケットだけを集計する。符号化済みパケットからApp受信までの時間は受信の`host`から送信の`host`を引く。物理端末同士でこの差を求めるには、共通の時間基準を別途確立する。

受信観測は`processReceivedAudio`境界で本番の`AppAudioPipeline.processReceivedAudioPacket`を一度だけ呼び、その戻りPCMを保存する。途中から別decoderを起動して復号を重複実行しない。UIの受信通知・音量表示は通常どおり流し、観測のために音声をMainActorへ戻さない。

連続性不合格でも残りの設定区間を測定してWAVとJSONを保存し、最後にテストを失敗させる。受話を期待する区間で連続性が不合格の場合は、最終出力の `speech` に加え、実際に取得できた復号直後の `decoded` と受信ミキサー直後の `mixed` のWAVを保存する。それぞれJSONの時計と照合できる。接続喪失や処理不能はその時点で失敗する。保存WAVは判定に使った同じsnapshotから書き出す。

```sh
python3 scripts/audio_e2e.py --matrix identity --speech-pair english
python3 scripts/audio_e2e.py --matrix identity --speech-pair japanese
# iOSの実Mixer→PCM16 encode/decode→実出力を1プロセスで測定する
python3 scripts/audio_e2e.py --pipeline-only
```

`--pipeline-only`はRTC・VAD・送信Isolationを外し、日本語発話を20ms／100ms周期でAppAudioPipelineへ渡す。入力の収録時刻はサンプル数から求め、受信には製品通話と同じ開始待機2ms、予約上限120ms、相手別の適応再生を使う。各条件で安定するまで2秒待ってから20秒測定し、有声区間の欠落0を要求する。実出力WAV・処理エラーと、相手別の再生予約調整・リセット、最終出力側のリセットを記録する。通信を外した経路の連続性を確かめる試験。

コーデックの要求と実選択は別に記録する。現行AACはnative AAC-ELD monoであり、AAC条件では実選択がAAC-ELDかつfallback=falseを要求する。旧AAC-ELD v2の非対応時にPCMへ代替した結果はAAC成功として数えない。

### マイクOFFで待ち、後参加と経路復旧を続けて検証する

通常のCLIでは、次のコマンドでInternet経路を試す。Internetは `--configuration Release` でも試せる。近距離は `--transport local` を選び、UDP受信口を中断できるDebug構成を使う。待機秒数は1〜300秒。実行環境の確認には短い待機を使え、5分の待機を評価するときは300秒を指定する。

```sh
python3 scripts/audio_e2e.py --two-simulators --transport webrtc --matrix smoke \
  --seconds 6 --speech-pair japanese --background-recovery 300
```

両端のXcodeの試験結果に加え、後参加、双方のマイクOFF、経路復旧後の3つの測定結果が両端に揃うことを確認する。この試験は片側のマイクをOFFに保って聞こえ方を調べる。双方向の遅延基準は、通常の音声試験で引き続き測る。

2台のiOS Simulatorで `RideIntercomAudioE2E` の `testDuplexSpeechOverNetwork` を使う。両端で同じ実行IDと試験Worker URLを指定し、それぞれ異なるroleを使う。両端の試験構成を次の表に合わせる。

| 条件 | 環境変数と設定値 |
|---|---|
| 共通 | `AUDIO_E2E_WAIT_FOR_LATE_PARTICIPANT=1`、`AUDIO_E2E_BACKGROUND_AFTER_START=1` |
| 共通 | `AUDIO_E2E_BACKGROUND_MIC_OFF=1`、`AUDIO_E2E_BACKGROUND_MUTED_WAIT_SECONDS=300` |
| 近距離の場合 | `AUDIO_E2E_TRANSPORT=local`、`AUDIO_E2E_BACKGROUND_LOCAL_RECOVERY=1` |
| Internetの場合 | `AUDIO_E2E_TRANSPORT=webrtc`、`AUDIO_E2E_BACKGROUND_INTERNET_RECOVERY=1` |

近距離のUDP受信口の中断にはDebug-Validationを使う。

先に入った側をマイクOFFのまま別アプリへ移し、受信音声0のまま同じ通話で待つ。後から入る側が発話を送り、先に入った側の実出力と照合する。続いて双方が約60秒マイクOFFのまま送受信0を確認し、同じ通話中の経路を一時中断する。試験の段階を揃える合図には試験WorkerへのHTTPを使う。音声と相手の認証は製品の通話経路を通す。経路の復旧後に話す側だけ送話を許可し、聞く側の実出力に再び相手の発話が現れること、反対向きの受信は0であること、最初の通話参照と終了期限が保たれることを確認する。Simulatorの別アプリ移行を使うため、実機の画面ロックと実ネットワークは[未確認事項](../validation/未確認事項.md)で管理する。

## 再利用と後片付け

音声機器の設定を片方で復元できなくても、もう片方の復元と所有するSimulatorの回収を続ける。設定コマンドを起動できない場合や応答の形式が不正な場合は、`results.json` の音声復元の項目にエラーの種類を記録する。試験の終了コードは失敗になる。

通常実行では通常検証（`validate.py`）と共通の専用Simulatorを1台だけ再利用し、終了時に停止する。`--two-simulators`の2台目は所有記録を残して作り、終了時に削除する。中断で残った場合も、次回の同じ実行ロックの下で所有する端末だけを回収する。mainの通常作業フォルダのprojectを使い、build cacheはXcode既定のDerivedDataを再利用する。projectコピーや`/tmp`専用build、`--build-root`による別cacheは使用しない。生成先はXcodeの`-showBuildSettings -json`から必要なpathだけを取得する。MacとiOS Simulatorは同じBuild/Productsを使うため、生成xctestrun名にはplatformを含める。2台構成では役割も含める。

正常終了時のtest host終了はXcodeに任せる。timeout・SIGINT・SIGTERMでは、起動時に取得したprocess identityと所有子孫だけを回収し、専用Simulatorを停止する。同じ既定DerivedDataを使うGUI hostをpath一致で終了しない。旧journalに実行ファイルpathだけが残り、そのhostが動いている場合は所有を証明できないため失敗を記録し、signalを送らない。名前だけの`pkill`や`simctl shutdown all`は使用しない。二重実行はlockで拒否する。SIGKILLや電源断で終了処理自体が実行できなかった場合は、次回起動で全端末の一覧を証跡へ保存する。管理記録が失われても専用名から停止済み端末を再発見し、互換端末を再利用する。起動中の専用端末がある場合は、端末を作成・削除せずに失敗するため、所有する作業を確認して終了してから再実行する。

```sh
# CI等で今回作った端末を終了時に削除する
python3 scripts/audio_e2e.py --matrix quick --ephemeral
# 再利用端末を削除する。旧hostの所有を証明できない場合は停止せず失敗にする
python3 scripts/audio_e2e.py --cleanup-only
```

再利用用と一時実行用の所有情報、および通常検証と共有する排他lockは`/tmp/RideIntercom-AudioE2E-<uid>/`に置く。`--cleanup-only`は記録外を含む停止済みの管理対象端末も削除する。build cacheと検証証跡は消さない。

予約済みの専用名は`RideIntercom Audio E2E <8桁のhex>`、`RideIntercom Validation <実行名>`、旧`RideIntercom Recovery Tests`。毎回、記録済みで互換な端末、次に最終利用日時が新しい互換端末を優先し、残りの停止済み専用端末を削除する。対応runtime・device typeの端末がない場合だけ作成する。削除失敗時は新規作成しない。一般のiPhone/iPad端末や所有不明の名前は対象外。

## 証跡

標準出力の`Evidence:`が保存先を示す。既定はmain作業フォルダの`.validation/audio-e2e-<日時>`。`--output`で新しい空の保存先を指定できる。同じrunを上書きしない。build cacheと測定証跡は分けて扱う。

| ファイル | 内容 |
|---|---|
| results.json / results.tsv | build、実行、受入判定、後片付けの成否と秒数 |
| measurements.json | 全通信経路・全端末・全設定の発話照合、packet数、render数、peak、要求／実選択codec。各設定の実測が揃わない場合も失敗扱い |
| pipeline-measurements.json | 各専用modeで回収した測定。`--pipeline-only`では20ms／100ms入力周期別の連続性、相手別の再生予約調整・リセット、最終出力側のリセット、処理失敗 |
| configuration.json | run識別子、入力境界、通信経路、実行するmodeと`expectedMeasurementIDs`。同じIDを、通信試験の経路と両端ごと、または専用modeの測定結果の照合に使う。`--cleanup-only`の期待IDは空配列 |
| scenarios.json | 通信試験の両端に渡す設定。通常の通信試験では選択したマトリクス、`--transport mixed`では通話を始めるための初期設定。専用modeと`--cleanup-only`では作成しない |
| source-manifest.json | HEAD、Swift・テスト・スクリプト・project・発話fixture・アセットカタログとIcon Composer内の全形式のSHA-256。Git未登録の追加アセットも含める。ビルドから受入までに入力やHEADが変わると失敗する。プロジェクトで共通のビルド番号だけが進む場合は許容する |
| `test-<通信経路>-<端末>.log` | Xcodeが報告した `.xcresult` の場所を記録する。通信経路と端末ごとに別の結果を標準の `Logs/Test` から読み取る |
| attachments-<通信経路>-<端末> | 設定区間ごとのJSON測定値、実render WAV、連続性の検査に合格しなかった場合の復号・ミキサーWAV、終了時の状態 |
| simulator-id.txt | 実行に使用した端末の識別子 |

双方向の遅延を計測できた行では、`measurements.json` の `captureToRenderLatencySeconds` に実測値を保存する。`captureToRenderLatencyWithAllowanceSeconds` は、実測値に位置合わせの計測余裕10 msを加えた判定値である。125 msの上限には後者を照合し、上限を超えた行にも両方の値を保存する。専用モードにはそれぞれの遅延判定があり、2台間の `duplex-latency` は対象外と記録する。

背景通話の後参加と受話再開では、各端末の `packet-timing` に符号化済みpacketの収録時刻、受信側で処理を始めた時刻と予約後の待ち量・調整回数を記録する。相手音声を受ける測定では復号直後のWAVとnative出力WAVを保存し、それぞれの固定時刻での連続性を測定する。両端のpacketは収録時刻を基準に照合し、記録区間の前後は重なる範囲を使う。音声は試験fixtureの内容を専用の検証成果物に保存する。

`receiveProcessing` は観測を明示した受信処理でのみ記録する。同じ端末の単調時計の秒で、`lockRequestedAt`（Appの受信時刻で、AudioMixerへ渡す `arrivedAt` と同じ）、`lockAcquiredAt`、`decodedAt`（decoderの取得と復号後）、`reservedAt`（再生予約と必要なplayer開始の後）を並べる。復号結果にPCMがなければ `reservedAt` を省く。`handled` は予約量の診断取得とlock解放後の時刻なので、`reservedAt` との差から予約後の観測に費やした時間も分けられる。各差は経過時間であり、各段のCPU実行時間とOSやフレームワーク内部で待った時間を区別する測定ではない。[Appの到着時刻の契約](../spec/App/音声処理仕様.md#出力クロックの共有)

再生位置を調整した受信packetの行には `playoutAdjustment` が付く。送受信の境界で `sequence` は一致するとは限らない。そのため、送受信は外側の `capture` と `duration` で照合する。内側の `capturedAt` と3つのsample位置は、復号後に予約した音声との照合に使う。sample位置の単位と `reason` の意味は[AudioMixerの現行仕様](../spec/packages/Audio/AudioMixer.md)に従う。次のpacketに同じ調整を繰り返し記録しない。通常の双方向試験でも同じ観測を使う。

再生の基準位置を決めた予約では `playoutReservation.anchorLead` に待ち時間を決めた値が付く。単位と記録条件は[AudioMixerの再生予約の仕様](../spec/packages/Audio/AudioMixer.md#再生予約量の制御)に従う。定常区間の収録から予測描画までの時間を比べる際は、起動区間の予約のうち、その時間が定常区間へ続いた行を調べる。

成功判定には両側で専用E2Eが実際に1件ずつ完了し、失敗・skipがないことを要求する。後片付け失敗も終了コードを非ゼロにする。実行結果・未確認範囲は[検証状況](../validation/README.md)へ記録する。

## 音声トラブルの比較記録

音の途切れや遅れ、切替後だけ声が変わる症状を調べるときは、[音声の検証履歴](../validation/README.md)から同じ症状と操作を探し、該当する履歴の見出しへ追記する。次に読む人が「前と同じ壊れ方か」「どの変更だけ戻せるか」を判断できるよう、成功・失敗・修復・不採用の観測を残す。次の調査ではそこに記録した入力・観測段・判定式を先に照合する。

再調査では、先に保存済みの数値を[切替試験の比較例](../validation/history/音声同一性と途切れの再現.md#aacの定常波形と受信分離をオンにしたときの無音を分けて比較する)と照合する。試験名が同じでも、操作の区間、入出力経路、ビルド構成、判定方法が異なる値は区別する。次のコマンドは実行結果を保存したフォルダで使う。Simulatorの起動やコードの切替は不要。

作業中の差分を含む試験では、コミット番号だけでは同じ入力を再現できない。各実行の `source-manifest.json` で実際に使ったファイルを照合する。動作が変わる差分を基準に採用するときは、その差分を特定できるコミットかパッチも対応付けて残す。

```sh
jq -r '.[] | select(.scenario == "live-settings") | .stages[] |
  [.stage, .maximumSilenceMilliseconds, .steady.maximum2msRMSError, .steady.passed] | @tsv' pipeline-measurements.json
```

現在の結果と保存済みの値で判断できる項目は再測定を省く。機器や試験条件を合わせられない場合、保存波形がなく原因を区別できない場合は、不足する比較だけを選んで実行する。

| 比較に残すもの | 他の担当が読み取れる具体性 |
|---|---|
| 症状と引き金 | 誰の声がどちら向きでどう変わったか。開始状態、操作順、発生区間・頻度。既知の正常操作と、初めて差が出た操作を並べる。利用者報告と測定で再現した現象は区別する |
| 比較するビルドと実行条件 | 各観測のBuild・ソース識別子、環境、fixture・入力区間、実際の経路・codec・設定のうち結果を左右するもの。同じだった条件と意図して変えた条件を示す。他にも差があれば比較の限界を添える。正常に動いたビルドを特定できない場合はその旨と、基準に使える同一run内の正常区間を示す |
| 壊した変更と最初に差が見えた段 | 変更した処理、状態の所有元、壊れた前提、前後段の観測を結ぶ。収録・送信処理・通信・復号・再生予約・実出力のうち最後に正常だった段と最初に異常を観測した段を記す。間に未計測の段があれば範囲として残す。最初に失敗を観測したビルドと、不具合が入ったことを特定できた変更は区別する |
| 正常・失敗・修復の値 | 側・方向・観測点・単位・区間・判定方法をそろえて値を横に並べる。run、ログ・波形・測定JSONの場所を添え、ローカル成果物を開けない担当にも判断できる要点を本文に残す。試験用fixtureを使い、利用者の会話や秘密は記録しない |
| 原因の根拠と戻せる範囲 | 1つの差を除く・戻す・再適用するなど、どの比較が原因を支持するかを書く。改善しなかった試案、悪化した別の指標、変更を残したか撤回したかも該当時に残す。次に同じ兆候が出たとき、最初に比較する処理と、維持する隣の経路を示す |

### 切替時の基準を確かめる試験と、切替間隔の限界を調べる試験

| 知りたいこと | 実行方法 | 結果の読み方 |
|---|---|---|
| 決めた条件で以前の動作と音質を保てたか | `python3 scripts/audio_e2e.py --switches-only` | 14区間の切替は各操作後に2秒待つ。定常波形・音の段差・最長無音と内部処理を判定する。共有入出力の復帰も別の試験で確認する |
| 短い間隔で操作を繰り返すと、どの音が先に崩れるか | `python3 scripts/audio_e2e.py --switch-limits-only` | 600 Hzの入力と14区間の操作順を保ち、待ち時間を2秒、1秒、0.5秒に変える。各条件で音声処理を新しく開始する。各区間の値と目標外の箇所を記録する |

限界試験が終わったら、`pipeline-measurements.json` から待ち時間別に `switch-limits-2000ms`、`switch-limits-1000ms`、`switch-limits-500ms` を読む。測定の成否と品質目標の達否を区別する。3条件のうち目標に届いた条件、外れた条件、測定できなかった条件を示す。確認した間隔と間隔の間は未測定として扱う。同じ値がすでに保存されていれば、その値を先に使う。

3条件の観測結果を保存済みの記録から読み出す。

```sh
jq -r '.[] | select(.scenario | startswith("switch-limits-")) |
  [.intervalMilliseconds, .qualityObservation, (.stages | length), (.unmetStages | join(", "))] | @tsv' pipeline-measurements.json
```

各間隔の `qualityObservation` は、測れた全項目が目標内なら `met`、目標を外れたら `unmet`、測定が成立しなければ `unavailable`。目標外の区間名は `unmetStages` に残る。限界試験の成功は測定を完了したことを示す。受入には基準試験の結果を使う。判定器だけを確認する場合は、Macで次の試験を使う。16 kHzの合成波形に119、120、121 msの無音を入れ、最初の2件が上限内、最後が超過と判定されることを確かめる。

```sh
xcodebuild test -scheme RideIntercomAudioE2E -configuration Debug-Validation -destination 'platform=macOS' -only-testing:RideIntercomAudioE2ETests/SwitchMeasurementTests
```

### 音声が壊れたか、品質が変わったかを判断する

まず[実装状況と品質目標の判定](../policies/文書作成規約.md#実装状況と品質目標の合否を引き継ぐ)を記す。そのうえで、同じ話者・方向・操作・入力・観測点の過去の成功記録と比べる。機器、OS、コード、試験音、測定窓、判定式のうち比較に影響する差を明示する。条件をそろえられない場合は、それぞれの合否を保ち、品質の変化は「比較できず」と書く。

| 保存した結果に現れる差 | 次の担当者に伝えること |
|---|---|
| 以前は相手に音が届いた。今回は同じ操作で音が届かない、または必要な経路へ切り替わらない | 動かなくなった機能と範囲。録音や測定自体の失敗は区別する |
| 音は届くが、以前は満たした上限を超えた | その条件で品質が劣化したこと、指標、以前の値、今回の値、上限。原因となる変更は根拠が得られた時点で追記する |
| 上限内でも、無音や遅延が以前のばらつきを超えて長くなった | 「目標は達成、以前より劣化」とし、比較した区間と差を記録する |
| 音が届き、指標が良い方向に変わった | 同じ条件で比較した値と改善幅。目標にまだ届かないときは「改善したが未達」、修正と結果の対応を確かめて目標に戻った範囲を「回復」とする。同じコードで再実行して目標に届いた場合は「今回は達成、回復は未確認」とする |
| 差が測定のばらつきの範囲にある、またはばらつきに対して小さく改善か劣化かを判断できない | 観測した差と合否を記録し、変化の方向は未確定にする。原因や採否の判断に必要な場合だけ追加測定する |

複数の指標が違う方向に動いた場合は、機能全体をまとめて「改善」と判定しない。たとえば最長無音が短くなっても、同じ試験で定常波形が崩れたなら、切替中の連続性と定常時の音質の両方を書く。

**記録の監査**では、今回の履歴と既存の差分・測定の対応をたどる。比較条件をそろえた結論か、修復で戻った性質と残った失敗を分けたか、同じ症状を別の原因でも説明できるかを確認する。不足の指摘には「どの判断ができないか」「どの証跡・値をどの段で照合すれば埋まるか」を含める。既存記録で分かる箇所は補い、その結果を読み直す。未観測・再現せず・原証跡なしの場合は、その境界と次の一手を残す。

[音声の現行仕様](../spec/App/音声処理仕様.md#安定した音声動作の理由と変更範囲)には採用した仕組みと効く条件、履歴には当時の失敗と比較、未解決の修正は[共通バックログ](../backlog/README.md)、確認だけが残る条件は[未確認事項](../validation/未確認事項.md)へつなぐ。失敗したrunの値は後の成功でも保持する。[送信分離の修正前後を比べた例](../validation/history/音声同一性と途切れの再現.md#送信分離の再onで同じ症状が出たときの比較)・[受話再開の無音をサンプル位置から絞った例](../validation/history/音声同一性と途切れの再現.md#位置調整で発話の途中に447msの無音が入る)

## Fixture

同梱WAVはmacOSの音声合成で生成した48kHz・mono・PCM16の発話である。実行のたびに音声合成や外部サービスを呼ばず、同じWAVを繰り返す。実際の利用者の会話は含まない。

| ファイル | 声・生成条件 | 長さ |
|---|---|---|
| speech.wav | Samantha、英語 | 約4.48秒 |
| reply.wav | Daniel、別の英語文 | 約3.57秒 |
| speech-ja.wav | Kyoko、日本語、`say -r 180` | 約13.70秒 |
| reply-ja.wav | Reed（日本語）、別の日本語文、`say -r 210` | 約13.90秒 |

日本語入力は2026-10-29に`/usr/bin/say -v <voice> -r <rate> -o <file.aiff> <text>`で生成した。変換には`afconvert -f WAVE -d LEI16@48000 -c 1`を使った。原文は以下の通り。

> 次の信号を右に曲がってください。橋を渡ったら、広い駐車場で待ち合わせましょう。後ろの二人も聞こえていますか。ゆっくり進むので、安全なところで返事をしてください。

> こちらは全員そろっています。少し風が強くなりました。トンネルを抜けてから、青い看板の手前で止まります。三人目は赤い自転車です。到着したら、もう一度連絡します。

## サーバーモックの範囲

Mac側のテストターゲットが`127.0.0.1`だけでWorker API / WebSocket membership / SFUを起動し、終了時に全connectionを閉じる。資格はrun固有のfixture値であり、実Cloudflare資格・外部サービスは使わない。

| 境界 | 実際に通るもの |
|---|---|
| アプリ | アプリ側のアダプターとRTC RouteManagerを使う。通信にはCloudflareRealtimeSignalingClient、URLSession HTTP / WebSocket、WebRTCNativeEngineを使う |
| 媒体 | 両端末と模擬SFUの間の実ICE / DTLS / SCTP。信頼性あり制御channelと信頼性なし音声channel |
| 模擬SFU | 同梱WebRTCエンジンで受信した暗号化済みgroup envelopeを相手の接続へ転送。発話の生成・復号・decodeをしない |
| 模擬Worker | join / publish / pull / renew / deleteとmembership通知。実Cloudflareの運用認証・quota・TURN・請求の検証は含めない |
| 起動制約 | localhostへのHTTPだけを使い、既存のRTC clientのlocalhost許可範囲を利用。製品のHTTPS設定UIは変更しない |

WebSocketのhandshake / framingは[RFC 6455](https://www.rfc-editor.org/rfc/rfc6455)に従う。テストサービスは2参加者のmembership通知に必要な範囲だけを実装し、汎用WebSocketサーバーとして公開しない。

物理iPhoneのマイク・Bluetooth・ロック中の動作と、実Cloudflareの運用結果は、このSimulatorとサーバーモックの結果で代用しない。

## 低遅延・微小不連続・会話の自動検証

```sh
# 実iOS capture → VAD → TX isolation → codec → RX → hardware output、3音声×3codec
python3 scripts/audio_e2e.py --realtime-only
# native codecの全提供bitrateと、VAD/DSPを含む送信結合
python3 scripts/audio_e2e.py --codec-only
# 8人の実RouteManager / codec、仮想の複数配送経路、実hardware mix
python3 scripts/audio_e2e.py --group-only
# 再生を続けながらcodec / rate / isolationを切り替える
python3 scripts/audio_e2e.py --switches-only
# 1〜3秒の間と短い相槌を両端末で照合する（20秒以上）
python3 scripts/audio_e2e.py --matrix identity --speech-pair conversation --seconds 20
```

| 試験 | 追加した厳密な条件 |
|---|---|
| realtime-only | 3音声×PCM16/Opus/AAC。共通host clockと単一offsetでcapture→最終renderを測り、10msの計測余裕を加えて125ms以下。capture・actorへの受け渡し・renderの破棄0、処理失敗0、全文同一性、会話の相槌一致 |
| codec-only / native | 4音声×22 codec/rate/bitrate条件。既存の全文判定に加えmissingActiveRatio=0、会話は各相槌も一致。fallbackを認めない |
| codec-only / transmit | 2声×入力quantum 256/960sample×isolation ON/OFF×3codecの24条件。実App送信VAD/DSP/codecを通して2周再生し、欠落0と相槌を検査 |
| group-only | 8人の独立時計、PCM/Opus/AACと異なるbitrate/rate、Localだけを使う参加者、Internetに限る参加者、両方を使う参加者。仮想経路の遅延・jitter・複製を実認証/暗号化/中継へ与え、全話者の順序・欠落・重複・codec境界と7話者同時mixを検査。1/2/3秒後の100ms相槌も残ること |
| switches-only | 14区間で送受信isolationとPCM/Opus/AAC・16/24/48kHzを変更。送信はPCM16で初回のON、AACで再ONと解除を試す。通常区間は微小不連続oracle、切替区間はsample段差0.04未満・無音120ms以下、内部破棄0・エラー0。全体を実render WAVで保存。別テストで共有I/Oを4回切替し、各操作500ms未満・復帰後の定常toneを検証。600Hzと1,100HzのPCM16を同時に再生し、600Hzの相手だけを20回切り替える。受信を拒否せず、最終出力の段差が0.04未満、1,100Hz成分が切替前の振幅の70%を超えることを切替付近の10ms窓で確認する。定常時の分離効果と最終出力WAVも照合する |
| 微小不連続の負例 | 全体の0.1%に当たる1ms欠落・1ms重複、単発clickを必ず拒否。単一正弦波fit後の最大2ms残差RMS≤0.006・sample段差≤0.10。平均誤差で薄めない |
| 相槌の負例 | 「うん」「ふん」を個別に消した音声を拒否。whole recordingで決めた同じoffsetの位置で相関≥0.65を要求し、別の良い断片へ探し直さない |

8人試験の転送は決定的な仮想経路であり、8台の物理無線機器・実Cloudflare SFUの測定ではない。ネットワーク2端末試験とは独立して必要とする。realtime-onlyも空気伝搬・Bluetooth・物理iPhoneの口から耳を測った結果ではない。native SoundIsolationのalgorithmic latencyは有効な段数に応じて加算されるため、任意に重ねた設定や全ネットワークで125msを保証するものではない。

各専用modeで選ぶXCTest、必要な測定ID、追加の事前試験と実行時間の上限は `scripts/audio_e2e_matrix.py` の同じ定義を使う。選択したXCTest数と実行数が一致し、回収した測定IDが必要なIDと一致するときに受け入れる。測定JSONは `pipeline-measurements.json` に集約する。たとえば `--switches-only` は共有I/Oと連続切替のXCTest 2件を実行し、`input-mode-recovery` と `live-settings` の測定をそれぞれ1件要求する。preflightはiOSの負例・micro gap・相槌負例・native sessionの計5件と、Macのfixture時刻検査2件を必須にし、skipは認めない。switches-onlyのiOS事前試験は送信分離の再ONと二人の受信分離切替も実行する。packet到着・capture・OS制御の時刻traceはE2E専用attachmentへ保存し、本番のframeごとのログには追加しない。

conversation-ja.wav（Kyoko、約16.38秒）とconversation-reply-ja.wav（Reed、約14.89秒）は1/2/3秒の休止と「うん」「ふん」を含む。原文・各発話の正確な開始終了はFixtures/conversation-manifest.json、再生成はscripts/build_conversation_fixtures.pyに従う。毎回のテストでは同梱WAVを使う。

## ビルド成果物の再作成

既存のbuild productsに問題がある場合は`--clean-build`を指定し、Xcode既定のDerivedData内で標準のcleanを行ってから再構築する。別のcacheやprojectコピーへ切り替える復旧策は使わない。bundle identifierや署名方式を実行ごとに変更せず、OSの許可リストを増やす方法を復旧策にしない。local networkの拒否とbuild／hostの不整合は結果を分けて記録し、確認していない原因を権限不足と決めつけない。

録音probeのsample領域は開始前に確保・初期化し、音声callback内で配列の拡張やcopy-on-writeによる大量のデータのコピーを避ける。snapshotは記録済みprefixをrender用lockの外で複製し、設定区間の境界はsample数だけを読む。snapshotとresetは同じ試験ownerが順に行い、解析中の領域を書き換えない。iOS captureの時刻不連続も測定JSONへ残し、内部ringのdrop counterとは別に検出する。

fixtureの再生位置は最初のcapture時刻と現在のcapture時刻の差から求める。native I/Oが中断した場合、その区間のsource sampleを省略し、その後の発話全部を後ろへずらさない。10msの欠落で正確に10ms分のsource sampleを省略し、以後の時計を保つ正例を事前検査する。欠落・繰り返しの拒否閾値は変更しない。

性能測定では`--configuration Release`を明示し、通常Releaseと同じ最適化を持つ標準構成`Release-Validation`を使う。DEBUGマクロは追加せず、内部API参照に必要な`ENABLE_TESTABILITY=YES`と検証namespaceをprojectの標準設定へ置く。既定のDebugは通常検証と同じ`Debug-Validation`を使い、schemeのTestActionで明示したsigned-out fixtureから起動する。通常Debug／Release／Archiveの設定は変更しない。コンパイラ条件・namespace・署名設定をCLIから上書きしない。`configuration.json`に測定構成、`build-settings-<platform>.json`にXcodeで解決した構成と生成先を記録する。資格を含み得るbuild settings全体は保存しない。音声同一性・欠落ゼロ・125msの判定は構成によらず同じものを適用し、Releaseの成功で既存のDebug失敗を成功へ書き換えない。

MacとSimulatorは同じMacのCoreAudio serviceを共有する。2つのhostのnative graph初期化を同時に開始せず、最初のhostが初期化完了を通知してから次を起動する。初期化は30秒を上限とし、失敗時は後続hostを起動せず所有processを回収する。通話開始後の双方向送受信・capture/render時計・判定閾値は変えない。

## 検証用の送話側から通常の通話を始めた端末へ発話する

受話端末を一度準備してマイクOFFでロックする試験には、`RideIntercomAudioE2E`の`testDuplexSpeechOverNetwork`を送話側だけに使う。通常の音声E2Eと同じ隔離済みホストを用意する。送話側で`AUDIO_E2E_ROLE=b`、`AUDIO_E2E_TRANSPORT=local`、`AUDIO_E2E_STANDALONE_RECEIVER=1`を指定する。`AUDIO_E2E_RUN`には新しいUUIDを設定し、発話6〜20秒のsmokeシナリオを1件選ぶ。受話端末は既存の[実機用検証App](自動検証.md#ios実機の準備とロック中の検証を分ける)を使う。

送話側のログで`AUDIO_E2E_STANDALONE_INVITE_READY`が出たら、送話側のAppのdata containerで`tmp/RideIntercom.AudioE2E.<実行ID>.b/receiver-invitation.url`を読む。試験用の招待リンクは受話側の起動時だけ渡す。[試験用グループの自動開始](自動検証.md#試験用グループをマイクoffで自動開始する)で、受話側のグループ選択、通話開始、マイクOFFを自動化する。招待リンクはログ・結果の添付・Gitに残さない。

受話端末の背景・単独待機・マイクOFF・受信0の継続を確認してから、同じ送話側フォルダに空の`join`ファイルを作る。送話側は合図を最大10分待ち、近距離の認証とメディア開始後に試験音声を送る。送話側の結果には発話を確認した時刻と符号化packet数だけを残す。受話側の記録で、同じ通話の識別子・期限、認証、受信と発話区間の有声出力を照合する。実機はロック中の観測を確認する。Simulatorでの手順確認では、同じ通常画面を既存の`testStandardMutedWaitingKeepsAudioInBackground`で操作し、UIテスト側の`RIDEINTERCOM_WAIT_FOR_AUDIO_E2E_INVITATION=1`で外部の招待を待つ。

再起動したAppで受話を確認する場合は、受話側の`testSavedGroupStartsLocalAfterColdOfflineLaunch`に`RIDEINTERCOM_COLD_START_PEER_GROUP`として送話側の実行UUIDを渡す。受話側の`AUDIO_E2E_RECEIVER_WAITING_FOR_INVITE`を確認して招待を開く。受話側は保存・終了・再起動を経て一覧で選んだ後に`AUDIO_E2E_RECEIVER_WAITING_AFTER_RESTART`を出す。音声準備・受信0を確認してから送話側の`join`を作る。受話側は「会話中」を確認し、相手が離脱したら待機に戻る。音声の判定は受話側の`background-call-standard-open.json`を使い、待機時と同じプロセス・通話・自動切断期限で、近距離での認証、受信、復号、native出力の有声を照合する。[再起動後の受話結果](../validation/history/近距離オフライン通信.md#再起動後の待機から相手が参加して受話へ進む)
