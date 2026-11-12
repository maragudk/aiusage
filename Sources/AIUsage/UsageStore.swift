import AIUsageKit
import Foundation
import Observation

/// Fetches usage from every provider on a schedule and holds the latest result per provider.
///
/// Providers are fetched concurrently and fail independently: one provider's error never touches another's section.
@MainActor
@Observable
final class UsageStore {
    enum RefreshReason: String {
        case poll
        /// A provider's login repair finished. Refreshes only that provider, to show the repaired state.
        case loginRepaired
    }

    static let pollInterval = Duration.seconds(120)

    private(set) var sections: [ProviderSection]
    private(set) var isRefreshing = false
    /// The Claude weekly percentage from the latest successful fetch. It survives errors, so the menu bar keeps
    /// showing the last known number.
    private(set) var lastClaudeWeeklyPercent: Int?

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private var backoffs: [String: Backoff] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Providers whose login repair finished while a refresh was running.
    @ObservationIgnored private var pendingRepairs: Set<String> = []
    @ObservationIgnored private let now: () -> Date

    init(providers: [any UsageProvider], now: @escaping () -> Date = Date.init) {
        self.providers = providers
        self.now = now
        sections = providers.map { ProviderSection(id: $0.id, name: $0.name) }
    }

    var visibleSections: [ProviderSection] {
        sections.filter(\.isAvailable)
    }

    /// When the newest data shown was fetched. Failed fetches don't count, so the footer never calls stale data fresh.
    var lastUpdated: Date? {
        visibleSections.compactMap(\.lastSuccess).max()
    }

    /// The number the menu bar shows instead of its icon, or nil when it should show the icon.
    var menuBarPercent: Int? {
        guard visibleSections.contains(where: { $0.id == "claude" }) else {
            return nil
        }
        return lastClaudeWeeklyPercent
    }

    /// Starts polling. The first refresh happens right away.
    func start() {
        guard pollTask == nil else {
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(.poll)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Fetches every provider that is due, or only `providerID` when given. Only one refresh runs at a time. That
    /// can't get stuck, because every fetch is bounded: the Keychain read by its timeout, and HTTP requests by the
    /// session's timeouts.
    func refresh(_ reason: RefreshReason, only providerID: String? = nil) async {
        guard !isRefreshing else {
            if reason == .loginRepaired, let providerID {
                pendingRepairs.insert(providerID)
            }
            return
        }
        let now = now()
        for provider in providers {
            let isAvailable = provider.isAvailable
            let repair = isAvailable ? provider.loginRepair : nil
            update(provider.id) { section in
                section.isAvailable = isAvailable
                section.repairTitle = repair?.title
                section.repairHelp = repair?.help
            }
        }
        let due = providers.filter { (providerID == nil || $0.id == providerID) && isDue($0, now: now) }
        guard !due.isEmpty else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        Log.usage.notice("refresh reason=\(reason.rawValue, privacy: .public) providers=\(due.map(\.id).joined(separator: ","), privacy: .public)")

        await withTaskGroup(of: (String, Result<[UsageLimit], UsageError>).self) { group in
            for provider in due {
                group.addTask {
                    do throws(UsageError) {
                        return (provider.id, .success(try await provider.fetchLimits()))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                apply(result, to: id)
            }
        }

        if let id = pendingRepairs.popFirst() {
            isRefreshing = false
            await refresh(.loginRepaired, only: id)
        }
    }

    /// Runs the provider's login repair, then refreshes.
    func repairLogin(for id: String) {
        guard let provider = providers.first(where: { $0.id == id }),
              let repair = provider.loginRepair,
              section(id)?.repairStatus == nil
        else {
            return
        }
        Log.login.notice("login repair started provider=\(id, privacy: .public)")
        update(id) { $0.repairStatus = "Starting…" }
        Task {
            await repair.perform { message in
                Task { @MainActor in
                    self.update(id) { section in
                        // A message can arrive after the repair has finished. Drop it then.
                        if section.repairStatus != nil {
                            section.repairStatus = message
                        }
                    }
                }
            }
            update(id) { $0.repairStatus = nil }
            Log.login.notice("login repair finished provider=\(id, privacy: .public)")
            await refresh(.loginRepaired, only: id)
        }
    }

    private func isDue(_ provider: any UsageProvider, now: Date) -> Bool {
        guard section(provider.id)?.isAvailable == true else {
            return false
        }
        return backoffs[provider.id, default: Backoff()].allowsAttempt(at: now)
    }

    private func apply(_ result: Result<[UsageLimit], UsageError>, to id: String) {
        let now = now()
        switch result {
        case .success(let limits):
            backoffs[id, default: Backoff()].recordSuccess()
            if id == "claude" {
                lastClaudeWeeklyPercent = MenuBarUsage.weeklyPercent(limits: limits)
            }
            update(id) { section in
                section.limits = limits
                section.error = nil
                section.lastSuccess = now
            }
            Log.usage.notice("fetch ok provider=\(id, privacy: .public) limits=\(limits.count, privacy: .public)")
        case .failure(let error):
            if error.shouldBackOff {
                backoffs[id, default: Backoff()].recordFailure(at: now, retryAfter: error.retryAfter)
                logRateLimit(error, provider: id, now: now)
            }
            update(id) { section in
                section.error = error
                if !error.keepsLastData {
                    section.limits = []
                }
            }
            Log.usage.error("fetch failed provider=\(id, privacy: .public) category=\(error.category, privacy: .public)")
        }
    }

    /// Logs a 429 with its `Retry-After` and the resulting wait, to learn the real rate limit window.
    private func logRateLimit(_ error: UsageError, provider id: String, now: Date) {
        guard case .rateLimited(let retryAfter) = error else {
            return
        }
        let backoff = backoffs[id, default: Backoff()].notBefore.map { Int($0.timeIntervalSince(now)) } ?? 0
        let retryAfterText = retryAfter.map { String(Int($0.rounded())) } ?? "none"
        Log.usage.notice("rate limited provider=\(id, privacy: .public) retryAfter=\(retryAfterText, privacy: .public) backoff=\(backoff, privacy: .public)")
    }

    private func section(_ id: String) -> ProviderSection? {
        sections.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout ProviderSection) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&sections[index])
    }
}
