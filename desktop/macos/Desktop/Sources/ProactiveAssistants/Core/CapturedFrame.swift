import Foundation

enum CaptureTrigger: String, Codable, Equatable {
    case timer
    case startupImmediate = "startup_immediate"
    case contextSwitch = "context_switch"
    case manual
    case replay
}

enum CapturedTextSource: String, Codable, Equatable {
    case none
    case ocr
    case accessibility
    case hybrid
    case deferred
}

/// Represents a captured screen frame that can be analyzed by assistants
struct CapturedFrame {
    /// JPEG-encoded image data
    let jpegData: Data

    /// Name of the active application
    let appName: String

    /// Title of the active window (if available)
    let windowTitle: String?

    /// Sequential frame number for ordering
    let frameNumber: Int

    /// Timestamp when the frame was captured
    let captureTime: Date

    /// Optional reference to the screenshot in the Rewind database
    /// Used to link proactive extractions back to their source screenshot
    let screenshotId: Int64?

    /// Reason this frame was captured. Stored with Rewind screenshots so later
    /// prompts and diagnostics can distinguish timer captures from future event-driven captures.
    let captureTrigger: CaptureTrigger

    init(
        jpegData: Data,
        appName: String,
        windowTitle: String? = nil,
        frameNumber: Int,
        captureTime: Date = Date(),
        screenshotId: Int64? = nil,
        captureTrigger: CaptureTrigger = .timer
    ) {
        self.jpegData = jpegData
        self.appName = appName
        self.windowTitle = windowTitle
        self.frameNumber = frameNumber
        self.captureTime = captureTime
        self.screenshotId = screenshotId
        self.captureTrigger = captureTrigger
    }
}
