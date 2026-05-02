import AppKit
import Foundation

struct DockIconVisibilitySettings {
  static let hideDockIconKey = "hideDockIcon"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var hidesDockIcon: Bool {
    get { defaults.bool(forKey: Self.hideDockIconKey) }
    set { defaults.set(newValue, forKey: Self.hideDockIconKey) }
  }

  static func activationPolicy(hidesDockIcon: Bool) -> NSApplication.ActivationPolicy {
    hidesDockIcon ? .accessory : .regular
  }
}

extension Notification.Name {
  static let dockIconVisibilityPreferenceDidChange = Notification.Name(
    "dockIconVisibilityPreferenceDidChange")
}
