//
//  TransferActivityViewModel.swift
//  MacOS
//

import Combine
import Foundation

/// One in-flight workspace mutation (upload / download / delete / rename / mkdir).
/// Identified by a stable key so concurrent operations on different paths render
/// as distinct rows in the strip; collisions on the same key just refresh the title.
struct TransferActivity: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: Kind

    enum Kind: Equatable {
        case upload
        case download
        case delete
        case rename
        case createDirectory
    }
}

/// Tracks the set of in-flight workspace mutations so the Finder window can
/// render a transient bottom activity strip. Optimistic by design — core does
/// not yet stream incremental progress through the FFI event channel, so each
/// operation only contributes a `start` / `finish` lifecycle.
@MainActor
final class TransferActivityViewModel: ObservableObject {
    @Published private(set) var activeTransfers: [TransferActivity] = []

    private var byId: [String: TransferActivity] = [:]

    func start(id: String, title: String, kind: TransferActivity.Kind) {
        let activity = TransferActivity(id: id, title: title, kind: kind)
        byId[id] = activity
        rebuildOrdered()
    }

    func finish(id: String) {
        guard byId.removeValue(forKey: id) != nil else { return }
        rebuildOrdered()
    }

    private func rebuildOrdered() {
        // Stable order: kind priority then title, so the strip doesn't visually
        // jitter when overlapping operations resolve out of insertion order.
        activeTransfers = byId.values.sorted {
            if $0.kind.sortRank != $1.kind.sortRank {
                return $0.kind.sortRank < $1.kind.sortRank
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

private extension TransferActivity.Kind {
    var sortRank: Int {
        switch self {
        case .upload: return 0
        case .download: return 1
        case .delete: return 2
        case .rename: return 3
        case .createDirectory: return 4
        }
    }
}
