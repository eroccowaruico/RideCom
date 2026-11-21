# 近距離制御のQUIC移行

## 通信方式の選定

2026-11-02の追加依頼。Xcode 27 SDKでMultipeerConnectivity全体が非推奨となった。[TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)によると、各APIは「Deprecated in iOS 27.0」で、移行先はNetwork.frameworkである。同日に代替手段を調査し、利用者の回答で移行方針を決めた。

移行前にMCSessionが担っていたのは、探索・招待、暗号化必須のsession、handshake・presence・操作のreliable転送だけだった。Local音声は当時からNetwork.frameworkのUDP（`includePeerToPeer = true`）で送っていた（[RTC仕様](../../spec/packages/RTC.md)）。TN3213は、Apple peer-to-peer Wi-FiがMultipeer専用ではなく、Network.frameworkからも使えることを明記している。移行後も、AP・セルラーがない屋外の近距離通話（[製品要求](../../requirements/製品要求.md)）を同じ無線で成立させる。実装はNetwork.frameworkの `NWListener`、`NWBrowser`、`NWConnection` を使う。

| 代替手段 | 判断 |
|---|---|
| Network.framework＋peer-to-peer Wi-Fi | 採用。iOS/macOS両対応で、端末の組ごとのペアリングが不要。既存のUDP媒体と同じ基盤 |
| Wi-Fi Aware＋DeviceDiscoveryUI | 第1段階は不採用。対応機種と端末の組ごとのペアリングが制約になる。[改善候補](../../backlog/改善候補.md#近距離通信の追加経路と統合)へ置く |
| Core Bluetooth | 第1段階は不採用。音声主経路には帯域・距離・遅延が不足し得る。補助経路として後から検討する（[改善候補](../../backlog/改善候補.md#近距離通信の追加経路と統合)） |
| Nearby Interaction、GameKit、SharePlay、インターネット共有 | 対象外。音声・制御のデータ経路にならない、Multipeer系の旧方式である、またはAP・Internet不在の要求を満たさない |

| 論点 | 2026-11-02に決めた方針 |
|---|---|
| 制御protocol | QUICを使う。handshake・presence・操作をQUICのreliable streamへ移し、message境界はframingで保つ。64 KiBの受信上限など現行のLocal制約を引き継ぐ |
| 暗号化と認証 | TLS-PKIを基本路線とする。端末ごとに一時的な自己署名identityを生成してmutual TLSを張る。相手証明書はTLS層の信頼評価では受け入れ、既存のgroup共有鍵によるhandshake MACへ証明書fingerprint等を含めて通信路へ束縛し、そこで認証する。Apple OSにidentityの生成APIがないため、生成は最小の自前実装とした（外部依存を増やさない。2026-11-17）。束縛は、handshakeのMACへ送信側・受信側の両方の証明書のfingerprintを含める方式とした（2026-11-17）。TLS-PSKは旧APIだけの機能で、TLS 1.3とQUICに対応しないため使わない |
| 接続の形 | 届く相手とはすべて直接接続する部分メッシュとし、全員が直接届くことを前提にしない。隊列で先頭と最後尾が直接届かない場合も、既存の[重複破棄付き転送（最大8hop）](../../spec/packages/RTC.md#混在通話と経路)で中間の端末が中継する。特定の端末をserverにするclient-server構成は、その端末の離脱や隊列内の位置で全体が切れるため採らない。同じ相手との重複接続は広告名の比較で小さい側だけが発信し、既存の[招待競合の回避](../../spec/packages/RTC.md#近距離の接続試行が競合する場合)の辞書順を引き継ぐ |
| 探索とプライバシー | 最低限とする。`NWListener`でBonjour serviceを広告し、TXTには現行と同じgroupHashを載せる。自動接続のため、service名には端末名を使わず通話世代ごとの識別子を使う。識別子のrotation等の追加対策は、利用規模・利用場所から現時点では行わない |
| 音声 | 第1段階は既存の`_ride-audio._udp`のUDP媒体を維持し、UDP媒体用のnonceを新しい制御経路のhandshakeから渡す。QUIC datagramへの統合は[改善候補](../../backlog/改善候補.md#近距離通信の追加経路と統合)とする |
| 旧版との互換 | 維持しない。Multipeer版と新版の混在通話は不可とし、両端末で同じ方式に対応するアプリを使う。利用者の操作・表示（Settingsの近距離ON/OFF、接続・切断、経路の表示）は変えない。設定・診断の経路識別子は`RouteKind.multipeer`を使用する |
| 電力 | 第1段階はTN3213の基本どおりとする。通話停止で探索・listener・connectionを破棄し、途中参加・再発見のために通話中は探索を維持する現行の扱いを引き継ぐ。Bluetooth併用等の省電力・補助経路は後から検討する |

## 経路の切り替え

近距離経路の制御に `_ride-control._udp` を使用する。音声は認証した相手のnonceで `_ride-audio._udp` を解決する。QUICのidentity・handshake・探索の部品を確認した条件と結果は[RTC仕様](../../spec/packages/RTC.md#近距離の探索とquic制御)に記録した。

AP・セルラーなしの屋外での相互通話、隊列の中継距離・移動・画面ロック・消費電力は[実機確認待ち](../実機確認待ち.md#iphone無線音声機器の確認)で追う。


## 2026-11-17の検証

- RTC単独でRTCTests 129件、RTCNativeWebRTCTests 4件が成功した。macOS上の実QUIC・UDPで同時探索、認証拒否、制御切断後の媒体資格の保持、別世代への切替、再認証、音声の双方向の伝送を確認した。80 byteの送信元IDでUDPを通す境界試験も成功した。
- 仮想4端末の直線隊列では、全方向の音声が1回ずつ届き、中間端末の離脱で分断し、復帰後に自動で合流した。RTC単独でiOS Simulator・watchOS Simulator向けのビルドも成功した。
- AppのLocal音声E2Eは、Macに入出力を兼ねる48 kHz機器が0台のため測定前に終了した。専用Simulatorを停止し、音声選択の復元工程は成功した。証跡は `.validation/audio-e2e-20261117-181332-723774/results.json`。その後、利用者が48 kHzの仮想の入出力機器Loopback Audioを用意した。後続の測定では異なる発話を両端から送り、相手の波形との相関が自分の発話との相関を0.10超上回る条件で折り返しを除外する。

### Appの招待・回帰と音声E2E

| 実行 | 観測 |
|---|---|
| iPhone SimulatorのAppテスト | 選択8スイートの54テスト定義、パラメータ展開後の58実行がすべて成功。別に、実QUICで招待を受け、双方のUsersを保存して再読込するテストが24反復すべて成功した。証跡は `.validation/local-quic-ios-182154` と `.validation/local-quic-ios-nested-182422` |
| macOS 27.2、DerivedData配置でのApp全体 | 656件中654件成功、2件失敗。未登録者から招待の受諾を届けるテストと、双方のUsers保存・再読込のテストで、招待元の登録結果が空だった。証跡は `.validation/local-quic-app-macos-20261117/actual-summary.json` |
| MacとiPhone SimulatorのLocal音声E2E | Loopback Audio（48 kHz）を使って両端でnative音声の開始に成功。Mac側で制御のBonjour探索が `NoAuth(-65555)` を返し、両端が認証待ちで時間切れとなった。測定は0件で、波形の同一性・欠落0・125 ms以内の判定には到達していない。Simulatorの音声選択を復元し、専用Simulatorの終了に成功した。証跡は `.validation/audio-e2e-20261117-182610-618879/results.tsv` と同じ場所の `measurements.json` |

同じMacのAppテストホストでBonjourの4種のserviceを比較した。domain（既定／`local.`）、TXT取得、peer-to-peer、UDP parametersを変えた各16条件、計64条件の結果はserviceごとに一致した。`_ride-audio._udp` と旧 `_ride-intercom._tcp` は各16条件で探索開始（ready）、`_ride-control._udp` と旧 `_ride-intercom._udp` は各16条件で `NoAuth`。readyは探索を開始できたことを示す。OSのローカルネットワーク許可を設定し直し、実行ファイルのUUIDを変えた試行でも制御の探索拒否が続いた。証跡は `.validation/bonjour-comparison-mac-183405/comparison.log`、`.validation/quic-auth-after-reset-183945`、`.validation/quic-auth-no-stub-184027`。Macでの再開条件は[未確認事項](../未確認事項.md#macの近距離quic探索とapp音声e2e)で追う。

Macの標準配置でも同一署名・同一bundle IDの検証用Appを試した。DerivedDataから実行したときはmDNSResponderが実行元のApp情報の取得時に OSStatus -5000 を記録した。`/Applications` 配下に同じAppを配置すると、OSが現行のBonjour宣言を読み取り、探索と広告は利用者の許可待ち（`pending`）へ進んだ。署名と検証用保存先を起動前に照合した。証跡は `.validation/quic-applications-host-184945/`。

別々のiPhone Simulatorの2プロセスで実行した比較では、両端の事前試験各5件が成功した。両方の探索・広告でホストOSに許可待ちの記録があり、60秒以内に相互認証できず測定は0件だった。音声機器選択の復元、追加端末の削除、再利用端末の停止を確認した。証跡は `.validation/quic-two-iphones-20261117-184746/`。


### Macの標準配置での実招待とApp回帰

利用者がローカルネットワークを許可した後、`/Applications` 配下の検証用Appで実QUICの招待を再実行した。招待の受諾から双方のUsers登録とディスク再読込まで単発で1.407秒、続けて24反復すべて成功した。同じ配置のApp全体では77スイートの656テスト定義、パラメータ展開後の772実行がすべて成功した。DerivedData配置で失敗した招待2件も含む。証跡は `.validation/quic-applications-host-184945/regression-190123/`。

許可後もDerivedDataから再実行すると、同じ実招待でBonjourの `NoAuth(-65555)` が再発した。このMacの自動検証では、許可した標準配置のAppホストを使う。証跡は `.validation/quic-auth-derived-after-grant-190349/`。

### 標準配置のMacとiPhone Simulatorの音声測定

Release-Validationを既定のDerivedDataでビルドした。Mac側では署名済みApp、PackageFrameworksと音声E2E用xctestrunを `/Applications` の検証専用ディレクトリに同じ製品構成で配置した。起動前に署名、xctestrunの参照先と検証用の保存先を照合した。iPhone Simulatorの入出力を48 kHzのLoopback Audioに固定し、役割ごとに異なる発話を送った。判定は通常のLocal quickと同じである。結果は `.validation/audio-e2e-20261117-190501-776563/measurements.json` と同ディレクトリの `results.tsv` にある。

| 条件 | Mac受話の有声区間の欠落率 | iPhone Simulator受話の有声区間の欠落率 |
|---|---:|---:|
| 既定AAC | 0% | 0% |
| Opus 24 kHz・エフェクトあり | 0% | 0% |
| PCM16 16 kHz・voiceChat | 2.92% | 0.68% |
| 出力ミュート | 無音を確認 | 無音を確認 |
| ミュート解除後 | 0% | 0.64% |

両方向の5条件すべてで計10件を測定した。有音8件の出力は相手の発話との相関が0.945以上で、自分の発話との相関を上回った。送受の記録が重なる区間では、送信側の収録時刻に対応するパケットがすべて到着した。PCM16とミュート復帰で生じた欠落は、受信側の復号直後にも現れた。旧Multipeer制御のLocal測定（`.validation/audio-e2e-20261103-232137-068927/`）でもPCM16と復帰で同傾向の欠落があった。

既定AACの収録から相手のrenderまでの片道遅延は、iPhone Simulator→Macが111.05 ms、Mac→iPhone Simulatorが120.29 ms。判定は波形照合の余裕10 msを加えるため後者は130.29 msとなり、125 msの基準を超えた。音声E2E全体は不合格である。既定AACの送信callbackから相手の受信callbackまでの中央値は両方向とも0.6 ms未満だった。残る音声品質の受入は[音声の途切れと遅延](../../backlog/未実装課題.md#音声の途切れと遅延)で追う。

実行中のソース一致、音声機器設定の復元、専用Simulatorの停止、標準配置のDebug・Release検証Appの回収を確認した。古い検証版Widget（build 462）も利用者の指定で終了し、旧親Appの登録だけを解除した。その後もこのMacのDerivedData配置では探索拒否が再現した。標準配置の回収記録は `.validation/quic-applications-host-184945/cleanup.json` にある。

同じLoopback Audio・Releaseで、iPhone Simulator内の通信を通さないリアルタイム試験も実行した。日本語の3発話と3 codecの9条件すべてで相手波形に相当する参照音声との連続性を確認した。判定余裕込みで125 msを超えた条件は6件。通信を含まない経路でも遅延条件を超える。証跡は `.validation/audio-e2e-20261117-190902-228818/pipeline-measurements.json`。音声選択を復元し、Simulatorの停止を確認した。

### 既定AACとPCM16 16kHzの現行再測定（2026-11-19）

基準は `73b74018`。同じRelease-Validationと英語の合成発話で、標準配置の署名済みMacとiOS 27.2 Simulatorを使った。Local quickの既定AACとPCM16 16kHz・voiceChat（相手ごとの受信音声の分離あり）を8秒ずつ測った。両端の接続・認証、実UDP転送と実出力を通した。

| 条件 | 音声の向き | 復号後の欠落 | 実出力の欠落 | 収録から実描画 | 10msの判定余裕込み |
|---|---|---:|---:|---:|---:|
| 既定AAC | iOS Simulator → Mac | 0% | 0% | 104.84ms | 114.84ms |
| 既定AAC | Mac → iOS Simulator | 0% | 0% | 122.08ms | 132.08ms |
| PCM16 16kHz | iOS Simulator → Mac | 0% | 0% | 163.99ms | 173.99ms |
| PCM16 16kHz | Mac → iOS Simulator | 0% | 0% | 167.21ms | 177.21ms |

送信時の収録時刻で両端の記録を照合した重複区間の全packetが到着し、送信callbackから相手の受信callbackまでの中央値は0.38〜0.49msだった。既定AACのMac→Simulatorでは発話波形と時刻の照合上、復号直後に約68ms、受信Mixerに約122msを観測した。復号後から描画までに残る待ちを対象に、再生予約と実際の出力位置を照合する。16kHzの以前の欠落は今回の条件・長さでは観測されなかった。

事前試験7件・各端の実音声試験・素材とソースの照合・音声選択の復元・Simulator停止・一時Mac Appの回収は成功。125ms判定は3条件で未達のためrun全体は不合格。証跡は `.validation/local-aac-and-pcm16-current-20261119` の波形・`measurements.json`・両端のpacket時刻。近距離のローカル測定であり、物理iPhoneのマイク、ロック、Bluetooth、実無線移動の観測は残る。

### PCM16 16kHzの欠落をiPhone Simulator 2台で再確認する

2026-11-21。`01e8fcb4` のRelease-Validation Build 1703をiOS 27.2 Simulator 2台で使った。標準のquickから `pcm16-16k-voicechat` をそのまま選び、保存済みグループの近距離通話で英語の合成発話を両方向へ8秒流した。PCM16・16kHz・Voice Chat、送信分離ON、相手ごとの受信音声の分離ON、VADはNoisy。実UDPの送受信と最終出力を通常の試験で確認した。両端で同じPCM16・mono16kを適用し、fallbackはなかった。

| 受信側 | 復号／Mixer／最終出力の有声欠落 | 復号波形の時間位置 | Mixerと最終出力の時間位置 | 実出力＋計測余裕10ms |
|---|---:|---:|---:|---:|
| A | 0／0／0% | 63.12ms | 210.46ms | 220.46ms |
| B | 0／0／0% | 63.04ms | 204.04ms | 214.04ms |

時間位置は同じ参照発話から換算した。復号側は復号波形の収録時刻を使い、復号処理の完了時刻とは区別する。両端で収録・転送・描画・送信の内部破棄0と出力リセット0。旧報告の有声欠落は、この8秒の条件では再現しなかった。受信分離を重ねた状態で復号波形から実出力までの位置差は約141〜147ms。次に差を分ける場合は、同じ送信条件で相手ごとの受信音声の分離だけを変え、復号と実出力の両方を比較する。125msは既定条件の製品目標で、今回の相手別分離を有効にした構成でも汎用検証の125ms判定は両方向とも未達だった。

事前5件、両側の試験各1件、ソース照合、入出力設定の復元と専用Simulatorの回収を確認した。証跡は `.validation/pcm16-16k-current-1703/nearby/`、選択入口は同じ親フォルダの `run_pcm16.py`。他OSとの組合せや実機の異なる機器・長時間での再現性は引き続き確認対象。

<a id="pcm16-16khzで相手別受信分離だけを切り替える"></a>

### PCM16 16kHzで相手ごとの受信音声の分離だけを切り替える

2026-11-21。`a083336f` のRelease-Validation Build 1704をiOS 27.2 Simulator 2台で使った。保存済みグループの同じ近距離通話で、PCM16・16kHz・Voice Chat・送信分離ON・VAD Noisyを保ち、相手ごとの受信音声の分離をON、OFF、OFF、ONの順で各8秒比較した。両側とも指定したAudio Unitの稼働状態と実UDP送受信を照合した。表は共通の合成発話から換算した実出力の位置と有声欠落。遅延値は計測余裕を加える前の値で、有声欠落がある区間は遅延合否に使わない。

| 区間 | 実出力 A／B | 最終出力の有声欠落 A／B |
|---|---:|---:|
| ON 1回目 | 202.04／201.42ms | 0／0.65% |
| OFF 1回目 | 161.23／160.54ms | 0／0.48% |
| OFF 2回目 | 110.81／115.63ms | 0／0% |
| ON 2回目 | 172.60／208.75ms | 0／0% |

復号の有声欠落、内部破棄、出力リセットは全8区間で0。ONの4区間では、復号波形の時間位置と再生予約の予測時刻を使った推定で、予約から実出力まで約57msだった。Bの欠落がないOFF 2回目からON 2回目では、実出力の差93.13msのうち、収録時刻から予約位置までの中央値の差が36.88ms、残る描画側の差は約56msだった。OFFになっても、1回目と2回目の受信予約の時刻は同じ水準にそろわなかった。

BのON 1回目では、packet 590が直前の受信から15.54ms後に届き、予定の先頭はplayerが報告した描画位置を96 sample過ぎていた。`pastRenderPosition`による予約は26.69ms後ろに移った。最終WAVの3.591〜3.606秒は5msずつの各窓で無音。Mixerも同じサンプル値で、その位置に対応する復号の有声PCMは残っていた。この区間は予約の移動で生じた待ちと位置が一致する。BのOFF 1回目にも欠落はあったが、観測された予約変更と同じ時刻ではなかった。次はpacket 590の前後の収録・到着・描画境界を固定し、遅着で取り直すときの無音と後続の相槌を、同じ実描画の試験で比較する。

予約を10ms早める案の確認には、同じ区間のpacket 590以降の459件を使える。記録上は全件で `startSample - 480` が `writableSample` 以上だった。これは保存済みの位置に対する計算で、次の試験では同じ到着を与えて実描画上の語頭・連続性と予約の戻りを確認する。

事前5件とAの試験が成功。Bの試験は有声欠落の2検査で失敗し、125msの汎用判定も未達だった。ソース照合、入出力設定の復元と専用Simulator回収を確認した。証跡は `.validation/pcm16-peer-isolation-1704/paired/` と、同じ親フォルダの `comparison.json`、`summarize.py`、`run_comparison.py`。物理端末やほかの経路での再現は別に確認する。

### PCM16の遅着後の予約を早めると次の空白が増える条件を確認する

2026-11-21。`2ae0b787` のAudioMixerを隔離したRelease試験で使った。Build 1704の受信B・相手別分離ONからpacket 578〜612の収録・到着時刻と描画位置を採取した。受信フォーマットへ変換した後に相当する48kHz・各480 sampleの識別可能なPCMを使い、最初に当時の収録と再生位置の対応を与えた。以降は保存済みの描画済み位置までAVAudioEngineで実際に描画してから、当時と同じ到着時刻を渡した。書込み可能位置は記録どおり描画済み位置の512 sample先、nativeへの引渡し余裕と基本待ちは各96 sample。試作は遅着を回復する予約で学習値を保ち、今回の追加待ちを最大240または480 sampleだけ減らす。

遅着の追加なしでは、対照でpacket 590の予定が描画済み位置から96 sample手前になり、再予約後に実出力へ1,281 sample（26.69ms）の無音が入ることを再現した。MacとiOS 27.2 Simulatorで結果はサンプル単位で一致した。発話の16,800 sampleは、追加遅着を含む全条件で一度ずつ順に出た。

| 後続のpacket 600に加えた遅れ | 現行の空白 | 5ms短縮案の空白 | 10ms短縮案の空白 |
|---|---:|---:|---:|
| なし、10.67ms、21.33ms | 26.69ms | 21.69ms | 16.69ms |
| 32ms | 26.69ms | 21.69ms | 16.69msと17.33ms |

Macでは保存時の残り余裕が小さかったpacket 687を含む699まで範囲を延ばした。そのpacketに21.33msの到着遅れを加えると、現行はpacket 590の26.69msのみで、5msと10msの両短縮案には22msの空白が追加された。すべての試験入力は順に一度ずつ描画した。固定で待ちを減らす案では、短い空白を1つ減らす効果と後続の空白を増やす条件が同時にあったため、製品の再予約の待ちを維持する。

Build 1704の実通話では、packet 590の送信記録から相手の受信まで約5.53ms、直前のpacketでは約0.42msかかった。同じ送信と受信の時刻を局所のUDP処理に照合し、再予約が必要になる前の遅れを特定する。今回の描画比較は履歴の再生位置と遅着を注入したAudioMixerの試験で、無線、受信分離の信号処理、物理iPhoneの動作は別に検証する。

Macで2件、iOS Simulatorで1件を試験し、iOSではソース照合、音声機器設定の復元、専用Simulatorの回収も確認した。証跡は `.validation/pcm16-expired-replay-1705/` の試作、`mac-summary.json`、`ios-summary.json`、`mac-expanded-summary.json` と各実行ログ。

### 標準のケース選択でPCM16の実通話を測る

2026-11-21。Build 1705のiPhone Simulator 2台で標準入口の `--matrix quick --scenario pcm16-16k-voicechat` を実行した。`scenarios.json`、両端に渡したケース、両端から回収した測定はいずれも選んだ1件だけ。PCM16 16kHzが適用され、両方向の復号の有声欠落と内部破棄は0。Aの実出力は0.56%の有声欠落で波形試験が失敗し、Bの遅延判定は計測余裕込み197.67msで125ms未達。選択したケースにも通常と同じ判定が適用された。[ケース選択の手順](../../development/音声E2Eテスト.md#通信音声のケースを選ぶ)

Aで再予約を観測したpacket 488は、送信の記録から受信まで約3.07ms、直前の487は約0.35ms。受信から予約完了は0.03ms前後だった。今回も受信処理を始める前に増えた時間を、送信と受信に近い観測点で調べる。選択試験の証跡は `.validation/audio-scenario-selection-1705/pcm16/`、スクリプト回帰171件は `.validation/20261121-040817-876090/`。事前5件、ソース照合、入出力の復元と検証端末の回収を確認した。

Build 1707で `--scenario output-mute` の1件を同じ近距離構成で選んだ。両端で音声packetを受信したまま、2秒間の実出力が無音（ピーク0、基準0.001未満）になることを確認した。両端のケース照合・波形判定、試験端末の回収まで成功した。証跡は `.validation/audio-scenario-selection-1705/mute-verified/`。手順から導いた選択順、指定省略時の全件実行、不正な指定時の準備前終了をスクリプト試験で、選択したケースだけの実行と既存判定の適用を2つの実通話試験で照合した。

### PCM16の待ちをUDP受信とRTC処理開始で分ける

2026-11-21。Build 1704と1705で遅着の直前後の波形は得られていたが、送信・UDP・RTCのどこが伸びたかは不明だった。両方とも受話のコア課題（重み8）。PCM16の転送の切り分けは調査箇所を絞る効果を0.25、見込み0.65、10〜15分と見積もった（5.2〜7.8/時）。既定AACの書込位置と語頭の再計測は短縮案の採否を進める効果を0.40、見込み0.45、30〜45分と見積もった（1.9〜2.9/時）。1回の実通信で次の調査箇所を選べるPCM16を先に測る。欠落が再現しない場合は、実測した待ちと予約の余裕の関係までを判定する。[再利用したAACの測定方法](音声同一性と途切れの再現.md#現行の近距離通話で送信からudp受信までを照合する)

基準 `aae96848` に調査用の時刻計測だけを足したRelease-Validation Build 1708をiOS 27.2 Simulator 2台で使用した。検証の引数を示す。

```text
--configuration Release --transport local --matrix quick --scenario pcm16-16k-voicechat --seconds 20 --saved-group-start --two-simulators --ephemeral
```

送信分離と相手ごとの受信音声の分離を有効にした16kHzの合成発話。送信queueの取出し、RTCでの封入、native UDPの送信開始・受信コールバック、RTCの受信処理開始・転送、Appの受信と予約を同じ単調時計で測った。暗号化済みパケットの短いハッシュと方向別のsequenceで結び、鍵・音声データを時刻記録に入れず、測定対象4,002件すべてで1つずつ照合できた。

| 測定区間 | A→B 中央値 / 最大 | B→A 中央値 / 最大 |
|---|---:|---:|
| App送信記録から相手App受信まで | 0.509 / 1.100ms | 0.498 / 5.992ms |
| native UDP送信開始から受信コールバックまで | 0.137 / 0.290ms | 0.133 / 0.414ms |
| UDP受信コールバックからRTCの受信処理開始まで | 0.042 / 0.306ms | 0.042 / 5.389ms |
| RTCの受信処理開始から認証・参加状態の確認後まで | 0.163 / 0.328ms | 0.162 / 0.336ms |
| RTC認証後の受信bufferから転送まで | 0.005 / 0.051ms | 0.005 / 0.022ms |

B→Aの最長は送信seq 328、受信seq 326。UDPは0.176ms、コールバックからRTC処理開始まで5.389ms、App受信から予約完了まで0.050ms。このpacketの予約先は書込可能位置の24.63ms先で、遅着による再予約は発生しなかった。別のpacketの無音短縮はあったが、復号・混合・実出力の有声欠落と内部破棄は両方向とも0。125msの比較基準は計測余裕込み187.23／183.83ms（A／B）で未達。通常の近距離転送は両方向とも中央値0.51ms以内であり、この計測から持続的な受話遅延の説明は得られていない。

次は遅れが出た経路に絞り、Localの受領確認を含むコールバック内処理と、イベントを渡してからRTCが処理するまでを分ける。過去に発話欠落を伴った遅着が同じ区間だったかも照合する。今回の計測では、受信bufferや予約余裕を変更する根拠は得られなかった。固定試験は準備から結果収集・回収まで約2分半（iOS build 80秒、両端並行の試験コマンドは約32秒、波形・時刻の照合は別途）。事前5件、連続性、ソース照合、音声設定の復元と試験端末の回収を確認し、一時計測を作業ソースから外した。証跡は `.validation/pcm16-datagram-1708/` の `probe.patch`、`DatagramTimingTrace.swift`、`analyze.py` と `pair/joined-timing.json`、`pair/results.tsv`。記録したコマンドと両端の添付から、時間区間・順序・4,002件の照合と波形判定を再現できることを確認した。

### PCM16のLocal受領確認とRTCイベントの待ちを照合する

2026-11-21。`62c8373a` に前回の調査用差分を当て、UDPコールバック内の受領確認の開始・送信、`LocalCallRoute` のイベント受渡しの開始と戻り、`RouteManager` のイベント読取を加えた。iOS Simulator 2台、Release-Validation Build 1709。前回の標準E2Eコマンドの `--seconds` だけを30に変更し、一度の双方向通話で最長の受信待ちがどこに生じるかを確認した。波形の連続性と遅延は既存基準で判定した。

| 区間 | A→B 中央値 / 最大 | B→A 中央値 / 最大 |
|---|---:|---:|
| UDP受信からイベント受渡し開始まで | 0.008 / 0.078ms | 0.009 / 0.247ms |
| イベント受渡し開始からRTCでの読取まで | 0.026 / 0.249ms | 0.028 / 0.306ms |
| RTCでのイベント読取から受信処理開始まで | 0.007 / 0.133ms | 0.007 / 0.931ms |
| UDP受信からRTC受信処理開始まで | 0.042 / 0.258ms | 0.045 / 0.968ms |

両端の記録時間が重なる範囲で3,003件ずつ、計6,006件を一件ずつ照合した。記録の端に重ならない送受信記録が計16件あった。受領確認はA→B 60件、B→A 59件で、作成からnative送信呼出まで最大0.074ms。最長の受信待ちはB→Aの受信seq 436で、受領確認は発生せず、0.968msのうち0.931msがRTCのイベント読取後だった。当該パケットは書込可能位置ちょうどに予約され、再予約はなかった。前回の5.39msと発話欠落を伴う遅着は再現せず、同じ区間が遅れたかは未確認。

復号・混合・実出力の有声欠落と内部破棄は両方向とも0。相手ごとの受信音声の分離を有効にした今回のPCM16は、計測余裕込み179.65／191.42ms（A／B）でE2Eの遅延判定は未達。事前5件、ソース照合、音声設定の復元と端末回収を確認した。一時計測を作業ソースから外した。証跡は `.validation/pcm16-rtc-handoff-1709/` の `probe.patch`、`analyze.py`、`pair/joined-timing.json` と `pair/results.tsv`。記録した境界、方向別sequence、添付の波形判定から測定結果を照合した。PCM16の次の自然発生の欠落時にこの境界を採取し、通常の転送だけを繰り返す試行はここで閉じる。

## 間欠的に失敗する実Multipeerの招待テスト

2026-11-15〜16、iPhone 17 Pro Simulator（iOS 27.2）で`ContactInvitationPersistenceTests.nativeVMNotificationCommitsBothUsersAndSurvivesDiskReload`が間欠的に60秒の制限時間を超えた。同一プロセス内の2つのViewModelを実Multipeer（Bonjour）でつなぐテストは、成功時なら1.5〜2.5秒で終わる。

| 条件 | 結果 |
|---|---|
| 音声開始・Audio Checkの制御側を整理する前のソース | 連続8回と連続24回、すべて成功。同日の`scripts/validate.sh ios`でも成功 |
| 整理した後のソース、最初の時間帯 | `scripts/validate.sh ios`で1回、単独実行16回のうち2回が時間切れ |
| 整理した後のソース、後の時間帯 | 連続24回、すべて成功 |

2026-11-17には、macOSの`scripts/validate.sh macos`（653件）でも同じテストが1回失敗した。直前と直後の全体実行は成功している。

| 項目 | macOSでの失敗（2026-11-17） |
|---|---|
| 失敗の形 | 時間制限には達せず、テスト内の10秒の待ちが切れて10.137秒で終了した。受け取った側の保存までは成功し、送った側への通知が届かなかった |
| ログ | テスト実行中の約6秒間に105行のエラーが出た。内容は`[GCKSession] Failed to send a DTLS packet … sendmsg error: No route to host (65)`だった。成功した実行には1行もない |
| 変更との関係 | 失敗時の作業差分は、通話の接続先を求める処理の共通化（直近の通話とWidget）だけで、招待・Multipeerの経路には差分がない |
| 読み取れること | この失敗では、Multipeerの接続がホストのネットワークでパケットを送れていない。iOS Simulatorでの時間切れ（main actorが戻らない）と同じ原因かは分からない |

| 項目 | 内容 |
|---|---|
| 変更との関係 | 失敗は整理後のソースでだけ出たが、同じソースが後の時間帯では24回連続で成功した。このテストは媒体を開始せず（`startMediaCallCount == 0`を検査する）、整理した音声開始・Audio Check・音声session失敗報告の処理を実行しない。変更が原因である証拠も、原因でないことの証明もない |
| 観測 | 時間切れの実行では、テスト内の10秒の待ちを過ぎても終了せず、main actorが戻っていない。`[GCKSession] Something is terribly wrong; no clist for remoteID`は成功した実行にも出るため、失敗の目印にならない |
| 当時の次の確認 | QUIC制御で同じ招待テストを繰り返す。再発時にテストhostの`sample`を取り、停止している呼び出しを特定する |

### 繰り返し実行で分かったこと（2026-11-17、macOS）

このテストだけを同じプロセスで繰り返し実行し（合計約420回）、失敗の内訳を調べた。失敗は2種類あり、原因が違う。

| 種類 | 観測 | 対応 |
|---|---|---|
| 通知が届く前に待ちが切れる | Multipeerの最初の接続が`No route to host`で失敗する回がある（10秒待ちで80回中4回）。Multipeerは約10秒後に失敗を返し、RTCの経路の再試行（[RouteManager](../../spec/packages/RTC.md)）が自分でつなぎ直す。待ちを延ばした実行では、失敗した回が11.4秒または34.9秒で成功した | テストの待ちを10秒から45秒に延ばした（製品の1回の試行は60秒）。延ばした後も、再試行が2回続けて失敗して45秒に収まらない回が100回に1回程度残る |
| テストのプロセスが落ちる | 約420回のうち3回、main threadの`CFNetwork _MonitorCancel` → `_netServiceMonitorCallBack` → `objc_loadWeak`で`EXC_BAD_ACCESS`。旧実装で資源の解放をMainActorへ揃えた後も起きる | 未解決。停止した探索・sessionのオブジェクトを2秒間保持してから解放する変更を試したが、約230回のうち2回同じ形で落ちたため採用していない。弱参照を持つ側のメモリが壊れており、Multipeerが内部で持つBonjourのオブジェクトの寿命の問題と読める。Appのコードから確実に避ける方法は見つかっていない |

上記は旧版での記録で、発生条件は近距離接続を止めるとき（切断・招待の受け渡しの終了）だった。QUIC版での招待処理は同じAppテストの繰り返し結果で評価する。

QUIC移行後に同じ招待テストは標準配置のMacとiOS Simulatorでそれぞれ24反復に成功した。DerivedData配置の探索拒否と実環境の受入は[Macの近距離QUIC探索とApp音声E2E](../未確認事項.md#macの近距離quic探索とapp音声e2e)で追う。

## 通話から独立したデータの往復と再接続

2026-11-20。保存済み招待を通話の設定と寿命に依存させず届けるため、RTC packageで近距離の実経路を確認した。追加した試験は開始時にAPIがないためコンパイルに失敗した。`RTCLocalDataChannel`の実装後、同じ資格を持つ二者の間で実Bonjour探索・QUIC認証・データの往復が成立した。同じ元の資格で並行起動した通話の制御側には、相手の認証とデータはどちらも届かなかった。片側を止めて他方が離脱を検出し、再開後に同じ相手を認証した。共通制御のリンク通知は弱参照にし、閉じたリンクと通知の循環保持を解消した。[RTCの契約](../../spec/packages/RTC.md#通話を開始しない近距離データ交換)

最終ソースでmacOSの近距離制御・framing・通話回帰18件と、iOS 27.2 Simulatorの標準`RTC-Package`スキームによる近距離制御・通話・混在経路の35件が成功した。Simulatorは専用端末を回収した。証跡は `.validation/local-control-data/macos-final.log` と `.validation/local-control-data/ios-final/`。次はAppの署名付き返信・受領確認と保存をこの経路につなぐ。端末ロック中の転送、実機同士の圏外受取、登録済み相手への暗号化したグループ招待は[近距離の転送仕様](../../spec/App/通信仕様.md#近距離配送の保存と確認)で追う。


## 一つの待ち受けで登録済みの端末へ宛先別に届ける

2026-11-20。保存済みの相手に近距離で招待を届ける際、相手ごとのリスナーを避けられるかを確認した。送り手1台に異なる資格を持つ宛先2台を設定し、受け手は互いにも既知の鍵を持つが宛先を広告しない状態で、実Bonjourで探索した。送り手は同じ待ち受けで両端末を認証し、選んだ一方へだけデータを送り、同じ接続で受領を受け取った。宛先を指定しない送信、該当の鍵を知っていても広告で許可した相手以外のID、同じ元資格の既存通話との混線を防いだ。停止後は両受信側が切断を検出した。

広告の名前や証明書の指紋が差し替わると、同じTXT内の宛先情報が既知の鍵と一致しない。上限を超えた広告を退け、別の鍵で一致しないことも確認した。起動ごとに名前と証明書を変えて広告とTLSに結び付けるため、連絡先のリスナーを持ち続けず、同じ宛先への固定の識別子を公開せずに探索できる。既存の共有資格による招待通信と通話では従来の対称な認証を共用する。[RTCの宛先別探索仕様](../../spec/packages/RTC.md#登録済み端末を宛先にした探索)

変更前の試験は宛先別通信のAPIがないためコンパイルに失敗した。macOSでは制御・通話の25件、iOS 27.2 Simulatorでは標準 `RTC-Package` スキームで制御・通話・媒体の47件が成功した。Simulatorの失敗・skip・Xcode実行時警告は0で、試験専用端末は回収済み。証跡は `.validation/nearby-addressed/` の `rtc-red.log`、`rtc-macos-final.log`、`ios-regression/`。保存・起動・復帰からの自動探索、招待の永続化との結合、操作直後にロックした実機での受領は[Appの残課題](../../spec/App/通信仕様.md#近距離配送の保存と確認)で追う。
