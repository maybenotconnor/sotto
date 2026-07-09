import Foundation
import Testing
@testable import Sotto

struct SettingsStoreWebDAVTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "settings-webdav-\(UUID().uuidString)")!
    }

    /// Unique service per test so parallel tests never share Keychain state.
    private func freshKeychain() -> KeychainStore {
        KeychainStore(service: "webdav-test-\(UUID().uuidString)")
    }

    private func configure(
        _ settings: SettingsStore, keychain: KeychainStore,
        url: String? = "https://dav.example.com/files/connor/Sotto",
        user: String? = "connor", password: String? = "secret"
    ) {
        settings.webdavServerURL = url
        settings.webdavUsername = user
        if let password { keychain.set(password, for: WebDAVConfig.passwordKeychainKey) }
    }

    @Test func accessorsRoundTripAndDefault() {
        let settings = SettingsStore(defaults: freshSuite())
        #expect(settings.webdavServerURL == nil)
        #expect(settings.webdavUsername == nil)
        #expect(settings.webdavEnabled == true)        // pause toggle defaults on
        #expect(settings.webdavAudioBackup == false)   // audio opt-in defaults off

        settings.webdavServerURL = "https://x.example"
        settings.webdavUsername = "u"
        settings.webdavEnabled = false
        settings.webdavAudioBackup = true
        #expect(settings.webdavServerURL == "https://x.example")
        #expect(settings.webdavUsername == "u")
        #expect(settings.webdavEnabled == false)
        #expect(settings.webdavAudioBackup == true)

        settings.webdavServerURL = nil                 // forget clears via nil
        #expect(settings.webdavServerURL == nil)
    }

    @Test func loadReturnsConfigWhenFullyConfigured() {
        let settings = SettingsStore(defaults: freshSuite())
        let keychain = freshKeychain()
        defer { keychain.delete(WebDAVConfig.passwordKeychainKey) }
        configure(settings, keychain: keychain)
        settings.webdavAudioBackup = true

        let config = WebDAVConfig.load(settings: settings, keychain: keychain)

        #expect(config?.baseURL.absoluteString == "https://dav.example.com/files/connor/Sotto")
        #expect(config?.username == "connor")
        #expect(config?.password == "secret")
        #expect(config?.audioEnabled == true)
    }

    @Test func loadIsNilWhenAnyPieceIsMissingOrNotHTTPS() {
        let keychain = freshKeychain()
        defer { keychain.delete(WebDAVConfig.passwordKeychainKey) }

        let noURL = SettingsStore(defaults: freshSuite())
        configure(noURL, keychain: keychain, url: nil)
        #expect(WebDAVConfig.load(settings: noURL, keychain: keychain) == nil)

        let httpOnly = SettingsStore(defaults: freshSuite())
        configure(httpOnly, keychain: keychain, url: "http://insecure.example/dav")
        #expect(WebDAVConfig.load(settings: httpOnly, keychain: keychain) == nil)

        let noUser = SettingsStore(defaults: freshSuite())
        configure(noUser, keychain: keychain, user: "")
        #expect(WebDAVConfig.load(settings: noUser, keychain: keychain) == nil)

        let noPassword = SettingsStore(defaults: freshSuite())
        let emptyKeychain = freshKeychain()
        configure(noPassword, keychain: emptyKeychain, password: nil)
        #expect(WebDAVConfig.load(settings: noPassword, keychain: emptyKeychain) == nil)
    }
}
