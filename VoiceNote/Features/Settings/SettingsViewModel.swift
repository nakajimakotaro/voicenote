import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    /// 保存済みのキーの伏せ字表示。未保存ならnil
    private(set) var maskedKey: String?
    var keyInput = ""
    private(set) var errorMessage: String?

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    var canSave: Bool { !trimmedInput.isEmpty }

    private var trimmedInput: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load() {
        do {
            maskedKey = try keychain.read().map(Self.mask)
            errorMessage = nil
        } catch {
            errorMessage = "APIキーを読み出せませんでした"
        }
    }

    func saveKey() {
        guard canSave else { return }
        do {
            try keychain.save(trimmedInput)
            keyInput = ""
            load()
        } catch {
            errorMessage = "APIキーを保存できませんでした"
        }
    }

    func deleteKey() {
        do {
            try keychain.delete()
            maskedKey = nil
            errorMessage = nil
        } catch {
            errorMessage = "APIキーを削除できませんでした"
        }
    }

    /// "sk-proj-abcdef…wxyz" → "sk-••••••••wxyz"
    nonisolated static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: 8) }
        return "\(key.prefix(3))••••••••\(key.suffix(4))"
    }
}
