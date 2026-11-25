# SoundIsolation package 設定値

## 目的

本書は RideCom App が `SoundIsolation` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## VoiceIsolationConfiguration

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| `VoiceIsolationConfiguration` | 送信・相手別受信・受信全体のいずれも `.voice`、`mix: 0.5` | AppがAudio Unitの生成時に指定する固定値 |
| 送信のON／OFF | `isSoundIsolationEnabled` | 設定画面で保存した値。通話とAudio Checkで共用する |
| 相手別受信のON／OFF | `remoteSoundIsolationEnabled[peerID, default: false]` | 通話画面で指定した相手の設定 |
| 受信全体のON／OFF | `receiveMixSoundIsolationEnabled` | 通話画面で指定した出力全体の設定 |

Settings の `Voice Isolation Effect` は送信用 `SoundIsolation` package の effect-level 設定として扱う。Call の参加者行と master 出力行は受信側 peer bus / RX master bus の effect-level 設定として扱う。SessionManager の `AudioInputVoiceProcessingConfiguration.soundIsolationEnabled` へは渡さない。mix などの Audio Unit parameter は画面設定にしない。

| 状態 | App の扱い |
|---|---|
| `VoiceIsolationSupport.isAvailable == true` で対象busを作る | ON／OFFにかかわらず `VoiceIsolationEffect` を生成し、Mixerの順序付きeffect一覧に登録する |
| 対応環境でON | Audio Unitのbypassを解除し、Mixerが該当ノードを音声経路につなぐ。実行状態は `active` |
| 対応環境でOFF | Audio Unitをbypassにし、Mixerが該当ノードを信号経路から外す。ノードとmixを保持し、実行状態は `bypassed`。外したノードの遅延は残る経路に加えない |
| `VoiceIsolationSupport.isAvailable == false` | ON／OFFにかかわらずノードを作らない。操作を非表示にし、support reportで非対応と示す |

Appは `VoiceIsolationRuntimeSnapshot` を `RTCRuntimePackageReport` に載せ、AudioMixerのeffect metadataにも状態を反映する。Diagnosticsは設定した混合比と実行状態を区別する。表示用の効果ノードは作らない。

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| Audio Unit parameter | package 仕様を正とする |
| support check / fallback の詳細 | package adapter で扱う |

詳細な SoundIsolation の仕様は `docs/spec/packages/Audio/Effectors/SoundIsolation.md` を正とする。

## 通話の音声保持

ONに戻しても生成時と同じ混合比を使う。複数段で処理しても、各段が落とす弱い音節を原音から残すための値である。切替時の準備と出力保護は[Appの音声処理仕様](../../../../音声処理仕様.md#声の分離を切り替えるときの準備と出力保護)を参照する。走行音とBluetoothの聞こえ方は実機で確認する。
