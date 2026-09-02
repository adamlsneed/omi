import XCTest

@testable import Omi_Computer

/// The push-to-talk chord reveals a hidden bar for the session only: neither the
/// reveal nor the end-of-session hide may write the "Show floating bar" preference.
@MainActor
final class PushToTalkBarRevealTests: XCTestCase {
  private let enabledKey = "askOmiBarEnabled"
  private var savedValue: Any?

  override func setUp() async throws {
    savedValue = UserDefaults.standard.object(forKey: enabledKey)
  }

  override func tearDown() async throws {
    if let savedValue {
      UserDefaults.standard.set(savedValue, forKey: enabledKey)
    } else {
      UserDefaults.standard.removeObject(forKey: enabledKey)
    }
  }

  func testShortcutRevealDoesNotPersistEnablePreference() {
    let manager = FloatingControlBarManager.shared
    manager.isEnabled = false
    manager.hideTemporarily()

    PushToTalkManager.shared.revealBarForShortcutPress()

    XCTAssertFalse(manager.isEnabled, "the chord must not turn the bar preference back on")
  }

  func testEndOfSessionHideDoesNotPersistEnablePreference() {
    let manager = FloatingControlBarManager.shared
    manager.isEnabled = true

    PushToTalkManager.shared.hideBarIfDisabledAfterSession(reason: .silentRejected)

    XCTAssertTrue(manager.isEnabled, "a transient hide must not turn the bar preference off")
  }

  func testOnlySilentSessionsOnADisabledBarHideIt() {
    XCTAssertTrue(
      PushToTalkManager.shouldHideBarAfterSession(
        reason: .silentRejected, barEnabled: false, showingAIConversation: false, showingNotification: false))
    XCTAssertTrue(
      PushToTalkManager.shouldHideBarAfterSession(
        reason: .tooShort, barEnabled: false, showingAIConversation: false, showingNotification: false))
    XCTAssertFalse(
      PushToTalkManager.shouldHideBarAfterSession(
        reason: .success, barEnabled: false, showingAIConversation: false, showingNotification: false),
      "a session that opened a conversation is re-hidden by the conversation close path")
    XCTAssertFalse(
      PushToTalkManager.shouldHideBarAfterSession(
        reason: .silentRejected, barEnabled: true, showingAIConversation: false, showingNotification: false),
      "users who keep the bar on must not lose it")
    XCTAssertFalse(
      PushToTalkManager.shouldHideBarAfterSession(
        reason: .silentRejected, barEnabled: false, showingAIConversation: true, showingNotification: false))
    XCTAssertFalse(
      PushToTalkManager.shouldHideBarAfterSession(
        reason: .silentRejected, barEnabled: false, showingAIConversation: false, showingNotification: true))
  }
}
