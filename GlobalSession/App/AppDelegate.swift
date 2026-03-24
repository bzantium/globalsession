import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var viewModel: MenuBarViewModel!
    private var globalMonitor: Any?
    private var localMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = MenuBarViewModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let img: NSImage
            if let resourcePath = Bundle.main.path(forResource: "menubar_icon", ofType: "png"),
               let customImg = NSImage(contentsOfFile: resourcePath) {
                customImg.size = NSSize(width: 16, height: 16)
                customImg.isTemplate = true
                img = customImg
            } else {
                img = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "GlobalSession")!
                img.isTemplate = true
            }
            button.image = img
            button.action = #selector(togglePanel)
            button.target = self
        }

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
}
