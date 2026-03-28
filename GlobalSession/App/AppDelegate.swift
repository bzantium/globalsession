import SwiftUI
import Combine
import ServiceManagement
import ApplicationServices

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var viewModel: MenuBarViewModel!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var templateIcon: NSImage?
    private var blinkTimer: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? SMAppService.mainApp.register()
        viewModel = MenuBarViewModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let resourcePath = Bundle.main.path(forResource: "menubar_icon", ofType: "png"),
               let customImg = NSImage(contentsOfFile: resourcePath) {
                customImg.size = NSSize(width: 16, height: 16)
                templateIcon = customImg
            } else {
                let img = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "GlobalSession")!
                templateIcon = img
            }
            templateIcon?.isTemplate = true
            button.image = templateIcon
            button.action = #selector(togglePanel)
            button.target = self
        }

        viewModel.$policyMode
            .combineLatest(viewModel.$connectionState)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, state in
                self?.updateIcon(mode: mode, connected: state == .connected)
            }
            .store(in: &cancellables)

        viewModel.$isSwitchingMode
            .receive(on: RunLoop.main)
            .sink { [weak self] switching in
                self?.updateBlink(busy: switching)
            }
            .store(in: &cancellables)

        let popoverView = MenuBarPopover(viewModel: viewModel)
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingController(rootView: popoverView)

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = hostingView

        // Make the window content view and all layers fully transparent
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = .clear
        panel.contentView?.layer?.isOpaque = false
        hostingView.view.wantsLayer = true
        hostingView.view.layer?.backgroundColor = .clear
        hostingView.view.layer?.isOpaque = false

        // Walk all subviews to ensure none have opaque backgrounds
        func clearBackgrounds(_ view: NSView) {
            view.wantsLayer = true
            view.layer?.backgroundColor = .clear
            view.layer?.isOpaque = false
            for subview in view.subviews {
                clearBackgrounds(subview)
            }
        }
        clearBackgrounds(panel.contentView!)

        // Prompt after UI is ready
        DispatchQueue.main.async { [weak self] in
            self?.promptForAccessibilityIfNeeded()
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Size panel to fit SwiftUI content
        if let contentSize = panel.contentViewController?.view.fittingSize {
            panel.setContentSize(contentSize)
        }

        let buttonFrame = buttonWindow.frame
        let panelSize = panel.frame.size
        let x = buttonFrame.midX - panelSize.width / 2
        let y = buttonFrame.minY - panelSize.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, event.window != self.panel {
                self.hidePanel()
            }
            return event
        }
    }

    private func updateBlink(busy: Bool) {
        guard let button = statusItem.button else { return }
        blinkTimer?.invalidate()
        blinkTimer = nil

        if busy {
            button.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.3
            fade.duration = 0.8
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(fade, forKey: "blink")
        } else {
            button.layer?.removeAnimation(forKey: "blink")
            button.layer?.opacity = 1.0
        }
    }

    private func updateIcon(mode: PolicyMode, connected: Bool) {
        guard let button = statusItem.button, let template = templateIcon else { return }
        if connected, mode != .unknown {
            let tint: NSColor = mode == .prod ? .systemOrange : .systemBlue
            let size = template.size

            let composite = NSImage(size: size, flipped: false) { rect in
                // Outline: full-size icon in white
                template.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)

                // Colored fill: slightly inset, drawn on top
                let fillImg = NSImage(size: size, flipped: false) { r in
                    template.draw(in: r.insetBy(dx: 1.5, dy: 1.5))
                    tint.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                fillImg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            composite.isTemplate = false
            button.image = composite
        } else {
            template.isTemplate = true
            button.image = template
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Accessibility Permission

    private func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "GlobalSession needs Accessibility permission to control VPN connect/disconnect.\n\nAfter opening Settings, click \"+\" and add GlobalSession from Applications."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
