import Foundation
import Testing

@testable import AIUsageKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func date(_ string: String) throws -> Date {
        try #require(ISO8601.date(from: string))
    }
}
