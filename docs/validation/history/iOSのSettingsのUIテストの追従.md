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
| 確認していない範囲 | UIテスト全体の実行と所要時間、`ios-recovery`、iPad（[未確認事項](../未確認事項.md#iosのuiテスト全体の所要時間と未実行の範囲)） |

横向き・最大の文字サイズのSettingsで見える範囲が狭いこと自体は、今回は評価していない。
