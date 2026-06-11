import SwiftUI

enum ConnectionState: Equatable {
    case connected
    case disconnected
    case unknown
}

enum PolicyMode: String, Equatable {
    case prod
    case dev
    case unknown

    init(from policy: String) {
        self = policy == "prod" ? .prod : .dev
    }

    var label: String {
        switch self {
        case .prod: return "Prod"
        case .dev: return "Dev"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .prod: return .orange
        case .dev: return .blue
        case .unknown: return .gray
        }
    }

    var apiURL: URL {
        switch self {
        case .prod: return AppConstants.prodModeURL
        case .dev, .unknown: return AppConstants.devModeURL
        }
    }
}

enum TimerAlertLevel {
    case safe       // > 10 min, green
    case warning    // 1-10 min, orange
    case critical   // < 1 min, red
    case expired

    var color: Color {
        switch self {
        case .safe: return .green
        case .warning: return .orange
        case .critical: return .red
        case .expired: return .red
        }
    }

    init(remaining: TimeInterval) {
        switch remaining {
        case ..<0: self = .expired
        case 0..<60: self = .critical
        case 60..<600: self = .warning
        default: self = .safe
        }
    }
}

struct SessionInfo {
    let connectTime: Date
    /// Server-authoritative expiry from GlobalProtect's gateway config
    /// (`<user_expires>` in PanGPS.log). `nil` when it couldn't be read, in
    /// which case we fall back to a fixed `sessionDuration`.
    let expiry: Date?

    init(connectTime: Date, expiry: Date? = nil) {
        self.connectTime = connectTime
        self.expiry = expiry
    }

    var expiryTime: Date {
        expiry ?? connectTime.addingTimeInterval(AppConstants.sessionDuration)
    }

    /// Total session length, used to scale the countdown progress bar so it
    /// reflects the real lifetime (~10h) rather than the fallback constant.
    var totalDuration: TimeInterval {
        max(1, expiryTime.timeIntervalSince(connectTime))
    }

    var remainingSeconds: TimeInterval {
        expiryTime.timeIntervalSinceNow
    }

    var alertLevel: TimerAlertLevel {
        TimerAlertLevel(remaining: remainingSeconds)
    }
}

struct PolicyResponse: Decodable {
    let policy: String
}
