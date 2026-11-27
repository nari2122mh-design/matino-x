import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var patchStore: PatchProjectStore
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @AppStorage(FeatureVisibility.developerModeStorageKey)
    private var developerModeEnabled = false
    @AppStorage(FeatureVisibility.categoryTabsStorageKey)
    private var categoryTabsEnabled = true
    @State private var tabNavigation: AppTabNavigationState
    /// MATINO X: bind TabView directly to AppSection (type-safe selection).
    @State private var selectedSection: AppSection = .aim
    @State private var showLogs = false

    init() {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let initialTab: Int
        if arguments.contains("--simulate-new-tab") {
            initialTab = 1
        } else if arguments.contains("--simulate-sources-tab") {
            initialTab = 2
        } else if arguments.contains("--simulate-installed-tab")
                    || arguments.contains("--simulate-patch-tab")
                    || arguments.contains("--simulate-wallpaper-tab") {
            initialTab = 3
        } else if arguments.contains("--simulate-files-tab") {
            initialTab = 4
        } else if arguments.contains("--simulate-search-tab") {
            initialTab = 5
        } else {
            initialTab = AppSection.aim.rawValue
        }
        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: initialTab))
        _selectedSection = State(
            initialValue: arguments.contains("--simulate-settings")
                ? .settings
                : (AppSection(rawValue: initialTab) ?? .aim)
        )
#else
        _tabNavigation = State(initialValue: AppTabNavigationState())
#endif
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        // MATINO X: never force a tab switch from coordinator changes. This
        // used to bounce the user back to AIM when opening MORE / a link.
        .onChange(of: selectedSection) { section in
            log("tab: selection -> \(section.rawValue)")
        }
        .onChange(of: developerModeEnabled) { _ in
            reconcileVisibleSelection()
        }
        .onChange(of: categoryTabsEnabled) { _ in
            reconcileVisibleSelection()
        }
        .onAppear {
            reconcileVisibleSelection()
        }
        .sheet(isPresented: $showLogs) { LogView() }
        .patchStorePresentation(patchStore)
        .repositoryStorePresentation(repositoryStore, patchStore: patchStore)
    }

    private var compactLayout: some View {
        TabView(selection: $selectedSection) {
            ForEach(featureVisibility.visibleSections) { section in
                sectionContent(section)
                    .tabItem {
                        CompactTabLabel(
                            title: section.displayTitle(language: language),
                            systemImage: section.systemImage
                        )
                    }
                    .tag(section)
            }
        }
        .toolbarBackground(AppTheme.consoleBackground.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(featureVisibility.visibleSections) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSection = section
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        Label(section.displayTitle(language: language), systemImage: section.systemImage)
                            .fontWeight(section == selectedSection ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        section == selectedSection
                            ? AppTheme.accent.opacity(0.14)
                            : Color.clear
                    )
                    .accessibilityAddTraits(
                        section == selectedSection ? .isSelected : []
                    )
                }
            }
            .navigationTitle("MATINO X")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            sectionContent(selectedVisibleSection)
                .id(selectedVisibleSection.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        switch section {
        case .home:
            RepositoryHomeView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .new:
            RepositoryNewView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .sources:
            RepositorySourcesView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .installed, .aim, .hologram, .skin, .misc:
            // MATINO X: the three category tabs reuse Installed as a filtered,
            // read-only list (no apply/run control is added).
            PatchProjectsView(
                categoryFilter: section.packageFilterToken,
                categoryTitle: section.categoryTabTitle,
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .settings:
            // MATINO X: Settings is now a real tab like AIM/HOLOGRAM/SKIN.
            SettingsView()
        case .more:
            MoreView()
        case .files:
            AppDataBrowserView(
                tabSession: filesTabSession,
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .search:
            RepositorySearchView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { tabNavigation.selectedTab },
            set: { newValue in
                // MATINO X: Settings is a normal tab now — select it directly.
                tabNavigation.select(newValue)
            }
        )
    }

    private var filesTabSession: Binding<FilesTabSession> {
        Binding(
            get: { tabNavigation.filesTabs },
            set: { tabNavigation.setFilesTabs($0) }
        )
    }

    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(
            developerModeEnabled: developerModeActive,
            categoryTabsEnabled: categoryTabsEnabled
        )
    }

    private var developerModeActive: Bool {
#if targetEnvironment(simulator)
        developerModeEnabled
            || ProcessInfo.processInfo.arguments.contains("--simulate-developer-mode")
            || ProcessInfo.processInfo.arguments.contains("--simulate-files-tab")
#else
        developerModeEnabled
#endif
    }

    private var selectedVisibleSection: AppSection {
        featureVisibility.isVisible(selectedSection)
            ? selectedSection
            : (featureVisibility.isVisible(.aim) ? .aim : .installed)
    }

    /// Keep the section actually bound to the TabView in sync with the
    /// (legacy) navigation state. Previously only the navigation state was
    /// reconciled, so hiding the current section could leave the UI stuck on
    /// a tab that was no longer visible.
    private func reconcileVisibleSelection() {
        tabNavigation.reconcileSelection(with: featureVisibility)
        selectedSection = selectedVisibleSection
    }

    /// MATINO X: Settings is a real tab, like AIM / HOLOGRAM. Every
    /// "Settings" button in the app switches to it instead of presenting a
    /// modal sheet, so navigation behaves consistently everywhere.
    private func openSettings() {
        selectedSection = .settings
    }

    private func openLogs() {
        showLogs = true
    }
}

private struct CompactTabLabel: View {
    let title: String
    let systemImage: String

    @ViewBuilder
    var body: some View {
        if let image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: image)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

private extension AppSection {
    var titleKey: String {
        switch self {
        case .home: return "tab.home"
        case .new: return "tab.new"
        case .sources: return "tab.sources"
        case .installed: return "tab.installed"
        case .files: return "tab.files"
        case .search: return "tab.search"
        case .aim: return "tab.aim"
        case .hologram: return "tab.hologram"
        case .skin: return "tab.skin"
        case .misc: return "MISC"
        case .more: return "MORE"
        case .settings: return "settings.title"
        }
    }

    /// MATINO X: the category tabs carry fixed labels, so they bypass the
    /// localization table (which has no entry for them).
    func displayTitle(language: AppLanguage) -> String {
        categoryTabTitle ?? language.text(titleKey)
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .new: return "clock.fill"
        case .sources: return "shippingbox.fill"
        case .installed: return "tray.full.fill"
        case .files: return "folder.fill"
        case .search: return "magnifyingglass"
        case .aim: return "scope"
        case .hologram: return "cube.transparent.fill"
        case .skin: return "tshirt.fill"
        case .misc: return "square.grid.2x2.fill"
        case .more: return "ellipsis.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
