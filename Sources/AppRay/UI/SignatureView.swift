import SwiftUI

struct SignatureView: View {
    var app: AnalyzedApp

    @State private var entitlementSearch = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let failure = app.signature.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
                }

                DetailSection(
                    title: "Designated requirement",
                    footnote: """
                    The `CodeRequirement` of every PPPC entry, and the part inside the \
                    braces of the DDM composed identifier. Identical to `codesign -d -r-`.
                    """
                ) {
                    CopyableRow(
                        label: "Requirement",
                        value: app.signature.designatedRequirement,
                        isMonospaced: true,
                        placeholder: "Unavailable"
                    )
                    Divider()
                    CopyableRow(
                        label: "CDHash",
                        value: app.signature.cdHash,
                        isMonospaced: true
                    )
                }

                ValiditySection(app: app)

                DetailSection(title: "Signing details") {
                    CopyableRow(label: "Team identifier", value: app.signature.teamIdentifier)
                    Divider()
                    CopyableRow(label: "Signing identifier", value: app.signature.signingIdentifier)
                    Divider()
                    LabeledContent("Hardened runtime") {
                        Text(app.signature.hasHardenedRuntime ? "Enabled" : "Not enabled")
                            .foregroundStyle(app.signature.hasHardenedRuntime ? .primary : .secondary)
                    }
                    Divider()
                    LabeledContent("Library validation") {
                        Text(app.signature.hasLibraryValidation ? "Enabled" : "Not enabled")
                            .foregroundStyle(app.signature.hasLibraryValidation ? .primary : .secondary)
                    }
                }

                if !app.signature.certificates.isEmpty {
                    DetailSection(
                        title: "Certificate chain",
                        footnote: "Leaf first, then the intermediates and the root above it."
                    ) {
                        ForEach(app.signature.certificates) { certificate in
                            CertificateRow(certificate: certificate)
                            if certificate.id != app.signature.certificates.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                DetailSection(
                    title: "Entitlements",
                    footnote: app.signature.entitlements.isEmpty
                        ? nil
                        : "\(app.signature.entitlements.count) entitlements."
                ) {
                    if !app.signature.entitlements.isEmpty {
                        TextField("Filter", text: $entitlementSearch)
                            .textFieldStyle(.roundedBorder)
                        Divider()
                    }
                    PlistTree(entries: app.signature.entitlements, searchText: entitlementSearch)
                }

                DetailSection(title: "Linked frameworks") {
                    if app.machO.linkedLibraries.isEmpty {
                        Text("None read.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(app.machO.linkedLibraries, id: \.self) { library in
                            Text(library)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
