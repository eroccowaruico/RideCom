import SwiftUI

#if canImport(UIKit)
import UIKit

struct ContactInvitationActivity: UIViewControllerRepresentable {
    let share: PreparedContactInvitationShare?
    let message: String
    let onCompletion: @MainActor (PreparedContactInvitationShare, Bool) -> Void

    final class Coordinator { var isPresenting = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let presenter = UIViewController()
        presenter.view = UIView()
        presenter.view.isUserInteractionEnabled = false
        return presenter
    }

    func updateUIViewController(_ presenter: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let share, !coordinator.isPresenting else { return }
        coordinator.isPresenting = true
        Task { @MainActor [weak presenter] in
            guard let presenter, let anchor = presenter.viewIfLoaded, anchor.window != nil else {
                coordinator.isPresenting = false
                onCompletion(share, false)
                return
            }
            let item = ContactInvitationLinkItem(url: share.url)
            let controller = UIActivityViewController(activityItems: [item, message], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = anchor
            controller.popoverPresentationController?.sourceRect = anchor.bounds
            controller.completionWithItemsHandler = { _, completed, _, error in
                let succeeded = completed && error == nil
                Task { @MainActor in
                    coordinator.isPresenting = false
                    onCompletion(share, succeeded)
                }
            }
            presenter.present(controller, animated: true)
        }
    }
}

private final class ContactInvitationLinkItem: NSObject, UIActivityItemSource {
    let url: URL

    init(url: URL) { self.url = url }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        String(localized: "RideCom Invite")
    }
}
#elseif os(macOS)
import AppKit

struct ContactInvitationActivity: NSViewRepresentable {
    let share: PreparedContactInvitationShare?
    let message: String
    let onCompletion: @MainActor (PreparedContactInvitationShare, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        guard let share, coordinator.completion == nil else { return }
        coordinator.completion = { succeeded in onCompletion(share, succeeded) }
        Task { @MainActor [weak anchor] in
            guard let anchor, anchor.window != nil else {
                coordinator.finish(false)
                return
            }
            let picker = NSSharingServicePicker(items: [share.url as NSURL, message as NSString])
            coordinator.picker = picker
            picker.delegate = coordinator
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.picker?.close()
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var picker: NSSharingServicePicker?
        var completion: (@MainActor (Bool) -> Void)?

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                                  proposedSharingServices services: [NSSharingService]) -> [NSSharingService] {
            guard let url = items.compactMap({ $0 as? URL }).first,
                  let icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil) else { return services }
            let copy = NSSharingService(
                title: String(localized: "Copy Invitation Link"), image: icon, alternateImage: nil
            ) { [weak self] in
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                finish(pasteboard.setString(url.absoluteString, forType: .string))
            }
            return [copy] + services
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                  didChoose service: NSSharingService?) {
            if service == nil { finish(false) }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                  delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
            sharingService.subject = String(localized: "RideCom Invite")
            return self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(true) }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finish(false)
        }

        func finish(_ succeeded: Bool) {
            let handler = completion
            completion = nil
            picker = nil
            handler?(succeeded)
        }
    }
}
#endif
