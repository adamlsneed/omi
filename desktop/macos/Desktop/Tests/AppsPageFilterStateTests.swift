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

  func testInstalledCategoryUsesSearchBackedResults() {
    let state = AppsPageFilterState(
      searchText: "",
      selectedCategory: "productivity",
      selectedCapability: nil,
      showInstalledOnly: true,
      viewAllSection: nil
    )

    XCTAssertTrue(state.hasActiveFilters)
    XCTAssertTrue(state.usesSearchBackedResults)
  }
}
