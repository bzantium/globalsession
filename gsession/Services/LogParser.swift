import Foundation

final class LogParser {
    private static let connectPattern = try! NSRegularExpression(
        pattern: #"^(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}):\d+ \[Info \]: portal status is Connected\.$"#,
        options: .anchorsMatchLines
    )
    // Matches any log line indicating the tunnel went down. Kept deliberately
    // broad — GlobalProtect emits many disconnect phrasings and an incomplete
    // allowlist is what caused the stale "VPN Connected" bug. In particular
    // "Tunnel is down due to ..." matches ANY reason (not a fixed enum), and
    // "User disconnecting tunnel starts" is the earliest signal of a manual
    // disconnect (it may be the only line if GP hangs before completing).
    // Inner groups are non-capturing so group 1 stays the timestamp.
    private static let disconnectPattern = try! NSRegularExpression(
        pattern: #"^(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}):\d+ \[Info \]: (?:Tunnel is down due to .+|Tunnel retry done: (?:failed retry|received disconnect)|User was logged out of Gateway .+|User disconnecting tunnel starts|GlobalProtect service stopped\.|portal status is Invalid portal\.)$"#,
        options: .anchorsMatchLines
    )

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func parseLatestSession() -> SessionInfo? {
        guard let data = readLogTail() else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        return Self.latestSession(in: content)
    }

    /// Pure parsing core: given raw log text, return the active session (or nil
    /// if the latest connect has been superseded by a later disconnect event).
    /// Separated from file I/O so it can be unit-tested with fixture content.
    static func latestSession(in content: String) -> SessionInfo? {
        var lastConnect: Date?
        var lastDisconnect: Date?
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)

        Self.connectPattern.enumerateMatches(in: content, range: range) { result, _, _ in
            guard let result, let tsRange = Range(result.range(at: 1), in: content) else { return }
            if let date = Self.dateFormatter.date(from: String(content[tsRange])) {
                lastConnect = date
            }
        }

        Self.disconnectPattern.enumerateMatches(in: content, range: range) { result, _, _ in
            guard let result, let tsRange = Range(result.range(at: 1), in: content) else { return }
            if let date = Self.dateFormatter.date(from: String(content[tsRange])) {
                lastDisconnect = date
            }
        }

        guard let connectTime = lastConnect else { return nil }

        if let disconnectTime = lastDisconnect, disconnectTime > connectTime {
            return nil // VPN is currently down
        }

        return SessionInfo(connectTime: connectTime)
    }

    private func readLogTail() -> Data? {
        let path = AppConstants.logFilePath
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536) // last 64KB
        handle.seek(toFileOffset: fileSize - readSize)
        return handle.readDataToEndOfFile()
    }
}
