import Foundation

/// Reads a generic password from the login Keychain with `/usr/bin/security find-generic-password -w`.
///
/// The app doesn't read Keychain items with `SecItemCopyMatching`. The tools that own the items update them with
/// the `security` tool or a library that runs it, and each update resets the item's partition list to
/// `apple-tool:`. That drops the "Always Allow" that macOS stored for this app, so the next read waits on an access
/// prompt. The `security` tool stays trusted through updates, so reading through it keeps working without a prompt.
///
/// Read only: this never writes an item or changes its access list.
enum KeychainPassword {
    /// The `security` tool that reads the Keychain item.
    static let securityTool = URL(filePath: "/usr/bin/security")
    /// How long one Keychain read may take. It only takes long when macOS shows a prompt, such as an access
    /// prompt or the password prompt of a locked keychain, so this leaves a person time to answer it.
    static let readTimeout: Duration = .seconds(60)

    /// The password of the item with `service`, and `account` if given.
    ///
    /// - Parameter notFoundMessage: the message of the `notLoggedIn` error when there is no such item.
    static func read(
        service: String,
        account: String?,
        notFoundMessage: String,
        run: Command.Runner
    ) async throws(UsageError) -> Data {
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        arguments.append("-w")

        // `security` exits with the low byte of the `OSStatus`.
        switch await run(securityTool, arguments, readTimeout) {
        case .exited(status: 0, let output):
            return password(fromOutput: output)
        case .exited(status: 44, _): // errSecItemNotFound
            throw .notLoggedIn(notFoundMessage)
        case .exited(status: 51, _), // errSecAuthFailed, when the user clicks Deny
             .exited(status: 128, _): // errSecUserCanceled
            throw .keychainDenied
        case .exited(let status, _):
            throw .keychainReadFailed(status: status)
        case .timedOut:
            throw .keychainTimedOut
        case .launchFailed:
            throw .keychainToolFailed
        }
    }

    /// The password from the output of `security find-generic-password -w`, which is the password and
    /// a newline, or the password in hex if it isn't printable text.
    static func password(fromOutput output: Data) -> Data {
        var output = output
        if output.last == UInt8(ascii: "\n") {
            output.removeLast()
        }
        return hexDecoded(output) ?? output
    }

    /// The bytes that `data` spells in hex, or nil if it isn't hex.
    private static func hexDecoded(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else {
            return nil
        }
        let nibbles = data.compactMap { byte -> UInt8? in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        guard nibbles.count == data.count else {
            return nil
        }
        return Data(stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] })
    }
}
