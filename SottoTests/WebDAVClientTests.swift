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
