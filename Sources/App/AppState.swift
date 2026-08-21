import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var instances: [Instance] = []
    var selectedInstance: Instance?
    var selectedInstanceSystems: [SystemRecord] = []
    var systemDetails: [String: SystemDetailsRecord] = [:]
    var containers: [String: [ContainerRecord]] = [:]
    var activeAlerts: [AlertRecord] = []
    var memoryBreakdowns: [String: MemoryBreakdown] = [:]
    var isLoading = false
    var errorMessage: String?
    var isConfigured = false

    /// Where the numbers on screen came from.
    ///
    /// Worth surfacing rather than hiding: SSH mode means no history and no alerts,
    /// so a reading that silently arrived by a different route would be misleading.
    var dataSource: DataSource = .hub
    var sshTargets: [SSHTarget] = []
    var sshFailures: [String: String] = [:]

    /// Alerts that should affect the menu bar. Beszel counts VMware balloon
    /// pages as used RAM. When a direct snapshot proves the guest's own memory
    /// is below the configured threshold, that Memory alert is informational
    /// noise rather than workload pressure.
    var actionableAlerts: [AlertRecord] {
        activeAlerts.filter { alert in
            guard alert.isMemoryAlert,
                  let systemID = alert.system,
                  let breakdown = memoryBreakdowns[systemID],
                  let threshold = alert.effectiveThreshold else {
                return true
            }
            return breakdown.usedPercentage > threshold
        }
    }

    /// Read the machines directly and leave the hub out of it entirely.
    ///
    /// Distinct from the fallback, which reacts to a hub that stopped answering.
    /// This is the user saying "do not ask the hub at all", so it holds even while
    /// the hub is perfectly healthy, and it survives relaunches.
    var sshDirectModeEnabled: Bool {
        didSet {
            guard sshDirectModeEnabled != oldValue else { return }
            sshStore.directModeEnabled = sshDirectModeEnabled
            applyDirectModeChange()
        }
    }

    private let storage = StorageManager()
    private let keychain = KeychainService.shared
    private let sshStore = SSHTargetStore()
    private let sshService = SSHStatsService()
    private var apiServices: [UUID: BeszelAPIService] = [:]
    private var loadTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?
    private var containerTask: Task<Void, Never>?

    private init() {
        sshDirectModeEnabled = sshStore.directModeEnabled
        loadInstances()
        sshTargets = sshStore.loadTargets()
        isConfigured = !instances.isEmpty || !sshTargets.isEmpty
        if selectedInstance != nil || !sshTargets.isEmpty {
            loadSystems()
            loadSystemDetails()
            loadAlerts()
            loadContainers()
        }
    }

    func loadSystems() {
        // The user asked for SSH, so the hub is not consulted at all — not even
        // to discover that it is fine. Nothing here can flip the app back to the
        // hub; only turning the mode off does that.
        if sshDirectModeEnabled && !sshTargets.isEmpty {
            // Recorded now rather than when the readings land. The three hub-only
            // loaders decide what to do by reading this, and for the second or two
            // a first SSH collection takes they would otherwise still consider the
            // hub fair game — which is exactly what the mode exists to prevent.
            dataSource = .sshDirect
            loadTask?.cancel()
            loadTask = Task { await loadFromSSH(source: .sshDirect) }
            return
        }

        guard let instance = selectedInstance else {
            // No hub configured at all. SSH is not a fallback here, it is the
            // only source, so use it directly rather than reporting nothing.
            if !sshTargets.isEmpty {
                loadTask?.cancel()
                loadTask = Task { await loadFromSSH(source: .ssh(reason: "Merkez yapılandırılmamış")) }
            }
            return
        }

        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            errorMessage = nil

            defer { isLoading = false }

            do {
                let service = getOrCreateService(for: instance)
                let systems = try await service.fetchSystems()
                guard !Task.isCancelled else { return }
                selectedInstanceSystems = systems.sorted { $0.name < $1.name }
                dataSource = .hub
                sshFailures = [:]

                // The hub has no separate balloon field. A direct agent snapshot
                // supplies only that missing piece; the hub remains the source of
                // systems, details, containers and alerts.
                if !sshTargets.isEmpty {
                    let direct = await sshService.fetchAll(targets: sshTargets)
                    guard !Task.isCancelled else { return }
                    memoryBreakdowns = mapMemoryBreakdowns(
                        from: direct,
                        onto: selectedInstanceSystems
                    )
                } else {
                    memoryBreakdowns = [:]
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }

                // The hub did not answer. This is the case the fork exists for:
                // rather than leaving the menu empty, go straight to the machines.
                if sshFallbackEnabled && !sshTargets.isEmpty {
                    await loadFromSSH(source: .ssh(reason: error.localizedDescription))
                } else {
                    errorMessage = error.localizedDescription
                    dataSource = .hub
                }
            }
        }
    }

    /// Populate everything from the machines themselves, bypassing the hub.
    ///
    /// The source travels in rather than being derived here, because the same
    /// collection means two different things: a fallback carries the hub's error,
    /// direct mode carries no fault at all.
    private func loadFromSSH(source: DataSource) async {
        isLoading = true
        defer { isLoading = false }

        let result = await sshService.fetchAll(targets: sshTargets)
        guard !Task.isCancelled else { return }

        selectedInstanceSystems = result.systems
        systemDetails = result.details
        containers = result.containers
        memoryBreakdowns = result.memoryBreakdowns
        sshFailures = result.failures
        dataSource = source

        // Alerts live in the hub's database, so there are none to show on this
        // path. Leaving stale ones on screen would imply they are still current.
        activeAlerts = []
        errorMessage = result.systems.isEmpty
            ? (source.reason ?? "Kullanılabilir SSH hedefi yok")
            : nil
    }

    func loadSystemDetails() {
        guard let instance = selectedInstance, dataSource.isHub else { return }

        detailsTask?.cancel()
        detailsTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let details = try await service.fetchSystemDetails()
                guard !Task.isCancelled else { return }

                var mapped: [String: SystemDetailsRecord] = [:]
                for detail in details {
                    mapped[detail.system] = detail
                }
                systemDetails = mapped
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    // While SSH is carrying the app these three would only queue up more calls to
    // a hub already known to be unreachable. loadSystems() still tries the hub on
    // every refresh, so recovery is noticed there and normal service resumes.
    func loadAlerts() {
        guard let instance = selectedInstance, dataSource.isHub else { return }

        alertTask?.cancel()
        alertTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let alerts = try await service.fetchAlerts(filter: "enabled = true")
                guard !Task.isCancelled else { return }
                activeAlerts = alerts.filter { $0.triggered == true }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func loadContainers() {
        guard let instance = selectedInstance, dataSource.isHub else { return }

        containerTask?.cancel()
        containerTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let allContainers = try await service.fetchContainers()
                guard !Task.isCancelled else { return }

                var grouped: [String: [ContainerRecord]] = [:]
                for container in allContainers {
                    grouped[container.system, default: []].append(container)
                }
                containers = grouped
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func selectInstance(_ instance: Instance?) {
        selectedInstance = instance
        selectedInstanceSystems = []
        systemDetails = [:]
        containers = [:]
        activeAlerts = []
        memoryBreakdowns = [:]
        loadSystems()
        loadSystemDetails()
        loadAlerts()
        loadContainers()
        storage.saveSelectedInstanceID(instance?.id)
    }

    func addInstance(_ instance: Instance) {
        keychain.saveCredential(instance.credential, for: instance.id.uuidString)

        var storedInstance = instance
        storedInstance.credential = ""
        instances.append(storedInstance)
        saveInstances()

        if selectedInstance == nil {
            selectInstance(instance)
        }
        isConfigured = true
    }

    func removeInstance(_ instance: Instance) {
        keychain.deleteCredential(for: instance.id.uuidString)
        apiServices.removeValue(forKey: instance.id)
        instances.removeAll { $0.id == instance.id }
        saveInstances()

        if selectedInstance?.id == instance.id {
            selectedInstance = instances.first
            selectedInstanceSystems = []
            systemDetails = [:]
            containers = [:]
            activeAlerts = []
            memoryBreakdowns = [:]
            if selectedInstance != nil {
                loadSystems()
                loadSystemDetails()
                loadAlerts()
                loadContainers()
            }
        }
        isConfigured = !instances.isEmpty
    }

    func updateInstance(_ instance: Instance) {
        if !instance.credential.isEmpty {
            keychain.updateCredential(instance.credential, for: instance.id.uuidString)
        }

        apiServices.removeValue(forKey: instance.id)

        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            var storedInstance = instance
            storedInstance.credential = ""
            instances[index] = storedInstance
            saveInstances()
        }

        if selectedInstance?.id == instance.id {
            selectInstance(instance)
        }
    }

    func instanceWithCredential(_ instance: Instance) -> Instance {
        var fullInstance = instance
        fullInstance.credential = keychain.loadCredential(for: instance.id.uuidString) ?? ""
        return fullInstance
    }

    private func loadInstances() {
        instances = storage.loadInstances()

        if let savedID = storage.loadSelectedInstanceID(),
           let instance = instances.first(where: { $0.id == savedID }) {
            selectedInstance = instance
        } else {
            selectedInstance = instances.first
        }
    }

    private func saveInstances() {
        storage.saveInstances(instances)
    }

    // MARK: - SSH targets

    var sshFallbackEnabled: Bool {
        get { sshStore.fallbackEnabled }
        set {
            sshStore.fallbackEnabled = newValue
            // Turning it off while it is carrying the app would leave stale numbers
            // on screen, so go back to the hub and let it report its own state.
            // Only the fallback is undone here: direct mode was asked for, and
            // switching off a safety net is no reason to overrule that.
            if !newValue, dataSource.reason != nil {
                dataSource = .hub
                loadSystems()
            }
        }
    }

    /// Act on the mode having been switched.
    ///
    /// Turning it off has more to do than turning it on: the three hub-only
    /// loaders sat out the whole time SSH was carrying the app, so the details,
    /// alerts and containers on screen are all from the other path and have to be
    /// fetched again rather than waiting for whichever timer happens to fire.
    private func applyDirectModeChange() {
        if sshDirectModeEnabled {
            loadSystems()
        } else {
            dataSource = .hub
            sshFailures = [:]
            loadSystems()
            loadSystemDetails()
            loadAlerts()
            loadContainers()
        }
    }

    func addSSHTarget(_ target: SSHTarget) {
        sshTargets.append(target)
        sshStore.saveTargets(sshTargets)
        isConfigured = true
        if sshDirectModeEnabled { loadSystems() }
    }

    func updateSSHTarget(_ target: SSHTarget) {
        guard let index = sshTargets.firstIndex(where: { $0.id == target.id }) else { return }
        sshTargets[index] = target
        sshStore.saveTargets(sshTargets)
        if !dataSource.isHub { loadSystems() }
    }

    func removeSSHTarget(_ target: SSHTarget) {
        sshTargets.removeAll { $0.id == target.id }
        sshStore.saveTargets(sshTargets)
        sshFailures.removeValue(forKey: target.recordID)
        isConfigured = !instances.isEmpty || !sshTargets.isEmpty

        // A direct mode with nothing left to read is a mode that can only report
        // emptiness, so removing the last target ends it. Its didSet returns the
        // app to the hub, which makes the further reload below unnecessary.
        if sshDirectModeEnabled && sshTargets.isEmpty {
            sshDirectModeEnabled = false
            return
        }

        if !dataSource.isHub { loadSystems() }
    }

    /// Run one target now and report what came back, for the settings screen's
    /// test button. Configuring SSH is fiddly enough that guessing whether it
    /// worked is not good enough.
    func testSSHTarget(_ target: SSHTarget) async -> String {
        let result = await sshService.fetchAll(targets: [target])
        if let failure = result.failures[target.recordID] {
            return "Başarısız — \(failure)"
        }
        guard let system = result.systems.first, let info = system.info else {
            return "Başarısız — okunabilir veri alınamadı"
        }
        let cpu = info.cpu.map { String(format: "%.1f%%", $0) } ?? "?"
        let mem = info.mp.map { String(format: "%.1f%%", $0) } ?? "?"
        let balloonStatus = result.balloonCapableTargetIDs.contains(target.recordID)
            ? "Balloon hazır"
            : "Balloon alanı yok; hazır agent’ı kurun"
        return "Başarılı — CPU \(cpu), RAM \(mem) · \(balloonStatus)"
    }

    /// Re-key direct readings from SSH target ids to PocketBase system ids.
    /// Host address is strongest; normalized display name and hostname cover
    /// installations where the hub stores a private address instead.
    private func mapMemoryBreakdowns(
        from direct: SSHStatsService.Result,
        onto hubSystems: [SystemRecord]
    ) -> [String: MemoryBreakdown] {
        var mapped: [String: MemoryBreakdown] = [:]

        for (targetID, breakdown) in direct.memoryBreakdowns {
            guard let directSystem = direct.systems.first(where: { $0.id == targetID }) else {
                continue
            }
            let directDetails = direct.details[targetID]
            let directNames = [directSystem.name, directSystem.info?.h, directDetails?.hostname]
                .compactMap { $0 }
                .map(normalizedSystemIdentity)
                .filter { !$0.isEmpty }

            let match = hubSystems.first { hubSystem in
                if let directHost = directSystem.host,
                   let hubHost = hubSystem.host,
                   !directHost.isEmpty,
                   directHost.caseInsensitiveCompare(hubHost) == .orderedSame {
                    return true
                }

                let hubNames = [hubSystem.name, hubSystem.info?.h]
                    .compactMap { $0 }
                    .map(normalizedSystemIdentity)
                return !Set(directNames).isDisjoint(with: hubNames)
            }

            if let match {
                mapped[match.id] = breakdown
            }
        }
        return mapped
    }

    private func normalizedSystemIdentity(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func getOrCreateService(for instance: Instance) -> BeszelAPIService {
        if let existing = apiServices[instance.id] {
            return existing
        }

        let fullInstance = instanceWithCredential(instance)
        let service = BeszelAPIService(instance: fullInstance)
        apiServices[instance.id] = service
        return service
    }
}

struct Instance: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var email: String
    var credential: String

    init(id: UUID = UUID(), name: String, url: String, email: String, credential: String) {
        self.id = id
        self.name = name
        self.url = url
        self.email = email
        self.credential = credential
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        email = try container.decode(String.self, forKey: .email)
        credential = ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(email, forKey: .email)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Instance, rhs: Instance) -> Bool {
        lhs.id == rhs.id
    }
}

final class StorageManager {
    private let defaults = UserDefaults.standard
    private let instancesKey = "com.nohitdev.BeszelBar.instances"
    private let selectedInstanceKey = "com.nohitdev.BeszelBar.selectedInstance"

    func saveInstances(_ instances: [Instance]) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        defaults.set(data, forKey: instancesKey)
    }

    func loadInstances() -> [Instance] {
        guard let data = defaults.data(forKey: instancesKey),
              let instances = try? JSONDecoder().decode([Instance].self, from: data) else {
            return []
        }
        return instances
    }

    func saveSelectedInstanceID(_ id: UUID?) {
        if let id = id {
            defaults.set(id.uuidString, forKey: selectedInstanceKey)
        } else {
            defaults.removeObject(forKey: selectedInstanceKey)
        }
    }

    func loadSelectedInstanceID() -> UUID? {
        guard let string = defaults.string(forKey: selectedInstanceKey) else { return nil }
        return UUID(uuidString: string)
    }
}
