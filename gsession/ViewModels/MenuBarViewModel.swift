import SwiftUI
import Combine

final class MenuBarViewModel: ObservableObject {
    @Published var connectionState: ConnectionState = .unknown
    @Published var policyMode: PolicyMode = .unknown
    @Published var isSwitchingMode = false
    @Published var switchingToProd: Bool? = nil  // nil = not switching, true = →prod, false = →dev
    @Published var lastError: String?

    let sessionManager = SessionManager()

    private let policyService = PolicyService()
    private let vpnControl = VPNControlService()
    @Published var isVPNToggling = false
    @Published var isRestarting = false
    @Published var isRestartingApp = false
    @Published var isRefreshing = false
    @Published var restartStatus: String?

    /// Consecutive policy-fetch failures. The policy endpoint returns 200 only
    /// through the tunnel, so a sustained failure is an authoritative disconnect
    /// signal that may override a stale log (defense in depth for the log parser).
    private var policyFailureStreak = 0
    private static let policyFailureThreshold = 3
    /// Set once the policy probe has confirmed the tunnel is down. While true, a
    /// stale "connected" log line must not flip the UI back to connected.
    private var policyConfirmedDown = false
    private var logTimer: Timer?
    private var errorDismissTask: Task<Void, Never>?
    private var policyTimer: Timer?
    @Published var isBusy = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        sessionManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        startPolling()
    }

    deinit {
        logTimer?.invalidate()
        policyTimer?.invalidate()
    }

    // MARK: - Actions

    func switchMode(to mode: PolicyMode) {
        guard !isSwitchingMode, !isBusy else { return }
        Task {
            await MainActor.run {
                isSwitchingMode = true
                switchingToProd = (mode == .prod)
                isBusy = true
                lastError = nil
            }
            do {
                try await policyService.switchMode(mode)
                await MainActor.run {
                    policyMode = mode
                    isSwitchingMode = false
                    switchingToProd = nil
                }
                // Keep isBusy=true until correct mode is confirmed twice consecutively
                await policyService.waitForStability(expectedMode: mode)
                await MainActor.run { isBusy = false }
            } catch {
                let msg = "Failed to switch to \(mode.label): \(error.localizedDescription)"
                await MainActor.run {
                    self.showError(msg)
                    isBusy = false
                    isSwitchingMode = false
                    switchingToProd = nil
                }
            }
        }
    }

    func connectVPN() {
        guard !isVPNToggling, !isBusy else { return }
        isVPNToggling = true
        isBusy = true
        Task {
            do {
                // The popover control is a toggle clicked by position, so skip it
                // when the (authoritative, locale-free) GlobalProtect log already
                // reports the target state — otherwise a stale connectionState
                // would toggle the wrong way and disconnect a live session.
                let alreadyConnected = await MainActor.run { sessionManager.isConnectedViaLog }
                if !alreadyConnected {
                    try await vpnControl.perform(.connect)
                    await policyService.waitForStability()
                }
                // Set connected state before clearing flags to avoid flash
                await MainActor.run { connectionState = .connected }
            } catch {
                await MainActor.run { showError(error.localizedDescription) }
            }
            await MainActor.run {
                isVPNToggling = false
                isBusy = false
            }
        }
    }

    func disconnectVPN() {
        guard !isVPNToggling, !isBusy else { return }
        isVPNToggling = true
        isBusy = true
        Task {
            do {
                // Skip the toggle if the GlobalProtect log already reports
                // disconnected — clicking it then would connect instead (see
                // connectVPN for the rationale).
                let alreadyDisconnected = await MainActor.run { !sessionManager.isConnectedViaLog }
                if !alreadyDisconnected {
                    try await vpnControl.perform(.disconnect)
                    // Wait until VPN is actually disconnected
                    for _ in 0..<15 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let stillConnected = await MainActor.run {
                            sessionManager.refreshSessionInfo()
                            return sessionManager.isConnectedViaLog
                        }
                        if !stillConnected { break }
                    }
                }
                await MainActor.run {
                    connectionState = .disconnected
                    policyMode = .unknown
                }
            } catch {
                await MainActor.run { showError(error.localizedDescription) }
            }
            await MainActor.run {
                isVPNToggling = false
                isBusy = false
            }
        }
    }

    func restartVPN() {
        guard !isVPNToggling, !isBusy else { return }
        isVPNToggling = true
        isBusy = true
        isRestarting = true
        restartStatus = "Disconnecting..."
        lastError = nil
        Task {
            // Step 1 & 2: Disconnect, then confirm via the log. The click may throw
            // yet still have taken effect (and is a toggle clicked by position), so
            // we don't trust its result — we poll the log. Restart is only offered
            // while connected, but guard anyway so we never toggle the wrong way.
            let startedConnected = await MainActor.run { sessionManager.isConnectedViaLog }
            if startedConnected {
                try? await vpnControl.perform(.disconnect)
                await MainActor.run { restartStatus = "Settling..." }
                if !(await waitForLog(connected: false, seconds: 15)) {
                    await endRestart(error: "Restart failed: the VPN did not disconnect.")
                    return
                }
                // Brief settle so GlobalProtect will accept a fresh connect.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            // Step 3: Reconnect with a single click, then confirm via the log.
            // After a confirmed disconnect one click reconnects a still-valid
            // session; but if the session has expired, that same click hands off to
            // GlobalProtect's own sign-in flow (browser / credentials / MFA). We
            // must NOT retry the click — a second click would disrupt or cancel that
            // sign-in — so we click once and wait. If the tunnel doesn't come up in
            // time, the user most likely needs to finish signing in; we say so and
            // let routine log polling flip the UI to connected once they do.
            await MainActor.run { restartStatus = "Reconnecting..." }
            do {
                try await vpnControl.perform(.connect)
            } catch {
                await endRestart(error: "Restart failed during reconnect: \(error.localizedDescription)")
                return
            }
            if await waitForLog(connected: true, seconds: 40) {
                await MainActor.run { connectionState = .connected }
                await endRestart()
            } else {
                // Not up yet — expired session waiting on sign-in is the usual
                // reason. Don't re-click; let the user finish authenticating.
                await endRestart(error: "Almost there — sign in to GlobalProtect to finish reconnecting.")
            }
        }
    }

    /// Polls the GlobalProtect log once a second for up to `seconds`, returning
    /// true as soon as it reports the desired `connected` state (and false if the
    /// window elapses first). The log is the authoritative, locale-free signal for
    /// tunnel state, so both the disconnect and reconnect steps of a restart wait
    /// on it rather than trusting the AppleScript click's return.
    private func waitForLog(connected target: Bool, seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let connected = await MainActor.run {
                sessionManager.refreshSessionInfo()
                return sessionManager.isConnectedViaLog
            }
            if connected == target { return true }
        }
        return false
    }

    /// Clears the restart flags (and optionally surfaces an error) on the main
    /// actor. Every restart exit path funnels through here so none can leave the
    /// UI stuck in the "Restarting…" state.
    private func endRestart(error: String? = nil) async {
        await MainActor.run {
            if let error { showError(error) }
            isVPNToggling = false
            isBusy = false
            isRestarting = false
            restartStatus = nil
        }
    }

    /// Kills and relaunches the GlobalProtect GUI app (not the VPN service).
    /// Use when the menu-bar UI is stuck. The VPN tunnel stays connected.
    func restartGPProcess() {
        guard !isVPNToggling, !isBusy, !isRestartingApp else { return }
        isRestartingApp = true
        isBusy = true
        lastError = nil
        Task {
            do {
                try await vpnControl.restartGlobalProtectApp()
                // Give the relaunched GUI a moment to register its menu-bar item
                // before allowing AppleScript-driven actions again.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                await MainActor.run { showError("Failed to restart GlobalProtect: \(error.localizedDescription)") }
            }
            await MainActor.run {
                isRestartingApp = false
                isBusy = false
            }
        }
    }

    /// Forces an immediate re-evaluation of connection state (log + policy),
    /// bypassing the poll timers. Backing for the refresh button.
    func refresh() {
        guard !isBusy, !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        // Force a re-read of the session expiry (routine polling reuses the
        // cached value for the life of a connection).
        sessionManager.invalidateExpiryCache()
        checkLog()
        Task {
            await forceCheckPolicy()
            await MainActor.run { isRefreshing = false }
        }
    }

    private func showError(_ message: String) {
        lastError = message
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { lastError = nil }
        }
    }

    // MARK: - Private

    private func startPolling() {
        sessionManager.startMonitoring()
        checkLog()
        Task { await checkPolicy() }

        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkLog()
        }

        policyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.checkPolicy() }
        }
    }

    private func checkLog() {
        guard !isBusy else { return }

        sessionManager.refreshSessionInfo()
        let logConnected = sessionManager.isConnectedViaLog

        if sessionManager.isExpired {
            connectionState = .disconnected
            policyMode = .unknown
        } else if logConnected && connectionState != .connected && !policyConfirmedDown {
            // Trust a log "connected" only when the policy probe hasn't confirmed
            // the tunnel is down — otherwise a stale log line would resurrect a
            // false "VPN Connected".
            connectionState = .connected
        } else if !logConnected && connectionState == .connected && policyConfirmedDown {
            // Only tear down to disconnected when the authoritative policy/route
            // probe agrees. The log alone can produce false negatives (GP
            // silently re-establishes the tunnel after a transient drop without
            // logging a new connect), which previously fought the 5s policy poll
            // and made the icon blink connected<->disconnected every cycle.
            connectionState = .disconnected
            policyMode = .unknown
        }
    }

    @MainActor
    private func checkPolicy() async {
        guard !isBusy else { return }
        await forceCheckPolicy()
    }

    @MainActor
    private func forceCheckPolicy() async {
        guard !sessionManager.isExpired else { return }
        do {
            let response = try await policyService.fetchPolicy()
            policyFailureStreak = 0
            policyConfirmedDown = false
            connectionState = .connected
            policyMode = PolicyMode(from: response.policy)
        } catch {
            policyFailureStreak += 1
            // A failed policy fetch is ambiguous: the endpoint is unreachable both
            // when the VPN is down AND when the VPN is up but the policy server
            // itself is down. The kernel routing table breaks the tie — while
            // GlobalProtect is connected it owns the default route (a utun).
            let tunnelUp = await Task.detached { NetworkRoute.defaultRouteIsTunnel() }.value
            if tunnelUp {
                // VPN is genuinely up; only the policy server is unreachable.
                // Stay connected and keep the last known mode until it returns.
                policyConfirmedDown = false
                connectionState = .connected
            } else if !sessionManager.isConnectedViaLog || policyFailureStreak >= Self.policyFailureThreshold {
                // Tunnel is gone and either the log agrees or the failure is
                // sustained — authoritatively disconnected.
                policyConfirmedDown = true
                connectionState = .disconnected
                policyMode = .unknown
            }
        }
    }
}
