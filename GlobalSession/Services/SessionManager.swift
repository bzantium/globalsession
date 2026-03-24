import Foundation
import Combine

final class SessionManager: ObservableObject {
    @Published var sessionInfo: SessionInfo?
    @Published var remainingSeconds: TimeInterval = 0
    @Published var alertLevel: TimerAlertLevel = .safe

    let logParser = LogParser()
    private var countdownTimer: Timer?

    var isConnectedViaLog: Bool {
        logParser.parseLatestSession() != nil
    }

    func startMonitoring() {
        refreshSessionInfo()
        startCountdown()
    }

    func stopMonitoring() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func refreshSessionInfo() {
        sessionInfo = logParser.parseLatestSession()
        updateTimerState()
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateTimerState()
        }
    }

    private func updateTimerState() {
        guard let session = sessionInfo else {
            remainingSeconds = 0
            alertLevel = .safe
            return
        }
        remainingSeconds = session.remainingSeconds
        alertLevel = TimerAlertLevel(remaining: remainingSeconds)
    }
}
