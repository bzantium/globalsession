import Foundation
import Combine

final class SessionManager: ObservableObject {
    @Published var sessionInfo: SessionInfo?
    @Published var remainingSeconds: TimeInterval = 0
    @Published var alertLevel: TimerAlertLevel = .safe

    let logParser = LogParser()
    private var countdownTimer: Timer?

    // Cache the (expensive) PanGPS.log expiry lookup, refreshing it only when a
    // new connection appears — the expiry is fixed for the life of a session.
    private var cachedExpiryConnectTime: Date?
    private var cachedExpiry: Date?

    var isConnectedViaLog: Bool {
        logParser.parseLatestSession() != nil
    }

    var isExpired: Bool {
        sessionInfo != nil && remainingSeconds <= 0
    }

    func startMonitoring() {
        refreshSessionInfo()
        startCountdown()
    }

    func stopMonitoring() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Drops the cached expiry so the next `refreshSessionInfo()` re-reads
    /// PanGPS.log. The expiry is normally cached for the life of a connection
    /// (keyed on connectTime); this forces a re-read to pick up a mid-session
    /// lifetime change that routine polling would otherwise skip. Backs the
    /// manual refresh button.
    func invalidateExpiryCache() {
        cachedExpiryConnectTime = nil
    }

    func refreshSessionInfo() {
        guard let base = logParser.parseLatestSession() else {
            sessionInfo = nil
            updateTimerState()
            return
        }

        // Re-read the expiry from PanGPS.log only when the connection is new;
        // for an ongoing session the cached value is reused every tick.
        if cachedExpiryConnectTime != base.connectTime {
            if let parsed = logParser.parseSessionExpiry(),
               let blockTime = parsed.blockTime,
               blockTime >= base.connectTime,
               parsed.expiry > base.connectTime {
                // The gateway config block was logged at/after this connect, so
                // its <user_expires> belongs to the current session — lock it in.
                cachedExpiry = parsed.expiry
                cachedExpiryConnectTime = base.connectTime
            } else {
                // A fresh connect writes <user_expires> a few seconds after the
                // connect event (and any expiry already in the log is from the
                // previous session). Use the fallback for now and retry on the
                // next tick — deliberately NOT caching, so connectTime stays
                // "unseen" until the real block appears.
                cachedExpiry = nil
            }
        }

        sessionInfo = SessionInfo(connectTime: base.connectTime, expiry: cachedExpiry)
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
