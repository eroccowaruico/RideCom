# RideCom Call 画面項目

## 目的

本書は Call タブの UI 項目を定義する。

## Standardの通話・ユーザー・グループ

Watch音声のpairが失われ、Watchでの再準備が必要な場合は、この端末のResume Audioを表示しない。Watchからの再開始案内に従う。既存pairを保持した一時停止では共通の再開操作を利用する。

初期表示はStandard。`Users` / `Groups` / `Settings`の標準TabView（Standardの`Groups`は設定の「グループタブを表示」がONのときだけ。既定はOFFで`Users` / `Settings`の2つ。OFFにしたときGroupsを表示中ならUsersへ戻し、通話・グループ・保存データは変えない。Advancedは常に`Groups`を表示する。`.sidebarAdaptable`。iPhoneはタブバー、iPad・Macはサイドバー）を使い（最初はUsers）、Diagnosticsは含めない。通話はタブにせず、接続先を選んだときに開く（compact幅のiPhoneは`sheet`、iPad・Macは`inspector`の右の列、`closeCallButton`で閉じる）。iPhoneで`inspector`のcompact表示（OSのシート）を使わないのは、ツールバーに…メニューを置いたその表示を一覧から開き直すとSwiftUIのガラス描画が停止したため（2026-11-03、[証跡](../../../validation/history/画面デザインと録音操作の整理.md#通話のメニューと一覧の行から設定を開く)）。通話中に通話を閉じている間は、iOSはタブバー上の`tabViewBottomAccessory`（`callAccessory`。状態の記号、名前と状態の語の2行の`callAccessoryOpenButton`、`callAccessoryMuteButton`、`callAccessoryEndButton`。切断は標準の`confirmationDialog`で「{接続先}との接続を切断しますか？」と確認（`callAccessoryConfirmEndButton`）。長押しのメニューは置かない）、macOSはツールバーの`callAccessoryOpenButton`（状態の記号と「{接続先} · {状態の語}」）から開き直す。切断すると通話を閉じて一覧へ戻り、未選択・未接続だけの画面は置かない。以下の詳細画面はSettingsのApp LayoutでAdvancedへ切り替えて使用する。Users / Groupsと参加者は人物と通常グループを共通の青いアバターとし、`person.fill`／`person.3.fill`の記号で区別する。アイコン画像の変更機能は持たず、名前と種別を併記する。Users / Groupsの一覧はSettingsと同じ`readableScrollWidth()`で、行を最大640ptで見えている領域の中央に置き、背景とスクロールバーは端まで広げる。中央に寄せる余りがシステムの余白（regular 20pt）以下の幅（iPhoneなど）はシステムの余白のままにし、行は左右に余白を取った角丸のまとまりになる（macOSのListは左右の`contentMargins`を使わないため、macOSでは`safeAreaPadding`で行を寄せる）。Users / GroupsはStandardとAdvancedで画面構成を分け、AdvancedのUsers / Groupsの行は一般向けの行の部品を使わず`AdvancedRecordRow`で実装の値を出す（Users: 呼び名、`Direct {短縮id} · N devices`または`No direct group yet`、`Name shared by this person: {displayName}`、通話中の状態。Groups: `Saved Groups {件数}`に`N members · key ready`（保存した通話の鍵がないグループ（`groupsMissingKeys`）は`key missing`）・等幅の短縮`id`・通話中の`active`、`Direct Groups {件数}`に内部のdirectグループ）。保存状態・共通操作と同じ意味の表示部品を共用する。Callはモードに応じた画面を使用する。接続先の選択とグループ作成はUsers / Groupsタブへ集約する。画面だけを切り替え、接続・選択・ミュート・一覧の正本は同じIntercomViewModelに保つ。

| 画面・項目ID | 表示と操作 |
|---|---|
| Call / `standardCallScreen` | 先頭は状態ヒーロー。ナビゲーションのタイトルは置かない。縦は1列、iPhoneの横（compact高さ）では左の固定列（幅の45%、ヒーローと操作を縦の中央）と右の詳細一覧の2列にする。右の詳細一覧（`standardCallDetailsScroll`）だけをスクロールし、主要操作を隠さない。iPad・Macでは一覧の右の列（`inspector`、幅320〜420pt）に1列で置く。横のcompact高さでアクセシビリティ文字サイズのときは、上を情報一覧、下を3操作の固定領域（`standardCallFixedControls`）に分け、操作のラベルを記号の横に並べて全文を表示する。状態ヒーロー（`standardCallHero`）は左寄せのLiquid Glassのカード（`.glassEffect`、形は`ConcentricRectangle`。縦の一覧ではそのSectionの行の背景にし、下の一覧と同じ幅にする）で、上から種別・人数（記号付き、subheadline semibold、例: グループ・4人／ユーザー）、接続先の名前（title bold、2行まで）、状態の記号と語（title3 semibold。接続中は進行表示だけwarning）、理由があれば次の行に補足（例: 相手の参加を待っています）を置く。経路は出さない。状態と補足をダッシュで1行につながない。VoiceOverではヒーロー全体を1つの見出しの要素にし、labelを種別・人数と名前、valueを状態と補足にする。操作はヒーローの外（下）に置く。接続前・接続待ち・会話中・音声停止・音声エラーを文言と記号または進捗で示す。認証だけでは会話中にせず、音声準備も成立している状態を使う。触覚は会話中への遷移でsuccess、音声停止への遷移でwarning、接続の終了でstop、マイク／出力ミュートの切替でselectionを出す |
| `standardConnectButton` / `standardEndCallButton` | 接続はglassProminent、切断はdangerの円形glassProminentで下のラベルは`End`（日本語「切断」、`standardEndControlLabel`）。切断の確認は標準の`alert`で「{接続先}との接続を切断しますか？」（`Disconnect from {name}?`。通話のアクセサリと同じ文）。通常グループの接続済みの相手の行は`DisclosureGroup`（`standardPeerRow-{id}`）で、タップで開くとその人の音量のSlider（`standardPeerVolume-{id}`、数値なし）を出す。閉じている間は出さない。ミュート・スピーカー・切断の3つの円は見た目の直径64pt（横画面・低い高さは56pt。ガラスの余白7ptを引いた記号の枠で描く）で、ヒーローと同じ列の幅に均等に広げ、両端の円を列の端から4ptに置く。切断は隣と32pt以上離す。主要ボタン（`appProminentButtonStyle()`。接続・切替・音声を再開、名前の入力の「はじめる」、新しいグループの「作成して接続」、空状態の主要操作）は置いたまとまりの幅いっぱい（`.buttonSizing(.flexible)`）。空状態の主要操作は一覧の幅から余白を引いた幅で最大420pt。切断確認を取消すと既存通話・ミュートを維持し、確定時だけ描画時に捕捉したCallReferenceを共通endCallへ渡す。接続は共通startCallへ渡す。別の通話中は接続ボタンを出さない（切替は置かない）。一覧の行のタップ・呼び出しの通知のタップで別の通話を置き換えることはなく、切替の確認のダイアログも置かない（今の通話を開くだけ） |
| `standardMuteButton` / `standardMuteState` | 円形glassのmic.slash記号を固定し、ミュート中だけdangerの選択状態とする。下のラベル（`standardMuteState`）はMute／Mutedで状態を語でも示す。操作列の下にマイクの状態の案内文は置かない。共通setCallMutedへ描画時のCallReferenceと希望値を渡す。Watch音声選択中はマイク操作を表示せず「Watchでマイクを操作」（`standardMicrophoneStatus`）と案内し、以前のphone mute値を状態として表示しない |
| `standardUsersList` | 保存済みユーザーだけを表示。未登録の相手の行は保存済み詳細を開き、識別済み相手の行のタップは`openDestination`で内部通話先を解決し、待機中ならその場で接続を始めてCallへ移る（[操作の流れ](../../../design/操作の流れ.md)の「選んだら接続」）。現在の通話先なら再接続せずに開き、接続中（接続待ちも含む）は1つの場所にいるため、別の通話中に別の行を選んでも今の通話を開くだけで、切り替えず確認も出さない（`openDestination`は`showsLiveCall`。別の場所へは切断してから選ぶ）。開始できない場合も接続先を表示し、理由を示す。内部グループの作成や選択は要求しない。行のswipe（OS標準の記号の丸いボタン）に`User Settings`（相手の設定）と`Delete`を置き（長押しのメニューは置かない。マウスでスワイプできないMacだけ同じ項目を右クリックのメニュー`macRightClickMenu`に出す）（Deleteは標準の`alert`で「{名前}を削除しますか？」と確認し、確定は`confirmDeleteDestinationButton`。その相手と接続中（`isInCall(with: .user)`）なら、グループの削除と同じく本文「今の接続は切断されます。」と確定「切断して削除」にする）、鉛筆・`info.circle`は置かない。接続中の相手の行には状態の語（`directoryRowCallStatus`、記号だけ状態色）を示す。空のときはListの`overlay`で一覧の領域の縦横中央に`ContentUnavailableView`（見出しと`emptyUsersInviteButton`の1つだけ。Groupsは`emptyGroupsCreateButton`）、10人を超えると検索（`.searchable`、プレースホルダー「名前で検索」）を出す。Standardの一覧に説明のfooterを置かない（Advancedは保存の規則を文で出す）。行の名前は通常の文字色で、色は状態の記号だけに付ける（`directoryRowButtonStyle`。iOSは行全体のタップを保ったまま`foregroundStyle(.primary)`） |
| `standardGroupsList` | 通常グループだけを表示し、進行中の通話の実状態（接続待ち・会話中・音声停止等）を行内に示す。行のタップはUsersと同じく待機中は接続を始め、別の通話中は今の通話を開くだけで切り替えない。行の補助は人数（例: 4 people／4人）。行のswipe（Macは右クリック）は共通の`destinationRowActions`で`Group Settings`と、`canEditSavedGroups && groupRepository.ownsGroup(group.id)`のときだけ`Delete`を出す。StandardとAdvancedの通常グループ行で条件を揃える。削除は共通の`destinationDeleteConfirmation`で確認し、取消で一覧と通話を保持、確定で既存の`deleteGroup`へ渡す。接続中は本文で切断を知らせ、確定は`Disconnect and Delete`。Group Settingsの最後の`Delete Group`も維持し、オーナー以外は設定画面から抜ける。New Groupは既存の名前入力・保存ユーザー選択Formを開く。作成確定時の既存開始処理を共用する。空のときは`emptyGroupsCreateButton`、10件を超えると検索を出す |
| Current Call | Standardでは一覧に置かず、通話のアクセサリ（`callAccessoryOpenButton`）が進行中の通話へ戻す。別の接続先を表示した後でも進行中の通話を開き直す。Advancedは一覧先頭のCurrent Call（`standardCurrentCallButton`）も維持する。保存ユーザーを削除すると、その相手との通話は切断されて消える |
| 招待・参加者 | 通話のツールバーの操作はモードごとに別のView（`StandardCallSettingsButton`・`AdvancedCallMoreMenu`）で、`CallPanel`が選ぶ。Standardは…メニューを置かず、ツールバーの設定のボタン（`gearshape`）1つだけ: 通常groupは`Group Settings`（グループの設定、`callGroupSettingsButton`）、個別通話は`User Settings`（相手の設定、`callUserSettingsButton`。保存ユーザーが消えたら無効）。`Invite Members`（メンバーを招待）はメンバー一覧の先頭の`addSavedUsersButton`の1つで、設定とは別にする。宛先のないグループのリンクはAdvancedのメニュー・Group Settingsから共有する。Advancedは…メニュー（`callMoreMenu`）で、実装の操作名で、`Group Settings`／`User Settings`、`Add Saved Users`（`callAddMembersButton`）、共有可能なら`Invite`（directは`Share Call Invite`、`inviteButton`）。メニューは対象ID・有効な操作・共有プレビュー名で更新し、音声メーターの変化とは独立させる。通話の画面に共有だけのボタンを単独で置かない。Standardの通話のメンバーの行にはスワイプ・長押しの操作を置かず、名前の変更・外すはGroup Settingsで行う。既存の署名付き共有、本人名／別名編集、通常groupへの保存ユーザー追加・削除を共用する。groupで会っただけの相手をUsersへ追加しない |
| 声のインジケーター | このグループの通話中だけ、声の大小を`StandardVoiceIndicator`（SF Symbolsの可変値、`.symbolVariableValueMode(.draw)`）で示す。数値は出さない。通常グループだけメンバーの先頭に自分の行（「自分」、ミュート中は「ミュート中」）を置き、行末にマイクの入力（`microphone.and.signal.meter`、`diagnosticsInputLevel`、`standardVoiceIndicatorSelf`）。本人確認済みの相手の行末に届いている声（`waveform`、`GroupMember.voiceLevel`、`standardVoiceIndicator-{id}`）。音量のSliderの右端に実際の出力（`speaker.wave.3`、`diagnosticsOutputLevel`、`standardVoiceIndicatorOutput`）。値はdBFSの表示値を4段に丸め、最も小さな声より下は無音として灰色（textSecondary）、声があればvoice色。ミュート中・消音中・相手のミュート中は段の代わりにdangerの`mic.slash`／`speaker.slash`。読み上げはlabel「自分の声」「{名前}の声」「出力」、value「話しています」「無音」「ミュート中」 |
| メンバーの状態 | 通常グループの通話中だけ、各メンバーの名前の下に状態の語を1つ出す。話している人は「話しています」（`standardMemberSpeaking-{id}`。語は標準の副次色で、声の大小は行末の声のインジケーターが示す）、本人確認済みでミュート中の人は「ミュート中」、届いているが本人確認前は「接続中」（`standardMemberConnecting-{id}`）、届いていない人は「接続していません」（`standardMemberNotConnected-{id}`）。本人確認済みで黙っている人は語を出さない。判定は保存したメンバーの状態ではなく、今の`authenticatedPeerIDs`・`connectedPeerIDs`を使う。行は名前と状態を1つの読み上げにまとめる。未接続の人の「呼び出す」は未実装 |
| `standardSpeakerButton` / 入出力 | 相手の声を消す切替は「Silence」（消音。消音中は「Silenced」（消音中）、`standardSpeakerControlLabel`）。電話アプリの「スピーカー」（出力先の切替）と紛れないよう「Speaker」の語を使わない。VoiceOverはlabel「Silence」、value「On／Off」（オン／オフ）とisSelectedで読み、既存toggleOutputMuteへ渡す。選択状態の塗りはアクセント色とし、隣の切断（danger）と同じ塗りを並べない。音量は見出しのないSectionのSliderだけ（`standardVolumeSlider`、label「Volume」（音量）。今の出力先の音量）で、数値を出さない。0〜200%の範囲で調整できる。100%の位置だけに基準の目盛を置き、両端の記号の間の幅をすべてSliderに使う。値に応じた追加ラベルや余白を置かず、位置と幅を一定にする。左に`speaker`、右に出力の声のインジケーター。1対1の通話に説明の文は置かない。マイク／出力ミュート、出力・参加者音量、対応機器の音声分離、機器切断後の再開。経路やcodecの診断値は出さない |
| `standardReceiveVoiceIsolationToggle` | 対応環境の接続中に音量の下へ表示する。個人通話は `Isolate the Other Person’s Voice`（相手の声を分離）、グループは `Isolate Incoming Voices`（受信する声を分離）。両方とも自分が聞く混合後の受信へ適用する。 |
| 復旧 | 保存読込失敗・破損の既存reload/reset操作、通話・音声のエラーと再試行案内を同じ状態から表示する |

英語を原文としてString Catalogに一般画面と共通の操作・設定・アカウント案内の日本語を保持する。本人名・別名・グループ名は翻訳しない。App生成の再試行秒数、名前・人数の補間、招待・音声復旧の定型案内も翻訳対象とし、英語の単複を扱う。OSやサービスから来る任意の自由文は独自翻訳しない。Advancedの診断項目の全訳は対象外。購入商品未設定は利用不可と表示し、通知の送信・24時間利用権の完成を装わない。通話権利条件は画面側に追加しない。[共通利用権判定](../通話利用権仕様.md)が媒体準備と成立を区別し、作成不可・権利を持つ参加者待ちにはSettingsのAccessを案内する。


Call は通話開始、接続維持、参加者確認、入出力の最小操作を行う主画面である。

Connect・Disconnect・ローカルマイクの操作は[通話先と操作対象の共通境界](../通信仕様.md#通話先と操作対象の共通境界)を使う。描画時の通話先・通話世代・設定値を保持し、遅れた終了やミュートが別の通話に作用しないようにする。

## 新しい相手への直接招待

設計は[招待と登録](../../../design/招待と登録の設計.md#招待の作成)と[HTML見本](../../../design/一般向け/デザイン見本.html)。ユーザーの＋から、名前の明示保存、招待共有、相手の登録確認を別々に行う。共有先への到着は推測しない。データの正本は`SavedUser`、配送は`ContactInvitationRecord.personID`で紐づける。

| UI・共通操作 | 保存・状態・画面の動作 |
|---|---|
| `inviteContactButton` / `emptyUsersInviteButton` | 両モードとも「Add Person」（相手を追加）。`beginContactInvitationPresentation()`は未保存のUUIDの`.person`を開くだけで、保存・署名鍵生成・招待発行・通信をしない |
| `contactInvitationNameField` / `saveContactPersonButton` | 名前は空の入力欄、仮名は固定の候補。この端末の呼び名と、明示共有する招待文に使うことを説明する。空欄なら候補で「Save」。保存ボタンはキーボードの上を含む下端の`safeAreaBar`。`saveContactPerson`成功で同じシートを保存済み詳細へ切り替える。Return・focus移動・画面終了では保存しない。失敗は名前を保持して同じ画面へ理由を出す |
| `contactPersonSavedName` / `contactPersonRegistrationState` | Standardの保存済み詳細は確定した名前、「Not registered」（未登録）と「相手が登録すると通話できます。」。識別済みの受諾を保存した時だけ「Registered」（登録済み）に更新する。名前は入力欄へ戻さず、登録完了でシートを閉じない |
| `shareContactInvitationButton` | 未登録の人の「Share Invitation」（招待を共有）。`prepareContactPersonShare`は押した時点のログイン世代・未登録の人・有効な招待を照合する。招待を再利用し、初回または期限切れでは同じ人に紐づける。iOS系の標準共有の完了、またはMacの標準共有サービスの完了・リンクのコピー成功で、同じアカウントと招待の状態を確認して共有結果を記録する。共有画面の表示・プレビュー・取消では共有完了を記録しない。コピー・共有後も未登録のままで、受領・登録は返信で確認する |
| `contactInvitationSheet` / `closeContactInvitationButton` | `.person(UUID)`の識別を保存・共有・登録で維持する。OS共有は子の画面であり、取消・コピー・復帰後も同じ人の詳細を保つ。保存前の「Cancel」は無書込、保存後は「Done」（完了）で一覧へ。意図しない親シートの終了を防ぐためinteractive dismissを無効にする。完了で閉じてもUsers所有の有限な返信試行は続ける |
| `standardUser-{id}` | 一覧は`directoryUsers`で未登録を含む同じ人を1行表示。未登録は破線の人物と「Not registered」、タップで詳細（通話を始めない）。識別済みは通常の行で、従来どおりタップで個別通話を開始する。名前の編集・削除は両モード共通の行操作から可能。未登録の人の設定に「本人の名前」を捏造しない |
| `editContactPersonNameButton` | Standardの保存済み詳細から名前の設定を開く。編集は保存ボタンで確定し、取消は保持。完了後は同じ相手の詳細へ戻る |
| Advancedの人の詳細 | `SavedUser`の`id`・`displayName`・`localName`・`memberIDs`・`principal`と、対応する配送記録を同じ詳細に内包する。`ContactInvitationRecord`の`id`・`personID`・`direction`・`state`・`canResume`・`expiresAt`・`peerMemberID`・`nickname`・通知の`session`（running/stopped）をその値で表示する。`Retry Notification`と`Cancel Pending Invitation`／`Stop Retrying Notification`は実装の条件どおり。取消はその端末の再試行を止め、保存した人の詳細を維持する |
| 受諾・返信の表示 | 作者は署名付き受諾で同じ人を識別済みに更新する。受け手は登録時に相手を保存し、未配送の返信はその人の詳細・設定内で扱う。利用可能な近距離の経路では返信と到着確認を自動で届ける。通常通話中も近距離で返信できる。近距離を無効にしている通話中だけ「Waiting for the current call to end.」を表示し、再試行を出さない。`pendingContactInvitations`は内部の未完了一覧を維持するが、人と紐づく記録をUsersへ別行表示しない。旧形式の未紐付け記録だけは互換用詳細へ残す |
| `contactInvitationPreview` | URLの署名・期限・宛先を検証し、本人名と登録・拒否の効果を表示する。URLを開くだけではユーザー／pending／署名鍵を保存しない |
| `acceptContactInvitationButton` / `cancelContactInvitationButton` | 「Register」（登録）で初めて相手を保存し、同じacceptingのシートIDを保って保存済み詳細へ更新する。「Done」（完了）でUsersへ戻る。通常通話・ミュートを維持して返信を開始する。「Decline」（拒否）は保存せず閉じ、拒否通知や拒否記録を作らない。元のリンクは有効期限内なら再び開いて登録できる |

旧形式の未紐付け送信招待は `pendingContactInvitation-{id}` から開く。「Share Invitation」／「Share Again」は保存済みの人と同じ `ContactInvitationShareButton` を使う。`prepareContactInvitationShare` は今のログイン世代・招待ID・期限・保存済みの署名鍵を照合して同じリンクを返す。OSの成功通知で `completeContactInvitationSharing` が同じアカウントと招待を再確認し、未送信（`sent == false`）なら `sent = true` を保存して再表示する。共有の表示・プレビュー・取消ではその詳細に留まり、状態を保つ。Standardは「Not sent yet」から「Waiting to be accepted」へ更新し、Advancedは `sent` の保存値を表示する。親シートはinteractive dismissを無効にし、「Close」で同じ行がある一覧へ戻る。

### 招待返信の共有

[通信を使わずに返信する](../../../design/招待と登録の設計.md#通信を使わずに返信する)の状態と復帰を適用する。URL入口は`rideintercom://contact-reply`。保留中のログインには既存のpendingInviteURLを使い、現アカウントで検証してから共通receiveContactReplyURLへ接続する。URLの検証だけで通常通話やミュートを変更しない。

iOSで「登録」または返信の再試行を押した直後に完了・画面ロック・他のアプリへ移っても、OSが与えた時間内は同じ返信を届ける。人物詳細と相手の設定は両モードで同じ相手ID・招待IDを`retryContactPersonInvitation`へ渡す。時間切れで返信が未配送なら同じ相手の詳細に表示し、既存の共有や再試行を使える。[背景処理の契約](../通信仕様.md#個人の招待と登録)。

| UI・実装 | 動作 |
|---|---|
| 登録後の同じ受け取り画面 | keepingPresentationを指定し、同じacceptingのシート内でStandard／Advancedの保存済み人の詳細へ更新。登録ボタンを外しDoneを出す。相手のpersonIDを保持し、返信を共有するために設定を開き直す手間を設けない |
| StandardのshareContactReplyButton | incoming・pending・canResume・期限内なら詳細／相手の設定に「Share Reply」。通信・通常通話と独立して共有。OS取消・コピーで同じ親を保ち、配達状態を書かない |
| StandardのshareContactConfirmationButton | outgoing・confirmed・receivedBySharing=true・canResume・期限内のときだけ「Reply received」と「Share Confirmation」。相手が確認を開くと返信待ちを解消する旨を添える |
| Advancedの共有 | ContactInvitationRecordのreceivedBySharingをtrue／false／nilで表示。canShareContactReplyに従いincomingはShare Accepted Receipt、outgoingはShare Acknowledgement。人の詳細と相手の設定に同じ記録を内包する |
| export／エラー | InvitationShare(contactReplyID:)がexport時にaccountAccessID・現在の記録・期限・鍵を再検証。表示時とexport時に現在の記録・相手の登録と公開鍵を照合し、削除・取消後の古い共有操作は無効にする。失敗は同じ詳細に表示。読込・保存失敗は既存の再読込へ接続し、通常通話を勝手に切断しない |
| import／再表示 | 元の作者は同じ人・開いている詳細を登録済みに更新。受け手は検証済みACKでpendingを解消。どちらも新しいシートを強制せず、再起動後は同じ人の設定から続ける。未知・改ざん・取消・期限切れは保存しない。相手を削除すると、その人との招待も同時に停止するため、古い返信を開いても一覧へ戻らない。再登録は新しい招待から行う |
| Advancedの再試行・停止 | 同じAdvancedContactInvitationContentを登録直後の詳細・人物詳細・相手の設定で使い、相手IDと招待IDを共通操作へ渡す。受信pendingとoutgoing confirmedの停止はStop Retrying Notification。受信の確認本文は登録済み相手が残ることを伝える。成功後はstate=cancelled、canResume=false、session=stoppedと「Retries stopped on this device.」（この端末での再試行を停止しました。）。再試行・返信共有を出さず、相手と同じ詳細／設定を保つ。保存失敗では元の状態と操作を保って理由を表示 |
| 期限切れの保存済み返信 | StandardのcontactInvitationStateは「Reply expired」（返信の有効期限が切れました）、続けて「Ask the sender for a new invitation.」。再試行・共有を出さず、登録済みの人は保つ。AdvancedはhasExpired(at:)のtrue／falseと期限・保存state・canResumeを併記し、期限内だけ再試行・取消を出す。近距離が無効な通話中、または保存を編集できない場合はRetry Notificationを無効にする。期限到達で人を削除したり通話を切断したりしない |

### 登録後の呼び名の確認

[仮名から本人名への選択](../../../design/招待と登録の設計.md#仮名から本人名への選択)に従う。空欄保存時だけ`usesProvisionalName=true`を渡す。本人名を取得した同じ人の`needsNameConfirmation`を表示条件とし、文字列の形式では推測しない。

| UI・状態 | 表示・操作・保存 |
|---|---|
| Standardの未確認 | 同じ行に「Their name: {本人名}」。タップは既存の接続開始のまま。詳細・相手の設定内に旧名と本人名、「Use Their Name」「Keep This Name」。新しい画面を自動で開かず通話を止めない |
| Advancedの実装値 | 詳細・相手の設定に`usesProvisionalName`（true／false／nil）、`needsNameConfirmation`をそのまま表示。`Use Shared Name`／`Keep Local Name`を同じ保存処理へ接続。確認中は従来のリセット操作を重ねない |
| 確認操作 | `useContactPeerNameButton`／`keepContactLocalNameButton`は表示した両名を再検証してatomic保存。同じ人・シートを保ち、確認を消す。前者は`localName=nil`、後者は現名を保持し、どちらも確認済みを保存 |
| 設定で保存済み | 選択直後は「Done」のみ。入力は実際の`localName`で、nilは空欄・本人名をプレースホルダーにする。新たな文字編集がある場合だけ「Cancel」「Save」へ戻し、2択を隠す。空欄または本人名そのもののSaveは本人名への追従とする |
| Partial／再表示 | 選ばず閉じても元の仮名と未確認を保ち、再表示・再起動で続ける。明示編集済み・由来不明の旧データは自動確認しない |
| Error | 保存失敗・確認中の名前変更は元の名前を保ち、その場で再確認・再試行。別人や新しい編集へ古い選択を適用しない |
| Ideal／Empty／Loading | 選択後は同じ確認を繰り返さない。未登録・本人名未取得では確認なし。ローカル保存に独立Loadingやtimerを作らない |

### Contact招待のUIスタックと遷移

| 状態 | 成立条件・表示 | 操作・復帰先 |
|---|---|---|
| Ideal | 識別済み相手。登録済みの同じ人の行・開いている詳細を更新 | 詳細は完了まで維持。未完了の返信だけを内包し、登録済みの人を招待待ちへ戻さない |
| Empty | 未保存の名前、またはUsersが0件 | ＋→入力→保存。Cancelは無書込。空欄の候補は明示保存時にだけ採用 |
| Partial | 名前だけ保存済み、または登録済みで返信未配送 | 未登録は共有せず完了できる。共有取消・コピー・再表示・再起動で同じ名前と人のIDを保つ。返信は有限な再試行 |
| Error | 名前の保存・リンク準備・検証失敗 | 入力／保存した人と通常通話を保ち、その場で再試行。保存の成否不明では既存の再読込による復旧を使う |
| Loading | 実際の有限な返信試行中 | 現在の通信状態から進捗を出す。ローカル保存に独立したLoading画面・UI用timerを作らず、未登録の人を無期限に待機表示しない |

Appがbackgroundへ移ると、OSから有限の実行時間を得ている返信はその間継続する。それ以外の招待通信は停止し、対象とログイン世代を一時保持する。前面復帰時に同じ世代・有効期限と利用できる経路を確認し、同じ招待を1回だけ再開する。Internet資格や購入の更新を、近距離の再開の前提にしない。サインアウト・別アカウント・期限切れでは再開せず、常時scan・background polling・通知送信を増やさない。各試行は既存の最大60秒に従う。通知は通常のAPNsとUserNotificationsのみで、CallKit・VoIP Push・Apple PushToTalkを使わない。

## Advancedの接続先未選択

通話は接続先が選ばれているときだけ開くため、未選択の画面と`chooseUserButton`・`chooseGroupButton`は置かない。現在の通話があるときはCurrent Callから戻れ、保存データの復旧操作とエラーも表示する。グループの一覧と新規作成はGroupsタブが提供する。タブ移動だけでは既存通話を切り替えず、一覧での別の接続先の選択も今の通話を開くだけで切り替えない。

## 1対1の呼び出しの通知

1対1の接続を新しく始めたとき（一覧・Widget・Watch・Siriのどこからでも`startCall`の`.user`）に、相手から受け取った許可があれば呼び出しの通知を1回だけ送る（`IntercomViewModel.noticeNewDirectCall(to:)`）。すでにその通話中なら送らない。グループは送らない。通知は親切な知らせであり（[製品要求](../../../requirements/製品要求.md#利用者に提供すること)）、送った結果・応答待ち・応答なし・届けられないことを画面に出さず、再送・取消・「もう一度呼び出す」も置かない。状態ヒーローは通話の状態（接続中・会話中など）のまま。Standard・Advancedの相手の設定と、Apple Watchにも手動の送信・取消を置かない。

## ユーザー指定の個別通話

| 項目 | 表示・操作 |
|---|---|
| Users | 直接招待関係として保存した相手名を`standardUser-{UUID}`の行に表示。共通の`selectUser`へ渡し、双方の確認済みアカウントがあれば別端末でも同じ二人の内部通話先を解決する。自分の別端末は対象外。削除済み・未知のUUIDは画面外から渡しても拒否する |
| Current Call | 進行中の個別通話を`standardCurrentCallButton`で開く。相手を削除するとその通話は切断され、Current Callからも消える |
| Groups | kind=groupだけを表示。個別通話の内部ID・group作成操作を要求しない |
| 個別通話の画面 | タイトルは相手名。Standardは`kind == .direct`ならメンバーSection（`standardCallParticipantsHeading`、自分と相手の行、個別音量、招待）を表示せず、ヒーロー・通話操作・音量を表示する。接続待ち・音声停止・エラー・再表示・表示モードの往復でも同じで、通常グループは2人でもメンバーSectionを維持する。Advancedの`directCallHelpLabel`は個別通話であること（Individual call）を示す。相手を削除すると個別通話groupも消えるため、削除後の状態の表示はない。既存通話中に別の相手を選んだときは今の通話を開くだけで切り替えない（AdvancedのConnectも別の通話を置き換えない） |
| Share Call Invite | Advancedの通話の`More`の項目（`inviteButton`）とUser Settings（`userSettingsInviteButton`）に、共有可能な場合だけ表示する。User Settingsの共有先とUsersの行の短縮IDは、その行から個別通話を始めるときと同じIDで解決する。相手のアカウント宛て通話を使う場合、別に保存された端末宛て通話を共有先に選ばない。解決先の保存前は行に`No direct group yet`を表示し、User Settingsに共有を出さない。共有操作は特定の相手宛ての署名付き招待をOS共有画面へ渡す。Standardの個別通話には相手の設定への入口を置く。通常groupの`Invite`とは宛先制約が異なる |
| 鍵の競合からの復旧 | Standardで異なる鍵を持つ個別通話の招待が届き、この端末が既存の鍵を保持する側なら、通話の補助情報にある案内と同じSectionに「招待を共有」（`shareCrossedDirectInvitationButton`）を出す。表示中の対象が一致し、共有できる場合に限る。OS共有の取消・コピー後は同じ通話を表示する。相手が新しい招待を受け取って開くと既存の鍵選択処理が適用される |
| 参加者操作 | 個別通話ではAdd Saved Users、参加者Delete、招待枠の追加を提供しない。ミュート・音量・音声効果・Disconnectは既存の共通操作を使う |

## 保存済みユーザーの操作

Groupsの`New Group`（`standardCreateGroupButton`）からFormを開く。見出しは「New Group」（既存groupへの追加は「Invite Members」）。新規作成の名前入力（`savedUsersGroupNameField`）は、共通の`MemberSelection`が生成した編集可能な名前で開く。空欄時のprompt・保存名、選択しても変えない条件は[新しいグループの初期名](#新しいグループの初期名)を正本とする。既存groupへの追加では名前欄を出さない。

| 項目 | Standard（`StandardMemberSelection`） | Advanced（`AdvancedSavedUsersSelection`） |
|---|---|---|
| 保存ユーザーの行 | 「Your Users」（あなたのユーザー）にアバター・名前・選択の印（`checkmark.circle.fill`／`circle`）。候補がなければSectionを出さない | 「Saved Users」に名前と選択中だけの`checkmark`。Toggleは使わない |
| 行の操作 | 両モードともタップで選ぶだけ（`selectUser-{UUID}`、VoiceOverは選択状態）。行に名前の編集・削除、説明やfooterを置かない | 同左。画面の構成と選択の印はモードごとに持つ |
| 人数とエラー | 保存と共通のSavedUser.groupMemberIDsで数える。確認済みの同じアカウントは1枠、principalがない相手はmember ID単位。一覧の下の`safeAreaBar`に「{n}/8 people including you」（自分を含めて{n}/8人、`memberSelectionCount`）と`savedUsersErrorLabel` | Formの別Sectionに「{n} of 8 members including you」と`savedUsersErrorLabel` |
| 確定操作 | `safeAreaBar`に主要操作1つ（`saveUserSelectionButton`）。作成は`Create and Connect`（作成して接続）、別の通話中は`Create Group`、既存groupへの追加は`Save Invitations`（招待を保存） | ツールバーの`saveUserSelectionButton`。新規作成は同じ`Create and Connect`／`Create Group`、既存groupへの追加は`Add Users` |
| 取消 | ツールバーの`Cancel`（`closeSavedUsersButton`）。変更せず閉じる | 同左 |

選択の値・名前の生成・検証・保存は両モード共通の`MemberSelection`。保存済みの相手を使うグループを作成し、待機中ならそのまま接続する。既知のアカウントと確認済み端末鍵を持つ登録済みの相手には、保存と同時に配送待ちを作り、自動配送する。未交換の許可は次の接続で交換し、手動共有も任意に使える。新しい人には下記の名前付き共有段階を出す。

Usersの行の`User Settings`（`userSettingsView`）は相手の設定を開く。モードごとに別のView（`StandardUserSettingsView`・`AdvancedUserSettingsView`）で、`UserSettingsView`が選ぶ。Standardは、見本の項目だけを置く。「Name on This Device」（この端末での名前、`savedUserNameField`。今の呼び名で開き、空なら本人の名前をプレースホルダーに出す）と別のSection「Their Own Name」（本人の名前、`savedUserOriginalName`。副次色で読むだけ）、最後に赤の`Delete User`（ユーザーを削除、`deleteUserButton`。確認はタイトル「{呼び名}を削除しますか？」と「削除」（`confirmDeleteUserButton`。その相手と接続中なら本文「今の接続は切断されます。」と確定「切断して削除」）・「キャンセル」で、削除の同期が未実装のため本文を出さない）。`Save`（`saveUserNameButton`）では、空欄か本人の名前と同じなら呼び名を解除して本人名に従い、それ以外は端末内の呼び名として保存する。招待の共有、`Use Shared Name`、通知の切替、説明のfooterは置かない（通知はOSの設定だけで、個人で登録した相手は全員通知を送ってよい）。Standardの相手の設定には呼び出しの送信を置かない。1対1の接続を始めると呼び出しの通知を1回だけ送る（下の[1対1の呼び出しの通知](#1対1の呼び出しの通知)）。AdvancedもUsersの行のスワイプ（Macは右クリック）の「User Settings」から開く。Advancedの相手の設定は端末での呼び名、本人名、`Use Shared Name`（`resetUserNameButton`）、Usersの行が解決する個別通話が保存され共有可能なら招待（`userSettingsInviteButton`）、`Delete User`を置く。手動の呼び出し・受信の切替は両モードとも置かず、`closeUserSettingsButton`で閉じる。同じ名前の別IDは統合しない。行のDeleteは相手とその個別通話group（Advancedの`advancedDirectGroup-{UUID}`）を消し、その相手との進行中の通話は切断する。通常グループのメンバーは保持する。表示名変更は既存グループにも反映する。

StandardではCallのメンバー一覧の先頭の`Invite Members`（メンバーを招待、`addSavedUsersButton`）、Advancedは通話の…メニュー（`callAddMembersButton`）、両モードでGroup Settings（`groupSettingsAddMembersButton`）から保存ユーザーを追加する。現在のgroup IDを操作対象として固定し、直接招待関係のある保存ユーザーのうち、まだ含まれない相手を選択して追加する。自分を含め8memberまでで、重複・古い操作対象・保存失敗は確定しない。`savedUsersErrorLabel`で失敗を示す。選択中は通知しない。保存時に確認済みの相手への自動配送待ちを作り、許可未交換の相手は次の接続を待つ。旧形式の相手は手動共有する（下の登録済みの相手へのグループ招待）。

確認済みの登録相手には暗号化した招待を自動配送する。相手の端末が受取を確定するまでは「招待中」。受取側は確定前は一覧やグループタブの案内に出さない。手動共有では署名付きURLを相手が開いたときにgroupを保存する。新しい人は個人登録とgroup参加を兼ねる専用招待を使う。保存ユーザーを選ぶか新しい人を1人以上入力した作成・追加が成功したら、sheetを閉じずに同じsheetを招待の段階へ切り替える。

| 状態 | 成立条件 | 表示 | 可能な操作 | 復帰先 |
|---|---|---|---|---|
| Ideal | 保存ユーザーまたは新しい人を1人以上含む作成・追加が保存された | 見出し`Invitation`（招待）。常に対象group名。Standardは相手の名前と招待状態、AdvancedはIntercomGroup・SavedUser・GroupDeliveryRecordの値。任意の共有ボタン（`addedUsersInviteButton`） | 共有、Done（`finishAddingUsersButton`） | Doneで元の画面。作成時は新groupの通話画面 |
| Partial | 共有せずにDoneを押した | Standardの通話・グループ設定では同じ相手の行に招待状態を表示 | 新しい相手の行から同じ人物詳細へ戻り、共有できる。Advancedの宛先のないリンクはGroup Settingsの`groupSettingsInviteButton`または通話の…メニューから共有できる | 元の画面 |
| Error | 保存に失敗した | 選択画面のまま`savedUsersErrorLabel` | 選択の変更・再試行・Cancel | 選択画面 |
| Empty | 保存ユーザーも新しい人も含めずgroupを作成した | 招待の段階を出さずにsheetを閉じる | 通常どおり | 新groupの通話画面 |
| Loading | 該当しない | 保存は同期処理で、共有URLはOS共有画面の要求時に作るため待ち表示を持たない | — | — |

Standardの通常グループでは、通話とGroup Settingsのメンバー一覧の先頭に「メンバーを招待」を置く。新しい相手の枠は破線のアバターと名前、「まだ送っていません」「受け取り待ち」「期限切れ」など、保存した招待の状態で示す。接続の有無にかかわらず、行から同じ人物詳細を開く（通話では `standardCallInvitee-{id}`）。共有を閉じても詳細に留まる。返信が確認できたら同じ枠が通常のメンバーになり、招待状態と招待詳細への入口が消える。登録済みの相手への配送記録も、未完了は両画面で同じ語にする。保存確認後の「受け取り済み」はグループ設定で確認できる。

招待の段階の表示中に対象groupが削除された場合はsheetを閉じる。共有URLは既存のInviteと同じく共有時に対象group・権利を再検証する。

Users / Groupsのルート識別子`standardUsersList` / `standardGroupsList`は、モード切替前後の既存UIテストとの互換性のためAdvancedでも維持する。状態と操作の所有者は共通のViewModelであり、識別子は画面構成の共有を意味しない。Call配下はStandard・Advanced・Commonに責務ごとに配置する。

### 新しいグループの初期名

新規作成の共通データ`MemberSelection`は、初期化時に`Group {code}`（日本語「グループ {code}」）を生成し、`typedName`へ入れる。`code`はUUIDの先頭6文字（0〜9・A〜F）。保存済みの名前と一致したら生成し直す。両モードの入力欄`savedUsersGroupNameField`はこの値で開き、空にすると同じ生成名をpromptに出す。`groupName`は空白を除いた手入力を優先し、空ならその生成名を使う。生成名は有効な名前なので、メンバー未選択でも作成できる。選択・再描画で初期名と手入力を置き換えず、閉じて新しい作成画面を開いたときに次の初期名を生成する。

作成前の手入力、作成後の明示的な名前編集、保存・再表示を保持する。既存グループへのメンバー追加では名前を生成せず、保存済み名・個人通話の内部名も変えない。名前の生成・検証・保存は同期処理で専用Loadingを持たず、保存失敗は既存のエラー表示と入力保持を使う。利用不可・人数上限などのcanSave条件は維持する。

### 一覧の削除のUIスタック

| 状態 | 表示と操作・復帰先 |
|---|---|
| Ideal | 編集可能なオーナーの通常グループ行に共通の削除・設定を出す。削除は確認後に実行する |
| Empty | 最後のグループを削除したら既存のNo Groups Yetと新規作成の入口へ戻る |
| Error | 保存復旧が必要など`canEditSavedGroups`が偽なら行の削除を出さず、既存の保存エラーと復旧操作を維持する。削除失敗ではグループを維持する |
| Partial | 接続中のグループも同じ確認を使い、本文と確定ボタンで切断を伝える。取消でグループと通話を保つ。非オーナーの行は設定だけを出す |
| Loading | ローカルの削除は同期処理のため専用表示を設けない。他端末への同期は未実装であり、全員への削除完了を表示しない |

## グループの設定と相手の設定

グループの設定の最後の削除／抜けるとその確認は、両モードで同じ`Common/GroupRemovalSection.swift`を使う。`groupRepository.ownsGroup(group.id)`でオーナーは`Delete Group`、それ以外は`Leave Group`を出し分け、`canEditSavedGroups`が偽なら無効にする。記号を付けない赤い文字のボタン、グループ名を含む確認、接続中だけの切断の案内、取消・確定の結果を共有する。設定の名前・メンバー・招待の構成はモードごとに維持する。 新しい相手への招待で保存したgroupから抜けると、そのgroupに結合した未完了の返信を保存と同時に取消し、対応する試行を停止する。登録済みの相手と個人通話は残る。古い招待の再登録は既存の新しい招待を求める表示にし、削除したgroupを戻さない。

[操作の流れ](../../../design/操作の流れ.md)の「設定は名前の付いた入口から」に従う。画面はモードごとに別のView（Group Settingsは`StandardGroupSettingsView`・`AdvancedGroupSettingsView`、User Settingsは`StandardUserSettingsView`・`AdvancedUserSettingsView`）で、`GroupSettingsView`・`UserSettingsView`が選ぶ。Users / Groupsの一覧の行のswipeは両モードで完全に同一のため、`Common`の修飾子`destinationRowActions`を共用する。使用済みの通常グループURLを退出後に再び開くと、新しい招待を依頼するよう案内し、現在の画面・通話を保つ。メンバーの行のswipeは項目が違う（Advancedだけ名前の編集がある）ため、モードごとの修飾子（`standardMemberRowActions`・`advancedMemberRowActions`）に分ける。削除・外すの確認（`destinationDeleteConfirmation`・`memberRemoveConfirmation`）は安全規則として共通にする。グループ設定でメンバーを外す確定は共通の `removeMember` へ渡す。確定時に有効な利用権・保存可否・対象の所属を照合する。確認中に利用権が切れた場合は、開いていた画面とメンバーを保ち、その画面で設定の「利用権」への案内を出す。保存成功後に行を消し、その相手への未受領の自動配送を取り消す。この端末では相手の音声を停止し、再接続しても行を戻さない。残った相手との通話は同じ通話を続ける。ほかの端末への除外反映は削除同期の対象。Standardのメンバー詳細は保存成功時に閉じる。同期は画面を閉じた後もアプリが続ける。長押しのメニュー（`contextMenu`）は両モードとも置かず、マウスでスワイプできないMacだけ同じ項目を右クリックのメニュー（`macRightClickMenu`）に出す。入口はStandardは通話のツールバーの設定のボタン、Advancedは通話の…メニューと、Users / Groupsの行のswipeだけで、行のタップは接続の1つの意味に保つ。開いても選択中の通話・表示中の通話を切り替えない。

| 画面 | 項目 | 操作 |
|---|---|---|
| Group Settings（`groupSettingsView`） | 名前（`groupSettingsNameField`）、メンバー（Standardは先頭に自分の行（「自分」、`groupSettingsSelf`、操作なし）。相手の行のタップ（`groupSettingsMember-{id}`、行末にchevron）でメンバーの画面（`StandardGroupMemberView`。タイトルはその人の名前、「この端末での名前」（`groupMemberNameField`。空ならプレースホルダーに本人の名前を出し、空で保存すると本人の名前に戻る）と最後の赤い`Remove from Group`（グループから外す、`removeGroupMemberButton`）だけ。Advancedの`GroupMemberNameView`とは部品を分ける）を開き、行のswipeは`Remove`（`person.badge.minus`）だけ。Advancedは行のswipeで`Edit Name`と、`canManageRegularGroups`のときだけ`Remove`を出す。Macは同じ操作を右クリックで出す。どれも標準の`alert`で「{名前}をグループから外しますか？」と確認し、確定は`confirmRemoveMemberButton`）、追加の行（`groupSettingsAddMembersButton`。Standardは一覧の先頭に破線のアバターと`Invite Members`（メンバーを招待）で、通話のメンバー一覧の先頭と同じ語。Advancedは`Add Members`）、招待（`groupSettingsInviteButton`。Advancedのみ）、最後の赤いボタン1つ（両モードで同じ`GroupRemovalSection`。記号なしの赤い文字）: グループを作った人（オーナー。この端末で作ったグループ。招待から入ったグループは`GroupSnapshot.Record.joinedByInvitation`で区別し、記録より前のグループはオーナー扱い）は`Delete Group`（`deleteGroupButton`）、それ以外は`Leave Group`（グループから抜ける、`leaveGroupButton`。この端末から外す。ほかのメンバーへの反映は削除の同期で行う）。確認のタイトルは「{グループ}を削除しますか？」／「{グループ}から抜けますか？」、接続中なら本文「今の接続は切断されます。」と確定「切断して削除」／「切断して抜ける」（`confirmDeleteGroupButton`／`confirmLeaveGroupButton`）。メンバーの招待（`groupSettingsAddMembersButton`と通話の`addSavedUsersButton`）と外す操作は利用権を持つ人（`canManageRegularGroups`）だけに出し、持たない人には出さない（無効にして見せない）。宛先のないグループのリンクはAdvancedの`Invite`で共有する | `Done`（`saveGroupSettingsButton`）で名前を保存して閉じる。名前は端末内の`renameGroup`で保存し、接続中でも再接続しない。`|`は保存しない。Standardの名前の欄はプレースホルダーにメンバーの名前から作った名前（例: Haruka and Kenta）を出し、空にして`Done`を押すとその名前を保存する。Advancedは空白だけの名前を保存しない。削除・退出は確認後に保存する。保存に成功したら、対象グループに接続中のときだけ切断し、設定を閉じる。保存に失敗したら設定と名前の入力を保ち、同じ画面に既存の保存エラー（`groupSettingsError`）を出す。グループと接続は保つ。`Cancel`（`closeGroupSettingsButton`）は名前を保存しない |
| User Settings（`userSettingsView`） | Standardはこの端末での名前、本人の名前、`Delete User`。Advancedは端末での呼び名、本人の名前、Use Shared Name、招待（`userSettingsInviteButton`）、`Delete User`（`deleteUserButton`） | `Save`で呼び名を保存。削除は確認の後で、相手の個別通話groupも消し、その相手との通話は切断する。通常groupの所属と招待で確認した本人の情報は保持する |

Advanced Group Settingsの新規招待行（`groupSettingsMember-{id}`）は `outgoingGroupInvitation(forPendingMember:in:)` で対象のグループと予約枠に一致する `ContactInvitationRecord` を読む。メンバー名に `direction · state · sent {true|false|nil}` とISO 8601の `expiresAt` を添える。人物IDが一致する詳細を開き、OS共有取消で状態を維持し、共有完了で同じ行の `sent` を更新する。署名付き返信が保存されるとその枠を通常メンバーとして表示する。登録済み相手への配送は同じgroupの `GroupDeliveryRecord` を別Sectionで確認する。

対象groupの消失・種別不一致では設定の内容を表示しない。設定の招待は対象group IDに固定した共有（`InvitationShare(settingsGroupID:)`）を使い、表示中の通話が別のgroupでも、共有時に対象groupの存在・鍵・権限を再検証する。通話画面の招待は従来どおり表示中の通話に固定し、選択が変われば共有しない。Advancedの通話の参加者は状態と音声操作だけを表示する。Standardで新しい相手の招待枠をタップすると人物詳細を開く。名前の編集と通常groupから外す操作はGroup Settingsで行う。相手を追加し直した後も、外す前に保存した名前付き招待への遅れた返信では、その相手の行や現在の通話を更新しない。

## 通話画面

### 親セクション

| 項目名（日本語） | 項目ID | 目的 | 実装 | 発現条件 | 表示仕様 |
|---|---|---|---|---|---|
| 通話画面 | `callScreen` | 接続、音声入出力、参加者状態を一画面で扱う | `CallView` | `selectedGroup != nil` | 画面タイトルは通常group名、個別通話では相手の表示名。横のcompact高さと幅600pt以上では、状態ヘッダーと接続操作の列、参加者とエラーの列に分けてそれぞれスクロールする。触覚はStandardと共通 |
| 通話ステータスヘッダー | `callStatusHeader` | 通話全体の状態を最上部に集約する | `statusHeader` | 常時 | 接続、入力、出力をまとめる |
| 接続操作 | `connectButton` / `disconnectButton` | 通話を開始・終了する | `controls` | 常時 | 接続状態に応じて表示 |
| 参加者セクション | `call-participants-section` | 相手ごとの状態、出力調整、peer bus effect 設定を扱う | `VStack` | 常時 | 見出しと参加者領域 |
| 音声エラー表示領域 | `audioErrorLabel` | 音声系失敗を可視化する | `Text` | `audioErrorMessage != nil` | 赤文字 |

### ステータスヘッダー

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|
| 通話状態要約 | `callStatusHeader` | `connectionStatusIcon` | `Call status` | `callPresenceLabel`, `routeLabel`, `connectionState`, `isAudioReady`, `isCallMediaStarted` | 接続アイコン + 2 行テキスト | Idle、Waiting、Connected / Audio Idle、通話中 |
| 接続状態ラベル | `connectionStatusIcon` | `callPresenceLabel` | 接続状態名 | `String` | 1 行目 | 状態不明時も文言化する |
| 経路ラベル | `connectionStatusIcon` | `routeLabel` | 経路 | `String` | 2 行目補助テキスト | Local / Internet / Offline / Control Only |
| ローカル入力ヘッダー | `callStatusHeader` | `localMicrophoneHeaderControl` | `Input` | `GroupMember`, `Bool` | ローカル入力状態カード | Unmuted / Muted |
| ローカル入力状態ラベル | `localMicrophoneHeaderControl` | `localMicrophoneStateLabel` | `Unmuted` / `Muted` | `isMuted` | 状態テキスト | 入力状態 |
| ローカル入力メーター | `localMicrophoneHeaderControl` | `localMicrophoneMeter` | なし | `voiceLevel`, `voicePeakLevel`, `isMuted` | 値文字列なしのメーター | 入力レベルとピーク |
| ローカルミュートボタン | `localMicrophoneHeaderControl` | `localMicrophoneMuteButton` | `Mute` | `Bool` | `mic.slash`固定のglassボタン。ミュート中だけdangerのglassProminentとisSelected | 押下でマイクミュート反転。Watch音声選択中は操作を外し、Watchでの操作案内を表示 |
| マスター出力グループ | `callStatusHeader` | `outputStateLabel` | `Output` | `masterOutputVolume`, `isOutputMuted`, `receiveMasterSoundIsolationEnabled` | 出力ラベル + スライダー + Isolate All Received Voices + ミュート | OS 音量ではなく App 最終出力 |
| マスター出力スライダー | `callStatusHeader` | `masterOutputSlider` | `Output Volume` | `Float`, `0...2` | `1.0` が通常、`1.0` 超過は boost | マスターgain後のrx-output PeakLimiterで最終ピークを抑制 |
| マスター出力 Voice Isolation Effect | `callStatusHeader` | `masterVoiceIsolationToggle` | `Isolate All Received Voices`（英語） | `receiveMasterSoundIsolationEnabled`。既定 `false` | `supportsSoundIsolation == true` のとき Toggle | RX master bus の SoundIsolation effect 有効/無効 |
| マスター出力ミュートボタン | `callStatusHeader` | `masterOutputMuteButton` | `Mute Output` / `Unmute Output` | `Bool` | ミュート時はアクセント色のglassProminentとisSelected | 入力や接続は止めない |
| ダッキング状態アイコン | `callStatusHeader` | `duckingStatusIcon` | なし | `isDuckOthersEnabled`, `isOtherAudioDuckingActive` | 設定 ON 時のみ `waveform` | 設定 ON と実効 ON を分ける |

### 接続操作

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|
| 接続ボタン | `callScreen` | `connectButton` | `Connect` | `canDisconnectCall == false` | 主要ボタン | 音声起動失敗と接続失敗を分ける |
| 切断ボタン | `callScreen` | `disconnectButton` | `Disconnect` | `canDisconnectCall == true` | 主要ボタン | 音声起動失敗と接続失敗を分ける |

## 参加者

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|
| 参加者見出し | `call-participants-section` | なし | `Participants` | 固定文字列 | セクション見出し | なし |
| 参加者空状態 | `call-participants-section` | `emptyRemoteParticipantsLabel` | `No remote riders` | 固定文字列 | 空状態カード | 相手不在 |
| 参加者カード行 | `call-participants-section` | `remoteParticipantRow{index}` | 参加者カード | `GroupMember`, `remoteOutputVolumes[member.id]`, `remoteSoundIsolationEnabled[member.id]` | 1 参加者 1 カード | 受信音声がなくても存在 |
| 参加者名 | `remoteParticipantRow{index}` | `participantName{index}` | `member.displayName` | `String` | 最大 2 行 | 保存名 |
| 接続/認証状態 | `remoteParticipantRow{index}` | `participantStatusSummary{index}` | 状態の文字 | `connectionState`, `authenticationState` | Wi-Fi 系 + 認証系の記号と文字 | 接続軸と認証軸を分ける |
| コーデック表示 | `remoteParticipantRow{index}` | `participantAudioPipelineState{index}` | `PCM 16-bit` など | `AudioCodecIdentifier?` | `Label`。未観測は `--` | 最後に観測した codec |
| 参加者入力メーター | `remoteParticipantRow{index}` | `participantVoiceLevel{index}` | なし | `voiceLevel`, `voicePeakLevel`, `isMuted` | 値文字列`LEVEL n  PEAK n`（ミュート中は`MUTED`、`voiceMeterValueLabel`） | 受信後デコード済みレベル |
| 参加者出力値 | `remoteParticipantRow{index}` | `participantOutputValue{index}` | `{n}%` | `remoteOutputVolumes[member.id]` | 補助テキスト | peer source fader |
| 参加者出力スライダー | `remoteParticipantRow{index}` | `participantOutputSlider{index}` | `{name} Output` | `Double`, `0...1`。未設定時 `1.0` | 個別出力スライダー | マスター出力とは別。peer source faderへ即時反映 |
| 参加者 Voice Isolation Effect | `remoteParticipantRow{index}` | `participantVoiceIsolationToggle{index}` | `Isolate This Voice`（英語）、読み上げは `Isolate Voice From {name}` | `remoteSoundIsolationEnabled[member.id]`。未設定時 `false` | `supportsSoundIsolation == true` のとき Toggle | 該当 peer bus の SoundIsolation effect 有効/無効 |

## エラー表示

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|
| 音声エラーメッセージ | `audioErrorLabel` | `audioErrorLabel` | 音声エラー文言 | `String` | 赤色フットノート | 画面全体を塞がず、その場で読める補助文言として扱う |

## Voice Isolationの現在の提供状態

SoundIsolation対応環境では、Settingsに自分の送信側、Callに受信側の操作を表示する。AdvancedのOutputは受信全体、参加者行はその相手の受信へ適用する。通話開始時に実Mixerへノードを接続し、設定変更は実Audio Unitのbypassへ反映する。停止中は要求設定だけ保持し、稼働中とは表示しない。非対応環境では操作を表示せずsupport reportで区別する。

## 混在通話・機器切断の表示

| 項目 | 仕様 |
|---|---|
| 経路 | availableRoutesからLocal / Internet / Local + Internetを表示。Localだけでも他者経由の中継が可能 |
| 音声操作 | 全production routeで共通のmeter・effect・master/peer音量・muteを使用 |
| Internet失敗 | `connectivityNotice`。通常は到達可能な参加者との接続を維持して再試行する旨を表示。アカウントの既存通話との競合は、既存通話の終了・通信断時の期限待ち・再操作を案内する。通話全体が手動復帰待ちならConnectを表示する |
| 通話中のiOS音声再構成 | 同じ入出力先で音声の構成だけが変わったときは、同じ通話で音声が自動で戻る。再構成に失敗したらAudio Pausedを表示し、理由と再開の操作を出す。マイクの許可が得られなかった場合は、設定で許可する案内を理由にする。Standardはヒーローに理由をまとめ、Advancedは再開操作のそばに理由を出す。 |
| 機器消失 | `audioRouteNotice`と、認証済み相手がいるときはConnected / Audio Paused、相手待ちはAudio paused。理由と接続・中継の維持を明示 |
| 再開 | `resumeAudioButton`。標準Button、文字ラベルとSF Symbolを併用。認証済みpeerなしでは無効 |
| 別グループ閲覧 | activeGroup用の機器・経路通知を別groupの状態として表示しない |
| 到達確認 | 接続状態・mute解除は相手に聞こえた証明ではない。実音声の受け入れを別途行う |

## 経路共通の操作と識別

| 対象 | 契約 |
|---|---|
| マスター・参加者音量 / effect / meter | Local / Internet / 中継で共通。経路変更で操作を隠さない |
| callStatusHeader | 独立したaccessibility container。子の`masterOutputSlider`、`masterOutputMuteButton`などの識別子を上書きしない |
| 話者設定 | origin peer IDごとに保持。中継gatewayの音量ではない |

## グループ資格の案内

| 状態 | 表示・動作 |
|---|---|
| 鍵不足・保存失敗・不正招待・command過負荷 | Call入口の `groupErrorLabel`。AdvancedはCallの内容の先頭に不透明のカード（`AdvancedCallErrorCard`。接続先がないときはそのカードだけのScrollView）で置き、`Material`の帯にしない。理由と再招待/再試行を表示する。切断後にも表示し、新しい接続は利用者の操作で開始する |
| 新規グループ作成・有効な選択/接続 | 以前のgroupエラーを解除。通話中に別groupの招待が失敗しても旧通話は維持 |

情報は色だけに依存せずテキストとアイコンで伝え、通常エラーは文脈内に表示する。[Apple HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)に従い、明示的に全groupを消すresetだけ確認を要求する。

## 保存済みグループの復旧

| 項目ID | 表示・操作 | 条件と結果 |
|---|---|---|
| groupStorageStatus | Groups上部のSaved Groups Section、文字とSF Symbol | 一時アクセス失敗・破損・未知schema・鍵欠落・回収待ちを区別。固定高を設けず折り返す。同じ保存エラーを上部bannerへ重複表示しない |
| reloadSavedGroupsButton | Reload Saved Groups | 通話中は無効でDisconnectを案内。未知schemaも無効。成功時は一覧を再構成し選択とerrorを解除 |
| resetSavedGroupsButton | Reset Saved Groups and Users… | 破損時のみ標準destructive Button。標準alertに影響、退避、再招待の必要性を表示 |
| confirmResetSavedGroupsButton / cancelResetSavedGroupsButton | Reset Saved Groups / Cancel | 確認後だけ通話を終了し、元データ退避→空manifest commit→group鍵回収。Cancelを明示し、取り消しなら変更なし |
| standardCreateGroupButton | New Group | 保存読込に失敗している間は無効。鍵欠落・回収待ちだけなら他groupの利用を妨げない |

resetでrider identity・音声設定・Internet資格は変更しない。退避失敗なら元データを保持してerrorを表示する。一般commandの待機上限超過はCallの案内から、停止完了後の明示Connectを促す。

### グループ内の名前編集

AdvancedではGroups管理画面の参加者名から、StandardではGroup Settingsのメンバーの行から名前編集を開く。対象groupを固定したFormで、`groupMemberNameField`にこの端末の呼び名（見出し「この端末での呼び名」、プレースホルダーは本人の名前。空で保存すると本人の名前へ戻す）、`groupMemberOriginalName`に本人名を表示する。`saveGroupMemberNameButton`で保存、`resetGroupMemberNameButton`で本人名へ戻す。保存ユーザーなら一覧の呼び名も更新し、それ以外は対象groupだけへ保存する。編集を理由にユーザー登録・通知をしない。

### Standardの直近通話

通話していないときに、現在のアカウントと保存一覧で確認できる直近宛先をStandardのUsers一覧の先頭のRecent Callに表示する（以前の通話タブの空状態から移した）。Advancedの設計にないため、AdvancedのUsersには出さない（`RecentCallSection`は`Standard/StandardDirectoryViews.swift`）。行のタップは他の行と同じ`openDestination`。行は一覧の行と同じ`DirectoryRowLabel`で、種類のアバター、現在の名前、補足（グループは「グループ・{n}人」、人物は「ユーザー」）を出す（`recentCallButton`）。描画時に示した宛先とログイン世代を共通開始操作へ渡し、削除やログイン変更後は再検証する。通話成立時の記録、設定との保存、破損時の扱いは[通信仕様](../通信仕様.md#直近の成立済み通話先)を参照する。

## 共通の操作表現

StandardとAdvancedの接続・音声再開には標準`glassProminent`、補助操作には`glass`のButtonStyleを使う。Advancedの参加者操作と、Form内の設定コントロールを維持する。画面の背景は、上端のbackgroundTop（ライト`#CFE5F6`、ダーク`#0E2238`）から下へbackgroundBase（ライト`#EBF1F7`、ダーク`#03070D`）に変わり、変化の終わりから下は一定の色にする（`AppColorPalette`の`callScreenBackground`・`listScreenBackground`と`screenBackground(_:)`。List・Formは標準のセルのまま、背景を画面に固定する）。終わりの位置は、StandardのCall・Appleログイン・名前の入力が高さの45%（ガラスのヒーローと操作が変化の上に乗る）、Users・Groups・招待のシート・Settingsとその中の画面・AdvancedのCall・Diagnosticsが25%（行は一定の色の上に並ぶ）。macOSは標準のwindowの背景で、グラデーションを使わない（[背景のグラデーション](../../../design/カラーテーマ.md#背景のグラデーション)）。下から開くシート（メンバーを招待・新しいグループと招待の送信、グループの設定、相手の設定、メンバーの呼び名、招待の受け取り、購入、アカウントの削除と削除中の表示）も同じ25%の背景にし、Formの標準の単色にしない。面は[面の重なり](../../../design/カラーテーマ.md#面の重なり)に従い、独自に描くAdvanced・Diagnosticsのカード（`appCallCardStyle`・`appDiagnosticsCardStyle`）は不透明の`cardSurface`（`secondarySystemGroupedBackground`）に`cardBorder`の枠線、Diagnosticsの入れ子の面は不透明の`panelSurface`（`tertiarySystemGroupedBackground`）で、ガラス・Material・薄めた色にしない。ガラスはStandardの状態ヒーロー、ボタン、ナビゲーションだけ。通話のアクセサリの中のミュート（オフ）と切断は、OSのガラスの上に記号だけを置き、ミュート中だけDangerで塗った円に白い記号にする。共通の青いtintで揃える。


## 新しい相手へのグループ招待

Standardの通話の`Invite Members`（`addSavedUsersButton`）、Advancedの通話の`More`にある`Add Saved Users`（`callAddMembersButton`）、両モードのGroup Settings（`groupSettingsAddMembersButton`）、新規作成は同じ`SavedUsersView`へ入る。両モードとも、`canManageRegularGroups`が偽なら既存グループの招待入口を出さず、新規作成を無効にする。利用権があり通常groupの8枠に余裕があれば、候補の保存ユーザーが0人でも入口を使える。満員の既存グループでは招待を無効にする。入力中に利用権が切れた場合は名前・選択を保ち、保存を無効にして同じ画面で設定の「利用権」を案内する。保存時も共通判定を使う。

| 対応する実装・ID | 表示・操作 |
|---|---|
| MemberSelection.newPeople／newGroupID | 未保存のGroupInvitationDraftを保持。StandardはYour Usersの上、AdvancedはNew Peopleに共通NewGroupInviteesを置く。保存済みの選択行は各モードのまま |
| addNewGroupInviteeButton | Invite Someone New（新しい人を招待）。押すと名前欄を追加してfocusし、人数へ1枠を加える。8枠で無効 |
| newGroupInviteName-{UUID} | Their Name。空欄は重複しない仮名候補を採用。Removeは未保存行だけを外す。Returnはfocusを外すだけで保存しない |
| saveUserSelectionButton | Standardの既存groupはSave Invitations、AdvancedはAdd Users、新規作成のCreate and Connect／Create Groupは従来どおり。名前・人・予約枠・招待を同じcommitで確定する |
| groupInvitePerson-{UUID} | Invitation（招待）に参加先・保存済みの名前を並べ、同じ人のモード別詳細を開く。元のperson IDで識別し、既知の相手へ解決しても勝手に別画面へ進めない |
| shareContactInvitationButton | 参加先と人を確認してOS共有へ。取消・コピーで同じ詳細と保存状態を保つ。Doneは取消ではなく、保存済みのまま閉じる |
| group設定の招待中の行 | 保存した同じ人のContactPersonSheetを開き、共有・名前編集を再開。通常のメンバーの編集・削除と区別し、PendingAvatarを使う |
| invitedGroupPreview／acceptContactInvitationButton | 作者とgroup名、登録するとGroupsへも加わる旨。拒否は無保存。Registerは関係とgroupを一度に保存し、通話を切り替えず同じ詳細へ |
| AdvancedContactInvitationContent | invitedGroupIDとsentを他の保存値に併記。秘密の添付やgroup鍵を表示のために読み出さない |
| reloadGroupInvitationStorageButton | 保存失敗時は同じ入力を保ち、既存のReload Saved Groupsから回復。曖昧な保存完了後の再試行も同じIDで重複を防ぐ |

UI Stackと期限・取消・失敗の復帰は[状態遷移](../../../design/招待と登録の設計.md#新しい相手のグループ招待の状態遷移)と[通信契約](../通信仕様.md#個人登録を兼ねるグループ招待)に従う。登録済みの選択相手への自動配送は、下記の状態を同じ保存後の段階に表示する。新しい人への宛先なしリンクで代用しない。

Standardの保存済み人物詳細は、未登録 AND 共有対象の送信招待ありの場合に、登録状態の下へ一覧と同じ招待状態（`contactPersonOutgoingInvitationState`）を追加する。`contactPersonInvitationForSharing`は共有操作と表示に同じ送信記録（`state == pending OR state == expired`）を渡す。`contactInvitationStateWord`は下表に従う。期限と現在時刻はUnix秒で評価する。Advancedの人物詳細は同じ記録の保存値を表示する。

| 項目名（日本語） | 表示時の条件 | 操作と結果 |
|---|---|---|
| 期限切れ | `state == expired OR expiresAt ≤ 現在時刻`。グループ招待は対応する予約枠がある場合 | 「招待を共有」は同じ人と参加先の新しい招待を保存してOS共有を開く。共有を取り消した場合も新しい招待と枠を保持し、「まだ送っていません」を表示する |
| まだ送っていません | 有効 AND `sent == false` | OS共有を取り消すと同じ状態を保つ。共有操作またはコピーの完了を保存し、同じ詳細を「受け取り待ち」にする |
| 受け取り待ち | 有効 AND (`sent == true OR sent == nil`)。`nil`は共有結果を持たない旧記録 | 「招待を共有」は同じ有効な招待を使う。登録状態は署名付き返信で更新する |

期限切れの枠またはグループを外した後も、Usersには保存した人を残す。Standardではその招待の行・参加先・期限切れ表示を外す。Advancedでは履歴が残る間は `state == cancelled` を表示する。Usersの同じ人から新しく共有する場合は個人招待を作る。[予約枠と保存の契約](../通信仕様.md#個人登録を兼ねるグループ招待)に従う。

## 登録済みの相手へのグループ招待の表示

保存後も同じSavedUsersViewを維持し、OS共有を自動では開かない。Done／完了で明示的に閉じる。StandardRegisteredGroupInvitationsは「招待を保存しました。相手ごとの状態を確認できます。必要なら招待を共有してください。」と名前ごとの状態、任意の「招待を共有」を表示する。pending／queuedは「招待中」、同じ相手のどれか1台がreceivedなら「受け取り済み」。同期で追加端末へ届ける場合も、表示は「受け取り済み」を保ち、Advancedでは追加端末の配送を同じ欄で確認できる。全件cancelledは「招待を停止しました」。外した相手を同じグループに招待し直すと「招待中」から始まり、新しい配送の受領で「受け取り済み」になる。Advancedの配送欄にも新しい配送が出て、前回の受領済み記録は消える。principalや確認済み鍵がなく記録を作れない相手は「招待の共有が必要です」。旧形式の相手だけでも同じ保存済み画面で名前ごとに「招待の共有が必要です」と任意の共有を表示する。

AdvancedRegisteredGroupInvitationsはGroupDeliveryRecordのid・recipientMemberID・state・expiresAt・credentialReferenceを表示する。項目名と値が同じ行に収まらないときは値を次の行へ送り、長いIDを折り返す。保存後の`Invite`は配送記録の前に置き、相手の受取を待っている間も共有できる。OS共有を開く・閉じる・コピーする操作で配送状態を進めない。両モードで保存・送受信・判定は同じ処理を使い、文言と配置はモード所有の画面に分ける。新しい相手もいる場合、その人の名前付き詳細と登録済みの相手の配送状態を同じ保存後の画面で続けられる。

iOSの保存直後に背景へ移ると、送信処理はOSが与えた有限の実行時間で進む。時間切れでは保存済みの同じ行と状態を保つ。近距離の署名付き受領またはInternetの受信箱で受取が確定したときに同じ行の状態を更新する。「受け取り済み」は招待の状態を示す。受取側は通信断などで中断した処理を次の同期で続ける。保存済みグループと鍵が食い違う自動招待や、そのグループで外した相手から届いた自動招待は、今のグループ・画面・通話を保って処理を終え、次の招待を受け取る。[グループ自動配送の実行契約](../通信仕様.md#グループ自動配送の実行契約)。

## 非表示のグループタブへの受取案内

StandardUsersViewだけがStandardGroupInvitationOfferを持つ。Standard・グループタブOFF・Users一覧・保存編集可能・通話なし・名前選択なし・人物詳細や設定／削除確認なしの場合に、受取group名と「グループタブを表示しますか？」を標準アラートで一度だけ出す。人物の登録後は同じ詳細に留まり、完了で一覧へ戻るまで確認を出さない。

「表示する」は確認済みを保存し、グループタブの設定をONにしてGroups一覧へ移る。「今はしない」は設定を変えず確認済みだけ保存する。どちらも接続せず、group・鍵・現在の通話を変更しない。既に届いた複数groupは一度の返答で確認済みとし、別groupが新しく届くまで繰り返さない。保存失敗は既存の再読込へ接続し、確認済みとして捨てない。Advancedにはこのアラートを置かない。

グループ一覧を表示した場合も、到着済みの案内を確認済みにする。表示していたタブを明示的にOFFにする操作も既存の案内を消費し、過去に見たgroupを再案内しない。確認済みの保存に失敗した場合は既存の保存復旧へ進み、無条件には消費しない。

## 保存済み招待画面の責務

SavedUsersViewは選択から保存済みへの遷移・対象ID・sheetの終了を所有する。StandardGroupInvitationSavedViewとAdvancedGroupInvitationSavedViewが表示を分け、Doneは親から渡す同じ終了操作を呼ぶ。両方で見出しInvitation（招待）、対象group名（savedInvitationGroupName）、任意共有、明示的な完了を維持する。共有の完了を保存の条件にしない。

Standardは新しい人の名前にRegistered／Not registered（登録済み／未登録）を添え、未登録の人が残るときだけ各人の共有案内を出す。内部IDや鍵・配送方式の説明は出さない。AdvancedはIntercomGroup.id／name、SavedUserのid／isRegisteredを表示し、人を開くと既存の詳細へ進む。登録済みの配送記録はAdvancedRegisteredGroupInvitationsがそのまま表示する。未保存の選択値と保存処理はMemberSelectionで共通に保ち、見た目の都合で状態を複製しない。

## 完了後のグループ設定で確認する招待状態

StandardGroupSettingsViewのMembersは新しい相手の予約枠に「招待中」を添える。登録済み相手の配送記録が残る間は、同じ人の複数端末をまとめた状態を名前の下に出す。StandardGroupInvitationStatusが保存画面と同じ語（招待中／受け取り済み／招待を停止しました）を使う。記録がない旧形式や保持期限後のメンバーに受領済みを推測して付けない。状態の識別子はgroupSettingsInvitationState-{member.id}。既存のタップ・外す・名前変更はそのまま使う。

AdvancedGroupSettingsViewは共有できる場合に`Invite`を配送記録の前に置く。対象groupのoutgoing記録はAdvancedGroupDeliveryRecordsで表示する。id・recipientMemberID・state・expiresAt・credentialReferenceとその識別子は保存画面と同じ。入力中の名前、今の通話、共有操作を状態更新で切り替えない。groupInvitationDeliveries(in:)が対象groupの記録を照会し、groupInvitationDeliveryState(forMember:in:)は保存済み人物のアカウントを解決して既存の端末集約判定を使う。画面用の別の配送状態・通信・timerは持たない。

### 操作直後のロックと相手待ち

Standard・Advancedとも、接続操作から音声入出力の準備を開始する。相手の参加まで画面を開いたまま待つ操作を求めない。相手待ち・復旧可能な切断でも接続意思と終了期限を保ち、入出力を停止して前面復帰を待つ方式にはしない。音声準備だけで相手と接続済みとは表示せず、相手の認証と利用条件が成立するまで送信しない。通常のミュート値は維持する。マイクOFF・受話なしでしばらく待った場合も、画面を開く操作やミュート解除を求めずに後参加の音声を受け取る。通話中に双方が話さない間の経路断から復旧したときも、同じ通話で受話を再開する。OSによる録音開始拒否・音声中断は接続待ちと別に扱い、この契約の実機受入は[背景の受入マトリクス](../../../validation/未確認事項.md#ios背景実行の調査と受入マトリクス)で管理する。

相手待ちの音声一時停止でも`resumeAudioButton`を有効にし、相手を待たずに音声準備を再開し、成功後に停止表示を解除する。準備中も相手と接続済みとは表示せず、認証・利用条件が揃うまで送信しない。Standard・Advancedで操作の意味を揃え、muteと元の終了期限を維持する。
