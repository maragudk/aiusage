import AIUsageKit
import Foundation

/// What the panel shows for one provider.
struct ProviderSection: Identifiable {
    let id: String
    let name: String
    var isAvailable = false
    var limits: [UsageLimit] = []
    var error: UsageError?
    var lastSuccess: Date?
    /// The title of the provider's login repair button, if it has one.
    var repairTitle: String?
    /// The current step of a running login repair, or nil when none is running.
    var repairStatus: String?

    var isLoading: Bool {
        limits.isEmpty && error == nil && lastSuccess == nil
    }

    var canRepairLogin: Bool {
        guard case .loginExpired = error else {
            return false
        }
        return repairTitle != nil
    }
}
