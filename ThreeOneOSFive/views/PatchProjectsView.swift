import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import AVFoundation

/// MATINO X: sound URL from embedded media (no separate bundle files).
private func appSoundURL(_ name: String) -> URL? {
    switch name {
    case "applied": return EmbeddedMedia.url(EmbeddedMedia.applied, filename: "applied.m4a")
    case "restored": return EmbeddedMedia.url(EmbeddedMedia.restored, filename: "restored.m4a")
    case "tap": return EmbeddedMedia.url(EmbeddedMedia.tap, filename: "tap.m4a")
    default: return nil
    }
}

private enum PatchPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "3105") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
    static let copiesSelectedDocument = true
}

private enum WallpaperPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "tendies") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
}

/// MATINO X: switches that trim the Installed screen down to a plain list.
private enum InstalledScreenLayout {
    /// The "New Patch" call-to-action inside the empty state.
    static let showsNewPatchButton = false
    /// The "Utilities / Cleaner" block at the bottom of the list.
    static let showsUtilitiesSection = false
    /// The "Nothing Installed" empty-state card.
    static let showsEmptyState = false
    /// The search field above the list.
    static let showsSearchField = false
    /// The "Open Logs" item in the settings menu.
    static let showsOpenLogs = false
    /// Detail-screen rows: Privacy, Password, Export .3105.
    static let showsPrivacyRow = false
    static let showsPasswordSection = false
    static let showsExportButton = false
    /// List-row extras: kind badge (.3105) and workspace-item count.
    static let showsKindBadge = false
    static let showsRowDetail = false
    /// Swipe-to-delete in the list. Files are managed from the site only.
    static let allowsRowDeletion = false
    /// Detail screen: Information and Workspace sections.
    static let showsDetailInfo = false
    static let showsDetailWorkspace = false
    /// Game-variant segmented selector (FREE FIRE NORMAL / FREE FIRE MAX).
    static let showsGameVariantSelector = true
    /// Static "SELECT PATCH" label on the right of each patch row.
    static let showsSelectPatchLabel = false
    /// Reference-style list: plain text rows, no cards/icons.
    static let usesReferenceListStyle = true
}

struct PatchProjectsView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var store: PatchProjectStore
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @State private var showCreate = false
    @State private var showImporter = false
    @State private var showWallpaperImporter = false
    @State private var showCleaner = false
    /// MATINO X: the green bell at the top right opens the notes page.
    @State private var showNotes = false
    @State private var searchText = ""
    /// MATINO X: read-only display filter shown in the category tabs.
    /// 0 = "For You" (curated, non-MAX), 1 = "All Packages" (everything).
    @State private var gameVariant: Int? = 0
    @State private var wallpaperPackages: [WallpaperStagedPackage] = []
    @State private var wallpaperImportFeedback: WallpaperImportFeedback?
    @State private var wallpaperPendingDeletion: WallpaperStagedPackage?
    @State private var isImportingWallpapers = false
    /// MATINO X: true while an inline INJECT from the list is running.
    @State private var isInjecting = false
    /// MATINO X: keeps the confirmation sound alive while it plays.
    @State private var injectAudioPlayer: AVAudioPlayer?
    /// MATINO X: error surfaced when an inline INJECT/INJECTED fails.
    @State private var injectFeedback: InjectFeedback?
    @State private var showSimulatedWallpaperDetail = false
    @State private var simulatedWallpaperDetailGate = OneShotPresentationGate()
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void
    /// MATINO X: when set, the list only shows .3105 packages whose file name
    /// contains this token (the AIM / HOLOGRAM P / SKIN category tabs).
    let categoryFilter: String?
    /// Navigation title for a category tab (literal label); nil keeps
    /// the localized "Installed" title.
    let categoryTitle: String?

    private var filteredItems: [PatchLibraryItem] {
        let base: [PatchLibraryItem]
        if let token = categoryFilter {
            // MATINO X: match only the category prefix. A file named
            // "HOLOGRAM_AIM_... " belongs to HOLOGRAM, not AIM, so checking
            // anywhere in the name would leak it into other category tabs.
            base = store.items.filter {
                $0.packageURL.lastPathComponent
                    .lowercased()
                    .hasPrefix(token.lowercased() + "_")
            }
        } else {
            base = store.items
        }
        // MATINO X: game-variant filter uses an explicit prefix token. A file
        // in MAX never appears in NORMAL: after the optional category prefix,
        // the name starts with either MAX_ or NORMAL_. Files with no token are
        // treated as NORMAL so they are never shown as MAX.
        let variantFiltered: [PatchLibraryItem]
        if let variant = gameVariant, InstalledScreenLayout.showsGameVariantSelector {
            variantFiltered = base.filter { item in
                let name = item.packageURL.lastPathComponent.lowercased()
                let afterCategory = categoryFilter.map { token in
                    name.hasPrefix(token.lowercased() + "_")
                        ? String(name.dropFirst(token.count + 1))
                        : name
                } ?? name
                let isMax = afterCategory.hasPrefix("max_")
                return variant == 1 ? isMax : !isMax
            }
        } else {
            variantFiltered = base
        }
        // MATINO X: patches whose file name contains ANTENA / ANTENNA are
        // listed at the bottom. All other patches keep their relative order
        // and appear first.
        func isAntena(_ item: PatchLibraryItem) -> Bool {
            let name = item.packageURL.lastPathComponent.lowercased()
            return name.contains("antena") || name.contains("antenna")
        }
        let ordered = variantFiltered.filter { !isAntena($0) }
            + variantFiltered.filter { isAntena($0) }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { item in
            if item.packageURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard let project = item.project else { return false }
            if project.name.localizedCaseInsensitiveContains(query)
                || project.author.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard item.canInspectContents else { return false }
            return project.allBundleIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
                || project.directories.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                }
                || project.rules.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                        || $0.replacementFilename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var filteredWallpaperPackages: [WallpaperStagedPackage] {
        // Category tabs are about .3105 packages only.
        guard categoryFilter == nil else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return wallpaperPackages }
        return wallpaperPackages.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasLocalContent: Bool {
        if categoryFilter != nil { return !store.items.isEmpty }
        return !store.items.isEmpty || !wallpaperPackages.isEmpty
    }

    private var hasSearchResults: Bool {
        !filteredItems.isEmpty || !filteredWallpaperPackages.isEmpty
    }

    init(
        categoryFilter: String? = nil,
        categoryTitle: String? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        self.categoryFilter = categoryFilter
        self.categoryTitle = categoryTitle
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
#if targetEnvironment(simulator)
        _showCreate = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--simulate-patch-editor")
        )
#endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MATINO X: Settings moved to the bottom tab bar; the top
                // gear button is hidden (see settingsGearButton).
                if InstalledScreenLayout.showsSearchField {
                    AppSearchField(
                        text: $searchText,
                        prompt: language.text("installed.search"),
                        clearLabel: language.text("common.clear")
                    )
                    Divider()
                }
                List {
                    if categoryFilter != nil {
                        categoryHeaderCard
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 2, trailing: 18))
                    }
                    if InstalledScreenLayout.showsGameVariantSelector && categoryFilter != nil {
                        gameVariantSelector
                            .listRowSeparator(.hidden)
                    }
                    if !hasLocalContent && (store.isBusy || isImportingWallpapers) {
                        loadingState
                            .listRowSeparator(.hidden)
                    } else if !hasLocalContent && categoryFilter == nil {
                        if InstalledScreenLayout.showsEmptyState {
                            emptyState
                                .listRowSeparator(.hidden)
                        } else {
                            EmptyView()
                                .listRowSeparator(.hidden)
                        }
                    } else if !hasSearchResults && !store.isBusy {
                        searchEmptyState
                            .listRowSeparator(.hidden)
                    } else {
                        if !filteredItems.isEmpty {
                            Section {
                                // MATINO X: header row with the active variant
                                // on the left and a static SELECT PATCH label.
                                if InstalledScreenLayout.showsGameVariantSelector {
                                    HStack {
                                        Label(
                                            gameVariant == 1 ? "FF MAX" : "FF NORMAL",
                                            systemImage: "bolt.fill"
                                        )
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.primary)
                                        Spacer()
                                        Text("SELECT PATCH")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .listRowSeparator(.hidden)
                                }
                                // MATINO X: swipe-to-delete is disabled; files
                                // are managed from the site only.
                                if InstalledScreenLayout.allowsRowDeletion {
                                    ForEach(filteredItems) { item in
                                        itemRow(item)
                                    }
                                    .onDelete { offsets in
                                        offsets.map { filteredItems[$0] }.forEach(store.delete)
                                    }
                                } else {
                                    ForEach(filteredItems) { item in
                                        itemRow(item)
                                    }
                                }
                            }
                        }
                        if !filteredWallpaperPackages.isEmpty {
                            Section(language.text("tab.wallpapers")) {
                                ForEach(filteredWallpaperPackages) { package in
                                    NavigationLink {
                                        InstalledWallpaperPackageDetailView(
                                            package: package,
                                            onApplied: reloadWallpaperPackages
                                        )
                                    } label: {
                                        wallpaperRow(package)
                                    }
                                    .swipeActions(
                                        edge: .trailing,
                                        allowsFullSwipe: false
                                    ) {
                                        Button(role: .destructive) {
                                            wallpaperPendingDeletion = package
                                        } label: {
                                            Label(
                                                language.text("common.delete"),
                                                systemImage: "trash"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if InstalledScreenLayout.showsUtilitiesSection, cleanerEnabled {
                        Section(language.text("repository.utilities")) {
                            cleanerRow
                        }
                    }
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
            }
            .navigationTitle(categoryFilter == nil ? language.text("tab.installed") : "")
            .navigationBarTitleDisplayMode(.inline)
            // MATINO X: green bell, top right — opens the notes written from
            // the secure console (BundledFiles/windows.json).
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    notesBellButton
                }
            }
            .sheet(isPresented: $showNotes) {
                MatinoNotesView()
            }
            .sheet(isPresented: $showImporter) {
                FileDocumentPicker(
                    allowedContentTypes: PatchPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: PatchPackagePickerPolicy.copiesSelectedDocument,
                    allowsMultipleSelection: false,
                    onSelection: { result in
                        showImporter = false
                        if case .success(let urls) = result, let url = urls.first {
                            store.importPackage(at: url)
                        }
                    },
                    onCancel: {
                        showImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showCreate) {
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false
                ) { project, password in
                    store.create(project: project, password: password)
                }
            }
            .sheet(isPresented: $showCleaner) {
                CleanerView()
            }
            .sheet(item: $draftCoordinator.request) { request in
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false,
                    initialDraft: request.draft
                ) { project, password in
                    store.create(project: project, password: password)
                    draftCoordinator.clear()
                }
            }
            .sheet(isPresented: $showWallpaperImporter) {
                FileDocumentPicker(
                    allowedContentTypes: WallpaperPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: true,
                    allowsMultipleSelection: true,
                    onSelection: { result in
                        showWallpaperImporter = false
                        if case .success(let urls) = result, !urls.isEmpty {
                            importWallpaperPackages(urls)
                        }
                    },
                    onCancel: {
                        showWallpaperImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .alert(item: $wallpaperImportFeedback) { feedback in
                Alert(
                    title: Text(language.text(feedback.titleKey)),
                    message: Text(feedback.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
            .alert(item: $injectFeedback) { feedback in
                Alert(
                    title: Text(language.text(feedback.titleKey)),
                    message: Text(feedback.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
            .alert(item: $wallpaperPendingDeletion) { package in
                Alert(
                    title: Text(language.text("wallpaper.delete_title")),
                    message: Text(language.text(
                        "wallpaper.delete_message",
                        package.displayName
                    )),
                    primaryButton: .destructive(
                        Text(language.text("common.delete"))
                    ) {
                        deleteWallpaperPackage(package)
                    },
                    secondaryButton: .cancel(Text(language.text("common.cancel")))
                )
            }
            .onAppear {
                reloadWallpaperPackages()
                consumeExternalImport()
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains(
                    "--simulate-wallpaper-detail"
                ), !wallpaperPackages.isEmpty,
                   simulatedWallpaperDetailGate.claim() {
                    DispatchQueue.main.async {
                        showSimulatedWallpaperDetail = true
                    }
                }
#endif
            }
            .navigationDestination(isPresented: $showSimulatedWallpaperDetail) {
                if let package = wallpaperPackages.first {
                    InstalledWallpaperPackageDetailView(
                        package: package,
                        onApplied: reloadWallpaperPackages
                    )
                }
            }
            .onChange(of: draftCoordinator.importRequest?.id) { _ in
                consumeExternalImport()
            }
            .onChange(of: scenePhase) { phase in
                // MATINO X: coming back to the app re-checks the repository,
                // so site-side additions and deletions show up immediately.
                if phase == .active {
                    store.refreshFromRepository()
                }
            }
            // MATINO X: poll while the screen is open so a file added or
            // removed on the site appears/disappears within seconds, with no
            // need to leave and reopen the app. Conditional ETag requests keep
            // this cheap. Only poll when active.
            .onReceive(
                Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            ) { _ in
                if scenePhase == .active { store.refreshFromRepository() }
            }
        }
    }

    /// MATINO X: read-only two-option filter (no apply/run). Selecting an
    /// option only narrows which .3105 packages are listed in this tab.
    /// Styled as a segmented control with an outer track, matching the design.
    private var gameVariantSelector: some View {
        HStack(spacing: 0) {
            variantButton(title: "FREE FIRE", subtitle: "NORMAL", value: 0)
            variantButton(title: "FREE FIRE MAX", subtitle: "MAX", value: 1)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.consoleBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
        }
        .padding(.vertical, 4)
    }

    /// MATINO X: category header card shown at the top of the AIM /
    /// HOLOGRAM / SKIN tabs - icon tile, bold title, subtitle.
    private var categoryHeaderCard: some View {
        let title = (categoryTitle ?? "AIM").uppercased()
        return HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: categoryHeaderSymbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(.primary)
                Text("ONLINE \(title) PATCHES")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.consoleBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .padding(.vertical, 4)
    }

    private var categoryHeaderSymbol: String {
        switch (categoryFilter ?? "").lowercased() {
        case "hologram": return "cube.transparent.fill"
        case "skin": return "tshirt.fill"
        default: return "scope"
        }
    }

    private func variantButton(title: String, subtitle: String, value: Int) -> some View {
        let selected = gameVariant == value
        return Button {
            // MATINO X: keep exactly one variant selected. Tapping twice must
            // never clear the filter, otherwise MAX and NORMAL files mix.
            withAnimation(.easeInOut(duration: 0.15)) {
                gameVariant = value
            }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var settingsGearButton: some View {
        Menu {
            Button(action: onOpenSettings) {
                Label(
                    language.text("settings.title"),
                    systemImage: "gearshape"
                )
            }
            // MATINO X: Open Logs is hidden behind a flag.
            if InstalledScreenLayout.showsOpenLogs {
                Button(action: onOpenLogs) {
                    Label(
                        language.text("accessibility.open_logs"),
                        systemImage: "apple.terminal"
                    )
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 32, height: 32)
                .background(AppTheme.consoleBackground, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
                }
        }
        .accessibilityLabel(language.text("accessibility.open_settings"))
    }

    /// MATINO X: green bell button in the navigation bar (top right).
    private var notesBellButton: some View {
        Button {
            showNotes = true
        } label: {
            Image(systemName: "bell.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.green)
                .frame(width: 32, height: 32)
                .background(AppTheme.consoleBackground, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.green.opacity(0.55), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle().strokeBorder(Color.black, lineWidth: 1.5)
                        }
                        .offset(x: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notes from the site")
    }

    private func consumeExternalImport() {
        guard let request = draftCoordinator.importRequest else { return }
        draftCoordinator.clearImport()
        store.importPackage(from: request.source)
    }

    private func wallpaperRow(_ package: WallpaperStagedPackage) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: wallpaperSymbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                InstalledContentKindBadge(kind: .wallpaper, language: language)
                Text(language.text(
                    "wallpaper.package_summary",
                    Int64(package.payload.descriptors.count),
                    ByteCountFormatter.string(
                        fromByteCount: package.payload.totalBytes,
                        countStyle: .file
                    )
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var cleanerRow: some View {
        Button {
            showCleaner = true
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("tab.cleaner"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(language.text("repository.cleaner_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var wallpaperSymbol: String {
        if #available(iOS 18.0, *) {
            return "photo.on.rectangle.angled.fill"
        }
        return "photo.fill.on.rectangle.fill"
    }

    private func reloadWallpaperPackages() {
        wallpaperPackages = WallpaperPackageStore.packages()
    }

    private func deleteWallpaperPackage(_ package: WallpaperStagedPackage) {
        do {
            try WallpaperPackageStore.delete(package)
            reloadWallpaperPackages()
        } catch {
            wallpaperImportFeedback = WallpaperImportFeedback(
                titleKey: "wallpaper.operation_failed",
                message: wallpaperErrorMessage(error)
            )
        }
    }

    private func importWallpaperPackages(_ urls: [URL]) {
        guard !isImportingWallpapers else { return }
        isImportingWallpapers = true
        DispatchQueue.global(qos: .userInitiated).async {
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try WallpaperPackageStore.importPackage(from: url)
                    imported += 1
                    log("wallpaper: staged \(url.lastPathComponent)")
                } catch {
                    failures.append(
                        "\(url.lastPathComponent): \(wallpaperErrorMessage(error))"
                    )
                    log("wallpaper: import rejected \(url.lastPathComponent)")
                }
            }
            DispatchQueue.main.async {
                isImportingWallpapers = false
                reloadWallpaperPackages()
                wallpaperImportFeedback = WallpaperImportFeedback(
                    titleKey: failures.isEmpty
                        ? "wallpaper.import_done_title"
                        : "wallpaper.import_result_title",
                    message: failures.isEmpty
                        ? language.text(
                            "wallpaper.import_done_message",
                            Int64(imported)
                        )
                        : failures.joined(separator: "\n")
                )
            }
        }
    }

    private func wallpaperErrorMessage(_ error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }

    @ViewBuilder
    private func itemRow(_ item: PatchLibraryItem) -> some View {
        if item.isLocked {
            Button { store.requestUnlock(for: item) } label: {
                PatchProjectRow(item: item, language: language)
            }
            .buttonStyle(.plain)
        } else {
            // MATINO X: detail screen is hidden - the row only hosts the
            // inline INJECT / INJECTED button, everything else lives here.
            HStack(alignment: .center, spacing: 12) {
                PatchProjectRow(item: item, language: language)
                    .frame(maxWidth: .infinity, alignment: .leading)
                injectButton(for: item)
            }
        }
    }

    /// MATINO X: compact INJECT / INJECTED button on the right of every
    /// patch row. INJECT applies the patch directly; INJECTED reverts it
    /// back to the original files once a receipt exists.
    private func injectButton(for item: PatchLibraryItem) -> some View {
        let receipt = DevicePatchService.latestReceipt(projectID: item.id)
        return Button {
            guard !isInjecting else { return }
            if let receipt {
                revert(receipt)
            } else {
                inject(item)
            }
        } label: {
            Text(receipt != nil ? "INJECTED" : "INJECT")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(AppTheme.consoleBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isInjecting)
        .accessibilityLabel(receipt != nil ? "INJECTED" : "INJECT")
    }

    /// MATINO X: applies the patch from the list without opening detail.
    /// Waits for the launch-time load/repository sync to settle, retries a
    /// transient failure, and surfaces an error instead of failing silently.
    private func inject(_ item: PatchLibraryItem) {
        guard item.project != nil, !isInjecting else { return }
        let applyErrorFallback = language.text("patch.error.apply")
        isInjecting = true
        Task.detached(priority: .userInitiated) {
            // Launch window: the store is still loading/mirroring the repo,
            // so containers and the workspace may not be ready yet.
            var waited = 0
            while (await MainActor.run { store.isBusy }) && waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            var lastError: Error?
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                // Re-read the item on the main actor: the store may have
                // reloaded it, and its @Published state must not be read from
                // this detached background task.
                let fresh = await MainActor.run {
                    store.items.first(where: { $0.id == item.id })
                }
                guard let fresh, let project = fresh.project else { break }
                do {
                    let resolved = fresh.summary.schemaVersion >= 2 && fresh.canInspectContents
                        ? try PatchProjectLibrary.synchronizeWorkspace(item: fresh)
                        : project
                    _ = try DevicePatchService.apply(project: resolved)
                    await MainActor.run {
                        isInjecting = false
                        store.reload()
                        Self.playInjectSound(named: "applied", player: &injectAudioPlayer)
                    }
                    return
                } catch {
                    lastError = error
                }
            }
            await MainActor.run {
                isInjecting = false
                store.reload()
                injectFeedback = InjectFeedback(
                    titleKey: "common.failed",
                    message: lastError.map { "\($0)" } ?? applyErrorFallback
                )
            }
        }
    }

    /// MATINO X: bundled confirmation sound for a list-level INJECT.
    private static func playInjectSound(named name: String, player: inout AVAudioPlayer?) {
        guard let url = appSoundURL(name) else { return }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.prepareToPlay()
            audio.play()
            player = audio
        } catch {
            // Audio is cosmetic only; never surface an error for it.
        }
    }

    /// MATINO X: INJECTED state - restores the original files for this
    /// receipt so the row falls back to the INJECT state. Waits for the
    /// launch-time load to settle and retries once, mirroring inject().
    private func revert(_ receipt: PatchTransactionReceipt) {
        guard !isInjecting else { return }
        let restoreErrorFallback = language.text("patch.error.restore")
        isInjecting = true
        Task.detached(priority: .userInitiated) {
            var waited = 0
            while (await MainActor.run { store.isBusy }) && waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            var lastError: Error?
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                do {
                    let inspection = try DevicePatchService.inspectRestore(receipt: receipt)
                    try DevicePatchService.restore(
                        receipt: receipt,
                        allowChangedTargets: !inspection.changedTargets.isEmpty
                    )
                    await MainActor.run {
                        isInjecting = false
                        store.reload()
                        Self.playInjectSound(named: "restored", player: &injectAudioPlayer)
                    }
                    return
                } catch {
                    lastError = error
                }
            }
            await MainActor.run {
                isInjecting = false
                store.reload()
                injectFeedback = InjectFeedback(
                    titleKey: "common.failed",
                    message: lastError.map { "\($0)" } ?? restoreErrorFallback
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("installed.empty_title"))
                .font(.headline)
            Text(language.text("installed.empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if InstalledScreenLayout.showsNewPatchButton {
                Button(language.text("patch.new")) { showCreate = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(language.text("installed.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("patch.search_empty"))
                .font(.headline)
            Text(language.text("patch.search_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

private struct WallpaperImportFeedback: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

/// MATINO X: alert payload for a failed inline INJECT / INJECTED action.
private struct InjectFeedback: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

private struct PatchProjectRow: View {
    let item: PatchLibraryItem
    let language: AppLanguage
    @State private var metadataVersion = 0

    var body: some View {
        Group {
            if InstalledScreenLayout.usesReferenceListStyle {
                referenceRow
            } else {
                classicRow
            }
        }
        // MATINO X: redraw when site-side comments/names are re-synced so the
        // changed text appears immediately, not only after a full app restart.
        .onReceive(NotificationCenter.default.publisher(
            for: .matinoMetadataUpdated
        )) { _ in metadataVersion += 1 }
    }

    /// MATINO X: reference-style row - plain text, no card, no icon:
    ///   AIM DRAG
    ///   FREE FIRE • NORMAL
    ///   (comment from the site, if any)
    private var referenceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PatchProjectStore.displayName(for: item.packageURL.lastPathComponent)
                 ?? item.project?.name
                 ?? language.text("patch.locked_project"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
            Text(variantLine)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if let comment = PatchProjectStore.comment(for: item.packageURL.lastPathComponent),
               !comment.isEmpty {
                Text(comment)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
    }

    private var variantLine: String {
        let name = item.packageURL.lastPathComponent.lowercased()
        return name.contains("max") ? "FREE FIRE • MAX" : "FREE FIRE • NORMAL"
    }

    private var classicRow: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: item.isLocked ? "lock.doc.fill" : "shippingbox.fill")
            VStack(alignment: .leading, spacing: 3) {
                // MATINO X: show the name chosen on the site when available.
                Text(PatchProjectStore.displayName(for: item.packageURL.lastPathComponent)
                     ?? item.project?.name
                     ?? language.text("patch.locked_project"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // MATINO X: comment from the site, shown under the file name.
                if let comment = PatchProjectStore.comment(for: item.packageURL.lastPathComponent),
                   !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // MATINO X: show the full description, never truncate it.
                }
                if InstalledScreenLayout.showsKindBadge {
                    InstalledContentKindBadge(kind: .patch, language: language)
                }
                if let author = item.project?.author, !author.isEmpty {
                    Text(language.text("patch.by_author", author))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if InstalledScreenLayout.showsRowDetail {
                    Text(rowDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // MATINO X: static label only - no apply/run behaviour.
            if InstalledScreenLayout.showsSelectPatchLabel {
                Text("SELECT PATCH")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if item.summary.isPasswordProtected {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(language.text("patch.password_protected"))
            }
            if item.project?.isPrivate == true {
                Image(systemName: "eye.slash.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel(language.text("patch.private"))
            }
        }
        .padding(.vertical, 4)
    }

    private var rowDetail: String {
        if item.isLocked {
            return language.text("patch.tap_to_unlock")
        }
        if item.project?.isPrivate == true, !item.isAuthorCopy {
            return language.text("patch.private_received")
        }
        return language.text(
            item.summary.schemaVersion >= 2
                ? "patch.workspace_items_count"
                : "patch.rules_count",
            Int64((item.project?.rules.count ?? 0) + (item.project?.directories.count ?? 0))
        )
    }
}

private enum InstalledContentKind {
    case patch
    case wallpaper

    var localizationKey: String {
        switch self {
        case .patch: return "installed.kind.patch"
        case .wallpaper: return "installed.kind.wallpaper"
        }
    }

    var systemImage: String {
        switch self {
        case .patch: return "shippingbox.fill"
        case .wallpaper: return "photo.fill"
        }
    }
}

private struct InstalledContentKindBadge: View {
    let kind: InstalledContentKind
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
            Text(language.text(kind.localizationKey))
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AppTheme.accent.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}

struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    let request: PatchPasswordRequest
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.password"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in
                            store.clearUnlockError()
                        }
                    if let errorKey = store.unlockErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if let origin = request.origin {
                        Text(language.text(
                            "patch.password_repo_contact",
                            origin.repositoryName
                        ))
                    } else {
                        Text(language.text("patch.password_once_message"))
                    }
                }
            }
            .navigationTitle(language.text("patch.unlock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.unlock"), action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

private struct PatchStorePresentationModifier: ViewModifier {
    @ObservedObject var store: PatchProjectStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.passwordRequest, onDismiss: store.cancelUnlock) { request in
                PatchUnlockView(store: store, request: request)
            }
    }
}

extension View {
    func patchStorePresentation(_ store: PatchProjectStore) -> some View {
        modifier(PatchStorePresentationModifier(store: store))
    }
}

private struct PatchProjectDetailView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showEditor = false
    @State private var editingRule: PatchRule?
    @State private var showApplyConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var showChangedRestoreConfirmation = false
    @State private var showResetConfirmation = false
    @State private var restoreChangedPaths: [String] = []
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?
    @State private var shareRequest: PatchShareRequest?
    /// MATINO X: audio played instead of the "Done" alert after a successful apply.
    @State private var successAudioPlayer: AVAudioPlayer?

    private var item: PatchLibraryItem? {
        store.items.first(where: { $0.id == projectID })
    }

    private var receipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: projectID)
    }

    private var isWorkspaceProject: Bool {
        (item?.summary.schemaVersion ?? 1) >= 2
    }

    var body: some View {
        List {
            if let item, let project = item.project {
                if InstalledScreenLayout.showsDetailInfo {
                    Section(language.text("patch.information")) {
                        if !project.author.isEmpty {
                            patchInfoRow(
                                label: language.text("patch.author"),
                                value: project.author
                            )
                        }
                        if InstalledScreenLayout.showsPrivacyRow {
                            patchInfoRow(label: language.text("patch.privacy")) {
                                Label(
                                    language.text(project.isPrivate
                                        ? "patch.private"
                                        : "patch.public"),
                                    systemImage: project.isPrivate
                                        ? "eye.slash.fill"
                                        : "eye"
                                )
                                .foregroundStyle(project.isPrivate ? AppTheme.accent : Color.secondary)
                            }
                        }
                        if let origin = item.origin {
                            patchInfoRow(
                                label: language.text("repository.source"),
                                value: origin.repositoryName
                            )
                        }
                    }
                }

                if project.isPrivate && !item.canInspectContents {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                            Text(language.text("patch.private_hidden_title"))
                                .font(.headline)
                            Text(language.text("patch.private_hidden_message"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else if isWorkspaceProject && !InstalledScreenLayout.showsDetailWorkspace {
                    // MATINO X: Workspace hidden - nothing rendered here.
                    EmptyView()
                } else if isWorkspaceProject {
                    Section {
                        ForEach(project.allBundleIdentifiers, id: \.self) { bundleID in
                            Label {
                                Text(bundleID)
                                    .font(.subheadline.monospaced())
                            } icon: {
                                Image(systemName: "app.dashed")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        LabeledContent(language.text("patch.files")) {
                            Text("\(project.rules.count)")
                        }
                        LabeledContent(language.text("patch.folders")) {
                            Text("\(project.directories.count)")
                        }
                        if let workspaceURL = item.workspaceURL {
                            NavigationLink {
                                FileBrowserView(
                                    containerPath: workspaceURL.path,
                                    title: project.name,
                                    bundleID: nil
                                )
                            } label: {
                                Label(
                                    language.text("patch.open_workspace"),
                                    systemImage: "folder"
                                )
                            }
                        }
                    } header: {
                        Text(language.text("patch.workspace"))
                    } footer: {
                        Text(language.text("patch.workspace_detail_footer"))
                    }
                } else {
                    Section {
                        ForEach(project.rules) { rule in
                            Button {
                                editingRule = rule
                            } label: {
                                HStack(spacing: 10) {
                                    ruleSummary(rule)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(language.text("patch.edit_rule_hint"))
                        }
                    } header: {
                        Text(language.text("patch.rules"))
                    } footer: {
                        Text(language.text("patch.legacy_footer"))
                    }
                }

                if InstalledScreenLayout.showsPasswordSection {
                    Section(language.text("patch.password")) {
                        HStack(spacing: 12) {
                            Image(systemName: item.summary.isPasswordProtected ? "lock.fill" : "lock.open")
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 24)
                            Text(language.text(item.summary.isPasswordProtected
                                ? "patch.password_locked"
                                : "patch.no_password"))
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        if receipt != nil {
                            Button(role: .destructive) {
                                showRestoreConfirmation = true
                            } label: {
                                actionLabel("INJECTED", systemImage: "arrow.right.circle.fill")
                            }
                            .disabled(isWorking)
                        } else {
                            Button {
                                showApplyConfirmation = true
                            } label: {
                                actionLabel("patch.apply", systemImage: "arrow.right.circle.fill")
                            }
                            .disabled(isWorking)
                        }
                    }

                } footer: {
                    Text(language.text("patch.apply_footer"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item?.project?.name ?? language.text("patch.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isWorking {
                    ProgressView()
                } else if !isWorkspaceProject, item?.canInspectContents == true {
                    Button(language.text("patch.edit")) { showEditor = true }
                        .disabled(item?.project == nil)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let item, let project = item.project {
                PatchProjectEditorView(
                    existingProject: project,
                    passwordIsProtected: item.summary.isPasswordProtected
                ) { updatedProject, _ in
                    store.update(project: updatedProject)
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            PatchRuleEditorView(rule: rule) { updatedRule in
                updateRule(updatedRule)
            }
        }
        .confirmationDialog(
            language.text("patch.apply_confirm_title"),
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.apply")) { apply() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.apply_confirm_message"))
        }
        .confirmationDialog(
            language.text("patch.restore_confirm_title"),
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore"), role: .destructive) { prepareRestore() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.restore_confirm_message"))
        }
        .confirmationDialog(
            language.text("patch.restore_changed_title"),
            isPresented: $showChangedRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore_changed_action"), role: .destructive) {
                restore(allowChangedTargets: true)
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(changedRestoreMessage)
        }
        .confirmationDialog(
            language.text("patch.reset_confirm_title"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.reset"), role: .destructive) { resetToAppliedState() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.reset_confirm_message"))
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .sheet(item: $shareRequest) { request in
            PatchActivityView(items: [request.url])
                .ignoresSafeArea()
        }
    }

    private func actionLabel(_ key: String, systemImage: String) -> some View {
        Label(language.text(key), systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func patchInfoRow(
        label: String,
        value: String
    ) -> some View {
        patchInfoRow(label: label) {
            Text(value)
                .foregroundStyle(.primary)
        }
    }

    private func patchInfoRow<Content: View>(
        label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }

    private func ruleSummary(_ rule: PatchRule) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.bundleID)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(rule.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(rule.replacementFilename, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func updateRule(_ updatedRule: PatchRule) {
        guard var project = item?.project,
              let index = project.rules.firstIndex(where: { $0.id == updatedRule.id }) else {
            return
        }
        project.rules[index] = updatedRule
        project.updatedAt = Date()
        do {
            try PatchPackageCodec.validate(project)
            store.update(project: project)
        } catch let error as PatchPackageError {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: error.localizationKey,
                messageArgument: error.localizationArgument
            )
        } catch {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: "patch.error.invalid_project"
            )
        }
    }

    /// MATINO X: play the bundled confirmation sound for a finished action
    /// (in place of the old "Done" alerts).
    private static func playSound(named name: String, player: inout AVAudioPlayer?) {
        guard let url = appSoundURL(name) else { return }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.prepareToPlay()
            audio.play()
            player = audio
        } catch {
            // Audio is cosmetic only; never surface an error for it.
        }
    }

    private func apply() {
        guard let item, let baseProject = item.project else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let project = item.summary.schemaVersion >= 2 && item.canInspectContents
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : baseProject
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    Self.playSound(named: "applied", player: &successAudioPlayer)
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func prepareExport() {
        guard let item else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                if item.summary.schemaVersion >= 2, item.canInspectContents {
                    _ = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                }
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    shareRequest = PatchShareRequest(url: item.packageURL)
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.invalid_project"
                    )
                }
            }
        }
    }

    private var changedRestoreMessage: String {
        guard item?.project?.isPrivate != true || item?.isAuthorCopy == true else {
            return language.text(
                "patch.restore_changed_private_message",
                Int64(restoreChangedPaths.count)
            )
        }
        var visiblePaths = restoreChangedPaths.prefix(5).joined(separator: "\n")
        if restoreChangedPaths.count > 5 {
            visiblePaths += "\n…"
        }
        return language.text(
            "patch.restore_changed_message",
            Int64(restoreChangedPaths.count),
            visiblePaths
        )
    }

    private func prepareRestore() {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let inspection = try DevicePatchService.inspectRestore(receipt: receipt)
                if inspection.changedTargets.isEmpty {
                    try DevicePatchService.restore(receipt: receipt)
                    await MainActor.run {
                        isWorking = false
                        Self.playSound(named: "restored", player: &successAudioPlayer)
                    }
                } else {
                    await MainActor.run {
                        isWorking = false
                        restoreChangedPaths = inspection.changedTargets.map(\.displayPath)
                        showChangedRestoreConfirmation = true
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.restore"
                    )
                }
            }
        }
    }

    private func restore(allowChangedTargets: Bool) {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(
                    receipt: receipt,
                    allowChangedTargets: allowChangedTargets
                )
                await MainActor.run {
                    isWorking = false
                    Self.playSound(named: "restored", player: &successAudioPlayer)
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }

    private func resetToAppliedState() {
        guard let receipt, let project = item?.project else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.resetToAppliedState(
                    receipt: receipt,
                    project: project
                )
                await MainActor.run {
                    isWorking = false
                    Self.playSound(named: "applied", player: &successAudioPlayer)
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.reset"
                    )
                }
            }
        }
    }

    private func privateErrorKey(for error: PatchPackageError) -> String {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationKey
        }
        return "patch.error.private_operation"
    }

    private func privateErrorArgument(for error: PatchPackageError) -> String? {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationArgument
        }
        return nil
    }
}

private struct PatchShareRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PatchActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}


// MARK: - Green bell page: notes written from the secure console

/// One entry of BundledFiles/windows.json, exactly as edited on the site.
struct MatinoSiteNote: Identifiable, Decodable {
    let title: String
    let content: String
    let ts: Double?
    var id: String { title }
}

/// MATINO X: reads the console notes through the GitHub Contents API (the
/// only source that is never CDN-stale), so anything saved on the site shows
/// up on this page without rebuilding the IPA.
@MainActor
final class MatinoNotesStore: ObservableObject {
    @Published private(set) var notes: [MatinoSiteNote] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    private struct ContentEnvelope: Decodable {
        let content: String
    }

    private static let endpoint =
        "https://api.github.com/repos/nari2122mh-design/matino-x/contents/BundledFiles/windows.json"

    func refresh() async {
        if notes.isEmpty { isLoading = true }
        loadFailed = false
        defer { isLoading = false }

        guard var components = URLComponents(string: Self.endpoint) else { return }
        components.queryItems = [
            URLQueryItem(name: "ref", value: "main"),
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("matino-x-app", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                loadFailed = notes.isEmpty
                return
            }
            if let decoded = Self.decode(data) {
                notes = decoded
            } else {
                loadFailed = notes.isEmpty
            }
        } catch {
            loadFailed = notes.isEmpty
        }
    }

    private static func decode(_ data: Data) -> [MatinoSiteNote]? {
        guard let envelope = try? JSONDecoder().decode(ContentEnvelope.self, from: data),
              let raw = Data(base64Encoded: envelope.content, options: .ignoreUnknownCharacters)
        else { return nil }

        // Current format: [ { "title": …, "content": …, "ts": … }, … ]
        if let list = try? JSONDecoder().decode([MatinoSiteNote].self, from: raw) {
            return list
                .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { ($0.ts ?? 0) > ($1.ts ?? 0) }
        }
        // Legacy format kept by older consoles: { "TITLE": "content" }
        if let dict = try? JSONDecoder().decode([String: String].self, from: raw) {
            return dict
                .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { MatinoSiteNote(title: $0.key, content: $0.value, ts: nil) }
                .sorted { $0.title < $1.title }
        }
        return nil
    }
}

/// MATINO X: the page opened by the green bell in the top right corner.
struct MatinoNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = MatinoNotesStore()

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.notes.isEmpty {
                    emptyState
                } else {
                    List(store.notes) { note in
                        noteRow(note)
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                    .refreshable { await store.refresh() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("NOTES")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("CLOSE") { dismiss() }
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .task { await store.refresh() }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(Color.green)
            Text(store.loadFailed ? "Can't load notes" : "No notes yet")
                .font(.system(size: 17, weight: .bold))
            Text(store.loadFailed
                 ? "Check your connection and pull down to retry."
                 : "Anything added from the secure console appears here instantly.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func noteRow(_ note: MatinoSiteNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let ts = note.ts, ts > 0 {
                    Text(dateString(ts))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if !note.content.isEmpty {
                Text(note.content)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.consoleBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
    }

    private func dateString(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM · HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
