import XCTest
@testable import CourtsideCore

final class SmokeTests: XCTestCase {
  func testSeasonLabel() {
    XCTAssertEqual(NBA().season(on: NBA.date("2026-10-27")), "2026-27")
    XCTAssertEqual(NBA().season(on: NBA.date("2026-06-10")), "2025-26")
  }
}
