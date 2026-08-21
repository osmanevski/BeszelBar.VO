import Foundation

/// One `beszel-agent stats` document.
///
/// This is the payload our patched agent prints when invoked over SSH. It is the
/// same structure the agent would otherwise hand to the hub, so the field names
/// below are the agent's own short keys rather than anything we invented — which
/// is why `info` decodes straight into `SystemInfo` with no translation at all.
struct AgentSnapshot: Decodable {
    let stats: AgentStats?
    let info: SystemInfo?
    let containers: [AgentContainer]?
    let details: AgentDetails?
    let balloonBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case stats
        case info
        case containers = "container"
        // `Details` has no json tag upstream, so it marshals under the Go field name.
        case details = "Details"
        case balloonBytes = "balloon_bytes"
    }

    var memoryBreakdown: MemoryBreakdown? {
        let totalBytes = details?.memoryTotal.map(Double.init)
            ?? stats?.mem.map { $0 * 1024 * 1024 * 1024 }
        return MemoryBreakdown(
            reportedPercentage: stats?.memPct ?? info?.mp,
            balloonBytes: balloonBytes,
            totalBytes: totalBytes
        )
    }
}

/// The subset of the agent's stats block the menu bar actually displays.
///
/// The agent emits far more than this (per-core usage, temperatures, network
/// interfaces, SMART data). Decoding only what is shown keeps this type from
/// having to track every upstream field.
struct AgentStats: Decodable {
    let cpu: Double?
    let mem: Double?
    let memUsed: Double?
    let memPct: Double?
    let swap: Double?
    let swapUsed: Double?
    let diskTotal: Double?
    let diskUsed: Double?
    let diskPct: Double?
    let loadAvg: [Double]?

    enum CodingKeys: String, CodingKey {
        case cpu
        case mem = "m"
        case memUsed = "mu"
        case memPct = "mp"
        case swap = "s"
        case swapUsed = "su"
        case diskTotal = "d"
        case diskUsed = "du"
        case diskPct = "dp"
        case loadAvg = "la"
    }
}

/// Static host facts. Upstream tags these for CBOR only, so over the JSON path
/// they arrive under their Go field names.
struct AgentDetails: Decodable {
    let hostname: String?
    let kernel: String?
    let cores: Int?
    let threads: Int?
    let cpuModel: String?
    let os: Int?
    let osName: String?
    let arch: String?
    let podman: Bool?
    let memoryTotal: Int64?

    enum CodingKeys: String, CodingKey {
        case hostname = "Hostname"
        case kernel = "Kernel"
        case cores = "Cores"
        case threads = "Threads"
        case cpuModel = "CpuModel"
        case os = "Os"
        case osName = "OsName"
        case arch = "Arch"
        case podman = "Podman"
        case memoryTotal = "MemoryTotal"
    }
}

/// A container as it appears on the JSON path.
///
/// Upstream marks health, status, image and id as `json:"-"` — they travel to the
/// hub over CBOR only. So a container seen through SSH carries its name and
/// resource use but not its health or image. The mapping below fills those in as
/// unknown rather than pretending otherwise.
struct AgentContainer: Decodable {
    let name: String?
    let cpu: Double?
    let memory: Double?
    let bandwidth: [UInt64]?

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case cpu = "c"
        case memory = "m"
        case bandwidth = "b"
    }
}

// MARK: - Mapping onto the hub's shapes

extension AgentSnapshot {
    /// Build the record the menu already knows how to render.
    ///
    /// The hub assigns each system a PocketBase id; over SSH there is no hub to
    /// do that, so the target's own stable id stands in. Views key off this, and
    /// keeping it stable across refreshes is what stops rows from flickering.
    func systemRecord(for target: SSHTarget) -> SystemRecord {
        var resolvedInfo = info

        // A snapshot taken through SSH has no notion of "the hub last heard from
        // this host N seconds ago", so uptime and the load average are taken from
        // the stats block when the info block omits them.
        if resolvedInfo == nil, let stats = stats {
            resolvedInfo = SystemInfo(
                h: details?.hostname, k: details?.kernel, c: details?.cores,
                t: details?.threads, m: details?.cpuModel, o: nil, os: details?.os,
                u: nil, v: nil, cpu: stats.cpu, mp: stats.memPct, dp: stats.diskPct,
                b: nil, bb: nil, l1: nil, l5: nil, l15: nil, la: stats.loadAvg,
                bat: nil, g: nil, dt: nil, p: details?.podman, ct: nil,
                efs: nil, sv: nil
            )
        }

        return SystemRecord(
            id: target.recordID,
            name: target.name,
            status: "up",
            host: target.host,
            port: nil,
            info: resolvedInfo,
            v: info?.v,
            updated: ISO8601DateFormatter().string(from: Date())
        )
    }

    func detailsRecord(for target: SSHTarget) -> SystemDetailsRecord? {
        guard let details = details else { return nil }
        return SystemDetailsRecord(
            id: target.recordID,
            system: target.recordID,
            hostname: details.hostname,
            kernel: details.kernel,
            cores: details.cores,
            threads: details.threads,
            cpu: details.cpuModel,
            memory: details.memoryTotal,
            os: details.os,
            osName: details.osName,
            arch: details.arch,
            podman: details.podman,
            updated: ISO8601DateFormatter().string(from: Date())
        )
    }

    func containerRecords(for target: SSHTarget) -> [ContainerRecord] {
        guard let containers = containers else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        return containers.compactMap { container in
            guard let name = container.name else { return nil }
            let sent = container.bandwidth?.first ?? 0
            let received = container.bandwidth?.dropFirst().first ?? 0

            return ContainerRecord(
                id: "\(target.recordID):\(name)",
                name: name,
                cpu: container.cpu ?? 0,
                memory: container.memory ?? 0,
                net: Double(sent &+ received),
                // Health, status and image do not cross the JSON path. Reporting
                // "no health check" is honest; inventing "healthy" would not be.
                health: .none,
                status: "",
                image: "",
                system: target.recordID,
                updated: now
            )
        }
    }
}
