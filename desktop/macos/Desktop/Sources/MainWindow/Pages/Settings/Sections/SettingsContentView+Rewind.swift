import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SettingsContentView {
  var rewindSection: some View {
    VStack(spacing: 20) {
      // Storage Stats
      settingsCard(settingId: "rewind.storage") {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Image(systemName: "internaldrive.fill")
              .scaledFont(size: 16)
              .foregroundColor(OmiColors.purplePrimary)

            VStack(alignment: .leading, spacing: 4) {
              Text("Storage")
                .scaledFont(size: 15, weight: .medium)
                .foregroundColor(OmiColors.textPrimary)

              if let stats = rewindStats {
                Text("\(stats.total) frames • \(RewindStorage.formatBytes(stats.storageSize))")
                  .scaledFont(size: 13)
                  .foregroundColor(OmiColors.textTertiary)
              } else {
                Text("Loading...")
                  .scaledFont(size: 13)
                  .foregroundColor(OmiColors.textTertiary)
              }
            }

            Spacer()
          }
        }
      }
      .task {
        rewindStats = await RewindIndexer.shared.getStats()
      }

      // Excluded Apps
      settingsCard(settingId: "rewind.excludedapps") {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Image(systemName: "eye.slash.fill")
              .scaledFont(size: 16)
              .foregroundColor(OmiColors.purplePrimary)

            VStack(alignment: .leading, spacing: 4) {
              Text("Excluded Apps")
                .scaledFont(size: 15, weight: .medium)
                .foregroundColor(OmiColors.textPrimary)

              Text("Screen capture is paused when these apps are active")
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textTertiary)
            }

            Spacer()

            Button("Reset to Defaults") {
              rewindSettings.resetToDefaults()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }

          Divider()
            .background(OmiColors.backgroundQuaternary)

          // List of excluded apps
          if rewindSettings.excludedApps.isEmpty {
            HStack {
              Spacer()
              VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                  .scaledFont(size: 24)
                  .foregroundColor(OmiColors.textTertiary)
                Text("No apps excluded")
                  .scaledFont(size: 13)
                  .foregroundColor(OmiColors.textTertiary)
              }
              .padding(.vertical, 16)
              Spacer()
            }
          } else {
            LazyVStack(spacing: 8) {
              ForEach(Array(rewindSettings.excludedApps).sorted(), id: \.self) { appName in
                ExcludedAppRow(
                  appName: appName,
                  onRemove: {
                    rewindSettings.includeApp(appName)
                  }
                )
              }
            }
          }

          Divider()
            .background(OmiColors.backgroundQuaternary)

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
            .background(OmiColors.backgroundQuaternary)

          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Suppress private browser windows")
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(OmiColors.textSecondary)
              Text("Skip Rewind capture for Chrome Incognito, Safari Private Browsing, Firefox Private Windows, and Edge InPrivate windows.")
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)
            }

            Spacer()

            Toggle("", isOn: $rewindSettings.suppressPrivateBrowsing)
              .toggleStyle(.switch)
              .labelsHidden()
          }

          VStack(alignment: .leading, spacing: 12) {
            Text("Window title patterns")
              .scaledFont(size: 13, weight: .medium)
              .foregroundColor(OmiColors.textSecondary)

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
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Image(systemName: "battery.75percent")
              .scaledFont(size: 16)
              .foregroundColor(OmiColors.purplePrimary)

            VStack(alignment: .leading, spacing: 4) {
              Text("Battery Optimization")
                .scaledFont(size: 15, weight: .medium)
                .foregroundColor(OmiColors.textPrimary)

              Text(
                "On battery, Omi captures your screen less often to save power while keeping text recognition accurate."
              )
              .scaledFont(size: 13)
              .foregroundColor(OmiColors.textTertiary)
            }

            Spacer()

            Text("Automatic")
              .scaledFont(size: 13, weight: .medium)
              .foregroundColor(OmiColors.textSecondary)
          }
        }
      }

      // Retention Settings
      settingsCard(settingId: "rewind.retention") {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Image(systemName: "clock.fill")
              .scaledFont(size: 16)
              .foregroundColor(OmiColors.purplePrimary)

            VStack(alignment: .leading, spacing: 4) {
              Text("Data Retention")
                .scaledFont(size: 15, weight: .medium)
                .foregroundColor(OmiColors.textPrimary)

              Text("How long to keep screen recordings")
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textTertiary)
            }

            Spacer()

            Picker("", selection: $rewindSettings.retentionDays) {
              Text("3 days").tag(3)
              Text("7 days").tag(7)
              Text("14 days").tag(14)
              Text("30 days").tag(30)
            }
            .pickerStyle(.menu)
            .frame(width: 110)
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
        .foregroundColor(OmiColors.textTertiary)
        .frame(width: 24, height: 24)

      Text(pattern)
        .scaledFont(size: 13)
        .foregroundColor(OmiColors.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .scaledFont(size: 16)
          .foregroundColor(isHovered ? OmiColors.error : OmiColors.textTertiary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isHovered ? OmiColors.backgroundQuaternary.opacity(0.5) : Color.clear)
    )
    .onHover { hovering in
      isHovered = hovering
    }
  }
}
