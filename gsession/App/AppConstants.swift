import Foundation

enum AppConstants {
    static let policyURL = URL(string: "https://selka.onkakao.net/sase/policy")!
    static let prodModeURL = URL(string: "https://selka.onkakao.net/sase/prod")!
    static let devModeURL = URL(string: "https://selka.onkakao.net/sase/default")!

    static let logFilePath = "/Library/Logs/PaloAltoNetworks/GlobalProtect/pan_gp_event.log"

    /// The PanGPS daemon log. Unlike the event log, it records the gateway
    /// config pushed on every (re)connect, including the server-authoritative
    /// session expiry (`<user_expires>`, an absolute Unix epoch). We read it to
    /// drive the countdown instead of guessing a fixed `sessionDuration`.
    static let serviceLogFilePath = "/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log"

    /// launchd label for the GlobalProtect menu-bar GUI agent (PanGPA).
    /// Managed in the per-user `gui/<uid>` domain; restarting it does not touch
    /// the privileged VPN service daemon (PanGPS), so the tunnel stays up.
    static let gpGuiLaunchdLabel = "com.paloaltonetworks.gp.pangpa"

    static let policyTimeout: TimeInterval = 3
    static let switchTimeout: TimeInterval = 30
    static let pollingInterval: TimeInterval = 10  // Normal polling
    /// Fallback session length, used only when the real expiry can't be read
    /// from PanGPS.log (`<user_expires>`). Set to match the gateway's observed
    /// lifetime (`<lifetime>` ≈ 35997s ≈ 10h) so the fallback doesn't reproduce
    /// the "expires an hour early" bug when the log is unavailable.
    static let sessionDuration: TimeInterval = 10 * 3600 // 10 hours
}
