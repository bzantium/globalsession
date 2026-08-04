import Foundation

final class VPNControlService {
    enum VPNAction {
        case connect
        case disconnect
    }

    func perform(_ action: VPNAction) async throws {
        // The connect/disconnect control is a single toggle button in
        // GlobalProtect's menu-bar popover. We select it by geometry, not title:
        // it's the full-width button (~202pt), while the only other button — the
        // gateway-favourite star — is a 22pt icon. Geometry stays correct in any
        // system language, unlike the localized title ("연결"/"연결 해제", …).
        // Direction is the caller's responsibility; `action` is only used for the
        // error message.
        //
        // We must target the popover SPECIFICALLY, not "window 1": GlobalProtect
        // also raises status/notification windows (e.g. "연결되었습니다",
        // "만료되었습니다"). Those are AXStandardWindow (~480pt) and, when present,
        // become window 1 — demoting the real popover to window 2. The old
        // "window 1" logic then skipped opening the popover (a window already
        // "existed") and clicked one of the notification's own buttons (also
        // >100pt wide), reporting a false success while the VPN never toggled.
        // The popover is uniquely an AXSystemDialog; `findPopover` filters on that
        // subrole (locale-independent, unlike the window title/description) and
        // ignores notification windows entirely.
        //
        // The popover is an NSPopover that closes the moment it loses focus. If it
        // is already open, use its button directly — clicking the menu-bar item
        // first would merely close it. If it is closed, open it. A popover that
        // stays open without exposing a usable button for one second is treated as
        // stale and reset once before the remaining polling attempts.
        let script = """
        on findPopover()
            -- The menu-bar popover is the only AXSystemDialog window. Notification
            -- windows are AXStandardWindow, so this skips them even when one is
            -- frontmost. `size of window` reads are unreliable while a notification
            -- is up, so we match on subrole alone — never window geometry.
            tell application "System Events" to tell process "GlobalProtect"
                repeat with w in windows
                    try
                        if (subrole of w) is "AXSystemDialog" then return w
                    end try
                end repeat
            end tell
            return missing value
        end findPopover

        tell application "System Events"
            tell process "GlobalProtect"
                -- The menu-bar item is a toggle. Only click it when the popover is
                -- closed; an already-open popover may be immediately actionable. A
                -- notification window does NOT count as the popover being open.
                if (my findPopover()) is missing value then
                    tell menu bar item 1 of menu bar 2 to click
                end if
                repeat with attempt from 1 to 100
                    set didClick to false
                    try
                        set pop to my findPopover()
                        if pop is not missing value then
                            set primary to missing value
                            set widest to 0
                            repeat with b in (every button of pop)
                                if enabled of b then
                                    -- Bind `size of b` first; `item 1 of (size of b)`
                                    -- inline fails because `b` is a live `every button`
                                    -- reference, not a resolved element.
                                    set sz to size of b
                                    set bw to item 1 of sz
                                    if bw > widest then
                                        set widest to bw
                                        set primary to b
                                    end if
                                end if
                            end repeat
                            -- >100pt selects the full-width toggle, never a stray icon.
                            if primary is not missing value and widest > 100 then
                                -- Toggling the VPN dismisses the popover, which can make
                                -- the `click` command itself error even though the click
                                -- registered. Swallow that and still report success —
                                -- otherwise a successful action is reported as a timeout.
                                try
                                    click primary
                                end try
                                set didClick to true
                            end if
                        end if
                    end try
                    if didClick then return "ok"

                    -- Recover once from a genuinely stale/mid-transition popover.
                    -- This happens only after giving an existing usable button a
                    -- full second to appear, so a normally open popup is never
                    -- toggled closed before we try its button.
                    if attempt is 20 then
                        if (my findPopover()) is not missing value then
                            tell menu bar item 1 of menu bar 2 to click
                            repeat 20 times
                                if (my findPopover()) is missing value then exit repeat
                                delay 0.05
                            end repeat
                        end if
                        if (my findPopover()) is missing value then
                            tell menu bar item 1 of menu bar 2 to click
                        end if
                    end if
                    delay 0.05
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
                // caller — e.g. restartGlobalProtectApp — with isBusy=true forever).
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

    /// Runs AppleScript through the `osascript` subprocess rather than
    /// NSAppleScript: the system binary inherits Automation/Accessibility (TCC)
    /// permission reliably — including for ad-hoc-signed debug builds — whereas an
    /// in-process API would require this app itself to be TCC-trusted. A denied
    /// grant surfaces as `.accessibilityDenied` instead of a raw osascript error.
    private func runAppleScript(_ source: String) async throws -> String {
        do {
            return try await runProcess("/usr/bin/osascript", ["-e", source])
        } catch let VPNControlError.scriptError(message) where Self.isAccessibilityDenied(message) {
            throw VPNControlError.accessibilityDenied
        }
    }

    /// -25211 (assistive access) / -1743 (Apple Events) in an osascript error
    /// mean the app lacks the Accessibility/Automation grant.
    private static func isAccessibilityDenied(_ message: String) -> Bool {
        message.contains("-25211") || message.contains("-1743")
            || message.lowercased().contains("assistive access")
            || message.contains("보조 접근")
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
