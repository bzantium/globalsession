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
                try await vpnControl.perform(.connect)
                await policyService.waitForStability()
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

            // Step 1: Disconnect
            // The AppleScript may throw (timeout, permission error) even though it
            // partially succeeded (clicked the disconnect button). So on failure,
            // poll the log to see if the VPN actually disconnected before giving up.
            do {
                try await vpnControl.perform(.disconnect)
            } catch {
                // Script errored – but the VPN might still be disconnecting.
                // Wait up to 10 seconds, checking every second.
                var disconnected = false
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let stillConnected = await MainActor.run {
                        sessionManager.refreshSessionInfo()
                        return sessionManager.isConnectedViaLog
                    }
                    if !stillConnected {
                        disconnected = true
                        break
                    }
                }
                if !disconnected {
                    await MainActor.run {
                        showError("Restart failed during disconnect: \(error.localizedDescription)")
                        isVPNToggling = false
                        isBusy = false
                        isRestarting = false
                        restartStatus = nil
                    }
                    return
                }
                // VPN did disconnect despite the script error – continue restart flow.
            }

            // Step 2: Wait for VPN to fully disconnect (confirmed via log)
            await MainActor.run { restartStatus = "Settling..." }
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let stillConnected = await MainActor.run {
                    sessionManager.refreshSessionInfo()
                    return sessionManager.isConnectedViaLog
                }
                if !stillConnected { break }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000) // extra settle time

            // Step 3: Reconnect
            await MainActor.run { restartStatus = "Reconnecting..." }
            do {
                try await vpnControl.perform(.connect)
            } catch {
                await MainActor.run {
                    showError("Restart failed during reconnect: \(error.localizedDescription)")
                    isVPNToggling = false
                    isBusy = false
                    isRestarting = false
                    restartStatus = nil
                }
                return
            }

            await MainActor.run {
                isVPNToggling = false
                isBusy = false
                isRestarting = false
                restartStatus = nil
            }
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
        } else if !logConnected && connectionState == .connected {
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
