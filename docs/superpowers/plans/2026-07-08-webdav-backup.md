# WebDAV Backup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, outbound-only WebDAV backup — the second `TranscriptSyncSink` — that mirrors finalized `.md` transcripts to a user-configured self-hosted server (primary target: OpenCloud). Transcripts only (never audio), no restore (iCloud owns restore), plugged into the existing `SyncSinkRegistry` fan-out with no new AppModel choke points.

**Architecture:** A `WebDAVConfig` value (URL + username in `UserDefaults`, app password in Keychain) resolves the target. A thin `WebDAVClient` (injected `URLSession`, HTTP Basic, system-trust TLS) provides `mkcol`/`put`/`delete`/`check`, behind a `WebDAVClienting` protocol so the sink is testable without a network. `WebDAVSyncSink` mirrors `.md` via `MKCOL` (lazy day collection) + `PUT`, and removes via `DELETE`. `SyncSinkRegistry.activeSinks` appends it when configured and reachable under the Wi-Fi-only policy. Settings gets a WebDAV subsection with a "Test connection" affordance.

**Tech Stack:** Swift 6, SwiftUI, `URLSession` (+ `URLProtocol` stub in tests), Swift Testing (`import Testing`), xcodegen.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from the design (`docs/superpowers/specs/2026-07-08-webdav-backup-design.md`) and `project.yml`.

- **Swift 6.0**, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`. iOS deployment target **26.0**. **Zero new warnings.**
- **Contents:** `.md` transcripts ONLY — never audio (`.m4a`), `_day.json`, or `.caf`. **No audio backup exists in WebDAV** (design §2).
- **Direction:** outbound only — `PUT`/`DELETE`/`MKCOL`. No inbound pull/restore.
- **Layout:** `<baseURL>/<yyyy-MM-dd>/<basename>.md`, where `<baseURL>` is the user's full base collection URL, `<day>` is `yyyy-MM-dd`, `<basename>` is `HH-mm-ss`.
- **Best-effort contract:** every sink op is `async` and MUST NEVER throw into the caller, fail a transcription job, block the queue, delay a transition handler, or ride the main actor. Fan-out stays `Task.detached(priority: .utility)` (already so in `SyncSinkRegistry`).
- **Auth:** username + app password, HTTP Basic. URL + username in `UserDefaults` (`SettingsStore`); app password in Keychain (`KeychainStore`, service `com.decanlys.Sotto`, key `webDAVAppPassword`).
- **TLS:** system trust only — no `URLSession` delegate cert override, no self-signed bypass.
- **Opt-in:** `webDAVBackupEnabled` default **false**.
- **Bundle id / logger subsystem:** `com.decanlys.Sotto`.
- **Test command:** `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → expect `** TEST SUCCEEDED **`. **After creating ANY new file, run `xcodegen generate` before building** (the `.xcodeproj` is generated; xcodegen globs `Sotto/` and `SottoTests/`).
- **The `.xcodeproj` is gitignored** — regenerated via `xcodegen generate`, never committed. Do NOT `git add Sotto.xcodeproj`; stage only source/test/doc files.

---

## File Structure

**New production files** (all under `Sotto/Files/` unless noted):
- `WebDAVConfig.swift` — the resolved config value + `load(_:keychain:)`.
- `WebDAVClient.swift` — `WebDAVResult`, the `WebDAVClienting` protocol, and the real `WebDAVClient` (URLSession-backed).
- `WebDAVSyncSink.swift` — the `TranscriptSyncSink` conformer (`upsert`/`remove`).

**Modified production files:**
- `Sotto/Files/RetentionPolicy.swift` — add `webDAVBackupEnabled` (default off), `webDAVServerURL`, `webDAVUsername` accessors.
- `Sotto/Files/TranscriptSyncSink.swift` — append WebDAV to `SyncSinkRegistry.activeSinks` + the lazily-created `sharedMonitor`.
- `Sotto/App/AppModel.swift` — add `testWebDAVConnection(url:username:password:) async -> String`.
- `Sotto/App/SettingsView.swift` — add the WebDAV subsection to `backupSection`.

**Test files** (new, under `SottoTests/`):
- `WebDAVConfigTests.swift`
- `WebDAVClientTests.swift` (uses a `URLProtocol` stub)
- `WebDAVSyncSinkTests.swift` (uses a `RecordingWebDAVClient` fake)
- `SyncSinkRegistryWebDAVTests.swift` (WebDAV branch of `activeSinks`, injected monitor)
- `WebDAVConnectionTestTests.swift` (`AppModel.testWebDAVConnection` result→string mapping)

> **Registry test note:** `SyncSinkRegistry.testSinks` is a process-global mutated by `SyncFanOutTests` (a `@Suite(.serialized)`). The new `SyncSinkRegistryWebDAVTests` exercises `activeSinks` *without* touching `testSinks` (it builds real sinks from settings), so it does not race that suite. Do NOT set `testSinks` from the new suite.

---

## Task 1: `SettingsStore` WebDAV accessors

The persisted config surface: one enable bit (default off) + two non-secret strings. The app password is NOT here — it lives in Keychain (Task 2).

**Files:**
- Modify: `Sotto/Files/RetentionPolicy.swift` (add to the `extension SettingsStore` block, after `iCloudBackupEnabled` ~line 123)
- Test: `SottoTests/WebDAVConfigTests.swift` (created here; extended in Task 2)

**Interfaces:**
- Produces: `SettingsStore.webDAVBackupEnabled: Bool` (default false), `SettingsStore.webDAVServerURL: String?`, `SettingsStore.webDAVUsername: String?` — all get/nonmutating set. Read by `WebDAVConfig.load` (Task 2) and `SyncSinkRegistry` (Task 5).

- [ ] **Step 1: Write the failing test**

Create `SottoTests/WebDAVConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct WebDAVConfigTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "webdav-config-\(UUID().uuidString)")!
    }

    @Test func backupEnabledDefaultsOffAndRoundTrips() {
        let settings = SettingsStore(defaults: freshSuite())
        #expect(settings.webDAVBackupEnabled == false)   // opt-in: default off
        settings.webDAVBackupEnabled = true
        #expect(settings.webDAVBackupEnabled == true)
    }

    @Test func urlAndUsernameRoundTripAndDefaultNil() {
        let settings = SettingsStore(defaults: freshSuite())
        #expect(settings.webDAVServerURL == nil)
        #expect(settings.webDAVUsername == nil)
        settings.webDAVServerURL = "https://cloud.example.com/remote.php/dav/files/alice/Sotto"
        settings.webDAVUsername = "alice"
        #expect(settings.webDAVServerURL == "https://cloud.example.com/remote.php/dav/files/alice/Sotto")
        #expect(settings.webDAVUsername == "alice")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVConfigTests 2>&1 | tail -5`
Expected: FAIL — `value of type 'SettingsStore' has no member 'webDAVBackupEnabled'`.

- [ ] **Step 3: Add the accessors**

In `Sotto/Files/RetentionPolicy.swift`, inside `extension SettingsStore`, after `iCloudBackupEnabled`:

```swift
    /// WebDAV backup phase (design 2026-07-08): whether finalized transcripts also mirror to a
    /// user-configured WebDAV server. Default OFF (opt-in) — iCloud is the default backup; WebDAV
    /// is deliberate self-hoster config. `bool(forKey:)` already returns false when unset.
    var webDAVBackupEnabled: Bool {
        get { defaults.bool(forKey: "webDAVBackupEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "webDAVBackupEnabled") }
    }

    /// The user's full base collection URL (e.g. https://host/remote.php/dav/files/alice/Sotto).
    /// Not secret → UserDefaults; the app password is Keychain-held (see WebDAVConfig).
    var webDAVServerURL: String? {
        get { defaults.string(forKey: "webDAVServerURL") }
        nonmutating set { defaults.set(newValue, forKey: "webDAVServerURL") }
    }

    var webDAVUsername: String? {
        get { defaults.string(forKey: "webDAVUsername") }
        nonmutating set { defaults.set(newValue, forKey: "webDAVUsername") }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVConfigTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/RetentionPolicy.swift SottoTests/WebDAVConfigTests.swift
git commit -m "feat: SettingsStore WebDAV accessors (enabled/url/username)"
```

---

## Task 2: `WebDAVConfig` — resolved, validated target

The value the sink and client carry. `load` returns non-nil only when everything needed to actually talk to the server is present, so "not configured" is a clean nil rather than a half-built request.

**Files:**
- Create: `Sotto/Files/WebDAVConfig.swift`
- Test: extend `SottoTests/WebDAVConfigTests.swift`

**Interfaces:**
- Consumes: `SettingsStore` (Task 1), `KeychainStore` (existing, `Sotto/Transcription/KeychainStore.swift`).
- Produces: `struct WebDAVConfig: Sendable { let baseURL: URL; let username: String; let appPassword: String }` + `static func load(_ settings: SettingsStore, keychain: KeychainStore = KeychainStore()) -> WebDAVConfig?`.
- Consumed by: `WebDAVClient` (Task 3), `SyncSinkRegistry` (Task 5), `AppModel.testWebDAVConnection` (Task 6).

- [ ] **Step 1: Write the failing tests**

Append to `SottoTests/WebDAVConfigTests.swift`:

```swift
    // --- WebDAVConfig.load ---

    /// A KeychainStore against a per-test service so the app password doesn't leak between runs.
    private func scopedKeychain() -> KeychainStore { KeychainStore(service: "webdav-test-\(UUID().uuidString)") }

    @Test func loadNilWhenDisabled() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.webDAVServerURL = "https://h/dav/Sotto"
        settings.webDAVUsername = "alice"
        let kc = scopedKeychain(); kc.set("pw", for: "webDAVAppPassword")
        #expect(WebDAVConfig.load(settings, keychain: kc) == nil)   // enabled == false
    }

    @Test func loadNilWhenAnyFieldMissing() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.webDAVBackupEnabled = true
        let kc = scopedKeychain()
        // No URL / username / password yet.
        #expect(WebDAVConfig.load(settings, keychain: kc) == nil)
        settings.webDAVServerURL = "https://h/dav/Sotto"
        #expect(WebDAVConfig.load(settings, keychain: kc) == nil)   // still no username/pw
        settings.webDAVUsername = "alice"
        #expect(WebDAVConfig.load(settings, keychain: kc) == nil)   // still no password
    }

    @Test func loadNilWhenURLUnparseable() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.webDAVBackupEnabled = true
        settings.webDAVServerURL = "not a url"
        settings.webDAVUsername = "alice"
        let kc = scopedKeychain(); kc.set("pw", for: "webDAVAppPassword")
        #expect(WebDAVConfig.load(settings, keychain: kc) == nil)
    }

    @Test func loadSucceedsWithEverythingPresent() throws {
        let settings = SettingsStore(defaults: freshSuite())
        settings.webDAVBackupEnabled = true
        settings.webDAVServerURL = "https://cloud.example.com/remote.php/dav/files/alice/Sotto"
        settings.webDAVUsername = "alice"
        let kc = scopedKeychain(); kc.set("app-pw", for: "webDAVAppPassword")

        let config = try #require(WebDAVConfig.load(settings, keychain: kc))
        #expect(config.baseURL.absoluteString == "https://cloud.example.com/remote.php/dav/files/alice/Sotto")
        #expect(config.username == "alice")
        #expect(config.appPassword == "app-pw")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVConfigTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'WebDAVConfig' in scope`.

- [ ] **Step 3: Create `WebDAVConfig.swift`**

```swift
import Foundation

/// A complete, validated WebDAV backup target (design 2026-07-08). Constructed only when backup
/// is enabled AND base URL + username + app password are all present and the URL parses — a nil
/// `load` means "WebDAV not configured", so the sink is simply not assembled. Carries the secret
/// as a value so the sink needs no Keychain access on the hot path.
struct WebDAVConfig: Sendable, Equatable {
    let baseURL: URL       // the user's full base collection URL
    let username: String
    let appPassword: String

    /// Resolves from settings (URL + username in UserDefaults) + Keychain (app password, key
    /// `webDAVAppPassword`). The Keychain read is fast/sync — safe to call from `activeSinks`.
    static func load(_ settings: SettingsStore, keychain: KeychainStore = KeychainStore()) -> WebDAVConfig? {
        guard settings.webDAVBackupEnabled,
              let urlString = settings.webDAVServerURL, !urlString.isEmpty,
              let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http",
              url.host != nil,
              let username = settings.webDAVUsername, !username.isEmpty,
              let password = keychain.get("webDAVAppPassword"), !password.isEmpty
        else { return nil }
        return WebDAVConfig(baseURL: url, username: username, appPassword: password)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVConfigTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVConfig.swift SottoTests/WebDAVConfigTests.swift
git commit -m "feat: WebDAVConfig — validated target resolved from settings + Keychain"
```

---

## Task 3: `WebDAVClient` — HTTP verbs

The `mkcol`/`put`/`delete`/`check` client, behind a protocol so the sink is testable without a network. Precedent: `DeepgramService` (injected `URLSession`, best-effort). Tested against a `URLProtocol` stub — the standard way to assert `URLSession` request construction deterministically.

**Files:**
- Create: `Sotto/Files/WebDAVClient.swift`
- Test: `SottoTests/WebDAVClientTests.swift`

**Interfaces:**
- Consumes: `WebDAVConfig` (Task 2).
- Produces:
  - `enum WebDAVResult: Sendable, Equatable { case ok, unauthorized, insufficientStorage, unreachable, failed(Int) }`
  - `protocol WebDAVClienting: Sendable { func mkcol(_:) async -> WebDAVResult; func put(_:to:) async -> WebDAVResult; func delete(_:) async -> WebDAVResult; func check() async -> WebDAVResult }`
  - `struct WebDAVClient: WebDAVClienting { init(config: WebDAVConfig, session: URLSession = .shared) }`
- Consumed by: `WebDAVSyncSink` (Task 4), `AppModel.testWebDAVConnection` (Task 6).

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/WebDAVClientTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

/// Records the last request and returns a scripted response. Registered per-test via a custom
/// URLSessionConfiguration so it never touches the real network.
final class WebDAVStubProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { let method: String; let url: String; let authorization: String? }
    nonisolated(unsafe) static var captured: Captured?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var failTransport = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = Captured(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"))
        if Self.failTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct WebDAVClientTests {
    private func client(_ base: String = "https://cloud.example.com/dav/Sotto") -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDAVStubProtocol.self]
        WebDAVStubProtocol.captured = nil
        WebDAVStubProtocol.failTransport = false
        WebDAVStubProtocol.statusCode = 200
        return WebDAVClient(
            config: WebDAVConfig(baseURL: URL(string: base)!, username: "alice", appPassword: "pw"),
            session: URLSession(configuration: config))
    }

    @Test func putIssuesPutToPercentEncodedPathWithBasicAuth() async {
        let result = await client().put(Data("body".utf8), to: "2026-07-05/09-15-00.md")
        #expect(result == .ok)
        let cap = WebDAVStubProtocol.captured!
        #expect(cap.method == "PUT")
        #expect(cap.url == "https://cloud.example.com/dav/Sotto/2026-07-05/09-15-00.md")
        // Basic YWxpY2U6cHc= == base64("alice:pw")
        #expect(cap.authorization == "Basic YWxpY2U6cHc=")
    }

    @Test func mkcolIssuesMkcolAndTreats405AsOk() async {
        let c = client()
        WebDAVStubProtocol.statusCode = 201
        #expect(await c.mkcol("2026-07-05") == .ok)
        #expect(WebDAVStubProtocol.captured!.method == "MKCOL")
        WebDAVStubProtocol.statusCode = 405   // already exists
        #expect(await c.mkcol("2026-07-05") == .ok)
    }

    @Test func deleteIssuesDelete() async {
        WebDAVStubProtocol.statusCode = 204
        let c = client()
        #expect(await c.delete("2026-07-05/09-15-00.md") == .ok)
        #expect(WebDAVStubProtocol.captured!.method == "DELETE")
    }

    @Test func checkIssuesPropfindOnBase() async {
        WebDAVStubProtocol.statusCode = 207   // Multi-Status
        let c = client()
        #expect(await c.check() == .ok)
        let cap = WebDAVStubProtocol.captured!
        #expect(cap.method == "PROPFIND")
        #expect(cap.url == "https://cloud.example.com/dav/Sotto")
    }

    @Test func statusMappings() async {
        let c = client()
        WebDAVStubProtocol.statusCode = 401
        #expect(await c.put(Data(), to: "x/y.md") == .unauthorized)
        WebDAVStubProtocol.statusCode = 507
        #expect(await c.put(Data(), to: "x/y.md") == .insufficientStorage)
        WebDAVStubProtocol.statusCode = 500
        #expect(await c.put(Data(), to: "x/y.md") == .failed(500))
        WebDAVStubProtocol.failTransport = true
        #expect(await c.put(Data(), to: "x/y.md") == .unreachable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVClientTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'WebDAVClient' in scope`.

- [ ] **Step 3: Create `WebDAVClient.swift`**

```swift
import Foundation

/// The outcome of a WebDAV request, mapped from HTTP status / transport state so callers (the
/// sink and "Test connection") never see raw `URLResponse`s. Best-effort: no throwing surface.
enum WebDAVResult: Sendable, Equatable {
    case ok
    case unauthorized          // 401 / 403 — bad username or app password
    case insufficientStorage   // 507 — server full
    case unreachable           // transport failure (DNS, TLS, no route)
    case failed(Int)           // any other non-2xx
}

/// The WebDAV verbs the backup needs. A protocol so `WebDAVSyncSink` is unit-testable against a
/// fake; the real `WebDAVClient` is tested against a `URLProtocol` stub.
protocol WebDAVClienting: Sendable {
    /// Create the collection at `relativePath`. `already-exists` (405) counts as success.
    func mkcol(_ relativePath: String) async -> WebDAVResult
    func put(_ data: Data, to relativePath: String) async -> WebDAVResult
    func delete(_ relativePath: String) async -> WebDAVResult
    /// "Test connection": PROPFIND (Depth: 0) on the base collection.
    func check() async -> WebDAVResult
}

/// Real client (design 2026-07-08): requests against `config.baseURL` with HTTP Basic auth and
/// an injected `URLSession` (default `.shared`), system-trust TLS only (no delegate override).
/// Every op is best-effort — a transport error maps to `.unreachable`, never throws.
struct WebDAVClient: WebDAVClienting {
    let config: WebDAVConfig
    let session: URLSession

    init(config: WebDAVConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func mkcol(_ relativePath: String) async -> WebDAVResult {
        await send("MKCOL", relativePath: relativePath, body: nil, treat405AsOK: true)
    }

    func put(_ data: Data, to relativePath: String) async -> WebDAVResult {
        await send("PUT", relativePath: relativePath, body: data)
    }

    func delete(_ relativePath: String) async -> WebDAVResult {
        await send("DELETE", relativePath: relativePath, body: nil)
    }

    func check() async -> WebDAVResult {
        await send("PROPFIND", relativePath: "", body: nil, extraHeaders: ["Depth": "0"])
    }

    // MARK: - Request plumbing

    /// Appends each already-split path component to the base URL (percent-encoding via
    /// `appendingPathComponent`), so `2026-07-05/09-15-00.md` becomes two safe components.
    private func url(for relativePath: String) -> URL {
        var url = config.baseURL
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func authorizationHeader() -> String {
        let raw = "\(config.username):\(config.appPassword)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    private func send(
        _ method: String, relativePath: String, body: Data?,
        treat405AsOK: Bool = false, extraHeaders: [String: String] = [:]
    ) async -> WebDAVResult {
        var request = URLRequest(url: url(for: relativePath))
        request.httpMethod = method
        request.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200...299: return .ok
        case 405 where treat405AsOK: return .ok
        case 401, 403: return .unauthorized
        case 507: return .insufficientStorage
        default: return .failed(http.statusCode)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVClientTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVClient.swift SottoTests/WebDAVClientTests.swift
git commit -m "feat: WebDAVClient — mkcol/put/delete/check with Basic auth, best-effort"
```

---

## Task 4: `WebDAVSyncSink` — the sink

The `TranscriptSyncSink` conformer: `upsert` = lazy `MKCOL` day collection + `PUT` the `.md`; `remove` = `DELETE` the `.md`. Transcripts only — `segment.audio` is never read.

**Files:**
- Create: `Sotto/Files/WebDAVSyncSink.swift`
- Test: `SottoTests/WebDAVSyncSinkTests.swift`

**Interfaces:**
- Consumes: `TranscriptSyncSink`/`SyncSegment` (existing), `WebDAVClienting` (Task 3).
- Produces: `struct WebDAVSyncSink: TranscriptSyncSink { let client: any WebDAVClienting }`.
- Consumed by: `SyncSinkRegistry` (Task 5).

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/WebDAVSyncSinkTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

/// Records calls so a test can assert the sink drove the expected verbs/paths. An actor because
/// the sink may be invoked from detached tasks. Every method returns `.ok`.
actor RecordingWebDAVClient: WebDAVClienting {
    enum Call: Equatable, Sendable {
        case mkcol(String), put(String), delete(String), check
    }
    private(set) var calls: [Call] = []

    func mkcol(_ relativePath: String) async -> WebDAVResult { calls.append(.mkcol(relativePath)); return .ok }
    func put(_ data: Data, to relativePath: String) async -> WebDAVResult { calls.append(.put(relativePath)); return .ok }
    func delete(_ relativePath: String) async -> WebDAVResult { calls.append(.delete(relativePath)); return .ok }
    func check() async -> WebDAVResult { calls.append(.check); return .ok }
}

struct WebDAVSyncSinkTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebDAVSink-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `<root>/<day>/<base>.md [+ .m4a]`; returns the segment.
    private func makeSegment(root: URL, day: String, base: String, audio: Bool) throws -> SyncSegment {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try "transcript".write(to: dayDir.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        let m4a = dayDir.appendingPathComponent("\(base).m4a")
        if audio { try Data([0x01]).write(to: m4a) }
        return SyncSegment(m4aURL: m4a)
    }

    @Test func upsertMkcolsDayThenPutsMarkdownNeverAudio() async throws {
        let root = tempDir()
        let segment = try makeSegment(root: root, day: "2026-07-05", base: "09-15-00", audio: true)
        let recorder = RecordingWebDAVClient()

        await WebDAVSyncSink(client: recorder).upsert(segment)

        let calls = await recorder.calls
        #expect(calls == [.mkcol("2026-07-05"), .put("2026-07-05/09-15-00.md")])
        // Audio is never uploaded — no .put for the .m4a.
        #expect(!calls.contains(.put("2026-07-05/09-15-00.m4a")))
    }

    @Test func upsertOfMissingMarkdownSkipsSilently() async throws {
        // A segment whose .md doesn't exist (deleted between finalize and mirror): no crash, no put.
        let root = tempDir()
        let m4a = root.appendingPathComponent("2026-07-05/09-15-00.m4a")
        let recorder = RecordingWebDAVClient()

        await WebDAVSyncSink(client: recorder).upsert(SyncSegment(m4aURL: m4a))

        #expect(await recorder.calls.isEmpty)   // nothing to upload
    }

    @Test func removeDeletesMarkdownPath() async {
        let recorder = RecordingWebDAVClient()
        await WebDAVSyncSink(client: recorder).remove(day: "2026-07-05", basename: "09-15-00")
        #expect(await recorder.calls == [.delete("2026-07-05/09-15-00.md")])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVSyncSinkTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'WebDAVSyncSink' in scope`.

- [ ] **Step 3: Create `WebDAVSyncSink.swift`**

```swift
import Foundation

/// Second `TranscriptSyncSink` (design 2026-07-08): an opt-in outbound mirror of finalized `.md`
/// transcripts to a user-configured WebDAV server. Transcripts ONLY — `segment.audio` is never
/// read. Best-effort and failure-isolated per the protocol: every op degrades to "didn't back
/// up"; nothing throws into the caller. Deletes may lag on the server (foreground-only DELETE);
/// a reconcile pass is a documented follow-up, not this scope.
struct WebDAVSyncSink: TranscriptSyncSink {
    let client: any WebDAVClienting

    func upsert(_ segment: SyncSegment) async {
        // Read the .md bytes off the local store. Missing (retention/merge/delete raced the
        // mirror) → skip silently; the next event or a manual backup retries.
        guard let data = try? Data(contentsOf: segment.markdown) else { return }
        _ = await client.mkcol(segment.day)                              // lazy day collection; 405 = ok
        _ = await client.put(data, to: "\(segment.day)/\(segment.basename).md")   // audio ignored
    }

    func remove(day: String, basename: String) async {
        _ = await client.delete("\(day)/\(basename).md")                 // 404 tolerated (already gone)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVSyncSinkTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/WebDAVSyncSink.swift SottoTests/WebDAVSyncSinkTests.swift
git commit -m "feat: WebDAVSyncSink — transcripts-only outbound mirror (mkcol+put / delete)"
```

---

## Task 5: `SyncSinkRegistry` integration + Wi-Fi gate

Append the WebDAV sink to `activeSinks` when configured and reachable under the Wi-Fi-only policy. Gating at assembly (not inside the sink) mirrors how `WiFiGatedService` decides whether to use Deepgram at all. A lazily-created shared monitor avoids a fresh `NWPathMonitor` per event and costs nothing for users who never enable WebDAV.

**Files:**
- Modify: `Sotto/Files/TranscriptSyncSink.swift` (the `SyncSinkRegistry` enum)
- Test: `SottoTests/SyncSinkRegistryWebDAVTests.swift`

**Interfaces:**
- Consumes: `WebDAVConfig.load` (Task 2), `WebDAVClient` (Task 3), `WebDAVSyncSink` (Task 4), `SettingsStore.wifiOnlyUpload` + WebDAV accessors, `NetworkMonitoring`/`WiFiMonitor` (existing).
- Produces: an updated `activeSinks` that includes a `WebDAVSyncSink` under the right conditions.

**Design note on testing the gate:** to keep the Wi-Fi branch deterministically testable without depending on device network state, add a `#if DEBUG`-only injectable monitor override on the registry (same pattern as the existing `testSinks` seam). Production reads the lazily-created `sharedMonitor`.

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/SyncSinkRegistryWebDAVTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

/// A fixed-answer monitor so the Wi-Fi gate is deterministic in tests.
private struct FixedMonitor: NetworkMonitoring { let isOnWiFi: Bool }

@Suite(.serialized)   // mutates the DEBUG monitor override; keep serialized like SyncFanOutTests
struct SyncSinkRegistryWebDAVTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sink-registry-webdav-\(UUID().uuidString)")!
    }

    /// Enable WebDAV with a full, valid config (URL + username in settings, password in Keychain).
    private func configured(_ settings: SettingsStore, keychain: KeychainStore) {
        settings.iCloudBackupEnabled = false        // isolate the WebDAV slot
        settings.webDAVBackupEnabled = true
        settings.webDAVServerURL = "https://cloud.example.com/dav/Sotto"
        settings.webDAVUsername = "alice"
        keychain.set("pw", for: "webDAVAppPassword")
    }

    @Test func webDAVSinkPresentWhenConfiguredAndOnWiFi() {
        let settings = SettingsStore(defaults: freshSuite())
        let kc = KeychainStore(service: "reg-webdav-\(UUID().uuidString)")
        configured(settings, keychain: kc)
        SyncSinkRegistry.testMonitor = FixedMonitor(isOnWiFi: true)
        SyncSinkRegistry.testKeychain = kc
        defer { SyncSinkRegistry.testMonitor = nil; SyncSinkRegistry.testKeychain = nil }

        let sinks = SyncSinkRegistry.activeSinks(settings)
        #expect(sinks.contains { $0 is WebDAVSyncSink })
    }

    @Test func webDAVSinkAbsentWhenDisabledOrIncomplete() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.iCloudBackupEnabled = false
        SyncSinkRegistry.testMonitor = FixedMonitor(isOnWiFi: true)
        defer { SyncSinkRegistry.testMonitor = nil }
        // Disabled → no WebDAV sink; with iCloud also off, no sinks at all.
        #expect(SyncSinkRegistry.activeSinks(settings).isEmpty)
    }

    @Test func webDAVSinkGatedOffWhenOffWiFiAndWifiOnly() {
        let settings = SettingsStore(defaults: freshSuite())
        let kc = KeychainStore(service: "reg-webdav-\(UUID().uuidString)")
        configured(settings, keychain: kc)
        settings.wifiOnlyUpload = true
        SyncSinkRegistry.testMonitor = FixedMonitor(isOnWiFi: false)   // off Wi-Fi
        SyncSinkRegistry.testKeychain = kc
        defer { SyncSinkRegistry.testMonitor = nil; SyncSinkRegistry.testKeychain = nil }

        #expect(!SyncSinkRegistry.activeSinks(settings).contains { $0 is WebDAVSyncSink })
    }

    @Test func webDAVSinkPresentOffWiFiWhenWifiOnlyIsOff() {
        let settings = SettingsStore(defaults: freshSuite())
        let kc = KeychainStore(service: "reg-webdav-\(UUID().uuidString)")
        configured(settings, keychain: kc)
        settings.wifiOnlyUpload = false
        SyncSinkRegistry.testMonitor = FixedMonitor(isOnWiFi: false)
        SyncSinkRegistry.testKeychain = kc
        defer { SyncSinkRegistry.testMonitor = nil; SyncSinkRegistry.testKeychain = nil }

        #expect(SyncSinkRegistry.activeSinks(settings).contains { $0 is WebDAVSyncSink })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncSinkRegistryWebDAVTests 2>&1 | tail -5`
Expected: FAIL — `type 'SyncSinkRegistry' has no member 'testMonitor'` / no WebDAV sink assembled.

- [ ] **Step 3: Update `SyncSinkRegistry`**

In `Sotto/Files/TranscriptSyncSink.swift`, extend the `SyncSinkRegistry` enum. Add the DEBUG seams next to the existing `testSinks`, the lazy `sharedMonitor`, and the WebDAV branch in `activeSinks`:

```swift
    #if DEBUG
    /// Test seam: a fixed-answer reachability monitor for the WebDAV Wi-Fi gate.
    nonisolated(unsafe) static var testMonitor: NetworkMonitoring?
    /// Test seam: a scoped Keychain so a test's app password doesn't leak between runs.
    nonisolated(unsafe) static var testKeychain: KeychainStore?
    #endif

    /// Lazily-created shared reachability monitor — constructed only once the WebDAV branch is
    /// first reached (i.e. a user actually enabled WebDAV), so users who never configure it pay
    /// nothing. Avoids starting a fresh NWPathMonitor per fan-out event.
    private static let sharedMonitor: NetworkMonitoring = WiFiMonitor()

    private static func monitor() -> NetworkMonitoring {
        #if DEBUG
        if let testMonitor { return testMonitor }
        #endif
        return sharedMonitor
    }
```

Then in `activeSinks`, after the iCloud append and before `return sinks`:

```swift
        // WebDAV (design 2026-07-08): opt-in, transcripts-only, gated by the Wi-Fi-only policy.
        // Resolved fresh per event like every other sink, so a config change applies immediately.
        #if DEBUG
        let keychain = testKeychain ?? KeychainStore()
        #else
        let keychain = KeychainStore()
        #endif
        if let config = WebDAVConfig.load(settings, keychain: keychain),
           !settings.wifiOnlyUpload || monitor().isOnWiFi {
            sinks.append(WebDAVSyncSink(client: WebDAVClient(config: config)))
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the WebDAV suite AND the existing `SyncSinkRegistryTests`/`SyncFanOutTests` to confirm no regression:
`xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncSinkRegistryWebDAVTests -only-testing:SottoTests/SyncSinkRegistryTests -only-testing:SottoTests/SyncFanOutTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/TranscriptSyncSink.swift SottoTests/SyncSinkRegistryWebDAVTests.swift
git commit -m "feat: SyncSinkRegistry — assemble WebDAV sink, Wi-Fi-gated"
```

---

## Task 6: `AppModel.testWebDAVConnection` — the "Test connection" entry point

A user-initiated real network call (never from setup/tests) that exercises the typed-in — not-yet-persisted — credentials and returns a human string. Mirrors `testDeepgramKey`'s pattern (detached, off-main, user-initiated).

**Files:**
- Modify: `Sotto/App/AppModel.swift` (add near `testDeepgramKey`, ~line 549)
- Test: `SottoTests/WebDAVConnectionTestTests.swift`

**Interfaces:**
- Consumes: `WebDAVConfig` (Task 2), `WebDAVClient`/`WebDAVResult` (Task 3).
- Produces:
  - `func testWebDAVConnection(url: String, username: String, password: String) async -> String` (MainActor, on `AppModel`).
  - A pure, testable mapping helper: `enum WebDAVConnectionMessage { static func text(for result: WebDAVResult) -> String }` (or a `WebDAVResult`-string map exposed for the unit test). Keep the network call in `AppModel`; keep the string mapping pure and unit-tested.

- [ ] **Step 1: Write the failing test** (for the pure mapping — the network call itself is manual-only)

Create `SottoTests/WebDAVConnectionTestTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct WebDAVConnectionTestTests {
    @Test func mapsEachResultToUserFacingText() {
        #expect(WebDAVConnectionMessage.text(for: .ok) == "Connected.")
        #expect(WebDAVConnectionMessage.text(for: .unauthorized)
            == "Authentication failed — check username and app password.")
        #expect(WebDAVConnectionMessage.text(for: .unreachable)
            == "Server unreachable — check the URL and your network.")
        #expect(WebDAVConnectionMessage.text(for: .insufficientStorage)
            == "Server is out of space.")
        #expect(WebDAVConnectionMessage.text(for: .failed(500))
            == "Unexpected server response (500).")
    }

    @Test func invalidURLReportsUnreachableWithoutNetwork() async {
        // A blank/garbage URL can't build a config → the connection test short-circuits to the
        // unreachable message and never touches the network.
        let text = WebDAVConnectionMessage.textForInvalidConfig
        #expect(text == "Server unreachable — check the URL and your network.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVConnectionTestTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'WebDAVConnectionMessage' in scope`.

- [ ] **Step 3: Add the mapping + the AppModel method**

Add the pure mapping (a small type — put it in `Sotto/Files/WebDAVClient.swift` beside `WebDAVResult`, or a new `Sotto/Files/WebDAVConnectionMessage.swift`):

```swift
/// Maps a `WebDAVResult` to the string shown under the Settings "Test connection" button.
/// Pure + unit-tested; the network call lives in `AppModel.testWebDAVConnection`.
enum WebDAVConnectionMessage {
    static let textForInvalidConfig = "Server unreachable — check the URL and your network."

    static func text(for result: WebDAVResult) -> String {
        switch result {
        case .ok: return "Connected."
        case .unauthorized: return "Authentication failed — check username and app password."
        case .insufficientStorage: return "Server is out of space."
        case .unreachable: return "Server unreachable — check the URL and your network."
        case .failed(let code): return "Unexpected server response (\(code))."
        }
    }
}
```

In `Sotto/App/AppModel.swift`, near `testDeepgramKey`:

```swift
    /// Settings "Test connection" (WebDAV): PROPFIND the candidate collection with the typed-in
    /// credentials (not yet persisted). Real network call — user-initiated only, never from setup
    /// or tests. Detached + off-main like `testDeepgramKey`.
    func testWebDAVConnection(url: String, username: String, password: String) async -> String {
        guard let base = URL(string: url), base.scheme == "https" || base.scheme == "http",
              base.host != nil, !username.isEmpty, !password.isEmpty else {
            return WebDAVConnectionMessage.textForInvalidConfig
        }
        let config = WebDAVConfig(baseURL: base, username: username, appPassword: password)
        let result = await Task.detached(priority: .userInitiated) {
            await WebDAVClient(config: config).check()
        }.value
        return WebDAVConnectionMessage.text(for: result)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/WebDAVConnectionTestTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/AppModel.swift Sotto/Files/WebDAVClient.swift SottoTests/WebDAVConnectionTestTests.swift
git commit -m "feat: AppModel.testWebDAVConnection + result→message mapping"
```

> If you put the mapping in a separate `WebDAVConnectionMessage.swift`, `git add` that path instead of `WebDAVClient.swift`.

---

## Task 7: Settings — WebDAV subsection

Add the WebDAV disclosure group to the existing `backupSection`, below the iCloud controls. Mirrors the Deepgram-key form: `SecureField` for the password, a "Test connection" button with a ✓/✗ + message, persistence on submit and on disappear.

**Files:**
- Modify: `Sotto/App/SettingsView.swift`
- Test: none (SwiftUI view wiring; the logic underneath is unit-tested in Tasks 1–6). Verify by build + manual smoke.

**Interfaces:**
- Consumes: `SettingsStore` WebDAV accessors (Task 1), `KeychainStore` (existing), `AppModel.testWebDAVConnection` (Task 6).

- [ ] **Step 1: Add `@State` + load existing values**

Near the other `@State` vars (top of `SettingsView`, by `deepgramKey`/`iCloudBackupEnabled`):

```swift
    @State private var webDAVEnabled = false
    @State private var webDAVURL = ""
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var webDAVTestResult: String?
```

In the same `.task`/`onAppear` block that loads `deepgramKey`/`iCloudBackupEnabled` (~line 50):

```swift
            webDAVEnabled = settings.webDAVBackupEnabled
            webDAVURL = settings.webDAVServerURL ?? ""
            webDAVUsername = settings.webDAVUsername ?? ""
            webDAVPassword = KeychainStore().get("webDAVAppPassword") ?? ""
```

- [ ] **Step 2: Add the WebDAV UI to `backupSection`**

Append inside the `Section("Backup & Restore")`, after the iCloud block:

```swift
            // --- WebDAV (design 2026-07-08): opt-in, transcripts-only, in ADDITION to iCloud ---
            Toggle("Back up to WebDAV server", isOn: $webDAVEnabled)
                .onChange(of: webDAVEnabled) { _, value in
                    model.settings.webDAVBackupEnabled = value
                }
            if webDAVEnabled {
                TextField("Server URL", text: $webDAVURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: webDAVURL) { _, _ in webDAVTestResult = nil }
                    .onSubmit { persistWebDAV() }
                TextField("Username", text: $webDAVUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: webDAVUsername) { _, _ in webDAVTestResult = nil }
                    .onSubmit { persistWebDAV() }
                SecureField("App password", text: $webDAVPassword)
                    .onChange(of: webDAVPassword) { _, _ in webDAVTestResult = nil }
                    .onSubmit { persistWebDAV() }
                HStack {
                    Button("Test connection") {
                        Task {
                            persistWebDAV()
                            webDAVTestResult = "Testing…"
                            webDAVTestResult = await model.testWebDAVConnection(
                                url: webDAVURL, username: webDAVUsername, password: webDAVPassword)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(webDAVURL.isEmpty || webDAVUsername.isEmpty || webDAVPassword.isEmpty)
                }
                if let webDAVTestResult {
                    Text(webDAVTestResult).font(.caption).foregroundStyle(.secondary)
                }
                Text("Transcripts (not audio) are also mirrored to your own WebDAV server, in addition to iCloud. Deleting a transcript here removes it from the server on the app's next foreground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Add `persistWebDAV()` + persist-on-disappear**

Add a helper beside `persistKey()`:

```swift
    private func persistWebDAV() {
        model.settings.webDAVServerURL = webDAVURL.isEmpty ? nil : webDAVURL
        model.settings.webDAVUsername = webDAVUsername.isEmpty ? nil : webDAVUsername
        if webDAVPassword.isEmpty { KeychainStore().delete("webDAVAppPassword") }
        else { KeychainStore().set(webDAVPassword, for: "webDAVAppPassword") }
    }
```

And call `persistWebDAV()` wherever `persistKey()` is called on disappear (the `.onDisappear` near line 306).

- [ ] **Step 4: Build + smoke**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (full suite; no view test, but confirm the whole thing still builds + passes).

Manual smoke (simulator): open Settings ▸ Backup & Restore, toggle WebDAV on, enter a URL/username/password, tap "Test connection" (expect a mapped message).

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/SettingsView.swift
git commit -m "feat: Settings — WebDAV backup subsection with Test connection"
```

---

## Task 8: Full-suite gate + forward-compat doc touch

Confirm the whole suite is green with zero new warnings, and update the iCloud design's forward-compat note so it points at this shipped design (housekeeping — the iCloud doc §10 called WebDAV "next phase").

**Files:**
- Modify: `docs/superpowers/specs/2026-07-07-backup-restore-icloud-design.md` (§10 WebDAV bullet — mark it landed, link this design). Optional but keeps the docs honest.

- [ ] **Step 1: Full suite**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. Grep the build log for `warning:` in changed files → none.

- [ ] **Step 2: Doc touch (optional)**

Update the iCloud design §10 WebDAV bullet to reference `specs/2026-07-08-webdav-backup-design.md` as shipped, and note audio + restore were dropped in its brainstorm.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-07-backup-restore-icloud-design.md
git commit -m "docs: mark WebDAV phase landed in iCloud design forward-compat note"
```

---

## Verification checklist (whole feature)

- [ ] `webDAVBackupEnabled` defaults **off**; URL/username in UserDefaults; app password in Keychain (`webDAVAppPassword`).
- [ ] `WebDAVConfig.load` is nil unless enabled + valid URL + username + password.
- [ ] `WebDAVClient` issues correct verbs/URLs with `Authorization: Basic …`; status mapping correct; `405` on `MKCOL` = ok; transport error = `.unreachable`.
- [ ] `WebDAVSyncSink.upsert` = `mkcol(day)` + `put(<day>/<base>.md)`, **never** audio; missing `.md` skips; `remove` = `delete(<day>/<base>.md)`.
- [ ] `activeSinks` includes WebDAV only when configured **and** (Wi-Fi allowed or `wifiOnlyUpload` off); iCloud unaffected; both can be active together.
- [ ] `testWebDAVConnection` maps every `WebDAVResult` to the right string; invalid config short-circuits without a network call.
- [ ] Settings WebDAV subsection persists correctly (incl. clearing the Keychain password when emptied).
- [ ] Full suite `** TEST SUCCEEDED **`, zero new warnings, Swift 6.
- [ ] Five AppModel fan-out sites **unchanged** — WebDAV rides the existing fan-out with no new call sites.
