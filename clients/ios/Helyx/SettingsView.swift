import SwiftUI

/// The server of the app: its address, its port, and its token. With no
/// settings, the app starts here; a wrong address shows the text of the error
/// that the bindings threw (`docs/features/ios-app.md`, "The settings").
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @State private var address = ""
    @State private var port = ""
    @State private var token = ""
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Server") {
                TextField("Address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                // Not a password of an account: no offer to save it.
                SecureField("Token", text: $token)
                    .textContentType(.oneTimeCode)
            }
            Section {
                Button("Connect") { connect() }
                if store.settings != nil {
                    Button("Cancel") { store.cancelSettings() }
                }
            }
            if let message = failure ?? store.notice {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Server")
        .onAppear(perform: fill)
    }

    private func fill() {
        address = store.settings?.address ?? "127.0.0.1"
        port = store.settings.map { String($0.port) } ?? ""
        token = store.settings?.token ?? ""
        failure = nil
    }

    private func connect() {
        guard let number = UInt16(port), number != 0 else {
            failure = "the port is 1 to 65535"
            return
        }
        guard !address.isEmpty else {
            failure = "the address is an IP address"
            return
        }
        failure = nil
        store.use(
            ServerSettings(address: address, port: number, token: token)
        )
    }
}
