import Darwin
import Foundation
import PeakmonCore

/// Reads always-on Metal presentation statistics on macOS 27 and later.
/// The Apple-signed command line tool owns its logging entitlements. This
/// adapter neither enables the HUD nor changes a target's tracing settings.
/// Callers own observation cadence; each reading retains its recorded window.
public actor MetalFrameRateCollector {
    public nonisolated static var isSupported: Bool {
        if #available(macOS 27.0, *) {
            return FileManager.default.isExecutableFile(atPath: "/usr/bin/metalperftrace")
        }
        return false
    }

    /// Reads the birth time needed to distinguish a reused PID.
    public nonisolated static func identity(for pid: Int32) -> FrameRateProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return FrameRateProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
        )
    }

    private let runner: any MetalFrameRateRunning
    private let identityReader: @Sendable (Int32) -> FrameRateProcessIdentity?
    private let supported: Bool
    private var generation = UUID()
    private var deliveredEnds: [String: Date] = [:]

    public init() {
        runner = MetalFrameRateCommandRunner()
        identityReader = Self.identity
        supported = Self.isSupported
    }

    init(
        runner: any MetalFrameRateRunning,
        identityReader: @escaping @Sendable (Int32) -> FrameRateProcessIdentity?,
        supported: Bool = true,
    ) {
        self.runner = runner
        self.identityReader = identityReader
        self.supported = supported
    }

    /// Discovers recent, independently measurable layers for live candidates.
    public func discoverSources(for identities: [FrameRateProcessIdentity]) async throws -> [FrameRateSource] {
        guard supported else { throw MetalFrameRateError.unsupported }
        let live = Set(identities).filter { identityReader($0.pid) == $0 }
        guard !live.isEmpty else { return [] }
        let traces = try await snapshot(identities: Array(live))
        var sources: [String: FrameRateSource] = [:]
        for trace in traces where identityReader(trace.source.processIdentity?.pid ?? -1) == trace.source.processIdentity {
            if !trace.readings.isEmpty { sources[trace.source.id] = trace.source }
        }
        return sources.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// Returns new recorded windows for exactly the selected process and layer.
    /// Windows that start before `since` are excluded rather than relabelled.
    public func sample(source: FrameRateSource, since: Date) async throws -> [FrameRateReading] {
        guard supported else { throw MetalFrameRateError.unsupported }
        guard source.scope == .application,
              let identity = source.processIdentity, source.layerID != nil,
              identityReader(identity.pid) == identity
        else { throw MetalFrameRateError.processChanged }
        let traces = try await snapshot(identities: [identity])
        guard identityReader(identity.pid) == identity else { throw MetalFrameRateError.processChanged }
        let boundary = max(since, deliveredEnds[source.id] ?? since)
        var windows: [String: FrameRateReading] = [:]
        for trace in traces where trace.source.id == source.id {
            for reading in trace.readings where reading.intervalStart >= boundary {
                let selectedReading = FrameRateReading(
                    source: source,
                    intervalStart: reading.intervalStart,
                    intervalEnd: reading.intervalEnd,
                    framesPerSecond: reading.framesPerSecond,
                    frameIntervalMilliseconds: reading.frameIntervalMilliseconds,
                )
                windows[selectedReading.id] = selectedReading
            }
        }
        let result = windows.values.sorted { $0.intervalEnd < $1.intervalEnd }
        if let end = result.last?.intervalEnd { deliveredEnds[source.id] = end }
        return result
    }

    /// Cancels current reads and waits until all owned commands have exited.
    public func stop() async {
        generation = UUID()
        deliveredEnds.removeAll(keepingCapacity: true)
        await runner.stop()
    }

    private func snapshot(identities: [FrameRateProcessIdentity]) async throws -> [MetalFrameRateTraceSource] {
        let requestGeneration = generation
        try checkRequest(requestGeneration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peakmon-metal-fps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A wider lookback tolerates delayed persistence. The selected session
        // boundary and delivered end time still determine which windows escape.
        let collected = try await runner.run(
            arguments: ["collect", "--last", "30s", "--json", directory.path],
            directory: directory,
            timeout: 6,
        )
        try checkRequest(requestGeneration)
        guard let manifest = try JSONSerialization.jsonObject(with: collected) as? [String: Any],
              let paths = manifest["traces"] as? [String]
        else { throw MetalFrameRateError.invalidOutput }
        let predicate = "pid IN {\(Set(identities.map(\.pid)).sorted().map(String.init).joined(separator: ","))}"
        var result: [MetalFrameRateTraceSource] = []
        for path in paths {
            try checkRequest(requestGeneration)
            let traceURL = URL(fileURLWithPath: path).standardizedFileURL
            guard traceURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
                throw MetalFrameRateError.invalidOutput
            }
            let data = try await runner.run(
                // Exporting a timeline does not enable per-frame signposts.
                // Only the existing aggregate Stats Timeline is consumed.
                arguments: ["overview", "--json", "--json-include-timeline", "--predicate", predicate, traceURL.path],
                directory: directory,
                timeout: 6,
            )
            try checkRequest(requestGeneration)
            result.append(contentsOf: try MetalFrameRateParser.parse(data, identities: identities))
        }
        return result
    }

    private func checkRequest(_ requestGeneration: UUID) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
    }
}

public enum MetalFrameRateError: Error, Equatable {
    case unsupported
    case processChanged
    case invalidOutput
    case commandTimedOut
    case commandFailed(status: Int32)
}

struct MetalFrameRateTraceSource: Sendable {
    let source: FrameRateSource
    let readings: [FrameRateReading]
}

enum MetalFrameRateParser {
    static func parse(_ data: Data, identities: [FrameRateProcessIdentity]) throws -> [MetalFrameRateTraceSource] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let error = json as? [String: Any], error["error"] as? String == "No session found" { return [] }
        guard let processes = json as? [[String: Any]] else { throw MetalFrameRateError.invalidOutput }
        let identitiesByPID = Dictionary(identities.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let fractionalDates = ISO8601DateFormatter()
        fractionalDates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Date? {
            guard let raw = raw as? String else { return nil }
            return fractionalDates.date(from: raw) ?? dates.date(from: raw)
        }
        var result: [MetalFrameRateTraceSource] = []
        for process in processes {
            guard let pid = number(process["PID"]), pid.rounded() == pid,
                  pid > 0, pid <= Double(Int32.max),
                  let identity = identitiesByPID[Int32(pid)],
                  let layers = process["Layers"] as? [[String: Any]]
            else { continue }
            let processName = process["Process"] as? String ?? String(identity.pid)
            for layer in layers {
                guard let layerID = identifier(layer["Layer ID"]),
                      let timeline = layer["Stats Timeline"] as? [[String: Any]]
                else { continue }
                let configuration = (layer["Configuration Timeline"] as? [[String: Any]])?.last
                    ?? layer["Configuration"] as? [String: Any]
                var name = processName
                if let width = number(configuration?["Width (pixels)"]),
                   let height = number(configuration?["Height (pixels)"]), width > 0, height > 0
                {
                    name += String(format: " · %.0f×%.0f", width, height)
                }
                let source = FrameRateSource(
                    id: "metal:\(identity.pid):\(identity.startSeconds):\(identity.startMicroseconds):\(layerID)",
                    name: name,
                    scope: .application,
                    processIdentity: identity,
                    layerID: layerID,
                )
                var readings: [FrameRateReading] = []
                for window in timeline {
                    guard let start = date(window["Start Date"]), let end = date(window["End Date"]),
                          start >= identity.startedAt,
                          let presented = window["Presented Frame Stats"] as? [String: Any],
                          let fps = number(presented["FPS"]),
                          let count = number(presented["Frame Count"]), count >= 0,
                          let active = number(window["Time Active (sec)"]), active > 0
                    else { continue }
                    let intervals = window["Frame-On-Glass Interval Stats"] as? [String: Any]
                    let interval = number(intervals?["Average (ms)"]).flatMap { $0 > 0 ? $0 : nil }
                    let reading = FrameRateReading(
                        source: source,
                        intervalStart: start,
                        intervalEnd: end,
                        framesPerSecond: fps,
                        frameIntervalMilliseconds: interval,
                    )
                    if reading.isValid { readings.append(reading) }
                }
                result.append(MetalFrameRateTraceSource(source: source, readings: readings))
            }
        }
        return result
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let raw = raw as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
        let value = raw.doubleValue
        return value.isFinite ? value : nil
    }

    private static func identifier(_ raw: Any?) -> String? {
        if let raw = raw as? String, !raw.isEmpty { return raw }
        if let raw = raw as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() { return raw.stringValue }
        return nil
    }
}

protocol MetalFrameRateRunning: Sendable {
    func run(arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Data
    func stop() async
}

actor MetalFrameRateCommandRunner: MetalFrameRateRunning {
    private struct Operation {
        let state: MetalFrameRateCommandState
        let task: Task<Data, Error>
    }

    private let executable: URL
    private var operations: [UUID: Operation] = [:]

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/metalperftrace")) {
        self.executable = executable
    }

    func run(arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        let state = MetalFrameRateCommandState()
        let executable = executable
        let task = Task.detached(priority: .utility) {
            try state.run(executable: executable, arguments: arguments, directory: directory, timeout: timeout)
        }
        operations[id] = Operation(state: state, task: task)
        defer { operations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            state.cancel()
        }
    }

    func stop() async {
        let pending = Array(operations.values)
        for operation in pending { operation.state.cancel() }
        for operation in pending { _ = try? await operation.task.value }
    }
}

/// Process launch, signalling and completion are coordinated with one lock.
/// Blocking waits run on a utility task; file output avoids pipe deadlocks.
private final class MetalFrameRateCommandState: @unchecked Sendable {
    private enum StopReason { case cancelled, timedOut }
    private let lock = NSLock()
    private var process: Process?
    private var reason: StopReason?

    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) throws -> Data {
        let output = directory.appendingPathComponent("\(UUID().uuidString).stdout")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = outputHandle
        child.standardError = FileHandle.nullDevice
        lock.lock()
        guard reason == nil else { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout)) { [weak self] in
            self?.stop(.timedOut)
        }
        child.waitUntilExit()
        lock.lock()
        process = nil
        let stopReason = reason
        lock.unlock()
        switch stopReason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw MetalFrameRateError.commandTimedOut
        case nil: break
        }
        guard child.terminationStatus == 0 else {
            throw MetalFrameRateError.commandFailed(status: child.terminationStatus)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 64 * 1024 * 1024 else {
            throw MetalFrameRateError.invalidOutput
        }
        return try Data(contentsOf: output)
    }

    func cancel() { stop(.cancelled) }

    private func stop(_ stopReason: StopReason) {
        lock.lock()
        if reason == nil { reason = stopReason }
        let child = process
        lock.unlock()
        guard let child, child.isRunning else { return }
        child.terminate()
        // Bound cancellation even if a child ignores SIGTERM. This only
        // addresses the still-owned process, never an application target.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        }
    }
}
