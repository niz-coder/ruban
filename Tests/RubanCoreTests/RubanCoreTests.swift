import CoreGraphics
import XCTest
@testable import RubanCore

final class StripTests: XCTestCase {
    func strip(_ ids: [WindowID], width: Double = 0.5) -> Strip {
        var s = Strip()
        for id in ids { s.insert(id, width: width, after: s.columns.isEmpty ? nil : s.columns.count - 1) }
        return s
    }

    func testInsertGoesRightOfFocused() {
        var s = strip([1, 2, 3])
        s.focused = 0
        let at = s.insert(9, width: 0.5, after: s.focused)
        XCTAssertEqual(at, 1)
        XCTAssertEqual(s.columns.map { $0.windows[0] }, [1, 9, 2, 3])
        XCTAssertEqual(s.focused, 0, "a new window must not steal the focus index")
    }

    func testRemoveFocusedMovesFocusLeft() {
        var s = strip([1, 2, 3])
        s.focused = 2
        s.remove(3)
        XCTAssertEqual(s.focused, 1)
        s.focused = 0
        s.remove(1)
        XCTAssertEqual(s.focused, 0)
        XCTAssertEqual(s.columns.map { $0.windows[0] }, [2])
    }

    func testNavigationSkipsAbsentColumns() {
        var s = strip([1, 2, 3])
        s.focused = 0
        XCTAssertTrue(s.focusNeighbor(1, present: [1, 3]))
        XCTAssertEqual(s.focused, 2)
        XCTAssertFalse(s.focusNeighbor(1, present: [1, 3]))
        XCTAssertTrue(s.focusNumber(2, present: [1, 3]))
        XCTAssertEqual(s.focused, 2)
    }

    func testStackAndPopOut() {
        var s = strip([1, 2, 3])
        s.focused = 1
        XCTAssertTrue(s.stackIntoNeighbor(-1, present: [1, 2, 3]))
        XCTAssertEqual(s.columns.map(\.windows), [[1, 2], [3]])
        XCTAssertEqual(s.focused, 0)
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertTrue(s.popOut(1))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertFalse(s.popOut(1), "a lone window has no stack to leave")
    }

    func testCycleWidthAndFull() {
        var s = strip([1])
        XCTAssertTrue(s.cycleWidth(presets: [1.0 / 3, 0.5, 2.0 / 3]))
        XCTAssertEqual(s.columns[0].width, 2.0 / 3, accuracy: 0.001)
        XCTAssertTrue(s.cycleWidth(presets: [1.0 / 3, 0.5, 2.0 / 3]))
        XCTAssertEqual(s.columns[0].width, 1.0 / 3, accuracy: 0.001)
        XCTAssertTrue(s.toggleFullWidth())
        XCTAssertEqual(s.columns[0].width, 1)
        XCTAssertTrue(s.toggleFullWidth())
        XCTAssertEqual(s.columns[0].width, 1.0 / 3, accuracy: 0.001)
    }

    func testPinMovesColumnToEdgeAndInsertKeepsItThere() {
        var s = strip([1, 2, 3])
        s.focused = 2
        XCTAssertTrue(s.togglePin(.left))
        XCTAssertEqual(s.columns.map { $0.windows[0] }, [3, 1, 2])
        XCTAssertEqual(s.focused, 0)
        s.insert(7, width: 0.5, after: nil)
        s.focused = 0
        let at = s.insert(8, width: 0.5, after: -1)
        XCTAssertEqual(at, 1, "nothing slides in front of a left-pinned column")
        XCTAssertTrue(s.togglePin(.left))
        XCTAssertNil(s.columns[0].pinned)
    }

    func testReplaceKeepsSlot() {
        var s = strip([1, 2, 3])
        s.replace(2, with: 20)
        XCTAssertEqual(s.columns.map { $0.windows[0] }, [1, 20, 3])
    }
}

final class LayoutTests: XCTestCase {
    // A 1470 x 956 MacBook screen: 33 pt menu bar, 58 pt Dock.
    let params = LayoutParams(
        area: CGRect(x: 0, y: 33, width: 1470, height: 865),
        screen: CGRect(x: 0, y: 0, width: 1470, height: 956),
        gap: 8, centre: .never
    )

    func strip(_ n: Int, width: Double = 0.5) -> Strip {
        var s = Strip()
        for id in 1...n { s.insert(WindowID(id), width: width, after: s.columns.isEmpty ? nil : s.columns.count - 1) }
        return s
    }

    func testTwoHalvesFillTheScreen() {
        let s = strip(2)
        let present: Set<WindowID> = [1, 2]
        let g = Layout.geometry(s, present: present, params)
        let f = Layout.frames(s, present: present, params, geometry: g, scroll: 0)
        XCTAssertEqual(f[1]!.minX, 8)
        XCTAssertEqual(f[2]!.maxX, 1462, accuracy: 1)
        XCTAssertEqual(f[2]!.minX - f[1]!.maxX, 8, accuracy: 1)
        XCTAssertEqual(f[1]!.minY, 41)
        XCTAssertEqual(f[1]!.height, 849)
        XCTAssertEqual(g.maxScroll, 0, accuracy: 1)
    }

    func testRevealScrollsJustEnough() {
        var s = strip(4)
        let present: Set<WindowID> = [1, 2, 3, 4]
        let g = Layout.geometry(s, present: present, params)
        s.focused = 2
        let scroll = Layout.revealScroll(g, focused: 2, current: 0, mode: .never)
        let span = g.span(of: 2)!
        XCTAssertEqual(scroll, span.x + span.width - g.scrollWidth, accuracy: 0.5, "the third column lands flush with the right edge")
        XCTAssertEqual(Layout.revealScroll(g, focused: 1, current: scroll, mode: .never), scroll, "already visible: no scroll")
        XCTAssertEqual(Layout.revealScroll(g, focused: 0, current: scroll, mode: .never), 0)
    }

    func testOnOverflowCentresOnlyWhenNeeded() {
        let two = strip(2)
        let g2 = Layout.geometry(two, present: [1, 2], params)
        XCTAssertEqual(Layout.revealScroll(g2, focused: 1, current: 0, mode: .onOverflow), 0)
        let four = strip(4)
        let g4 = Layout.geometry(four, present: [1, 2, 3, 4], params)
        let s = Layout.revealScroll(g4, focused: 2, current: 0, mode: .onOverflow)
        let span = g4.span(of: 2)!
        XCTAssertEqual(s + g4.scrollWidth / 2, span.x + span.width / 2, accuracy: 1)
    }

    func testStackSplitsHeight() {
        var s = strip(2)
        s.focused = 1
        _ = s.stackIntoNeighbor(-1, present: [1, 2])
        let g = Layout.geometry(s, present: [1, 2], params)
        let f = Layout.frames(s, present: [1, 2], params, geometry: g, scroll: 0)
        XCTAssertEqual(f[1]!.minX, f[2]!.minX)
        XCTAssertEqual(f[2]!.minY - f[1]!.maxY, 8, accuracy: 1)
        XCTAssertEqual(f[2]!.maxY, 890)
    }

    func testTabbedColumnSharesOneFrame() {
        var s = strip(2)
        s.focused = 1
        _ = s.stackIntoNeighbor(-1, present: [1, 2])
        _ = s.toggleTabbed()
        let g = Layout.geometry(s, present: [1, 2], params)
        let f = Layout.frames(s, present: [1, 2], params, geometry: g, scroll: 0)
        XCTAssertEqual(f[1], f[2])
    }

    func testPinnedColumnStaysPutWhileTheRestScrolls() {
        var s = strip(4, width: 1.0 / 3)
        s.focused = 0
        _ = s.togglePin(.left)
        let present: Set<WindowID> = [1, 2, 3, 4]
        let g = Layout.geometry(s, present: present, params)
        XCTAssertNotNil(g.pinned[0])
        XCTAssertEqual(g.spans.count, 3)
        let a = Layout.frames(s, present: present, params, geometry: g, scroll: 0)
        let b = Layout.frames(s, present: present, params, geometry: g, scroll: 300)
        XCTAssertEqual(a[1], b[1])
        XCTAssertNotEqual(a[2], b[2])
        XCTAssertGreaterThanOrEqual(a[2]!.minX, a[1]!.maxX + 8)
    }

    func testParkingLeavesASliver() {
        let region = CGRect(x: 0, y: 33, width: 1470, height: 865)
        let off = CGRect(x: -900, y: 41, width: 700, height: 849)
        XCTAssertEqual(Layout.park(off, region: region, screen: params.screen).minX, -699)
        let right = CGRect(x: 1600, y: 41, width: 700, height: 849)
        XCTAssertEqual(Layout.park(right, region: region, screen: params.screen).minX, 1469)
        let partly = CGRect(x: 1200, y: 41, width: 700, height: 849)
        XCTAssertEqual(Layout.park(partly, region: region, screen: params.screen), partly)
    }

    func testSnapPicksNearestColumn() {
        let s = strip(4)
        let g = Layout.geometry(s, present: [1, 2, 3, 4], params)
        let span1 = g.span(of: 1)!
        let snapped = Layout.snap(g, scroll: span1.x - 50, focused: 0, mode: .never)!
        XCTAssertEqual(snapped.scroll, span1.x, accuracy: 0.5)
        XCTAssertEqual(snapped.focused, 1)
    }

    func testFractionRoundTrip() {
        let inner = params.inner.width
        let w = Layout.pixelWidth(0.5, inner: inner, gap: 8)
        XCTAssertEqual(Layout.fraction(forWidth: w, inner: inner, gap: 8), 0.5, accuracy: 0.002)
    }
}

final class SwipeTrackerTests: XCTestCase {
    /// Three fingers side by side around a centre point.
    func three(_ x: Double, _ y: Double = 0.5) -> [(x: Double, y: Double)] {
        [(x - 0.05, y), (x, y + 0.02), (x + 0.05, y)]
    }

    func testSidewaysSwipeFollowsFingersThenEndsWithVelocity() {
        var t = SwipeTracker(fingers: 3)
        XCTAssertEqual(t.update(three(0.6), time: 0), [])
        XCTAssertEqual(t.update(three(0.59), time: 0.01), [], "below the threshold nothing happens yet")
        let start = t.update(three(0.57), time: 0.02)
        XCTAssertEqual(start.first, .began)
        guard case let .moved(catchUp) = start.last else { return XCTFail("expected a move") }
        XCTAssertEqual(catchUp, -0.03, accuracy: 1e-9)
        guard case let .moved(step) = t.update(three(0.52), time: 0.03).first else { return XCTFail("expected a move") }
        XCTAssertEqual(step, -0.05, accuracy: 1e-9)
        _ = t.update(three(0.47), time: 0.04)
        guard case let .ended(v) = t.update([], time: 0.05).first else { return XCTFail("expected the end") }
        XCTAssertLessThan(v, -3, "a quick leftward flick has a strong negative velocity")
        XCTAssertFalse(t.isActive)
    }

    func testVerticalSwipeIsLeftToMissionControl() {
        var t = SwipeTracker(fingers: 3)
        _ = t.update(three(0.5, 0.5), time: 0)
        XCTAssertEqual(t.update(three(0.505, 0.6), time: 0.02), [])
        XCTAssertEqual(t.update(three(0.7, 0.6), time: 0.04), [], "once vertical, sideways motion is ignored")
        _ = t.update([], time: 0.05)
        _ = t.update(three(0.5), time: 0.1)
        XCTAssertEqual(t.update(three(0.45), time: 0.12).first, .began, "a fresh gesture after lifting works again")
    }

    func testOtherFingerCountsAreIgnored() {
        var t = SwipeTracker(fingers: 3)
        let two: [(x: Double, y: Double)] = [(0.5, 0.5), (0.55, 0.5)]
        _ = t.update(two, time: 0)
        XCTAssertEqual(t.update([(0.3, 0.5), (0.35, 0.5)], time: 0.02), [], "two-finger scrolling stays with the app")
        var four = SwipeTracker(fingers: 4)
        _ = four.update(three(0.5), time: 0)
        XCTAssertEqual(four.update(three(0.3), time: 0.02), [])
    }

    func testAddingAFingerMidSwipeEndsIt() {
        var t = SwipeTracker(fingers: 3)
        _ = t.update(three(0.6), time: 0)
        _ = t.update(three(0.5), time: 0.02)
        XCTAssertTrue(t.isActive)
        guard case .ended = t.update(three(0.45) + [(0.9, 0.5)], time: 0.04).first else { return XCTFail("expected the end") }
        XCTAssertEqual(t.update(three(0.3), time: 0.06), [], "blocked until every finger lifts")
    }
}
