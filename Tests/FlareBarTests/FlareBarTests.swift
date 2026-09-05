import XCTest
@testable import FlareBarCore

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
    func testAIUsageAndDailyAllowance() throws {
        let bar = try CloudflareClient.aiBar(aiResponse([
            ["sum": ["totalNeurons": 7_999.5]],
            ["sum": ["totalNeurons": 0.5]],
        ]))
        XCTAssertEqual(bar.used, 8_000)
        XCTAssertEqual(bar.limit, 10_000)
        XCTAssertEqual(bar.percent, 80)
        XCTAssertEqual(bar.unit, "neurons/day")
        XCTAssertEqual(bar.resetDescription, "Resets 00:00 UTC")
    }

    func testAIEmptyIsZeroButMalformedIsUnavailable() throws {
        XCTAssertEqual(try CloudflareClient.aiBar(aiResponse([])).used, 0)
        XCTAssertThrowsError(try CloudflareClient.aiBar([:]))
        XCTAssertThrowsError(try CloudflareClient.aiBar(aiResponse([["sum": [:]]])))
        XCTAssertThrowsError(try CloudflareClient.aiBar(aiResponse([["sum": ["totalNeurons": NSNull()]]])))
        XCTAssertThrowsError(try CloudflareClient.aiBar(aiResponse([["sum": ["totalNeurons": -1]]])))
    }

    func testAIOveragePreservesUsage() throws {
        let bar = try CloudflareClient.aiBar(aiResponse([["sum": ["totalNeurons": 12_500]]]))
        XCTAssertEqual(bar.used, 12_500)
        XCTAssertEqual(bar.percent, 100)
    }

    func testAIUsesUTCDayAcrossMonthBoundary() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:30:00Z"))
        let query = CloudflareClient.aiQuery(accountTag: "account", date: CloudflareClient.utcDate(instant))
        XCTAssertTrue(query.contains("2026-10-01T00:00:00Z"))
        XCTAssertTrue(query.contains("2026-10-01T23:59:59Z"))
    }

    func testOldSnapshotStillDecodes() throws {
        let json = #"{"plan":"paid","accountName":"Test","accountTag":"account","bars":[{"id":"workers","title":"Workers","used":1,"limit":10000000,"unit":"req/mo","sampled":false}],"fetchedAt":0,"resetDescription":"Resets next month"}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.aiError)
        XCTAssertNil(snapshot.bars.first?.resetDescription)
        XCTAssertEqual(snapshot.bars.count, 1)
    }

    private func aiResponse(_ rows: [[String: Any]]) -> [String: Any] {
        ["data": ["viewer": ["accounts": [["aiInferenceAdaptiveGroups": rows]]]]]
    }

}
