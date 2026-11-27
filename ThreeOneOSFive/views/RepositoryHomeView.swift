import SwiftUI

struct RepositoryHomeView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var feed: [RepositoryPackageRecord] = []
    @State private var selectedSection = 0

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    private var visibleFeed: [RepositoryPackageRecord] {
        selectedSection == 0 ? feed : store.packages
    }

    private var featuredRecord: RepositoryPackageRecord? {
        visibleFeed.first(where: { $0.package.isFeatured }) ?? visibleFeed.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    brandCard

                    if store.packages.isEmpty {
                        emptyContent
                    } else {
                        if let featured = featuredRecord {
                            featureCard(featured)
                        }
                        sectionToggle
                        sectionHeader
                        rowsList
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppTheme.contentCardInset)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .refreshable {
                await store.refreshAllAndWait()
                rebuildFeed()
            }
            .navigationTitle(language.text("tab.home"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .navigationDestination(for: RepositoryPackageRecord.self) { record in
                RepositoryPackageDetailView(record: record)
            }
            .onAppear {
                store.refreshAllIfNeeded()
                if feed.isEmpty {
                    rebuildFeed()
                }
            }
            .onChange(of: store.packages) { _ in
                rebuildFeed()
            }
        }
    }

    private var emptyContent: some View {
        marketplaceEmpty(
            systemImage: store.sources.isEmpty
                ? "shippingbox.and.arrow.backward"
                : "shippingbox",
            titleKey: store.sources.isEmpty
                ? "repository.no_sources_title"
                : "repository.no_packages_title",
            messageKey: store.sources.isEmpty
                ? "repository.home_no_sources_message"
                : "repository.no_packages_message"
        )
    }

    private var brandCard: some View {
        HStack(spacing: 14) {
            AppLogo(size: 56)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("MATINO X")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                Text(language.text("home.brand_info"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.referenceCard, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("settings.title"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.referenceCard,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
        }
    }

    private func featureCard(_ record: RepositoryPackageRecord) -> some View {
        NavigationLink(value: record) {
            HStack(spacing: 16) {
                RepositoryPackageIcon(package: record.package, size: 64)

                VStack(alignment: .leading, spacing: 6) {
                    Text(record.package.name)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(record.package.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppTheme.referenceCard,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RepositoryCardButtonStyle())
    }

    private var sectionToggle: some View {
        HStack(spacing: 0) {
            sectionSegment(index: 0, title: language.text("repository.for_you"))
            sectionSegment(index: 1, title: language.text("repository.all_packages"))
        }
        .padding(6)
        .background(
            AppTheme.referenceCard,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.cardBorder, lineWidth: 1)
        }
    }

    private func sectionSegment(index: Int, title: String) -> some View {
        let isSelected = selectedSection == index
        let count = index == 0 ? feed.count : store.packages.count

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedSection = index
            }
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(language.text("repository.package_count", Int64(count)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isSelected ? Color.white.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
                language.text(
                    selectedSection == 0
                        ? "repository.for_you"
                        : "repository.all_packages"
                ),
                systemImage: "bolt.fill"
            )
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)

            Spacer(minLength: 8)

            Text(language.text("home.select_hint"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
        }
    }

    private var rowsList: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(visibleFeed) { record in
                NavigationLink(value: record) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.package.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(language.text(
                                "repository.home_package_meta",
                                record.package.author,
                                record.sourceName
                            ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            Text(language.text("common.version", record.package.version))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Text(language.text("common.open"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .textCase(.uppercase)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 13)
                            .background(
                                AppTheme.referenceCard,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                            }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RepositoryCardButtonStyle())
            }
        }
    }

    private func marketplaceEmpty(
        systemImage: String,
        titleKey: String,
        messageKey: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text(titleKey))
                .font(.headline)
            Text(language.text(messageKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 48)
        .background(
            AppTheme.referenceCard,
            in: RoundedRectangle(
                cornerRadius: AppTheme.contentCardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            AppCardBorder()
        }
    }

    private func rebuildFeed() {
        feed = PackageRepositoryFeedPolicy.home(store.packages)
    }
}

struct RepositoryNewView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var packages: [RepositoryPackageRecord] = []
    @State private var showSimulatedPackageDetail = false
    @State private var simulatedPackageDetailGate = OneShotPresentationGate()

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if packages.isEmpty {
                    Section {
                        emptyState
                    }
                } else {
                    Section {
                        ForEach(packages) { record in
                            NavigationLink(value: record) {
                                RepositoryNewPackageRow(record: record)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.text("tab.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .navigationDestination(for: RepositoryPackageRecord.self) { record in
                RepositoryPackageDetailView(record: record)
            }
            .navigationDestination(isPresented: $showSimulatedPackageDetail) {
                if let record = packages.first {
                    RepositoryPackageDetailView(record: record)
                }
            }
            .refreshable {
                await store.refreshAllAndWait()
                rebuildPackages()
            }
            .onAppear {
                store.refreshAllIfNeeded()
                rebuildPackages()
                openSimulatedPackageDetailIfNeeded()
            }
            .onChange(of: store.packages) { _ in
                rebuildPackages()
                openSimulatedPackageDetailIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isRefreshing && !store.sources.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(language.text("repository.refreshing"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            VStack(spacing: 12) {
                Image(systemName: store.sources.isEmpty ? "shippingbox" : "clock")
                    .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                    .foregroundStyle(AppTheme.accent)
                Text(language.text(
                    store.sources.isEmpty
                        ? "repository.no_sources_title"
                        : "repository.new_empty_title"
                ))
                .font(.headline)
                Text(language.text(
                    store.sources.isEmpty
                        ? "repository.no_sources_message"
                        : "repository.new_empty_message"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        }
    }

    private func rebuildPackages() {
        packages = PackageRepositoryFeedPolicy.newest(store.packages)
    }

    private func openSimulatedPackageDetailIfNeeded() {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains(
            "--simulate-package-detail"
        ), !packages.isEmpty, simulatedPackageDetailGate.claim() else {
            return
        }
        DispatchQueue.main.async {
            showSimulatedPackageDetail = true
        }
#endif
    }
}

struct RepositorySearchView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var searchText = ""

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [RepositoryPackageRecord] {
        guard !query.isEmpty else { return [] }
        return store.packages.filter { record in
            let package = record.package
            return package.name.localizedCaseInsensitiveContains(query)
                || package.author.localizedCaseInsensitiveContains(query)
                || package.summary.localizedCaseInsensitiveContains(query)
                || package.identifier.localizedCaseInsensitiveContains(query)
                || record.sourceName.localizedCaseInsensitiveContains(query)
                || (package.category?.localizedCaseInsensitiveContains(query) ?? false)
                || package.tags.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("repository.search_prompt"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                List {
                    if query.isEmpty {
                        searchPrompt
                            .listRowSeparator(.hidden)
                    } else if results.isEmpty {
                        searchEmpty
                            .listRowSeparator(.hidden)
                    } else {
                        Section(language.text(
                            "repository.search_results",
                            Int64(results.count)
                        )) {
                            ForEach(results) { record in
                                NavigationLink(value: record) {
                                    RepositoryPackageRow(record: record)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await store.refreshAllAndWait()
                }
            }
            .navigationTitle(language.text("repository.search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .navigationDestination(for: RepositoryPackageRecord.self) { record in
                RepositoryPackageDetailView(record: record)
            }
            .onAppear {
                store.refreshAllIfNeeded()
            }
        }
    }

    private var searchPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("repository.search_title"))
                .font(.headline)
            Text(language.text("repository.search_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var searchEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("repository.search_empty"))
                .font(.headline)
            Text(language.text("repository.search_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

private struct RepositoryCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private struct RepositoryNewPackageRow: View {
    @Environment(\.appLanguage) private var language
    let record: RepositoryPackageRecord

    var body: some View {
        HStack(spacing: 12) {
            RepositoryPackageIcon(package: record.package, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.package.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(language.text(
                    "repository.home_package_meta",
                    record.package.author,
                    record.sourceName
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let publishedAt = record.package.publishedAt {
                Text(
                    publishedAt,
                    format: .dateTime.day().month(.abbreviated)
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
