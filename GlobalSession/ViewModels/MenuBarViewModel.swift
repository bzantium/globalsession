import SwiftUI
import Combine

final class MenuBarViewModel: ObservableObject {
    @Published var connectionState: ConnectionState = .unknown
    @Published var policyMode: PolicyMode = .unknown
    @Published var isSwitchingMode = false
    @Published var switchingToProd: Bool? = nil  // nil = not switching, true = →prod, false = →dev
    @Published var modeCooldown = 0  // cooldown seconds remaining
    @Published var lastError: String?

    let sessionManager = SessionManager()

    private let policyService = PolicyService()
    private var logTimer: Timer?
    private var errorDismissTask: Task<Void, Never>?
    private var policyTimer: Timer?
    private var isBusy = false  // Pause polling during mode switch
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
        guard !isSwitchingMode, modeCooldown <= 0 else { return }
        Task {
            await MainActor.run {
                isSwitchingMode = true
                switchingToProd = (mode == .prod)
                isBusy = true
                lastError = nil
            }
            var success = false
            do {
                try await policyService.switchMode(mode)
                await MainActor.run { policyMode = mode }
                success = true
            } catch {
                let msg = "Failed to switch to \(mode.label): \(error.localizedDescription)"
                await MainActor.run { self.showError(msg) }
            }
            await MainActor.run {
                isBusy = false
                isSwitchingMode = false
                switchingToProd = nil
            }
            // 10s cooldown only on success
            if success {
                await MainActor.run { modeCooldown = 10 }
                for i in stride(from: 9, through: 0, by: -1) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await MainActor.run { modeCooldown = i }
                }
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

        if logConnected && connectionState != .connected {
            connectionState = .connected
        } else if !logConnected && connectionState == .connected {
            connectionState = .disconnected
            policyMode = .unknown
        }
    }

    @MainActor
    private func checkPolicy() async {
        guard !isBusy, modeCooldown <= 0 else { return }
        await forceCheckPolicy()
    }

    @MainActor
    private func forceCheckPolicy() async {
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
