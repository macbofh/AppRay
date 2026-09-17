import SwiftUI

struct PrivilegesView: View {
    @Environment(InspectorModel.self) private var model
    var app: AnalyzedApp

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedFinding) {
            ForEach(app.findingsByConfidence, id: \.confidence) { group in
                Section {
                    ForEach(group.findings) { finding in
                        PrivilegeRow(finding: finding)
                            .tag(finding.id)
                    }
                } header: {
                    Label(group.confidence.title, systemImage: group.confidence.symbolName)
                } footer: {
                    Text(group.confidence.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }
            }
        }
        .listStyle(.inset)
        .inspector(isPresented: .constant(model.selectedFinding != nil)) {
            if let finding = app.findings.first(where: { $0.id == model.selectedFinding }) {
                PrivilegeDetail(finding: finding)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
    }
}

private struct PrivilegeRow: View {
    var finding: PrivilegeFinding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: finding.service.symbolName)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.service.displayName)
                    .fontWeight(.medium)
                Text(evidenceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ChannelBadges(service: finding.service)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var evidenceSummary: String {
        guard let first = finding.evidence.first else {
            return "Nothing in the bundle reveals this."
        }
        let extra = finding.evidence.count - 1
        let base = "\(first.source.rawValue): \(first.key)"
        return extra > 0 ? "\(base) + \(extra) more" : base
    }
}

/// The two-channel answer to "how do I actually configure this?".
struct ChannelBadges: View {
    var service: PrivilegeService

    var body: some View {
        HStack(spacing: 5) {
            switch service.pppcSupport {
            case .grantAndDeny:
                Badge(text: "PPPC", tone: .positive)
            case .denyOnly:
                Badge(text: "PPPC deny only", tone: .caution)
            case .unsupported:
                EmptyView()
            }

            if service.ddmPrivacyKey != nil {
                Badge(text: "DDM", tone: .positive)
            }

            if service.pppcSupport == .unsupported, service.ddmPrivacyKey == nil {
                Badge(text: "Not manageable", tone: .critical)
            }
        }
    }
}

private struct PrivilegeDetail: View {
    var finding: PrivilegeFinding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: finding.service.symbolName)
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(finding.service.displayName)
                            .font(.title2.weight(.semibold))
                        Text(finding.service.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                DetailSection(title: "How MDM reaches this") {
                    Text(finding.service.manageabilitySummary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if finding.service.isPPPCDeprecatedInMacOS27 {
                        Divider()
                        Label(
                            "Apple deprecated this PPPC key in macOS 27.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if finding.service.allowsStandardUserOverride {
                        Divider()
                        Label(
                            "Supports AllowStandardUserToSetSystemService, which lets a non-admin change it.",
                            systemImage: "person.badge.shield.checkmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                DetailSection(
                    title: "Evidence",
                    footnote: finding.confidence.explanation
                ) {
                    if finding.evidence.isEmpty {
                        Text("None. This service leaves no trace in an app bundle.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(finding.evidence) { evidence in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(evidence.source.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(evidence.key)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                if let detail = evidence.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if evidence.id != finding.evidence.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}
