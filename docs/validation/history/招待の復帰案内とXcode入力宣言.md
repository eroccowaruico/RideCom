# 招待の復帰案内とXcode入力宣言

2026-11-01、`ff306083`を基準に実施したApp工程。Xcodeの保存形式・設定を受け入れたまま、通常の作業フォルダ`/Users/naohito/source/RideIntercom`で標準TestActionとRelease Archiveを検証する。package／serverの製品処理と配布binaryは変更しない。

## 変更と境界

| 対象 | 変更・確認内容 |
|---|---|
| 招待の失敗 | 期限切れ・非対応version・不正形式／署名等の理由と復帰操作を共通ViewModelで設定する。前回の成功表示を消し、新しい有効な招待で失敗表示を消す。保存処理の個別エラーと既存の認可を維持 |
| 通話の保持 | 無効な招待でgroup・鍵・進行中の通話を変更しない。招待URLの永続台帳や再送pollingは追加しない |
| 両画面の言語 | Standardに加え、Advancedも動的エラーをLocalizedStringKeyとして表示する。一般的な保存失敗文を含め日本語訳を補う |
| Xcode入力 | App／Widget／Watchの番号反映scriptへproject directoryとproject.pbxprojのread入力を追加。OS設定checkerが読むscript・権限・Info・翻訳・Watchアイコンも宣言。採番lock・予約値照合・並列処理・sandboxは維持 |

## 自動検証

最終Mac／iPhone／Archiveの402入力が一致することを確認した。各runは同じ作業フォルダ内の`.validation`に保存し、生成hostの隔離を起動前に検査する。ビルド中の共通counter増分以外のsource変更を認めない。Xcodeの構成・compiler条件・namespace・entitlementのCLI上書きは行わず、共有schemeのTestActionを使う。

| 検証 | 結果・証跡 |
|---|---|
| Mac App | 最終512テストメソッド成功。失敗・skip・runtime warningなし。`invite-recovery-native-final/macos.xcresult` |
| iPhone App／UI | 最終500件成功（App498件、英日UI2件）。実際のStandard／Advancedをassertし、画面添付も確認。失敗・skip・runtime warningなし。`invite-recovery-ios-final/ios.xcresult` |
| iPad UI | 同じ最終buildの英日UI2件成功。Standard画面の不在とAdvancedのエラー領域も確認。`invite-recovery-ipad-final/ipad.xcresult`。iPhone／iPadをshutdown |
| Release Archive | 最終Mac build296・iOS build297の未署名Archive成功。通常namespace・production APNs・App／Widget／Watchの番号一致・package／test bundle／検証fixture不混入を検査。`invite-recovery-archives-final`。未署名・未提出 |
| Python | 107件成功、33.463秒。採番・project・platform設定・既存WebRTC更新検証を含む。`invite-recovery-python/tests.log` |

## 再現した失敗

| 結果 | 修正・保持した証跡 |
|---|---|
| Widget番号反映scriptがproject directoryのreadを拒否される | `invite-recovery-red`を保持。directory入力だけではproject.pbxprojのreadが拒否されたため、両方を入力へ追加。中間失敗は`invite-recovery-red-fixed-inputs` |
| OS設定checkerのsubprocessが読めない | `invite-recovery-red-project-inputs`を保持。呼び出すscriptとその実入力を列挙し、通常の作業フォルダで成功を確認 |
| 保存データのDecodingErrorを招待不正と誤分類 | `invite-storage-red`に1テスト・2 assertionのREDを保持。decodeJoinURLの境界だけで招待形式エラーへ正規化し、credential読取の失敗は既存の保存復旧へ渡す。端末資格の失敗も新しい招待の取得へ誤分類しない |
| UI試験がURL再openでStandard起動fixtureを再適用 | 初回UIのxcresultは成功したが、添付画像でAdvancedを確認できていないことが判明。URLを再openせず画面を切り替え、Standard画面の不在とAdvancedのgroupErrorLabelをassertする試験へ修正。初回を両画面の受入証拠にはしない |
| 招待失敗の表示がnilで前回成功が残る | `invite-recovery-red-complete-inputs`に4条件・8 assertionのREDを保持。他のGroupLifecycleテストは成功。共通処理の修正後、全App回帰を成功させた |

以前の`/private/tmp/RideIntercom-account-verification`での成功を、通常workspaceにおけるscript sandboxの証明とは扱わない。Xcodeのsandboxは一時領域の読み取りを許す場合があるため、今回の通常workspaceで判明した入力不足を修正した。採番時の整合性検査を削除したり、ENABLE_USER_SCRIPT_SANDBOXINGをOFFにする回避は行っていない。

## 受入範囲

実機・Appleログイン・通知・課金・署名・提出の受入ではない。既知のCoreAudio待機、独立音声E2E、Watch自身の音声と押下中送話、無線・電池・背景動作の確認は残す。古いDerivedDataを別worktreeから再利用した際のstale path warningと、AppIntents未使用targetのmetadata省略warningはログへ保持し、warningゼロとは扱わない。


## 期限切れ招待の置換と呼び名の一括保存

2026-11-17、期限切れの「新しい招待を送る」が、新規発行・呼び名の引継ぎ・旧記録の除去を別々に保存し、途中の失敗を無視していた。2回目の保存だけを失敗させると、呼び名のない新規招待へ移り、旧記録も残ることを再現した。`stageContactInvitation(_:now:replacingExpiredInvitation:)`で新規招待・Keychain参照・元のnickname・旧記録除去を1回のmanifest置換へまとめ、成功後だけ新しい詳細を開くようにした。期限内・存在しない置換対象も無書込で拒否する。App側だけの変更でpackage／serverは変更していない。

| 検証 | 結果と証跡 |
|---|---|
| 変更前 | `.validation/contact-replacement-red-20261117`。期限切れpendingとexpired記録の両方で、呼び名の欠落・旧記録残存・再読込の不整合を再現。先行の保存失敗テストは既存の読取専用／再読込契約を考慮していなかったため、直接再試行の期待を再読込後の回復へ訂正した |
| 最終Mac | `.validation/contact-replacement-macos-standard-final-20261117/app.xcresult`。標準配置の署名済み検証Appで関連5スイート・27定義／29実行成功。失敗・skip・runtime warningなし。実QUICの受諾→双方の登録→ディスク再読込も含む |
| 最終iOS Simulator | `.validation/contact-replacement-ios-final-20261117/ui.xcresult`。同じ5スイート・27定義／29実行成功。失敗・skip・runtime warningなし。所有Simulatorを終了 |
| 置換の回帰 | 元の呼び名、旧記録除去、新しい詳細の対象ID、再読込後の記録、不要な鍵の回収、通話を開始しないこと。保存前の失敗では旧manifest・名前・表示対象・確定済みの鍵を保持し、再読込後に再試行できる。鍵保存先と2回目の保存失敗は既存in-memory storeで注入 |
| 先行の環境失敗 | `.validation/contact-replacement-macos-green-20261117`ではDerivedData配置の実通信2テストが既知の`NoAuth(-65555)`で失敗。規定の標準配置へ最終ビルドをコピーし、5スイートすべてを再実行した。所有する検証コピー2つは回収済み。OS権限・通常Appの設定は変更していない |
| 集計と入力の照合 | 標準配置のテストとxcresult集計は成功したが、その後の一時runnerのrecord呼出しで引数誤りが出た。同じxcresultを共通`xcode_tests_passed`で独立評価して成功を確認し、`acceptance.json`へ記録。再実行したと扱わない。両最終runのSwift等429入力が最終ソースと一致 |
| 定義 | 通信仕様・UI Stack・招待のMarkdown・HTML見本・マニュアルを一緒に更新。文書参照・String Catalog・diff・HTMLの主要コンテナを検査。HTMLの既存`watch` ID重複は変更前から存在し、今回の招待修正では増やしていない |

通常APNs／UserNotificationsを前提とし、CallKit・VoIP Push・AppleのPushToTalk frameworkを使わない条件は維持した。今回の修正は期限切れ招待の保存境界であり、通知到着・実APNs・実機の共有／ロック／背景配送の受入を新たに成立させた結果ではない。HTMLのブラウザー描画、画面を開いたまま期限を迎える際の表示更新は今回の検証範囲に含めない。元の招待と新しい招待の共有手順は維持した。
