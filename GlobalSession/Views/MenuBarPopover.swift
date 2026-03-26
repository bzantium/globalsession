import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()

            if viewModel.connectionState == .connected {
                sessionTimerSection
                Divider()
            } else if viewModel.connectionState == .disconnected {
                disconnectedSection
                Divider()
            }

            if viewModel.isSwitchingMode, let toProd = viewModel.switchingToProd {
                Text("Switching to \(toProd ? "Prod" : "Dev")...")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(12)
                Divider()
            } else if viewModel.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Stabilizing VPN... (Switching Disabled)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                Divider()
            } else if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .help(error)
                    .padding(12)
                Divider()
            }

            footerSection
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.connectionState == .connected ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            Text(statusText)
                .font(.headline)

            Spacer()

            if viewModel.connectionState == .connected {
                modeToggle
            }
        }
        .padding(12)
    }

    private var statusText: String {
        switch viewModel.connectionState {
        case .connected: return "VPN Connected"
        case .disconnected: return "VPN Disconnected"
        case .unknown: return "Checking..."
        }
    }

    // MARK: - Mode Toggle

    @State private var isDevHovered = false
    @State private var isProdHovered = false

    private var modeToggle: some View {
        let isProd = viewModel.policyMode == .prod

        let switching = viewModel.isSwitchingMode
        let disabled = switching || viewModel.isBusy

        return HStack(spacing: 0) {
            Text("Dev")
                .font(.caption2)
                .fontWeight(.semibold)
                .frame(width: 36, height: 22)
                .background(!isProd ? Color.blue.opacity(switching ? 0 : 1) : Color.clear)
                .foregroundColor(!isProd ? .white.opacity(switching ? 0.5 : 1) : (isDevHovered && !disabled ? .white : .gray))
                .contentShape(Rectangle())
                .onHover { isDevHovered = $0 }
                .onTapGesture { if isProd && !disabled { viewModel.switchMode(to: .dev) } }

            Text("Prod")
                .font(.caption2)
                .fontWeight(.semibold)
                .frame(width: 36, height: 22)
                .background(isProd ? Color.orange.opacity(switching ? 0 : 1) : Color.clear)
                .foregroundColor(isProd ? .white.opacity(switching ? 0.5 : 1) : (isProdHovered && !disabled ? .white : .gray))
                .contentShape(Rectangle())
                .onHover { isProdHovered = $0 }
                .onTapGesture { if !isProd && !disabled { viewModel.switchMode(to: .prod) } }
        }
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .overlay {
            if viewModel.isSwitchingMode {
                ModeWaveOverlay(toProd: viewModel.switchingToProd ?? true)
            }
        }
    }

    // MARK: - Session Timer

    private var sessionTimerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Session")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                Text(timerText)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    LinearGradient(
                        stops: [
                            .init(color: .red, location: 0),
                            .init(color: .orange, location: 0.15),
                            .init(color: .yellow, location: 0.35),
                            .init(color: .green, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .mask(
                        HStack {
                            Rectangle().frame(width: geo.size.width * progressFraction)
                            Spacer(minLength: 0)
                        }
                    )
                }
            }
            .frame(height: 6)

            if let connectTime = viewModel.sessionManager.sessionInfo?.connectTime {
                HStack {
                    Text("Connected at \(connectTime, format: .dateTime.hour().minute()) (\(connectTime, format: .dateTime.month(.defaultDigits).day(.twoDigits)))")
                        .font(.caption2)
                        .foregroundColor(.white)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var timerText: String {
        let remaining = viewModel.sessionManager.remainingSeconds
        guard remaining > 0 else { return "Expired" }
        let total = max(0, Int(remaining))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    private var progressFraction: CGFloat {
        let remaining = viewModel.sessionManager.remainingSeconds
        guard remaining > 0 else { return 0 }
        return CGFloat(remaining / AppConstants.sessionDuration)
    }

    // MARK: - Disconnected

    @State private var isGPHovered = false

    private var disconnectedSection: some View {
        VStack(spacing: 8) {
            Text("Not connected to VPN")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Open GlobalProtect")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isGPHovered ? Color.blue : Color.blue.opacity(0.7))
                )
                .contentShape(Rectangle())
                .onHover { isGPHovered = $0 }
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/GlobalProtect.app"))
                }
        }
        .padding(12)
    }

    // MARK: - Footer

    @State private var isQuitHovered = false

    private var footerSection: some View {
        HStack {
            Text("Quit")
                .font(.caption)
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (isQuitHovered ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        )
        .contentShape(Rectangle())
        .onHover { isQuitHovered = $0 }
        .onTapGesture { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - Wave Gradient Animation

struct ModeWaveOverlay: View {
    let toProd: Bool
    @State private var phase: CGFloat = 0

    private var targetColor: Color { toProd ? .orange : .blue }
    private var sourceColor: Color { toProd ? .blue : .orange }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack(alignment: toProd ? .trailing : .leading) {
                    sourceColor
                    LinearGradient(
                        colors: [targetColor, targetColor, sourceColor.opacity(0)],
                        startPoint: toProd ? .trailing : .leading,
                        endPoint: toProd ? .leading : .trailing
                    )
                    .frame(width: geo.size.width * phase)
                }
            }
            .frame(width: 72, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(0.6)

            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        }
        .frame(width: 72, height: 22)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }
}
