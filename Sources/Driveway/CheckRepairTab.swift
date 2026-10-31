import AppKit
import DrivewayCore
import SwiftUI

/// Check, back up and repair a drive, with the last report. Repairs ask first; the forced one asks twice over.
struct CheckRepairTab: View {
    let model: DiskManagerModel
    let volume: Volume

    private enum Confirmation: Identifiable {
        case repair, force
        var id: Self { self }
    }

    @State private var confirmation: Confirmation?

    private var isBusy: Bool { model.busy.contains(volume.bsdName) }

    var body: some View {
        Form {
            let actions = VolumeList.repairActions(for: volume.filesystem)
            if actions.isEmpty {
                Section {
                    Text("Driveway can't check or repair \(volume.filesystem.displayName) drives.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if let note = VolumeList.repairNote(for: volume.filesystem) {
                        Label(note, systemImage: "info.circle")
                    }
                    HStack {
                        ForEach(actions, id: \.self) { action in
                            Button(Self.title(action)) { start(action) }
                                .disabled(isBusy)
                        }
                        if isBusy { ProgressView().controlSize(.small) }
                    }
                    if let path = model.backups[volume.bsdName] {
                        Label("Backup saved to \(path)", systemImage: "checkmark.circle")
                            .textSelection(.enabled)
                    }
                }
            }
            if let report = model.reports[volume.bsdName] {
                Section("Last result") { ReportView(report: report) }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Repair \(volume.label)?", isPresented: shown(.repair)
        ) {
            Button("Repair") { Task { await model.repair(volume, force: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(repairMessage)
        }
        .alert(
            "Force repair \(volume.label)?", isPresented: shown(.force)
        ) {
            Button("Force repair", role: .destructive) { Task { await model.repair(volume, force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "A forced repair answers yes to every question the repair tool asks, including removing files and folders it can't fix. Anything it removes is gone for good. Only use it if a normal repair didn't work, and copy what you can off the drive first."
            )
        }
    }

    private var repairMessage: String {
        var text =
            "Driveway will unmount \(volume.label), repair it and mount it again. Programs using files on it will be interrupted. Don't unplug the drive until it finishes."
        if let note = VolumeList.repairNote(for: volume.filesystem) { text += "\n\n" + note }
        return text
    }

    private static func title(_ action: RepairAction) -> String {
        switch action {
        case .check: "Check"
        case .backupFirst: Copy.backUpFirst
        case .repair: "Repair"
        case .repairForce: "Repair (force)…"
        }
    }

    private func start(_ action: RepairAction) {
        switch action {
        case .check: Task { await model.check(volume) }
        case .backupFirst: backUp()
        case .repair: confirmation = .repair
        case .repairForce: confirmation = .force
        }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = VolumeList.backupFileName(label: volume.label, date: Date())
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.backUp(volume, to: url.path) }
    }

    private func shown(_ value: Confirmation) -> Binding<Bool> {
        Binding(
            get: { confirmation == value },
            set: { if !$0, confirmation == value { confirmation = nil } })
    }
}

/// A report's summary in plain words, with the tool's own output behind a disclosure.
private struct ReportView: View {
    let report: CheckReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                report.summary,
                systemImage: report.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
            if !report.rawOutput.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(report.rawOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }
}
