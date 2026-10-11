import Foundation
import Security

/// OpenAIのAPIキーをキーチェーンに保存する。値はログやエラー表示に出さない
struct KeychainStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    var service = Bundle.main.bundleIdentifier ?? "NanpaVoice"
    var account = "openai-api-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 署名にキーチェーンの権限がないとき（無料アカウントで作ったMac版）の置き場所。
    /// サンドボックスの中なので他のアプリからは読めない
    private var fallbackURL: URL? {
        #if targetEnvironment(macCatalyst)
        URL.applicationSupportDirectory.appendingPathComponent("\(account).key")
        #else
        nil
        #endif
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement, let url = fallbackURL {
            try FileLayout.ensureDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            guard let url = fallbackURL, let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func delete() throws {
        if let url = fallbackURL { try? FileManager.default.removeItem(at: url) }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
