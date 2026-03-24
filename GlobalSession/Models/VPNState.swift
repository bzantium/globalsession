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

    var expiryTime: Date {
        connectTime.addingTimeInterval(AppConstants.sessionDuration)
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
