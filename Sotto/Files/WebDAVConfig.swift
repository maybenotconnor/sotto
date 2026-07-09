import Foundation

/// A fully-resolved WebDAV destination, loaded FRESH per event like every registry input.
/// `load` is the single definition of "configured": an https URL, a non-empty username,
/// and an app password in the Keychain. The base URL is the exact collection backups land
/// in — day folders are created directly inside it (design 2026-07-09 §2: no fixed
/// subfolder, no endpoint derivation).
struct WebDAVConfig: Sendable, Equatable {
    static let passwordKeychainKey = "webdavAppPassword"

    let baseURL: URL
    let username: String
    let password: String
    let audioEnabled: Bool

    static func load(
        settings: SettingsStore, keychain: KeychainStore = KeychainStore()
    ) -> WebDAVConfig? {
        guard let urlString = settings.webdavServerURL,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let username = settings.webdavUsername,
              !username.isEmpty,
              let password = keychain.get(passwordKeychainKey),
              !password.isEmpty
        else { return nil }
        return WebDAVConfig(
            baseURL: url, username: username, password: password,
            audioEnabled: settings.webdavAudioBackup)
    }
}
