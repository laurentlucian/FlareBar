import XCTest
import FlareBarCore

final class FlareBarTests: XCTestCase {
    func testFreePercent() {
        let bars = Limits.bars(plan: .free, workersRequests: 80_000, cpuMs: 0, kvReads: 0, d1Read: 0, d1Write: 0, doRequests: 0, sampled: false)
        XCTAssertEqual(bars.first { $0.id == "workers" }?.percent ?? 0, 80, accuracy: 0.01)
    }

    func testPaidWorkersCap() {
        let bars = Limits.bars(plan: .paid, workersRequests: 5_000_000, cpuMs: 15_000_000, kvReads: 0, d1Read: 0, d1Write: 0, doRequests: 0, sampled: false)
        XCTAssertEqual(bars.first { $0.id == "workers" }?.limit, 10_000_000)
        XCTAssertEqual(bars.first { $0.id == "cpu" }?.percent ?? 0, 50, accuracy: 0.01)
    }

    func testClamp() {
        let bars = Limits.bars(plan: .free, workersRequests: 200_000, cpuMs: 0, kvReads: 0, d1Read: 0, d1Write: 0, doRequests: 0, sampled: false)
        XCTAssertEqual(bars.first?.percent, 100)
    }

    func testMonthStart() {
        XCTAssertTrue(CloudflareClient.monthStartUTC().hasSuffix("-01"))
        XCTAssertEqual(CloudflareClient.utcDate().count, 10)
    }
}
