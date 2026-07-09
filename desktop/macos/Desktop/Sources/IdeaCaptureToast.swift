import AppKit
import SwiftUI

/// idea-capture: a small, self-dismissing toast shown for capture confirmations.
///
/// App-drawn rather than a system notification, so it is reliably visible regardless
/// of the user's Focus/Do-Not-Disturb state, notification permissions, or which
/// display/Space is active — the failure modes that made the NotificationService
/// banner (and the floating-bar preview) effectively invisible for a menu-bar action.
@MainActor
final class IdeaCaptureToast {
  static let shared = IdeaCaptureToast()
  private init() {}

  private var panel: NSPanel?
  private var dismissWork: DispatchWorkItem?
  private var onTap: (@MainActor () -> Void)?

  /// idea-capture: click detection for the "tap to open" toast. The panel is borderless,
  /// non-activating, and usually shown while another app is frontmost, so AppKit does not
  /// route a click's mouseDown into it (the click lands on the panel but is never
  /// delivered to a view, no matter the acceptsFirstMouse / canBecomeKey flags). Detect
  /// the tap by location with event monitors instead, which fire regardless of key state.
  private var clickMonitors: [Any] = []

  /// Show a toast top-center on the active display. `onTap`, when set, runs if the
  /// user clicks the toast (and dismisses it) — used to jump to the Ideas folder.
  /// Fixed window size — avoids any auto-sizing path. Letting AppKit resize a
  /// borderless panel to SwiftUI's content (via fittingSize or .preferredContentSize)
  /// triggers a constraint feedback loop that recurses until the stack overflows.
  private static let toastSize = NSSize(width: 384, height: 104)

  /// Transparent inset baked into the toast content (see ToastView) so the drop shadow has
  /// room inside the borderless window. The visible card is the panel bounds inset by this
  /// on every side.
  nonisolated static let shadowPadding: CGFloat = 14

  /// Region that counts as a tap on the visible card: the panel frame minus the transparent
  /// shadow margin. Using the raw panel frame would treat clicks in the invisible margin
  /// around the card as taps.
  nonisolated static func tapHitRect(panelFrame: NSRect) -> NSRect {
    panelFrame.insetBy(dx: shadowPadding, dy: shadowPadding)
  }

  /// Show a toast. `autoDismiss == false` keeps it up until the next `show`/`dismiss`
  /// (used for the "Capturing…" progress state while the network call is in flight).
  func show(
    symbol: String, title: String, message: String,
    autoDismiss: Bool = true, onTap: (@MainActor () -> Void)? = nil
  ) {
    self.onTap = onTap

    let content = ToastView(
      symbol: symbol, title: title, message: message, tappable: onTap != nil)
    let hosting = NSHostingView(rootView: content)
    hosting.sizingOptions = []  // never impose content-size constraints on the window
    hosting.translatesAutoresizingMaskIntoConstraints = true
    hosting.frame = NSRect(origin: .zero, size: Self.toastSize)

    let panel = self.panel ?? makePanel()
    self.panel = panel
    panel.ignoresMouseEvents = (onTap == nil)
    panel.setContentSize(Self.toastSize)
    panel.contentView = hosting

    let screen = screenForCursor()
    let vf = screen.visibleFrame
    panel.setFrameOrigin(
      NSPoint(x: vf.midX - Self.toastSize.width / 2, y: vf.maxY - Self.toastSize.height - 8))
    let screenIdx = NSScreen.screens.firstIndex(of: screen) ?? -1
    log(
      "IdeaCaptureToast: showing '\(title)' on screen #\(screenIdx) \(screen.frame) at \(panel.frame.origin)"
    )
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      panel.animator().alphaValue = 1
    }

    if onTap != nil {
      installClickMonitors()
    } else {
      removeClickMonitors()
    }

    dismissWork?.cancel()
    guard autoDismiss else { return }
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    dismissWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
  }

  /// idea-capture: watch for a left click on the toast. The global monitor catches clicks
  /// while another app is frontmost; the local one while this app is. A click inside the
  /// toast frame triggers onTap; anything else is ignored.
  private func installClickMonitors() {
    removeClickMonitors()
    let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleMonitorClick() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
      MainActor.assumeIsolated { self?.handleMonitorClick() }
      return event
    }
    clickMonitors = [global, local].compactMap { $0 }
  }

  private func removeClickMonitors() {
    for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
    clickMonitors.removeAll()
  }

  private func handleMonitorClick() {
    guard onTap != nil, let panel = panel, panel.isVisible else { return }
    if Self.tapHitRect(panelFrame: panel.frame).contains(NSEvent.mouseLocation) { handleTap() }
  }

  private func handleTap() {
    removeClickMonitors()
    let action = onTap
    onTap = nil  // guard against a second monitor callback for the same click
    log("IdeaCaptureToast: tap received")
    dismiss()
    action?()
  }

  private func dismiss() {
    dismissWork?.cancel()
    dismissWork = nil
    removeClickMonitors()
    guard let panel = panel else { return }
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = 0.22
        panel.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in self?.panel?.orderOut(nil) })
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .popUpMenu  // above app windows and most overlays
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    return panel
  }

  private func screenForCursor() -> NSScreen {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
      ?? NSScreen.main ?? NSScreen.screens[0]
  }
}

private struct ToastView: View {
  let symbol: String
  let title: String
  let message: String
  let tappable: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.black.opacity(0.86))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

      HStack(spacing: 11) {
        Image(systemName: symbol)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.white)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
          Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if tappable {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .padding(IdeaCaptureToast.shadowPadding)  // room inside the transparent window for the shadow
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
