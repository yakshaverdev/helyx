import Foundation

/// The server that the app uses.
struct ServerSettings: Equatable {
    /// An IP address, as the bindings parse it.
    var address: String
    /// 1 to 65535.
    var port: UInt16
    /// The token of the handshake; an empty token is no proof.
    var token: String
}

/// Where the settings live between launches: the address and the port in
/// `UserDefaults`, the token in the Keychain (`docs/features/ios-app.md`,
/// "Ownership").
enum SettingsStorage {
    private static let addressKey = "server.address"
    private static let portKey = "server.port"

    static func load() -> ServerSettings? {
        let defaults = UserDefaults.standard
        guard
            let address = defaults.string(forKey: addressKey),
            let port = UInt16(exactly: defaults.integer(forKey: portKey)),
            port != 0,
            let token = Keychain.load()
        else { return nil }
        return ServerSettings(address: address, port: port, token: token)
    }

    /// False when the token was not kept, so the next launch asks again.
    static func save(_ settings: ServerSettings) -> Bool {
        UserDefaults.standard.set(settings.address, forKey: addressKey)
        UserDefaults.standard.set(Int(settings.port), forKey: portKey)
        return Keychain.save(settings.token)
    }
}
