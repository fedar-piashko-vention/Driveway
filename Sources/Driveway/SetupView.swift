import AppKit
import DrivewayCore
import SwiftUI

/// The Setup window (mockup B): one group per feature with what it still needs and an Unlock button, conflict
/// warnings, and a footer with the ready count and Unlock everything.
struct SetupView: View {
    @Bindable var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What this Mac can do").font(.title2.bold())
                Text("Install what's missing to unlock each feature.").foregroundStyle(.secondary)
            }
            if setup.hasScanned {
                ForEach(setup.conflicts, id: \.self) { ConflictRow(driver: $0) }
                ForEach(setup.groups) { FeatureGroupRow(group: $0, setup: setup) }
            } else {
                ProgressView("Checking this Mac…").frame(maxWidth: .infinity, minHeight: 200)
            }
            if let notice = setup.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(Copy.featuresReady(setup.readyCount))
                Spacer()
                if setup.isWorking { ProgressView().controlSize(.small) }
                Button(Copy.unlockEverything) { Task { await setup.unlockEverything() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!setup.canUnlockEverything)
            }
        }
        .padding(20)
        .frame(width: 540)
        .sheet(isPresented: $setup.logShown) { InstallLogView(setup: setup) }
        .alert("Driveway", isPresented: errorShown) {
            Button("OK") { setup.errorMessage = nil }
        } message: {
            Text(setup.errorMessage ?? "")
        }
        .task { await setup.scan() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.rescanOnActivate()
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { setup.errorMessage != nil }, set: { if !$0 { setup.errorMessage = nil } })
    }
}

private struct FeatureGroupRow: View {
    let group: SetupGroup
    let setup: SetupModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(group.state == .ready ? "✅" : "🔒")
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.headline)
                if let detail = group.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(group.items, id: \.label) { item in
                    Text("\(item.symbol) \(item.label)").font(.caption)
                }
            }
            Spacer(minLength: 12)
            switch group.state {
            case .ready:
                Text("Ready").font(.caption.bold()).foregroundStyle(.green)
            case .notAvailableYet:
                EmptyView()
            case .locked:
                Button(setup.buttonTitle(for: group.feature)) { Task { await setup.unlock(group.feature) } }
                    .disabled(setup.isWorking)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// Another NTFS/ext driver is installed. Driveway never removes it; it says how to.
private struct ConflictRow: View {
    let driver: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⚠️")
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.conflictWarning(driver: driver))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = ConflictingDrivers.supportURL(for: driver) {
                    Link("\(driver) support and uninstall instructions", destination: url).font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Live brew output. Continue answers brew's question with yes; Cancel stops brew.
private struct InstallLogView: View {
    let setup: SetupModel

    private var running: Bool { setup.installer.isBrewRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installing tools").font(.headline)
            Text(Copy.untrustedTapNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(setup.log.enumerated()), id: \.offset) { Text($0.element) }
                        if !setup.installer.pendingLine.isEmpty { Text(setup.installer.pendingLine) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: setup.log.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: setup.installer.pendingLine) { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                Spacer()
                if running {
                    Button("Cancel", role: .cancel) { setup.cancelBrew() }
                    // Only while brew waits on an unfinished line, i.e. a question.
                    Button("Continue") { setup.answerYes() }
                        .disabled(setup.installer.pendingLine.isEmpty)
                } else {
                    Button("Done") { setup.logShown = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
        .interactiveDismissDisabled(setup.isWorking)
    }
}
