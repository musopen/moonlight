// LastFMCredentialStore.swift
//
// Saves, loads and deletes the user's Last.fm sign-in in the macOS Keychain, the system's secure
// password storage, so the user stays connected between launches without the app keeping it in
// plain files. The sign-in stays on this Mac: it is not copied into backups or to a new Mac.
// Sign-ins saved by older versions are moved over the first time they are read.

import Foundation
import Security

protocol LastFMSessionStoring: AnyObject {
    func loadSession() throws -> LastFMSession?
    func saveSession(_ session: LastFMSession) throws
    func deleteSession() throws
}

final class LastFMKeychainStore: LastFMSessionStoring {
    private let service = "org.musopen.moonlight.lastfm"
    private let account = "session"
    /// Keeps the session key on this device: it is excluded from backups and never migrates.
    /// macOS only honours this in the data protection keychain, so every query asks for it.
    private let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    func loadSession() throws -> LastFMSession? {
        switch copyData(dataProtection: true) {
        case .found(let data):
            return try decode(data)
        case .failed(let status):
            throw LastFMAPIError.keychain(status)
        case .notFound, .unavailable:
            break
        }

        // Sessions saved by older builds live in the file-based login keychain, which backups
        // and Migration Assistant copy. Move them into the data protection keychain once.
        switch copyData(dataProtection: false) {
        case .found(let data):
            let session = try decode(data)
            if add(data, dataProtection: true) == errSecSuccess {
                SecItemDelete(identityQuery(dataProtection: false) as CFDictionary)
            }
            return session
        case .failed(let status):
            throw LastFMAPIError.keychain(status)
        case .notFound, .unavailable:
            return nil
        }
    }

    func saveSession(_ session: LastFMSession) throws {
        let data = try JSONEncoder().encode(session)
        try deleteSession()
        var status = add(data, dataProtection: true)
        if status == errSecMissingEntitlement {
            // Unsigned development builds can't use the data protection keychain.
            status = add(data, dataProtection: false)
        }
        guard status == errSecSuccess else { throw LastFMAPIError.keychain(status) }
    }

    func deleteSession() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(identityQuery(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw LastFMAPIError.keychain(status)
            }
        }
    }

    private enum CopyResult {
        case found(Data)
        case notFound
        case unavailable
        case failed(OSStatus)
    }

    private func copyData(dataProtection: Bool) -> CopyResult {
        var result: CFTypeRef?
        var query = identityQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case errSecMissingEntitlement:
            return .unavailable
        case let status:
            return .failed(status)
        }
    }

    private func add(_ data: Data, dataProtection: Bool) -> OSStatus {
        var query = identityQuery(dataProtection: dataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func decode(_ data: Data) throws -> LastFMSession {
        try JSONDecoder().decode(LastFMSession.self, from: data)
    }

    private func identityQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
