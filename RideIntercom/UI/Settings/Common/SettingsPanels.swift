import SwiftUI
import RTC
import Codec

/// Settings sections that are the same in Standard and Advanced. The only difference a mode asks for is
/// the default's mark: Advanced marks the implementation's default so a changed value can be put back;
/// Standard has no expert choices, so it never shows the mark.
func settingsOption(_ title: String, isDefault: Bool, marks: Bool = true) -> Text {
    marks && isDefault ? Text(verbatim: "\(title) (Default)") : Text(verbatim: title)
}

struct CallDisconnectTimerSection: View {
    let viewModel: IntercomViewModel
    /// Advanced marks the implementation's default; the mode's screen says which it is.
    var marksDefault = false
    var disabledWatchInterval: CallDisconnectInterval? = nil

    var body: some View {
        Section {
            Picker("Regular Calls", selection: Binding(get: { viewModel.callDisconnectInterval },
                                                       set: { viewModel.setCallDisconnectInterval($0) })) {
                ForEach(CallDisconnectInterval.allCases) { interval in
                    settingsOption(interval.title, isDefault: interval == .regularDefault, marks: marksDefault).tag(interval)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("callDisconnectIntervalPicker")
            if let disabledWatchInterval {
                WatchDisconnectTimerPicker(selection: .constant(disabledWatchInterval))
                    .disabled(true)
            }
        } header: {
            Text("Automatic Disconnection")
        } footer: {
            Text("Applies when starting a new call. Waiting and reconnecting count toward this time. You can start another call after the timer ends it.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callDisconnectTimerSection")
    }
}

struct WatchDisconnectTimerPicker: View {
    @Binding var selection: CallDisconnectInterval

    var body: some View {
        Picker("Calls Started from Watch", selection: $selection) {
            ForEach(CallDisconnectInterval.allCases) { interval in
                settingsOption(interval.title, isDefault: interval == .watchDefault).tag(interval)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("watchCallDisconnectIntervalPicker")
    }
}

struct CommunicationPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Toggle(
                "Local Network",
                isOn: Binding(
                    get: { viewModel.isRTCTransportRouteEnabled(.multipeer) },
                    set: { viewModel.setRTCTransportRoute(.multipeer, enabled: $0) }
                )
            )
            .disabled(!viewModel.canToggleRTCTransportRoute(.multipeer))
            .accessibilityIdentifier("localNetworkRouteToggle")

            Toggle(
                "Internet",
                isOn: Binding(
                    get: { viewModel.isRTCTransportRouteEnabled(.webRTC) },
                    set: { viewModel.setRTCTransportRoute(.webRTC, enabled: $0) }
                )
            )
            .disabled(!viewModel.canToggleRTCTransportRoute(.webRTC))
            .accessibilityIdentifier("internetRouteToggle")
        } header: {
            Text("Communication")
                .accessibilityIdentifier("communicationPanel")
        } footer: {
            Text("Internet controls this device’s service connection. Nearby riders can relay calls for riders with Internet off. Relay uses battery and data. Changing these settings ends the current connection; connect again to apply them.")
                .font(.footnote)
        }
    }
}

struct AudioIOPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            if viewModel.availableOutputPorts.count > 1 {
                AudioPortPicker(
                    title: "Output",
                    selection: Binding(
                        get: { viewModel.selectedOutputPort },
                        set: { viewModel.setOutputPort($0) }
                    ),
                    ports: viewModel.availableOutputPorts,
                    accessibilityIdentifier: "audioCheckOutputPicker"
                )
                .disabled(viewModel.audioCheckPhase.isInProgress)
            }

            if viewModel.availableInputPorts.count > 1 {
                AudioPortPicker(
                    title: "Input",
                    selection: Binding(
                        get: { viewModel.selectedInputPort },
                        set: { viewModel.setInputPort($0) }
                    ),
                    ports: viewModel.availableInputPorts,
                    accessibilityIdentifier: "audioCheckInputPicker"
                )
                .disabled(viewModel.audioCheckPhase.isInProgress)
            }

            if viewModel.supportsSoundIsolation {
                Toggle(
                    "Transmit Voice Isolation Effect",
                    isOn: Binding(
                        get: { viewModel.isSoundIsolationEnabled },
                        set: { viewModel.setSoundIsolationEnabled($0) }
                    )
                )
                .accessibilityIdentifier("soundIsolationToggle")
            }
        } header: {
            Text("Audio I/O")
        }
        .accessibilityIdentifier("audioIOPanel")
    }
}

struct VoiceActivityPanel: View {
    @Bindable var viewModel: IntercomViewModel
    /// Advanced marks the implementation's default; the mode's screen says which it is.
    var marksDefault = false

    var body: some View {
        Section {
            Picker("VAD Sensitivity", selection: Binding(
                get: { viewModel.vadSensitivity },
                set: { viewModel.setVADSensitivity($0) }
            )) {
                ForEach(VoiceActivitySensitivity.allCases) { sensitivity in
                    // Standard reads the word in the person's language; Advanced adds the default's mark.
                    Group {
                        if marksDefault, sensitivity == IntercomViewModel.defaultVADSensitivity {
                            settingsOption(sensitivity.label, isDefault: true)
                        } else {
                            Text(LocalizedStringKey(sensitivity.label))
                        }
                    }
                    .tag(sensitivity)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("vadSensitivityPicker")

        } header: {
            Text("Voice Activity")
                .accessibilityIdentifier("voiceActivityPanel")
        }
    }
}

struct ResetSettingsPanel: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var isConfirmingReset = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Text("Reset All Settings")
            }
            .accessibilityIdentifier("resetAllSettingsButton")
        } footer: {
            Text("Resets audio and call settings to their default values. Saved groups and members are not changed.")
                .accessibilityIdentifier("resetSettingsPanel")
        }
        .alert("Reset All Settings?", isPresented: $isConfirmingReset) {
            Button("Reset All Settings", role: .destructive) {
                viewModel.resetAllSettings()
            }
            .accessibilityIdentifier("confirmResetAllSettingsButton")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("cancelResetAllSettingsButton")
        } message: {
            Text("Resets audio and call settings to their default values. Saved groups and members are not changed.")
        }
    }
}
