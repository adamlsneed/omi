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

  func testSettingsStatusDistinguishesSavedTokenFromVerifiedConnection() {
    let status = BrowserExtensionSetup.settingsStatus(
      enabled: true,
      token: "u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p-nP2QH0",
      verified: false
    )

    XCTAssertEqual(status.kind, .needsVerification)
    XCTAssertEqual(status.text, "Needs verification")
    XCTAssertTrue(status.detail.contains("token is saved"))
  }

  func testConnectionFailureGuidanceNamesMissingPrerequisite() {
    let guidance = BrowserExtensionSetup.connectionFailureGuidance(
      chromeInstalled: true,
      extensionInstalled: false,
      token: "u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p-nP2QH0"
    )

    XCTAssertEqual(guidance.title, "Extension is not installed")
    XCTAssertTrue(guidance.message.contains("Install the Playwright MCP Bridge extension"))
  }

  func testConnectionFailureGuidanceExplainsMcpClientStatusWhenLocalChecksPass() {
    let guidance = BrowserExtensionSetup.connectionFailureGuidance(
      chromeInstalled: true,
      extensionInstalled: true,
      token: "u0L1_VAMekk_3s9AgWW1jKMEs99jcgsiS0p-nP2QH0"
    )

    XCTAssertEqual(guidance.title, "No live browser connection")
    XCTAssertTrue(guidance.message.contains("MCP client"))
    XCTAssertTrue(guidance.message.contains("copy a fresh token"))
  }
}
