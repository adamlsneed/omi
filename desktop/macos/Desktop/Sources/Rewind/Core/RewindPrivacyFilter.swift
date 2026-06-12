import Foundation

enum RewindPrivacyFilter {
    static func shouldExclude(
        appName: String,
        windowTitle: String?,
        excludedApps: Set<String>,
        excludedWindowPatterns: Set<String>,
        suppressPrivateBrowsing: Bool
    ) -> Bool {
        if excludedApps.contains(appName) {
            return true
        }

        if suppressPrivateBrowsing && isPrivateBrowsingWindow(appName: appName, windowTitle: windowTitle) {
            return true
        }

        return excludedWindowPatterns.contains { pattern in
            matches(pattern: pattern, appName: appName, windowTitle: windowTitle)
        }
    }

    static func isPrivateBrowsingWindow(appName: String, windowTitle: String?) -> Bool {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return false
        }

        let browser = appName.lowercased()
        let titleLower = title.lowercased()

        if browser.contains("chrome")
            || browser.contains("chromium")
            || browser.contains("brave")
            || browser.contains("arc")
        {
            return titleLower.contains("incognito")
        }

        if browser.contains("safari") {
            return titleLower.contains("private browsing")
        }

        if browser.contains("firefox") {
            return titleLower.contains("private browsing")
                || titleLower.contains("private window")
        }

        if browser.contains("edge") {
            return titleLower.contains("inprivate")
        }

        return false
    }

    static func matches(pattern: String, appName: String, windowTitle: String?) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let parts = trimmed.components(separatedBy: "::")
        if parts.count == 2 {
            return wildcardMatches(parts[0], value: appName)
                && wildcardMatches(parts[1], value: windowTitle ?? "")
        }

        return wildcardMatches(trimmed, value: windowTitle ?? "")
    }

    private static func wildcardMatches(_ pattern: String, value: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            .replacingOccurrences(of: "\\*", with: ".*")
        let regex = "^\(escaped)$"
        return value.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
