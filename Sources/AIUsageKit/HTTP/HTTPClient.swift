import Foundation

/// Sends HTTP requests. A protocol so tests can stand in for the network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws(UsageError) -> (Data, HTTPURLResponse)
}

/// An `HTTPClient` on an ephemeral `URLSession` without cookies, caching or redirects.
///
/// Redirects are refused so a bearer token can never be forwarded to another host.
public final class URLSessionHTTPClient: HTTPClient {
    public static let shared = URLSessionHTTPClient()

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws(UsageError) -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network
        }
        guard let response = response as? HTTPURLResponse else {
            throw .invalidResponse
        }
        return (data, response)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension HTTPClient {
    /// Sends a GET request for a provider, logs the status, and maps failure statuses to errors.
    func get(_ request: URLRequest, provider: String, expiredMessage: String) async throws(UsageError) -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            Log.usage.error("fetch provider=\(provider, privacy: .public) category=\(error.category, privacy: .public)")
            throw error
        }
        Log.usage.notice("fetch provider=\(provider, privacy: .public) status=\(response.statusCode, privacy: .public)")
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw .loginExpired(expiredMessage)
        case 429:
            throw .rateLimited(retryAfter: RetryAfter.seconds(from: response.value(forHTTPHeaderField: "Retry-After")))
        case 500..<600:
            throw .server(status: response.statusCode)
        default:
            throw .http(status: response.statusCode)
        }
    }
}

/// Parses the `Retry-After` header, as seconds or an HTTP date.
enum RetryAfter {
    static func seconds(from value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return max(seconds, 0)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return max(date.timeIntervalSince(now), 0)
    }
}
