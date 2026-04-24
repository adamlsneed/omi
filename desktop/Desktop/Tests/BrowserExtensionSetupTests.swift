import XCTest

@testable import Omi_Computer

final class BrowserExtensionSetupTests: XCTestCase {
  func testParseTokenAcceptsFullEnvAssignment() {
    let parsed = BrowserExtensionSetup.parseToken(
      "PLAYWRIGHT_MCP_EXTENSION_TOKEN=u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p-nP2QH0")

    XCTAssertEqual(parsed, "u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p-nP2QH0")
    XCTAssertNil(BrowserExtensionSetup.validateToken(parsed))
  }

  func testParseTokenRemovesCopiedLineWrapping() {
    let parsed = BrowserExtensionSetup.parseToken(
      """
      PLAYWRIGHT_MCP_EXTENSION_TOKEN=u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p
      -nP2QH0
      """)

    XCTAssertEqual(parsed, "u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p-nP2QH0")
    XCTAssertNil(BrowserExtensionSetup.validateToken(parsed))
  }
}
