import SwiftUI

struct OverviewView: View {
    var app: AnalyzedApp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                DetailSection(title: "Identity") {
                    CopyableRow(label: "Bundle identifier", value: app.info.bundleIdentifier)
                    Divider()
                    CopyableRow(label: "Team identifier", value: app.signature.teamIdentifier)
                    Divider()
                    CopyableRow(label: "Signing identifier", value: app.signature.signingIdentifier)
                    Divider()
                    CopyableRow(label: "Version", value: app.info.versionSummary)
                }

                DetailSection(title: "Bundle", footnote: bundleFootnote) {
                    CopyableRow(label: "Platform", value: app.info.platform.label)
                    Divider()
                    CopyableRow(label: "Path", value: app.info.url.path)
                    Divider()
                    CopyableRow(label: "Executable", value: app.info.executableName)
                    Divider()
                    CopyableRow(
                        label: "Architectures",
                        value: app.machO.architectures.isEmpty
                            ? nil
                            : app.machO.architectures.joined(separator: ", ")
                    )
                    Divider()
                    CopyableRow(label: "Built against SDK", value: app.machO.sdkVersion)
                    Divider()
                    CopyableRow(
                        label: "Minimum system version",
                        value: app.info.minimumSystemVersion ?? app.machO.minimumOSVersion
                    )
                    if !app.info.urlSchemes.isEmpty {
                        Divider()
                        CopyableRow(
                            label: "URL schemes",
                            value: app.info.urlSchemes.joined(separator: ", ")
                        )
                    }
                    if let copyright = app.info.copyright {
                        Divider()
                        CopyableRow(label: "Copyright", value: copyright)
                    }
                }

                DetailSection(title: "Ready for MDM", footnote: mdmFootnote) {
                    CopyableRow(
                        label: "Designated requirement",
                        value: app.signature.designatedRequirement,
                        isMonospaced: true,
                        placeholder: "Unavailable — the app is not signed"
                    )
                    Divider()
                    CopyableRow(
                        label: app.info.platform == .macOS
                            ? "DDM composed identifier"
                            : "DDM app identifier",
                        value: app.ddmComposedIdentifier,
                        isMonospaced: true,
                        placeholder: app.info.platform == .macOS
                            ? "Needs both a bundle identifier and a signature"
                            : "Needs a bundle identifier"
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// The wrapper note outranks the missing-executable one: it says the path
    /// above is not the bundle these figures came from.
    private var bundleFootnote: String? {
        if app.info.layout.isWrapped {
            return """
            An iOS app inside a wrapper bundle. Everything here was read from \
            \(app.info.layout.bundleURL.lastPathComponent) inside it.
            """
        }
        return app.machO.architectures.isEmpty ? "The main executable could not be read." : nil
    }

    private var mdmFootnote: String {
        switch app.info.platform {
        case .macOS:
            """
            These two strings are what a PPPC profile and a DDM declaration \
            target the app by. Everything else in the export is derived from them.
            """
        case .iOS:
            """
            iOS matches an app by its bundle identifier alone. The designated requirement \
            is read from the bundle and shown here, but no iOS payload uses it — and there \
            is no PPPC payload on iOS at all.
            """
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            AppIconView(url: app.info.url, size: 108)

            VStack(alignment: .leading, spacing: 8) {
                Text(app.info.name)
                    .font(.largeTitle.weight(.semibold))

                if let version = app.info.versionSummary {
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
        // A wrapping row: the badge count varies a lot between apps.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeContent }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { badgeContent }
            }
        }
    }

    @ViewBuilder
    private var badgeContent: some View {
        if let team = app.signature.teamIdentifier {
            Badge(text: team, symbolName: "person.badge.key", tone: .neutral)
        }

        // An iOS app says so first, and says nothing about notarization, which
        // is a macOS process it has never been through.
        if app.info.platform == .iOS {
            Badge(text: app.info.platform.label, symbolName: "iphone", tone: .neutral)
        } else {
            switch app.trust?.gatekeeper.notarization {
            case .notarized:
                Badge(text: "Notarized", symbolName: "checkmark.seal", tone: .positive)
            case .notNotarized:
                Badge(text: "Not notarized", symbolName: "exclamationmark.seal", tone: .critical)
            case .appStore:
                Badge(text: "Mac App Store", symbolName: "checkmark.seal", tone: .positive)
            case .appleSystem:
                Badge(text: "Apple system software", symbolName: "apple.logo", tone: .neutral)
            case .unknown:
                Badge(text: "Notarization unknown", symbolName: "questionmark.circle", tone: .caution)
            case nil:
                Badge(text: "Verifying…", symbolName: "hourglass", tone: .neutral)
            }
        }

        certificateBadge

        switch app.trust?.signatureValidity {
        case .invalid:
            Badge(text: "Signature invalid", symbolName: "xmark.seal", tone: .critical)
        case .unsigned:
            Badge(text: "Unsigned", symbolName: "exclamationmark.triangle", tone: .critical)
        case .valid, nil:
            // A valid signature is the expectation; no badge for it. The
            // unsigned and ad-hoc cases below still deserve one.
            if !app.signature.isSigned {
                Badge(text: "Unsigned", symbolName: "exclamationmark.triangle", tone: .critical)
            } else if app.signature.isAdHoc {
                Badge(text: "Ad-hoc signed", symbolName: "exclamationmark.triangle", tone: .caution)
            }
        }

        if app.signature.hasHardenedRuntime {
            Badge(text: "Hardened runtime", symbolName: "lock", tone: .positive)
        }

        if app.info.isAgent {
            Badge(text: "Agent (no Dock icon)", symbolName: "eye.slash", tone: .neutral)
        }
    }

    /// An expired certificate only breaks an app that was signed without a
    /// secure timestamp, so the badge says which of the two situations it is.
    @ViewBuilder
    private var certificateBadge: some View {
        if let certificate = app.signature.leafCertificate {
            switch certificate.validity {
            case .valid:
                EmptyView()
            case .expiringSoon(let days):
                Badge(
                    text: "Certificate expires in \(days) d",
                    symbolName: "clock.badge.exclamationmark",
                    tone: .caution
                )
            case .expired:
                Badge(
                    text: app.signature.hasSecureTimestamp
                        ? "Certificate expired (timestamped)"
                        : "Certificate expired",
                    symbolName: app.signature.hasSecureTimestamp
                        ? "clock.badge.checkmark"
                        : "xmark.seal",
                    tone: app.signature.hasSecureTimestamp ? .caution : .critical
                )
            case .notYetValid:
                Badge(text: "Certificate not valid yet", symbolName: "clock", tone: .critical)
            case .unknown:
                EmptyView()
            }
        }
    }
}
