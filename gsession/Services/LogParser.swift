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
    //
    // EXCEPTION: "Tunnel is down due to network change" is transient — GP
    // silently re-establishes the tunnel (no new "portal status is Connected")
    // and the login session survives it, so treating it as terminal produced a
    // false "disconnected" and a broken session timer. It is excluded here via
    // negative lookahead; a network change that does NOT recover is still caught
    // by the policy/route probe in the view model (defense in depth).
    //
    // Inner groups are non-capturing so group 1 stays the timestamp.
    private static let disconnectPattern = try! NSRegularExpression(
        pattern: #"^(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}):\d+ \[Info \]: (?:Tunnel is down due to (?!network change\.$).+|Tunnel retry done: (?:failed retry|received disconnect)|User was logged out of Gateway .+|User disconnecting tunnel starts|GlobalProtect service stopped\.|portal status is Invalid portal\.)$"#,
        options: .anchorsMatchLines
    )

    /// Captures the absolute session expiry (Unix epoch) that the gateway
    /// pushes on every (re)connect. Lives in PanGPS.log, not the event log.
    private static let expiryPattern = try! NSRegularExpression(
        pattern: #"<user_expires>(\d+)</user_expires>"#
    )

    /// A PanGPS.log line timestamp prefix, e.g. "06/10/2026 08:45:35". Used to
    /// date the config block carrying `<user_expires>` so we can tell whether
    /// it belongs to the current connection or a previous one.
    private static let serviceTimestampPattern = try! NSRegularExpression(
        pattern: #"(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}):\d+"#
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

    /// The session expiry the gateway pushed, plus the time its config block was
    /// logged. `blockTime` lets callers reject a stale expiry left over from a
    /// previous connection when reconnecting (the new block is written a few
    /// seconds after the connect event).
    struct SessionExpiry {
        let expiry: Date
        let blockTime: Date?
    }

    /// Reads the server-authoritative session expiry from PanGPS.log, where the
    /// gateway config block (refreshed on every reconnect) carries an absolute
    /// `<user_expires>` epoch. Returns `nil` if the log is unreadable or has no
    /// such entry — callers then fall back to the fixed `sessionDuration`.
    func parseSessionExpiry() -> SessionExpiry? {
        guard let data = readServiceLogTail() else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        return Self.sessionExpiry(in: content)
    }

    /// Pure core: the latest `<user_expires>` epoch in the given log text, paired
    /// with the timestamp of the nearest preceding log line (the config block's
    /// time). Separated from file I/O for unit testing.
    static func sessionExpiry(in content: String) -> SessionExpiry? {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        var lastMatch: NSTextCheckingResult?
        Self.expiryPattern.enumerateMatches(in: content, range: fullRange) { result, _, _ in
            if result != nil { lastMatch = result } // keep the last (most recent)
        }
        guard let match = lastMatch,
              let epochRange = Range(match.range(at: 1), in: content),
              let epoch = TimeInterval(content[epochRange]) else { return nil }
        let expiry = Date(timeIntervalSince1970: epoch)

        // The config block's time = the last log timestamp before <user_expires>.
        var blockTime: Date?
        let before = NSRange(location: 0, length: match.range.location)
        Self.serviceTimestampPattern.enumerateMatches(in: content, range: before) { result, _, _ in
            guard let result, let tsRange = Range(result.range(at: 1), in: content) else { return }
            if let date = Self.dateFormatter.date(from: String(content[tsRange])) { blockTime = date }
        }
        return SessionExpiry(expiry: expiry, blockTime: blockTime)
    }

    private func readLogTail() -> Data? {
        readTail(of: AppConstants.logFilePath, bytes: 65536)
    }

    /// PanGPS.log is far chattier and the expiry block can sit well behind the
    /// tail of a long-lived session (~20KB/h of idle noise; ~265KB after 13h),
    /// so read a much larger window — still bounded for a ~10h max lifetime.
    private func readServiceLogTail() -> Data? {
        readTail(of: AppConstants.serviceLogFilePath, bytes: 2_097_152) // 2MB
    }

    private func readTail(of path: String, bytes: UInt64) -> Data? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize = min(fileSize, bytes)
        handle.seek(toFileOffset: fileSize - readSize)
        return handle.readDataToEndOfFile()
    }
}
