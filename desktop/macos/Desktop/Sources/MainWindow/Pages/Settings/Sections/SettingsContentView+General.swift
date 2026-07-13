import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import OmiTheme

extension SettingsContentView {
  var generalSection: some View {
    VStack(spacing: OmiSpacing.xl) {
      // Screen Recording toggle
      settingsCard(settingId: "general.screencapture") {
        HStack(spacing: OmiSpacing.lg) {
          Image(systemName: "rectangle.dashed.badge.record")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(OmiColors.info)

          VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
            Text(DesktopRecordingControlCopy.screenRecordingTitle)
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(OmiColors.textPrimary)

            Text(
              permissionError
                ?? (isMonitoring ? "Recording screen content" : "Screen recording is paused")
            )
            .scaledFont(size: OmiType.body)
            .foregroundColor(permissionError != nil ? OmiColors.warning : OmiColors.textTertiary)
          }

          Spacer()

          if isToggling {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Toggle(
              DesktopRecordingControlCopy.screenRecordingTitle,
              isOn: Binding(
                get: { isMonitoring },
                set: { newValue in
                  isMonitoring = newValue
                  toggleMonitoring(enabled: newValue)
                }
              )
            )
            .toggleStyle(OmiToggleStyle())
            .labelsHidden()
            .accessibilityLabel(DesktopRecordingControlCopy.screenRecordingTitle)
          }
        }
      }

      // Microphone toggle
      settingsCard(settingId: "general.audiorecording") {
        HStack(spacing: OmiSpacing.lg) {
          Image(systemName: "mic.fill")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(OmiColors.info)

          VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
            Text(DesktopRecordingControlCopy.microphoneTitle)
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(OmiColors.textPrimary)

            Text(
              transcriptionError
                ?? (isTranscribing
                  ? (appState.isAwaitingMeeting
                    ? "Waiting for a meeting…" : "Recording and transcribing microphone audio")
                  : "Microphone recording is paused")
            )
            .scaledFont(size: OmiType.body)
            .foregroundColor(transcriptionError != nil ? OmiColors.warning : OmiColors.textTertiary)
          }

          Spacer()

          if isTogglingTranscription {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Toggle(
              DesktopRecordingControlCopy.microphoneTitle,
              isOn: Binding(
                get: { isTranscribing },
                set: { newValue in
                  isTranscribing = newValue
                  toggleTranscription(enabled: newValue)
                }
              )
            )
            .toggleStyle(OmiToggleStyle())
            .labelsHidden()
            .accessibilityLabel(DesktopRecordingControlCopy.microphoneTitle)
          }
        }
      }

      // Notifications toggle
      settingsCard(settingId: "general.notifications") {
        VStack(spacing: OmiSpacing.md) {
          HStack(spacing: OmiSpacing.lg) {
            Image(systemName: "bell.fill")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(OmiColors.info)

            VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
              Text("Notifications")
                .scaledFont(size: OmiType.subheading, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

              Text(notificationStatusText)
                .scaledFont(size: OmiType.body)
                .foregroundColor(
                  appState.isNotificationBannerDisabled ? OmiColors.warning : OmiColors.textTertiary
                )
            }

            Spacer()

            // Toggle mirrors the effective notification state. macOS ownership
            // caveat: the app can request/repair permission but cannot revoke
            // it, so flipping OFF (or fixing disabled banners) deep-links to
            // System Settings; the toggle re-syncs from the real permission.
            Toggle(
              "",
              isOn: Binding(
                get: {
                  appState.hasNotificationPermission && !appState.isNotificationBannerDisabled
                },
                set: { newValue in
                  if newValue {
                    if appState.isNotificationBannerDisabled {
                      // Banners off — user needs to change style in System Settings
                      appState.openNotificationPreferences()
                    } else {
                      // Auth not granted — try lsregister repair first
                      AnalyticsManager.shared.notificationRepairTriggered(
                        reason: "settings_fix_button",
                        previousStatus: "not_authorized",
                        currentStatus: "not_authorized"
                      )
                      appState.repairNotificationAndFallback()
                    }
                  } else {
                    appState.openNotificationPreferences()
                  }
                }
              )
            )
            .toggleStyle(OmiToggleStyle())
            .labelsHidden()
          }

          // Warning when banners are disabled
          if appState.isNotificationBannerDisabled {
            HStack(spacing: OmiSpacing.sm) {
              Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: OmiType.caption)
                .foregroundColor(OmiColors.warning)

              Text(
                "Banners disabled - you won't see visual alerts. Set style to \"Banners\" in System Settings."
              )
              .scaledFont(size: OmiType.caption)
              .foregroundColor(OmiColors.warning)

              Spacer()
            }
            .padding(OmiSpacing.sm)
            .background(
              RoundedRectangle(cornerRadius: OmiChrome.elementRadius)
                .fill(OmiColors.warning.opacity(0.1))
            )
          }
        }
      }

      // System Audio capture mode (macOS 14.4+ — system audio capture requires Core Audio taps)
      if #available(macOS 14.4, *) {
        settingsCard(settingId: "general.systemaudio") {
          VStack(alignment: .leading, spacing: OmiSpacing.md) {
            HStack(spacing: OmiSpacing.lg) {
              Image(systemName: "speaker.wave.2.fill")
                .scaledFont(size: OmiType.subheading)
                .foregroundColor(OmiColors.info)

              VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
                Text("System Audio")
                  .scaledFont(size: OmiType.subheading, weight: .semibold)
                  .foregroundColor(OmiColors.textPrimary)

                Text("Choose when Omi records audio from other apps (calls, videos, music).")
                  .scaledFont(size: OmiType.body)
                  .foregroundColor(OmiColors.textTertiary)
              }

              Spacer()

              Picker(
                "",
                selection: Binding(
                  get: { systemAudioCaptureMode },
                  set: { newValue in
                    systemAudioCaptureMode = newValue
                    setSystemAudioCaptureMode(newValue)
                  }
                )
              ) {
                Text("Always").tag(AssistantSettings.SystemAudioCaptureMode.always)
                Text("Only during meetings").tag(
                  AssistantSettings.SystemAudioCaptureMode.onlyDuringMeetings)
                Text("Never").tag(AssistantSettings.SystemAudioCaptureMode.never)
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .frame(width: 200)
            }

            if systemAudioCaptureMode == .onlyDuringMeetings {
              Text(
                "Omi captures other apps' audio only while you're in a call (e.g. Zoom, Teams, FaceTime). Detecting browser-based calls like Google Meet requires Screen Recording permission."
              )
              .scaledFont(size: OmiType.caption)
              .foregroundColor(OmiColors.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }

      // Notifications toggle
      settingsCard(settingId: "general.notifications") {
        VStack(spacing: 12) {
          HStack(spacing: 16) {
            Circle()
              .fill(
                appState.hasNotificationPermission && !appState.isNotificationBannerDisabled
                  ? OmiColors.success
                  : (appState.isNotificationBannerDisabled
                    ? OmiColors.warning : OmiColors.textTertiary.opacity(0.3))
              )
              .frame(width: 12, height: 12)
              .shadow(
                color: appState.hasNotificationPermission && !appState.isNotificationBannerDisabled
                  ? OmiColors.success.opacity(0.5) : .clear, radius: 6)

            VStack(alignment: .leading, spacing: 4) {
              Text("Notifications")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

              Text(notificationStatusText)
                .scaledFont(size: 13)
                .foregroundColor(
                  appState.isNotificationBannerDisabled ? OmiColors.warning : OmiColors.textTertiary
                )
            }

            Spacer()

            if appState.hasNotificationPermission && !appState.isNotificationBannerDisabled {
              // Show enabled badge
              Text("Enabled")
                .scaledFont(size: 12, weight: .medium)
                .foregroundColor(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                  Capsule()
                    .fill(Color.green.opacity(0.15))
                )
            } else {
              // Show button to enable or fix
              Button(action: {
                if appState.isNotificationBannerDisabled {
                  // Banners off — user needs to change style in System Settings
                  appState.openNotificationPreferences()
                } else {
                  // Auth not granted — try lsregister repair first
                  AnalyticsManager.shared.notificationRepairTriggered(
                    reason: "settings_fix_button",
                    previousStatus: "not_authorized",
                    currentStatus: "not_authorized"
                  )
                  appState.repairNotificationAndFallback()
                }
              }) {
                Text(appState.isNotificationBannerDisabled ? "Fix" : "Enable")
                  .scaledFont(size: 12, weight: .semibold)
                  .foregroundColor(.white)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    RoundedRectangle(cornerRadius: 6)
                      .fill(
                        appState.isNotificationBannerDisabled
                          ? OmiColors.warning : OmiColors.info)
                  )
              }
              .buttonStyle(.plain)
            }
          }

          // Warning when banners are disabled
          if appState.isNotificationBannerDisabled {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.warning)

              Text(
                "Banners disabled - you won't see visual alerts. Set style to \"Banners\" in System Settings."
              )
              .scaledFont(size: 12)
              .foregroundColor(OmiColors.warning)

              Spacer()
            }
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(OmiColors.warning.opacity(0.1))
            )
          }
        }
      }

      // Dock Icon toggle
      settingsCard(settingId: "general.dockicon") {
        HStack(spacing: 16) {
          Image(systemName: "dock.rectangle")
            .scaledFont(size: 16)
            .foregroundColor(OmiColors.textPrimary)
            .frame(width: 12)

          VStack(alignment: .leading, spacing: 4) {
            Text("Dock Icon")
              .scaledFont(size: 16, weight: .semibold)
              .foregroundColor(OmiColors.textPrimary)

            Text(
              hidesDockIcon
                ? "Hidden from Dock and app switcher"
                : "Visible in Dock and app switcher"
            )
              .scaledFont(size: 13)
              .foregroundColor(OmiColors.textTertiary)
          }

          Spacer()

          Toggle(
            "Dock Icon",
            // ON = Dock icon visible. Stored as `hideDockIcon` (inverted) so the
            // underlying preference and its default (visible) stay unchanged.
            isOn: Binding(
              get: { !hidesDockIcon },
              set: { newValue in
                hidesDockIcon = !newValue
                NotificationCenter.default.post(
                  name: .dockIconVisibilityPreferenceDidChange, object: nil)
              }
            )
          )
          .toggleStyle(.switch)
          .labelsHidden()
          .accessibilityLabel("Dock Icon")
        }
      }

      // Font Size
      settingsCard(settingId: "general.fontsize") {
        VStack(spacing: OmiSpacing.md) {
          HStack(spacing: OmiSpacing.lg) {
            Image(systemName: "textformat.size")
              .scaledFont(size: 16, weight: .medium)
              .foregroundColor(OmiColors.info)
              .frame(width: 12)

            VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
              Text("Font Size")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

              Text("Scale: \(Int(fontScaleSettings.scale * 100))%")
                .scaledFont(size: OmiType.body)
                .foregroundColor(OmiColors.textTertiary)
            }

            Spacer()

            if fontScaleSettings.scale != 1.0 {
              Button("Reset") {
                fontScaleSettings.resetToDefault()
              }
              .buttonStyle(OmiButtonStyle(.primary, size: .compact))
            }
          }

          HStack(spacing: OmiSpacing.md) {
            // The small/large "A" pair illustrates the scale range — keep the
            // original 12/18 ratio rather than the type registers.
            Text("A")
              .scaledFont(size: 12, weight: .medium)
              .foregroundColor(OmiColors.textTertiary)

            Slider(value: $fontScaleSettings.scale, in: 0.5...2.0, step: 0.05)
              .tint(OmiColors.info)

            Text("A")
              .scaledFont(size: 18, weight: .medium)
              .foregroundColor(OmiColors.textTertiary)
          }

          Text("The quick brown fox jumps over the lazy dog")
            .scaledFont(size: 14)
            .foregroundColor(OmiColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, OmiSpacing.xxs)

          HStack {
            Spacer()
            Button(action: {
              resetWindowToDefaultSize()
            }) {
              HStack(spacing: OmiSpacing.xs) {
                Image(systemName: "arrow.uturn.backward")
                Text("Reset Window Size")
              }
            }
            .buttonStyle(OmiButtonStyle(.primary, size: .compact))
          }
        }
      }

    }
  }

}
