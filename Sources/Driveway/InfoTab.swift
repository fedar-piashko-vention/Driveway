import AppKit
import DrivewayCore
import SwiftUI

/// A drive's details, its banner when something needs attention, and Eject / Show in Finder.
struct InfoTab: View {
    let model: DiskManagerModel
    let volume: Volume

    static func accessText(_ access: AccessMode) -> String {
        switch access {
        case .readWrite: "Read/Write"
        case .readOnly: "Read-only ⚠️"
        case .notMounted: "Not mounted"
        }
    }

    var body: some View {
        Form {
            if let banner = VolumeList.banner(for: volume) {
                Section { BannerView(model: model, volume: volume, banner: banner) }
            }
            Section {
                LabeledContent("Device", value: volume.deviceModel)
                LabeledContent("Filesystem", value: volume.filesystem.displayName)
                LabeledContent("Capacity", value: Self.bytes(volume.capacityBytes))
                if let used = volume.usedBytes, volume.capacityBytes > 0 {
                    LabeledContent("Used") {
                        VStack(alignment: .trailing) {
                            ProgressView(
                                value: Double(min(used, volume.capacityBytes)), total: Double(volume.capacityBytes)
                            )
                            .frame(maxWidth: 200)
                            Text("\(Self.bytes(used)) of \(Self.bytes(volume.capacityBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Mount point", value: volume.mountPoint ?? "Not mounted")
                LabeledContent("Access", value: Self.accessText(volume.access))
                if let backend = volume.backend {
                    LabeledContent("Mounted with", value: backend == .kernel ? "Kernel extension" : "FSKit")
                }
                LabeledContent("Health", value: VolumeList.healthText(volume.health))
            }
            if volume.filesystem == .ntfs {
                Section {
                    Toggle(Copy.alwaysMountReadOnly, isOn: alwaysReadOnly)
                        .disabled(!model.settingsLoaded)
                }
            }
            Section {
                HStack {
                    if VolumeList.offersMountReadWrite(volume) {
                        Button(Copy.mountReadWrite) { Task { await model.mountReadWrite(volume) } }
                            .disabled(model.busy.contains(volume.bsdName) || model.isAlwaysReadOnly(volume))
                            .help(
                                model.isAlwaysReadOnly(volume)
                                    ? "This drive is set to always mount read-only." : "Mount this drive read/write with Driveway.")
                    }
                    Button("Eject") { Task { await model.eject(volume) } }
                        .disabled(model.busy.contains(volume.bsdName))
                    Button("Show in Finder") {
                        if let path = volume.mountPoint {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    .disabled(volume.mountPoint == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var alwaysReadOnly: Binding<Bool> {
        Binding(
            get: { model.isAlwaysReadOnly(volume) },
            set: { on in Task { await model.setAlwaysReadOnly(on, for: volume) } })
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct BannerView: View {
    let model: DiskManagerModel
    let volume: Volume
    let banner: VolumeBanner

    var body: some View {
        switch banner {
        case .dirty:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Mounted read-only because Windows didn't shut this drive down cleanly.",
                    systemImage: "exclamationmark.triangle")
                Button(Copy.fixAndMount) { Task { await model.fixAndMount(volume) } }
                    .disabled(model.busy.contains(volume.bsdName))
            }
        case .hibernated:
            Label(
                "Mounted read-only because Windows is hibernating (Fast Startup). Shut Windows down fully, or turn off Fast Startup by running powercfg /hibernate off in Windows, then plug the drive in again.",
                systemImage: "moon.zzz")
        case .otherDriver(let driver):
            Label("\(Copy.mountedBy(driver)). Driveway leaves this drive alone.", systemImage: "info.circle")
        case .error(let message):
            Label("Driveway couldn't mount this drive read/write: \(message)", systemImage: "exclamationmark.triangle")
        }
    }
}
