import AppKit
import DrivewayCore
import DrivewayIPC
import SwiftUI

@main
struct DrivewayApp: App {
    @State private var model: DiskManagerModel
    @State private var setup: SetupModel

    init() {
        // One helper connection for the Disk Manager and the Setup scan.
        let client = HelperClient()
        let model = DiskManagerModel(client: client)
        _model = State(initialValue: model)
        _setup = State(initialValue: SetupModel(client: client, diskManager: model))
    }

    var body: some Scene {
        Window("Driveway", id: "disk-manager") {
            DiskManagerView(model: model, setup: setup)
                .onOpenURL { model.open($0) }
        }
        .commands {
            CommandGroup(after: .appSettings) { SetupMenuItems(setup: setup) }
        }
        Window("Setup", id: "setup") {
            SetupView(setup: setup)
        }
        .windowResizability(.contentSize)
        // Notification links open the Disk Manager, never Setup.
        .handlesExternalEvents(matching: [])
        Settings {
            SettingsView(model: model)
        }
    }
}

/// Driveway > Setup… and Driveway > Uninstall Driveway Helper….
struct SetupMenuItems: View {
    let setup: SetupModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Setup…") { openWindow(id: "setup") }
        Button("Uninstall Driveway Helper…") {
            guard confirmUninstall() else { return }
            Task {
                await setup.uninstallHelper()
                // Shows what's locked now, and any error.
                openWindow(id: "setup")
            }
        }
        .disabled(setup.isWorking)
    }

    private func confirmUninstall() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Driveway's helper?"
        alert.informativeText =
            "Driveway will stop mounting NTFS drives read/write and can't check, repair or format drives until you install the helper again from Setup. Your settings are kept."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The Disk Manager window: drives in the sidebar, the selected drive's tabs in the detail.
struct DiskManagerView: View {
    @Bindable var model: DiskManagerModel
    let setup: SetupModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 420)
        .disabled(model.formatting != nil)
        .overlay {
            // Kept here, not in the Format tab: the erase makes the drive leave the list, which removes the tabs.
            if let formatting = model.formatting { FormatProgressView(formatting: formatting) }
        }
        .task {
            model.start()
            await model.refresh()
            // This window exists at launch, so the launch check lives here.
            if await setup.checkAtLaunch() { openWindow(id: "setup") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
            setup.rescanOnActivate()
        }
        .alert("Driveway", isPresented: errorShown) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        if !model.helperReachable {
            ContentUnavailableView {
                Label("Driveway's helper isn't running", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("Driveway needs its helper to list and mount drives.")
            } actions: {
                Button("Open Setup") { openWindow(id: "setup") }
            }
        } else if let volume = model.selectedVolume {
            TabView {
                InfoTab(model: model, volume: volume)
                    .tabItem { Text("Info") }
                CheckRepairTab(model: model, volume: volume)
                    .tabItem { Text("Check & Repair") }
                FormatTab(model: model, volume: volume)
                    .id("\(volume.bsdName)|\(volume.settingsKey)")
                    .tabItem { Text("Format") }
            }
            .padding()
        } else if model.volumes.isEmpty {
            ContentUnavailableView(
                "No external drives", systemImage: "externaldrive",
                description: Text("Connect a drive to see it here."))
        } else {
            ContentUnavailableView("Select a drive", systemImage: "externaldrive")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Covers the window while a format runs, so nothing else can be started and the warning stays in view.
private struct FormatProgressView: View {
    let formatting: FormatInProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 10) {
                ProgressView()
                Text("Formatting \(formatting.label)…").font(.headline)
                Text(formatting.description).foregroundStyle(.secondary)
                Text("Don't unplug the drive until it finishes.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
    }
}
