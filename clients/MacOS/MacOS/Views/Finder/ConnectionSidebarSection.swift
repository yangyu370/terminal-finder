import SwiftUI

/// The "Connections" section embedded in `FinderSidebarView`. Loads existing
/// connections from the store on first appearance, lets the user add new ones
/// via `NewConnectionSheet`, and forwards selection to the workspace browser.
struct ConnectionSidebarSection: View {
    @ObservedObject var viewModel: ConnectionViewModel
    let onOpenConnection: (String) -> Void
    let onMove: (FinderDragItem, String) -> Void

    @State private var isAddingConnection = false
    @State private var hasLoaded = false

    var body: some View {
        Section {
            ForEach(viewModel.connections) { item in
                ConnectionRow(
                    item: item,
                    onSelect: { onOpenConnection(item.id) },
                    onRemove: {
                        Task { @MainActor in
                            try? await viewModel.remove(id: item.id)
                        }
                    }
                )
                .dropDestination(for: FinderDragItem.self) { dragItems, _ in
                    guard let dragItem = dragItems.first,
                          FinderMoveDropGuard.canMove(
                              dragItem,
                              intoDirectory: "",
                              targetConnectionId: item.id
                          )
                    else {
                        return false
                    }

                    onMove(dragItem, "")
                    return true
                }
            }
        } header: {
            HStack {
                Text("Connections")
                Spacer()
                Button {
                    isAddingConnection = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add connection")
            }
        }
        .sheet(isPresented: $isAddingConnection) {
            NewConnectionSheet(viewModel: viewModel, isPresented: $isAddingConnection)
        }
        .task {
            // Run only on first appearance; subsequent sidebar redraws must not
            // re-hydrate (which would create duplicate core entries).
            guard !hasLoaded else { return }
            hasLoaded = true
            try? await viewModel.load()
        }
    }
}
