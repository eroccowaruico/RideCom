import Foundation
import RTC
import Testing

@testable import RideIntercom

@MainActor
struct ContactBootstrapTests {
  // Ordinary group invitation acceptance remains a separate contract.
  @Test func unknownContactAcceptanceRegistersAuthorAndAuthenticatedDeliveryRegistersRecipient() throws {
    let author = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-author")
    let friend = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-friend")
    let authorViewModel = author.viewModel, friendViewModel = friend.viewModel
    let authorNotification = RecordingCallSession(), friendNotification = RecordingCallSession()
    authorViewModel.contactSessionFactory = { authorNotification }
    friendViewModel.contactSessionFactory = { friendNotification }
    defer { authorViewModel.disconnect(); friendViewModel.disconnect() }
    let url = try #require(authorViewModel.makeContactInviteURL())
    #expect(authorViewModel.savedRemoteUsers.isEmpty)
    #expect(authorViewModel.groups.isEmpty)
    try friendViewModel.acceptContactInviteURL(url)
    #expect(authorViewModel.savedRemoteUsers.isEmpty)
    #expect(friendViewModel.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]])
    #expect(authorViewModel.groups.isEmpty)
    #expect(friendViewModel.regularGroups.isEmpty)
    #expect(friendNotification.sentApplicationDataMessages.isEmpty)

    friendNotification.authenticate(["contact-author"])
    let receipt = try #require(friendNotification.sentApplicationDataMessages.last {
      $0.namespace == DirectInvitationReceipt.namespace
    })
    #expect(friendViewModel.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]],
            "Explicit acceptance already saved the signed author")
    // A receipt from an unbound / unauthenticated sender cannot save anyone.
    authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: receipt))
    #expect(authorViewModel.savedRemoteUsers.isEmpty)
    authorNotification.authenticate(["contact-friend"])
    authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: receipt))
    #expect(authorViewModel.savedRemoteUsers.map(\.memberIDs) == [["contact-friend"]])
    let spentID = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
      .context.id
    #expect(throws: (any Error).self) {
      _ = try authorViewModel.prepareContactInvitationShare(
        spentID, expectedAccountAccessID: authorViewModel.accountAccessID)
    }
    #expect(friendViewModel.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]])
    let acknowledgement = try #require(authorNotification.sentApplicationDataMessages.last {
      $0.namespace == DirectInvitationReceipt.namespace
    })
    friendNotification.onEvent?(.receivedApplicationData(peerID: "contact-author", message: acknowledgement))
    #expect(friendViewModel.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]])
    #expect(authorViewModel.regularGroups.isEmpty, "Contact bootstrap is never an ordinary group")
    #expect(friendViewModel.regularGroups.isEmpty)
    let call = IntercomGroup.directCallID(memberIDs: ["contact-author", "contact-friend"])
    #expect(authorViewModel.groups.map(\.id) == [call] && friendViewModel.groups.map(\.id) == [call])
    let key = try #require(try authorViewModel.groupRepository.credential(for: call))
    #expect(try friendViewModel.groupRepository.credential(for: call) == key,
            "Both sides finish the invitation with one pair call key")
    #expect(author.callSession.startMediaCallCount == 0)
    #expect(friend.callSession.startMediaCallCount == 0)
  }

  @Test(arguments: [true, false])
  func savedContactsCanStartInternetOnlyAfterNearbyRegistration(hasInternetCredential: Bool) async throws {
    let authorID = "contact-author", friendID = "contact-friend"
    let author = AppTestSupport.makeHarness(groups: [], hasInternetCallCredential: hasInternetCredential,
                                            localMemberID: authorID, enforceCallAccess: false)
    let friend = AppTestSupport.makeHarness(groups: [], hasInternetCallCredential: hasInternetCredential,
                                            localMemberID: friendID, enforceCallAccess: false)
    defer { author.viewModel.disconnect(); friend.viewModel.disconnect() }
    let authorReply = RecordingCallSession(), friendReply = RecordingCallSession()
    author.viewModel.contactSessionFactory = { authorReply }
    friend.viewModel.contactSessionFactory = { friendReply }

    try friend.viewModel.acceptContactInviteURL(try #require(author.viewModel.makeContactInviteURL()))
    try deliverNearbyReply(friendTransport: friendReply, authorTransport: authorReply,
                           authorID: authorID, friendID: friendID)
    let callID = IntercomGroup.directCallID(memberIDs: [authorID, friendID])
    let callKey = try #require(try author.viewModel.groupRepository.credential(for: callID))
    try #require(try friend.viewModel.groupRepository.credential(for: callID) == callKey)

    for (endpoint, remoteID) in [(author, friendID), (friend, authorID)] {
      let model = endpoint.viewModel
      try #require(model.enabledRTCTransportRoutes == [.multipeer, .webRTC])
      model.setRTCTransportRoute(.multipeer, enabled: false)
      model.reloadSavedGroups()
      let savedContact = try #require(model.savedRemoteUsers.first { $0.memberIDs == [remoteID] })
      #expect(model.openDestination(.user(savedContact.id)) == .opened)
      #expect(model.selectedGroup?.id == callID)
      #expect(endpoint.callSession.enabledRouteValues.last == [.webRTC])
      if hasInternetCredential {
        try #require(model.activeGroupID == callID)
        #expect(endpoint.callSession.connectedGroup?.accessSecret == callKey.secret)
        #expect(model.groupErrorMessage == nil)
        #expect(endpoint.callSession.startMediaCallCount == 0)
        endpoint.callSession.authenticate([remoteID], route: .webRTC)
        await AppTestSupport.waitUntil { model.isCallMediaStarted }
        #expect(model.authenticatedPeerIDs == [remoteID])
        #expect(model.connectionState == .internetConnected && model.isCallMediaStarted)
      } else {
        #expect(model.activeGroupID == nil && endpoint.callSession.connectedGroup == nil)
        let setup = String(localized: "Could not prepare Internet calling for this device.")
        #expect(model.groupErrorMessage == setup)
      }
    }
  }

  @Test func provisionalNamesPairAColorWithACreatureAndAvoidNamesInUse() {
    var generator = SystemRandomNumberGenerator()
    #expect(ProvisionalName.all(japanese: true).count == 112)
    #expect(ProvisionalName.all(japanese: true).contains("青いキツネ"))
    #expect(ProvisionalName.all(japanese: false).contains("Blue Fox"))
    let used = Set(ProvisionalName.all(japanese: false).filter { $0 != "White Gull" })
    #expect(ProvisionalName.candidate(japanese: false, avoiding: used, using: &generator) == "White Gull")
    let everything = Set(ProvisionalName.all(japanese: false))
    #expect(ProvisionalName.candidate(japanese: false, avoiding: everything, using: &generator) == "Blue Fox 2")
  }

  @Test(arguments: [false, true], [false, true])
  func anExplicitReplyAttemptContinuesAfterLeavingTheApp(retrying: Bool, expires: Bool) throws {
    let author = AppTestSupport.makeHarness(groups: [], localMemberID: "background-reply-author")
    let friend = AppTestSupport.makeHarness(groups: [], localMemberID: "background-reply-friend")
    let authorViewModel = author.viewModel, friendViewModel = friend.viewModel
    let authorTransport = RecordingCallSession()
    var friendTransports: [RecordingCallSession] = []
    authorViewModel.contactSessionFactory = { authorTransport }
    friendViewModel.contactSessionFactory = {
      let transport = RecordingCallSession()
      friendTransports.append(transport)
      return transport
    }
    defer { authorViewModel.disconnect(); friendViewModel.disconnect() }
    var starts = 0, finishes = 0
    var expire: (@MainActor () -> Void)?
    friendViewModel.beginContactInvitationBackgroundTime = { onExpiration in
      starts += 1; expire = onExpiration
      return { finishes += 1 }
    }
    let url = try #require(authorViewModel.makeContactInviteURL())
    #expect(friendViewModel.previewContactInvitation(url)); #expect(starts == 0)
    #expect(friendViewModel.acceptPresentedContactInvitation(keepingPresentation: true))
    #expect(starts == 1, "Register requests time before the user can leave")
    let id = try #require(friendViewModel.contactInvitationID)
    let saved = try #require(friendViewModel.contactInvitationRecord(id))
    if retrying {
      friendViewModel.stopContactInvitationSession()
      let person = try #require(friendViewModel.savedRemoteUsers.first).id
      try #require(friendViewModel.retryContactPersonInvitation(id, personID: person))
      #expect(starts == 2, "Send Again also requests time before the user can leave")
      try #require(friendViewModel.retryContactPersonInvitation(id, personID: person))
      #expect(starts == 2 && friendTransports.count == 2, "The same running attempt keeps its existing time allowance")
    }
    let activeAttempt = retrying ? 2 : 1
    friendViewModel.dismissContactInvitationPresentation(); friendViewModel.suspendContactInvitationForBackground()
    #expect(friendViewModel.contactInvitationID == id && friendTransports.count == activeAttempt)
    #expect(finishes == activeAttempt - 1)
    if expires {
      expire?()
      #expect(friendViewModel.contactInvitationID == nil && finishes == activeAttempt)
      #expect(friendViewModel.contactInvitationRecord(id) == saved && friendViewModel.savedRemoteUsers.count == 1)
      friendViewModel.resumeSuspendedContactInvitation()
      #expect(friendViewModel.contactInvitationID == id && friendTransports.count == activeAttempt + 1
        && starts == activeAttempt)
    }
    try deliverNearbyReply(friendTransport: friendTransports.last, authorTransport: authorTransport,
                           authorID: "background-reply-author", friendID: "background-reply-friend")
    #expect(authorViewModel.savedRemoteUsers.map(\.memberIDs) == [["background-reply-friend"]])
    #expect(friendViewModel.savedRemoteUsers.map(\.memberIDs) == [["background-reply-author"]])
    #expect(friendViewModel.contactInvitationRecord(id)?.state == .delivered && finishes == activeAttempt)
    #expect(author.callSession.startMediaCallCount == 0 && friend.callSession.startMediaCallCount == 0)
  }

  @Test func theNameGivenBeforeSendingBecomesTheSavedUsersLocalName() throws {
    let author = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-author")
    let friend = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-friend")
    let authorViewModel = author.viewModel, friendViewModel = friend.viewModel
    let authorNotification = RecordingCallSession(), friendNotification = RecordingCallSession()
    authorViewModel.contactSessionFactory = { authorNotification }
    friendViewModel.contactSessionFactory = { friendNotification }
    defer { authorViewModel.disconnect(); friendViewModel.disconnect() }
    let url = try #require(authorViewModel.makeContactInviteURL())
    let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
    #expect(authorViewModel.setContactInvitationNickname(id, "  Riding Buddy  "))
    #expect(authorViewModel.contactInvitationRecord(id)?.nickname == "Riding Buddy")

    try friendViewModel.acceptContactInviteURL(url)
    friendNotification.authenticate(["contact-author"])
    let receipt = try #require(friendNotification.sentApplicationDataMessages.last {
      $0.namespace == DirectInvitationReceipt.namespace
    })
    authorNotification.authenticate(["contact-friend"])
    authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: receipt))
    let user = try #require(authorViewModel.savedRemoteUsers.first)
    #expect(user.localName == "Riding Buddy", "The inviter's own word for the person names them on this device")
    #expect(user.displayName != "Riding Buddy", "The person's shared name is kept separately")
  }

  @Test(arguments: [false, true])
  func reInvitingAnExistingContactReplacesThePairCallKeyOnBothDevices(missingKey: Bool) throws {
    let callID = IntercomGroup.directCallID(memberIDs: ["contact-author", "contact-friend"])
    let author = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-author")
    let friendKeys = InMemoryGroupCredentialStore()
    let friend = AppTestSupport.makeHarness(groups: [], credentialStore: friendKeys, localMemberID: "contact-friend")
    let authorViewModel = author.viewModel, friendViewModel = friend.viewModel
    let authorNotification = RecordingCallSession(), friendNotification = RecordingCallSession()
    authorViewModel.contactSessionFactory = { authorNotification }
    friendViewModel.contactSessionFactory = { friendNotification }
    defer { authorViewModel.disconnect(); friendViewModel.disconnect() }
    let firstURL = try #require(authorViewModel.makeContactInviteURL())
    try friendViewModel.acceptContactInviteURL(firstURL)
    friendNotification.authenticate(["contact-author"])
    let firstReceipt = try #require(friendNotification.sentApplicationDataMessages.last)
    authorNotification.authenticate(["contact-friend"])
    authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: firstReceipt))
    let firstAcknowledgement = try #require(authorNotification.sentApplicationDataMessages.last)
    friendNotification.onEvent?(.receivedApplicationData(peerID: "contact-author", message: firstAcknowledgement))

    let oldKey = try #require(try authorViewModel.groupRepository.credential(for: callID))
    #expect(try friendViewModel.groupRepository.credential(for: callID) == oldKey)
    let contact = try #require(friendViewModel.savedRemoteUsers.first)
    if missingKey {
      try verifyNoticeAfterLosingCallKey(friend, keys: friendKeys, callID: callID, contactID: contact.id)
    }

    #expect(authorViewModel.setLocalDisplayName("Updated Author"))
    let secondURL = try #require(authorViewModel.makeContactInviteURL())
    #expect(secondURL != firstURL)
    #expect(
      try GroupInviteTokenCodec.decodeJoinURL(secondURL, contactBootstrap: true).inviterDisplayName == "Updated Author")
    try friendViewModel.acceptContactInviteURL(secondURL)
    friendNotification.authenticate(["contact-author"])
    let secondReceipt = try #require(friendNotification.sentApplicationDataMessages.last)
    authorNotification.authenticate(["contact-friend"])
    authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: secondReceipt))
    let secondAcknowledgement = try #require(authorNotification.sentApplicationDataMessages.last)
    friendNotification.onEvent?(.receivedApplicationData(peerID: "contact-author", message: secondAcknowledgement))

    #expect(friendViewModel.savedRemoteUsers.first?.displayName == "Updated Author")
    let newKey = try #require(try authorViewModel.groupRepository.credential(for: callID))
    #expect(newKey != oldKey)
    #expect(try friendViewModel.groupRepository.credential(for: callID) == newKey)
    #expect(authorViewModel.groups.map(\.id) == [callID] && friendViewModel.groups.map(\.id) == [callID])
    #expect(authorViewModel.groups.first?.kind == .direct && friendViewModel.groups.first?.kind == .direct)
    if missingKey {
      #expect(friendViewModel.startCall(to: .user(contact.id), accountAccessID: friendViewModel.accountAccessID))
      #expect(friend.callSession.connectedGroup?.id == callID)
      #expect(friendViewModel.groupErrorMessage == nil)
    }
  }

  private func deliverNearbyReply(
    friendTransport: RecordingCallSession?, authorTransport: RecordingCallSession, authorID: String, friendID: String
  ) throws {
    let friendTransport = try #require(friendTransport)
    friendTransport.authenticate([authorID])
    let receipt = try #require(
      friendTransport.sentApplicationDataMessages.last {
        $0.namespace == DirectInvitationReceipt.namespace
      })
    authorTransport.authenticate([friendID])
    authorTransport.onEvent?(.receivedApplicationData(peerID: friendID, message: receipt))
    let acknowledgement = try #require(
      authorTransport.sentApplicationDataMessages.last {
        $0.namespace == DirectInvitationReceipt.namespace
      })
    friendTransport.onEvent?(.receivedApplicationData(peerID: authorID, message: acknowledgement))
  }

}

private extension ContactBootstrapTests {
  func verifyNoticeAfterLosingCallKey(
    _ friend: AppTestSupport.Harness, keys: InMemoryGroupCredentialStore, callID: UUID, contactID: UUID
  ) throws {
    let model = friend.viewModel
    let name = "Ski Friend"
    #expect(model.renameSavedUser(contactID, displayName: name))
    let reference = try #require(friend.groupStore.snapshot.groups.first { $0.id == callID }?.credentialReference)
    try keys.delete(reference: reference)
    model.reloadSavedGroups()
    #expect(model.openDestination(.user(contactID)) == .opened)
    #expect(model.groupErrorMessage == String(localized: "Ask \(name) to send you a new invitation."))
    #expect(friend.callSession.connectedGroup == nil)
  }
}
