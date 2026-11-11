import os

/// Loggers for the app. Log fetch outcomes only: provider, HTTP status and error category.
/// Never log tokens, headers or response bodies.
///
/// Outcomes are logged at `notice` level or above, because `info` messages aren't persisted
/// and soon disappear from `log show`.
public enum Log {
    public static let subsystem = "dk.maragu.aiusage"

    public static let usage = Logger(subsystem: subsystem, category: "usage")
    public static let login = Logger(subsystem: subsystem, category: "login")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
