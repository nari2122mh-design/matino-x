import SwiftUI

/// MATINO X: switches that hide non-essential sections in Settings.
private enum SettingsLayout {
    static let showsFeatures = false
    static let showsAppHeader = true
    static let showsWallpaperReset = false
    static let showsSocialMedia = false
    static let showsCredits = false
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var license = BaypassLicense.shared
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @AppStorage(FeatureVisibility.developerModeStorageKey)
    private var developerModeEnabled = false

    var body: some View {
        NavigationStack {
            List {
                if SettingsLayout.showsAppHeader {
                    Section {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black)
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("SETTINGS")
                                    .font(.system(size: 24, weight: .heavy))
                                    .foregroundStyle(.primary)
                                Text("APP CONFIGURATION")
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
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 2, trailing: 18))
                    }
                }

                Section {
                    Picker(language.text("settings.language"), selection: $languageCode) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)

                if SettingsLayout.showsFeatures {
                    Section {
                        Toggle(isOn: $cleanerEnabled) {
                            Label(language.text("tab.cleaner"), systemImage: "sparkles")
                        }
                        Toggle(isOn: $developerModeEnabled) {
                            Label(
                                language.text("settings.developer_mode"),
                                systemImage: "hammer.fill"
                            )
                        }
                    } header: {
                        Text(language.text("dashboard.features"))
                    } footer: {
                        Text(language.text("settings.developer_mode_footer"))
                    }
                }

                if SettingsLayout.showsWallpaperReset,
                   WallpaperFeatureSupportPolicy.isSupported(
                    major: AppInfo.versionTuple.major
                ) {
                    Section {
                        NavigationLink {
                            WallpaperResetSettingsView()
                        } label: {
                            Label(
                                language.text("wallpaper.reset"),
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                    } header: {
                        Text(language.text("tab.wallpapers"))
                    } footer: {
                        Text(language.text("wallpaper.reset_settings_footer"))
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                        LabeledContent(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppTheme.consoleBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                // MATINO X: license remaining time card.
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("LICENSE TIME", value: license.remainingTimeText)
                        if let duration = license.licenseDuration {
                            LabeledContent("DURATION", value: duration)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppTheme.consoleBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(language.text("settings.current_version"))
                            Spacer()
                            Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                            .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                        }
                        LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                        LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                        LabeledContent("iOS 26", value: ExploitSupportPolicy.verifiedIOS26Range)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("iOS 27.0")
                                .font(.body)
                            ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { version in
                                Text(versionLabel(version))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppTheme.consoleBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if SettingsLayout.showsSocialMedia {
                    Section(language.text("settings.social_media")) {
                        creditsRow(
                            name: "GitHub",
                            role: language.text("social.github_role"),
                            url: "https://github.com/YangJiiii/3105"
                        )
                        creditsRow(
                            name: "Cộng Đồng IOSVN",
                            role: language.text("social.iosvn_role"),
                            url: "https://t.me/ioscrackvn"
                        )
                    }
                }

                if SettingsLayout.showsCredits {
                    Section(language.text("settings.credits")) {
                        creditsRow(
                            name: "YangJiii",
                            role: language.text("credit.yangjiii"),
                            url: "https://x.com/duongduong0908"
                        )
                        creditsRow(
                            name: "0xjohnnydev",
                            role: language.text("credit.filzaslop"),
                            url: "https://github.com/0xjohnnydev/FilzaSlop"
                        )
                        creditsRow(
                            name: "LeminLimez",
                            role: language.text("credit.pocket_poster"),
                            url: "https://github.com/leminlimez/Pocket-Poster"
                        )
                        creditsRow(
                            name: "CrazyMind90",
                            role: language.text("credit.sandbox_escape"),
                            url: "https://github.com/CrazyMind90"
                        )
                        creditsRow(
                            name: "forcequitOS",
                            role: language.text("credit.forcequit"),
                            url: "https://github.com/forcequitOS"
                        )
                    }
                }

                // MATINO X: exit/deactivate button - removes the stored license key.
                Section {
                    Button(role: .destructive) {
                        license.deactivate()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 18, weight: .semibold))
                            Text("EXIT")
                                .font(.system(size: 16, weight: .bold))
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .tint(AppTheme.accent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private func versionLabel(
        _ version: (beta: Int, publicBeta: Int?, build: String)
    ) -> String {
        if let publicBeta = version.publicBeta {
            return language.text(
                "settings.developer_public_beta_build",
                Int64(version.beta),
                Int64(publicBeta),
                version.build
            )
        }
        return language.text(
            "settings.developer_beta_build",
            Int64(version.beta),
            version.build
        )
    }

    @ViewBuilder
    private func creditsRow(name: String, role: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 28, height: 28)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(language.text("accessibility.open_profile", name))
        }
    }
}
