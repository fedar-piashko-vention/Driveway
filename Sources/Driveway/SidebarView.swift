import DrivewayCore
import SwiftUI

/// The drive list, grouped "NTFS / ext" and "Other".
struct SidebarView: View {
    @Bindable var model: DiskManagerModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(VolumeList.sections(model.volumes), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.volumes) { volume in
                        VolumeRow(volume: volume).tag(volume.bsdName)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct VolumeRow: View {
    let volume: Volume

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(volume.label).lineLimit(1)
            HStack(spacing: 6) {
                Text(volume.filesystem.displayName)
                if volume.filesystem.isDrivewayManaged {
                    AccessPill(access: volume.access)
                } else {
                    Text(Copy.handledByMacOS)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AccessPill: View {
    let access: AccessMode

    var body: some View {
        Text(InfoTab.accessText(access))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(access == .readWrite ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
    }
}
