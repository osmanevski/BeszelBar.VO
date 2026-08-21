import SwiftUI

@main
struct BeszelBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(appState: AppState.shared)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Ayarlar…") {
                    WindowManager.shared.showSettings()
                }
                .keyboardShortcut(",")
            }
            CommandGroup(after: .appTermination) {
                Button("BeszelBar’dan Çık") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
