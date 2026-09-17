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

                DetailSection(title: "Signature") {
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
                    Divider()
                    LabeledContent("Stapled notarization ticket") {
                        if let gatekeeper = app.gatekeeper {
                            Text(gatekeeper.hasStapledTicket ? "Present" : "Not stapled")
                                .foregroundStyle(gatekeeper.hasStapledTicket ? .primary : .secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let signed = app.signature.signedDate {
                        Divider()
                        LabeledContent("Signed") {
                            Text(signed.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }

                DetailSection(
                    title: "Gatekeeper",
                    footnote: "A missing stapled ticket is not proof of anything — macOS can still check notarization online."
                ) {
                    LabeledContent("Assessment") {
                        if let gatekeeperText {
                            Text(gatekeeperText)
                                .multilineTextAlignment(.trailing)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Running spctl…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !app.signature.certificates.isEmpty {
                    DetailSection(title: "Certificate chain") {
                        ForEach(app.signature.certificates) { certificate in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(certificate.summary)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                if let expiry = certificate.expiryDate {
                                    Text("Expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(expiry < .now ? .red : .secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var gatekeeperText: String? {
        switch app.gatekeeper?.verdict {
        case .accepted(let source): "Accepted — \(source)"
        case .rejected(let reason): "Rejected — \(reason)"
        case .unknown(let detail): detail
        case nil: nil
        }
    }
}
