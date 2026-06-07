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

  /// Show a toast top-center on the active display. `onTap`, when set, runs if the
  /// user clicks the toast (and dismisses it) — used to jump to the Ideas folder.
  /// Fixed window size — avoids any auto-sizing path. Letting AppKit resize a
  /// borderless panel to SwiftUI's content (via fittingSize or .preferredContentSize)
  /// triggers a constraint feedback loop that recurses until the stack overflows.
  private static let toastSize = NSSize(width: 384, height: 104)

  /// Show a toast. `autoDismiss == false` keeps it up until the next `show`/`dismiss`
  /// (used for the "Capturing…" progress state while the network call is in flight).
  func show(
    symbol: String, title: String, message: String,
    autoDismiss: Bool = true, onTap: (@MainActor () -> Void)? = nil
  ) {
    self.onTap = onTap

    let content = ToastView(
      symbol: symbol, title: title, message: message,
      tappable: onTap != nil,
      onTap: { [weak self] in self?.handleTap() }
    )
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

    dismissWork?.cancel()
    guard autoDismiss else { return }
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    dismissWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
  }

  private func handleTap() {
    let action = onTap
    dismiss()
    action?()
  }

  private func dismiss() {
    dismissWork?.cancel()
    dismissWork = nil
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
  let onTap: @MainActor () -> Void

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
    .padding(14)  // room inside the transparent window for the shadow
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { if tappable { onTap() } }
  }
}
