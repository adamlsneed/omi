enum DesktopRecordingControlCopy {
  static let screenRecordingTitle = "Screen Recording"
  static let microphoneTitle = "Microphone"
}

enum IdeaCaptureSidebarAction: Equatable {
  case start
  case stop

  static func current(isActive: Bool) -> IdeaCaptureSidebarAction {
    isActive ? .stop : .start
  }

  var title: String {
    switch self {
    case .start:
      return "Capture Idea"
    case .stop:
      return "Stop Idea"
    }
  }

  var systemImage: String {
    switch self {
    case .start:
      return "lightbulb.fill"
    case .stop:
      return "stop.fill"
    }
  }

  var helpText: String {
    switch self {
    case .start:
      return "Start recording a focused idea"
    case .stop:
      return "Stop recording and save this idea"
    }
  }

  var accessibilityLabel: String { title }
}
