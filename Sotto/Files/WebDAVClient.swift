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
