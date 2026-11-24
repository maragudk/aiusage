import Foundation
import Synchronization

/// Antigravity CLI (`agy`) quota, read with the OAuth login that `agy` keeps in the login Keychain.
///
/// The Keychain is re-read on every fetch and never written. The access token lasts an hour, and only `agy`
/// renews it, while it runs. The app doesn't renew it, because that would need Antigravity's OAuth client
/// secret. When the token has expired, `loginRepair` lets `agy` renew it.
public struct AntigravityProvider: UsageProvider {
    /// The host `agy` itself uses. The production host `cloudcode-pa.googleapis.com` answers too, but with
    /// untouched counters: every bucket full, resetting one window from now. So the app doesn't fall back to it.
    static let endpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let expiredMessage = "Antigravity login expired."
    static let refreshFailedMessage = "Antigravity couldn't refresh its login. Run agy in Terminal and log in again."
    static let noSubscriptionMessage = "Google reports no Antigravity subscription for this account."

    /// The client identity of Antigravity's hub. With another User-Agent, the endpoint answers 403
    /// `SUBSCRIPTION_REQUIRED`, even for a paid plan.
    static let userAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=\(arch))"
    }()

    public let id = "antigravity"
    public let name = "Antigravity"

    private let http: any HTTPClient
    private let readCredentials: @Sendable () async throws(UsageError) -> Data
    private let tokenFile: URL
    private let locateAgy: @Sendable () -> URL?
    private let now: @Sendable () -> Date
    private let run: AntigravityLoginRepair.Runner
    /// The expiry of the login that `agy` last failed to refresh, so the panel can say to log in again.
    private let failedRefresh = FailedRefresh()

    public init(http: any HTTPClient = URLSessionHTTPClient.shared) {
        // At most one Keychain read in flight, so overlapping fetches can't stack two Keychain prompts.
        let reads = SingleFlight<Result<Data, UsageError>>()
        let tokenFile = AntigravityHome.tokenFile()
        self.init(
            http: http,
            readCredentials: { () async throws(UsageError) in
                try await reads.run {
                    do throws(UsageError) {
                        return .success(try await AntigravityCredentials.read(tokenFile: tokenFile))
                    } catch {
                        return .failure(error)
                    }
                }.get()
            },
            tokenFile: tokenFile,
            locateAgy: { AntigravityHome.locateCLI() },
            now: { Date() }
        )
    }

    init(
        http: any HTTPClient,
        readCredentials: @escaping @Sendable () async throws(UsageError) -> Data,
        tokenFile: URL,
        locateAgy: @escaping @Sendable () -> URL?,
        now: @escaping @Sendable () -> Date,
        run: @escaping AntigravityLoginRepair.Runner = Command.run
    ) {
        self.http = http
        self.readCredentials = readCredentials
        self.tokenFile = tokenFile
        self.locateAgy = locateAgy
        self.now = now
        self.run = run
    }

    /// Whether `agy` is installed or its token file exists. The Keychain isn't checked here, because this runs
    /// on every refresh and a Keychain read can wait on a prompt.
    public var isAvailable: Bool {
        locateAgy() != nil || FileManager.default.fileExists(atPath: tokenFile.path)
    }

    public var loginRepair: LoginRepair? {
        guard let agy = locateAgy() else {
            return nil
        }
        let repair = AntigravityLoginRepair(agy: agy, checkLogin: { [self] in await checkLoginAfterRefresh() }, runCommand: run)
        return LoginRepair(
            title: "Refresh Antigravity login",
            help: "Runs agy models, which lets agy refresh its own login. It doesn't use any of your Antigravity quota.",
            perform: repair.run
        )
    }

    public func fetchLimits() async throws(UsageError) -> [UsageLimit] {
        let credentials = try AntigravityCredentials.parse(await readCredentials())
        do {
            return try await fetchLimits(with: credentials)
        } catch .loginExpired where failedRefresh.matches(credentials) {
            throw .loginExpired(Self.refreshFailedMessage)
        }
    }

    private func fetchLimits(with credentials: AntigravityCredentials) async throws(UsageError) -> [UsageLimit] {
        if credentials.isExpired(at: now()) {
            throw .loginExpired(Self.expiredMessage)
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await http.fetch(request, provider: id, expiredMessage: Self.expiredMessage, providerError: Self.error(status:body:))
        return try AntigravityUsageParser.parse(data)
    }

    /// A 403 whose error details have the reason `SUBSCRIPTION_REQUIRED` means the account has no quota to show.
    static func error(status: Int, body: Data) -> UsageError? {
        guard status == 403,
              let response = try? JSONDecoder().decode(ErrorResponse.self, from: body),
              response.error?.details?.contains(where: { $0.value?.reason == "SUBSCRIPTION_REQUIRED" }) == true
        else {
            return nil
        }
        return .unsupported(noSubscriptionMessage)
    }

    /// Checks the login that `agy` left after a refresh. If the server still rejects it, remembers that, so the
    /// panel says to log in with `agy` instead of offering only the same refresh.
    ///
    /// Only login failures count as rejection. A network or server error says nothing about the login.
    func checkLoginAfterRefresh() async -> Bool {
        let credentials: AntigravityCredentials
        do {
            credentials = try AntigravityCredentials.parse(await readCredentials())
        } catch {
            return !Self.isLoginRejection(error)
        }
        do {
            _ = try await fetchLimits(with: credentials)
        } catch {
            if case .loginExpired = error {
                failedRefresh.record(credentials)
            }
            return !Self.isLoginRejection(error)
        }
        failedRefresh.clear()
        return true
    }

    private static func isLoginRejection(_ error: UsageError) -> Bool {
        switch error {
        case .loginExpired, .notLoggedIn:
            true
        case .unsupported, .keychainDenied, .keychainReadFailed, .keychainTimedOut, .keychainToolFailed,
             .rateLimited, .server, .http, .network, .invalidResponse:
            false
        }
    }

    private struct ErrorResponse: Decodable {
        let error: Body?

        struct Body: Decodable {
            let details: [Lossy<Detail>]?
        }

        struct Detail: Decodable {
            let reason: String?
        }
    }
}

/// The expiry of the login that a refresh failed for. A login with another expiry is a new one.
private final class FailedRefresh: Sendable {
    private struct Login: Equatable {
        let expiresAt: Date?
    }

    private let login = Mutex<Login?>(nil)

    func record(_ credentials: AntigravityCredentials) {
        login.withLock { $0 = Login(expiresAt: credentials.expiresAt) }
    }

    func clear() {
        login.withLock { $0 = nil }
    }

    func matches(_ credentials: AntigravityCredentials) -> Bool {
        login.withLock { $0 == Login(expiresAt: credentials.expiresAt) }
    }
}
