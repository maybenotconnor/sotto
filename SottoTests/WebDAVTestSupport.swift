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
