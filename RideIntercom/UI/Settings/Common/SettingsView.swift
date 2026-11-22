import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var isEditingInternet = false

    var body: some View {
        Form {
            if viewModel.interfaceMode == .standard {
                StandardSettingsView(viewModel: viewModel, isEditingInternet: $isEditingInternet,
                                     showsWatchSettings: showsWatchSettings)
            } else {
                AdvancedSettingsView(viewModel: viewModel, isEditingInternet: $isEditingInternet,
                                     showsWatchSettings: showsWatchSettings)
            }
        }
        .formStyle(.grouped)
        .screenBackground(AppColorPalette.listScreenBackground)
        .readableScrollWidth()
        .accessibilityIdentifier("settingsScrollView")
        .sheet(isPresented: $isEditingInternet) {
            NavigationStack {
                Form {
                    InternetAppleSignInSection(viewModel: viewModel)
                }
                .formStyle(.grouped)
                .screenBackground(AppColorPalette.listScreenBackground)
                .navigationTitle("Internet Connection")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { isEditingInternet = false }
                            .accessibilityIdentifier("closeInternetConnection")
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 320)
            #endif
        }
    }

    private var showsWatchSettings: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}
