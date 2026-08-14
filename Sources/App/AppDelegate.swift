import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?

    /// One menu for the life of the app, refilled before each opening.
    ///
    /// It used to be rebuilt and reassigned whenever anything changed, which meant
    /// a refresh landing while the menu was open replaced the menu somebody was
    /// reading — and closed it.
    private let menu = NSMenu()
    private var liveRowTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        menu.delegate = self
        MenuBuilder.populate(menu, appState: AppState.shared)
        item.menu = menu
        self.statusItem = item

        AppState.shared.loadSystems()
        RefreshService.shared.start()
        startObserving()

        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        RefreshService.shared.stop()
        observationTask?.cancel()
        liveRowTimer?.invalidate()
    }

    /// The menu contents are built when the menu opens, so the only thing left
    /// for observation to keep current is the thing on show while it is closed.
    private func startObserving() {
        observationTask = Task { @MainActor in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AppState.shared.activeAlerts
                    } onChange: {
                        continuation.resume()
                    }
                }
                refreshStatusButton()
            }
        }
    }

    private func refreshStatusButton() {
        guard let button = statusItem?.button else { return }

        let alertCount = AppState.shared.activeAlerts.count
        if alertCount > 0 {
            button.image = NSImage(systemSymbolName: "server.rack.fill", accessibilityDescription: "BeszelBar")
            button.title = " \(alertCount)"
        } else {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
            button.title = ""
        }
        button.image?.size = NSSize(width: 18, height: 18)
    }

    /// Nudge the rows that act on a click into looking at the app again.
    ///
    /// An open menu runs its own event loop, and the observation driving the rest
    /// of the app does not get a turn inside it. Without this the row that says
    /// "Refreshing…" would still say it long after the numbers had landed.
    @objc private func refreshLiveRows() {
        for item in menu.items {
            (item.view as? MenuActionRow)?.refresh()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuBuilder.populate(menu, appState: AppState.shared)
    }

    func menuWillOpen(_ menu: NSMenu) {
        liveRowTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.35,
            target: self,
            selector: #selector(refreshLiveRows),
            userInfo: nil,
            repeats: true
        )
        // .common, because .default does not include the mode a menu tracks in —
        // a timer scheduled the usual way would not fire until the menu closed.
        RunLoop.main.add(timer, forMode: .common)
        liveRowTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        liveRowTimer?.invalidate()
        liveRowTimer = nil
    }
}
