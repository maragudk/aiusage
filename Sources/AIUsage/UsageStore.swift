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
        case panelOpened
        case manual
    }

    static let pollInterval = Duration.seconds(5 * 60)
    /// Opening the panel refreshes a provider whose data is older than this,
    /// unless it was already tried within this time.
    static let panelRefreshAge: TimeInterval = 60

    private(set) var sections: [ProviderSection]
    private(set) var isRefreshing = false

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private var backoffs: [String: Backoff] = [:]
    @ObservationIgnored private var lastAttempts: [String: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var needsManualRefresh = false

    init(providers: [any UsageProvider]) {
        self.providers = providers
        sections = providers.map { ProviderSection(id: $0.id, name: $0.name) }
    }

    var visibleSections: [ProviderSection] {
        sections.filter(\.isAvailable)
    }

    /// When the newest data shown was fetched. Failed fetches don't count, so the footer never calls stale data fresh.
    var lastUpdated: Date? {
        visibleSections.compactMap(\.lastSuccess).max()
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

    func panelDidOpen() {
        Task { await refresh(.panelOpened) }
    }

    func refreshNow() {
        Task { await refresh(.manual) }
    }

    func refresh(_ reason: RefreshReason) async {
        guard !isRefreshing else {
            if reason == .manual {
                needsManualRefresh = true
            }
            return
        }
        let now = Date()
        for provider in providers {
            let isAvailable = provider.isAvailable
            let repair = isAvailable ? provider.loginRepair : nil
            update(provider.id) { section in
                section.isAvailable = isAvailable
                section.repairTitle = repair?.title
                section.repairHelp = repair?.help
            }
        }
        let due = providers.filter { isDue($0, reason: reason, now: now) }
        guard !due.isEmpty else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        for provider in due {
            lastAttempts[provider.id] = now
        }
        Log.usage.info("refresh reason=\(reason.rawValue, privacy: .public) providers=\(due.map(\.id).joined(separator: ","), privacy: .public)")

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

        if needsManualRefresh {
            needsManualRefresh = false
            isRefreshing = false
            await refresh(.manual)
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
            await refresh(.manual)
        }
    }

    private func isDue(_ provider: any UsageProvider, reason: RefreshReason, now: Date) -> Bool {
        guard section(provider.id)?.isAvailable == true else {
            return false
        }
        // Manual refreshes skip the backoff and ask for Keychain access again.
        if reason == .manual {
            return true
        }
        if section(provider.id)?.error == .keychainDenied {
            return false
        }
        if reason == .panelOpened {
            let isStale = section(provider.id)?.lastSuccess.map { now.timeIntervalSince($0) > Self.panelRefreshAge } ?? true
            let wasTriedRecently = lastAttempts[provider.id].map { now.timeIntervalSince($0) <= Self.panelRefreshAge } ?? false
            guard isStale, !wasTriedRecently else {
                return false
            }
        }
        return backoffs[provider.id, default: Backoff()].allowsAttempt(at: now)
    }

    private func apply(_ result: Result<[UsageLimit], UsageError>, to id: String) {
        let now = Date()
        switch result {
        case .success(let limits):
            backoffs[id, default: Backoff()].recordSuccess()
            update(id) { section in
                section.limits = limits
                section.error = nil
                section.lastSuccess = now
            }
            Log.usage.notice("fetch ok provider=\(id, privacy: .public) limits=\(limits.count, privacy: .public)")
        case .failure(let error):
            if error.shouldBackOff {
                backoffs[id, default: Backoff()].recordFailure(at: now, retryAfter: error.retryAfter)
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
