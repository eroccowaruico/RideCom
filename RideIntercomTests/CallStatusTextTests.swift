import Foundation
import Testing
@testable import RideIntercom

/// The state reads on one short line; any reason goes on the next line, never after a dash.
struct CallStatusTextTests {
    @Test(arguments: [StandardCallStatus.ready, .connecting, .inCall, .audioPaused, .audioUnavailable])
    func titleIsTheStateAloneAndDetailIsTheReason(status: StandardCallStatus) {
        #expect(!status.title.contains("—"))
        #expect(status.detail.map { !$0.contains("—") } ?? true)
        #expect((status.detail == nil) == [.ready, .inCall].contains(status))
    }

    @Test func japaneseUsesTheDesignTerms() throws {
        let bundle = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        let japanese = { (key: String) in bundle.localizedString(forKey: key, value: nil, table: nil) }
        #expect(japanese(StandardCallStatus.inCall.title) == "会話中")
        #expect(japanese(StandardCallStatus.ready.title) == "未接続")
        #expect(japanese(StandardCallStatus.connecting.detail ?? "") == "相手の参加を待っています")
        #expect(japanese("End Call") == "切断")
        #expect(japanese("Recent Call") == "前回の接続先")
        // The glossary: say which voice isolation works on, invite (never add), and the words below.
        #expect(japanese("Isolate the Other Person’s Voice") == "相手の声を分離")
        #expect(japanese("Isolate Incoming Voices") == "受信する声を分離")
        #expect(japanese("Transmit Voice Isolation Effect") == "送信する声を分離")
        #expect(japanese("Unmuted") == "オフ")
        #expect(japanese("Cancel Call Request") == "呼び出しを取り消す")
        #expect(japanese("Share Call Invite") == "招待を共有")
        #expect(japanese("Name shared by this person") == "本人の名前")
        #expect(japanese("Switch to This Call") == "接続を切り替える")
        #expect(japanese("Contact Invitation") == "招待")
        #expect(japanese("No Groups Yet") == "まだグループがありません")
        #expect(japanese("Invite Someone") == "新しい相手を招待")
        // No English left in Standard: the app's own audio choices and the audio check's reasons read in Japanese.
        #expect(japanese("Auto") == "自動")
        #expect(japanese("Receiver") == "受話口")
        for reason in [
            "Audio recording processing failed", "Incomplete microphone recording", "Preparing Watch audio check",
                       "Waiting for Watch playback", "Watch audio check failed", "Watch playback did not start"] {
            #expect(japanese(reason) != reason, "\(reason) has no Japanese")
        }
        #expect(japanese("Set up Internet calling to use notifications.") == "通知を利用するにはインターネット通話を設定してください。")
        #expect(japanese("Create and Connect") == "作成して接続")
    }
}
