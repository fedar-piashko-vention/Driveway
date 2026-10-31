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
    @State private var sheetShown = false

    init(model: DiskManagerModel, volume: Volume) {
        self.model = model
        self.volume = volume
        _wholeDisk = State(initialValue: FormatForm.defaultsToWholeDisk(volume, in: model.volumes))
    }

    private var ready: Set<Feature> { model.readyFeatures }
    /// The choice, unless it has become unavailable since it was picked.
    private var filesystem: FilesystemKind { FormatForm.effective(chosen, ready: ready) }
    private var target: FormatTarget { FormatForm.target(for: volume, wholeDisk: wholeDisk) }
    private var isBusy: Bool { model.busy.contains(volume.bsdName) }

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

                Toggle("Erase the whole disk", isOn: $wholeDisk)
                Picker("Partition scheme", selection: $scheme) {
                    ForEach([PartitionScheme.gpt, .mbr], id: \.self) { Text(FormatForm.schemeTitle($0)).tag($0) }
                }
                .disabled(!wholeDisk)
                if !wholeDisk {
                    Text("Formatting just this partition keeps the drive's partition table.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Erase…") { sheetShown = true }
                        .disabled(!canErase)
                    if isBusy { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $sheetShown) {
            EraseSheet(
                model: model, volume: volume, wholeDisk: wholeDisk,
                request: { request(confirmation: $0) },
                dismiss: { sheetShown = false })
        }
    }

    private var emptyMessage: String? {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FormatMessages.text(for: .emptyLabel) : nil
    }

    private var filesystemBinding: Binding<FilesystemKind> {
        Binding(get: { filesystem }, set: { chosen = $0 })
    }

    private func request(confirmation: String) -> FormatRequest {
        FormatRequest(
            filesystem: filesystem, label: label, scheme: scheme, target: target, confirmation: confirmation)
    }
}

/// The last question before an erase: what will be lost, and the drive's name to type.
private struct EraseSheet: View {
    let model: DiskManagerModel
    let volume: Volume
    let wholeDisk: Bool
    let request: (String) -> FormatRequest
    let dismiss: () -> Void

    @State private var typed = ""
    @State private var working = false

    private var valid: Bool {
        do throws(FormatValidationError) {
            try validate(request(typed), currentDriveName: volume.label)
            return true
        } catch {
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Erase \(volume.label)?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            ForEach(FormatForm.warning(for: volume, wholeDisk: wholeDisk, in: model.volumes), id: \.self) { line in
                Text(line)
            }
            Text("This can't be undone. Don't unplug the drive until it finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Type \(volume.label) to confirm", text: $typed)
                .disabled(working)
                .onSubmit { if valid && !working { erase() } }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Erase", role: .destructive) { erase() }
                    .disabled(!valid || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(working)
    }

    /// Sends the format. The sheet closes when it ends, whether it worked or failed; an error is then shown by the window.
    private func erase() {
        let formatRequest = request(typed)
        working = true
        Task {
            await model.format(formatRequest, volume: volume)
            working = false
            dismiss()
        }
    }
}
