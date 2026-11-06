import Foundation

struct UnmountRetrySettings: Equatable {
    let retries: Int
    let interval: Int

    static let defaults = UnmountRetrySettings(retries: 10, interval: 30)

    static func parse(retries: String, interval: String) throws -> UnmountRetrySettings {
        guard let count = Int(retries.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0,
              let seconds = Int(interval.trimmingCharacters(in: .whitespacesAndNewlines)), seconds > 0 else {
            throw UnmountCheckError("重试次数须为非负整数，间隔须为大于 0 的整数秒")
        }
        return UnmountRetrySettings(retries: count, interval: seconds)
    }
}

struct UnmountRetryPlan<Target> {
    let settings: UnmountRetrySettings
    private(set) var remaining: Int
    private(set) var pending: [Target]

    init(targets: [Target], settings: UnmountRetrySettings) {
        self.settings = settings
        remaining = settings.retries
        pending = targets
    }

    var canRetry: Bool { remaining > 0 && !pending.isEmpty }
    var retriesUsed: Int { settings.retries - remaining }

    mutating func recordFailures(_ targets: [Target]) {
        pending = targets
    }

    mutating func nextRetry() -> [Target]? {
        guard canRetry else { return nil }
        remaining -= 1
        return pending
    }
}
