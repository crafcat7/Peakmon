import AppKit
import Darwin
import Observation
import PeakmonCollectors
import PeakmonCore

struct FrameRateApplicationTarget: Identifiable, Hashable, Sendable {
    let name: String
    let identity: FrameRateProcessIdentity
    let bundlePath: String

    var id: String { "\(identity.pid):\(identity.startSeconds):\(identity.startMicroseconds)" }
}

/// Owns collection independently of the page's visibility or SwiftUI lifetime.
@MainActor
@Observable
final class FrameRateObservationStore {
    var scope: FrameRateScope = .desktop
    var selectedApplicationID: String?
    var selectedSourceID: String?
    private(set) var applications: [FrameRateApplicationTarget] = []
    private(set) var sources: [FrameRateSource] = []
    private(set) var session = FrameRateObservationSession()
    private(set) var statusTitle = "Not started"
    private(set) var message: String?
    private(set) var elapsed: TimeInterval = 0

    private enum Phase { case idle, preparing, observing, stopping }
    private var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var selectedScope: FrameRateScope = .desktop
    @ObservationIgnored private var selectedApp: String?
    @ObservationIgnored private var selectedSource: String?
    @ObservationIgnored private var startedUptime: TimeInterval?
    @ObservationIgnored private let desktopCollector = FrameRateCollector()
    @ObservationIgnored private let applicationCollector = MetalFrameRateCollector()
    private static let observationDuration = FrameRateObservationSession.observationDuration

    var applicationSupported: Bool { MetalFrameRateCollector.isSupported }
    var isRunning: Bool { phase == .preparing || phase == .observing || phase == .stopping }
    var isPreparing: Bool { phase == .preparing }
    var isStopping: Bool { phase == .stopping }
    var canStop: Bool { phase == .preparing || phase == .observing }
    var canMark: Bool { phase == .observing && session.startedAt != nil && session.markers.count < 60 }

    var canStart: Bool {
        guard !isRunning else { return false }
        if scope == .desktop { return true }
        guard applicationSupported, let application = selectedApplication,
              Self.isCurrent(application.identity) else { return false }
        return sources.count < 2 || sources.contains { $0.id == selectedSourceID }
    }

    var latestReading: FrameRateReading? {
        guard let latest = session.readings.last else { return nil }
        if !isRunning { return latest }
        let age = Date.now.timeIntervalSince(latest.intervalEnd)
        // A delayed trace is displayed as recorded data, never a fresh poll.
        return age >= -1 && age <= 15 ? latest : nil
    }

    var isDelayed: Bool {
        guard isRunning, let latest = session.readings.last else { return false }
        return Date.now.timeIntervalSince(latest.intervalEnd) > 4
    }

    private var selectedApplication: FrameRateApplicationTarget? {
        applications.first { $0.id == selectedApplicationID }
    }

    func refreshApplications() {
        guard !isRunning else { return }
        applications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let identity = MetalFrameRateCollector.identity(for: app.processIdentifier)
            else { return nil }
            return FrameRateApplicationTarget(
                name: app.localizedName ?? String(app.processIdentifier),
                identity: identity,
                bundlePath: app.bundleURL?.standardizedFileURL.path ?? "",
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Refreshing the list must preserve a finished observation of an exited target.
        if !applications.contains(where: { $0.id == selectedApplicationID }), session.startedAt == nil {
            selectedApplicationID = nil
            selectionChanged()
        }
    }

    func selectionChanged() {
        guard !isRunning else { return }
        let scopeChanged = scope != selectedScope
        let appChanged = scope == .application && selectedApplicationID != selectedApp
        let sourceChanged = scope == .application && selectedSourceID != selectedSource
        selectedScope = scope
        selectedApp = selectedApplicationID
        selectedSource = selectedSourceID
        guard scopeChanged || appChanged || sourceChanged else { return }
        if scopeChanged || appChanged {
            sources = []
            selectedSourceID = nil
            selectedSource = nil
        }
        session = FrameRateObservationSession()
        elapsed = 0
        phase = .idle
        statusTitle = "Not started"
        message = nil
    }

    func start() {
        guard !isRunning else { return }
        // A target can exit while the idle UI still displays its old enabled
        // button. Explain that event and preserve any completed results.
        if scope == .application, let application = selectedApplication,
           !Self.isCurrent(application.identity) {
            phase = .idle
            statusTitle = "Target exited"
            message = "The selected application has exited or restarted."
            return
        }
        guard canStart else { return }
        generation &+= 1
        let token = generation
        let observationScope = scope
        let target = observationScope == .application ? selectedApplication : nil
        let chosen = sources.first {
            $0.id == selectedSourceID && ($0.processIdentity.map(Self.isCurrent) ?? true)
        }
        let startDate = Date.now
        startedUptime = ProcessInfo.processInfo.systemUptime
        elapsed = 0
        session = FrameRateObservationSession()
        phase = .preparing
        statusTitle = "Preparing observation"
        message = nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.observe(scope: observationScope, application: target, chosen: chosen, startedAt: startDate, token: token)
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.observationDuration)) }
            catch { return }
            guard let self, generation == token else { return }
            stop(at: startDate.addingTimeInterval(Self.observationDuration), automatically: true)
        }
    }

    func stop() {
        stop(at: .now, automatically: false)
    }

    /// App termination waits for owned trace processes to be reaped.
    func stopAndWait() async {
        stop()
        await task?.value
    }

    private func stop(at stoppedAt: Date, automatically: Bool) {
        guard isRunning, phase != .stopping else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        generation &+= 1
        let token = generation
        let oldTask = task
        task = nil
        oldTask?.cancel()
        phase = .stopping
        statusTitle = "Stopping observation"
        updateElapsed(at: ProcessInfo.processInfo.systemUptime)
        task = Task { [weak self] in
            guard let self else { return }
            await applicationCollector.stop()
            await oldTask?.value
            await desktopCollector.reset()
            guard generation == token else { return }
            session.finish(at: stoppedAt)
            phase = .idle
            statusTitle = automatically && session.readings.isEmpty ? "No frame rate data" : "Observation ended"
            if automatically && session.readings.isEmpty {
                message = "No new presentation data was recorded during this observation."
            }
            task = nil
        }
    }

    func mark() {
        guard phase == .observing else { return }
        session.mark()
    }

    private func observe(
        scope: FrameRateScope,
        application: FrameRateApplicationTarget?,
        chosen: FrameRateSource?,
        startedAt: Date,
        token: UInt64,
    ) async {
        do {
            await desktopCollector.reset()
            await applicationCollector.stop()
            try ensureCurrent(token)
            var fixedSource = chosen
            if scope == .application {
                guard let application, Self.isCurrent(application.identity) else {
                    await end(title: "Target exited", message: "The selected application has exited or restarted.", token: token)
                    return
                }
                if fixedSource == nil {
                    let identities = await Task.detached(priority: .utility) {
                        Self.candidateIdentities(for: application)
                    }.value
                    sources = try await applicationCollector.discoverSources(for: identities)
                    try ensureCurrent(token)
                    guard Self.isCurrent(application.identity) else {
                        await end(title: "Target exited", message: "The selected application has exited or restarted.", token: token)
                        return
                    }
                    if sources.count > 1 {
                        deadlineTask?.cancel()
                        deadlineTask = nil
                        selectedSourceID = nil
                        phase = .idle
                        statusTitle = "Not started"
                        message = "Choose a presentation source before starting. Frame rates from different sources are not added."
                        task = nil
                        return
                    }
                    guard let source = sources.first else {
                        await end(title: "No frame rate data", message: "This application currently provides no readable Metal frame-rate data. Try again while it is rendering.", token: token)
                        return
                    }
                    fixedSource = source
                    selectedSourceID = source.id
                }
                guard let fixedSource else { return }
                selectedSource = selectedSourceID
                session.begin(source: fixedSource, at: startedAt)
            }
            phase = .observing
            statusTitle = "Observing"
            var missingDesktopWindows = 0
            var nextApplicationPoll: TimeInterval = 0
            while generation == token && !Task.isCancelled {
                let uptime = ProcessInfo.processInfo.systemUptime
                updateElapsed(at: uptime)
                if elapsed >= Self.observationDuration { break }
                if let application, !Self.isCurrent(application.identity) {
                    await end(title: "Target exited", message: "The selected application has exited or restarted.", token: token)
                    return
                }
                if scope == .desktop {
                    if let reading = try await desktopCollector.collectReading() {
                        try ensureCurrent(token)
                        if session.source == nil {
                            session.begin(source: reading.source, at: startedAt)
                        }
                        session.ingest([reading])
                        missingDesktopWindows = 0
                    } else {
                        missingDesktopWindows += 1
                        if missingDesktopWindows >= 8 {
                            await end(title: "No frame rate data", message: "No active display presentation source is available. Display activity is required to identify an external source.", token: token)
                            return
                        }
                    }
                } else if let fixedSource, uptime >= nextApplicationPoll {
                    let since = session.readings.last?.intervalEnd ?? startedAt
                    let readings = try await applicationCollector.sample(source: fixedSource, since: since)
                    try ensureCurrent(token)
                    guard let application, Self.isCurrent(application.identity) else {
                        await end(title: "Target exited", message: "The selected application has exited or restarted.", token: token)
                        return
                    }
                    session.ingest(readings)
                    nextApplicationPoll = ProcessInfo.processInfo.systemUptime + 3
                }
                try await Task.sleep(for: .seconds(1))
            }
            try ensureCurrent(token)
            await end(
                title: session.readings.isEmpty ? "No frame rate data" : "Observation ended",
                message: session.readings.isEmpty ? "No new presentation data was recorded during this observation." : nil,
                token: token,
            )
        } catch is CancellationError {
            // The stop owner handles teardown and publishes the final state.
        } catch {
            guard generation == token else { return }
            if error as? FrameRateCollectorError == .displayConfigurationChanged {
                await end(title: "Observation ended", message: "The display configuration changed. Start a new observation for the current source.", token: token)
            } else if error as? FrameRateCollectorError == .sourceUnavailable {
                await end(title: "No frame rate data", message: "The display presentation source became unavailable.", token: token)
            } else if error as? MetalFrameRateError == .processChanged {
                await end(title: "Target exited", message: "The selected presentation process has exited or restarted.", token: token)
            } else {
                await end(title: "Observation failed", message: "Frame-rate data could not be read. Start a new observation to retry.", token: token)
            }
        }
    }

    private func ensureCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func updateElapsed(at uptime: TimeInterval) {
        elapsed = min(Self.observationDuration, max(0, uptime - (startedUptime ?? uptime)))
    }

    private func end(title: String, message: String?, token: UInt64) async {
        guard generation == token else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        phase = .stopping
        let endedAt = Date.now
        updateElapsed(at: ProcessInfo.processInfo.systemUptime)
        await desktopCollector.reset()
        await applicationCollector.stop()
        guard generation == token else { return }
        session.finish(at: endedAt)
        phase = .idle
        statusTitle = title
        self.message = message
        task = nil
    }

    nonisolated private static func isCurrent(_ identity: FrameRateProcessIdentity) -> Bool {
        MetalFrameRateCollector.identity(for: identity.pid) == identity
    }

    /// Bundle descendants cover helper executables without trusting CPU order.
    /// Sources outside this bundle remain unclaimed rather than assigned to it.
    nonisolated private static func candidateIdentities(for target: FrameRateApplicationTarget) -> [FrameRateProcessIdentity] {
        guard !target.bundlePath.isEmpty else { return [target.identity] }
        // Workspace URLs can retain aliases such as /tmp, while proc_pidpath
        // reports /private/tmp. Compare canonical paths for bundled helpers.
        let bundlePath = URL(fileURLWithPath: target.bundlePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [target.identity] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [target.identity] }
        var identities = Set([target.identity])
        for pid in pids.prefix(min(Int(actual), pids.count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let end = path.firstIndex(of: 0) ?? path.endIndex
            let string = String(decoding: path[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let processPath = URL(fileURLWithPath: string)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard processPath.hasPrefix(bundlePath + "/"),
                  isDescendant(pid: pid, of: target.identity.pid),
                  let identity = MetalFrameRateCollector.identity(for: pid)
            else { continue }
            identities.insert(identity)
        }
        return identities.sorted { $0.pid < $1.pid }
    }

    nonisolated private static func isDescendant(pid: Int32, of ancestor: Int32) -> Bool {
        var current = pid
        var visited = Set<Int32>()
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard current > 1, visited.insert(current).inserted else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
            current = Int32(bitPattern: info.pbi_ppid)
        }
        return false
    }
}
