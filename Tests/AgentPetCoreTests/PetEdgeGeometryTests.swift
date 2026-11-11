import XCTest
import CoreGraphics
@testable import AgentPetCore

final class PetEdgeGeometryTests: XCTestCase {
    private let left = PetEdgeScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                     visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 750))
    private let right = PetEdgeScreen(frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                      visibleFrame: CGRect(x: 1000, y: 25, width: 1000, height: 750))

    func testSnapsOnlyAtOuterEdgesAndNotAtSeams() {
        let outerLeft = CGRect(x: 4, y: 100, width: 120, height: 120)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: outerLeft, screens: [left, right],
                                            snapDistance: 20)?.side, .left)
        let seamLeft = CGRect(x: 950, y: 100, width: 120, height: 120)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: seamLeft, screens: [left, right],
                                          snapDistance: 30))
        let seamRight = CGRect(x: 990, y: 100, width: 120, height: 120)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: seamRight, screens: [left, right],
                                          snapDistance: 30))
        let outerRight = CGRect(x: 1900, y: 100, width: 120, height: 120)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: outerRight, screens: [left, right],
                                            snapDistance: 20)?.side, .right)
    }

    func testOutwardReleaseStillSnapsWhileAnyUsablePartRemainsVisibleOnEitherSide() {
        let distance: CGFloat = 12.6
        for width: CGFloat in [35, 70, 180] {
            for side in PetEdgeSide.allCases {
                for outward in [-distance + 0.01, 0, distance + 1, width * 0.75, width - 0.5] {
                    let x = side == .right ? left.visibleFrame.maxX - width + outward
                        : left.visibleFrame.minX - outward
                    let frame = CGRect(x: x, y: 100, width: width, height: width)
                    XCTAssertEqual(PetEdgeGeometry.snap(petFrame: frame, screens: [left],
                        snapDistance: distance)?.side, side, "\(side) width=\(width) outward=\(outward)")
                }
                let outside = side == .right ? left.visibleFrame.maxX + 1
                    : left.visibleFrame.minX - width - 1
                XCTAssertNil(PetEdgeGeometry.snap(petFrame: CGRect(x: outside, y: 100, width: width, height: width),
                    screens: [left], snapDistance: distance), "Completely outside still uses recovery")
                let tooFarInside = side == .right ? left.visibleFrame.maxX - width - distance - 1
                    : left.visibleFrame.minX + distance + 1
                XCTAssertNil(PetEdgeGeometry.snap(petFrame: CGRect(x: tooFarInside, y: 100, width: width, height: width),
                    screens: [left], snapDistance: distance), "Do not expand the in-screen attraction range")
            }
        }
    }

    func testOvershootAcrossSharedSeamNeverTucksOnEitherSide() {
        for outward: CGFloat in [0, 20, 69.5] {
            for x in [left.frame.maxX - 70 + outward, right.frame.minX - outward] {
                XCTAssertNil(PetEdgeGeometry.snap(petFrame: CGRect(x: x, y: 100, width: 70, height: 70),
                    screens: [left, right], snapDistance: 12.6))
            }
        }
    }

    func testPartialSharedEdgeOnlyBlocksItsLocalVerticalBand() {
        let upper = PetEdgeScreen(frame: CGRect(x: -1000, y: 400, width: 1000, height: 400),
                                  visibleFrame: CGRect(x: -1000, y: 400, width: 1000, height: 400))
        let screens = [left, upper]
        let lowPet = CGRect(x: 2, y: 80, width: 120, height: 120)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: lowPet, screens: screens,
                                            snapDistance: 20)?.side, .left)
        let highPet = CGRect(x: 2, y: 500, width: 120, height: 120)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: highPet, screens: screens,
                                          snapDistance: 20),
                     "A display sharing only the upper band must not hide the whole side")
    }

    func testOutwardReleaseKeepsLocalPartialSeamsAndNegativeScreenCoordinates() {
        let primary = PetEdgeScreen(frame: CGRect(x: -1700, y: -200, width: 1000, height: 800),
            visibleFrame: CGRect(x: -1700, y: -175, width: 1000, height: 750))
        let upper = PetEdgeScreen(frame: CGRect(x: -2700, y: 200, width: 1000, height: 400),
            visibleFrame: CGRect(x: -2700, y: 200, width: 1000, height: 400))
        let low = CGRect(x: -1768, y: -100, width: 70, height: 70)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: low, screens: [primary, upper], snapDistance: 12.6)?.side, .left)
        let shared = low.offsetBy(dx: 0, dy: 400)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: shared, screens: [primary, upper], snapDistance: 12.6))
        let right = CGRect(x: -702, y: -100, width: 70, height: 70)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: right, screens: [primary, upper], snapDistance: 12.6)?.side, .right)
    }

    func testDockInsetRemainsTheTuckLineAcrossPartialOvershoot() {
        let docked = PetEdgeScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                   visibleFrame: CGRect(x: 80, y: 25, width: 920, height: 750))
        let atDock = CGRect(x: 82, y: 100, width: 120, height: 120)
        let atPhysicalEdge = CGRect(x: 2, y: 100, width: 120, height: 120)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: atDock, screens: [docked],
                                            snapDistance: 20)?.side, .left)
        // The updated outward-release contract permits this formerly refused
        // position: 42pt still overlaps usable space. It still tucks at x=80,
        // never at the physical x=0 edge or behind the Dock.
        let overshot = PetEdgeGeometry.snap(petFrame: atPhysicalEdge, screens: [docked], snapDistance: 20)
        XCTAssertEqual(overshot?.side, .left)
        XCTAssertEqual(overshot?.visibleFrame.minX, 80)
        let dockOnly = CGRect(x: 2, y: 100, width: 70, height: 70)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: dockOnly, screens: [docked], snapDistance: 20))
        let rightDock = PetEdgeScreen(frame: docked.frame,
            visibleFrame: CGRect(x: 0, y: 25, width: 920, height: 750))
        let rightOvershot = CGRect(x: 878, y: 100, width: 120, height: 120)
        XCTAssertEqual(PetEdgeGeometry.snap(petFrame: rightOvershot, screens: [rightDock], snapDistance: 20)?.visibleFrame.maxX, 920)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: CGRect(x: 928, y: 100, width: 70, height: 70),
                                          screens: [rightDock], snapDistance: 20))
    }

    func testFarOutsideOrVerticallyOutsideUsesRecoveryNotTuck() {
        let farRight = CGRect(x: 1200, y: 100, width: 120, height: 120)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: farRight, screens: [left, right],
                                          snapDistance: 24))
        let above = CGRect(x: 4, y: 900, width: 120, height: 120)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: above, screens: [left, right],
                                          snapDistance: 24))
        let below = CGRect(x: 4, y: -200, width: 120, height: 120)
        XCTAssertNil(PetEdgeGeometry.snap(petFrame: below, screens: [left, right],
                                          snapDistance: 24))
    }

    func testNearestScreenUsesRectangleDistanceInsteadOfMain() {
        let offRight = CGRect(x: 2400, y: 100, width: 100, height: 100)
        XCTAssertEqual(PetEdgeGeometry.nearestScreenIndex(for: offRight,
                                                          screens: [left, right]), 1)
        let offLeft = CGRect(x: -500, y: 100, width: 100, height: 100)
        XCTAssertEqual(PetEdgeGeometry.nearestScreenIndex(for: offLeft,
                                                          screens: [left, right]), 0)
    }

    func testPeekLayoutUsesAlphaContentAtPetSize70() throws {
        let content = CGSize(width: 535, height: 1140)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 900)
        let rightPeek = try XCTUnwrap(PetEdgeGeometry.peekLayout(
            anchor: CGPoint(x: visible.maxX, y: 200), petSize: 70,
            contentSize: content, visible: visible, side: .right))
        XCTAssertEqual(rightPeek.frame.height, 50, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rightPeek.frame.width, 44.001)
        XCTAssertEqual(rightPeek.frame.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertFalse(rightPeek.cropsInnerSide)
        XCTAssertGreaterThanOrEqual(rightPeek.frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(rightPeek.frame.maxY, visible.maxY)

        let leftPeek = try XCTUnwrap(PetEdgeGeometry.peekLayout(
            anchor: CGPoint(x: visible.minX, y: 200), petSize: 70,
            contentSize: content, visible: visible, side: .left))
        XCTAssertEqual(leftPeek.frame.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(leftPeek.frame.height, 50, accuracy: 0.001)
    }

    func testPeekLayoutCropsWideContentAndClampsVertically() throws {
        let visible = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let wide = try XCTUnwrap(PetEdgeGeometry.peekLayout(
            anchor: CGPoint(x: visible.maxX, y: -100), petSize: 70,
            contentSize: CGSize(width: 1000, height: 1000), visible: visible, side: .right))
        XCTAssertTrue(wide.cropsInnerSide)
        XCTAssertLessThanOrEqual(wide.frame.width, 44.001)
        XCTAssertEqual(wide.frame.height, 50, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(wide.frame.minY, visible.minY)
        let top = try XCTUnwrap(PetEdgeGeometry.peekLayout(
            anchor: CGPoint(x: visible.minX, y: 750), petSize: 70,
            contentSize: CGSize(width: 535, height: 1140), visible: visible, side: .left))
        XCTAssertLessThanOrEqual(top.frame.maxY, visible.maxY)
    }

    func testBubbleStackPlacesAboveAndFlipsBelowWithoutZeroHeight() throws {
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
        let pet = CGRect(x: 400, y: 350, width: 120, height: 120)
        let above = PetEdgeGeometry.bubbleStack(
            petFrame: pet, speechSize: CGSize(width: 292, height: 60),
            taskSize: CGSize(width: 292, height: 200), visible: visible)
        let speech = try XCTUnwrap(above.speechFrame)
        let task = try XCTUnwrap(above.taskFrame)
        XCTAssertFalse(above.below)
        XCTAssertGreaterThan(speech.minY, pet.maxY)
        XCTAssertGreaterThan(task.minY, speech.maxY)
        XCTAssertGreaterThanOrEqual(speech.minX, visible.minX + 8)
        XCTAssertLessThanOrEqual(task.maxX, visible.maxX - 8)

        let nearTop = CGRect(x: 400, y: 640, width: 120, height: 120)
        let below = PetEdgeGeometry.bubbleStack(
            petFrame: nearTop, speechSize: CGSize(width: 292, height: 60),
            taskSize: CGSize(width: 292, height: 200), visible: visible)
        XCTAssertTrue(below.below)
        XCTAssertLessThan(try XCTUnwrap(below.speechFrame).maxY, nearTop.minY)
        XCTAssertLessThan(try XCTUnwrap(below.taskFrame).maxY,
                          try XCTUnwrap(below.speechFrame).minY)
        XCTAssertGreaterThan(try XCTUnwrap(below.taskFrame).height, 0)
    }

    func testBubbleStackKeepsSpeechAndCapsTaskToAvailableHeight() throws {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 300)
        let pet = CGRect(x: 300, y: 120, width: 80, height: 80)
        let stack = PetEdgeGeometry.bubbleStack(
            petFrame: pet, speechSize: CGSize(width: 292, height: 60),
            taskSize: CGSize(width: 292, height: 500), visible: visible)
        let speech = try XCTUnwrap(stack.speechFrame)
        let task = try XCTUnwrap(stack.taskFrame)
        XCTAssertGreaterThan(speech.height, 0)
        XCTAssertGreaterThan(task.height, 0)
        XCTAssertGreaterThanOrEqual(speech.minY, visible.minY)
        XCTAssertLessThanOrEqual(task.maxY, visible.maxY)
        XCTAssertLessThanOrEqual(task.minY, speech.maxY)
    }

    func testRestorationKeepsOuterSideClampsAndRecoversNearestScreen() throws {
        let restored = try XCTUnwrap(PetEdgeGeometry.restoration(
            side: .left, anchor: CGPoint(x: 500, y: -100), petSize: 70,
            screens: [left, right]))
        XCTAssertEqual(restored.anchor.x, left.visibleFrame.minX)
        XCTAssertEqual(restored.anchor.y, left.visibleFrame.minY)
        XCTAssertEqual(restored.screenIndex, 0)

        let seam = PetEdgeGeometry.restoration(side: .right,
                                               anchor: CGPoint(x: 1000, y: 300),
                                               petSize: 70, screens: [left, right])
        XCTAssertNil(seam, "A side that is now a seam must restore as a normal pet")

        let removed = try XCTUnwrap(PetEdgeGeometry.restoration(
            side: .left, anchor: CGPoint(x: 1800, y: 300), petSize: 70,
            screens: [right]))
        XCTAssertEqual(removed.screenIndex, 0)
        XCTAssertEqual(removed.visibleFrame, right.visibleFrame)
    }
}
