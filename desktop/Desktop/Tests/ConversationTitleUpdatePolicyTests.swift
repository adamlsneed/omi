import XCTest
@testable import Omi_Computer

final class ConversationTitleUpdatePolicyTests: XCTestCase {
  func testUpdatedConversationChangesStructuredTitleOnly() {
    let original = ServerConversation(
      id: "conversation-1",
      createdAt: Date(timeIntervalSince1970: 10),
      startedAt: Date(timeIntervalSince1970: 20),
      finishedAt: Date(timeIntervalSince1970: 80),
      structured: Structured(
        title: "Old title",
        overview: "Overview",
        emoji: "chat",
        category: "work",
        actionItems: [],
        events: []
      ),
      transcriptSegments: [],
      geolocation: nil,
      photos: [],
      appsResults: [],
      source: .desktop,
      language: "en",
      status: .completed,
      discarded: false,
      deleted: false,
      isLocked: false,
      starred: true,
      folderId: "folder-1",
      inputDeviceName: "Mac"
    )

    let updated = ConversationTitleUpdatePolicy.updatedConversation(original, title: "New title")

    XCTAssertEqual(updated.id, original.id)
    XCTAssertEqual(updated.title, "New title")
    XCTAssertEqual(updated.structured.overview, original.structured.overview)
    XCTAssertEqual(updated.starred, original.starred)
    XCTAssertEqual(updated.folderId, original.folderId)
  }
}
