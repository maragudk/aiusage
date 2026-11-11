import Foundation
import Synchronization

@testable import AIUsageKit

/// Answers every request with a canned response and records the requests.
final class FakeHTTPClient: HTTPClient {
    private let status: Int
    private let body: Data
    private let headers: [String: String]
    private let requests = Mutex<[URLRequest]>([])

    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    var sentRequests: [URLRequest] {
        requests.withLock { $0 }
    }

    func send(_ request: URLRequest) async throws(UsageError) -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}
