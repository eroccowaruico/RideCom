# RideCom Diagnostics 画面項目

## 表示実装の所有

| 所有者 | 責務 |
|---|---|
| DiagnosticsInput | 更新時にViewModelから必要な値だけsnapshot化。子ViewはViewModelを保持しない |
| TransmitPipelinePresentation / ReceivePipelinePresentation | snapshotから状態・理由・step・peer表示を純粋に導出。RXは各段に1つの名前と識別子を持ち、待機・通話中の状態と詳細を同じ段へ投影する。副作用やObservable状態を持たない |
| LiveTransmitPipelineView / LiveReceivePipelineView | 表示順と画面構成。既存の項目・更新周期・識別子を維持 |
| PipelineComponents / ReceiveMixViews / DiagnosticsPipelineDetails | 必要な表示値だけ受け取る描画部品。色とアイコンの対応も描画側に置く |


各pipeline行とeffect stageは、既存状態を色と記号で示し、VoiceOverの値に状態語と既存の詳細を含める。`passing`はPassing（checkmark）、`waiting`はWaiting（pause）とする。`blocked`はBlocked（octagon）、`idle`はIdle（dashed circle）とする。Passingには累計のpacket・frame数に基づく状態も含まれ、現在の流量を証明しない。特大文字では行の名前・package・詳細を折り返す。effect stage chipは、色と記号の`PipelineStepState`が`waiting`と`unavailable`、`bypassed`と`idle`を同じ値にまとめる。各組の違いを残すため、名前の右にまとめる前の`AudioEffectStageRuntimeState`の値（`active`・`waiting`・`unavailable`・`bypassed`・`idle`）をそのまま文字で出す。VoiceOverの値にもその語を使う。

## 目的

本書は Diagnostics タブの UI 項目を定義する。

Diagnostics はログを読む代替ではない。音声 pipeline の現在状態は送信/受信パイプラインで見せ、現在状態一覧は pipeline から読み取れない App 状態と network quality に絞る。

## 入力データ

Diagnostics は package から得た runtime snapshot / report を正とする。App は表示名、折り返し、severity への写像だけを担当する。mixer 経路、effect chain、codec fallback、SessionManager resolved 値、RTC 接続状態を App 固有の固定値で作り直さない。

| 入力 | 主な参照先 | 描画先 |
|---|---|---|
| `AudioMixerSnapshot` | `audioMixerSnapshot` | TX Bus、TX FX、Peer Buses、Mix Down、RX Master、Master FX、mixer graph |
| `MixerBusSnapshot.effectChain` | `transmitEffectChainSnapshot`、`receivePeerEffectChainSnapshot(peerID:)`、`receiveMixEffectChainSnapshot` | effect stage chip の順序、状態、detail |
| `CodecRuntimeReport` | `codecRuntimeReport`、`selectedTransmitCodec` | Codec / Decode |
| `VADGateRuntimeSnapshot` | `vadGateRuntimeSnapshot` | VAD stage、発話状態、判定入力のRMS、noise floor、threshold、gain |
| `VoiceIsolationRuntimeSnapshot` | SoundIsolation report / AudioMixer effect metadata | SoundIsolation stage |
| `DynamicsProcessorRuntimeSnapshot` | DynamicsProcessor report / AudioMixer effect metadata | DynamicsProcessor stage |
| `PeakLimiterRuntimeSnapshot` | 接続したTX / RX出力Limiterの実設定 | 起動前・停止後はruntime stageを表示しない |
| `SessionManager` report / snapshot | session、input、output、voice processing の直近 report | Session、Input、Output |
| `RTC.RouteMetrics` | `lastRouteMetrics` | Networkの経路別の計測値 |
| `RTCRuntimeStatus` | `remoteRuntimeStatuses` | remote package runtime 状態の入力 |
| App 状態 | group、invite、display name、local UI state | Call、Invite、参加者名 |

## 画面構成

`diagnosticsPagePicker`でOverview、TX、RX、Network、Appliedを切り替える。5ページの選択には、全ページが一目で見える標準のsegmented Pickerを使う。iOSのアクセシビリティ文字サイズでは5つの区画が入らないため、同じ識別子の標準NavigationLinkから選択List（`diagnosticsPageSelection`、選択中にcheckmark）を開き、選ぶと元の画面へ戻る。幅900pt以上（`AppSize.diagnosticsTwoColumnMinimumWidth`）で通常の文字サイズを使い、Overview以外を選んだときは、Overviewと選んだページの2列を並べる。2列では各列が最大560pt（`AppSize.callColumnMaxWidth`）。幅が足りない場合、アクセシビリティ文字サイズの場合、またはOverviewを選んだ場合は、選んだページを最大640pt（`AppSize.singleColumnMaxWidth`）の1列で表示する。Overviewには送受信の判定と流れ、参加者、経路を表示する。通話と招待の現在状態はAppliedのCall・Inviteに表示する。画面内のページ選択は表示状態であり、ViewModelのsnapshotや通話状態を作り直さない。ページは上部の選択から切り替える。TXの各段とRXの相手および出力詳細は標準DisclosureGroupで開閉する。

TX/RXは従来のpipeline、Networkは、[Network診断](#network診断)のとおり、Local・Internetの計測カードと、最後に観測した相手ごとの経路を示すPathsを表示する。session全体のevent dropsはカードの上の1行。Appliedは`Requested → Applied`のカードで、1行に項目名・値（要求と適用が違えば「要求 → 適用」）・判定を置く。判定は、実装が比べている行（Codec・Session・Input sample rate）だけに出し、同じなら「Same」（success）、違えば「⚠ Differs」（warning）。Codecは`CodecIdentifier.displayName`と`48 kHz · 48 kbps`の単位で出す。経路が一致する単一の最新metricsのみ利用し、未取得値をNot measuredとする。Overviewは先頭の判定（`diagnosticsVerdict-TX`／`-RX`、`PipelineVerdict`）で、TX・RXそれぞれ最初のblocked／mutedの段を選ぶ。該当する段がなければ最初のwaitingを選ぶ。その段を`TX: Waiting at VAD`の形で太字にし、下の行にdetailを理由として出す。全段passingは`Passing`、全段idleは`Idle`、passingの後にidleが残るときは`Idle at {段}`。状態は文字サイズに合わせて大きくなる8ptの点（idleは破線の輪）と語で示す。続けて`Pipeline`に、TXとRXの主要な段を方向ごと（`diagnosticsStageDots-TX`／`-RX`）に並べ、処理順を矢印で、状態を記号と色で示す。TXではInputとTX Busの間にVADを置く。VADは観測したSpeechならPassing、SilenceならWaiting、音声準備前やミュート中はIdle。TX Busのエフェクトはその段の詳細に並べる。バス未観測またはエフェクトが待機・利用不能の場合は、TX BusをWaitingとして理由を表示する。狭い幅では直前の矢印・記号・段名をまとめて折り返す。VoiceOverは「TX: Session Passing, …」と1要素で読む。`Participants`は見出しに自分以外の人数を出す。1人1行で名前と観測した経路を表示する。経路は`Local · direct`／`Local · relayed`／`Internet`、未観測は`—`。保存された`PeerConnectionState`は点と語（`Connected`／`Connecting`／`Offline`）で出し、Offlineを薄く表示する。`Network`は経路が観測されたときだけ、1経路1行で経路名・相手数・`RTT`（未取得は`Not measured`）。TX/RXは機器、VAD、観測経路、相手別情報と出力buffer/resetを既存値から表示し、差分履歴を持たない毎秒値はNot measuredとする。Appliedはcodec、Sessionの要求と解決済み設定、stream実測sample rate、未計測のIO bufferを表示する。Unsupported、Ducking、機器、VAD、isolation、Call/InviteおよびInternet Serviceも表示する。Sessionの解決済み設定はハードウェア実測と区別し、未取得はNot measuredとする。

| 項目名（日本語） | 項目ID | 目的 | 実装 | 更新周期 | 表示仕様 |
|---|---|---|---|---|---|
| 診断画面 | `diagnosticsScrollView` | package runtime report と App 状態を要約する | `DiagnosticsView` | 表示中0.5秒。開く時点は即時、非表示のsnapshot作成は5秒 | `TimelineView` + `ScrollView` |
| 送信パイプライン | `liveTransmitPipelineView` | ローカル送信がどこまで進んでいるかを読む | `LiveTransmitPipelineView` | 0.5 秒 | compact row。effect chain は TX bus 内に内包表示 |
| 受信パイプライン | `liveReceivePipelineView` | 受信してから出力するまでの進み具合を読む | `LiveReceivePipelineView` | 0.5 秒 | compact row。peer bus は複数行一覧、effect chain は該当 bus 内に内包表示。RX master FXは実グラフの内容のみを表示する |

### 通話の音声が一時停止したとき

選択中の通話が現在の通話と一致し、`isAudioPausedForDeviceChange` が真の場合に、Overviewで送受信の判定の上に音声停止の行（`diagnosticsPausedCall`）を表示する。認証済みの相手がいれば `Connected / Audio Paused`、認証済みの相手がいなければ `Audio paused` とする。理由にはCallと同じ `audioRouteNotice` を使い、再開の失敗で通知文がない場合は `audioPauseError` を使う。送受信の判定と各段はそれぞれの観測を示す。再開の操作はCallで行い、成功後は音声停止の行が消える。[音声機器の切替・切断と復旧](../音声処理仕様.md)

### Diagnosticsの状態と遷移

[UIスタック](../../../design/デザインシステム.md#uiスタック)の5状態を、既存のpackage report・snapshotの有無と各段の状態から導出する。ページ選択は表示状態だけを変え、どの状態でも全5ページへ移動できる。

| 状態 | 成立条件・表示 | 操作・遷移・復帰先 |
|---|---|---|
| Ideal | 通話中で各段がPassing、Networkの最新metricsが15秒以内。Overviewの要約は`Passing` | 上部から該当ページを選び、必要な段を開く。同じ選択でOverviewへ戻る |
| Empty | 通話先・通話がなく、reportが未取得。各段の値は`Not available`（状態の記号はIdleの点線の円、RTCの段だけ`Media Idle`）。Networkは接続を促す`Not measured`の文言、Appliedの未取得値は`Not measured` | 通話はCall／Users／Groupsから開始する。Diagnosticsから通話を開始・変更しない |
| Error | いずれかの段がBlocked（session・codec・RTC等の失敗）。Overviewの要約が最初のblockedの段と理由を示し、記号と語で色以外でも区別する | TX・RXから該当する段を開く。復旧操作は各機能の画面（Call・Settings）で行う |
| Partial | 一部の段がWaiting／Muted、Networkが15秒超で`Stale`、相手や経路の値が未取得。取得済みの値と`Not measured`を並べ、未取得値を推測で埋めない | 値は0.5秒ごとの更新で自然に変わる。経路の再接続はDiagnosticsから行わない |
| Loading | 画面を開いた直後。表示時に即時のreport公開を要求し、届くまでは直前のsnapshotまたはEmptyの表示を使う。専用の読込画面は持たない | 次の0.5秒更新で該当状態へ移る |

## 送信パイプライン

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態・異常系の考え方 |
|---|---|---|---|---|---|---|
| SessionManager sessionステップ | `liveTransmitPipelineView` | `pipeline-session-step` | Session | `AudioSessionSnapshot`, `audioSessionProfile`, 直近 session report | 状態アイコン + profile | session error は blocked |
| SessionManager inputステップ | `liveTransmitPipelineView` | `pipeline-input-step` | Input | `AudioInputStreamCapture` snapshot、voice processing report、`isMuted` | stream format、frame count、mute | ミュートは故障ではなく waiting |
| 発話判定 | `liveTransmitPipelineView` | `vad` | VAD | `VADGateRuntimeSnapshot.lastAnalysis`、感度preset | 判定状態と感度。展開すると`Microphone input before TX Bus Effects.`と判定入力、noise floor、threshold（dBFS）、gain | メディア準備前、ミュート中、分析がないときは`Input level: Not measured` |
| AudioMixer TX busステップ | `liveTransmitPipelineView` | `pipeline-mixer-step` | TX Bus | `AudioMixerSnapshot` の `tx-bus` のsource数・effect数と、`transmitEffectChainSnapshot`の`sound-isolation` | 閉じた行に `n in / n FX`。分離stageがあれば同じstageの名前と実状態を `Isolation active`／`Isolation bypassed` の形で併記する | 音声未準備はIdleの`Not available`。bus未観測はWaitingの`Snapshot waiting`。effectの待機・利用不能時は理由を優先する |
| AudioMixer effect chainステップ | `liveTransmitPipelineView` | `pipeline-effects-step` | FX Chain | `AudioMixerSnapshot` の `tx-bus.effectChain` から導出した `transmitEffectChainSnapshot.stages` | TX bus 配下の inline stage chip として表示 | stage 内の unavailable / bypassed を warning 以下で表示 |
| codec ステップ | `liveTransmitPipelineView` | `pipeline-codec-step` | Codec | 要求と実効codec、`AppAudioTransmitter`が生成した音声packetの現在の通話分 | requested と selected を表示。fallback 時は `requested -> selected / Fallback`。展開すると`Encoded audio packets`の累計 | fallback は warning。発話状態で生成実績があればPassing。メディア未準備は未計測。値をRTC受付・音声到着へ流用しない |
| RTC ステップ | `liveTransmitPipelineView` | `pipeline-rtc-step` | RTC | 選択通話の制御接続と経路 | 制御の接続済みは経路と`Control Connected`。展開すると最後の自端末音声を渡した経路と観測時刻 | 制御接続は音声停止中も表示する。相手側の到着と最終出力は各端末の観測を要する |

## 送信 effect chain 表示

effect chain は AudioMixer package の `MixerBusSnapshot.effectChain` を正として、App の `transmitEffectChainSnapshot` から表示する。Diagnostics は effect の既定値や stage 配列を持たない。Diagnostics では FX Chain 行の下へ stage chip をインライン表示し、TX bus の内包関係が見えるようにする。

| stage | accessibilityIdentifier | package | 表示する状態 |
|---|---|---|---|
| Isolation | `pipeline-effect-stage-sound-isolation` | SoundIsolation | `active`／`bypassed`／`unavailable`など、登録済みstageの実状態 |
| VADGate（Mixer前段） | TX effect stage IDは持たない | VADGate | 送信パイプラインの独立したVAD行で、発話状態、感度、判定入力を表示する |
| Dynamics | `pipeline-effect-stage-dynamics-processor` | DynamicsProcessor | 登録済みstageの実状態 |
| Limiter | `pipeline-effect-stage-peak-limiter` | PeakLimiter | 登録済みstageの実状態 |

| 拡張ルール | 仕様 |
|---|---|
| stage 追加 | AudioMixer package の `tx-bus.effectChain` に stage が追加されれば Diagnostics の表示順へ反映する |
| 文字列の固定を禁止 | `SoundIsolation -> VADGate -> DynamicsProcessor -> PeakLimiter` のような固定文言や default 値を UI の判断基準にしない |
| 一覧性 | stage が増えた場合は FX Chain 行の内側で折り返し、ログを読まなくても各 stage の現在状態を読めるようにする |

## 送信RTCの経路分岐

`RTC` の分岐は `pipeline-rtc-route-multipeer`（Local）と `pipeline-rtc-route-webRTC`（Internet）。選択中の通話の `RTCNetworkDiagnostics.outboundAudioDispatch` を使う。経路へ渡した場合は受付結果を表示する。受付はPassingの記号と `Accepted by transport`、不受付はWaitingの記号と `Not accepted by transport` を表示する。受付結果のないreportはWaitingと `Acceptance not measured`。近距離でInternetの相手をカバーしたときはInternetにIdleの記号と `Covered by Local`。最後のpacketで使わなかった経路は `Not used for last packet`。記録がない場合は `No audio dispatch observed`、15秒を超えた場合は `Last dispatch is stale` としてIdleにする。Internetの `Send queue` は生成から15秒以内のnetwork reportの値を使用する。相手の受信は `Peer receipt: Not measured` とする。

## 受信パイプライン

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態・異常系の考え方 |
|---|---|---|---|---|---|---|
| RTC受信ステップ | `liveReceivePipelineView` | `receive-pipeline-rtc-step` | RTC RX | route、connected peer count、authenticated peer count、受信 packet count、RTCの破棄数、Appで認証済みの音声を受け取った時刻 | 音声の準備前は `Media Idle`。音声準備済みで制御未接続なら `Control Waiting`。接続後は経路、`n connected / n authenticated`、`Last receipt` と経過秒。時刻がない場合は `Receipt time not measured`。受信または破棄がある場合に `Received packets n`、破棄がある場合に `Dropped packets n` を表示する | 音声の準備前はIdle。接続待ち・受信の未観測・最後の受信から2秒超はWaiting。直近2秒に受信を観測するとPassing。復号エラーが起きても受信の時刻は進む |
| Codec decodeステップ | `liveReceivePipelineView` | `receive-pipeline-codec-step` | Decode | 現在の受信処理で空でないPCMを返したpacket数と最終時刻、復号に失敗したpacket数と最終時刻。受信グラフを作り直すと初期化する | `No PCM observed` または `PCM n`。PCMがあれば `Last PCM` と経過秒。失敗があれば `Decode errors n` と `Last error` の経過秒。peer別のdecode codecは参加者内訳で表示 | 直近2秒にPCMがあればPassing。直近のPCMがなく、2秒以内に失敗があればBlocked。両方の観測が途絶えればWaiting |
| peer busステップ | `liveReceivePipelineView` | `receive-pipeline-peer-bus-step` | Peer Buses | `AudioMixerSnapshot.routes` の `rx-peer-*` → `rx-master` と各入力の `MixerSourceSnapshot.lastScheduledAt` | `n peer buses`。peer別の再生予約・音量・FX要約は下の参加者内訳に表示 | 音声未準備はIdle。経路のある入力のいずれかに直近2秒以内のPCM再生予約があればPassing。全入力で未観測か2秒超はWaiting |
| receive mix downステップ | `liveReceivePipelineView` | `receive-pipeline-mix-step` | Mix Down | Peer Busesと同じ経路・再生予約 | `n routes → rx-master`（1本は `1 route → rx-master`）。その経路がある参加者の枝線が左の縦線で合流し、Mix Downで線が終わる | Peer Busesと同じ判定。再生予約後の出力はOutputで確認する |
| receive master busステップ | `liveReceivePipelineView` | `receive-pipeline-master-bus-step` | RX Master | `AudioMixerSnapshot` の `rx-master`、master volume、経路数と入力のPCM再生予約 | source bus count と OUT volume。mix 後の 1 本の master bus として表示。アクセシビリティ文字サイズではメーターを集計の下に置く | Peer Busesと同じ判定 |
| master effect chainステップ | `liveReceivePipelineView` | `receive-pipeline-master-effects-step` | Master FX | `AudioMixerSnapshot` の `rx-master.effectChain` + `rx-output.effectChain` から導出した `receiveMixEffectChainSnapshot.stages` | RX Master 配下に適用される ordered stage chip として inline 表示（Isolation → master fader → 出力Limiter） | stage 単位で unavailable / bypassed を表示 |
| outputステップ | `liveReceivePipelineView` | `receive-pipeline-output-step` | Output | native出力を最後に描画した時刻と最後の有声PCMの時刻、別rendererの最後に再生を予約した時刻、mute、volume | nativeは `Last audible PCM` と `Last render` の経過秒。展開時に機器名、取得した実形式・buffer・reset数 | muteはMuted、音量0はWaiting。直近2秒にnativeの有声PCMを観測していればPassing |

OverviewとRXは同じ判定を使い、表示中に経過秒を更新する。RTC RXとDecodeは該当する最新の観測が2秒を超えるとWaitingに戻り、累計と最後の観測を表示する。DecodeがBlockedの間はOverviewにも段名と直近の失敗が出る。別のpacketからPCMが得られればDecodeはPassingに戻る。再生予約と実出力は後の段で独立に観測する。nativeの有声PCMは `Last audible PCM · n s ago`（画面では `3s ago` の形）。2秒を超えると時刻は残したままWaitingになる。未観測は `No audible PCM observed`。別rendererは `Playback scheduled` または `No playback scheduled` に `Render not measured` を併記し、出力段はWaitingとする。音声処理が停止・再構築されると出力の時刻を初期化する。

native出力は無音の間も `Last render` を更新する。描画が2秒を超えて途絶えたら、共通の出力メーターのレベルとピークを0にする。再開した描画からメーターを更新する。

## 受信 mix topology 表示

`LiveReceivePipelineView` はRTC RX、Decode、Peer Busesの段を1行ずつ並べ、その下に参加者ごとの内訳（`diagnosticsReceiveDetails`）を置く。内訳の見出し`receive-mix-topology`（Participants）の下に標準DisclosureGroupを置く。開閉の対象は、自分以外の登録メンバーと、名簿への反映前でも認証または経路を確認できた相手である。経路のない相手を木の上に並べる。一度に開ける参加者は1人。別の相手を開くと前の詳細を閉じる。参加者の見出しと、経路がある人の合流線は表示したままにする。上部からRXを選ぶと処理順の先頭から表示する。調べたい相手の行を開く。RTC RXの破棄、Decodeの復号失敗、各相手のPlayoutを処理順にたどれる。LossとEvent dropsはNetworkを選んで確認する。

| 項目 | accessibilityIdentifier | 表示する状態 |
|---|---|---|
| 参加者内訳 | `diagnosticsReceiveDetails` | 見出しと参加者の一覧。通話先がなければNo participants |
| 内訳の見出し | `receive-mix-topology` | Participants |
| 参加者行 | メンバーIDを`id`に持つDisclosureGroup | 表示名と状態。経路なしはOfflineまたはNo mixer route。経路ありは、その相手の入力に直近2秒以内のPCM再生予約があればPassing、未観測か2秒超はWaiting。状態は共通の記号と語で示し、Waitingでも経路がある間は枝を描く。開くと、送信側のミュート（`mic.slash.fill`と語）、送信側が報告した実際のcodec識別子・bitrate（bps）・VAD・isolationと報告の経過秒を順に出す（15秒超はStale）。続けてRTC RXの接続・認証・観測した経路（Internet／Local direct／Local relayed、未観測時はPath not measured）を表示する。その次にDecodeのcodec識別子とpackets/sのNot measured、Playout、Peer Busの音量・FX要約を順に表示する。offlineはOfflineだけを表示する。未取得値はNot measured |
| 相手の再生予約 | `receive-peer-playout` | PCM sourceの`bufferedDuration`を`Playout: n ms queued`、そのsourceの累計を`Adjustments: n / Resets: n`と表示する。0は観測値。受信グラフの未準備・相手の経路なし・PCM sourceなしは`Playout: Not measured`。旧snapshotで調整回数が欠ける場合は調整回数に`Not measured`を表示する。再生予約の観測と状態は同じsnapshotを使い、実出力はOutputで確認する |
| master mix row | `receive-master-mix-card` | source bus count、総 RX、master volume / mute、RX master effect summary、出力 level |

## 受信 effect chain 表示

受信側は peer bus と receive master bus のそれぞれに ordered stages を持つ。Diagnostics は AudioMixer package snapshot 由来の `receivePeerEffectChainSnapshot(peerID:)` と `receiveMixEffectChainSnapshot` を描画する。effect の default 値や stage 配列を持たない。peer 側は全体で 1 つの共有 Peer FX 行にまとめず、参加者内訳の各参加者にstageの要約（`effectSummary`）として表示する。stage別のchipと識別子は持たない。TX Bus EffectsとMaster FXの共通表示は、幅に応じてstage名と状態を縦に並べ、アクセシビリティ文字サイズではstageを1列にする。

| chain | stage | accessibilityIdentifier | package | 表示する状態 |
|---|---|---|---|---|
| Peer FX | SoundIsolation | 参加者内訳の`FX`要約（stage別の識別子なし） | SoundIsolation | enabled / bypassed / unavailable |
| Master FX | SoundIsolation | `receive-master-effect-stage-sound-isolation` | SoundIsolation | enabled / bypassed / unavailable |
| Master FX | PeakLimiter | `receive-master-effect-stage-peak-limiter` | PeakLimiter | final peak guard ready / idle |

| 拡張ルール | 仕様 |
|---|---|
| stage 追加 | AudioMixer package の peer bus または master bus の `effectChain` に stage が追加されれば Diagnostics の表示順へ反映する |
| RX master limiter | 実グラフのrx-outputに存在するPeakLimiterを、master volume後の最終stageとして表示する |
| 文字列の固定を禁止 | 受信側も固定の effect 名列挙や default 値を UI の判断基準にしない |
| 一覧性 | peer chain は peer row 内、master chain は RX master row 内で別々に表示し、どちらで処理が止まっているかをログなしで読めるようにする |
| 表示順検証 | Diagnostics の effect chip は `AudioEffectChainSnapshot.stages` の登録順をそのまま使う。任意 stage を追加した順序が UI 表示用 model へ保持されることをテストする |

## Mixer graph 描画形式

AudioMixer package は UI 描画用の専用 DTO ではなく、現在の信号経路を説明する `MixerGraphSnapshot.nodes` / `edges` を返す。Diagnostics がグラフ表示を持つ場合はこの形式をそのまま使う。

| graph 要素 | 描画仕様 |
|---|---|
| `source` node | マイク入力または peer audio source として表示する |
| `busInput` node | bus 内の集約点として表示する |
| `effect` node | `MixerEffectSnapshot` の順序、状態、metadata を chip または node に表示する |
| `busFader` node | bus volume / mute の表示に使う |
| `output` node | final output として表示する |
| `sourceToBusInput` edge | source から bus input への接続として描く |
| `busSignal` edge | bus input、effect chain、fader の順序として描く |
| `busRoute` edge | RX peer bus から RX master bus への mix route として描く |
| `outputRoute` edge | RX master から output への接続として描く |

## 受信 peer metadata

| 項目 | 仕様 |
|---|---|
| codec metadata | keepalive metadata に remote peer の active codec を載せ、受信側の `GroupMember.activeCodec` に反映する |
| decode 表示 | Diagnostics は `activeCodec` を Decode ステップ内の `receive-peer-codec-{index}` に `DEC ...` として表示する。未受信または metadata 未到達の場合は `Unknown` とする |
| RTC 接続表示 | `GroupMember.connectionState` と `GroupMember.authenticationState` を RTC ステップ内の `receive-peer-rtc-{index}` に表示する |

## 現在状態一覧

| カード | ラベル | データ | 表示仕様 |
|---|---|---|---|
| Appliedの通話カード | `Call` | `connectionLabel`、選択したグループ | `CALL {state}` とグループIDの先頭8桁・メンバー数 |
| Appliedの招待カード | `Invite` | 招待可否、招待状態、選択したグループ | 招待状態とグループの同じ要約。表示更新では鍵の読込・作成や招待署名を行わない |

## 一覧性のルール

| 項目 | 仕様 |
|---|---|
| 表示粒度 | 1 カードは 1 つの層だけを示す。複数層の原因推測を 1 行へ詰め込まない |
| 文字量 | summary は 1 行、detail は補足。長文ログや stack trace は置かない |
| 状態 | パイプラインで各段の状態を語と記号で示す。AppliedのCall・Inviteは状態を文で示す |
| 表示順 | Appliedの`Requested → Applied`の後に、Call、Inviteの順。各カードは`State`の行（summary）と補足（detail）。RTT・loss・jitterはNetworkの経路ごとのカードに出す |
| ログとの関係 | Diagnostics で現在値を読み、ログは操作境界や失敗の後追い調査に使う |
| 環境差異 | unsupported / ignored は warning 以下に留め、継続可能な状態として表示する |
| パイプライン表示 | 各 pipeline step を大きな独立 card にしない。1 step は compact row、stage は親 row の内側の chip として表示する。狭い幅では段名の下に観測値を折り返す |
| 受信 peer 表示 | peer bus は複数人を前提に 1 peer 1 行で表示する。peer 数が増えても topology 全体を巨大 card grid にしない |
| overview の重複禁止 | Session、Input、Output、Codec、Mixer、Authentication など pipeline で読める値は現在状態一覧へ再掲しない |

## Accessibility Identifier

| 表示 | accessibilityIdentifier |
|---|---|
| Networkの経路カード | `diagnosticsNetworkLocal`、`diagnosticsNetworkInternet` |
| Paths | `diagnosticsNetworkPaths` |
| AppliedのCodec・VAD | `diagnosticsAppliedCodec`、`diagnosticsAppliedVAD` |

AppliedのCallとInviteは、カードの見出しとStateの値で識別する。

## 診断と適用状態の区別

実Mixerを毎回作り直して表示用の仮ノードを足す処理は使用しない。`AppAudioPipeline.snapshot` のbus、source、sink、routeをそのまま報告する。VADはMixer前段で実行するのでMixerのeffect chipには追加しない。上記stage IDは実ノードを配線した場合の表示契約であり、現在のSoundIsolation / DynamicsProcessor / PeakLimiter適用を示すものではない。

## 確認導線と実音声の区別

| 順序 / 項目 | ID / 表示 | 契約 |
|---|---|---|
| 概要 | `audioPathSummary` / Call / Network / Invite | 現在の媒体所有者を最初に表示。長い値は行数で切り捨てない |
| Internet Service | `internetServiceCheckStatus` | 保存前、確認中、認証済み、失敗をテキスト表示。運用側で通話を停止している応答を受けた場合は「インターネット通話は現在停止中です。」を表示する。tokenを含めない |
| Check Internet Service | `checkInternetService` | RTCのcheckServiceを呼ぶ。資格がない場合と確認中はdisabled。SFU媒体を作らない |
| 認証成功後 | active session数、予約参加者秒/月枠、対象月 | Workerの設定と端末認証の確認。SFU App Secretの正当性や音声成功とは別 |
| Local packet音声 | 既存TX/RX pipeline | 実際のMixer/codecのruntime reportを表示 |
| 全経路の音声 | Shared packet audio / TX/RX pipeline | 実際のPCM・packet・effect reportを表示。Internet失敗詳細をNetworkへ表示し、未提供のRTT/lossは未測定とする |
| Network | 測定値が全てnilならneutral | 不明をloss 0%や正常と扱わない |

Audio CheckはSettingsに置く。端末内の録音再生、サービス認証、ペアの媒体、実機の音響品質を別の確認として扱う。

## Network診断

| 表示 | identifier | 意味 |
|---|---|---|
| Network | `networkDiagnosticsSummary` | RTCNetworkDiagnosticsの表示。計測処理はRTC/native側が所有 |
| Connection failure | `diagnosticsNetworkInternetFailure` | Internetカードの先頭に、ViewModelの `internetFailureDetail` がある間だけ表示。ICE準備・入室の一般の失敗では、その処理名と失敗理由を表示する。経路が復帰するか通話を開始し直す・終了すると表示を消す |
| RTT / Send queue | 同上 | ICE transport RTTをms、DataChannel送信待ちをBで表示する。未取得は `Not measured` |
| Loss / Jitter | 同上 | Lossを%・Jitterをmsで別々に表示する。未取得は各項目で `Not measured` |
| Event drops | 同上 | session / route / engine / transportのoverflowとexpired。ネットワーク損失率ではない |
| Direct group path / Relayed | `diagnosticsNetworkPaths` | 相手名、Local／Internetと経路種別、短縮peer IDの矢印、`Last received n s ago`を相手別の行に並べて表示する。矢印は最後の認証済み受信を送信元から自端末の順で示す。15秒を超えた観測は`Stale`。音声の受信・出力はRXで確認する |
| Not measured / stale | 同上 | 未取得、または15秒を超えたreport。古い数値を正常値として表示しない |

LocalとInternetの計測カードでは、項目名と値・経路名と更新時刻が横に収まらないときは縦に並べる。Pathsでは相手名と矢印にカードの横幅を使う。アクセシビリティ文字サイズでは1行に1つのIDを置き、下向きの矢印でつなぐ。相手ごとの経路・観測値を1つの読み上げ単位にする。値は標準Textで折り返し・選択でき、色やアイコンだけに依存しない。切断・接続切替・世代変更時に旧reportを消去する。
