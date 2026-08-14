import SwiftUI

struct MenuHeaderView: View {
    var appState: AppState

    /// Line under the title.
    ///
    /// Free text so you can put your own name or team there, falling back to the
    /// selected hub's name — which is what upstream showed — when it is not set.
    /// Anything hardcoded here would follow every clone of this repository around.
    private var subtitle: String? {
        let custom = UserDefaults.standard
            .string(forKey: "com.nohitdev.BeszelBar.headerSubtitle")?
            .trimmingCharacters(in: .whitespaces)

        if let custom = custom, !custom.isEmpty { return custom }

        guard let selected = appState.selectedInstance else { return nil }
        return selected.name.isEmpty ? selected.url : selected.name
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("BeszelBar.VO")
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !appState.selectedInstanceSystems.isEmpty {
                    let online = appState.selectedInstanceSystems.filter { $0.isOnline }.count
                    let offline = appState.selectedInstanceSystems.count - online

                    HStack(spacing: 6) {
                        StatusBubble(count: online, color: .green, icon: "checkmark.circle.fill")
                        if offline > 0 {
                            StatusBubble(count: offline, color: .red, icon: "xmark.circle.fill")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
        }
        .frame(width: 300, height: 46)
    }
}

struct StatusBubble: View {
    let count: Int
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}
