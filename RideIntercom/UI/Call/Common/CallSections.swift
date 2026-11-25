import AuthenticationServices
import CallControl
import SwiftUI

struct CurrentCallSection: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    var excludesSelected = false
    var body: some View {
        if let id = viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection,
           !excludesSelected || viewModel.selectedGroup?.id != id,
           let group = viewModel.groups.first(where: { $0.id == id }) {
            Section("Current Call") {
                Button {
                    viewModel.selectGroup(group, connectIfIdle: false)
                    selectedTab = .call
                } label: { Label(viewModel.callTitle(for: group), systemImage: "phone.fill") }
                .directoryRowButtonStyle()
                .accessibilityIdentifier("standardCurrentCallButton")
            }
        }
    }
}

struct CallErrorSection: View {
    let viewModel: IntercomViewModel
    var offersDirectInvitationRecovery = false
    var body: some View {
        if let message = viewModel.groupErrorMessage, message != viewModel.groupStorageNotice {
            Section {
                Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle")
                    .accessibilityIdentifier("groupErrorLabel")
                if offersDirectInvitationRecovery, let group = viewModel.crossedDirectCallToShare {
                    CallInvitationButton(invitation: InvitationShare(viewModel: viewModel, groupID: group.id),
                                         previewTitle: viewModel.callTitle(for: group), title: "Share Invitation",
                                         accessibilityIdentifier: "shareCrossedDirectInvitationButton")
                }
            }
        }
    }
}

struct CallStorageSection: View {
    let viewModel: IntercomViewModel
    var body: some View {
        if let message = viewModel.groupStorageNotice {
            GroupStorageSection(message: message, canReset: viewModel.groupStorageIssue == .corrupted,
                canReload: viewModel.activeGroupID == nil && viewModel.groupStorageIssue != .unsupportedVersion,
                reloadRequiresDisconnect: viewModel.activeGroupID != nil,
                reload: viewModel.reloadSavedGroups, reset: viewModel.resetSavedGroups)
        }
    }
}

struct CallAppleEnrollmentButton: View {
    let viewModel: IntercomViewModel
    var inList = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmation: AppleEnrollmentConfirmation?

    var body: some View {
        if let call = viewModel.callForAppleEnrollmentConfirmation,
           viewModel.networkPathIsAvailable == true || confirmation != nil {
            if inList {
                Section { action(for: call) }
            } else {
                action(for: call)
            }
        }
    }

    private func action(for call: CallReference) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Verify your Apple account to use Internet calling.")
                .font(.footnote)
            SignInWithAppleButton(.continue, onRequest: { request in
                confirmation = viewModel.prepareCallEnrollmentConfirmation(request, for: call)
            }, onCompletion: { result in
                defer { confirmation = nil }
                guard let confirmation else { return }
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                        viewModel.reportCallEnrollmentConfirmationFailure(for: call)
                        return
                    }
                    viewModel.completeCallEnrollmentConfirmation(
                        confirmation, for: call, userID: credential.user,
                        state: credential.state, identityToken: credential.identityToken)
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        viewModel.reportCallEnrollmentConfirmationFailure(for: call)
                    }
                }
            })
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: 360).frame(height: 50)
            .disabled(confirmation != nil || viewModel.networkPathIsAvailable != true)
            .accessibilityIdentifier("callAppleEnrollmentButton")
        }
    }
}

struct DirectoryGroupLabel: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup

    var body: some View {
        DirectoryRowLabel(title: group.name, isGroup: true,
                          detail: String(localized: "\(group.members.count) people"),
            status: viewModel.isInCall(with: .group(group.id)) ? viewModel.callStatus(for: group.id) : nil)
    }
}
