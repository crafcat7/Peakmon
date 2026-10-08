import Darwin
import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("Metal frame-rate observation")
struct MetalFrameRateCollectorTests {
    private let identity = FrameRateProcessIdentity(pid: 41, startSeconds: 90, startMicroseconds: 123)

    private func window(start: Double, end: Double, fps: Any = 60.0, count: Int = 60) -> [String: Any] {
        [
            "Start Date": Date(timeIntervalSince1970: start).ISO8601Format(.init(includingFractionalSeconds: true)),
            "End Date": Date(timeIntervalSince1970: end).ISO8601Format(.init(includingFractionalSeconds: true)),
            "Time Active (sec)": end - start,
            "Presented Frame Stats": ["FPS": fps, "Frame Count": count],
            "Frame-On-Glass Interval Stats": ["Average (ms)": count == 0 ? 0.0 : 16.8],
        ]
    }

    private func fixture(windows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            ["PID": 999, "Process": "Other process", "Layers": [
                ["Layer ID": "other", "Stats Timeline": windows],
            ]],
            ["PID": 41, "Process": "Target renderer", "Layers": [
                ["Layer ID": "A", "Stats Timeline": windows, "Configuration Timeline": [
                    ["Width (pixels)": 240, "Height (pixels)": 160],
                ]],
                ["Layer ID": "B", "Stats Timeline": [window(start: 100, end: 101, fps: 120)]],
            ]],
        ])
    }

    @Test func parsesOnlyRequestedPIDAndKeepsLayersIndependent() throws {
        let parsed = try MetalFrameRateParser.parse(fixture(windows: [window(start: 100, end: 101, fps: 59.25)]), identities: [identity])
        #expect(parsed.count == 2)
        #expect(parsed.map(\.source.layerID) == ["A", "B"])
        #expect(parsed[0].source.id == "metal:41:90:123:A")
        #expect(parsed[0].source.name == "Target renderer · 240×160")
        let reading = try #require(parsed[0].readings.first)
        #expect(reading.framesPerSecond == 59.25)
        #expect(reading.frameIntervalMilliseconds == 16.8)
        #expect(reading.intervalStart == Date(timeIntervalSince1970: 100))
        #expect(reading.intervalEnd == Date(timeIntervalSince1970: 101))
        #expect(parsed[1].readings.first?.framesPerSecond == 120)
    }

    @Test func rejectsOldProcessWindowsAndMalformedValuesButPreservesRecordedZero() throws {
        let parsed = try MetalFrameRateParser.parse(fixture(windows: [
            window(start: 89, end: 90),
            window(start: 100, end: 99),
            window(start: 100, end: 101, fps: -1),
            window(start: 100, end: 101, fps: true),
            window(start: 100, end: 101, fps: "60"),
            window(start: 101, end: 102, fps: 0.0, count: 0),
        ]), identities: [identity])
        #expect(parsed[0].readings.count == 1)
        #expect(parsed[0].readings[0].framesPerSecond == 0)
        #expect(parsed[0].readings[0].frameIntervalMilliseconds == nil)
        #expect(try MetalFrameRateParser.parse(Data(#"{"error":"No session found"}"#.utf8), identities: [identity]).isEmpty)
        #expect(throws: MetalFrameRateError.invalidOutput) {
            try MetalFrameRateParser.parse(Data(#"{"unrecognized":[]}"#.utf8), identities: [identity])
        }
    }

    @Test func discoversSourcesThenDeliversOnlyNewSessionWindowsAndCleansTemporaryFiles() async throws {
        let data = try fixture(windows: [
            window(start: 100, end: 101), window(start: 101, end: 102),
            window(start: 101, end: 102), window(start: 102, end: 103),
        ])
        let runner = MetalFrameRateFixtureRunner(data: data)
        let identity = identity
        let collector = MetalFrameRateCollector(runner: runner, identityReader: { $0 == identity.pid ? identity : nil })
        let sources = try await collector.discoverSources(for: [identity])
        let source = try #require(sources.first { $0.layerID == "A" })
        let first = try await collector.sample(source: source, since: Date(timeIntervalSince1970: 101))
        #expect(first.map(\.intervalStart) == [Date(timeIntervalSince1970: 101), Date(timeIntervalSince1970: 102)])
        #expect(first.allSatisfy { $0.source == source })
        #expect(try await collector.sample(source: source, since: Date(timeIntervalSince1970: 101)).isEmpty)
        let directories = await runner.directories
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let commands = await runner.commands
        #expect(commands.allSatisfy { $0.first == "collect" || $0.first == "overview" })
        await collector.stop()
    }

    @Test func refusesPIDReuseDuringTheRead() async throws {
        let box = MetalFrameRateIdentityBox(identity)
        let runner = MetalFrameRateFixtureRunner(data: try fixture(windows: [window(start: 100, end: 101)]), beforeOverview: {
            box.set(FrameRateProcessIdentity(pid: 41, startSeconds: 99, startMicroseconds: 0))
        })
        let collector = MetalFrameRateCollector(runner: runner, identityReader: { box.read($0) })
        let source = FrameRateSource(id: "metal:41:90:123:A", name: "Target", scope: .application, processIdentity: identity, layerID: "A")
        await #expect(throws: MetalFrameRateError.processChanged) {
            try await collector.sample(source: source, since: Date(timeIntervalSince1970: 100))
        }
        #expect(await runner.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func commandDeadlineKillsAndReapsAnUnresponsiveChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peakmon-fps-timeout-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let runner = MetalFrameRateCommandRunner(executable: URL(fileURLWithPath: "/bin/sh"))
        await #expect(throws: MetalFrameRateError.commandTimedOut) {
            try await runner.run(arguments: ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10", "probe", pidFile.path], directory: directory, timeout: 0.1)
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["pid"])
        await runner.stop()
    }

    @Test func stoppingWaitsForChildExitAndCancelledTaskReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peakmon-fps-stop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let runner = MetalFrameRateCommandRunner(executable: URL(fileURLWithPath: "/bin/sh"))
        let task = Task {
            try await runner.run(arguments: ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10", "probe", pidFile.path], directory: directory, timeout: 20)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        await runner.stop()
        do { _ = try await task.value; Issue.record("A stopped command unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}

private actor MetalFrameRateFixtureRunner: MetalFrameRateRunning {
    let data: Data
    let beforeOverview: @Sendable () -> Void
    private(set) var directories: [URL] = []
    private(set) var commands: [[String]] = []

    init(data: Data, beforeOverview: @escaping @Sendable () -> Void = {}) {
        self.data = data
        self.beforeOverview = beforeOverview
    }

    func run(arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Data {
        commands.append(arguments)
        directories.append(directory)
        if arguments.first == "collect" {
            return try JSONSerialization.data(withJSONObject: ["traces": [directory.appendingPathComponent("fixture.atrc").path]])
        }
        beforeOverview()
        return data
    }

    func stop() {}
}

private final class MetalFrameRateIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: FrameRateProcessIdentity
    init(_ identity: FrameRateProcessIdentity) { self.identity = identity }
    func read(_ pid: Int32) -> FrameRateProcessIdentity? {
        lock.withLock { identity.pid == pid ? identity : nil }
    }
    func set(_ identity: FrameRateProcessIdentity) { lock.withLock { self.identity = identity } }
}
