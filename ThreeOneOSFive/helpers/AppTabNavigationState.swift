import Foundation

enum AppSection: Int, CaseIterable, Identifiable {
    case home
    case new
    case sources
    case installed
    case files
    case search
    // MATINO X: category tabs. They sit after the legacy cases so the raw
    // values of the simulator arguments keep meaning the same thing.
    case aim
    case hologram
    case skin
    case misc
    case more
    /// MATINO X: bottom-bar Settings entry. A distinct raw value keeps it out
    /// of the legacy simulator argument indices.
    case settings = 99

    var id: Int { rawValue }

    /// MATINO X: category tabs are read-only filters over Installed - they
    /// show the .3105 packages whose file name mentions the category and
    /// expose no apply/run control of their own.
    var packageFilterToken: String? {
        switch self {
        case .aim: return "aim"
        case .hologram: return "hologram"
        case .skin: return "skin"
        case .misc: return "misc"
        default: return nil
        }
    }

    /// Literal title for the category tabs. They are fixed labels, so they are
    /// not run through the localization table. nil means "use titleKey".
    var categoryTabTitle: String? {
        switch self {
        case .aim: return "AIM"
        case .hologram: return "HOLOGRAM"
        case .skin: return "SKIN"
        case .misc: return "MISC"
        case .more: return "MORE"
        default: return nil
        }
    }
}

enum WallpaperFeatureSupportPolicy {
    static func isSupported(major: Int) -> Bool {
        switch major {
        case 17, 18, 26, 27:
            return true
        default:
            return false
        }
    }
}

struct OneShotPresentationGate: Equatable {
    private(set) var hasClaimed = false

    mutating func claim() -> Bool {
        guard !hasClaimed else { return false }
        hasClaimed = true
        return true
    }
}

struct FeatureVisibility: Equatable {
    static let cleanerStorageKey = "feature.cleaner.enabled"
    static let developerModeStorageKey = "feature.developer_mode.enabled"
    /// MATINO X: the AIM / HOLOGRAM P / SKIN category tabs.
    static let categoryTabsStorageKey = "feature.category_tabs.enabled"

    let developerModeEnabled: Bool
    let categoryTabsEnabled: Bool

    init(developerModeEnabled: Bool, categoryTabsEnabled: Bool = true) {
        self.developerModeEnabled = developerModeEnabled
        self.categoryTabsEnabled = categoryTabsEnabled
    }

    var visibleSections: [AppSection] {
        AppSection.allCases.filter(isVisible)
    }

    func isVisible(_ section: AppSection) -> Bool {
        switch section {
        case .aim, .hologram, .skin, .misc, .more:
            return categoryTabsEnabled
        case .settings:
            return true
        case .installed:
            // MATINO X: Installed is replaced by the three category tabs.
            // It stays available only as the fallback when category tabs are
            // disabled via the flag, so the list is never stranded empty.
            return !categoryTabsEnabled
        case .files:
            return developerModeEnabled
        case .home, .new, .sources, .search:
            return false
        }
    }
}

struct AppTabNavigationState: Equatable {
    private(set) var selectedTab: Int
    private(set) var filesTabs: FilesTabSession

    init(
        selectedTab: Int = AppSection.aim.rawValue,
        filesNavigationPath: [FileBrowserDestination] = []
    ) {
        self.selectedTab = selectedTab
        var session = FilesTabSession()
        session.setActiveNavigationPath(filesNavigationPath)
        filesTabs = session
    }

    mutating func select(_ tab: Int) {
        selectedTab = tab
    }

    mutating func setFilesNavigationPath(_ path: [FileBrowserDestination]) {
        filesTabs.setActiveNavigationPath(path)
    }

    var filesNavigationPath: [FileBrowserDestination] {
        filesTabs.activeTab?.navigationPath ?? []
    }

    mutating func setFilesTabs(_ session: FilesTabSession) {
        filesTabs = session
    }

    mutating func reconcileSelection(with visibility: FeatureVisibility) {
        guard let selectedSection = AppSection(rawValue: selectedTab),
              visibility.isVisible(selectedSection) else {
            selectedTab = visibility.isVisible(.aim)
                ? AppSection.aim.rawValue
                : AppSection.installed.rawValue
            return
        }
    }
}

struct FileBrowserDestination: Hashable {
    let containerPath: String
    let startPath: String
    let title: String
    let bundleID: String?
}

struct FilesTabState: Identifiable, Equatable {
    let id: UUID
    var customTitle: String?
    var navigationPath: [FileBrowserDestination]

    func displayTitle(defaultTitle: String) -> String {
        customTitle ?? navigationPath.last?.title ?? defaultTitle
    }

    var currentPath: String? {
        navigationPath.last?.startPath
    }
}

struct FilesTabSession: Equatable {
    private(set) var tabs: [FilesTabState]
    private(set) var selectedTabID: UUID

    init(initialTabID: UUID = UUID()) {
        tabs = [FilesTabState(id: initialTabID, customTitle: nil, navigationPath: [])]
        selectedTabID = initialTabID
    }

    var activeTab: FilesTabState? {
        tabs.first { $0.id == selectedTabID }
    }

    func navigationPath(for id: UUID) -> [FileBrowserDestination] {
        tabs.first { $0.id == id }?.navigationPath ?? []
    }

    mutating func setNavigationPath(_ path: [FileBrowserDestination], for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].navigationPath = path
    }

    mutating func setActiveNavigationPath(_ path: [FileBrowserDestination]) {
        setNavigationPath(path, for: selectedTabID)
    }

    mutating func openTab(
        id: UUID = UUID(),
        navigationPath: [FileBrowserDestination] = []
    ) {
        tabs.append(FilesTabState(id: id, customTitle: nil, navigationPath: navigationPath))
        selectedTabID = id
    }

    mutating func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    mutating func renameTab(_ id: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    }

    mutating func closeTab(_ id: UUID, replacementID: UUID = UUID()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            tabs = [FilesTabState(id: replacementID, customTitle: nil, navigationPath: [])]
            selectedTabID = replacementID
            return
        }

        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    mutating func closeOtherTabs(keeping id: UUID) {
        guard let keptTab = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keptTab]
        selectedTabID = id
    }
}
