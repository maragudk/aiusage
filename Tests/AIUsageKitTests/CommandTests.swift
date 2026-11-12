import Foundation
import Testing

@testable import AIUsageKit

/// Runs real processes, but only `/bin/sh` and `/bin/cat`. Nothing here touches the Keychain.
struct CommandTests {
    private let shell = URL(filePath: "/bin/sh")

    @Test
    func `captures the output and exit status`() async {
        let result = await Command.run(shell, arguments: ["-c", "printf 'hello'; exit 3"], timeout: .seconds(10))
        #expect(result == .exited(status: 3, output: Data("hello".utf8)))
    }

    @Test
    func `captures output larger than a pipe buffer`() async {
        let result = await Command.run(shell, arguments: ["-c", "head -c 200000 /dev/zero"], timeout: .seconds(10))
        #expect(result == .exited(status: 0, output: Data(count: 200_000)))
    }

    @Test
    func `stdin is closed so a command that reads it doesn't wait`() async {
        let result = await Command.run(URL(filePath: "/bin/cat"), arguments: [], timeout: .seconds(10))
        #expect(result == .exited(status: 0, output: Data()))
    }

    @Test
    func `a command that runs too long is killed and reported as timed out`() async {
        let start = ContinuousClock.now
        let result = await Command.run(shell, arguments: ["-c", "exec sleep 30"], timeout: .milliseconds(300))
        #expect(result == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test
    func `a command that ignores SIGTERM is killed too`() async {
        let start = ContinuousClock.now
        let result = await Command.run(shell, arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: .milliseconds(300))
        #expect(result == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test
    func `a command that can't be started is a launch failure`() async {
        let result = await Command.run(URL(filePath: "/nonexistent/aiusage-test-tool"), arguments: [], timeout: .seconds(10))
        #expect(result == .launchFailed)
    }
}
