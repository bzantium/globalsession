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

// E) Regression: known disconnect reason still detected.
check("E: known tunnel-down reason", """
06/05/2026 09:17:50:805 [Info ]: portal status is Connected.
06/05/2026 09:20:00:000 [Info ]: Tunnel is down due to network change.
""", expectConnected: false)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
