import XCTest
@testable import agentpet
@testable import AgentPetCore

@MainActor
final class PetEdgeStateStoreTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, PetEdgeStateStore) throws -> Void) rethrows {
        let name = "pet-edge-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, PetEdgeStateStore(defaults: defaults))
    }

    func testSideRoundTripsPerWindowAndClearKeepsOtherKeys() {
        withDefaults { defaults, store in
            store.save(.left, forKey: "default")
            store.save(.right, forKey: "/work")
            XCTAssertEqual(store.side(forKey: "default"), .left)
            XCTAssertEqual(store.side(forKey: "/work"), .right)
            store.clear(forKey: "default")
            XCTAssertNil(store.side(forKey: "default"))
            XCTAssertEqual(store.side(forKey: "/work"), .right)
            XCTAssertNotNil(defaults.data(forKey: PetEdgeStateStore.sidesKey))
        }
    }

    func testBadOrUnknownValuesAreIgnoredWithoutCrashing() {
        withDefaults { defaults, store in
            defaults.set(Data("not-json".utf8), forKey: PetEdgeStateStore.sidesKey)
            XCTAssertNil(store.side(forKey: "default"))
            let bogus = try! JSONEncoder().encode(["default": "up", "/work": "left"])
            defaults.set(bogus, forKey: PetEdgeStateStore.sidesKey)
            XCTAssertNil(store.side(forKey: "default"))
            XCTAssertEqual(store.side(forKey: "/work"), .left)
            store.save(.right, forKey: "default")
            XCTAssertEqual(store.side(forKey: "default"), .right)
            XCTAssertEqual(store.side(forKey: "/work"), .left)
        }
    }

    func testOversizedPayloadIsRejected() {
        withDefaults { defaults, store in
            let huge = Data(repeating: 0x7b, count: 131_073)
            defaults.set(huge, forKey: PetEdgeStateStore.sidesKey)
            XCTAssertNil(store.side(forKey: "default"))
            store.save(.left, forKey: "default")
            XCTAssertEqual(store.side(forKey: "default"), .left)
        }
    }
}
