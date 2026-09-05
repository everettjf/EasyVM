import Foundation

private enum SoakToolError: LocalizedError {
    case invalidArguments
    case freshHeartbeatTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Expected: <workspace> <40-character source revision> <duration-seconds> <output>."
        case .freshHeartbeatTimedOut:
            return "The App did not publish a fresh soak heartbeat before the baseline timeout."
        }
    }
}

private struct SoakHeartbeat: Codable {
    let schemaVersion: Int
    let observedAt: Date
    let sourceRevision: String
    let guestAgentVersion: String
    let agentInstanceID: String?
    let bootID: String
    let uptimeSeconds: UInt64
    let desktopSessionActive: Bool
    let provisioningPending: Bool
}

private struct SoakObservation: Codable {
    let schemaVersion: Int
    let startedAt: Date
    let endedAt: Date
    let sourceRevision: String
    let guestAgentVersion: String
    let agentInstanceID: String
    let bootID: String
    let firstGuestUptimeSeconds: UInt64
    let lastGuestUptimeSeconds: UInt64
    let sampleCount: Int
    let maximumSampleGapSeconds: Int
    let continuousOperationSeconds: Int
    let desktopContinuouslyActive: Bool
    let provisioningContinuouslyComplete: Bool
}

@main
enum OmarchySoakAcceptanceTool {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4, let duration = Int(arguments[2]), duration > 0 else {
            throw SoakToolError.invalidArguments
        }
        let root = URL(filePath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = [
            FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath(),
            URL(filePath: "/tmp").resolvingSymlinksInPath(),
            URL(filePath: "/private/tmp").resolvingSymlinksInPath(),
        ]
        guard allowed.contains(where: { root.path.hasPrefix($0.path + "/") }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let revision = arguments[1]
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw SoakToolError.invalidArguments
        }
        let output = URL(filePath: arguments[3]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let heartbeatURL = root.appending(path: "Diagnostics/soak-heartbeat.json")
        let interval = max(1, Int(ProcessInfo.processInfo.environment[
            "EZVM_OMARCHY_SOAK_INTERVAL_SECONDS"
        ] ?? "30") ?? 30)
        let maximumAge = max(120, interval * 4)
        let baselineTimeout = max(1, Int(ProcessInfo.processInfo.environment[
            "EZVM_OMARCHY_SOAK_BASELINE_TIMEOUT_SECONDS"
        ] ?? "\(maximumAge)") ?? maximumAge)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A stopped VM leaves its last atomic heartbeat on disk. Establish a
        // baseline only after the App publishes a newer heartbeat so a restart
        // immediately before monitoring cannot bind the run to the old boot.
        let initialHeartbeat = try? decoder.decode(
            SoakHeartbeat.self,
            from: Data(contentsOf: heartbeatURL)
        )
        let baselineDeadline = Date().addingTimeInterval(TimeInterval(baselineTimeout))
        var first: SoakHeartbeat?
        repeat {
            if let data = try? Data(contentsOf: heartbeatURL),
               let candidate = try? decoder.decode(SoakHeartbeat.self, from: data) {
                if initialHeartbeat == nil || candidate.observedAt > initialHeartbeat!.observedAt {
                    first = candidate
                    break
                }
            }
            Thread.sleep(forTimeInterval: TimeInterval(interval))
        } while Date() < baselineDeadline
        guard let first else { throw SoakToolError.freshHeartbeatTimedOut }

        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(duration))
        var previousSample: SoakHeartbeat? = first
        var sampleCount = 1
        var maximumGap = 0

        repeat {
            let heartbeat = try decoder.decode(SoakHeartbeat.self, from: Data(contentsOf: heartbeatURL))
            let age = Date().timeIntervalSince(heartbeat.observedAt)
            guard heartbeat.schemaVersion == 1, heartbeat.sourceRevision == revision,
                  heartbeat.desktopSessionActive, !heartbeat.provisioningPending,
                  !heartbeat.bootID.isEmpty, heartbeat.agentInstanceID?.isEmpty == false,
                  age >= -5, age <= TimeInterval(maximumAge) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard heartbeat.bootID == first.bootID,
                  heartbeat.agentInstanceID == first.agentInstanceID,
                  heartbeat.guestAgentVersion == first.guestAgentVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let previous = previousSample, heartbeat.observedAt > previous.observedAt {
                guard heartbeat.uptimeSeconds >= previous.uptimeSeconds else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                maximumGap = max(
                    maximumGap,
                    Int(heartbeat.observedAt.timeIntervalSince(previous.observedAt).rounded(.up))
                )
                sampleCount += 1
                previousSample = heartbeat
            }
            if Date() < deadline { Thread.sleep(forTimeInterval: TimeInterval(interval)) }
        } while Date() < deadline

        guard let previous = previousSample, sampleCount >= 2,
              maximumGap <= maximumAge else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ended = Date()
        let elapsed = Int(ended.timeIntervalSince(started).rounded(.down))
        guard elapsed >= duration else { throw CocoaError(.fileReadCorruptFile) }
        let observation = SoakObservation(
            schemaVersion: 1,
            startedAt: started,
            endedAt: ended,
            sourceRevision: revision,
            guestAgentVersion: first.guestAgentVersion,
            agentInstanceID: first.agentInstanceID!,
            bootID: first.bootID,
            firstGuestUptimeSeconds: first.uptimeSeconds,
            lastGuestUptimeSeconds: previous.uptimeSeconds,
            sampleCount: sampleCount,
            maximumSampleGapSeconds: maximumGap,
            continuousOperationSeconds: elapsed,
            desktopContinuouslyActive: true,
            provisioningContinuouslyComplete: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(observation).write(to: output, options: [.atomic])
    }

}
