import Foundation

// Standalone test: compiled together with the real production sources
// (LogParser.swift, VPNState.swift, AppConstants.swift) via swiftc.
// Exercises LogParser.latestSession(in:) against fixtures that reproduce the
// "stale VPN Connected" bug. Exits non-zero if any case fails.

var failures = 0

func check(_ name: String, _ content: String, expectConnected: Bool) {
    let session = LogParser.latestSession(in: content)
    let got = (session != nil)
    let ok = (got == expectConnected)
    print("\(ok ? "PASS" : "FAIL") — \(name): expected \(expectConnected ? "connected" : "disconnected"), got \(got ? "connected" : "disconnected")")
    if !ok { failures += 1 }
}

// A) THE BUG: latest connect followed by "User disconnecting tunnel starts"
//    (the completion lines never arrive because GP hangs mid-disconnect).
check("A: user-disconnect intent only", """
06/04/2026 18:23:26:011 [Info ]: User was logged out of Gateway gw.example.com.
06/05/2026 09:17:50:805 [Info ]: portal status is Connected.
06/05/2026 09:25:23:314 [Info ]: User disconnecting tunnel starts
""", expectConnected: false)

// B) Unknown "Tunnel is down due to ..." variant not in the old allowlist.
check("B: tunnel down (packet sending failure)", """
06/05/2026 09:17:50:805 [Info ]: portal status is Connected.
06/05/2026 09:20:00:000 [Info ]: Tunnel is down due to packet sending failure.
""", expectConnected: false)

// C) Genuinely connected: connect with no later disconnect.
check("C: connected, no disconnect after", """
06/05/2026 09:17:50:805 [Info ]: portal status is Connected.
""", expectConnected: true)

// D) Reconnect: disconnect then a newer connect → connected.
check("D: disconnect then reconnect", """
06/05/2026 08:00:00:000 [Info ]: portal status is Connected.
06/05/2026 08:30:00:000 [Info ]: Tunnel is down due to disconnection.
06/05/2026 09:00:00:000 [Info ]: portal status is Connected.
""", expectConnected: true)

// E) Regression: a genuinely terminal tunnel-down reason is still detected.
check("E: known tunnel-down reason", """
06/05/2026 09:17:50:805 [Info ]: portal status is Connected.
06/05/2026 09:20:00:000 [Info ]: Tunnel is down due to disconnection.
""", expectConnected: false)

// I) THE BUG: "network change" is transient — GP silently re-establishes the
//    tunnel without a new "portal status is Connected", and the login session
//    survives it. Treating it as terminal caused a false "disconnected" + a
//    broken session timer. The route/policy probe remains the safety net for a
//    network change that does NOT recover.
check("I: network change is transient (session survives)", """
06/11/2026 09:11:31:336 [Info ]: portal status is Connected.
06/11/2026 16:57:38:494 [Info ]: Tunnel is down due to network change.
""", expectConnected: true)

// J) Regression: a network change FOLLOWED by a real logout is still down.
check("J: network change then logout", """
06/11/2026 09:11:31:336 [Info ]: portal status is Connected.
06/11/2026 16:57:38:494 [Info ]: Tunnel is down due to network change.
06/11/2026 16:58:00:000 [Info ]: User was logged out of Gateway gw.example.com.
""", expectConnected: false)

// K) A transport failure can recover without a fresh portal Connected event.
//    The original connect time must survive so the gateway expiry remains tied
//    to the real login session rather than restarting the countdown at restore.
let restoredSession = LogParser.latestSession(in: """
06/11/2026 09:11:31:336 [Info ]: portal status is Connected.
06/11/2026 16:18:28:562 [Info ]: Tunnel is down due to packet sending failure.
06/11/2026 18:01:25:071 [Info ]: Tunnel is restored.
""")
let restoredFormatter = DateFormatter()
restoredFormatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
restoredFormatter.locale = Locale(identifier: "en_US_POSIX")
let expectedOriginalConnect = restoredFormatter.date(from: "06/11/2026 09:11:31")
let restoredOK = restoredSession?.connectTime == expectedOriginalConnect
print("\(restoredOK ? "PASS" : "FAIL") — K: restored tunnel preserves original session start")
if !restoredOK { failures += 1 }

// L) A later real disconnect still wins over an earlier successful restore.
check("L: restored tunnel then manual disconnect", """
06/11/2026 09:11:31:336 [Info ]: portal status is Connected.
06/11/2026 16:18:28:562 [Info ]: Tunnel is down due to packet sending failure.
06/11/2026 18:01:25:071 [Info ]: Tunnel is restored.
06/11/2026 18:30:00:000 [Info ]: User disconnecting tunnel starts
""", expectConnected: false)

// MARK: - Session expiry parsing (PanGPS.log <user_expires>)

func checkExpiry(_ name: String, _ content: String, expectEpoch: TimeInterval?, expectBlock: String? = nil) {
    let result = LogParser.sessionExpiry(in: content)
    let got = result?.expiry.timeIntervalSince1970
    var ok = (got == expectEpoch)
    if let expectBlock {
        let bf = DateFormatter(); bf.dateFormat = "MM/dd/yyyy HH:mm:ss"; bf.locale = Locale(identifier: "en_US_POSIX")
        ok = ok && (result?.blockTime == bf.date(from: expectBlock))
    }
    let gotBlock = result?.blockTime.map { "\($0)" } ?? "nil"
    print("\(ok ? "PASS" : "FAIL") — \(name): expected \(expectEpoch.map { String($0) } ?? "nil"), got \(got.map { String($0) } ?? "nil") (block=\(gotBlock))")
    if !ok { failures += 1 }
}

// F) Config block with preceding timestamp → that epoch + block time.
checkExpiry("F: single user_expires", """
P44674-T25551 06/10/2026 08:45:35:648 Debug(3108): gateway's config is
\t\t<lifetime>35997</lifetime>
\t\t<user_expires>1781084732</user_expires>
""", expectEpoch: 1781084732, expectBlock: "06/10/2026 08:45:35")

// G) Multiple blocks (reconnects) → the LAST one wins (epoch + its block time).
checkExpiry("G: latest of several", """
P44674-T1 06/08/2026 10:51:29:894 Debug(3108): gateway's config is
\t\t<user_expires>1780919489</user_expires>
P44674-T2 06/10/2026 08:45:35:648 Debug(3108): gateway's config is
\t\t<user_expires>1781084732</user_expires>
""", expectEpoch: 1781084732, expectBlock: "06/10/2026 08:45:35")

// H) No expiry in log → nil (caller falls back to fixed duration).
checkExpiry("H: no user_expires", """
06/05/2026 09:17:50:805 [Info ]: portal status is Connected.
""", expectEpoch: nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
