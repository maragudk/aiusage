import Testing

@testable import AIUsageKit

struct UsageErrorTests {
    @Test
    func `errors that a retry might fix back off`() {
        for error in [UsageError.rateLimited(retryAfter: nil), .server(status: 500), .keychainTimedOut, .keychainDenied] {
            #expect(error.shouldBackOff)
        }
    }

    @Test
    func `errors that only the user can fix do not back off`() {
        for error in [UsageError.loginExpired("x"), .notLoggedIn("x"), .unsupported("x")] {
            #expect(!error.shouldBackOff)
        }
    }
}
