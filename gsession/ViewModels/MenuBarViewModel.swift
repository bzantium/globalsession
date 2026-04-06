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
    @Published var restartStatus: String?
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
        } else if logConnected && connectionState != .connected {
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
            connectionState = .connected
            policyMode = PolicyMode(from: response.policy)
        } catch {
            if !sessionManager.isConnectedViaLog {
                connectionState = .disconnected
                policyMode = .unknown
            }
        }
    }
}
