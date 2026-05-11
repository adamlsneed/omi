import XCTest
@testable import Omi_Computer

final class AppsPageFilterStateTests: XCTestCase {
    func testInstalledOnlyCountsAsActiveFilter() {
        let state = AppsPageFilterState(
            searchText: "",
            selectedCategory: nil,
            selectedCapability: nil,
            showInstalledOnly: true,
            viewAllSection: nil
        )

        XCTAssertTrue(state.hasActiveFilters)
        XCTAssertTrue(state.usesSearchBackedResults)
    }

    func testCapabilityCountsAsActiveSearchBackedFilter() {
        let state = AppsPageFilterState(
            searchText: "",
            selectedCategory: nil,
            selectedCapability: "external_integration",
            showInstalledOnly: false,
            viewAllSection: nil
        )

        XCTAssertTrue(state.hasActiveFilters)
        XCTAssertTrue(state.usesSearchBackedResults)
    }

    func testCategoryOnlyCanUseCategoryResults() {
        let state = AppsPageFilterState(
            searchText: "",
            selectedCategory: "productivity",
            selectedCapability: nil,
            showInstalledOnly: false,
            viewAllSection: nil
        )

        XCTAssertTrue(state.hasActiveFilters)
        XCTAssertFalse(state.usesSearchBackedResults)
    }

    func testSearchUsesSearchBackedResultsWithoutCountingAsAFilter() {
        let state = AppsPageFilterState(
            searchText: "notion",
            selectedCategory: nil,
            selectedCapability: nil,
            showInstalledOnly: false,
            viewAllSection: nil
        )

        XCTAssertFalse(state.hasActiveFilters)
        XCTAssertTrue(state.usesSearchBackedResults)
    }
}
