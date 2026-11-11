import Foundation
import AppKit
import AgentPetCore

/// Polls AO's independent read capability. It never navigates, writes AO state,
/// sends model tasks or treats a selected/idle session as a read receipt.
@MainActor
final class AOSessionReadingObserver {
    typealias Loaded = (AORunFile, AOSessionReadFrame)
    private let load: @Sendable () -> Loaded?
    private let publisherMatches: @MainActor (AOSessionReadFrame) -> Bool
    private let enabled: () -> Bool
    private let sessions: () -> [AgentSession]
    private let markRead: (AgentSession, Date) -> Bool
    private let refreshUI: () -> Void
    private var task: Task<Void, Never>?
    private var refreshing = false
    private var stopped = false

    init(load: @escaping @Sendable () -> Loaded? = AOSessionReadingObserver.read,
         publisherMatches: @escaping @MainActor (AOSessionReadFrame) -> Bool = AOSessionReadingObserver.matchesPublisher,
         enabled: @escaping () -> Bool,
         sessions: @escaping () -> [AgentSession],
         markRead: @escaping (AgentSession, Date) -> Bool,
         refreshUI: @escaping () -> Void) {
        self.load = load; self.publisherMatches = publisherMatches; self.enabled = enabled
        self.sessions = sessions; self.markRead = markRead; self.refreshUI = refreshUI
    }
    func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                await self.refreshNow()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    func stop() { stopped = true; task?.cancel(); task = nil }
    func refreshNow() async {
        guard !stopped, !refreshing, enabled() else { return }
        refreshing = true
        let read = load
        let value = await Task.detached(priority: .utility) { read() }.value
        refreshing = false
        guard !stopped, enabled(), let (run, frame) = value,
              frame.isCurrent(run: run, now: Date()), publisherMatches(frame) else { return }
        var changed = false
        for native in sessions() where native.aoObservation?.instanceID == run.appRunID {
            let receipts = frame.receipts.filter {
                $0.sessionId == native.aoBinding?.sessionID && $0.projectId == native.aoBinding?.projectID
                    && AOAPIDate.parse($0.sessionCreatedAt) == native.aoObservation?.createdAt
            }
            // Duplicate owners are ambiguous evidence, never a batch read.
            guard receipts.count == 1, let receipt = receipts.first, receipt.covers(native, now: Date()) else { continue }
            if markRead(native, Date(timeIntervalSince1970: receipt.viewedAt / 1000)) { changed = true }
        }
        if changed { refreshUI() }
    }
    nonisolated static func read() -> Loaded? {
        let runPath = AORunFile.path()
        guard let run = AORunFile.read(path: runPath) else { return nil }
        let location = URL(fileURLWithPath: runPath).deletingLastPathComponent().appendingPathComponent("desktop-session-reading-v1.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: location.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0, bytes.intValue < 4_194_304,
              let data = try? Data(contentsOf: location), data.count < 4_194_304,
              let frame = try? JSONDecoder().decode(AOSessionReadFrame.self, from: data),
              run == AORunFile.read(path: runPath) else { return nil }
        return (run, frame)
    }
    static func matchesPublisher(_ frame: AOSessionReadFrame) -> Bool {
        guard AORunFile.read()?.appRunID == frame.appRunId,
              let app = NSRunningApplication(processIdentifier: frame.pid), !app.isTerminated,
              let bundle = app.bundleURL else { return false }
        return bundle.resolvingSymlinksInPath().standardizedFileURL
            == URL(fileURLWithPath: frame.appPath).resolvingSymlinksInPath().standardizedFileURL
    }
}
