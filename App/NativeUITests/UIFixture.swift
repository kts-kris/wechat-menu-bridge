import Foundation
import XCTest

struct UIFixture {
    struct Endpoints: Decodable { let mcp: URL; let model: URL; let control: URL }
    struct Submission: Decodable, Equatable { let account: String; let peer: String; let text: String }
    struct Counts: Decodable { let sends: Int; let models: Int; let waits: Int; let faults: Int; let last: Submission? }

    let endpoints: Endpoints
    init(_ name: String) throws {
        let json = try XCTUnwrap(ProcessInfo.processInfo.environment["WMB_UI_FIXTURE_\(name)"])
        endpoints = try JSONDecoder().decode(Endpoints.self, from: Data(json.utf8))
        for (url, path) in [(endpoints.mcp, "/mcp"), (endpoints.model, "/v1/chat/completions"), (endpoints.control, "/")] {
            guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                  url.path == path, url.query == nil, url.user == nil else { throw URLError(.badURL) }
        }
    }

    @discardableResult
    func request(_ action: String = "counts") async throws -> Counts {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoints.control.appendingPathComponent(action), timeoutInterval: 2)
        if action != "counts" { request.httpMethod = "POST" }
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Counts.self, from: data)
    }
}
