import SwiftUI

/// Whether this app will actually run, and keep running.
///
/// Four facts decide that, and they interact: the signature has to verify, the
/// signing certificate has to have been valid *when the app was signed*, a
/// secure timestamp is what proves it was, and notarization is what lets
/// Gatekeeper open it on a Mac that has never seen it.
struct ValiditySection: View {
    var app: AnalyzedApp

    var body: some View {
        DetailSection(title: "Validity", footnote: footnote) {
            LabeledContent("Signature") {
                switch app.trust?.signatureValidity {
                case .valid:
                    StatusText("Verified against the bundle contents", tone: .positive)
                case .invalid(let reason, _):
                    StatusText(reason, tone: .critical)
                case .unsigned:
                    StatusText("Not signed", tone: .critical)
                case nil:
                    PendingText("Verifying every sealed resource…")
                }
            }

            Divider()

            LabeledContent("Signing certificate") {
                if let certificate = app.signature.leafCertificate {
                    StatusText(certificate.validity.summary, tone: tone(for: certificate.validity))
                } else {
                    StatusText("No certificate", tone: .critical)
                }
            }

            if let certificate = app.signature.leafCertificate,
               let notBefore = certificate.notBefore,
               let notAfter = certificate.expiryDate {
                Divider()
                LabeledContent("Valid from") {
                    Text(
                        "\(notBefore.formatted(date: .abbreviated, time: .omitted)) — "
                            + notAfter.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            }

            Divider()

            LabeledContent("Secure timestamp") {
                if let signed = app.signature.signedDate {
                    StatusText(
                        "Signed \(signed.formatted(date: .abbreviated, time: .shortened))",
                        tone: .positive
                    )
                } else {
                    StatusText("None", tone: .caution)
                }
            }

            Divider()

            LabeledContent("Notarization") {
                if let gatekeeper = app.trust?.gatekeeper {
                    StatusText(
                        gatekeeper.notarization.label,
                        tone: notarizationTone(gatekeeper.notarization)
                    )
                } else {
                    PendingText("Running spctl…")
                }
            }

            Divider()

            LabeledContent("Stapled ticket") {
                if let gatekeeper = app.trust?.gatekeeper {
                    StatusText(
                        gatekeeper.hasStapledTicket ? "Present" : "Not stapled",
                        tone: gatekeeper.hasStapledTicket ? .positive : .neutral
                    )
                } else {
                    PendingText("Checking…")
                }
            }

            Divider()

            LabeledContent("Gatekeeper") {
                if let text = gatekeeperText {
                    Text(text).multilineTextAlignment(.trailing)
                } else {
                    PendingText("Assessing…")
                }
            }
        }
    }

    /// The one sentence that resolves the most common confusion, shown only
    /// when it actually applies.
    private var footnote: String {
        guard let validity = app.signature.leafCertificate?.validity else {
            return "A missing stapled ticket is not proof of anything — macOS can still check notarization online."
        }

        switch (validity.isExpired, app.signature.hasSecureTimestamp) {
        case (true, true):
            return """
            The signing certificate has expired, but the signature carries a secure \
            timestamp proving the app was signed while the certificate was still \
            valid. macOS accepts it. Nothing to do.
            """
        case (true, false):
            return """
            The signing certificate has expired and there is no secure timestamp to \
            prove when the app was signed, so macOS treats the signature as expired. \
            The app needs re-signing.
            """
        case (false, false):
            return """
            No secure timestamp. The signature works today, but it will stop being \
            accepted the day the signing certificate expires. A missing stapled \
            ticket, by contrast, is not proof of anything — macOS can still check \
            notarization online.
            """
        case (false, true):
            return "A missing stapled ticket is not proof of anything — macOS can still check notarization online."
        }
    }

    private var gatekeeperText: String? {
        switch app.trust?.gatekeeper.verdict {
        case .accepted(let source): "Accepted — \(source)"
        case .rejected(let reason): "Rejected — \(reason)"
        case .unknown(let detail): detail
        case nil: nil
        }
    }

    private func tone(for validity: CertificateValidity) -> Badge.Tone {
        switch validity {
        case .valid: .positive
        case .expiringSoon: .caution
        // An expired certificate with a timestamp is a note, not a failure.
        case .expired: app.signature.hasSecureTimestamp ? .caution : .critical
        case .notYetValid: .critical
        case .unknown: .neutral
        }
    }

    private func notarizationTone(_ status: NotarizationStatus) -> Badge.Tone {
        switch status {
        case .notarized, .appStore: .positive
        case .notNotarized: .critical
        case .appleSystem: .neutral
        case .unknown: .caution
        }
    }
}

/// What changed in the bundle, once the signature has said it no longer
/// matches.
///
/// Grouped the way the privileges list is grouped — one group per kind, with
/// the sentence that says what that kind means underneath it — because a list
/// of paths without that sentence is another dead end.
struct TamperSection: View {
    @Environment(InspectorModel.self) private var model

    var app: AnalyzedApp
    var report: TamperReport

    var body: some View {
        DetailSection(
            title: "What changed since signing",
            footnote: """
            Paths are relative to the bundle. The same enumeration \
            `codesign --verify --deep --strict -vvvvv` prints, read straight from \
            Security.framework.
            """
        ) {
            ForEach(report.findingsByKind, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(group.kind.title) — \(group.findings.count)",
                        systemImage: group.kind.symbolName
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                    Text(group.kind.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(group.findings) { finding in
                        TamperRow(finding: finding)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if group.kind != report.findingsByKind.last?.kind {
                    Divider()
                }
            }

            Divider()

            Button("Copy the whole report") {
                guard let text = app.tamperReportText else { return }
                model.copy(text, label: "Tamper report")
            }
            .buttonStyle(.link)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One offending file. Clicking it copies its path, the way every other value
/// in this app behaves.
private struct TamperRow: View {
    @Environment(InspectorModel.self) private var model

    var finding: TamperFinding

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if let detail = finding.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "document.on.document")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture { model.copy(finding.path, label: "Path") }
        .help("Click to copy")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Copies the path to the clipboard")
    }
}

/// A certificate in the chain, with its window and where it sits in it.
struct CertificateRow: View {
    var certificate: CertificateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(certificate.summary)
                .font(.callout)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                if let notBefore = certificate.notBefore, let notAfter = certificate.expiryDate {
                    Text(
                        "\(notBefore.formatted(date: .abbreviated, time: .omitted)) — "
                            + notAfter.formatted(date: .abbreviated, time: .omitted)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(certificate.validity.summary)
                    .font(.caption)
                    .foregroundStyle(certificate.validity.isExpired ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Small pieces

private struct StatusText: View {
    var text: String
    var tone: Badge.Tone

    init(_ text: String, tone: Badge.Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            if tone != .neutral {
                Image(systemName: symbolName)
                    .imageScale(.small)
                    .foregroundStyle(tone.color)
            }
            Text(text)
                .multilineTextAlignment(.trailing)
        }
    }

    private var symbolName: String {
        switch tone {
        case .positive: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .critical: "xmark.circle.fill"
        case .neutral: "circle"
        }
    }
}

private struct PendingText: View {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(.secondary)
        }
    }
}
