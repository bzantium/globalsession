import Foundation

final class VPNControlService {
    enum VPNAction {
        case connect
        case disconnect
    }

    func perform(_ action: VPNAction) async throws {
        let buttonName: String
        let expectedState: String

        switch action {
        case .connect:
            buttonName = "연결"
            expectedState = "연결 해제됨"
        case .disconnect:
            buttonName = "연결 해제"
            expectedState = "연결됨"
        }

        let script = """
        tell application "System Events"
            tell process "GlobalProtect"
                -- Close stale popup if open, then reopen fresh
                if exists window 1 then
                    tell menu bar item 1 of menu bar 2
                        click
                    end tell
                    delay 0.3
                end if
                -- Open popup
                tell menu bar item 1 of menu bar 2
                    click
                end tell
                repeat 15 times
                    delay 0.5
                    try
                        if exists window 1 then
                            set allText to name of every static text of window 1
                            if allText contains "\(expectedState)" then
                                click button "\(buttonName)" of window 1
                                return "ok"
                            end if
                        end if
                    end try
                end repeat
                return "timeout"
            end tell
        end tell
        """

        let result = try await runAppleScript(script)
        if result != "ok" {
            throw VPNControlError.actionFailed(action)
        }
    }

    /// Restarts the GlobalProtect menu-bar GUI app (PanGPA).
    ///
    /// This targets only the GUI process, not the root VPN service daemon
    /// (`PanGPS`), so it requires no admin privileges and does not drop the
    /// active VPN tunnel. Use it when the menu-bar UI becomes unresponsive and
    /// AppleScript clicks stop working.
    ///
    /// Preferred path is `launchctl kickstart -k`, which asks launchd to kill
    /// the running instance and relaunch it under its own supervision — more
    /// robust than a manual kill+open because launchd owns the lifecycle. If
    /// that fails (e.g. the launchd label changed in a future GP version), we
    /// fall back to `killall` + `open`.
    func restartGlobalProtectApp() async throws {
        let target = "gui/\(getuid())/\(AppConstants.gpGuiLaunchdLabel)"
        do {
            // -k: kill the current instance before restarting it.
            try await runProcess("/bin/launchctl", ["kickstart", "-k", target])
            return
        } catch {
            // Fall through to the legacy kill + relaunch path.
        }

        // killall exits non-zero if the process isn't running ("No matching
        // processes"). That's fine — we just want it dead before relaunching,
        // so we ignore its exit status.
        _ = try? await runProcess("/usr/bin/killall", ["GlobalProtect"])

        // Give the process a moment to fully terminate before relaunching.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Relaunch the GUI app. `open` resolves the bundle by name.
        try await runProcess("/usr/bin/open", ["-a", "GlobalProtect"])
    }

    /// Runs an arbitrary executable and returns its trimmed stdout.
    /// Throws `VPNControlError.scriptError` on non-zero exit.
    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: VPNControlError.scriptError("Failed to launch \(launchPath): \(error.localizedDescription)"))
                    return
                }

                // Kill the process if it hangs, so the continuation always
                // resumes (otherwise a stuck launchctl/open would wedge the
                // caller — e.g. restartGPProcess — with isBusy=true forever).
                let timeout = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()

                if process.terminationStatus != 0 {
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                    continuation.resume(throwing: VPNControlError.scriptError(errMsg))
                } else {
                    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: output)
                }
            }
        }
    }

    /// Runs AppleScript via the `osascript` subprocess instead of NSAppleScript.
    /// This avoids the Accessibility/TCC permission issue where the app itself
    /// would need to be in the Accessibility list. The system `osascript` binary
    /// inherits permissions more reliably, especially for ad-hoc signed debug builds.
    private func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: VPNControlError.scriptError("Failed to launch osascript: \(error.localizedDescription)"))
                    return
                }

                // Kill osascript if it hangs longer than 15 seconds
                let timeout = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()

                if process.terminationStatus != 0 {
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                    // -25211 (assistive access) / -1743 (Apple Events) mean the
                    // app lacks Accessibility/Automation permission. Surface a
                    // clear, actionable error instead of the raw "...:133:148:
                    // execution error ... (-25211)" string.
                    if errMsg.contains("-25211") || errMsg.contains("-1743")
                        || errMsg.lowercased().contains("assistive access")
                        || errMsg.contains("보조 접근") {
                        continuation.resume(throwing: VPNControlError.accessibilityDenied)
                    } else {
                        continuation.resume(throwing: VPNControlError.scriptError(errMsg))
                    }
                } else {
                    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: output)
                }
            }
        }
    }
}

/// Kernel-level view of VPN connectivity, independent of the policy HTTP
/// endpoint and the GlobalProtect log. GlobalProtect runs a full-tunnel SASE
/// config, so while connected it owns the system default route via a `utun`
/// interface; when it drops, the default route reverts to the physical
/// interface (Wi-Fi/Ethernet). This lets us tell "VPN is down" apart from
/// "VPN is up but the policy server is unreachable" — which look identical to
/// the policy fetch and the log.
enum NetworkRoute {
    /// True if the system default route currently egresses a tunnel (`utun`)
    /// interface, i.e. a full-tunnel VPN like GlobalProtect is active.
    ///
    /// Note: this can't distinguish GlobalProtect from another full-tunnel VPN
    /// that also owns the default route (e.g. a Tailscale exit node). That's an
    /// uncommon setup and only matters when the policy server is also down.
    static func defaultRouteIsTunnel() -> Bool {
        defaultRouteInterface()?.hasPrefix("utun") ?? false
    }

    private static func defaultRouteInterface() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed
                    .replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

enum VPNControlError: LocalizedError {
    case actionFailed(VPNControlService.VPNAction)
    case scriptError(String)
    case accessibilityDenied

    var errorDescription: String? {
        switch self {
        case .actionFailed(let action):
            let name = action == .connect ? "connect" : "disconnect"
            return "Failed to \(name) VPN"
        case .scriptError(let msg):
            return "Script error: \(msg)"
        case .accessibilityDenied:
            return "Accessibility permission needed. Grant gsession in System Settings → Privacy & Security → Accessibility."
        }
    }
}
