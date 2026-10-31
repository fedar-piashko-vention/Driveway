import AppKit
import DrivewayCore
import DrivewayIPC
import SwiftUI

@main
struct DrivewayApp: App {
    @State private var model = DiskManagerModel()

    var body: some Scene {
        Window("Driveway", id: "disk-manager") {
            DiskManagerView(model: model)
                .onOpenURL { model.open($0) }
        }
        Window("Setup", id: "setup") {
            SetupPlaceholderView()
        }
        // Notification links open the Disk Manager, never Setup.
        .handlesExternalEvents(matching: [])
        Settings {
            SettingsView(model: model)
        }
    }
}

/// The Disk Manager window: drives in the sidebar, the selected drive's tabs in the detail.
struct DiskManagerView: View {
    @Bindable var model: DiskManagerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            model.start()
            await model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
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
                    .id(volume.bsdName)
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

/// Stands in for the Setup screen until it is built.
struct SetupPlaceholderView: View {
    var body: some View {
        Text("Setup is coming in a later build.")
            .padding(40)
    }
}
