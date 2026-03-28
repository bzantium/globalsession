import Foundation

final class PolicyService {
    private let policySession: URLSession
    private let switchSession: URLSession

    init() {
        let policyConfig = URLSessionConfiguration.ephemeral
        policyConfig.timeoutIntervalForRequest = AppConstants.policyTimeout
        policyConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.policySession = URLSession(configuration: policyConfig)

        let switchConfig = URLSessionConfiguration.ephemeral
        switchConfig.timeoutIntervalForRequest = AppConstants.switchTimeout
        switchConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.switchSession = URLSession(configuration: switchConfig)
    }

    func fetchPolicy() async throws -> PolicyResponse {
        let (data, response) = try await policySession.data(from: AppConstants.policyURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PolicyError.notConnected
        }
        return try JSONDecoder().decode(PolicyResponse.self, from: data)
    }

    func switchMode(_ mode: PolicyMode) async throws {
        var request = URLRequest(url: mode.apiURL)
        request.httpMethod = "POST"
        let (_, response) = try await switchSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PolicyError.switchFailed
        }
    }

    func waitForStability(expectedMode: PolicyMode? = nil) async -> Bool {
        var consecutiveMatches = 0
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let response = try? await fetchPolicy() {
                if let expected = expectedMode {
                    if PolicyMode(from: response.policy) == expected {
                        consecutiveMatches += 1
                        if consecutiveMatches >= 2 { return true }
                    } else {
                        consecutiveMatches = 0
                    }
                } else {
                    return true
                }
            } else {
                consecutiveMatches = 0
            }
        }
        return false
    }
}

enum PolicyError: LocalizedError {
    case notConnected
    case switchFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "VPN is not connected"
        case .switchFailed: return "Failed to switch policy mode"
        }
    }
}
