# SoundIsolation package 設定値

## 目的

本書は RideCom App が `SoundIsolation` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## VoiceIsolationConfiguration

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| TX `VoiceIsolationConfiguration` | 標準のvoice、mix 0.5 | 固定 |
| RX `VoiceIsolationConfiguration` | 標準のvoice、mix 0.5。切替では信号経路とbypassを変更する | AppAudioPipelineの通話用固定値 |
| TX effect chain 挿入 | 対応時はnodeを保持、`isSoundIsolationEnabled` でbypassを切替 | Settings の送信設定と runtime support から導出 |
| RX peer bus effect chain 挿入 | 対応時はnodeを保持、`remoteSoundIsolationEnabled[peerID, default: false]` でbypassを切替 | Call の参加者設定と runtime support から導出 |
| RX master bus effect chain 挿入 | 対応時はnodeを保持、`receiveMasterSoundIsolationEnabled` でbypassを切替 | Call の master 出力設定と runtime support から導出 |
| runtime snapshot | `VoiceIsolationRuntimeSnapshot` を chain ごとに `RTCRuntimePackageReport` と AudioMixer effect metadata に載せる | runtime report |

Settings の `Voice Isolation Effect` は送信用 `SoundIsolation` package の effect-level 設定として扱う。Call の参加者行と master 出力行は受信側 peer bus / RX master bus の effect-level 設定として扱う。SessionManager の `AudioInputVoiceProcessingConfiguration.soundIsolationEnabled` へは渡さない。mix などの Audio Unit parameter は画面設定にしない。

| 状態 | App の扱い |
|---|---|
| chain ごとの有効設定が `true` かつ `VoiceIsolationSupport.isAvailable == true` | 該当 bus の effect chain に `VoiceIsolationEffect` を挿入する |
| chain ごとの有効設定が `true` かつ `VoiceIsolationSupport.isAvailable == false` | Toggle を非表示にし、support reportで非対応とする。存在しないnodeをchainへ捏造しない |
| chain ごとの有効設定が `false` | 実Audio Unitのbypassを有効にし、runtime chain snapshot では bypassed stage として返し、Diagnostics はその snapshot を表示する。実音声処理では no-op / bypass として扱い、App 側で別の表示用 stage を作らない |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| wet / dry mix | 送信は0.5で固定。受信は有効設定から導出 |
| Audio Unit parameter | package 仕様を正とする |
| support check / fallback の詳細 | package adapter で扱う |

詳細な SoundIsolation の仕様は `docs/spec/packages/Audio/Effectors/SoundIsolation.md` を正とする。

## 通話の音声保持

各経路で音声分離が有効なときは、処理音50%・原音50%を混ぜる。送信・相手別・全体を重ねた場合も、各分類器が落とす弱い音節を残すための設定である。各Audio Unitは生成時にmixを50%に設定し、ON・OFFに応じて信号経路とbypassを切り替える。設定をONに戻すと、初めからONだったときと同じ割合で処理する。Diagnosticsは設定されたmixと実際のactive／bypassedを示す。走行音とBluetoothの聞こえ方は実機で確認する。
