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
                    continuation.resume(throwing: VPNControlError.scriptError(errMsg))
                } else {
                    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: output)
                }
            }
        }
    }
}

enum VPNControlError: LocalizedError {
    case actionFailed(VPNControlService.VPNAction)
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .actionFailed(let action):
            let name = action == .connect ? "connect" : "disconnect"
            return "Failed to \(name) VPN"
        case .scriptError(let msg):
            return "Script error: \(msg)"
        }
    }
}
