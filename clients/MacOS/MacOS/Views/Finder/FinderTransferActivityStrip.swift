//
//  FinderTransferActivityStrip.swift
//  MacOS
//

import SwiftUI

/// Transient bottom strip surfacing in-flight workspace mutations.
/// Renders one row per active transfer with an indeterminate spinner.
/// Core does not yet stream incremental progress through FFI, so the strip
/// only conveys "operation in flight" rather than a percentage.
struct FinderTransferActivityStrip: View {
    @ObservedObject var transferActivityVM: TransferActivityViewModel

    var body: some View {
        if transferActivityVM.activeTransfers.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 4) {
                ForEach(transferActivityVM.activeTransfers) { activity in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .progressViewStyle(.circular)

                        Text(activity.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Color(nsColor: .separatorColor)),
                alignment: .top
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
