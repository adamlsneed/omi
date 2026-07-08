import XCTest

@testable import Omi_Computer

@MainActor
final class AppProviderStateTests: XCTestCase {
    func testIsAppEnabledPrefersLiveProviderStateOverStaleValue() {
        let provider = AppProvider()
        provider.apps = [makeApp(id: "spotify", enabled: true)]
        let staleApp = makeApp(id: "spotify", enabled: false)

        XCTAssertTrue(provider.isAppEnabled(staleApp))
    }

    func testIsAppEnabledReadsCategoryFilteredState() {
        let provider = AppProvider()
        provider.filteredApps = [makeApp(id: "notes", enabled: true)]
        let staleApp = makeApp(id: "notes", enabled: false)

        XCTAssertTrue(provider.isAppEnabled(staleApp))
    }

    private func makeApp(id: String, enabled: Bool, capabilities: [String] = []) -> OmiApp {
        let capabilitiesData = try! JSONEncoder().encode(capabilities)
        let capabilitiesJSON = String(data: capabilitiesData, encoding: .utf8)!
        let json = """
        {
          "id": "\(id)",
          "name": "\(id)",
          "description": "",
          "image": "",
          "category": "other",
          "author": "Omi",
          "capabilities": \(capabilitiesJSON),
          "approved": true,
          "private": false,
          "installs": 0,
          "rating_count": 0,
          "is_paid": false,
          "enabled": \(enabled)
        }
        """
        return try! JSONDecoder().decode(OmiApp.self, from: Data(json.utf8))
    }
}
