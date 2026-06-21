import SwiftUI

/// Modal sheet that captures a new S3 connection. Credentials live only in
/// the SwiftUI `@State` while the sheet is up; on submit they're forwarded
/// to `ConnectionViewModel.create` and then cleared so the SwiftUI snapshot
/// never retains plaintext beyond the submission.
struct NewConnectionSheet: View {
    @ObservedObject var viewModel: ConnectionViewModel
    @Binding var isPresented: Bool

    @State private var displayName = ""
    @State private var endpoint = "http://localhost:9000"
    @State private var region = "us-east-1"
    @State private var bucket = ""
    @State private var basePrefix = ""
    @State private var pathStyle = true
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var errorText: String?
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !isSubmitting
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKeyId.isEmpty
            && !secretAccessKey.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Connection")
                .font(.headline)

            Form {
                TextField("Display name", text: $displayName)
                TextField("Endpoint", text: $endpoint)
                TextField("Region", text: $region)
                TextField("Bucket", text: $bucket)
                TextField("Base prefix (optional)", text: $basePrefix)
                Toggle("Path-style addressing (MinIO)", isOn: $pathStyle)
                TextField("Access key id", text: $accessKeyId)
                SecureField("Secret access key", text: $secretAccessKey)
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    clearCredentials()
                    isPresented = false
                }
                .disabled(isSubmitting)

                Button("Save") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func submit() {
        isSubmitting = true
        errorText = nil
        Task { @MainActor in
            do {
                try await viewModel.create(
                    displayName: displayName,
                    endpoint: endpoint,
                    region: region,
                    bucket: bucket,
                    basePrefix: basePrefix,
                    pathStyle: pathStyle,
                    accessKeyId: accessKeyId,
                    secretAccessKey: secretAccessKey
                )
                clearCredentials()
                isSubmitting = false
                isPresented = false
            } catch {
                errorText = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    private func clearCredentials() {
        accessKeyId = ""
        secretAccessKey = ""
    }
}
