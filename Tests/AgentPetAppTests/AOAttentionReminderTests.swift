import AppKit
import SwiftUI
import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class AOAttentionReminderTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_793_513_220)
    private let instance = "apprun-33333333-3333-3333-3333-333333333333"

    private func observation(_ id: String, activity: AOHostActivity = .waitingInput) -> AOHostObservation {
        AOHostObservation(sessionID: id, projectID: "project", role: .worker,
            harness: "opencode-v2", displayName: "Worker", status: "needs_input",
            activity: activity, activityAt: at, isTerminated: false,
            createdAt: at.addingTimeInterval(-100), updatedAt: at, observedAt: at,
            instanceID: instance)
    }

    private func receipt(_ id: String) -> AOAttentionReceipt {
        .init(observation: observation(id), version: 1, readThroughVersion: 0,
              waitingAt: at, instanceID: instance, lastWasWaiting: true, latestUpdatedAt: at)
    }

    func testSameNamedMembersHaveDistinctReminderSourcesAndOriginalEventTime() {
        let first = AOAttentionReminder(receipt: receipt("worker-1"))
        let second = AOAttentionReminder(receipt: receipt("worker-2"))
        XCTAssertNotEqual(first.sourceLabel, second.sourceLabel)
        XCTAssertTrue(first.sourceLabel.hasPrefix("worker-1"), "source ID must remain visible before a truncated title")
        XCTAssertEqual(first.occurredAt, at)
        var older = receipt("worker-1")
        older.observation.updatedAt = at.addingTimeInterval(100)
        XCTAssertEqual(AOAttentionReminder(receipt: older).occurredAt, at,
                       "polling time must not replace the saved waiting time")
        older.observation.displayName = "  "
        XCTAssertEqual(AOAttentionReminder(receipt: older).sourceLabel, "worker-1")
    }

    func testReminderAfterHostResumesUsesTheSavedWaitAndDismissesOnlyItsCapturedVersion() throws {
        let store = SessionStore()
        let first = observation("worker-1"), second = observation("worker-2")
        func snapshot(_ rows: [AOHostObservation]) -> AOSnapshot {
            .init(instanceID: instance, observedAt: at, projectNames: [:], sessions: rows)
        }
        _ = store.applyAOSnapshot(snapshot([first, second]), now: at)
        let captured = try XCTUnwrap(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }
            .first { $0.observation.sessionID == "worker-1" })
        var working = first
        working.activity = .active; working.status = "working"
        working.updatedAt = at.addingTimeInterval(1); working.activityAt = working.updatedAt
        _ = store.applyAOSnapshot(snapshot([working, second]), now: at)
        let saved = try XCTUnwrap(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }
            .first { $0.id == captured.id })
        XCTAssertEqual(saved.observation.activity, .waitingInput)
        XCTAssertEqual(AOAttentionReminder(receipt: saved).occurredAt, at)
        XCTAssertTrue(store.acknowledgeAO(captured, at: at.addingTimeInterval(2)))
        XCTAssertEqual(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }.filter(\.hasUnread)
            .map { $0.observation.sessionID }, ["worker-2"])
        _ = store.applyAOSnapshot(snapshot([working, second]), now: at)
        XCTAssertFalse(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }
            .contains { $0.id == captured.id && $0.hasUnread })
        var later = first
        later.updatedAt = at.addingTimeInterval(3); later.activityAt = later.updatedAt
        _ = store.applyAOSnapshot(snapshot([later, second]), now: at)
        XCTAssertFalse(store.acknowledgeAO(captured, at: at.addingTimeInterval(4)))
        XCTAssertTrue(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }
            .contains { $0.id == captured.id && $0.hasUnread }, "an old dismiss must not hide a later reminder")
    }

    func testReminderActionHasContrastOnLightAndDarkBackgroundsAtNarrowWidths() throws {
        _ = NSApplication.shared
        for width in [220.0, 300.0] {
            for dark in [false, true] {
                let renderer = ImageRenderer(content:
                    AOAttentionReminderView(receipt: receipt("worker-1"), fontSize: 12,
                        backgroundOpacity: 0, textOpacity: 1, acknowledge: {})
                        .frame(width: width).padding(8)
                        .background(dark ? Color.black : Color.white)
                        .environment(\.locale, Locale(identifier: "zh-Hans")))
                renderer.scale = 2
                let cg = try XCTUnwrap(renderer.cgImage)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
                XCTAssertEqual(bitmap.pixelsWide, Int((width + 16) * 2))
                XCTAssertLessThan(bitmap.pixelsHigh, 180, "the reminder must wrap within its row")
                if !dark {
                    var darkPixels = 0
                    for y in 16..<min(66, bitmap.pixelsHigh) {
                        for x in (bitmap.pixelsWide - 90)..<(bitmap.pixelsWide - 16) {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.6 { darkPixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(darkPixels, 500, "the action needs a contrasting surface on a white desktop")
                }
                if let folder = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"] {
                    try png.write(to: URL(fileURLWithPath: folder)
                        .appendingPathComponent("ao-reminder-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
