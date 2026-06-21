import SwiftUI

/// One cloud-connection entry in the Finder sidebar's Connections section.
/// Tapping the row asks the parent to open it; the context menu offers removal.
struct ConnectionRow: View {
    let item: ConnectionListItem
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud")
                .font(.system(size: 17, weight: .regular))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                Text(item.bucket)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Remove…", role: .destructive) { onRemove() }
        }
        .accessibilityLabel("Connection \(item.displayName)")
    }
}
