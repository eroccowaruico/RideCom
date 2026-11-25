# AudioMixer package 設定値

## 目的

本書は RideCom App が `AudioMixer` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## Mixer 設定

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| format | TXの処理は48kHz monoで、sinkは選択したRTC形式。RXの処理は実出力と設定のうち低いsample rateで行い、sinkはSessionManagerのactualHardwareFormat。[受信の処理形式](../../../音声処理仕様.md#音声-lifecycle) | adapter 導出 |
| `addPCMSource.maximumBufferedDuration` | TXは同期AudioFrameProcessorで再生queueを持たない。RXは`0.12`秒（再生開始までの待ちと単一frame長。出力時計の開始前に溜まった音声もこの幅を超えると再基準化する）、Audio Checkは`nil` | adapter固定 |
| `addPCMSource.captureTimePlayoutDelay` | TXは待機なし。RXは描画済みブロックの終端から`0.002`秒を下限に`adaptivePlayout`を有効化、Audio Checkは`nil` | adapter固定 |
| TX busのエフェクト | Appが `tx-bus` にSoundIsolation → DynamicsProcessor → PeakLimiterの順で登録する。SoundIsolationは対応機器で登録し、設定値で配線を切り替える。VADGateはMixerの前に置く | 固定の処理順と画面設定 |
| RX peer busのエフェクト | 対応機器では `rx-peer-{peerID}` にSoundIsolationを登録し、`remoteSoundIsolationEnabled` で配線を切り替える。無効なノードは遅延補償の対象から外す | 画面設定から導出 |
| RX master busのエフェクト | 対応機器では `rx-master` にSoundIsolationを登録する。master faderの後に `rx-output` busを接続し、PeakLimiterを登録する | 画面設定と固定の処理順 |
| master bus volume | `isOutputMuted ? 0 : overallOutputVolume` | 画面設定から導出 |
| peer source volume | `remoteOutputVolumes[peerID]`。未設定 peer は `1.0` | 画面設定から導出 |

受信側は peer ごとに RX peer bus を作り、全 RX peer bus を receive master bus へ route して mix down する。相手が複数いる場合は peer bus も複数になり、master bus は mix 後の 1 本だけを表す。

AudioMixerは実際に登録された処理順と各エフェクトの状態を `MixerBusSnapshot.effectChain` で報告する。Appの `transmitEffectChainSnapshot`、`receivePeerEffectChainSnapshot(peerID:)`、`receiveMixEffectChainSnapshot` はその値から表示を組み立てる。処理順と設定値を表示用に定義し直さない。

RX masterの表示用effect chainは、実snapshotの `rx-master.effectChain` と `rx-output.effectChain` を信号順に結合する。speaker-output sinkはrx-outputに置き、最終Limiterの後段に追加gainを置かない。

## Snapshot / graph の扱い

| snapshot | App での扱い |
|---|---|
| `AudioMixerSnapshot.busIDs` | TX bus、RX peer bus、RX master bus の存在確認に使う |
| `MixerBusSnapshot.sources` | マイク入力、RTC peer audio source、予約時間・リセット回数を確認する |
| `MixerBusSnapshot.effectChain` | Diagnostics の effect chip の順序、状態、詳細に使う |
| `AudioMixerSnapshot.routes` | RX peer bus から `rx-master` への mix down 表示に使う |
| `AudioMixerSnapshot.outputBusID` | 最終出力へ接続された bus の確認に使う |
| `MixerGraphSnapshot.nodes` / `edges` | グラフ描画が必要な UI では node / edge をそのまま使う。App 固有の推測で経路を補完しない |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| default format | package 仕様を正とする |
| bus ID / routing | App adapter の固定構成として扱う |
| effect chain 再構築 | package adapter が扱い、画面設定にしない |
| effect index | package adapter が扱い、画面設定にしない |
| soft clip / limiter の内部値 | Effectors 側の設定に寄せる |

詳細な bus、format、routing の仕様は `docs/spec/packages/Audio/AudioMixer.md` を正とする。

通話TXはAudioFrameProcessorの同期manual renderingを使う。native effectを通したPCMを10ms単位でCodecへ渡す。送信パケットの扱いは[音声処理仕様](../../../音声処理仕様.md#通話の再生予約)に従う。受信のrender通知は実Audio Unit quantumで受け、再生sinkは20msを上限に分割する。100ms tap待機、送信用player、2つ目の送信hardware clockは使わない。

RXは相手ごとのcapture clockをplayer clockへ対応付ける。連続sampleは隙間・重複なく予約し、到着が遅れた場合だけ必要な分を遅らせる。既に出力済みの発話を切り詰めず、無音中に増えた待ちを短縮する。開始待機は2msで、揺れのない相手には待ちを追加しない。iPhone間のWi-Fiが相手のpacketを保持してまとめて届ける場合は、AudioMixerが学習した待ちを会話の間でも保つ。学習値は開始待機などを除いた予約枠の半分までとし、まとまって届く後続packetにも余裕を残す。無音を短縮するときも、通常のまとまりに含まれる間隔を保つ。適応再生の判定は[AudioMixerパッケージ仕様](../../../../packages/Audio/AudioMixer.md)を参照する。0.3秒へ広げた候補は、出力時計の開始前に溜まった最大0.3秒の待ちが通話中に残るため採用しない（2026-11-03の音声E2E）。時計の大きなジャンプや120msを超える停滞は再基準化する。

PCMを出力backendへ渡す経路では、[再生予約の上限](../../../音声処理仕様.md#通話の再生予約)に従う。これは過負荷時の鮮度制限であり、固定の待機追加はない。無音frameも渡してcodecと再生の時計を維持する。各境界の上限は端末間遅延の保証ではない。

Codec、bit rate、RTC PCM formatの変更では受信Mixerと相手decoderを保持し、送信encoderとsink target formatだけを更新する。effect有効状態を変えた場合は、packageが報告する処理遅延の間だけPCMStreamTransitionの2msフェード付き無音を入れ、古い音を貯めて後から流さない。通常の連続PCMは加工しない。
