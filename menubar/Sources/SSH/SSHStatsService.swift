import Foundation

/// Reads machine stats by running the agent directly, with no hub in the path.
///
/// This is the whole point of the fork: when the hub — or the machine hosting it —
/// is down, the hub API returns nothing and the menu bar goes blank exactly when
/// you most want to look at it. Running `beszel-agent stats` over SSH answers from
/// the machine itself, so a dead hub costs you history and alerts but not sight.
final class SSHStatsService: @unchecked Sendable {

    struct Result {
        let systems: [SystemRecord]
        let details: [String: SystemDetailsRecord]
        let containers: [String: [ContainerRecord]]
        let failures: [String: String]
    }

    enum SSHError: LocalizedError {
        case commandFailed(target: String, message: String)
        case timedOut(target: String, seconds: Int)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let target, let message):
                return "\(target): \(message)"
            case .timedOut(let target, let seconds):
                return "\(target): \(seconds) saniyede yanıt yok"
            }
        }
    }

    /// How long a single target gets before it is written off.
    ///
    /// The agent spends about a second sampling before it prints anything — the
    /// window its cpu delta is measured over — so this has to leave room for that
    /// plus a cold SSH handshake.
    private let timeoutSeconds: Int = 15

    /// Collect every target in parallel.
    ///
    /// Wall time is the slowest target rather than the sum, which matters because
    /// each one deliberately spends a second sampling. A machine that is down
    /// contributes a recorded failure instead of taking the whole refresh with it.
    func fetchAll(targets: [SSHTarget]) async -> Result {
        let usable = targets.filter(\.isUsable)
        guard !usable.isEmpty else {
            return Result(systems: [], details: [:], containers: [:], failures: [:])
        }

        var systems: [SystemRecord] = []
        var details: [String: SystemDetailsRecord] = [:]
        var containers: [String: [ContainerRecord]] = [:]
        var failures: [String: String] = [:]

        await withTaskGroup(of: (SSHTarget, Swift.Result<AgentSnapshot, Error>).self) { group in
            for target in usable {
                group.addTask { [self] in
                    do {
                        return (target, .success(try await fetch(target: target)))
                    } catch {
                        return (target, .failure(error))
                    }
                }
            }

            for await (target, outcome) in group {
                switch outcome {
                case .success(let snapshot):
                    systems.append(snapshot.systemRecord(for: target))
                    if let detail = snapshot.detailsRecord(for: target) {
                        details[target.recordID] = detail
                    }
                    let containerRecords = snapshot.containerRecords(for: target)
                    if !containerRecords.isEmpty {
                        containers[target.recordID] = containerRecords
                    }
                case .failure(let error):
                    failures[target.recordID] = error.localizedDescription
                    // A target that cannot be reached is still a target worth
                    // showing — as down, not as absent. Dropping the row would
                    // read as "nothing wrong here".
                    systems.append(
                        SystemRecord(
                            id: target.recordID,
                            name: target.name,
                            status: "down",
                            host: target.host,
                            port: nil,
                            info: nil,
                            v: nil,
                            updated: ISO8601DateFormatter().string(from: Date())
                        )
                    )
                }
            }
        }

        // Preserve the configured order so rows do not reshuffle on every refresh.
        let position = Dictionary(
            uniqueKeysWithValues: usable.enumerated().map { ($1.recordID, $0) }
        )
        systems.sort { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }

        return Result(systems: systems, details: details, containers: containers, failures: failures)
    }

    private func fetch(target: SSHTarget) async throws -> AgentSnapshot {
        let output = try await run(target: target)
        return try JSONDecoder().decode(AgentSnapshot.self, from: output)
    }

    private func argv(for target: SSHTarget) -> [String] {
        switch target.transport {
        case .local:
            return ["/bin/sh", "-lc", target.command]
        case .ssh:
            return [
                "/usr/bin/ssh",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "IdentitiesOnly=yes",
                // ControlMaster keeps the connection warm between refreshes. Without
                // it every poll pays a fresh handshake, which on a 30 second refresh
                // is most of the cost of looking.
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(NSString(string: "~/.ssh/beszelbar-%r@%h:%p").expandingTildeInPath)",
                "-o", "ControlPersist=300",
                "-i", NSString(string: target.keyPath).expandingTildeInPath,
                "\(target.user)@\(target.host)",
                target.command,
            ]
        }
    }

    private func run(target: SSHTarget) async throws -> Data {
        let arguments = argv(for: target)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // stderr is drained on its own queue. The agent logs several lines
                // there on every run, and leaving it unread risks filling the pipe
                // buffer and wedging the child while we wait on stdout.
                var stderrData = Data()
                let stderrQueue = DispatchQueue(label: "beszelbar.ssh.stderr")
                let stderrDone = DispatchSemaphore(value: 0)
                stderrQueue.async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrDone.signal()
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

                let deadline = DispatchTime.now() + .seconds(self.timeoutSeconds)
                let finished = self.wait(for: process, until: deadline)

                if !finished {
                    process.terminate()
                    _ = stderrDone.wait(timeout: .now() + .seconds(2))
                    continuation.resume(
                        throwing: SSHError.timedOut(
                            target: target.name, seconds: self.timeoutSeconds
                        )
                    )
                    return
                }

                _ = stderrDone.wait(timeout: .now() + .seconds(2))

                guard process.terminationStatus == 0 else {
                    let message = String(data: stderrData, encoding: .utf8)?
                        .split(separator: "\n").last.map(String.init)
                        ?? "çıkış kodu \(process.terminationStatus)"
                    continuation.resume(
                        throwing: SSHError.commandFailed(target: target.name, message: message)
                    )
                    return
                }

                continuation.resume(returning: stdoutData)
            }
        }
    }

    private func wait(for process: Process, until deadline: DispatchTime) -> Bool {
        while process.isRunning {
            if DispatchTime.now() > deadline { return false }
            usleep(50_000)
        }
        return true
    }
}
