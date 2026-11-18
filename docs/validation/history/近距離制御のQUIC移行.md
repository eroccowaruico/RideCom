# 近距離制御のQUIC移行

## 通信方式の選定

2026-11-02の追加依頼。Xcode 27 SDKでMultipeerConnectivity全体が非推奨となった（[TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)。各APIは「Deprecated in iOS 27.0」、移行先はNetwork.framework）。同日に代替手段を調査し、利用者の回答で移行方針を決めた。

移行前にMCSessionが担っていたのは、探索・招待、暗号化必須のsession、handshake・presence・操作のreliable配送だけだった。Local音声は当時からNetwork.frameworkのUDP（`includePeerToPeer = true`）で送っていた（[RTC仕様](../../spec/packages/RTC.md)）。TN3213は、Apple peer-to-peer Wi-FiがMultipeer専用ではなく、Network.frameworkからも使えることを明記している。移行後も、AP・セルラーがない屋外の近距離通話（[製品要求](../../requirements/製品要求.md)）を同じ無線で成立させる。実装はNetwork.frameworkの `NWListener`、`NWBrowser`、`NWConnection` を使う。

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
| 接続の形 | 届く相手とはすべて直接接続する部分メッシュとし、全員が直接届くことを前提にしない。隊列で先頭と最後尾が直接届かない場合も、既存の[重複破棄付き転送（最大8hop）](../../spec/packages/RTC.md#混在通話と経路)で中間の端末が中継する。特定の端末をserverにするclient-server構成は、その端末の離脱や隊列内の位置で全体が切れるため採らない。同じ相手との重複接続は広告名の比較で小さい側だけが発信し、既存の[招待競合の回避](../../spec/packages/RTC.md#近距離接続試行の競合回避)の辞書順を引き継ぐ |
| 探索とプライバシー | 最低限とする。`NWListener`でBonjour serviceを広告し、TXTには現行と同じgroupHashを載せる。自動接続のため、service名には端末名を使わず通話世代ごとの識別子を使う。識別子のrotation等の追加対策は、利用規模・利用場所から現時点では行わない |
| 音声 | 第1段階は既存の`_ride-audio._udp`のUDP媒体を維持し、UDP媒体用のnonceを新しい制御経路のhandshakeから渡す。QUIC datagramへの統合は[改善候補](../../backlog/改善候補.md#近距離通信の追加経路と統合)とする |
| 旧版との互換 | 維持しない。Multipeer版と新版の混在通話は不可とし、同じ版同士で使う。利用者の操作・表示（Settingsの近距離ON/OFF、接続・切断、経路の表示）は変えない。設定・診断の経路識別子は`RouteKind.multipeer`を使用する |
| 電力 | 第1段階はTN3213の基本どおりとする。通話停止で探索・listener・connectionを破棄し、途中参加・再発見のために通話中は探索を維持する現行の扱いを引き継ぐ。Bluetooth併用等の省電力・補助経路は後から検討する |

## 経路の切り替え

近距離経路の制御に `_ride-control._udp` を使用する。音声は認証した相手のnonceで `_ride-audio._udp` を解決する。QUICのidentity・handshake・探索の部品を確認した条件と結果は[RTC仕様](../../spec/packages/RTC.md#近距離の探索とquic制御)に記録した。

AP・セルラーなしの屋外での相互通話、隊列の中継距離・移動・画面ロック・消費電力は[実機確認待ち](../実機確認待ち.md#iphone無線音声機器の確認)で追う。


## 2026-11-17の検証

- RTC単独でRTCTests 129件、RTCNativeWebRTCTests 4件が成功した。macOS上の実QUIC・UDPで同時探索、認証拒否、制御切断後の媒体資格の保持、別世代への切替、再認証、音声の双方向配送を確認した。80 byteの送信元IDでUDPを通す境界試験も成功した。
- 仮想4端末の直線隊列では、全方向の音声が1回ずつ届き、中間端末の離脱で分断し、復帰後に自動で合流した。RTC単独でiOS Simulator・watchOS Simulator向けのビルドも成功した。
- AppのLocal音声E2Eは、Macに入出力を兼ねる48 kHz機器が0台のため測定前に終了した。専用Simulatorを停止し、音声選択の復元工程は成功した。証跡は `.validation/audio-e2e-20261117-181332-723774/results.json`。その後、利用者が48 kHzの仮想入出力機器Loopback Audioを用意した。後続の測定では異なる発話を両端から送り、相手の波形との相関が自分の発話との相関を0.10超上回る条件で折り返しを除外する。

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

| 条件 | Mac受話の有声区間欠落率 | iPhone Simulator受話の有声区間欠落率 |
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

基準は `73b74018`。同じRelease-Validationと英語の合成発話を用い、標準配置の署名済みMacとiOS 27.2 SimulatorでLocal quickの既定AACとPCM16 16kHz・voiceChat（受信相手別音声分離あり）を8秒ずつ測った。両端の接続・認証、実UDP配送と実出力を通した。

| 条件 | 音声の向き | 復号後の欠落 | 実出力の欠落 | 収録から実描画 | 10msの判定余裕込み |
|---|---|---:|---:|---:|---:|
| 既定AAC | iOS Simulator → Mac | 0% | 0% | 104.84ms | 114.84ms |
| 既定AAC | Mac → iOS Simulator | 0% | 0% | 122.08ms | 132.08ms |
| PCM16 16kHz | iOS Simulator → Mac | 0% | 0% | 163.99ms | 173.99ms |
| PCM16 16kHz | Mac → iOS Simulator | 0% | 0% | 167.21ms | 177.21ms |

送信時の収録時刻で両端の記録を照合した重複区間の全packetが到着し、送信callbackから相手の受信callbackまでの中央値は0.38〜0.49msだった。既定AACのMac→Simulatorでは発話波形と時刻の照合上、復号直後に約68ms、受信Mixerに約122msを観測した。復号後から描画までに残る待ちを対象に、再生予約と実際の出力位置を照合する。16kHzの以前の欠落は今回の条件・長さでは観測されなかった。

事前試験7件・各端の実音声試験・素材とソースの照合・音声選択の復元・Simulator停止・一時Mac Appの回収は成功。125ms判定は3条件で未達のためrun全体は不合格。証跡は `.validation/local-aac-and-pcm16-current-20261119` の波形・`measurements.json`・両端のpacket時刻。近距離のローカル測定であり、物理iPhoneのマイク、ロック、Bluetooth、実無線移動の観測は残る。
