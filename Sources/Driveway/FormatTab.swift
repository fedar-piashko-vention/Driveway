import DrivewayCore
import SwiftUI

/// Erase and format a drive, or its whole disk. Erase… opens a sheet that shows what will be lost and asks for the
/// drive's name before anything is sent.
struct FormatTab: View {
    let model: DiskManagerModel
    let volume: Volume

    @State private var chosen: FilesystemKind = .exfat
    @State private var label = ""
    @State private var labelEdited = false
    @State private var scheme: PartitionScheme = .gpt
    @State private var wholeDisk: Bool
    @State private var pending: PendingErase?

    init(model: DiskManagerModel, volume: Volume) {
        self.model = model
        self.volume = volume
        _wholeDisk = State(initialValue: FormatForm.defaultsToWholeDisk(volume, in: model.volumes))
    }

    private var ready: Set<Feature> { model.readyFeatures }
    /// The choice, unless it has become unavailable since it was picked.
    private var filesystem: FilesystemKind { FormatForm.effective(chosen, ready: ready) }
    /// The toggle's meaning for this drive; whole media without a partition table can only be erased whole.
    private var erasesWholeDisk: Bool { FormatForm.erasesWholeDisk(volume, toggle: wholeDisk) }
    private var target: FormatTarget { FormatForm.target(for: volume, wholeDisk: erasesWholeDisk) }
    private var isBusy: Bool {
        model.formatting != nil || FormatForm.isBusy(volume, wholeDisk: erasesWholeDisk, busy: model.busy)
    }

    private var nameError: String? {
        FormatMessages.inlineError(
            filesystem: filesystem, label: label, scheme: scheme, target: target, driveName: volume.label)
    }

    private var canErase: Bool {
        !isBusy && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nameError == nil
    }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: filesystemBinding) {
                    ForEach(FormatForm.choices, id: \.self) { fs in
                        Text(fs.displayName)
                            .tag(fs)
                            .disabled(!FormatForm.isAvailable(fs, ready: ready))
                            .help(FormatForm.unavailableReason(fs, ready: ready) ?? "")
                    }
                }
                ForEach(FormatForm.choices.filter { !FormatForm.isAvailable($0, ready: ready) }, id: \.self) { fs in
                    if let reason = FormatForm.unavailableReason(fs, ready: ready) {
                        Text("\(fs.displayName): \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Name", text: $label)
                    .onChange(of: label) { labelEdited = true }
                if labelEdited, let message = nameError ?? emptyMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Erase the whole disk", isOn: wholeDiskBinding)
                    .disabled(FormatForm.isWholeDiskForced(volume))
                Picker("Partition scheme", selection: $scheme) {
                    ForEach([PartitionScheme.gpt, .mbr], id: \.self) { Text(FormatForm.schemeTitle($0)).tag($0) }
                }
                .disabled(!erasesWholeDisk)
                if !erasesWholeDisk {
                    Text("Formatting just this partition keeps the drive's partition table.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Erase…") {
                        pending = PendingErase(
                            filesystem: filesystem, label: label, scheme: scheme, target: target,
                            wholeDisk: erasesWholeDisk, expectedKey: volume.settingsKey)
                    }
                        .disabled(!canErase)
                    if isBusy { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pending) { pending in
            EraseSheet(model: model, volume: volume, pending: pending, dismiss: { self.pending = nil })
        }
    }

    private var emptyMessage: String? {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FormatMessages.text(for: .emptyLabel) : nil
    }

    private var filesystemBinding: Binding<FilesystemKind> {
        Binding(get: { filesystem }, set: { chosen = $0 })
    }

    private var wholeDiskBinding: Binding<Bool> {
        Binding(get: { erasesWholeDisk }, set: { wholeDisk = $0 })
    }
}

/// The form as it stood when Erase… was pressed. The sheet sends exactly this, whatever happens to the form behind it.
private struct PendingErase: Identifiable {
    let id = UUID()
    let filesystem: FilesystemKind
    let label: String
    let scheme: PartitionScheme
    let target: FormatTarget
    let wholeDisk: Bool
    /// The identity of the drive the form was for; the helper refuses the erase if the BSD name now names another.
    let expectedKey: String

    func request(confirmation: String) -> FormatRequest {
        FormatRequest(
            filesystem: filesystem, label: label, scheme: scheme, target: target, confirmation: confirmation,
            expectedKey: expectedKey)
    }
}

/// The last question before an erase: what will be lost, and the drive's name to type.
private struct EraseSheet: View {
    let model: DiskManagerModel
    let volume: Volume
    let pending: PendingErase
    let dismiss: () -> Void

    @State private var typed = ""
    @State private var sent = false

    private var valid: Bool {
        do throws(FormatValidationError) {
            try validate(pending.request(confirmation: typed), currentDriveName: volume.label)
            return true
        } catch {
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Erase \(volume.label)?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            ForEach(
                FormatForm.warning(for: volume, wholeDisk: pending.wholeDisk, in: model.volumes), id: \.self
            ) { line in
                Text(line)
            }
            Text("New format: \(FormatForm.summary(of: pending.request(confirmation: "")))")
            Text("This can't be undone. Don't unplug the drive until it finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Type \(volume.label) to confirm", text: $typed)
                .onSubmit { erase() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase", role: .destructive) { erase() }
                    .disabled(!valid || sent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Hands the format to the model and closes the sheet. The window shows the progress, and an error afterwards.
    private func erase() {
        guard valid, !sent else { return }
        sent = true
        let request = pending.request(confirmation: typed)
        let volume = volume
        Task { await model.format(request, volume: volume) }
        dismiss()
    }
}
