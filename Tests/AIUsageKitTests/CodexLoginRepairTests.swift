import Foundation
import Synchronization
import Testing

@testable import AIUsageKit

/// Runs the repair against a fake `codex` shell script that speaks just enough of the app-server protocol.
struct CodexLoginRepairTests {
    private let directory: URL
    private let codex: URL
    private let transcript: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        codex = directory.appending(path: "codex")
        transcript = directory.appending(path: "transcript")
        let script = """
            #!/bin/sh
            transcript='\(transcript.path)'
            echo "args: $*" >> "$transcript"
            if [ "$1" = "app-server" ]; then
              while IFS= read -r line; do
                echo "$line" >> "$transcript"
                case "$line" in
                  *'"method":"initialize"'*) echo '{"method":"some/notification","params":{}}'; echo '{"id":1,"result":{}}' ;;
                  *'"method":"account/read"'*) echo '{"id":99,"method":"server/request","params":{}}'; echo '{"id":2,"result":{"account":null}}' ;;
                esac
              done
              echo "app-server stdin closed" >> "$transcript"
            fi
            exit 0
            """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
    }

    private func readTranscript() throws -> [String] {
        try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test
    func `asks the app server to refresh and skips login when that worked`() async throws {
        let repair = CodexLoginRepair(codex: codex, version: "1.2.3", isLoginValid: { true })
        let messages = Mutex<[String]>([])
        await repair.run { message in messages.withLock { $0.append(message) } }

        let lines = try readTranscript()
        #expect(lines.first == "args: app-server")
        #expect(lines.contains { $0.contains(#""method":"initialize""#) && $0.contains(#""id":1"#) && $0.contains(#""version":"1.2.3""#) })
        #expect(lines.contains(#"{"method":"initialized"}"#))
        #expect(lines.contains { $0.contains(#""method":"account/read""#) && $0.contains(#""refreshToken":true"#) && $0.contains(#""id":2"#) })
        #expect(lines.last == "app-server stdin closed")
        #expect(!lines.contains("args: login"))
        #expect(messages.withLock { $0 }.count == 1)
    }

    @Test
    func `falls back to codex login when the token is still expired`() async throws {
        let repair = CodexLoginRepair(codex: codex, version: "1.2.3", isLoginValid: { false })
        let messages = Mutex<[String]>([])
        await repair.run { message in messages.withLock { $0.append(message) } }

        let lines = try readTranscript()
        #expect(lines.first == "args: app-server")
        #expect(lines.last == "args: login")
        #expect(messages.withLock { $0 }.count == 2)
    }

    @Test
    func `survives an app server that exits at once`() async throws {
        let quitter = directory.appending(path: "quitter")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: quitter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quitter.path)

        let repair = CodexLoginRepair(codex: quitter, version: "1", isLoginValid: { true })
        await repair.run { _ in }
    }

    @Test
    func `does nothing harmful when the CLI can't be started`() async {
        let repair = CodexLoginRepair(codex: directory.appending(path: "missing"), version: "1", isLoginValid: { false })
        let messages = Mutex<[String]>([])
        await repair.run { message in messages.withLock { $0.append(message) } }
        #expect(messages.withLock { $0 }.count == 2)
    }

    @Test
    func `gives up on an app server that never answers`() async throws {
        let silent = directory.appending(path: "silent")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: silent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)

        let repair = CodexLoginRepair(codex: silent, version: "1", isLoginValid: { true }, refreshTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        await repair.run { _ in }
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}
