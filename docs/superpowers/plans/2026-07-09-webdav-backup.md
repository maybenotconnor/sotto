# WebDAV Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in WebDAV backup provider (spec `docs/superpowers/specs/2026-07-09-webdav-backup-design.md`): mirror transcripts (+ optional audio) to a user-configured HTTPS WebDAV server, with manual restore, behind the existing `TranscriptSyncSink` seam.

**Architecture:** Fresh-per-event `WebDAVSyncSink` structs forward to one shared serial `WebDAVExecutor` actor (strict FIFO fixes the PUT-vs-DELETE resurrection race). A one-protocol transport seam (`WebDAVTransport`, satisfied by `URLSession`) makes everything testable with a scripted fake. Credentials: URL/username/toggles in `SettingsStore` (UserDefaults), app password in Keychain.

**Tech Stack:** Swift 6 (strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`), SwiftUI, URLSession, XMLParser, Swift Testing (`@Test` / `#expect`), xcodegen.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → expect `** TEST SUCCEEDED **`. Narrow a run with `-only-testing:SottoTests/<SuiteName>`.
- After creating any new file: `xcodegen generate` (project.yml globs `Sotto/` and `SottoTests/`), then build/test. `Sotto.xcodeproj` is **gitignored** — never `git add` it.
- Zero new warnings. Swift 6; default actor isolation is `nonisolated` — annotate deliberately.
- Commit messages: plain conventional style (`feat:`, `test:`, `docs:`), **no attribution trailers**.
- `_day.json`, `.caf` must never be uploaded. Audio (`.m4a`) uploads only when `webdavAudioBackup` is on.
- All sink work is best-effort: nothing here may ever throw into a caller, block the transcription queue, or ride the main actor.
- HTTPS only — reject non-`https` URLs at save and at `WebDAVConfig.load`.
- Keychain key for the app password: `webdavAppPassword` (constant `WebDAVConfig.passwordKeychainKey`).
- Existing test fakes live in `SottoTests/Fakes.swift` — `FakeNetworkMonitor(isOnWiFi:)` already exists; reuse it, don't redefine it.

---

### Task 1: SettingsStore accessors + WebDAVConfig

**Files:**
- Create: `Sotto/Files/WebDAVConfig.swift`
- Modify: `Sotto/Files/RetentionPolicy.swift` (append to the existing `SettingsStore` extension, after `iCloudBackupEnabled`)
- Test: `SottoTests/SettingsStoreWebDAVTests.swift` (create)

**Interfaces:**
- Consumes: `SettingsStore` (existing, `Sotto/Files/RetentionPolicy.swift`), `KeychainStore` (existing, `Sotto/Transcription/KeychainStore.swift` — `init(service:)`, `get`, `set`, `delete`).
- Produces: `SettingsStore.webdavServerURL: String?`, `.webdavUsername: String?`, `.webdavEnabled: Bool` (default true), `.webdavAudioBackup: Bool` (default false); `struct WebDAVConfig: Sendable, Equatable { let baseURL: URL; let username: String; let password: String; let audioEnabled: Bool }` with `static func load(settings: SettingsStore, keychain: KeychainStore = KeychainStore()) -> WebDAVConfig?` and `static let passwordKeychainKey = "webdavAppPassword"`.

- [ ] **Step 1: Write the failing tests**

`SottoTests/SettingsStoreWebDAVTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SettingsStoreWebDAVTests 2>&1 | tail -5`
Expected: build FAILURE — `webdavServerURL`/`WebDAVConfig` not defined. (`xcodegen generate` first so the new test file is in the project.)

- [ ] **Step 3: Implement**

Append to the `SettingsStore` extension in `Sotto/Files/RetentionPolicy.swift` (directly after `iCloudBackupEnabled`):

```swift
    // MARK: WebDAV backup (design 2026-07-09). URL + username + toggles are configuration
    // and live here; only the app password is a secret and lives in the Keychain
    // (WebDAVConfig.passwordKeychainKey) — same split as the Deepgram key.

    var webdavServerURL: String? {
        get { defaults.string(forKey: "webdavServerURL") }
        nonmutating set { defaults.set(newValue, forKey: "webdavServerURL") }
    }

    var webdavUsername: String? {
        get { defaults.string(forKey: "webdavUsername") }
        nonmutating set { defaults.set(newValue, forKey: "webdavUsername") }
    }

    /// Pause toggle — default on so saving a config starts backing up immediately; turning
    /// it off is non-destructive (config + server files stay), like iCloudBackupEnabled.
    var webdavEnabled: Bool {
        get {
            defaults.object(forKey: "webdavEnabled") == nil
                ? true : defaults.bool(forKey: "webdavEnabled")
        }
        nonmutating set { defaults.set(newValue, forKey: "webdavEnabled") }
    }

    /// Audio is opt-in per server (default off): privacy-first, no surprise multi-MB
    /// uploads. `bool(forKey:)` returns false when unset — exactly the default.
    var webdavAudioBackup: Bool {
        get { defaults.bool(forKey: "webdavAudioBackup") }
        nonmutating set { defaults.set(newValue, forKey: "webdavAudioBackup") }
    }
```

Create `Sotto/Files/WebDAVConfig.swift`:

```swift
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
```

- [ ] **Step 4: `xcodegen generate`, run the suite to verify it passes**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SettingsStoreWebDAVTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVConfig.swift Sotto/Files/RetentionPolicy.swift SottoTests/SettingsStoreWebDAVTests.swift
git commit -m "feat: SettingsStore WebDAV accessors + WebDAVConfig.load (defaults/Keychain split)"
```

---

### Task 2: WebDAVClient — transport seam, verbs, error taxonomy

**Files:**
- Create: `Sotto/Files/WebDAVClient.swift`
- Create: `SottoTests/WebDAVTestSupport.swift` (the scripted fake transport — shared by Tasks 2, 4, 5, 6)
- Test: `SottoTests/WebDAVClientTests.swift` (create)

**Interfaces:**
- Consumes: `WebDAVConfig` (Task 1).
- Produces:
  - `protocol WebDAVTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, URLResponse); func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) }` + `extension URLSession: WebDAVTransport`.
  - `enum WebDAVError: Error, Equatable { case unauthorized, notFound, conflict, insufficientStorage, server(Int) }`.
  - `struct WebDAVClient: Sendable { let config: WebDAVConfig; let transport: any WebDAVTransport }` with `putFile(_:to:contentType:)`, `delete(_:)` (tolerates 404), `mkcol(_:)` (tolerates 405), `propfind(_:depth:) -> Data`, `get(_:) -> Data`.
  - Test support: `actor FakeWebDAVTransport: WebDAVTransport` with `Scripted` responses and a `recorded: [Recorded]` log (see code below).

- [ ] **Step 1: Write the fake transport**

`SottoTests/WebDAVTestSupport.swift`:

```swift
import Foundation
@testable import Sotto

/// Scripted WebDAVTransport: records every request in arrival order and pops canned
/// responses front-to-back (empty script → `fallback`). Recorded order doubles as the
/// FIFO assertion for executor tests. An actor: requests arrive from executor tasks.
actor FakeWebDAVTransport: WebDAVTransport {
    enum Scripted: Sendable {
        case response(Int, Data)
        case error(any Error)

        static func status(_ code: Int, _ data: Data = Data()) -> Scripted {
            .response(code, data)
        }
    }

    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let uploadedFile: URL?
    }

    private(set) var recorded: [Recorded] = []
    private var script: [Scripted]
    private let fallback: Scripted

    init(script: [Scripted] = [], fallback: Scripted = .status(201)) {
        self.script = script
        self.fallback = fallback
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try respond(request, uploadedFile: nil)
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try respond(request, uploadedFile: fileURL)
    }

    private func respond(_ request: URLRequest, uploadedFile: URL?) throws -> (Data, URLResponse) {
        recorded.append(Recorded(
            method: request.httpMethod ?? "?", url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:], uploadedFile: uploadedFile))
        let next = script.isEmpty ? fallback : script.removeFirst()
        switch next {
        case .response(let code, let data):
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        case .error(let error):
            throw error
        }
    }
}

/// The standard test destination — audio off unless a test opts in.
func makeWebDAVConfig(audio: Bool = false) -> WebDAVConfig {
    WebDAVConfig(
        baseURL: URL(string: "https://dav.example.com/files/connor/Sotto")!,
        username: "connor", password: "secret", audioEnabled: audio)
}
```

- [ ] **Step 2: Write the failing tests**

`SottoTests/WebDAVClientTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct WebDAVClientTests {
    private func client(_ transport: FakeWebDAVTransport) -> WebDAVClient {
        WebDAVClient(config: makeWebDAVConfig(), transport: transport)
    }

    private func tempFile(_ contents: String = "body") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-\(UUID().uuidString).md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func putSendsPreemptiveBasicAuthAndContentType() async throws {
        let transport = FakeWebDAVTransport()
        let file = try tempFile()
        let target = URL(string: "https://dav.example.com/files/connor/Sotto/2026-07-07/09-15-00.md")!

        try await client(transport).putFile(file, to: target, contentType: "text/markdown")

        let recorded = await transport.recorded
        #expect(recorded.count == 1)
        #expect(recorded[0].method == "PUT")
        #expect(recorded[0].url == target)
        #expect(recorded[0].uploadedFile == file)   // streams from file, never Data(contentsOf:)
        // base64("connor:secret")
        #expect(recorded[0].headers["Authorization"] == "Basic Y29ubm9yOnNlY3JldA==")
        #expect(recorded[0].headers["Content-Type"] == "text/markdown")
    }

    @Test func statusCodesMapToTheErrorTaxonomy() async throws {
        let cases: [(Int, WebDAVError)] = [
            (401, .unauthorized), (404, .notFound), (409, .conflict),
            (507, .insufficientStorage), (500, .server(500)),
        ]
        for (status, expected) in cases {
            let transport = FakeWebDAVTransport(fallback: .status(status))
            let file = try tempFile()
            await #expect(throws: expected) {
                try await client(transport).putFile(
                    file, to: makeWebDAVConfig().baseURL, contentType: "text/markdown")
            }
        }
    }

    @Test func deleteTolerates404() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(404))
        try await client(transport).delete(makeWebDAVConfig().baseURL)   // must not throw
        #expect(await transport.recorded.first?.method == "DELETE")
    }

    @Test func mkcolTolerates405AlreadyExists() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(405))
        try await client(transport).mkcol(makeWebDAVConfig().baseURL)    // must not throw
        #expect(await transport.recorded.first?.method == "MKCOL")
    }

    @Test func propfindSetsDepthHeaderAndBodyAndRequires207() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(207, Data("xml".utf8)))
        let data = try await client(transport).propfind(makeWebDAVConfig().baseURL, depth: 1)

        #expect(String(decoding: data, as: UTF8.self) == "xml")
        let recorded = await transport.recorded
        #expect(recorded[0].method == "PROPFIND")
        #expect(recorded[0].headers["Depth"] == "1")
    }

    @Test func getReturnsBodyOn200() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(200, Data("hello".utf8)))
        let data = try await client(transport).get(makeWebDAVConfig().baseURL)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func transportErrorsPropagateAsThemselves() async throws {
        let transport = FakeWebDAVTransport(
            fallback: .error(URLError(.cannotConnectToHost)))
        await #expect(throws: URLError.self) {
            _ = try await client(transport).get(makeWebDAVConfig().baseURL)
        }
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVClientTests 2>&1 | tail -5`
Expected: build FAILURE — `WebDAVTransport`/`WebDAVClient` not defined.

- [ ] **Step 4: Implement**

Create `Sotto/Files/WebDAVClient.swift`:

```swift
import Foundation

/// One-method-per-shape transport seam (mirrors how NetworkMonitoring abstracts
/// NWPathMonitor): URLSession satisfies it in production; tests script it. Method names
/// deliberately differ from URLSession's own (`send`, not `data(for:)`) so the conformance
/// below can't shadow call sites elsewhere (DeepgramService) or recurse.
protocol WebDAVTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

extension URLSession: WebDAVTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await upload(for: request, fromFile: fileURL)
    }
}

/// Design §4 error taxonomy. `.conflict` (409) exists so the PUT→MKCOL→retry self-heal can
/// pattern-match "parent collection missing"; transport failures (URLError) propagate as
/// themselves — the executor maps both to status-line copy.
enum WebDAVError: Error, Equatable {
    case unauthorized          // 401
    case notFound              // 404
    case conflict              // 409
    case insufficientStorage   // 507
    case server(Int)           // any other non-success
}

/// Stateless request builder + status mapper for the five verbs Sotto uses. Preemptive
/// Basic auth on every request — no challenge round-trips; HTTPS is enforced upstream at
/// config save and `WebDAVConfig.load`.
struct WebDAVClient: Sendable {
    let config: WebDAVConfig
    let transport: any WebDAVTransport

    /// PUT replaces (RFC 4918). Uploads stream from the file so a multi-MB .m4a never
    /// loads into memory — used for .md too, so there is exactly one upload path.
    func putFile(_ fileURL: URL, to url: URL, contentType: String) async throws {
        var request = request("PUT", url)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport.upload(request, fromFile: fileURL)
        try check(response, accept: [200, 201, 204])
    }

    /// DELETE tolerating 404 — never-mirrored or already-gone is success (local is truth).
    func delete(_ url: URL) async throws {
        let (_, response) = try await transport.send(request("DELETE", url))
        try check(response, accept: [200, 204, 404])
    }

    /// MKCOL tolerating 405 (collection already exists — the self-heal re-PUTs right after).
    func mkcol(_ url: URL) async throws {
        let (_, response) = try await transport.send(request("MKCOL", url))
        try check(response, accept: [201, 405])
    }

    /// PROPFIND asking only for resourcetype — all restore/test-connection need. Depth is
    /// 0 (the collection itself) or 1 (+ immediate children); depth-infinity is never used
    /// because servers commonly disable it.
    func propfind(_ url: URL, depth: Int) async throws -> Data {
        var request = request("PROPFIND", url)
        request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let (data, response) = try await transport.send(request)
        try check(response, accept: [207])
        return data
    }

    func get(_ url: URL) async throws -> Data {
        let (data, response) = try await transport.send(request("GET", url))
        try check(response, accept: [200])
        return data
    }

    private static let propfindBody =
        #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let credentials = Data("\(config.username):\(config.password)".utf8)
            .base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ response: URLResponse, accept: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.server(-1) }
        guard !accept.contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401: throw WebDAVError.unauthorized
        case 404: throw WebDAVError.notFound
        case 409: throw WebDAVError.conflict
        case 507: throw WebDAVError.insufficientStorage
        default: throw WebDAVError.server(http.statusCode)
        }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVClientTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sotto/Files/WebDAVClient.swift SottoTests/WebDAVTestSupport.swift SottoTests/WebDAVClientTests.swift
git commit -m "feat: WebDAVClient — transport seam, five verbs, error taxonomy"
```

---

### Task 3: WebDAVMultistatus — PROPFIND response parser

**Files:**
- Create: `Sotto/Files/WebDAVMultistatus.swift`
- Test: `SottoTests/WebDAVMultistatusTests.swift` (create)

**Interfaces:**
- Consumes: nothing project-specific (Foundation `XMLParser`).
- Produces: `enum WebDAVMultistatus` with `struct Entry: Equatable, Sendable { let href: String /* percent-decoded */; let isCollection: Bool }` and `static func parse(_ data: Data) -> [Entry]`.

- [ ] **Step 1: Write the failing tests**

`SottoTests/WebDAVMultistatusTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct WebDAVMultistatusTests {
    /// OpenCloud/Nextcloud (sabre) shape: `d:` prefix for DAV:.
    private let sabreStyle = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/connor/Sotto/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/connor/Sotto/2026-07-07/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/connor/Sotto/notes.txt</d:href>
        <d:propstat><d:prop><d:resourcetype/></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
    </d:multistatus>
    """

    /// Apache mod_dav shape: `D:` prefix — same DAV: namespace.
    private let modDavStyle = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/dav/Sotto/2026-07-08/</D:href>
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/Sotto/2026-07-08/10-30-00.md</D:href>
        <D:propstat><D:prop><D:resourcetype/></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      </D:response>
    </D:multistatus>
    """

    @Test func parsesHrefsAndCollectionFlags() {
        let entries = WebDAVMultistatus.parse(Data(sabreStyle.utf8))
        #expect(entries == [
            .init(href: "/remote.php/dav/files/connor/Sotto/", isCollection: true),
            .init(href: "/remote.php/dav/files/connor/Sotto/2026-07-07/", isCollection: true),
            .init(href: "/remote.php/dav/files/connor/Sotto/notes.txt", isCollection: false),
        ])
    }

    @Test func namespacePrefixDoesNotMatter() {
        let entries = WebDAVMultistatus.parse(Data(modDavStyle.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].isCollection == true)
        #expect(entries[1].href == "/dav/Sotto/2026-07-08/10-30-00.md")
        #expect(entries[1].isCollection == false)
    }

    @Test func hrefsArePercentDecoded() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:"><d:response>
          <d:href>/dav/My%20Files/2026-07-07/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
        </d:response></d:multistatus>
        """
        #expect(WebDAVMultistatus.parse(Data(xml.utf8)).first?.href == "/dav/My Files/2026-07-07/")
    }

    @Test func garbageParsesToEmpty() {
        #expect(WebDAVMultistatus.parse(Data("not xml at all".utf8)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVMultistatusTests 2>&1 | tail -5`
Expected: build FAILURE — `WebDAVMultistatus` not defined.

- [ ] **Step 3: Implement**

Create `Sotto/Files/WebDAVMultistatus.swift`:

```swift
import Foundation

/// Minimal RFC 4918 multistatus reader: each <response>'s href + whether its resourcetype
/// marks a collection. Namespace-agnostic via shouldProcessNamespaces — OpenCloud,
/// Nextcloud, and Apache mod_dav all prefix DAV: differently, and local names + namespace
/// URI are the only stable coordinates. Malformed XML degrades to whatever parsed before
/// the error (garbage → empty) — callers treat it as "nothing listed", best-effort.
enum WebDAVMultistatus {
    struct Entry: Equatable, Sendable {
        let href: String        // percent-decoded server path
        let isCollection: Bool
    }

    static func parse(_ data: Data) -> [Entry] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        return reader.entries
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var href = ""
        private var inHref = false
        private var isCollection = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String]
        ) {
            guard namespaceURI == "DAV:" else { return }
            switch elementName {
            case "response": href = ""; isCollection = false
            case "href": inHref = true
            case "collection": isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inHref { href += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            guard namespaceURI == "DAV:" else { return }
            switch elementName {
            case "href":
                inHref = false
            case "response":
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(Entry(
                    href: trimmed.removingPercentEncoding ?? trimmed,
                    isCollection: isCollection))
            default: break
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVMultistatusTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVMultistatus.swift SottoTests/WebDAVMultistatusTests.swift
git commit -m "feat: WebDAVMultistatus — namespace-agnostic PROPFIND response parser"
```

---

### Task 4: WebDAVExecutor — FIFO pipeline, ops, status, test connection

**Files:**
- Create: `Sotto/Files/WebDAVExecutor.swift`
- Test: `SottoTests/WebDAVExecutorTests.swift` (create)

**Interfaces:**
- Consumes: `WebDAVConfig` (Task 1), `WebDAVClient`/`WebDAVTransport`/`WebDAVError` (Task 2), `SyncSegment` (existing, `Sotto/Files/TranscriptSyncSink.swift`), `NetworkMonitoring`/`WiFiMonitor` (existing, `Sotto/Transcription/NetworkMonitoring.swift`), `FakeNetworkMonitor` (existing, `SottoTests/Fakes.swift`).
- Produces:
  - `enum WebDAVStatus: Sendable { case idle, ok(Date), skippedWiFi(Date), failed(String, Date) }`
  - `enum WebDAVTestResult: Equatable, Sendable { case connected, unauthorized, notFound, failed(String) }`
  - `actor WebDAVExecutor` with `static let shared`, `init(transport:monitor:)`, `var lastOutcome: WebDAVStatus`, `func upsert(_ segment: SyncSegment, config: WebDAVConfig, wifiOnly: Bool)`, `func remove(day: String, basename: String, config: WebDAVConfig, wifiOnly: Bool)`, `func testConnection(config: WebDAVConfig) async -> WebDAVTestResult`, `func drain() async` (test sync). Also internal `runSerialized` used by Task 6.

- [ ] **Step 1: Write the failing tests**

`SottoTests/WebDAVExecutorTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct WebDAVExecutorTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebDAVExecutor-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<root>/<day>/<name>.md [+ .m4a]`; returns the SyncSegment (same shape the fan-out builds).
    private func makeSegment(
        root: URL, day: String = "2026-07-07", name: String = "09-15-00", m4a: Bool = true
    ) throws -> SyncSegment {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4aURL = dayDir.appendingPathComponent("\(name).m4a")
        if m4a { try Data([0x01]).write(to: m4aURL) }
        try "transcript".write(
            to: dayDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        return SyncSegment(m4aURL: m4aURL)
    }

    private func executor(
        _ transport: FakeWebDAVTransport, wifi: Bool = true
    ) -> WebDAVExecutor {
        WebDAVExecutor(transport: transport, monitor: FakeNetworkMonitor(isOnWiFi: wifi))
    }

    @Test func upsertPutsMarkdownOnlyWhenAudioDisabled() async throws {
        let transport = FakeWebDAVTransport()
        let executor = executor(transport)
        let segment = try makeSegment(root: tempDir())

        executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        let recorded = await transport.recorded
        #expect(recorded.map(\.method) == ["PUT"])
        #expect(recorded[0].url.absoluteString
            == "https://dav.example.com/files/connor/Sotto/2026-07-07/09-15-00.md")
        if case .ok = await executor.lastOutcome {} else {
            Issue.record("expected .ok, got \(await executor.lastOutcome)")
        }
    }

    @Test func upsertAlsoPutsAudioWhenEnabled() async throws {
        let transport = FakeWebDAVTransport()
        let executor = executor(transport)
        let segment = try makeSegment(root: tempDir())

        executor.upsert(segment, config: makeWebDAVConfig(audio: true), wifiOnly: false)
        await executor.drain()

        let urls = await transport.recorded.map(\.url.lastPathComponent)
        #expect(urls == ["09-15-00.md", "09-15-00.m4a"])
    }

    @Test func upsertSelfHealsMissingDayVia409MkcolRetry() async throws {
        let transport = FakeWebDAVTransport(
            script: [.status(409), .status(201), .status(201)])
        let executor = executor(transport)
        let segment = try makeSegment(root: tempDir())

        executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        let recorded = await transport.recorded
        #expect(recorded.map(\.method) == ["PUT", "MKCOL", "PUT"])
        #expect(recorded[1].url.absoluteString
            == "https://dav.example.com/files/connor/Sotto/2026-07-07/")
        if case .ok = await executor.lastOutcome {} else {
            Issue.record("self-healed op should record .ok")
        }
    }

    @Test func removeDeletesBothExtensionsTolerating404() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(404))
        let executor = executor(transport)

        executor.remove(day: "2026-07-07", basename: "09-15-00",
                        config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        let recorded = await transport.recorded
        #expect(recorded.map(\.method) == ["DELETE", "DELETE"])
        #expect(recorded.map(\.url.lastPathComponent) == ["09-15-00.md", "09-15-00.m4a"])
        if case .ok = await executor.lastOutcome {} else {
            Issue.record("404s are tolerated — outcome must be .ok")
        }
    }

    @Test func opsExecuteStrictlyFIFO() async throws {
        // 204 is accepted by both PUT and DELETE; the default 201 fallback would make
        // DELETE throw server(201) and drop the second DELETE (execution-found bug).
        let transport = FakeWebDAVTransport(fallback: .status(204))
        let executor = executor(transport)
        let segment = try makeSegment(root: tempDir())
        let config = makeWebDAVConfig()

        // The resurrection race: upsert then immediate remove of the SAME path. FIFO must
        // hold the DELETE until the PUT completed.
        executor.upsert(segment, config: config, wifiOnly: false)
        executor.remove(day: segment.day, basename: segment.basename,
                        config: config, wifiOnly: false)
        await executor.drain()

        #expect(await transport.recorded.map(\.method) == ["PUT", "DELETE", "DELETE"])
    }

    @Test func wifiGateSkipsEventOpsAndRecordsIt() async throws {
        let transport = FakeWebDAVTransport()
        let executor = executor(transport, wifi: false)
        let segment = try makeSegment(root: tempDir())

        executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: true)
        await executor.drain()

        #expect(await transport.recorded.isEmpty)
        if case .skippedWiFi = await executor.lastOutcome {} else {
            Issue.record("expected .skippedWiFi")
        }
    }

    @Test func unauthorizedRecordsAuthenticationFailure() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(401))
        let executor = executor(transport)
        let segment = try makeSegment(root: tempDir())

        executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        if case .failed(let reason, _) = await executor.lastOutcome {
            #expect(reason == "authentication failed")
        } else {
            Issue.record("expected .failed")
        }
    }

    @Test func testConnectionMapsTheFourOutcomes() async throws {
        let cases: [(FakeWebDAVTransport.Scripted, WebDAVTestResult)] = [
            (.status(207), .connected),
            (.status(401), .unauthorized),
            (.status(404), .notFound),
            (.error(URLError(.cannotConnectToHost)), .failed("server unreachable")),
        ]
        for (scripted, expected) in cases {
            let executor = executor(FakeWebDAVTransport(fallback: scripted))
            #expect(await executor.testConnection(config: makeWebDAVConfig()) == expected)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVExecutorTests 2>&1 | tail -5`
Expected: build FAILURE — `WebDAVExecutor` not defined.

- [ ] **Step 3: Implement**

Create `Sotto/Files/WebDAVExecutor.swift`:

```swift
import Foundation

/// Settings status line: the executor's most recent outcome. In-memory, resets per launch
/// — a diagnostic, not a ledger. A success clears a failure.
enum WebDAVStatus: Sendable {
    case idle
    case ok(Date)
    case skippedWiFi(Date)
    case failed(String, Date)
}

/// Settings "Test connection" result — the view maps these to copy (design §5).
enum WebDAVTestResult: Equatable, Sendable {
    case connected
    case unauthorized
    case notFound
    case failed(String)
}

/// The single long-lived WebDAV pipeline (design §3). Strict FIFO — one operation
/// completes before the next starts — which is the entire fix for the PUT-vs-DELETE
/// resurrection race: sinks stay fresh-per-event (instant settings application), and this
/// actor is the state that must span events. Event-driven ops honor the Wi-Fi gate at
/// execution time; manual sweep/restore/test bypass it (explicit user intent) but still
/// serialize behind pending ops. Best-effort throughout: failures record `lastOutcome`
/// and drop the op — the "Back up now" sweep is the recovery path.
actor WebDAVExecutor {
    static let shared = WebDAVExecutor()

    // Immutable + Sendable, so the chained op tasks read them without actor hops
    // (nonisolated access to actor `let`s).
    private let transport: any WebDAVTransport
    private let monitor: any NetworkMonitoring

    private var tail: Task<Void, Never>?
    private(set) var lastOutcome: WebDAVStatus = .idle

    init(transport: any WebDAVTransport = URLSession.shared,
         monitor: any NetworkMonitoring = WiFiMonitor()) {
        self.transport = transport
        self.monitor = monitor
    }

    // MARK: Event-driven ops (fire-and-forget, Wi-Fi gated)

    /// Mirror a finalized conversation: PUT the .md, plus the .m4a when the config says so.
    func upsert(_ segment: SyncSegment, config: WebDAVConfig, wifiOnly: Bool) {
        schedule { [monitor = self.monitor, transport = self.transport] in
            if wifiOnly, !monitor.isOnWiFi { return .skippedWiFi }
            let client = WebDAVClient(config: config, transport: transport)
            do {
                try await Self.putCreatingDay(
                    client, base: config.baseURL, day: segment.day,
                    file: segment.markdown, contentType: "text/markdown")
                if config.audioEnabled, let audio = segment.audio {
                    try await Self.putCreatingDay(
                        client, base: config.baseURL, day: segment.day,
                        file: audio, contentType: "audio/mp4")
                }
                return .ok
            } catch {
                return .failure(error)
            }
        }
    }

    /// Propagate a deletion: both extensions, 404s tolerated by the client — `remove`
    /// carries no knowledge of whether audio was ever mirrored (design §4).
    func remove(day: String, basename: String, config: WebDAVConfig, wifiOnly: Bool) {
        schedule { [monitor = self.monitor, transport = self.transport] in
            if wifiOnly, !monitor.isOnWiFi { return .skippedWiFi }
            let client = WebDAVClient(config: config, transport: transport)
            let dayURL = config.baseURL.appendingPathComponent(day, isDirectory: true)
            do {
                try await client.delete(dayURL.appendingPathComponent("\(basename).md"))
                try await client.delete(dayURL.appendingPathComponent("\(basename).m4a"))
                return .ok
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: Manual ops (awaited, serialized, no Wi-Fi gate)

    /// Settings "Test connection": PROPFIND Depth 0 on the base. Doesn't touch
    /// `lastOutcome` — its result is reported inline in the form, not the status line.
    func testConnection(config: WebDAVConfig) async -> WebDAVTestResult {
        let transport = self.transport
        return await runSerialized {
            do {
                _ = try await WebDAVClient(config: config, transport: transport)
                    .propfind(config.baseURL, depth: 0)
                return .connected
            } catch WebDAVError.unauthorized {
                return .unauthorized
            } catch WebDAVError.notFound {
                return .notFound
            } catch {
                return .failed(Self.describe(error))
            }
        }
    }

    /// Test synchronization only: awaits everything enqueued so far.
    func drain() async {
        await tail?.value
    }

    // MARK: FIFO machinery

    private enum OpOutcome {
        case ok
        case skippedWiFi
        case failure(any Error)
    }

    /// Fire-and-forget FIFO enqueue: the sink returns immediately; the op runs after every
    /// previously enqueued op, then records its outcome. Enqueue order is actor-arrival
    /// order — event ops arrive seconds apart in practice, and the only same-instant
    /// multi-op event (merge) targets different paths, so relative order there is moot.
    private func schedule(_ work: @escaping @Sendable () async -> OpOutcome) {
        let previous = tail
        tail = Task { [previous] in
            await previous?.value
            let outcome = await work()
            self.record(outcome)   // Task{} inherits actor isolation — await would warn
        }
    }

    /// Serialized-and-awaited, for manual ops: runs behind everything already queued and
    /// hands the result back. Task 6 builds sweep/restore on this.
    func runSerialized<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { [previous] in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func record(_ outcome: OpOutcome) {
        switch outcome {
        case .ok: lastOutcome = .ok(Date())
        case .skippedWiFi: lastOutcome = .skippedWiFi(Date())
        case .failure(let error): lastOutcome = .failed(Self.describe(error), Date())
        }
    }

    // MARK: Shared helpers (Task 6's sweep reuses both)

    /// PUT with the missing-day self-heal (design §4): try direct; on "parent collection
    /// missing" (RFC 4918 says 409; some servers answer 404) MKCOL the day and retry once.
    /// No proactive MKCOL and no created-days cache — this path heals every time, including
    /// when the server folder is deleted externally mid-run.
    static func putCreatingDay(
        _ client: WebDAVClient, base: URL, day: String, file: URL, contentType: String
    ) async throws {
        let dayURL = base.appendingPathComponent(day, isDirectory: true)
        let target = dayURL.appendingPathComponent(file.lastPathComponent)
        do {
            try await client.putFile(file, to: target, contentType: contentType)
        } catch WebDAVError.conflict, WebDAVError.notFound {
            try await client.mkcol(dayURL)
            try await client.putFile(file, to: target, contentType: contentType)
        }
    }

    /// Status-line copy for the §4 error taxonomy.
    static func describe(_ error: any Error) -> String {
        switch error {
        case WebDAVError.unauthorized: "authentication failed"
        case WebDAVError.notFound: "folder not found"
        case WebDAVError.conflict: "folder could not be created"
        case WebDAVError.insufficientStorage: "server is full"
        case WebDAVError.server(let code): "server error (\(code))"
        case is URLError: "server unreachable"
        default: "network error"
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVExecutorTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVExecutor.swift SottoTests/WebDAVExecutorTests.swift
git commit -m "feat: WebDAVExecutor — FIFO pipeline, 409 self-heal, Wi-Fi gate, status line"
```

---

### Task 5: WebDAVSyncSink + registry wiring

**Files:**
- Create: `Sotto/Files/WebDAVSyncSink.swift`
- Modify: `Sotto/Files/TranscriptSyncSink.swift` (the `activeSinks` function, currently lines 51–59)
- Test: `SottoTests/WebDAVSyncSinkTests.swift` (create)

**Interfaces:**
- Consumes: `WebDAVConfig.load` (Task 1), `WebDAVExecutor` (Task 4), `TranscriptSyncSink`/`SyncSegment`/`SyncSinkRegistry` (existing).
- Produces: `struct WebDAVSyncSink: TranscriptSyncSink { let config: WebDAVConfig; let wifiOnly: Bool; var executor: WebDAVExecutor = .shared }`; `SyncSinkRegistry.activeSinks(_:keychain:)` gains a defaulted `keychain: KeychainStore = KeychainStore()` parameter (existing call sites unchanged) and appends the WebDAV sink when enabled + configured.

- [ ] **Step 1: Write the failing tests**

`SottoTests/WebDAVSyncSinkTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct WebDAVSyncSinkTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebDAVSink-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freshSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "sink-webdav-\(UUID().uuidString)")!)
    }

    private func freshKeychain() -> KeychainStore {
        KeychainStore(service: "webdav-sink-test-\(UUID().uuidString)")
    }

    private func configure(_ settings: SettingsStore, keychain: KeychainStore) {
        settings.webdavServerURL = "https://dav.example.com/files/connor/Sotto"
        settings.webdavUsername = "connor"
        keychain.set("secret", for: WebDAVConfig.passwordKeychainKey)
    }

    @Test func sinkForwardsUpsertAndRemoveToTheExecutor() async throws {
        let transport = FakeWebDAVTransport()
        let executor = WebDAVExecutor(
            transport: transport, monitor: FakeNetworkMonitor(isOnWiFi: true))
        let sink = WebDAVSyncSink(
            config: makeWebDAVConfig(), wifiOnly: false, executor: executor)

        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-07", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")
        try "t".write(to: dayDir.appendingPathComponent("09-15-00.md"),
                      atomically: true, encoding: .utf8)

        await sink.upsert(SyncSegment(m4aURL: m4a))
        await sink.remove(day: "2026-07-07", basename: "09-15-00")
        await executor.drain()

        #expect(await transport.recorded.map(\.method) == ["PUT", "DELETE", "DELETE"])
    }

    @Test func registryAppendsWebDAVSinkWhenConfiguredAndEnabled() {
        let settings = freshSettings()
        let keychain = freshKeychain()
        defer { keychain.delete(WebDAVConfig.passwordKeychainKey) }
        configure(settings, keychain: keychain)
        settings.wifiOnlyUpload = false

        let sinks = SyncSinkRegistry.activeSinks(settings, keychain: keychain)

        let webdav = sinks.compactMap { $0 as? WebDAVSyncSink }
        #expect(webdav.count == 1)
        #expect(webdav.first?.config.username == "connor")
        #expect(webdav.first?.wifiOnly == false)   // snapshots the setting per event
        // iCloud (default on) + WebDAV — both providers fan out.
        #expect(sinks.count == 2)
    }

    @Test func registryOmitsWebDAVWhenPausedOrUnconfigured() {
        let keychain = freshKeychain()
        defer { keychain.delete(WebDAVConfig.passwordKeychainKey) }

        let paused = freshSettings()
        configure(paused, keychain: keychain)
        paused.webdavEnabled = false
        #expect(SyncSinkRegistry.activeSinks(paused, keychain: keychain)
            .compactMap { $0 as? WebDAVSyncSink }.isEmpty)

        let unconfigured = freshSettings()   // nothing saved at all
        #expect(SyncSinkRegistry.activeSinks(unconfigured, keychain: freshKeychain())
            .compactMap { $0 as? WebDAVSyncSink }.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVSyncSinkTests 2>&1 | tail -5`
Expected: build FAILURE — `WebDAVSyncSink` not defined; `activeSinks` has no `keychain:` parameter.

- [ ] **Step 3: Implement**

Create `Sotto/Files/WebDAVSyncSink.swift`:

```swift
import Foundation

/// WebDAV backup (design 2026-07-09): the first additional provider behind the sink seam.
/// Fresh per event like every sink — so settings changes apply on the very next event —
/// with all I/O forwarded to the shared WebDAVExecutor, whose strict FIFO prevents a
/// DELETE racing a slow PUT from resurrecting a deleted file on the server. `wifiOnly`
/// is snapshotted from settings at construction (per event), checked at execution.
struct WebDAVSyncSink: TranscriptSyncSink {
    let config: WebDAVConfig
    let wifiOnly: Bool
    var executor: WebDAVExecutor = .shared

    func upsert(_ segment: SyncSegment) async {
        await executor.upsert(segment, config: config, wifiOnly: wifiOnly)
    }

    func remove(day: String, basename: String) async {
        await executor.remove(day: day, basename: basename, config: config, wifiOnly: wifiOnly)
    }
}
```

In `Sotto/Files/TranscriptSyncSink.swift`, replace the `activeSinks` function body:

```swift
    static func activeSinks(
        _ settings: SettingsStore, keychain: KeychainStore = KeychainStore()
    ) -> [any TranscriptSyncSink] {
        #if DEBUG
        if let testSinks { return testSinks }
        #endif
        var sinks: [any TranscriptSyncSink] = []
        if settings.iCloudBackupEnabled { sinks.append(ICloudSyncSink()) }
        if settings.webdavEnabled, let config = WebDAVConfig.load(settings: settings, keychain: keychain) {
            sinks.append(WebDAVSyncSink(config: config, wifiOnly: settings.wifiOnlyUpload))
        }
        // Later phases append here: GoogleDriveSyncSink(...)
        return sinks
    }
```

(The `keychain` parameter exists so tests can isolate Keychain state per test; the two
static fan-out helpers `upsert(m4aURL:_:)`/`remove(m4aURL:_:)` keep calling
`activeSinks(settings)` and pick up the default.)

- [ ] **Step 4: Run the new suite AND the existing sink suites (regression)**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVSyncSinkTests -only-testing:SottoTests/SyncFanOutTests -only-testing:SottoTests/SyncSegmentTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVSyncSink.swift Sotto/Files/TranscriptSyncSink.swift SottoTests/WebDAVSyncSinkTests.swift
git commit -m "feat: WebDAVSyncSink + registry wiring behind webdavEnabled/config"
```

---

### Task 6: Sweep (backupAll) + restore on the executor

**Files:**
- Modify: `Sotto/Files/WebDAVExecutor.swift` (append the two manual ops)
- Test: `SottoTests/WebDAVExecutorTests.swift` (append tests)

**Interfaces:**
- Consumes: `runSerialized`/`putCreatingDay`/`record` (Task 4), `WebDAVMultistatus` (Task 3), `DayIndexStore` (existing actor — `init(rootDirectory:)`, `func rebuildAndPersist(dayDirectory: URL) -> DayIndex`, `func index(forDay:)`).
- Produces: `func backupAll(localRoot: URL, config: WebDAVConfig) async -> (transcripts: Int, audio: Int)`; `func restore(localRoot: URL, config: WebDAVConfig, dayIndex: DayIndexStore) async -> Int`.

- [ ] **Step 1: Write the failing tests** (append to `WebDAVExecutorTests`)

```swift
    // MARK: Sweep + restore (Task 6)

    @Test func backupAllSweepsTranscriptsAndSkipsInternalFiles() async throws {
        let transport = FakeWebDAVTransport()
        // Wi-Fi off + wifiOnlyUpload is irrelevant: manual ops bypass the gate.
        let executor = executor(transport, wifi: false)
        let root = tempDir()
        _ = try makeSegment(root: root, day: "2026-07-05", name: "09-15-00")
        _ = try makeSegment(root: root, day: "2026-07-06", name: "11-00-00")
        let day = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try Data().write(to: day.appendingPathComponent("_day.json"))
        try Data().write(to: day.appendingPathComponent("stray.caf"))

        let counts = await executor.backupAll(localRoot: root, config: makeWebDAVConfig())

        #expect(counts.transcripts == 2)
        #expect(counts.audio == 0)
        let names = Set(await transport.recorded.map(\.url.lastPathComponent))
        #expect(names == ["09-15-00.md", "11-00-00.md"])   // no _day.json, no .caf, no .m4a
    }

    @Test func backupAllIncludesAudioWhenEnabled() async throws {
        let transport = FakeWebDAVTransport()
        let executor = executor(transport)
        let root = tempDir()
        _ = try makeSegment(root: root, day: "2026-07-05", name: "09-15-00")

        let counts = await executor.backupAll(
            localRoot: root, config: makeWebDAVConfig(audio: true))

        #expect(counts.transcripts == 1)
        #expect(counts.audio == 1)
        let names = Set(await transport.recorded.map(\.url.lastPathComponent))
        #expect(names == ["09-15-00.md", "09-15-00.m4a"])
    }

    /// Multistatus for the base: the base itself, one day collection, one foreign file.
    private func baseListing() -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/files/connor/Sotto/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/passwords.txt</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
    }

    /// Multistatus for the day: two shaped transcripts + one foreign file.
    private func dayListing() -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/files/connor/Sotto/2026-07-05/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/09-15-00.md</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/10-30-00.md</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/readme.txt</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
    }

    /// Minimal valid transcript (frontmatter parseable by DayIndexRebuilder).
    private func transcriptBody(iso: String) -> String {
        """
        ---
        date: \(iso)
        duration: 12.0
        backend: speechAnalyzer
        title: Restored chat
        ---

        **Speaker 0:** hello there
        """
    }

    @Test func restoreFetchesOnlyMissingShapedFilesAndRebuildsIndex() async throws {
        let root = tempDir()
        // 10-30-00 already exists locally — restore must not overwrite or re-fetch it.
        let localDay = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try FileManager.default.createDirectory(at: localDay, withIntermediateDirectories: true)
        try "LOCAL WINS".write(to: localDay.appendingPathComponent("10-30-00.md"),
                               atomically: true, encoding: .utf8)

        let transport = FakeWebDAVTransport(script: [
            .status(207, baseListing()),   // PROPFIND base, depth 1
            .status(207, dayListing()),    // PROPFIND 2026-07-05, depth 1
            .status(200, Data(transcriptBody(iso: "2026-07-05T09:15:00Z").utf8)),  // GET 09-15-00.md
        ])
        let executor = executor(transport)
        let dayIndex = DayIndexStore(rootDirectory: root)

        let restored = await executor.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: dayIndex)

        #expect(restored == 1)
        let methods = await transport.recorded.map(\.method)
        #expect(methods == ["PROPFIND", "PROPFIND", "GET"])   // exactly one GET — the missing file
        #expect(try String(contentsOf: localDay.appendingPathComponent("10-30-00.md"),
                           encoding: .utf8) == "LOCAL WINS")
        let index = await dayIndex.index(forDay: localDay)
        #expect(index?.segments.contains { $0.hasAudio == false } == true)
    }

    @Test func restoreSecondRunIsANoOp() async throws {
        let root = tempDir()
        let script: [FakeWebDAVTransport.Scripted] = [
            .status(207, baseListing()),
            .status(207, dayListing()),
            .status(200, Data(transcriptBody(iso: "2026-07-05T09:15:00Z").utf8)),
            .status(200, Data(transcriptBody(iso: "2026-07-05T10:30:00Z").utf8)),
        ]
        let transport = FakeWebDAVTransport(script: script)
        let executor = executor(transport)
        let dayIndex = DayIndexStore(rootDirectory: root)

        let first = await executor.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: dayIndex)
        #expect(first == 2)

        // Fresh transport/script; same local state — everything already present.
        let transport2 = FakeWebDAVTransport(script: [
            .status(207, baseListing()), .status(207, dayListing()),
        ])
        let executor2 = WebDAVExecutor(
            transport: transport2, monitor: FakeNetworkMonitor(isOnWiFi: true))
        let second = await executor2.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: dayIndex)

        #expect(second == 0)
        #expect(await transport2.recorded.map(\.method) == ["PROPFIND", "PROPFIND"])   // no GETs
    }

    @Test func restoreSurvivesAnUnreachableServer() async throws {
        let transport = FakeWebDAVTransport(fallback: .error(URLError(.cannotConnectToHost)))
        let executor = executor(transport)
        let root = tempDir()
        let restored = await executor.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: DayIndexStore(rootDirectory: root))
        #expect(restored == 0)
    }
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVExecutorTests 2>&1 | tail -5`
Expected: build FAILURE — `backupAll`/`restore` not defined on `WebDAVExecutor`.

- [ ] **Step 3: Implement** (append to `WebDAVExecutor`, after `testConnection`)

```swift
    /// Settings "Back up now" (design §6): first-configure backfill, audio-toggle backfill,
    /// and the universal recovery path. Walks `<localRoot>/<day>/` two levels (the store
    /// layout is exactly two levels; skips `_day.json`/`.caf` by extension), PUTs every
    /// .md — and .m4a when the config says so. Per-file failures skip and continue; the
    /// first failure decides the recorded status.
    func backupAll(localRoot: URL, config: WebDAVConfig) async -> (transcripts: Int, audio: Int) {
        let transport = self.transport
        return await runSerialized {
            let client = WebDAVClient(config: config, transport: transport)
            var transcripts = 0, audio = 0
            var firstFailure: (any Error)?
            let days = (try? FileManager.default.contentsOfDirectory(
                at: localRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for day in days {
                guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let files = try? FileManager.default.contentsOfDirectory(
                          at: day, includingPropertiesForKeys: nil) else { continue }
                for file in files {
                    let contentType: String? = switch file.pathExtension {
                    case "md": "text/markdown"
                    case "m4a" where config.audioEnabled: "audio/mp4"
                    default: nil   // _day.json, .caf, audio when disabled
                    }
                    guard let contentType else { continue }
                    do {
                        try await Self.putCreatingDay(
                            client, base: config.baseURL, day: day.lastPathComponent,
                            file: file, contentType: contentType)
                        if contentType == "text/markdown" { transcripts += 1 } else { audio += 1 }
                    } catch {
                        if firstFailure == nil { firstFailure = error }
                    }
                }
            }
            await self.record(firstFailure.map { .failure($0) } ?? .ok)
            return (transcripts, audio)
        }
    }

    /// Settings "Restore from server" (design §6): additive, idempotent, transcripts only.
    /// Depth-1 PROPFIND walk (never infinity — servers commonly disable it); only
    /// Sotto-shaped paths (`yyyy-MM-dd/HH-mm-ss.md`) are considered — foreign files are
    /// invisible, which is what makes "exact URL, no subfolder" safe. Never overwrites a
    /// local file; rebuilds `_day.json` per touched day (restored conversations get
    /// hasAudio = false from the rebuilder — audio is not restored, same asymmetry as
    /// iCloud). Doesn't touch `lastOutcome`: its result is reported inline.
    func restore(localRoot: URL, config: WebDAVConfig, dayIndex: DayIndexStore) async -> Int {
        let transport = self.transport
        return await runSerialized {
            let client = WebDAVClient(config: config, transport: transport)
            guard let baseData = try? await client.propfind(config.baseURL, depth: 1)
            else { return 0 }

            let basePath = Self.normalizedPath(config.baseURL.path)
            let days = WebDAVMultistatus.parse(baseData).filter { entry in
                entry.isCollection
                    && Self.normalizedPath(entry.href) != basePath   // skip the base itself
                    && Self.lastComponent(entry.href)
                        .wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
            }

            var restored = 0
            var touchedDays: Set<String> = []
            for dayEntry in days {
                let day = Self.lastComponent(dayEntry.href)
                let dayURL = config.baseURL.appendingPathComponent(day, isDirectory: true)
                guard let listing = try? await client.propfind(dayURL, depth: 1)
                else { continue }
                let files = WebDAVMultistatus.parse(listing).filter { entry in
                    !entry.isCollection
                        && Self.lastComponent(entry.href)
                            .wholeMatch(of: /\d{2}-\d{2}-\d{2}\.md/) != nil
                }
                for file in files {
                    let name = Self.lastComponent(file.href)
                    let localDay = localRoot.appendingPathComponent(day, isDirectory: true)
                    let localMD = localDay.appendingPathComponent(name)
                    guard !FileManager.default.fileExists(atPath: localMD.path)
                    else { continue }   // never overwrite — local is canonical
                    guard let data = try? await client.get(
                        dayURL.appendingPathComponent(name)) else { continue }
                    try? FileManager.default.createDirectory(
                        at: localDay, withIntermediateDirectories: true)
                    guard (try? data.write(to: localMD)) != nil else { continue }
                    restored += 1
                    touchedDays.insert(day)
                }
            }

            for day in touchedDays {
                _ = await dayIndex.rebuildAndPersist(
                    dayDirectory: localRoot.appendingPathComponent(day, isDirectory: true))
            }
            return restored
        }
    }

    /// "/a/b/" and "/a/b" are the same collection.
    private static func normalizedPath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func lastComponent(_ href: String) -> String {
        href.split(separator: "/").last.map(String.init) ?? ""
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVExecutorTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVExecutor.swift SottoTests/WebDAVExecutorTests.swift
git commit -m "feat: WebDAV backupAll sweep + additive shape-filtered restore"
```

---

### Task 7: AppModel entry points + Settings UI

**Files:**
- Modify: `Sotto/App/AppModel.swift` (add four entry points after `iCloudAvailable()`, ~line 543)
- Create: `Sotto/App/WebDAVSettingsView.swift`
- Modify: `Sotto/App/SettingsView.swift` (one `@State`, one `.task` line, one row in `backupSection`)

**Interfaces:**
- Consumes: `WebDAVConfig.load` (Task 1), `WebDAVExecutor.shared` + `backupAll`/`restore`/`testConnection`/`lastOutcome` (Tasks 4/6), `WebDAVStatus`/`WebDAVTestResult` (Task 4), `KeychainStore`, `AppModel.segmentRoot`/`dayIndex`/`settings`/`loadInitialHistory()` (existing — same pattern as `restoreFromICloud` at `Sotto/App/AppModel.swift:514`).
- Produces: `AppModel.backupAllToWebDAV() async -> (transcripts: Int, audio: Int)`, `.restoreFromWebDAV() async -> Int`, `.testWebDAVConnection() async -> WebDAVTestResult`, `.webdavStatus() async -> WebDAVStatus`; `struct WebDAVSettingsView: View` (exposes `static func describe(_ status: WebDAVStatus) -> String` for the status line).

- [ ] **Step 1: Add the AppModel entry points** (after `iCloudAvailable()`)

```swift
    /// Settings "Back up now" (WebDAV): sweep every local transcript (+ audio when enabled)
    /// onto the configured server. Serialized behind pending event ops on the executor;
    /// bypasses the Wi-Fi gate (explicit user intent). Not configured → (0, 0).
    func backupAllToWebDAV() async -> (transcripts: Int, audio: Int) {
        guard let config = WebDAVConfig.load(settings: settings) else { return (0, 0) }
        return await WebDAVExecutor.shared.backupAll(localRoot: segmentRoot, config: config)
    }

    /// Settings "Restore from server": additive hydrate, then reload history — same
    /// reasoning as restoreFromICloud (restored days can predate the incremental refresh).
    func restoreFromWebDAV() async -> Int {
        guard let dayIndex, let config = WebDAVConfig.load(settings: settings) else { return 0 }
        let restored = await WebDAVExecutor.shared.restore(
            localRoot: segmentRoot, config: config, dayIndex: dayIndex)
        if restored > 0 { await loadInitialHistory() }
        return restored
    }

    /// Settings "Test connection": PROPFIND Depth 0 against the saved base URL.
    func testWebDAVConnection() async -> WebDAVTestResult {
        guard let config = WebDAVConfig.load(settings: settings) else {
            return .failed("not configured")
        }
        return await WebDAVExecutor.shared.testConnection(config: config)
    }

    /// The executor's last outcome, for the Settings status line.
    func webdavStatus() async -> WebDAVStatus {
        await WebDAVExecutor.shared.lastOutcome
    }
```

- [ ] **Step 2: Create `Sotto/App/WebDAVSettingsView.swift`**

```swift
import SwiftUI

/// WebDAV backup configuration (design 2026-07-09 §5): the first "additional backup
/// provider" behind the sink seam. URL + username live in SettingsStore; the app password
/// lives in the Keychain. Save is explicit (a button), never per-keystroke — the
/// persistKey() lesson. Test connection is an affordance, not a gate on saving.
struct WebDAVSettingsView: View {
    let model: AppModel

    @State private var serverURL = ""
    @State private var username = ""
    @State private var appPassword = ""
    @State private var enabled = true
    @State private var audioBackup = false
    @State private var configured = false
    @State private var formNote: String?
    @State private var statusLine = "—"
    @State private var backupResult: String?
    @State private var restoreResult: String?
    @State private var showForgetConfirm = false

    var body: some View {
        Form {
            serverSection
            if configured {
                optionsSection
                actionsSection
                forgetSection
            }
        }
        .navigationTitle("WebDAV server")
        .task { await load() }
    }

    private func load() async {
        let settings = model.settings
        serverURL = settings.webdavServerURL ?? ""
        username = settings.webdavUsername ?? ""
        appPassword = KeychainStore().get(WebDAVConfig.passwordKeychainKey) ?? ""
        enabled = settings.webdavEnabled
        audioBackup = settings.webdavAudioBackup
        configured = WebDAVConfig.load(settings: settings) != nil
        statusLine = Self.describe(await model.webdavStatus())
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("https://cloud.example.com/…", text: $serverURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Username", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("App password", text: $appPassword)
            Button("Save") { save() }
            Button("Test connection") { Task { await testConnection() } }
                .disabled(!configured)
            if let formNote {
                Text(formNote).font(.caption).foregroundStyle(.secondary)
            }
            Text("Paste the WebDAV URL of the folder backups should land in — day folders are created directly inside it. Generate an app password in your server's security settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// HTTPS-only enforced HERE with copy, not just silently at WebDAVConfig.load — a
    /// plain-http URL should fail loudly at save, not mysteriously at request time.
    private func save() {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme?.lowercased() == "https" else {
            formNote = "Enter an https:// URL — Sotto only connects over TLS."
            return
        }
        guard !trimmedUser.isEmpty, !appPassword.isEmpty else {
            formNote = "Username and app password are required."
            return
        }
        _ = url
        model.settings.webdavServerURL = trimmedURL
        model.settings.webdavUsername = trimmedUser
        KeychainStore().set(appPassword, for: WebDAVConfig.passwordKeychainKey)
        configured = WebDAVConfig.load(settings: model.settings) != nil
        formNote = "Saved."
    }

    private func testConnection() async {
        formNote = "Testing…"
        formNote = switch await model.testWebDAVConnection() {
        case .connected:
            "Connected."
        case .unauthorized:
            "Server reached, but username or app password was rejected."
        case .notFound:
            "Folder not found — check the URL or create the folder on your server."
        case .failed(let reason):
            "Connection failed — \(reason)."
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Back up to this server", isOn: $enabled)
                .onChange(of: enabled) { _, value in model.settings.webdavEnabled = value }
            Toggle("Also back up audio", isOn: $audioBackup)
                .onChange(of: audioBackup) { _, value in model.settings.webdavAudioBackup = value }
            Text("Transcripts (and audio, if enabled) are copied to your own server. Nothing else leaves this device. Turning backup off pauses it — files already on the server stay.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            LabeledContent("Status", value: statusLine)
            Button("Back up now") {
                backupResult = "Backing up…"
                Task {
                    let counts = await model.backupAllToWebDAV()
                    let t = counts.transcripts, a = counts.audio
                    backupResult = audioBackup
                        ? "Backed up \(t) transcript\(t == 1 ? "" : "s"), \(a) audio file\(a == 1 ? "" : "s")."
                        : "Backed up \(t) transcript\(t == 1 ? "" : "s")."
                    statusLine = Self.describe(await model.webdavStatus())
                }
            }
            if let backupResult {
                Text(backupResult).font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore from server") {
                restoreResult = "Restoring…"
                Task {
                    let n = await model.restoreFromWebDAV()
                    restoreResult = n > 0
                        ? "Restored \(n) transcript\(n == 1 ? "" : "s")."
                        : "Nothing new to restore."
                }
            }
            if let restoreResult {
                Text(restoreResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var forgetSection: some View {
        Section {
            Button("Forget this server", role: .destructive) { showForgetConfirm = true }
                .confirmationDialog("Forget this server?", isPresented: $showForgetConfirm) {
                    Button("Forget", role: .destructive) { forget() }
                } message: {
                    Text("Removes the server settings and app password from this device. Files already on the server are not touched.")
                }
        }
    }

    /// Clears local config only — deliberately NO destructive remote wipe (design §2:
    /// the user fully controls their own server, unlike the invisible iCloud container).
    private func forget() {
        model.settings.webdavServerURL = nil
        model.settings.webdavUsername = nil
        model.settings.webdavEnabled = true        // back to defaults
        model.settings.webdavAudioBackup = false
        KeychainStore().delete(WebDAVConfig.passwordKeychainKey)
        serverURL = ""; username = ""; appPassword = ""
        enabled = true; audioBackup = false
        configured = false
        backupResult = nil; restoreResult = nil
        formNote = "Server forgotten."
    }

    /// Status-line copy for the executor's last outcome (design §5).
    static func describe(_ status: WebDAVStatus) -> String {
        switch status {
        case .idle:
            "No backups attempted yet"
        case .ok(let date):
            "Last backup \(date.formatted(date: .omitted, time: .shortened))"
        case .skippedWiFi:
            "Skipped — waiting for Wi-Fi"
        case .failed(let reason, _):
            "Failed — \(reason)"
        }
    }
}
```

- [ ] **Step 3: Add the row to `SettingsView.backupSection`**

Add one `@State` alongside the other iCloud state vars (`Sotto/App/SettingsView.swift:21-28`):

```swift
    @State private var webdavHost = "Not configured"
```

In the `.task` block (after `iCloudHasBackups = await model.iCloudHasBackups()`):

```swift
            webdavHost = settings.webdavServerURL
                .flatMap { URL(string: $0)?.host() } ?? "Not configured"
```

At the end of `backupSection`'s `Section("Backup & Restore")` (after the `if iCloudHasBackups` block):

```swift
            // WebDAV phase (design 2026-07-09): the first "additional backup provider" row.
            // A NavigationLink per provider IS the reserved dropdown shape — Google Drive
            // later adds a second row, not a menu rework.
            NavigationLink {
                WebDAVSettingsView(model: model)
            } label: {
                LabeledContent("WebDAV server", value: webdavHost)
            }
```

- [ ] **Step 4: `xcodegen generate`, build, run the FULL suite**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, zero new warnings (check the build log section above the tail if in doubt: `2>&1 | grep -c "warning:"` should match main's count).

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/AppModel.swift Sotto/App/WebDAVSettingsView.swift Sotto/App/SettingsView.swift
git commit -m "feat: WebDAV Settings screen + AppModel backup/restore/test entry points"
```

---

### Task 8: Full verification + manual pass against the real server

**Files:**
- Modify (only if drift was found): `docs/superpowers/specs/2026-07-09-webdav-backup-design.md`, this plan.

- [ ] **Step 1: Full suite, clean**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Manual verification (simulator or device, real OpenCloud server)**

1. Settings → Backup & Restore → WebDAV server: paste the real WebDAV collection URL, username, app password → Save → **Test connection** → "Connected."
2. Deliberately break the password → Test connection → the auth-rejected message; fix it back.
3. Record a short segment; after transcription completes, confirm `<day>/<basename>.md` appears on the server (OpenCloud web UI).
4. Enable "Also back up audio" → **Back up now** → counts reported; `.m4a` files appear, `_day.json`/`.caf` do not.
5. Delete a conversation in Sotto → its files disappear from the server.
6. Erase simulator content (or fresh install) → reconfigure the server → **Restore from server** → transcripts return, appear in history with no audio; second tap reports "Nothing new to restore."
7. Status line: after step 3 shows "Last backup HH:MM"; with Wi-Fi-only on and Wi-Fi off (device test), shows "Skipped — waiting for Wi-Fi".

- [ ] **Step 3: Close out**

If implementation drifted from the spec, fold the corrections into the spec/plan (repo convention: `docs: fold <what> into <where>`), commit, and hand off per the finishing-a-development-branch skill.

---

## Plan Self-Review (done at write time)

- **Spec coverage:** §2 locked decisions → Tasks 1 (credentials split, defaults), 2 (HTTPS/Basic/verbs), 4 (FIFO, Wi-Fi gate, status, no remote wipe), 5 (pause toggle registry behavior), 6 (sweep backfill, additive shape-filtered restore, manual-bypass), 7 (Settings UX, test-connection copy, forget). §3 architecture → Tasks 1/2/4/5. §4 op semantics → Tasks 2/4. §5 settings → Task 7. §6 sweep/restore → Task 6. §7 testing strategy → each task's tests + Task 8 manual pass. §8 follow-ups → none implemented (correct).
- **Deviation from spec (deliberate):** `WebDAVConfig` gets its own file (`WebDAVConfig.swift`) instead of living in `WebDAVSyncSink.swift` — the client (Task 2) depends on it before the sink (Task 5) exists. Also `WebDAVError` gained `.conflict` (409), which the spec's enum omitted but its §4 self-heal requires.
- **Type consistency check:** `WebDAVConfig(baseURL:username:password:audioEnabled:)`, `WebDAVClient(config:transport:)`, `putFile(_:to:contentType:)`, `WebDAVExecutor.upsert(_:config:wifiOnly:)`, `backupAll(localRoot:config:) -> (transcripts: Int, audio: Int)`, `restore(localRoot:config:dayIndex:) -> Int`, `activeSinks(_:keychain:)` — verified identical across all tasks above.
