import OmiTheme
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What the Rewind storage card should say.
///
/// `RewindIndexer.getStats()` returns `nil` both before it has run and when the
/// Rewind database fails to open, so the card could not tell "not read yet"
/// from "could not be read" — a Rewind store that never opens left it reading
/// "Loading..." with no end and no way to retry. Resolving the caption from the
/// stats *and* whether a read has completed is what separates the two.
enum RewindStorageSummaryState: Equatable {
  case loading
  case loaded(caption: String)
  case unavailable

  static func resolve(
    stats: (total: Int, indexed: Int, storageSize: Int64)?,
    didCompleteRead: Bool
  ) -> RewindStorageSummaryState {
    if let stats {
      return .loaded(caption: "\(stats.total) frames • \(RewindStorage.formatBytes(stats.storageSize))")
    }
    return didCompleteRead ? .unavailable : .loading
  }
}

/// The storage card's contents. It owns whether a read has completed — the
/// parent's `rewindStats` alone cannot express that — and writes the result
/// back through the binding so there is still one stats value on the pane.
struct RewindStorageSummary: View {
  @Binding var stats: (total: Int, indexed: Int, storageSize: Int64)?
  @State private var didCompleteRead = false
  @State private var isReloading = false

  var body: some View {
    HStack {
      Image(systemName: "internaldrive.fill")
        .scaledFont(size: OmiType.subheading)
        .foregroundColor(Ink.secondary)

      VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
        Text("Storage")
          .scaledFont(size: OmiType.subheading, weight: .medium)
          .foregroundColor(Ink.primary)

        switch RewindStorageSummaryState.resolve(stats: stats, didCompleteRead: didCompleteRead) {
        case .loaded(let caption):
          Text(caption)
            .scaledFont(size: OmiType.body)
            .foregroundColor(Ink.secondary)
        case .loading:
          Text("Loading…")
            .scaledFont(size: OmiType.body)
            .foregroundColor(Ink.secondary)
        case .unavailable:
          Text("Couldn't read Rewind storage")
            .scaledFont(size: OmiType.body)
            .foregroundColor(SettingsInk.notice)
        }
      }

      Spacer()

      if case .unavailable = RewindStorageSummaryState.resolve(
        stats: stats, didCompleteRead: didCompleteRead)
      {
        Button("Retry") {
          Task { await read() }
        }
        .buttonStyle(OmiButtonStyle(.primary, size: .compact))
        .disabled(isReloading)
      }
    }
    .task { await read() }
  }

  private func read() async {
    guard !isReloading else { return }
    isReloading = true
    let next = await RewindIndexer.shared.getStats()
    stats = next
    didCompleteRead = true
    isReloading = false
  }
}

extension SettingsContentView {
  var rewindSection: some View {
    VStack(spacing: OmiSpacing.xl) {
      // Storage Stats
      settingsCard(settingId: "rewind.storage") {
        RewindStorageSummary(stats: $rewindStats)
      }

      // Meeting Note Screenshots
      settingsCard(settingId: "rewind.meetingnotescreenshots") {
        HStack {
          Image(systemName: "photo.on.rectangle.angled")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
            Text("Meeting Screenshots")
              .scaledFont(size: OmiType.subheading, weight: .medium)
              .foregroundColor(Ink.primary)

            Text("Add a few screenshots of what was on screen to a meeting's note")
              .scaledFont(size: OmiType.body)
              .foregroundColor(Ink.secondary)
          }

          Spacer()

          Toggle("", isOn: $meetingNoteScreenshotsEnabled)
            .toggleStyle(OmiToggleStyle())
            .labelsHidden()
            .onChange(of: meetingNoteScreenshotsEnabled) { _, newValue in
              guard !isSyncingMeetingNoteScreenshotsFromServer else { return }
              updateMeetingNoteScreenshotsSetting(enabled: newValue)
            }
        }
        .task { await loadMeetingNoteScreenshotsSetting() }
      }

      // Excluded Apps
      settingsCard(settingId: "rewind.excludedapps") {
        VStack(alignment: .leading, spacing: OmiSpacing.lg) {
          HStack {
            Image(systemName: "eye.slash.fill")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(Ink.secondary)

            VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
              Text("Excluded Apps")
                .scaledFont(size: OmiType.subheading, weight: .medium)
                .foregroundColor(Ink.primary)

              Text("Screen capture is paused when these apps are active")
                .scaledFont(size: OmiType.body)
                .foregroundColor(Ink.secondary)
            }

            Spacer()

            Button("Reset to Defaults") {
              rewindSettings.resetToDefaults()
            }
            .buttonStyle(OmiButtonStyle(.primary, size: .compact))
          }

          GlassSeparator()

          // List of excluded apps
          if rewindSettings.excludedApps.isEmpty {
            HStack {
              Spacer()
              VStack(spacing: OmiSpacing.sm) {
                Image(systemName: "checkmark.shield")
                  .scaledFont(size: 24)
                  .foregroundColor(Ink.secondary)
                Text("No apps excluded")
                  .scaledFont(size: OmiType.body)
                  .foregroundColor(Ink.secondary)
              }
              .padding(.vertical, OmiSpacing.lg)
              Spacer()
            }
          } else {
            // A rule between rows rather than a gap between them. A column of thirty app names on
            // one card ran together at `OmiSpacing.sm`: nothing said where one row ended, so it
            // read as a block of text with icons in it. The inset hairline is what makes it a list.
            let excluded = Array(rewindSettings.excludedApps).sorted()
            LazyVStack(spacing: 0) {
              ForEach(excluded, id: \.self) { appName in
                if appName != excluded.first { SettingsRowDivider() }
                ExcludedAppRow(
                  appName: appName,
                  onRemove: {
                    rewindSettings.includeApp(appName)
                  }
                )
                .padding(.vertical, SettingsGlassMetrics.rowVerticalPadding)
              }
            }
          }

          GlassSeparator()

          // Add app section
          AppRuleEditorView(
            title: "Add App to Exclusion List",
            placeholder: "App name (e.g., Passwords)",
            addButtonTitle: "Add",
            existingApps: rewindSettings.excludedApps,
            builtInApps: TaskAssistantSettings.builtInExcludedApps,
            onAdd: { appName in
              rewindSettings.excludeApp(appName)
            }
          )

          Divider()
            .background(Ink.rowFillHover)

          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Suppress private browser windows")
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(Ink.secondary)
              Text(
                "Skip Rewind capture for Chrome Incognito, Safari Private Browsing, Firefox Private Windows, and Edge InPrivate windows."
              )
              .scaledFont(size: 12)
              .foregroundColor(Ink.secondary)
            }

            Spacer()

            Toggle("", isOn: $rewindSettings.suppressPrivateBrowsing)
              .toggleStyle(.switch)
              .labelsHidden()
          }

          VStack(alignment: .leading, spacing: 12) {
            Text("Window title patterns")
              .scaledFont(size: 13, weight: .medium)
              .foregroundColor(Ink.secondary)

            HStack(spacing: 8) {
              TextField("e.g. Google Chrome::*Bank* or *Payroll*", text: $rewindWindowPatternInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                  addRewindWindowPattern()
                }

              Button("Add") {
                addRewindWindowPattern()
              }
              .buttonStyle(.bordered)
              .disabled(rewindWindowPatternInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !rewindSettings.excludedWindowPatterns.isEmpty {
              LazyVStack(spacing: 8) {
                ForEach(Array(rewindSettings.excludedWindowPatterns).sorted(), id: \.self) { pattern in
                  ExcludedWindowPatternRow(pattern: pattern) {
                    rewindSettings.includeWindowPattern(pattern)
                  }
                }
              }
            }
          }
        }
      }

      // Battery Settings
      settingsCard(settingId: "rewind.battery") {
        VStack(alignment: .leading, spacing: OmiSpacing.lg) {
          HStack {
            Image(systemName: "battery.75percent")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(Ink.secondary)

            VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
              Text("Battery Optimization")
                .scaledFont(size: OmiType.subheading, weight: .medium)
                .foregroundColor(Ink.primary)

              Text(
                "On battery, Omi captures your screen less often to save power while keeping text recognition accurate."
              )
              .scaledFont(size: OmiType.body)
              .foregroundColor(Ink.secondary)
            }

            Spacer()

            Text("Automatic")
              .scaledFont(size: OmiType.body, weight: .medium)
              .foregroundColor(Ink.secondary)
          }
        }
      }

      // Retention Settings
      settingsCard(settingId: "rewind.retention") {
        VStack(alignment: .leading, spacing: OmiSpacing.lg) {
          HStack {
            Image(systemName: "clock.fill")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(Ink.secondary)

            VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
              Text("Data Retention")
                .scaledFont(size: OmiType.subheading, weight: .medium)
                .foregroundColor(Ink.primary)

              Text(
                rewindSettings.keepsEverything
                  ? "Rewind reaches back as far as you have been capturing"
                  : "Older screen recordings are deleted, and Rewind cannot reach past them"
              )
              .scaledFont(size: OmiType.body)
              .foregroundColor(Ink.secondary)
            }

            Spacer()

            SettingsMenuPicker(selection: $rewindSettings.retentionDays) {
              Text("3 days").tag(3)
              Text("7 days").tag(7)
              Text("14 days").tag(14)
              Text("30 days").tag(30)
              Text("Keep everything").tag(RewindSettings.unlimitedRetentionDays)
            }
          }
        }
      }
    }
  }

  // MARK: - Transcription Section

  func addRewindWindowPattern() {
    let trimmed = rewindWindowPatternInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    rewindSettings.excludeWindowPattern(trimmed)
    rewindWindowPatternInput = ""
  }

  // MARK: - Meeting note screenshots setting

  /// Read-on-appear for the account-level gate (`GET v1/screen-frame-egress/settings`, contract
  /// §6). `meetingNoteScreenshotsEnabled`'s `@AppStorage` default is the offline cache this toggle
  /// (and `MeetingNoteScreenshotsFeature.isEnabled`) reads synchronously, so this call only ever
  /// reconciles that cache with the account's real value — e.g. after the setting changed on
  /// another device, or after a reinstall wiped the local mirror. It never blocks the toggle: on
  /// failure the cache is simply left as it was.
  func loadMeetingNoteScreenshotsSetting() async {
    do {
      let settings = try await APIClient.shared.getScreenFrameSettings()
      guard settings.meetingNoteScreenshotsEnabled != meetingNoteScreenshotsEnabled else { return }
      // Setting this directly would itself fire the toggle's `onChange` and PATCH the value we
      // just GET-ed straight back to the server. The flag tells that handler to stand down for
      // this one assignment.
      isSyncingMeetingNoteScreenshotsFromServer = true
      meetingNoteScreenshotsEnabled = settings.meetingNoteScreenshotsEnabled
      isSyncingMeetingNoteScreenshotsFromServer = false
    } catch {
      logError("Failed to load meeting note screenshots setting", error: error)
    }
  }

  /// Write-on-change for the same account-level gate (`PATCH v1/screen-frame-egress/settings`).
  ///
  /// Every other settings writer in this app (`updateDailySummarySettings`, `updateLanguage`,
  /// `updatePrivateCloudSync`, …, in `SettingsContentView+SettingsUpdates.swift`) fires the PATCH
  /// and only logs a failure, leaving the toggle exactly where the user left it. That is fine when
  /// the toggle is just a cached mirror of a server value the UI re-reads next time. This one is
  /// different: `MeetingNoteScreenshotsFeature.isEnabled` reads the *local* `UserDefaults` mirror
  /// synchronously as the actual feature gate, so a write that silently failed would leave the
  /// screenshot pipeline running (or stopped) here while the account — and every other device, and
  /// the web surface reading the same setting — disagreed. Nothing else in this file guards a
  /// settings write against that, so this one reverts the toggle to its last-known-good value
  /// instead of leaving that lie on screen.
  func updateMeetingNoteScreenshotsSetting(enabled: Bool) {
    Task {
      do {
        let _ = try await APIClient.shared.updateScreenFrameSettings(enabled: enabled)
      } catch {
        logError("Failed to update meeting note screenshots setting", error: error)
        isSyncingMeetingNoteScreenshotsFromServer = true
        meetingNoteScreenshotsEnabled = !enabled
        isSyncingMeetingNoteScreenshotsFromServer = false
      }
    }
  }
}

// MARK: - Excluded Window Pattern Row

struct ExcludedWindowPatternRow: View {
  let pattern: String
  let onRemove: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle.slash")
        .scaledFont(size: 16)
        .foregroundColor(Ink.secondary)
        .frame(width: 24, height: 24)

      Text(pattern)
        .scaledFont(size: 13)
        .foregroundColor(Ink.primary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .scaledFont(size: 16)
          .foregroundColor(isHovered ? Ink.errorRed : Ink.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isHovered ? Ink.rowFillHover.opacity(0.5) : Color.clear)
    )
    .onHover { hovering in
      isHovered = hovering
    }
  }
}
