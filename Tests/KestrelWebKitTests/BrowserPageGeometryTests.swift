import XCTest
@testable import KestrelWebKit

final class BrowserPageGeometryTests: XCTestCase {
    func testFractionalPageCoversTheToolbarJoinAtBothDisplayScales() {
        let host = CGRect(x: 100.23, y: -30.61, width: 800.3, height: 600.2)
        for scale in [CGFloat(1), 2] {
            let result = BrowserPageGeometry.coveringFrame(host, scale: scale)
            XCTAssertLessThanOrEqual(result.minX, host.minX)
            XCTAssertLessThanOrEqual(result.minY, host.minY)
            XCTAssertGreaterThanOrEqual(result.maxX, host.maxX)
            XCTAssertGreaterThanOrEqual(result.maxY, host.maxY)
            XCTAssertEqual(result.maxY * scale, (result.maxY * scale).rounded())
            XCTAssertLessThan(result.maxY - host.maxY, 1 / scale)
        }
    }
    func testIntegralFramesDoNotAddAnInsetOrBorder() {
        let host = CGRect(x: 10, y: 20, width: 700, height: 400)
        XCTAssertEqual(BrowserPageGeometry.coveringFrame(host, scale: 2), host)
    }
}
