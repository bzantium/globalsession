import Foundation

enum AppConstants {
    static let policyURL = URL(string: "https://selka.onkakao.net/sase/policy")!
    static let prodModeURL = URL(string: "https://selka.onkakao.net/sase/prod")!
    static let devModeURL = URL(string: "https://selka.onkakao.net/sase/default")!

    static let logFilePath = "/Library/Logs/PaloAltoNetworks/GlobalProtect/pan_gp_event.log"

    /// launchd label for the GlobalProtect menu-bar GUI agent (PanGPA).
    /// Managed in the per-user `gui/<uid>` domain; restarting it does not touch
    /// the privileged VPN service daemon (PanGPS), so the tunnel stays up.
    static let gpGuiLaunchdLabel = "com.paloaltonetworks.gp.pangpa"

    static let policyTimeout: TimeInterval = 3
    static let switchTimeout: TimeInterval = 30
    static let pollingInterval: TimeInterval = 10  // Normal polling
    static let sessionDuration: TimeInterval = 9 * 3600 // 9 hours
}
