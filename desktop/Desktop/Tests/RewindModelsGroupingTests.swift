import XCTest
@testable import Omi_Computer

final class RewindModelsGroupingTests: XCTestCase {
    func testGroupedByContextReturnsEmptyForEmptyResults() {
        let results: [Screenshot] = []
        XCTAssertTrue(results.groupedByContext().isEmpty)
    }

    func testGroupedByContextKeepsSameContextWithinWindowTogether() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let screenshots = [
            makeScreenshot(id: 1, timestamp: base, appName: "Safari", windowTitle: "Docs"),
            makeScreenshot(id: 2, timestamp: base.addingTimeInterval(10), appName: "Safari", windowTitle: "Docs"),
        ]

        let groups = screenshots.groupedByContext(timeWindowSeconds: 30)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.first?.appName, "Safari")
        XCTAssertEqual(groups.first?.windowTitle, "Docs")
    }

    func testGroupedByContextSplitsSameContextOutsideWindow() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let screenshots = [
            makeScreenshot(id: 1, timestamp: base, appName: "Xcode", windowTitle: "Project"),
            makeScreenshot(id: 2, timestamp: base.addingTimeInterval(90), appName: "Xcode", windowTitle: "Project"),
        ]

        let groups = screenshots.groupedByContext(timeWindowSeconds: 30)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.count), [1, 1])
    }

    private func makeScreenshot(
        id: Int64,
        timestamp: Date,
        appName: String,
        windowTitle: String?
    ) -> Screenshot {
        Screenshot(
            id: id,
            timestamp: timestamp,
            appName: appName,
            windowTitle: windowTitle,
            isIndexed: true
        )
    }
}
