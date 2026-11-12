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
    /// The longest one provider's fetch may take. It's longer than the Keychain read timeout plus the
    /// HTTP timeout, so it only fires when something is stuck.
    static let fetchTimeout = Duration.seconds(60)

    private(set) var sections: [ProviderSection]
    /// The providers with a fetch in flight. Each provider has at most one, and a slow one doesn't hold up the others.
    private(set) var refreshingIDs: Set<String> = []

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private var backoffs: [String: Backoff] = [:]
    @ObservationIgnored private var lastAttempts: [String: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Providers that got a manual refresh while their fetch was in flight. They refresh again when it ends.
    @ObservationIgnored private var pendingManualIDs: Set<String> = []

    init(providers: [any UsageProvider]) {
        self.providers = providers
        sections = providers.map { ProviderSection(id: $0.id, name: $0.name) }
    }

    var isRefreshing: Bool {
        !refreshingIDs.isEmpty
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

    /// Fetches every provider that is due, or only those in `ids`. Providers with a fetch in flight are skipped;
    /// a manual refresh of one runs again when its fetch ends.
    func refresh(_ reason: RefreshReason, only ids: Set<String>? = nil) async {
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
        let candidates = providers.filter { ids?.contains($0.id) ?? true }
        if reason == .manual {
            pendingManualIDs.formUnion(candidates.map(\.id).filter(refreshingIDs.contains))
        }
        let due = candidates.filter { !refreshingIDs.contains($0.id) && isDue($0, reason: reason, now: now) }
        guard !due.isEmpty else {
            return
        }
        for provider in due {
            lastAttempts[provider.id] = now
            refreshingIDs.insert(provider.id)
        }
        Log.usage.notice("refresh reason=\(reason.rawValue, privacy: .public) providers=\(due.map(\.id).joined(separator: ","), privacy: .public)")

        await withTaskGroup(of: (String, Result<[UsageLimit], UsageError>).self) { group in
            for provider in due {
                group.addTask {
                    (provider.id, await provider.fetchLimits(timeout: Self.fetchTimeout))
                }
            }
            for await (id, result) in group {
                apply(result, to: id)
                refreshingIDs.remove(id)
            }
        }

        let rerun = pendingManualIDs.intersection(due.map(\.id))
        if !rerun.isEmpty {
            pendingManualIDs.subtract(rerun)
            await refresh(.manual, only: rerun)
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
