import SwiftUI

/// State management for apps/plugins functionality
@MainActor
class AppProvider: ObservableObject {
    @Published var apps: [OmiApp] = []
    @Published var popularApps: [OmiApp] = []  // Featured apps (is_popular=true)
    @Published var integrationApps: [OmiApp] = []  // Apps with external_integration capability
    @Published var chatApps: [OmiApp] = []  // Apps with chat capability
    @Published var summaryApps: [OmiApp] = []  // Apps with memories capability
    @Published var notificationApps: [OmiApp] = []  // Apps with proactive_notification capability
    @Published var enabledApps: [OmiApp] = []
    @Published var categories: [OmiAppCategory] = []
    @Published var capabilities: [OmiAppCapability] = []

    @Published var isLoading = false
    @Published var isSearching = false
    @Published var appLoadingStates: [String: Bool] = [:]

    @Published var searchQuery = ""
    @Published var selectedCategory: String?
    @Published var selectedCapability: String?
    @Published var showInstalledOnly = false

    @Published var errorMessage: String?
    @Published var categoryFilteredApps: [OmiApp]?
    @Published var hasMoreCategoryApps = false
    @Published var isLoadingMore = false

    private var categoryFilterOffset = 0
    private let categoryPageSize = 50

    private let apiClient = APIClient.shared

    // MARK: - Session Lifecycle

    func resetSessionState() {
        apps = []
        popularApps = []
        integrationApps = []
        chatApps = []
        summaryApps = []
        notificationApps = []
        enabledApps = []
        categories = []
        capabilities = []

        isLoading = false
        isSearching = false
        appLoadingStates = [:]

        searchQuery = ""
        selectedCategory = nil
        selectedCapability = nil
        showInstalledOnly = false

        errorMessage = nil
        categoryFilteredApps = nil
        hasMoreCategoryApps = false
        isLoadingMore = false
        categoryFilterOffset = 0
    }

    // MARK: - Fetch Methods

    /// Fetch only chat-capable apps for startup chat picker warmup.
    /// The full Apps page still loads categories, capabilities, ratings, and all groups on first use.
    func fetchChatAppsForStartup() async {
        do {
            let v2Response = try await apiClient.getAppsV2()
            let chat = v2Response.groups.first { $0.capability.id == "chat" }?.data ?? []
            chatApps = chat
            log("Fetched \(chatApps.count) chat apps for startup")
        } catch {
            logError("Failed to fetch startup chat apps", error: error)
        }
    }

    /// Fetch all apps data using v2/apps endpoint (grouped by capability, matching Flutter)
    func fetchApps() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            NotificationCenter.default.post(name: .appsPageDidLoad, object: nil)
        }

        do {
            // Fetch grouped apps and metadata in parallel
            async let v2AppsTask = apiClient.getAppsV2()
            async let categoriesTask = apiClient.getAppCategories()
            async let capabilitiesTask = apiClient.getAppCapabilities()

            let (v2Response, fetchedCategories, fetchedCapabilities) = try await (
                v2AppsTask,
                categoriesTask,
                capabilitiesTask
            )

            // Process groups off main thread
            let processed = await Task.detached(priority: .utility) {
                var dedupedApps: [OmiApp] = []
                var popular: [OmiApp] = []
                var integration: [OmiApp] = []
                var chat: [OmiApp] = []
                var summary: [OmiApp] = []
                var notification: [OmiApp] = []
                var allApps: [OmiApp] = []

                for group in v2Response.groups {
                    allApps.append(contentsOf: group.data)
                    switch group.capability.id {
                    case "popular":
                        popular = group.data
                    case "external_integration":
                        integration = group.data
                    case "chat":
                        chat = group.data
                    case "memories":
                        summary = group.data
                    case "proactive_notification":
                        notification = group.data
                    default:
                        break
                    }
                }

                // Remove duplicates
                var seenIds = Set<String>()
                dedupedApps = allApps.filter { app in
                    if seenIds.contains(app.id) { return false }
                    seenIds.insert(app.id)
                    return true
                }

                return (dedupedApps, popular, integration, chat, summary, notification)
            }.value

            // Batch-assign all @Published properties on main actor
            apps = processed.0
            popularApps = processed.1
            integrationApps = processed.2
            chatApps = processed.3
            summaryApps = processed.4
            notificationApps = processed.5
            categories = fetchedCategories
            capabilities = fetchedCapabilities

            updateDerivedLists()

            log("Fetched \(apps.count) apps via v2: \(popularApps.count) featured, \(integrationApps.count) integrations, \(chatApps.count) chat, \(summaryApps.count) summary, \(notificationApps.count) notifications")

            // Enrich ratings + enabled state in background.
            // v2/apps returns rating_avg=0 and may not include per-user enabled state.
            // v1/apps is user-specific and has real ratings + correct enabled field.
            Task {
                do {
                    let ratedApps = try await self.apiClient.getAppsWithRatings()
                    // Build a map of id → full app (for ratings AND enabled state)
                    let v1Map = Dictionary(uniqueKeysWithValues: ratedApps.map { ($0.id, $0) })
                    func enrich(_ list: inout [OmiApp]) {
                        for index in list.indices {
                            guard let v1App = v1Map[list[index].id] else { continue }
                            if v1App.ratingCount > 0 {
                                list[index].ratingAvg = v1App.ratingAvg
                                list[index].ratingCount = v1App.ratingCount
                            }
                            // Sync enabled state from user-specific v1/apps response
                            list[index].enabled = v1App.enabled
                        }
                    }
                    enrich(&self.apps)
                    enrich(&self.popularApps)
                    enrich(&self.integrationApps)
                    enrich(&self.chatApps)
                    enrich(&self.summaryApps)
                    enrich(&self.notificationApps)
                    self.updateDerivedLists()
                } catch {
                    // silently fail — ratings are supplementary
                }
            }
        } catch {
            logError("Failed to fetch apps", error: error)
            errorMessage = "Failed to load apps: \(error.localizedDescription)"
        }
    }

    /// Search apps with current filters
    func searchApps() async {
        guard !searchQuery.isEmpty || selectedCategory != nil || selectedCapability != nil || showInstalledOnly else {
            // Reset to default view
            await fetchApps()
            return
        }

        resetCategoryPagination()
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            apps = try await apiClient.searchApps(
                query: searchQuery.isEmpty ? nil : searchQuery,
                category: selectedCategory,
                capability: selectedCapability,
                installedOnly: showInstalledOnly
            )
            updateDerivedLists()
        } catch {
            logError("Failed to search apps", error: error)
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Fetch apps for a specific category from the API
    func fetchAppsForCategory(_ categoryId: String) async {
        isSearching = true
        categoryFilterOffset = 0
        defer { isSearching = false }

        do {
            let results = try await apiClient.getApps(category: categoryId, limit: categoryPageSize, offset: 0)
            categoryFilteredApps = results
            hasMoreCategoryApps = results.count >= categoryPageSize
            log("Fetched \(results.count) apps for category \(categoryId)")
        } catch {
            logError("Failed to fetch apps for category \(categoryId)", error: error)
            // Fallback to client-side filtering
            categoryFilteredApps = apps.filter { $0.category == categoryId }
            hasMoreCategoryApps = false
        }
    }

    /// Load more apps for the current category (pagination)
    func loadMoreCategoryApps() async {
        guard let categoryId = selectedCategory,
              hasMoreCategoryApps,
              !isLoadingMore else { return }

        isLoadingMore = true
        let newOffset = categoryFilterOffset + categoryPageSize
        defer { isLoadingMore = false }

        do {
            let results = try await apiClient.getApps(category: categoryId, limit: categoryPageSize, offset: newOffset)
            if !results.isEmpty {
                categoryFilteredApps?.append(contentsOf: results)
                categoryFilterOffset = newOffset
                hasMoreCategoryApps = results.count >= categoryPageSize
                log("Loaded \(results.count) more apps for category \(categoryId)")
            } else {
                hasMoreCategoryApps = false
            }
        } catch {
            logError("Failed to load more apps for category \(categoryId)", error: error)
        }
    }

    /// Clear category filter results
    func clearCategoryFilter() {
        selectedCategory = nil
        resetCategoryPagination()
    }

    private func resetCategoryPagination() {
        categoryFilteredApps = nil
        categoryFilterOffset = 0
        hasMoreCategoryApps = false
        isLoadingMore = false
    }

    /// Fetch user's enabled apps
    func fetchEnabledApps() async {
        do {
            let enabledAppIds = Set(try await apiClient.getEnabledAppIds())
            enabledApps = apps.filter { enabledAppIds.contains($0.id) }
            chatApps = enabledApps.filter { $0.worksWithChat }
        } catch {
            logError("Failed to fetch enabled apps", error: error)
        }
    }

    // MARK: - App Management

    /// Toggle app enabled state
    func toggleApp(_ app: OmiApp) async {
        await setApp(app, enabled: !isAppEnabled(app))
    }

    /// Enable an app
    func enableApp(_ app: OmiApp) async {
        await setApp(app, enabled: true)
    }

    /// Disable an app
    func disableApp(_ app: OmiApp) async {
        await setApp(app, enabled: false)
    }

    /// Check the provider's latest enabled state for an app value that may be stale.
    func isAppEnabled(_ app: OmiApp) -> Bool {
        currentApp(withId: app.id)?.enabled ?? app.enabled
    }

    /// Set app enabled state explicitly, so stale model values cannot invert the UI/backend state.
    @discardableResult
    func setApp(_ app: OmiApp, enabled desiredState: Bool) async -> Bool {
        if appLoadingStates[app.id] == true {
            return isAppEnabled(app) == desiredState
        }

        let currentState = isAppEnabled(app)
        guard currentState != desiredState else {
            setLocalEnabledState(for: app.id, enabled: desiredState)
            return true
        }

        appLoadingStates[app.id] = true
        defer { appLoadingStates[app.id] = false }

        do {
            if desiredState {
                try await apiClient.enableApp(appId: app.id)
                // Track app enabled
                AnalyticsManager.shared.appEnabled(appId: app.id, appName: app.name)
            } else {
                try await apiClient.disableApp(appId: app.id)
                // Track app disabled
                AnalyticsManager.shared.appDisabled(appId: app.id, appName: app.name)
            }

            setLocalEnabledState(for: app.id, enabled: desiredState)

            log("Set app \(app.id) enabled=\(desiredState)")
            return true
        } catch {
            logError("Failed to set app enabled=\(desiredState)", error: error)
            errorMessage = "Failed to \(desiredState ? "enable" : "disable") app"
            return false
        }
    }

    // MARK: - Helpers

    /// Check if an app is currently loading
    func isAppLoading(_ appId: String) -> Bool {
        appLoadingStates[appId] ?? false
    }

    private func currentApp(withId appId: String) -> OmiApp? {
        if let app = apps.first(where: { $0.id == appId }) { return app }
        if let app = categoryFilteredApps?.first(where: { $0.id == appId }) { return app }
        if let app = popularApps.first(where: { $0.id == appId }) { return app }
        if let app = integrationApps.first(where: { $0.id == appId }) { return app }
        if let app = chatApps.first(where: { $0.id == appId }) { return app }
        if let app = summaryApps.first(where: { $0.id == appId }) { return app }
        if let app = notificationApps.first(where: { $0.id == appId }) { return app }
        if let app = enabledApps.first(where: { $0.id == appId }) { return app }
        return nil
    }

    private func setLocalEnabledState(for appId: String, enabled: Bool) {
        func update(_ list: inout [OmiApp]) {
            for index in list.indices where list[index].id == appId {
                list[index].enabled = enabled
            }
        }

        update(&apps)
        update(&popularApps)
        update(&integrationApps)
        update(&chatApps)
        update(&summaryApps)
        update(&notificationApps)
        update(&enabledApps)
        if var filteredApps = categoryFilteredApps {
            update(&filteredApps)
            categoryFilteredApps = filteredApps
        }
        if !enabled && showInstalledOnly {
            apps.removeAll { $0.id == appId }
            categoryFilteredApps?.removeAll { $0.id == appId }
        }

        updateDerivedLists()
    }

    /// Update derived lists from main apps list
    private func updateDerivedLists() {
        enabledApps = apps.filter { $0.enabled }
        // Note: chatApps is populated from v2 response, but we also include enabled chat apps
        // that might not be in the original chatApps list
        let enabledChatApps = enabledApps.filter { $0.worksWithChat }
        let existingChatIds = Set(chatApps.map { $0.id })
        for app in enabledChatApps {
            if !existingChatIds.contains(app.id) {
                chatApps.append(app)
            }
        }
    }

    /// Get apps filtered by category (supports special section IDs)
    func apps(forCategory category: String) -> [OmiApp] {
        switch category {
        case "featured":
            return popularApps
        case "integrations":
            return integrationApps
        case "notifications":
            return notificationApps
        default:
            return apps.filter { $0.category == category }
        }
    }

    /// Get apps filtered by capability
    func apps(forCapability capability: String) -> [OmiApp] {
        apps.filter { $0.capabilities.contains(capability) }
    }

    /// Clear search and filters
    func clearFilters() {
        searchQuery = ""
        selectedCategory = nil
        selectedCapability = nil
        showInstalledOnly = false
        resetCategoryPagination()
    }
}
