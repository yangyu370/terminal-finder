//
//  ContentView.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

import SwiftUI
struct ContentView: View {
    @StateObject private var viewModel = BackendConnectionViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BackendStatusView(
                status: viewModel.status,
                detailText: viewModel.detailText
            )
            HStack {
                Button("Ping Core") {
                    viewModel.ping()
                }
                .disabled(viewModel.isConnecting)
                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 220)
        .task {
            viewModel.ping()
        }
    }
}
