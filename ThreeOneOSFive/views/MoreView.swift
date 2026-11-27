import SwiftUI

/// MATINO X: "More" tab — community links and MATINO X channel cards.
struct MoreView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                // Header card (same style as AIM / MISC / SETTINGS).
                Section {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black)
                            .frame(width: 56, height: 56)
                            .overlay {
                                Image(systemName: "ellipsis.circle.fill")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("MORE")
                                .font(.system(size: 24, weight: .heavy))
                                .foregroundStyle(.primary)
                            Text("COMMUNITY & CHANNELS")
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

                // Owner Telegram
                linkCard(
                    icon: "crown.fill",
                    title: "OWNER TELEGRAM",
                    subtitle: "@DYNASTY_212",
                    url: "https://t.me/DYNASTY_212"
                )

                // Official Telegram
                linkCard(
                    icon: "checkmark.seal.fill",
                    title: "OFFICIAL TELEGRAM",
                    subtitle: "MATINO X",
                    url: "https://t.me/MATINO123"
                )

                // MATINO X Channel (link not provided yet).
                linkCard(
                    icon: "megaphone.fill",
                    title: "MATINO X CHANNEL",
                    subtitle: "Coming soon",
                    url: nil
                )
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private func linkCard(icon: String, title: String, subtitle: String, url: String?) -> some View {
        Section {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if url != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.consoleBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let url, let link = URL(string: url) {
                    openURL(link)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 2, trailing: 18))
        }
    }
}
