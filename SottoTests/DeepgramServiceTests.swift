import Foundation
import Synchronization
import Testing
@testable import Sotto

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct DeepgramServiceTests {
    private func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func audioFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DGTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    @Test func buildsSpecCompliantRequestAndParsesUtterances() async throws {
        let requestBox = Mutex<URLRequest?>(nil)
        MockURLProtocol.handler = { request in
            requestBox.withLock { $0 = request }
            let body = """
            {"results": {"channels": [{"alternatives": [{"transcript": "hi there"}]}],
             "utterances": [
               {"start": 0.5, "end": 1.2, "transcript": "hi", "speaker": 0},
               {"start": 1.4, "end": 2.0, "transcript": "there", "speaker": 1}
             ]}}
            """
            return (200, Data(body.utf8))
        }
        let service = DeepgramService(apiKeyProvider: { "test-key" }, session: mockedSession())
        let result = try await service.transcribe(file: try audioFixture())

        let request = requestBox.withLock { $0 }!
        let url = request.url!.absoluteString
        #expect(url.hasPrefix("https://api.deepgram.com/v1/listen?"))
        #expect(url.contains("model=nova-3"))
        #expect(url.contains("diarize_model=latest"))
        #expect(!url.contains("diarize=true"))               // deprecated param must be absent
        #expect(url.contains("utterances=true"))
        #expect(url.contains("smart_format=true"))
        #expect(url.contains("mip_opt_out=true"))            // privacy: training opt-out always
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token test-key")

        #expect(result.backend == .deepgram)
        #expect(result.text == "hi there")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == "1")           // speaker index 0 → "Speaker 1"
        #expect(result.segments[1].speaker == "2")
        #expect(abs(result.segments[0].startTime - 0.5) < 0.001)
    }

    @Test func missingKeyThrowsBeforeAnyNetworkCall() async throws {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let service = DeepgramService(apiKeyProvider: { nil }, session: mockedSession())
        await #expect(throws: TranscriptionError.self) {
            _ = try await service.transcribe(file: try audioFixture())
        }
    }

    @Test func non200ThrowsBadResponse() async throws {
        MockURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        let service = DeepgramService(apiKeyProvider: { "k" }, session: mockedSession())
        await #expect(throws: TranscriptionError.self) {
            _ = try await service.transcribe(file: try audioFixture())
        }
    }

    @Test func keychainRoundTrip() {
        let store = KeychainStore(service: "com.decanlys.Sotto.tests")
        store.delete("dg")
        #expect(store.get("dg") == nil)
        #expect(store.set("secret-123", for: "dg"))
        #expect(store.get("dg") == "secret-123")
        #expect(store.set("secret-456", for: "dg"))           // overwrite
        #expect(store.get("dg") == "secret-456")
        store.delete("dg")
        #expect(store.get("dg") == nil)
    }
}
