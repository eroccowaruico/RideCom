# iOSのSettingsのUIテストの追従

2026-11-17。2026-11-15の`scripts/validate.sh ios`で失敗したSettingsのUIテスト3件の原因を調べ、テスト側を直した。3件とも画面は現行仕様どおりで、製品側の変更はない。

## 原因と直した内容

| テスト | 原因 | 直した内容 |
|---|---|---|
| `RideIntercomUITests.testAACBitrateChoicesSurviveCodecSwitches` | Advancedは実装の既定値の選択肢に「(Default)」を付ける（[Settings](../../spec/App/UI/Settings.md)）。テストは印のない`AAC-ELD`・`48 kHz`・`48 kbps`を探していた | 既定値の選択肢を印の付いた語で探す。同じ語を使う`testOpusManualLowBandwidthChoicesSurviveFormatAndCodecChanges`も合わせた |
| `RideIntercomUITests.testCallDisconnectTimersPersistIndependently` | 最後に既定値へ戻す操作が、印のない`3 hours`・`5 minutes`を探して失敗していた。途中で失敗した実行は選んだ値をSimulatorに残すため、次の実行は最初の既定値の確認でも失敗した | 最初に印の付いた既定値を選んでから始め、最後も印の付いた語で戻す |
| `AdaptiveInterfaceUITests.testEnglishTabsSheetsAndCallAcrossRotation` | 横向き・最大の文字サイズでは、通話のアクセサリとタブバーが画面の下半分に重なる。アクセサリの下にある行もXCUITestは操作可能と報告するため、テストは「Advanced Settings for Developers」の行をアクセサリ越しにタップし、通話を開いていた | 行をアクセサリの上端より上まで動かしてから操作する |

## 確認

| 対象 | 結果 |
|---|---|
| iPhone 17 Pro Simulator（iOS 27.2）での単独実行 | 上の3件、`testOpusManualLowBandwidthChoicesSurviveFormatAndCodecChanges`、`testJapaneseTabsSheetsAndCallAcrossRotation`の5件が成功 |
| この時点で確認していない範囲 | UIテスト全体の実行と所要時間、`ios-recovery`、iPad（全体の実行は次節、残りは[未確認事項](../未確認事項.md#iosの検証を全段階まで通す)） |

横向き・最大の文字サイズのSettingsで見える範囲が狭いこと自体は、今回は評価していない。

## UIテスト全体の実行と残りの失敗

同日、`VALIDATION_TIMEOUT_SECONDS=7200`で`scripts/validate.sh ios`を実行し、UIテストを最後まで実行した（証跡: `.validation/ios-ui-full-20261117`）。UIテスト61件に4307秒かかり、58件が成功、3件が失敗した。1件ずつ直列に実行するため、段階の既定上限1800秒には件数と所要時間の点で収まらない。

| 失敗したテスト | 原因 | 対応 |
|---|---|---|
| `StandardInterfaceUITests.testStandardInternetSetupKeepsManualCredentialsInAdvanced` | AdvancedのInternet設定の入力欄は、値の形（`https://example.workers.dev`）を見本として表示する。テストは以前の見本`Worker URL`を期待していた | 期待値を現行の見本に合わせた。単独実行で成功 |
| `StandardInterfaceUITests.testStandardUserSettingsShowTheNamesReceivingAndDelete` | 招待のシートが閉じている途中のスワイプが失われ、行の操作が出なかった。単独実行では成功する間欠の失敗 | 操作が出るまでスワイプし直す。単独実行で2回成功 |
| `RideIntercomUITests.testPhoneAudioCheckRecordsAndPlaysFromSettings` | この実行ではホストMacに入力と出力を両方持つ48 kHzの音声デバイスが1つもなく、Simulatorの音声固定（`simulator-audio-device`）が失敗した。同じ理由でApp単体の`nativeRecordingCheckUsesThePreparedGraphForTwoCycles`も失敗した | 環境の条件であり、変更していない。条件を満たすホストでの再実行が必要 |

`ios-tests`が失敗したため、`ios-recovery`とiPadの段階は実行されなかった。`testCorruptGroupStoreRecovery`を同じSimulatorで単独実行すると失敗した。Appは最初にUsersを開くのに、テストはGroupsの一覧にある作成ボタンを探していた。最初にGroupsを開くよう直し、単独実行で成功した。

`ios-tests`段階の既定上限は7200秒にした（[自動検証](../../development/自動検証.md#成功判定と異常終了)）。`VALIDATION_TIMEOUT_SECONDS`を指定した場合は、従来どおりその値が全段階に適用される。
