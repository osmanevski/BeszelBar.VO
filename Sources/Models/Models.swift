import Foundation

struct SystemRecord: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let status: String?
    let host: String?
    let port: String?
    let info: SystemInfo?
    let v: String?
    let updated: String?
}

struct SystemInfo: Codable, Hashable {
    let h: String?
    let k: String?
    let c: Int?
    let t: Int?
    let m: String?
    let o: String?
    let os: Int?
    let u: Double?
    let v: String?
    let cpu: Double?
    let mp: Double?
    let dp: Double?
    let b: Double?
    let bb: Double?
    let l1: Double?
    let l5: Double?
    let l15: Double?
    let la: [Double]?
    let bat: [Double]?
    let g: Double?
    let dt: Double?
    let p: Bool?
    let ct: Int?
    let efs: [String: Double]?
    let sv: [Int]?
}

/// Splits the guest's reported memory pressure into memory used by workloads
/// and memory reclaimed by a hypervisor balloon driver.
///
/// Beszel's ordinary percentage includes both. Keeping the split outside
/// `SystemInfo` is intentional: this extra measurement comes from our direct
/// agent snapshot and is not part of the hub's systems API.
struct MemoryBreakdown: Equatable, Hashable {
    let reportedPercentage: Double
    let usedPercentage: Double
    let balloonPercentage: Double

    init?(reportedPercentage: Double?, balloonBytes: UInt64?, totalBytes: Double?) {
        guard let reportedPercentage,
              let balloonBytes,
              balloonBytes > 0,
              let totalBytes,
              totalBytes > 0 else {
            return nil
        }

        let balloonPercentage = min(Double(balloonBytes) / totalBytes * 100, 100)
        self.reportedPercentage = min(max(reportedPercentage, 0), 100)
        self.balloonPercentage = balloonPercentage
        self.usedPercentage = min(max(reportedPercentage - balloonPercentage, 0), 100)
    }
}

extension SystemRecord {
    var displayStatus: String {
        guard let status = status?.lowercased() else { return "Bilinmiyor" }
        switch status {
        case "up", "online": return "Çevrimiçi"
        case "down", "offline": return "Çevrimdışı"
        case "pending": return "Bekliyor"
        default: return status.capitalized
        }
    }

    var isOnline: Bool {
        guard let status = status?.lowercased() else { return false }
        return status == "up" || status == "online"
    }

    var cpuPercentage: Double? {
        info?.cpu
    }

    var memoryPercentage: Double? {
        info?.mp
    }

    var diskPercentage: Double? {
        info?.dp
    }

    var temperature: Double? {
        info?.dt
    }
}

struct SystemStatsRecord: Identifiable, Codable {
    let id: String
    let created: String
    let stats: SystemStatsDetail?
    let type: String?
}

struct SystemStatsDetail: Codable {
    let cpu: Double?
    let mp: Double?
    let dp: Double?
    let ns: Double?
    let nr: Double?

    enum CodingKeys: String, CodingKey {
        case cpu, mp, dp, ns, nr
    }
}

struct SystemDetailsRecord: Identifiable, Codable, Hashable {
    let id: String
    let system: String
    let hostname: String?
    let kernel: String?
    let cores: Int?
    let threads: Int?
    let cpu: String?
    let memory: Int64?
    let os: Int?
    let osName: String?
    let arch: String?
    let podman: Bool?
    let updated: String?

    enum CodingKeys: String, CodingKey {
        case id, system, hostname, kernel, cores, threads, cpu, memory, os
        case osName = "os_name"
        case arch, podman, updated
    }
}

enum ContainerHealth: Int, Codable, Hashable {
    case none = 0
    case starting = 1
    case healthy = 2
    case unhealthy = 3

    var displayText: String {
        switch self {
        case .none: return "Sağlık Denetimi Yok"
        case .starting: return "Başlatılıyor"
        case .healthy: return "Sağlıklı"
        case .unhealthy: return "Sağlıksız"
        }
    }

    var color: String {
        switch self {
        case .none: return "secondary"
        case .starting: return "orange"
        case .healthy: return "green"
        case .unhealthy: return "red"
        }
    }
}

struct ContainerRecord: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let cpu: Double
    let memory: Double
    let net: Double
    let health: ContainerHealth
    let status: String
    let image: String
    let system: String
    let updated: Int64

    var updatedDate: Date {
        Date(timeIntervalSince1970: Double(updated) / 1000.0)
    }

    var displayStatus: String {
        switch status.lowercased() {
        case "running", "up": return "Çalışıyor"
        case "stopped", "exited", "down": return "Durdu"
        case "starting": return "Başlatılıyor"
        case "restarting": return "Yeniden başlatılıyor"
        case "paused": return "Duraklatıldı"
        default: return status
        }
    }
}

struct ContainerStatsRecord: Identifiable, Codable {
    let id: String
    let system: String
    let name: String?
    let cpu: Double?
    let mem: Double?
    let created: String?

    var containerID: String { id }
    var containerName: String? { name }
    var memory: Double? { mem }
}

struct AlertRecord: Identifiable, Codable {
    let id: String
    let name: String
    let system: String?
    let metric: String?
    let threshold: Double?
    /// Beszel 0.18+ calls the threshold `value`; older releases used
    /// `threshold`. Decode both so alert decisions remain version tolerant.
    let value: Double?
    let enabled: Bool?
    let triggered: Bool?
    let created: String?
    let updated: String?

    var displayMetric: String {
        switch metric?.lowercased() {
        case "memory", "mem": return "RAM"
        case "disk": return "Disk"
        case "temperature", "temp": return "Sıcaklık"
        case "network": return "Ağ"
        case "bandwidth": return "Bant genişliği"
        case "cpu": return "CPU"
        case .none: return "bilinmiyor"
        default: return metric ?? "bilinmiyor"
        }
    }

    var displayName: String {
        switch name.lowercased() {
        case "memory": return "RAM"
        case "disk": return "Disk"
        case "temperature": return "Sıcaklık"
        case "network": return "Ağ"
        case "bandwidth": return "Bant genişliği"
        case "status": return "Durum"
        case "cpu": return "CPU"
        default: return name
        }
    }

    var displayThreshold: String {
        if let t = effectiveThreshold {
            return String(format: "%.0f", t)
        }
        return "-"
    }

    var effectiveThreshold: Double? {
        threshold ?? value
    }

    var isMemoryAlert: Bool {
        name.caseInsensitiveCompare("Memory") == .orderedSame
            || metric?.caseInsensitiveCompare("Memory") == .orderedSame
    }
}

struct AlertHistoryRecord: Identifiable, Codable {
    let id: String
    let alert: String
    let system: String?
    let name: String?
    let message: String?
    let value: Double?
    let threshold: Double?
    let created: String?
}

struct PocketBaseListResponse<T: Codable>: Codable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int
    let items: [T]
}

struct AuthResponse: Codable {
    let token: String
}
