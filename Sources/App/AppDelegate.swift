import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        item.menu = MenuBuilder.build(appState: AppState.shared)
        self.statusItem = item

        AppState.shared.loadSystems()
        RefreshService.shared.start()
        startObserving()

        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        RefreshService.shared.stop()
        observationTask?.cancel()
    }

    private func startObserving() {
        observationTask = Task { @MainActor in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AppState.shared.instances
                        _ = AppState.shared.selectedInstance
                        _ = AppState.shared.selectedInstanceSystems
                        _ = AppState.shared.isLoading
                        _ = AppState.shared.activeAlerts
                        _ = AppState.shared.systemDetails
                        _ = AppState.shared.containers
                        // Without these the menu would keep rendering the old
                        // source after a switch that changed nothing else.
                        _ = AppState.shared.dataSource
                        _ = AppState.shared.sshTargets
                        _ = AppState.shared.sshFailures
                    } onChange: {
                        continuation.resume()
                    }
                }
                refreshMenu()
            }
        }
    }

    private func refreshMenu() {
        let appState = AppState.shared

        if let button = statusItem?.button {
            let alertCount = appState.activeAlerts.count
            if alertCount > 0 {
                button.image = NSImage(systemSymbolName: "server.rack.fill", accessibilityDescription: "BeszelBar")
                button.title = " \(alertCount)"
            } else {
                button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
                button.title = ""
            }
            button.image?.size = NSSize(width: 18, height: 18)
        }

        statusItem?.menu = MenuBuilder.build(appState: appState)
    }
}
