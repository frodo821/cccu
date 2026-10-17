import XCTest
@testable import CCCUHelperCore

/// フィッツの法則によるポインタ移動のモデル (CGEvent には触れない)
final class PointerTests: XCTestCase {
    func testDurationGrowsWithDistanceAndShrinksWithWidth() {
        let near = Fitts.duration(distance: 50, targetWidth: 40)
        let far = Fitts.duration(distance: 800, targetWidth: 40)
        let wide = Fitts.duration(distance: 800, targetWidth: 300)
        XCTAssertLessThan(near, far)
        XCTAssertLessThan(wide, far)
        XCTAssertGreaterThanOrEqual(Fitts.duration(distance: 1, targetWidth: 500), 0.08)   // 下限
        XCTAssertLessThanOrEqual(Fitts.duration(distance: 5000, targetWidth: 1), 0.6)      // 上限
    }

    func testMinimumJerkIsMonotoneAndBounded() {
        var last = -1.0
        for i in 0...20 {
            let v = Fitts.minimumJerk(Double(i) / 20)
            XCTAssertGreaterThanOrEqual(v, last); last = v
        }
        XCTAssertEqual(Fitts.minimumJerk(0), 0); XCTAssertEqual(Fitts.minimumJerk(1), 1, accuracy: 1e-9)
    }

    func testPathStartsAndEndsExactlyWithMonotoneTime() {
        var rng = SystemRandomNumberGenerator()
        let from = CGPoint(x: 100, y: 100), to = CGPoint(x: 700, y: 420)
        let path = Fitts.path(from: from, to: to, duration: 0.4, rng: &rng)
        XCTAssertGreaterThan(path.count, 20)
        XCTAssertEqual(path.first!.0, from); XCTAssertEqual(path.last!.0, to)
        XCTAssertEqual(path.last!.1, 0.4, accuracy: 1e-9)
        for i in 1..<path.count { XCTAssertGreaterThan(path[i].1, path[i - 1].1) }
        // 軌跡は直線から少し外れるが、大きくは逸れない
        let maxDeviation = path.map { p -> CGFloat in
            let dx = to.x - from.x, dy = to.y - from.y
            return abs((p.0.x - from.x) * dy - (p.0.y - from.y) * dx) / hypot(dx, dy)
        }.max()!
        XCTAssertGreaterThan(maxDeviation, 1); XCTAssertLessThan(maxDeviation, 60)
        XCTAssertEqual(Fitts.path(from: from, to: from, duration: 0.3, rng: &rng).count, 1)   // 移動なし
    }

    func testLandingStaysInsideTarget() {
        var rng = SystemRandomNumberGenerator()
        let c = CGPoint(x: 200, y: 300)
        for _ in 0..<50 {
            let p = Fitts.landing(center: c, size: CGSize(width: 100, height: 40), rng: &rng)
            XCTAssertLessThanOrEqual(abs(p.x - c.x), 15); XCTAssertLessThanOrEqual(abs(p.y - c.y), 6)
        }
        XCTAssertEqual(Fitts.landing(center: c, size: CGSize(width: 4, height: 4), rng: &rng), c)   // 極小は中心
        XCTAssertEqual(Fitts.landing(center: c, size: nil, rng: &rng), c)
    }

    func testScrollStepsSumAndDecelerate() {
        for total in [-500, -37, 24, 300, 2000] {
            let steps = Fitts.scrollSteps(total: total)
            XCTAssertEqual(steps.reduce(0, +), total)
            XCTAssertTrue(steps.allSatisfy { ($0 > 0) == (total > 0) })
            XCTAssertLessThanOrEqual(steps.count, 28)
            if steps.count > 3 { XCTAssertGreaterThanOrEqual(abs(steps[0]), abs(steps.last!)) }   // 減速
        }
        XCTAssertEqual(Fitts.scrollSteps(total: 0), [])
    }

    func testPointerModeParsing() {
        XCTAssertEqual(PointerMode(rawValue: "human"), .human)
        XCTAssertEqual(PointerMode(rawValue: "warp"), .warp)
        XCTAssertNil(PointerMode(rawValue: "teleport"))
    }
}
