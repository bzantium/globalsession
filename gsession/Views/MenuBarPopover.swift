import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()

            if viewModel.isRestarting {
                restartingSection
                Divider()
            } else if viewModel.connectionState == .connected && !viewModel.isVPNToggling {
                sessionTimerSection
                Divider()
                disconnectSection
                Divider()
            } else if viewModel.isVPNToggling {
                vpnTogglingSection
                Divider()
            } else if viewModel.connectionState == .disconnected {
                disconnectedSection
                Divider()
            }

            if viewModel.isSwitchingMode, let toProd = viewModel.switchingToProd {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    ShimmerText("Switching to \(toProd ? "Prod" : "Dev")...")
                }
                .padding(12)
                Divider()
            } else if viewModel.isBusy && !viewModel.isRestarting && !viewModel.isVPNToggling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    ShimmerText(viewModel.isRestartingApp ? "Restarting GlobalProtect..." : "Stabilizing VPN...")
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

            queryPieSection
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)

            Text(statusText)
                .font(.headline)

            Spacer()

            refreshButton

            if viewModel.connectionState == .connected && !viewModel.isRestarting && !viewModel.isVPNToggling {
                modeToggle
            }
        }
        .padding(12)
    }

    // MARK: - Refresh

    @State private var isRefreshHovered = false

    private var refreshButton: some View {
        Group {
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(isRefreshHovered && !viewModel.isBusy ? .white : .secondary)
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .help("Refresh connection status")
        .onHover { isRefreshHovered = $0 }
        .onTapGesture {
            if !viewModel.isBusy && !viewModel.isRefreshing { viewModel.refresh() }
        }
    }

    private var statusDotColor: Color {
        if viewModel.isRestarting || viewModel.isVPNToggling { return .orange }
        return viewModel.connectionState == .connected ? .green : .red
    }

    private var statusText: String {
        if viewModel.isRestarting { return "Restarting VPN..." }
        if viewModel.isVPNToggling {
            return viewModel.connectionState == .connected ? "Disconnecting..." : "Connecting..."
        }
        switch viewModel.connectionState {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
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
                    Text("Connected at \(connectTime, format: .dateTime.hour().minute()) (\(connectTime, format: .dateTime.month(.defaultDigits).day(.twoDigits))/\(connectTime, format: .dateTime.year()))")
                        .font(.caption2)
                        .foregroundColor(.white)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var timerText: String {
        guard viewModel.sessionManager.sessionInfo != nil else { return "Unavailable" }
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
        // Scale by the actual session length (from GP) so the bar starts full
        // and drains over the real ~10h lifetime, not the fallback constant.
        let total = viewModel.sessionManager.sessionInfo?.totalDuration ?? AppConstants.sessionDuration
        return CGFloat(min(1, remaining / total))
    }

    // MARK: - QueryPie Session

    @State private var isQueryPieOpenHovered = false

    private var queryPieSection: some View {
        let manager = viewModel.queryPieSessionManager

        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundColor(queryPieStatusColor)
                Text("QueryPie")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                Spacer()

                Text(queryPieTimerText)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(queryPieStatusColor)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(queryPieStatusColor)
                    .frame(width: 6, height: 6)
                Text(queryPieStatusText)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if manager.isAuthenticated, let expiry = manager.expiry {
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("until \(expiry, format: .dateTime.hour().minute())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(manager.isRunning ? "Show" : "Open")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(isQueryPieOpenHovered && manager.isInstalled ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isQueryPieOpenHovered && manager.isInstalled ? Color.white.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .help(manager.isInstalled ? "Open QueryPie Multi Agent" : "QueryPie Multi Agent is not installed")
                    .onHover { isQueryPieOpenHovered = $0 }
                    .onTapGesture {
                        if manager.isInstalled { manager.openApplication() }
                    }
            }
        }
        .padding(12)
    }

    private var queryPieTimerText: String {
        let manager = viewModel.queryPieSessionManager
        guard manager.isRunning else { return "--:--:--" }
        guard manager.expiry != nil else { return "Checking…" }
        guard manager.remainingSeconds > 0 else { return "Expired" }
        return formattedDuration(manager.remainingSeconds)
    }

    private var queryPieStatusText: String {
        let manager = viewModel.queryPieSessionManager
        if !manager.isInstalled { return "Not installed" }
        if !manager.isRunning { return "Not running" }
        if manager.expiry == nil { return "Session unavailable" }
        return manager.remainingSeconds > 0 ? "Agent session" : "Sign-in required"
    }

    private var queryPieStatusColor: Color {
        let manager = viewModel.queryPieSessionManager
        guard manager.isRunning, manager.expiry != nil else { return .gray }
        return manager.alertLevel.color
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Disconnected

    @State private var isGPHovered = false

    private var disconnectedSection: some View {
        VStack(spacing: 8) {
            if viewModel.isVPNToggling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Connect VPN")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isGPHovered ? Color.green : Color.green.opacity(0.7))
                    )
                    .contentShape(Rectangle())
                    .onHover { isGPHovered = $0 }
                    .onTapGesture { viewModel.connectVPN() }
            }
        }
        .padding(12)
    }

    // MARK: - Restarting

    private var restartingSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text(viewModel.restartStatus ?? "Restarting...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - VPN Toggling (Connect/Disconnect in progress)

    private var vpnTogglingSection: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            ShimmerText(viewModel.connectionState == .connected ? "Disconnecting..." : "Connecting...")
        }
        .padding(12)
    }

    @State private var isRestartHovered = false
    @State private var isDisconnectHovered = false

    private var disconnectSection: some View {
        HStack(spacing: 8) {
            // Restart button
            actionButton(
                label: viewModel.isRestarting ? (viewModel.restartStatus ?? "Restarting...") : "Restart",
                icon: "arrow.triangle.2.circlepath",
                color: .blue,
                isHovered: isRestartHovered,
                disabled: viewModel.isVPNToggling || viewModel.isBusy
            ) {
                viewModel.restartVPN()
            }
            .onHover { isRestartHovered = $0 }

            // Disconnect button
            actionButton(
                label: "Disconnect",
                icon: "xmark.circle",
                color: .red,
                isHovered: isDisconnectHovered,
                disabled: viewModel.isVPNToggling || viewModel.isBusy
            ) {
                viewModel.disconnectVPN()
            }
            .onHover { isDisconnectHovered = $0 }
        }
        .padding(12)
    }

    private func actionButton(label: String, icon: String, color: Color, isHovered: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        let effectiveColor: Color = disabled ? .gray : color
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(disabled ? .gray.opacity(0.5) : (isHovered ? .white : color))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && !disabled ? color.opacity(0.3) : effectiveColor.opacity(disabled ? 0.05 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(effectiveColor.opacity(disabled ? 0.1 : 0.3), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { action() } }
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

// MARK: - Shimmer Text

struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = 0

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.white.opacity(0.5))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: -geo.size.width * 0.2 + geo.size.width * 1.4 * phase)
                }
                .mask(Text(text).font(.caption))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
