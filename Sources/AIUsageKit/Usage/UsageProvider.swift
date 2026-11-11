/// A source of usage limits, such as an AI subscription.
///
/// To add a provider, write one new type that conforms to this protocol and add it to the app's provider list.
public protocol UsageProvider: Sendable {
    /// A stable lowercase identifier, used in logs.
    var id: String { get }

    /// The name shown as the section title, like "Claude".
    var name: String { get }

    /// Whether the provider is set up on this Mac. Providers that aren't are hidden.
    var isAvailable: Bool { get }

    /// An action that lets the owning tool repair an expired login, or nil if there is none.
    var loginRepair: LoginRepair? { get }

    /// Fetches every limit the provider reports.
    func fetchLimits() async throws(UsageError) -> [UsageLimit]
}

/// A user-triggered action that lets a provider's owning tool fix its own login.
public struct LoginRepair: Sendable {
    /// The button title, like "Refresh Codex login".
    public let title: String

    /// Runs the repair. It reports short status messages through `progress` while it works.
    public let perform: @Sendable (_ progress: @escaping @Sendable (String) -> Void) async -> Void

    public init(title: String, perform: @escaping @Sendable (_ progress: @escaping @Sendable (String) -> Void) async -> Void) {
        self.title = title
        self.perform = perform
    }
}
