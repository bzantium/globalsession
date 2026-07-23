import AppKit
import Combine
import Foundation

struct QueryPieTokenState: Equatable, Sendable {
    let host: String
    let accessTokenExpiresAt: Date
    let refreshTokenExpiresAt: Date
}

struct QueryPiePopupSuppressionPolicy {
    static let maximumAccessTokenWindow: TimeInterval = 6 * 60
    static let minimumRefreshTokenLifetime: TimeInterval = 10 * 60

    private static let minutePattern = try! NSRegularExpression(
        pattern: #"expire in\s+(\d+)\s+minute"#,
        options: [.caseInsensitive]
    )

    /// QueryPie 11.5 can report an SSH session as expiring when the rotating
    /// 20-minute access token is about to expire, even though the hard agent
    /// session (refresh token) still has hours remaining. Suppress only that
    /// signature; genuine session warnings outside this narrow window remain.
    static func shouldSuppress(
        message: String,
        tokenState: QueryPieTokenState,
        now: Date = Date()
    ) -> Bool {
        let accessRemaining = tokenState.accessTokenExpiresAt.timeIntervalSince(now)
        let refreshRemaining = tokenState.refreshTokenExpiresAt.timeIntervalSince(now)

        guard
            accessRemaining >= 0,
            accessRemaining <= maximumAccessTokenWindow,
            refreshRemaining >= minimumRefreshTokenLifetime
        else {
            return false
        }

        let range = NSRange(message.startIndex..., in: message)
        if
            let match = minutePattern.firstMatch(in: message, range: range),
            let minuteRange = Range(match.range(at: 1), in: message),
            let displayedMinutes = Int(message[minuteRange])
        {
            let accessMinutes = max(1, Int(ceil(accessRemaining / 60)))
            return abs(displayedMinutes - accessMinutes) <= 1
        }

        return message.localizedCaseInsensitiveContains("expire in soon")
            && accessRemaining <= 90
    }
}

/// Extracts the hard agent-session expiry that QueryPie Multi Agent writes to
/// its local log whenever it refreshes the short-lived access token.
///
/// Only the expiry field is retained. Authentication tokens and the surrounding
/// JSON are never exposed outside the small parsing buffer.
struct QueryPieLogParser {
    private static let accessExpiryPattern = try! NSRegularExpression(
        pattern: #"\"accessTokenExpiresAt\"\s*:\s*\"([^\"]+)\""#
    )
    private static let expiryPattern = try! NSRegularExpression(
        pattern: #"\"refreshTokenExpiresAt\"\s*:\s*\"([^\"]+)\""#
    )
    private static let hostPattern = try! NSRegularExpression(
        pattern: #"\[([^\]\s]+) WebView\]"#
    )

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func latestRefreshTokenExpiry(in text: String) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = expiryPattern.matches(in: text, range: range).last,
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        let value = String(text[valueRange])
        return fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }

    static func latestTokenState(in text: String) -> QueryPieTokenState? {
        let fullRange = NSRange(text.startIndex..., in: text)
        let accessMatches = accessExpiryPattern.matches(in: text, range: fullRange)
        let refreshMatches = expiryPattern.matches(in: text, range: fullRange)

        for accessMatch in accessMatches.reversed() {
            // Both values are fields of the same small AuthInfo log object. Pair
            // only a following refresh expiry nearby, avoiding a partial record
            // at a bounded read-chunk edge being mixed with an older refresh.
            guard let refreshMatch = refreshMatches.last(where: {
                $0.range.location > accessMatch.range.location
                    && $0.range.location - accessMatch.range.location < 32 * 1024
            }) else {
                continue
            }

            let contextStart = max(0, accessMatch.range.location - 4 * 1024)
            let contextRange = NSRange(
                location: contextStart,
                length: accessMatch.range.location - contextStart
            )
            guard
                let hostMatch = hostPattern.matches(in: text, range: contextRange).last,
                let hostRange = Range(hostMatch.range(at: 1), in: text),
                let accessRange = Range(accessMatch.range(at: 1), in: text),
                let refreshRange = Range(refreshMatch.range(at: 1), in: text),
                let accessExpiry = parseDate(String(text[accessRange])),
                let refreshExpiry = parseDate(String(text[refreshRange]))
            else {
                continue
            }

            return QueryPieTokenState(
                host: String(text[hostRange]),
                accessTokenExpiresAt: accessExpiry,
                refreshTokenExpiresAt: refreshExpiry
            )
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }

    /// Searches newest log files and reads them backwards in bounded chunks, so
    /// a growing QueryPie log is never loaded wholesale into gsession.
    static func latestRefreshTokenExpiry(inLogDirectory directory: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files
            .filter { $0.pathExtension == "log" && $0.lastPathComponent != "webView.log" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return left > right
            }

        // Two files cover the midnight rollover case where today's log exists
        // but the latest token refresh was written shortly before midnight.
        for file in candidates.prefix(2) {
            if let expiry = latestRefreshTokenExpiry(inLogFile: file) {
                return expiry
            }
        }
        return nil
    }

    static func latestTokenState(inLogDirectory directory: URL) -> QueryPieTokenState? {
        latestValue(inLogDirectory: directory, parser: latestTokenState(in:))
    }

    private static func latestValue<T>(
        inLogDirectory directory: URL,
        parser: (String) -> T?
    ) -> T? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files
            .filter { $0.pathExtension == "log" && $0.lastPathComponent != "webView.log" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return left > right
            }

        for file in candidates.prefix(2) {
            if let value = latestValue(inLogFile: file, parser: parser) {
                return value
            }
        }
        return nil
    }

    private static func latestRefreshTokenExpiry(inLogFile file: URL) -> Date? {
        latestValue(inLogFile: file, parser: latestRefreshTokenExpiry(in:))
    }

    private static func latestValue<T>(inLogFile file: URL, parser: (String) -> T?) -> T? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 256 * 1024
        let overlap: UInt64 = 32 * 1024
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        var chunkEnd = fileSize

        while chunkEnd > 0 {
            let chunkStart = chunkEnd > chunkSize ? chunkEnd - chunkSize : 0
            let readStart = chunkStart > overlap ? chunkStart - overlap : 0

            do {
                try handle.seek(toOffset: readStart)
                let data = try handle.read(upToCount: Int(chunkEnd - readStart)) ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                if let value = parser(text) {
                    return value
                }
            } catch {
                return nil
            }

            chunkEnd = chunkStart
        }
        return nil
    }
}

/// Keeps the QueryPie WebView workaround attached through page reloads and
/// renderer replacement. The injected fetch wrapper suppresses only warnings
/// that match the short-lived access-token countdown; all other dialogs use
/// QueryPie's original native-dialog path.
@MainActor
final class QueryPiePopupSuppressor {
    var onSuppressionCountChanged: ((Int) -> Void)?

    private struct CDPTarget: Decodable {
        let id: String
        let type: String
        let url: String
        let webSocketDebuggerUrl: String
    }

    private struct InstalledTarget {
        let debuggerURL: String
        let tokenSignature: String
        let scriptIdentifier: String
    }

    private enum SuppressorError: LocalizedError {
        case invalidDebuggerURL
        case commandTimeout
        case malformedResponse
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidDebuggerURL: return "Invalid QueryPie debugger URL"
            case .commandTimeout: return "QueryPie debugger command timed out"
            case .malformedResponse: return "Malformed QueryPie debugger response"
            case .commandFailed(let message): return "QueryPie debugger command failed: \(message)"
            }
        }
    }

    private static let targetListURL = URL(string: "http://127.0.0.1:9222/json/list")!
    private static let pollInterval: TimeInterval = 3

    private var tokenState: QueryPieTokenState?
    private var installedTargets: [String: InstalledTarget] = [:]
    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var lastReportedCount = 0

    deinit {
        pollTimer?.invalidate()
        pollTask?.cancel()
    }

    func start() {
        guard pollTimer == nil else { return }
        schedulePoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePoll()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
        installedTargets.removeAll()
    }

    func updateTokenState(_ state: QueryPieTokenState?) {
        guard tokenState != state else { return }
        tokenState = state
        schedulePoll()
    }

    private func schedulePoll() {
        guard pollTask == nil, tokenState != nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await pollTargets()
            pollTask = nil
        }
    }

    private func pollTargets() async {
        guard let tokenState else { return }

        do {
            var request = URLRequest(url: Self.targetListURL)
            request.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            let targets = try JSONDecoder().decode([CDPTarget].self, from: data)
            let liveIDs = Set(targets.map(\.id))
            installedTargets = installedTargets.filter { liveIDs.contains($0.key) }

            let matchingTargets = targets.filter { target in
                guard
                    target.type == "page",
                    let url = URL(string: target.url)
                else {
                    return false
                }
                return url.host == tokenState.host && url.path.hasPrefix("/multiagent")
            }

            var totalSuppressed = 0
            for target in matchingTargets {
                do {
                    totalSuppressed += try await reconcile(target: target, tokenState: tokenState)
                } catch {
                    // QueryPie replaces renderer targets during login and token
                    // refresh. Drop stale state and retry on the next short poll.
                    installedTargets.removeValue(forKey: target.id)
                }
            }

            if totalSuppressed != lastReportedCount {
                lastReportedCount = totalSuppressed
                onSuppressionCountChanged?(totalSuppressed)
            }
        } catch {
            // Port 9222 is absent while QueryPie is closed. This is a normal idle
            // state; the next poll reconnects after the app launches.
        }
    }

    private func reconcile(target: CDPTarget, tokenState: QueryPieTokenState) async throws -> Int {
        guard let debuggerURL = URL(string: target.webSocketDebuggerUrl) else {
            throw SuppressorError.invalidDebuggerURL
        }

        let signature = tokenSignature(tokenState)
        let previous = installedTargets[target.id]
        let injection = makeInjection(tokenState: tokenState)
        let socket = URLSession.shared.webSocketTask(with: debuggerURL)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        var commandID = 1
        var scriptIdentifier = previous?.scriptIdentifier
        let needsNewDocumentScript = previous?.tokenSignature != signature
            || previous?.debuggerURL != target.webSocketDebuggerUrl

        if needsNewDocumentScript {
            if
                previous?.debuggerURL == target.webSocketDebuggerUrl,
                let oldIdentifier = previous?.scriptIdentifier
            {
                _ = try? await sendCommand(
                    socket: socket,
                    id: commandID,
                    method: "Page.removeScriptToEvaluateOnNewDocument",
                    params: ["identifier": oldIdentifier]
                )
                commandID += 1
            }

            let response = try await sendCommand(
                socket: socket,
                id: commandID,
                method: "Page.addScriptToEvaluateOnNewDocument",
                params: ["source": injection]
            )
            commandID += 1
            guard
                let result = response["result"] as? [String: Any],
                let identifier = result["identifier"] as? String
            else {
                throw SuppressorError.malformedResponse
            }
            scriptIdentifier = identifier
        }

        let evaluation = try await sendCommand(
            socket: socket,
            id: commandID,
            method: "Runtime.evaluate",
            params: ["expression": injection, "returnByValue": true]
        )
        guard
            let result = evaluation["result"] as? [String: Any],
            let remote = result["result"] as? [String: Any],
            let value = remote["value"] as? String,
            let stateData = value.data(using: .utf8),
            let state = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
            let count = state["count"] as? Int,
            let scriptIdentifier
        else {
            throw SuppressorError.malformedResponse
        }

        installedTargets[target.id] = InstalledTarget(
            debuggerURL: target.webSocketDebuggerUrl,
            tokenSignature: signature,
            scriptIdentifier: scriptIdentifier
        )
        return count
    }

    private func sendCommand(
        socket: URLSessionWebSocketTask,
        id: Int,
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        // Chrome DevTools Protocol accepts JSON text frames. A binary WebSocket
        // frame is legal WebSocket, but Chromium closes/ignores it as a CDP
        // command, leaving the injection retry loop unable to make progress.
        guard let text = String(data: data, encoding: .utf8) else {
            throw SuppressorError.malformedResponse
        }
        try await socket.send(.string(text))
        let responseData = try await receiveResponse(socket: socket, commandID: id)
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw SuppressorError.malformedResponse
        }
        if let error = response["error"] as? [String: Any] {
            throw SuppressorError.commandFailed(error["message"] as? String ?? "unknown error")
        }
        return response
    }

    private func receiveResponse(
        socket: URLSessionWebSocketTask,
        commandID: Int
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let received): data = received
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    guard
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        (object["id"] as? Int) == commandID
                    else {
                        continue
                    }
                    return data
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw SuppressorError.commandTimeout
            }

            guard let first = try await group.next() else {
                throw SuppressorError.malformedResponse
            }
            group.cancelAll()
            return first
        }
    }

    private func tokenSignature(_ state: QueryPieTokenState) -> String {
        "\(state.host)|\(state.accessTokenExpiresAt.timeIntervalSince1970)|\(state.refreshTokenExpiresAt.timeIntervalSince1970)"
    }

    private func makeInjection(tokenState: QueryPieTokenState) -> String {
        let accessExpiryMilliseconds = Int64(tokenState.accessTokenExpiresAt.timeIntervalSince1970 * 1_000)
        let refreshExpiryMilliseconds = Int64(tokenState.refreshTokenExpiresAt.timeIntervalSince1970 * 1_000)

        return #"""
        (() => {
          const key = '__gsessionQueryPieWarningSuppression';
          const nextConfig = {
            accessTokenExpiresAt: \#(accessExpiryMilliseconds),
            refreshTokenExpiresAt: \#(refreshExpiryMilliseconds),
          };
          const existing = window[key];
          if (existing) {
            existing.configure(nextConfig);
            return JSON.stringify({status: 'updated', count: existing.count});
          }

          const originalFetch = window.fetch.bind(window);
          const state = {
            count: 0,
            config: nextConfig,
            installedAt: new Date().toISOString(),
            configure(config) { this.config = config; },
            shouldSuppress(message) {
              const now = Date.now();
              const accessRemaining = this.config.accessTokenExpiresAt - now;
              const refreshRemaining = this.config.refreshTokenExpiresAt - now;
              if (accessRemaining < 0 || accessRemaining > 6 * 60 * 1000) return false;
              if (refreshRemaining < 10 * 60 * 1000) return false;

              const minuteMatch = String(message || '').match(/expire in\s+(\d+)\s+minute/i);
              if (minuteMatch) {
                const displayedMinutes = Number(minuteMatch[1]);
                const accessMinutes = Math.max(1, Math.ceil(accessRemaining / 60000));
                return Math.abs(displayedMinutes - accessMinutes) <= 1;
              }
              return /expire in soon/i.test(String(message || '')) && accessRemaining <= 90000;
            },
          };

          window.fetch = async (input, init) => {
            const url = typeof input === 'string' ? input : input?.url;
            if (url === 'http://web-to-app/v5/app/ui/dialog-box') {
              let rawBody = init?.body;
              if (rawBody == null && input instanceof Request) {
                rawBody = await input.clone().text();
              }
              try {
                const body = typeof rawBody === 'string' ? JSON.parse(rawBody) : rawBody;
                if (
                  body?.header === 'Session Expiration Warning' &&
                  state.shouldSuppress(body?.message)
                ) {
                  state.count += 1;
                  state.lastMessage = body.message;
                  state.lastSuppressedAt = new Date().toISOString();
                  console.info('[gsession] false QueryPie session warning suppressed');
                  return new Response('{}', {
                    status: 200,
                    headers: {'content-type': 'application/json'},
                  });
                }
              } catch {
                // Preserve QueryPie's original behavior for malformed requests.
              }
            }
            return originalFetch(input, init);
          };

          Object.defineProperty(window, key, {
            value: state,
            configurable: false,
          });
          return JSON.stringify({status: 'installed', count: state.count});
        })()
        //# sourceURL=gsession-querypie-popup-suppressor.js
        """#
    }
}

@MainActor
final class QueryPieSessionManager: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var expiry: Date?
    @Published private(set) var remainingSeconds: TimeInterval = 0
    @Published private(set) var alertLevel: TimerAlertLevel = .safe
    @Published private(set) var suppressedPopupCount = 0

    private static let bundleIdentifier = "com.querypie.multi-agent"
    private static let fallbackApplicationURL = URL(fileURLWithPath: "/Applications/QueryPieMultiAgent.app")
    private static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".querypie-multi-agent/logs", isDirectory: true)

    private var countdownTimer: Timer?
    private var logRefreshTimer: Timer?
    private var parseTask: Task<Void, Never>?
    private var authenticatedRefreshTicks = 0
    private let popupSuppressor = QueryPiePopupSuppressor()

    deinit {
        countdownTimer?.invalidate()
        logRefreshTimer?.invalidate()
        parseTask?.cancel()
    }

    var isAuthenticated: Bool {
        isRunning && remainingSeconds > 0
    }

    func startMonitoring() {
        popupSuppressor.onSuppressionCountChanged = { [weak self] count in
            self?.suppressedPopupCount = count
        }
        popupSuppressor.start()
        refresh()

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimerState()
            }
        }

        logRefreshTimer?.invalidate()
        // Re-login should replace an expired timer almost immediately. Poll every
        // two seconds while unauthenticated; once a valid session is present,
        // parse only every eighth tick (~16s) to keep background work minimal.
        logRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isAuthenticated {
                    authenticatedRefreshTicks += 1
                    if authenticatedRefreshTicks < 8 { return }
                }
                authenticatedRefreshTicks = 0
                refresh()
            }
        }
    }

    func stopMonitoring() {
        countdownTimer?.invalidate()
        logRefreshTimer?.invalidate()
        parseTask?.cancel()
        countdownTimer = nil
        logRefreshTimer = nil
        parseTask = nil
        popupSuppressor.stop()
    }

    func refresh() {
        let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        isInstalled = workspaceURL != nil || FileManager.default.fileExists(atPath: Self.fallbackApplicationURL.path)
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty

        parseTask?.cancel()
        let logDirectory = Self.logDirectory
        parseTask = Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) {
                (
                    QueryPieLogParser.latestRefreshTokenExpiry(inLogDirectory: logDirectory),
                    QueryPieLogParser.latestTokenState(inLogDirectory: logDirectory)
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.expiry = parsed.0
            self?.popupSuppressor.updateTokenState(parsed.1)
            self?.updateTimerState()
        }
    }

    func openApplication() {
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
            ?? Self.fallbackApplicationURL
        guard FileManager.default.fileExists(atPath: applicationURL.path) else { return }
        NSWorkspace.shared.open(applicationURL)
        // NSWorkspace updates asynchronously; the next scheduled refresh is the
        // source of truth, while this short follow-up keeps the UI responsive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    private func updateTimerState() {
        guard let expiry else {
            remainingSeconds = 0
            alertLevel = .safe
            return
        }
        remainingSeconds = expiry.timeIntervalSinceNow
        alertLevel = TimerAlertLevel(remaining: remainingSeconds)
    }
}
