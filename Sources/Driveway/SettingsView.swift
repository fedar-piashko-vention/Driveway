import DrivewayCore
import SwiftUI

/// The Settings scene (Driveway > Settings…).
struct SettingsView: View {
    let model: DiskManagerModel

    var body: some View {
        Form {
            Toggle(Copy.autoMountNTFS, isOn: autoMount)
                .disabled(!model.settingsLoaded)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .task { await model.refresh() }
        .alert("Driveway", isPresented: errorShown) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var autoMount: Binding<Bool> {
        Binding(
            get: { model.settings.autoMountNTFS },
            set: { on in Task { await model.setAutoMountNTFS(on) } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
