import Foundation
import Security

public enum KeyError: Error, Equatable { case keychain(Int32), random, badHex }

public protocol KeyProvider { func key() throws -> Data }

public struct StaticKeyProvider: KeyProvider {
    private let data: Data
    public init(_ data: Data) { self.data = data }
    public func key() throws -> Data { data }
}

/// 64 hex characters = 32 raw bytes. For tests and disposable databases; the real key lives in the Keychain.
public struct HexKeyProvider: KeyProvider {
    private let hex: String
    public init(hex: String) { self.hex = hex }
    public func key() throws -> Data {
        guard hex.count == 64 else { throw KeyError.badHex }
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw KeyError.badHex }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// A random 32-byte key in the login Keychain (generic password), created on first use, never leaves this Mac.
public struct KeychainKeyProvider: KeyProvider {
    public var service: String
    public var account: String
    public init(service: String = "thatone", account: String = "index-key") {
        self.service = service; self.account = account
    }

    private var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func key() throws -> Data {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw KeyError.keychain(status) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { throw KeyError.random }
        var add = baseQuery
        add[kSecValueData] = Data(bytes)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeyError.keychain(added) }
        return Data(bytes)
    }

    func deleteForTesting() { SecItemDelete(baseQuery as CFDictionary) }
}

public enum Keys {
    /// `THATONE_KEY_HEX` if set (tests, disposable databases), otherwise the Keychain.
    public static func provider(environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        if let hex = environment["THATONE_KEY_HEX"], !hex.isEmpty { return HexKeyProvider(hex: hex) }
        return KeychainKeyProvider()
    }
}
