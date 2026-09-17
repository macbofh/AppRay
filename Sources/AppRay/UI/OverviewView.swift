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

                DetailSection(
                    title: "Bundle",
                    footnote: app.machO.architectures.isEmpty
                        ? "The main executable could not be read."
                        : nil
                ) {
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

                DetailSection(
                    title: "Ready for MDM",
                    footnote: """
                    These two strings are what a PPPC profile and a DDM declaration \
                    target the app by. Everything else in the export is derived from them.
                    """
                ) {
                    CopyableRow(
                        label: "Designated requirement",
                        value: app.signature.designatedRequirement,
                        isMonospaced: true,
                        placeholder: "Unavailable — the app is not signed"
                    )
                    Divider()
                    CopyableRow(
                        label: "DDM composed identifier",
                        value: app.ddmComposedIdentifier,
                        isMonospaced: true,
                        placeholder: "Needs both a bundle identifier and a signature"
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
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

        switch app.gatekeeper?.verdict {
        case .accepted(let source):
            Badge(text: source, symbolName: "checkmark.seal", tone: .positive)
        case .rejected(let reason):
            Badge(text: reason, symbolName: "xmark.seal", tone: .critical)
        case .unknown:
            Badge(text: "Gatekeeper unknown", symbolName: "questionmark.circle", tone: .caution)
        case nil:
            Badge(text: "Checking Gatekeeper…", symbolName: "hourglass", tone: .neutral)
        }

        if !app.signature.isSigned {
            Badge(text: "Unsigned", symbolName: "exclamationmark.triangle", tone: .critical)
        } else if app.signature.isAdHoc {
            Badge(text: "Ad-hoc signed", symbolName: "exclamationmark.triangle", tone: .caution)
        }

        if app.signature.hasHardenedRuntime {
            Badge(text: "Hardened runtime", symbolName: "lock", tone: .positive)
        }

        if app.info.isAgent {
            Badge(text: "Agent (no Dock icon)", symbolName: "eye.slash", tone: .neutral)
        }
    }
}
