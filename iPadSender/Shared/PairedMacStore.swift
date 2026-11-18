import Foundation
import Security

/// The Mac this iPad streams to. The app saves it when pairing; the broadcast extension reads it
/// when streaming starts.
struct PairedMac: Codable, Equatable {
    var macID: String
    var macName: String
    /// This iPad's ID on that Mac.
    var deviceID: String
    /// This iPad's own key for that Mac, known only to the two of them. Kept in the keychain.
    var streamKey: Data
    /// What the Mac calls this iPad.
    var deviceName: String
}

/// Stores the paired Mac in a keychain access group shared by the app and its broadcast extension
/// (they're separate processes, so they can't share ordinary app storage).
enum PairedMacStore {
    private static let service = "app.ipadlive.paired-mac"
    private static let account = "paired-mac"

    /// "TEAMID.<bundle prefix>.shared", filled into each target's Info.plist at build time.
    private static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LiveLinkKeychainGroup") as? String,
              !group.isEmpty else { return nil }
        return group
    }

    private static var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func load() -> PairedMac? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    static func save(_ mac: PairedMac) throws {
        let data = try JSONEncoder().encode(mac)
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        // Readable while the iPad is unlocked (broadcasting needs that anyway); never synced or backed up elsewhere.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "The keychain refused to save the pairing (error \(status)).",
            ])
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
