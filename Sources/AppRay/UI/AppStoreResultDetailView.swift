import SwiftUI

/// Shown for an App Store search result the admin has not dropped a bundle
/// for. Laid out like `OverviewView` on purpose, so switching between an
/// analysed app and a catalog listing feels like the same kind of screen —
/// but everything here is catalog metadata, never a code-signing fact.
struct AppStoreResultDetailView: View {
    @Environment(InspectorModel.self) private var model
    var result: AppStoreLookupResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                DetailSection(
                    title: "Not a local analysis",
                    footnote: """
                    There is no bundle here, so there is no code signature, no entitlements, \
                    and no privilege surface to read — only what Apple's catalog shows a shopper.
                    """
                ) {
                    CopyableRow(label: "Bundle identifier", value: result.bundleIdentifier, isMonospaced: true)
                    Divider()
                    CopyableRow(label: "Platform", value: result.platform.label)
                    Divider()
                    CopyableRow(label: "Developer", value: result.sellerName ?? result.developerName)
                    Divider()
                    CopyableRow(label: "Version", value: result.version)
                    Divider()
                    CopyableRow(label: "Kind", value: result.kind)
                    Divider()
                    CopyableRow(label: "Wrapper type", value: result.wrapperType)
                }

                DetailSection(title: "Catalog details") {
                    CopyableRow(label: "Price", value: priceDisplay)
                    Divider()
                    CopyableRow(label: "Genres", value: joined(result.genres))
                    Divider()
                    CopyableRow(label: "Size", value: result.formattedFileSize)
                    Divider()
                    CopyableRow(label: "Minimum OS", value: result.minimumOSVersion)
                    Divider()
                    CopyableRow(label: "Content rating", value: result.contentAdvisoryRating)
                    Divider()
                    CopyableRow(label: "Track content rating", value: result.trackContentRating)
                    Divider()
                    CopyableRow(label: "Released", value: formatted(result.releaseDate))
                    Divider()
                    CopyableRow(label: "Last updated", value: formatted(result.currentVersionReleaseDate))
                }

                DetailSection(title: "Ratings") {
                    CopyableRow(label: "All versions", value: result.formattedRating)
                    Divider()
                    CopyableRow(label: "Current version", value: result.formattedCurrentVersionRating)
                }

                DetailSection(
                    title: "Availability & licensing",
                    footnote: "Whether Apple Business Manager can assign this app to a device without an Apple ID."
                ) {
                    CopyableRow(label: "VPP device-based licensing", value: vppDisplay)
                    Divider()
                    CopyableRow(label: "Supported devices", value: joined(result.supportedDevices))
                    Divider()
                    CopyableRow(label: "Features", value: joined(result.features))
                    Divider()
                    CopyableRow(label: "Languages", value: joined(result.languageCodesISO2A))
                }

                if !result.advisories.isEmpty {
                    DetailSection(title: "Advisories") {
                        CopyableRow(label: "Advisories", value: joined(result.advisories))
                    }
                }

                DetailSection(title: "Links") {
                    CopyableRow(label: "Icon URL", value: result.largestArtworkURL?.absoluteString, isMonospaced: true)
                    Divider()
                    CopyableRow(label: "App Store page", value: result.appStoreURL?.absoluteString, isMonospaced: true)
                    Divider()
                    CopyableRow(
                        label: "Developer page",
                        value: result.developerViewURL?.absoluteString,
                        isMonospaced: true
                    )
                    Divider()
                    CopyableRow(label: "Seller URL", value: result.sellerURL?.absoluteString, isMonospaced: true)
                }

                if let releaseNotes = result.releaseNotes, !releaseNotes.isEmpty {
                    DetailSection(title: "What's new") {
                        Text(releaseNotes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let description = result.appDescription, !description.isEmpty {
                    DetailSection(title: "Description") {
                        Text(description)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !screenshots.isEmpty {
                    DetailSection(title: "Screenshots") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(screenshots, id: \.self) { url in
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(.quaternary)
                                        }
                                    }
                                    .frame(height: 320)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var screenshots: [URL] {
        result.platform == .macOS
            ? result.screenshotURLs
            : (result.screenshotURLs + result.ipadScreenshotURLs + result.appletvScreenshotURLs)
    }

    private var priceDisplay: String? {
        if let formattedPrice = result.formattedPrice, !formattedPrice.isEmpty { return formattedPrice }
        guard let price = result.price else { return nil }
        return price == 0 ? "Free" : "\(price) \(result.currency ?? "")"
    }

    private var vppDisplay: String? {
        guard let enabled = result.isVppDeviceBasedLicensingEnabled else { return nil }
        return enabled ? "Enabled" : "Not enabled"
    }

    private func joined(_ values: [String]) -> String? {
        values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private func formatted(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            RemoteIconView(url: result.largestArtworkURL, size: 108)
                .contextMenu {
                    Button("Save Image As…") {
                        guard let url = result.largestArtworkURL else { return }
                        model.exportRemoteIcon(from: url, suggestedName: result.name)
                    }
                    Button("Copy Icon URL") {
                        guard let url = result.largestArtworkURL else { return }
                        model.copy(url.absoluteString, label: "Icon URL")
                    }
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(result.name)
                    .font(.largeTitle.weight(.semibold))

                if let version = result.version {
                    Text("Version \(version)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                badges
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var badges: some View {
        // A wrapping row: stacks vertically once the window is too narrow
        // for the badges to sit side by side.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeContent }
            VStack(alignment: .leading, spacing: 6) { badgeContent }
        }
    }

    @ViewBuilder
    private var badgeContent: some View {
        Badge(text: "App Store lookup", symbolName: "storefront", tone: .neutral)
        Badge(text: result.platform.label, symbolName: "macwindow", tone: .neutral)
        if result.isVppDeviceBasedLicensingEnabled == true {
            Badge(text: "VPP device-based", symbolName: "checkmark.seal", tone: .positive)
        }
    }
}
