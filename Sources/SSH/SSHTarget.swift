import Foundation

/// A machine reachable without the hub.
///
/// The hub knows its systems because agents dial in and register. Nothing does
/// that here, so each target is configured by hand: where to reach it, which key
/// opens it, and what to run once inside.
struct SSHTarget: Identifiable, Codable, Equatable, Hashable {
    enum Transport: String, Codable, CaseIterable {
        /// Run the command on this Mac. No SSH, no key, no network.
        case local
        /// Run the command on the far end over SSH.
        case ssh

        var displayName: String {
            switch self {
            case .local: return "This Mac"
            case .ssh: return "SSH"
            }
        }
    }

    let id: UUID
    var name: String
    var transport: Transport
    var user: String
    var host: String
    var keyPath: String
    var command: String

    init(
        id: UUID = UUID(),
        name: String,
        transport: Transport = .ssh,
        user: String = "",
        host: String = "",
        keyPath: String = "~/.ssh/nabiz_stats",
        command: String = "beszel-agent stats"
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.user = user
        self.host = host
        self.keyPath = keyPath
        self.command = command
    }

    /// Stable identifier standing in for the hub's PocketBase record id.
    ///
    /// It must not change between refreshes — the menu keys rows off it, and a
    /// shifting id makes rows disappear and reappear instead of updating.
    var recordID: String { "ssh:\(id.uuidString)" }

    var isUsable: Bool {
        switch transport {
        case .local:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .ssh:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
                && !user.trimmingCharacters(in: .whitespaces).isEmpty
                && !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var displaySubtitle: String {
        switch transport {
        case .local: return "this Mac"
        case .ssh: return "\(user)@\(host)"
        }
    }
}

/// Which route the numbers currently on screen took.
enum DataSource: Equatable {
    case hub
    /// Carrying the app because the hub did not answer. The reason travels with
    /// the case so the menu can say what went wrong instead of just "degraded".
    case ssh(reason: String)
    /// Carrying the app because the user asked for it. Nothing went wrong, so
    /// this is reported as a mode rather than as a fault — but it is still worth
    /// saying, because history and alerts are missing here too.
    case sshDirect

    var isHub: Bool {
        if case .hub = self { return true }
        return false
    }

    var reason: String? {
        if case .ssh(let reason) = self { return reason }
        return nil
    }
}

/// Persistence for SSH targets.
///
/// Deliberately UserDefaults and not the keychain: a target holds a path to a key
/// file, never a secret. The key itself stays in ~/.ssh where ssh expects it, with
/// the permissions ssh already enforces.
final class SSHTargetStore {
    private let defaults = UserDefaults.standard
    private let targetsKey = "com.nohitdev.BeszelBar.sshTargets"
    private let fallbackEnabledKey = "com.nohitdev.BeszelBar.sshFallbackEnabled"
    private let directModeKey = "com.nohitdev.BeszelBar.sshDirectMode"

    func loadTargets() -> [SSHTarget] {
        guard let data = defaults.data(forKey: targetsKey),
              let targets = try? JSONDecoder().decode([SSHTarget].self, from: data) else {
            return []
        }
        return targets
    }

    func saveTargets(_ targets: [SSHTarget]) {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        defaults.set(data, forKey: targetsKey)
    }

    /// Defaults to on: a fallback nobody enabled is a fallback that will not be
    /// there on the night it is needed.
    var fallbackEnabled: Bool {
        get {
            if defaults.object(forKey: fallbackEnabledKey) == nil { return true }
            return defaults.bool(forKey: fallbackEnabledKey)
        }
        set { defaults.set(newValue, forKey: fallbackEnabledKey) }
    }

    /// Defaults to off, and stays where the user left it across launches.
    ///
    /// The opposite of `fallbackEnabled`: this one is a deliberate choice to stop
    /// using the hub, so it must never turn itself on. Silently bypassing a
    /// working hub would cost history and alerts with nobody having asked.
    var directModeEnabled: Bool {
        get { defaults.bool(forKey: directModeKey) }
        set { defaults.set(newValue, forKey: directModeKey) }
    }
}
