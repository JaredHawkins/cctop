import XCTest
@testable import CctopMenubar

final class NotchVisibilityTests: XCTestCase {

    func testIndicatorPlacementDefaultsBelowAndFallsBackFromInvalidValue() throws {
        let suiteName = "cctop-notch-placement-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(StatusIndicatorPlacement.current(defaults: defaults), .below)
        defaults.set("side", forKey: StatusIndicatorPlacement.defaultsKey)
        XCTAssertEqual(StatusIndicatorPlacement.current(defaults: defaults), .side)
        defaults.set("menu_bar", forKey: StatusIndicatorPlacement.defaultsKey)
        XCTAssertEqual(StatusIndicatorPlacement.current(defaults: defaults), .menuBar)
        defaults.set("elsewhere", forKey: StatusIndicatorPlacement.defaultsKey)
        XCTAssertEqual(StatusIndicatorPlacement.current(defaults: defaults), .below)
    }

    func testIndicatorPlacementMapsOnlyNotchChoicesToPillGeometry() {
        XCTAssertEqual(StatusIndicatorPlacement.side.notchPlacement, .side)
        XCTAssertEqual(StatusIndicatorPlacement.below.notchPlacement, .below)
        XCTAssertNil(StatusIndicatorPlacement.menuBar.notchPlacement)
    }

    func testBelowPlacementCentersPillImmediatelyUnderNotch() {
        let frame = NotchStatusController.pillFrame(
            screenFrame: NSRect(x: 100, y: 50, width: 1_000, height: 700),
            notchSize: CGSize(width: 200, height: 32),
            placement: .below
        )

        XCTAssertEqual(frame, NSRect(x: 574, y: 698, width: 52, height: 20))
    }

    func testSidePlacementPreservesExistingLeftShoulderFrame() {
        let frame = NotchStatusController.pillFrame(
            screenFrame: NSRect(x: 100, y: 50, width: 1_000, height: 700),
            notchSize: CGSize(width: 200, height: 32),
            placement: .side
        )

        XCTAssertEqual(frame, NSRect(x: 457, y: 730, width: 52, height: 20))
    }

    // MARK: - No notch or no built-in screen → tearDown

    func testNoNotchTearDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: false, hasBuiltinScreen: true,
            appIsActive: false, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .tearDown)
    }

    func testNoBuiltinScreenTearDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: false,
            appIsActive: false, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .tearDown)
    }

    // MARK: - Normal (app not active) — occlusion drives show/tearDown

    func testOccludedShowsPill() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: false, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .show)
    }

    func testNotOccludedTearsDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: false, pillExists: true, statusItemOccluded: false
        )
        XCTAssertEqual(action, .tearDown)
    }

    func testNotOccludedNoPillTearsDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: false, pillExists: false, statusItemOccluded: false
        )
        XCTAssertEqual(action, .tearDown)
    }

    // MARK: - App active with existing pill → keep (the fix)

    func testActiveWithPillKeeps() {
        // Core fix: don't tear down the pill while cctop is active.
        // The menubar is minimal and isStatusItemOccluded is unreliable.
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: true, statusItemOccluded: false
        )
        XCTAssertEqual(action, .keep)
    }

    func testActiveWithPillKeepsEvenIfOccluded() {
        // Active + pill exists → always keep, regardless of occlusion
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: true, statusItemOccluded: true
        )
        XCTAssertEqual(action, .keep)
    }

    // MARK: - App active without existing pill → do not create

    func testActiveNoPillOccludedTearsDown() {
        // Occlusion measurements can be transient while cctop is active.
        // Do not create a new pill until the app is inactive.
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .tearDown)
    }

    func testActiveNoPillNotOccludedTearsDown() {
        // No pill and not occluded → don't create one
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: false, statusItemOccluded: false
        )
        XCTAssertEqual(action, .tearDown)
    }
}
