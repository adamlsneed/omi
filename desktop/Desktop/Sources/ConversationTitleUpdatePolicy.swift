import Foundation

enum ConversationTitleUpdatePolicy {
  static func updatedConversation(_ conversation: ServerConversation, title: String) -> ServerConversation {
    var updated = conversation
    updated.structured.title = title
    return updated
  }
}
