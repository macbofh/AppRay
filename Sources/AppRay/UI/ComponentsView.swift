import SwiftUI

/// Nested executables inside the bundle. Helper tools embedded in an app
/// inherit the enclosing app's TCC permissions, but system extensions, login
/// items and separately-installed helpers often need entries of their own —
/// which is exactly what gets forgotten when a profile is written by hand.
struct ComponentsView: View {
    @Environment(InspectorModel.self) private var model
    var app: AnalyzedApp

    var body: some View {
        if app.components.isEmpty {
            ContentUnavailableView(
                "No nested components",
                systemImage: "shippingbox",
                description: Text("This bundle contains no helpers, login items, XPC services, system extensions or plug-ins.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(grouped, id: \.kind) { group in
                        DetailSection(title: group.kind.rawValue) {
                            ForEach(group.components) { component in
                                ComponentRow(component: component)
                                if component.id != group.components.last?.id {
                                    Divider()
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
    }

    private var grouped: [(kind: BundleComponent.Kind, components: [BundleComponent])] {
        Dictionary(grouping: app.components, by: \.kind)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }
}

private struct ComponentRow: View {
    @Environment(InspectorModel.self) private var model
    var component: BundleComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: component.kind.symbolName)
                    .foregroundStyle(.tint)
                Text(component.name)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                if let team = component.teamIdentifier {
                    Badge(
                        text: team,
                        tone: team == parentTeam ? .neutral : .caution
                    )
                } else {
                    Badge(text: "Unsigned", tone: .critical)
                }
            }

            if let identifier = component.bundleIdentifier {
                Text(identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let requirement = component.designatedRequirement {
                DisclosureGroup("Designated requirement") {
                    Text(requirement)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)

                    Button("Copy") {
                        model.copy(requirement, label: "\(component.name) requirement")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// Flag components signed by someone other than the app's own team — a
    /// bundled third-party helper needs its own scrutiny.
    private var parentTeam: String? {
        model.app?.signature.teamIdentifier
    }
}
