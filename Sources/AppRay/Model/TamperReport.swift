import Foundation

/// One thing in a bundle that no longer matches what the signature sealed.
struct TamperFinding: Hashable, Sendable, Identifiable {
    /// The ways a bundle can stop matching its signature. Each one is a
    /// separate list in the error Security.framework returns, and each one
    /// means something different to the admin holding the bundle.
    enum Kind: String, Sendable, CaseIterable {
        /// Sealed, still there, different bytes.
        case modified
        /// On disk, and the signature never covered it.
        case added
        /// Sealed, and no longer on disk.
        case missing
        /// A sealed file carries Finder information or a resource fork.
        case sideband
        /// Nested code — a framework, helper or extension — failing on its own.
        case subcomponent
        /// The bundle's own executable no longer matches its code directory.
        case executable

        var title: String {
            switch self {
            case .modified: "Modified since signing"
            case .added: "Added since signing"
            case .missing: "Missing since signing"
            case .sideband: "Carrying attached data"
            case .subcomponent: "Nested code that fails on its own"
            case .executable: "Main executable altered"
            }
        }

        var explanation: String {
            switch self {
            case .modified:
                "The file is still there, but its contents no longer hash to what the signature sealed."
            case .added:
                "Nothing in the signature covers these. They were put into the bundle after it was signed."
            case .missing:
                "The signature seals these files and they are no longer on disk."
            case .sideband:
                "A sealed file carries Finder information or a resource fork. codesign refuses to sign a bundle in this state; `xattr -cr` clears it."
            case .subcomponent:
                "A framework, helper or extension inside the bundle fails to verify against its own signature."
            case .executable:
                "The executable no longer matches the code directory in its signature. macOS will not launch it."
            }
        }

        var symbolName: String {
            switch self {
            case .modified: "pencil.circle"
            case .added: "plus.circle"
            case .missing: "minus.circle"
            case .sideband: "paperclip.circle"
            case .subcomponent: "shippingbox.circle"
            case .executable: "terminal"
            }
        }
    }

    var id: String { "\(kind.rawValue).\(path).\(detail ?? "")" }
    var kind: Kind
    /// Where the file sits inside the bundle, e.g. `Contents/Resources/x.png`.
    var path: String
    /// How it differs, where that can be established. Not every kind leaves
    /// something behind to describe.
    var detail: String?
}

/// What changed in a bundle after it was signed.
///
/// `SecStaticCodeCheckValidityWithErrors` does not stop at the first problem —
/// it walks the whole bundle and hands back the complete lists in the error it
/// returns. This is the same enumeration `codesign --verify --strict -vvv`
/// prints, without the subprocess.
struct TamperReport: Hashable, Sendable {
    var findings: [TamperFinding]

    var isEmpty: Bool { findings.isEmpty }

    /// Whether anything the signature actually seals has changed. Sideband data
    /// alone fails `codesign --strict` but Gatekeeper still accepts it, so the
    /// two cases do not carry the same consequence.
    var breaksSeal: Bool { findings.contains { $0.kind != .sideband } }

    var findingsByKind: [(kind: TamperFinding.Kind, findings: [TamperFinding])] {
        TamperFinding.Kind.allCases
            .map { kind in (kind, findings.filter { $0.kind == kind }) }
            .filter { !$0.1.isEmpty }
    }
}

extension AnalyzedApp {
    /// The report an admin pastes into a ticket or sends to the vendor: what
    /// this bundle claims to be, what no longer matches its signature, and what
    /// that costs. `nil` when the signature verifies.
    var tamperReportText: String? {
        guard case .invalid(let reason, let tamper) = trust?.signatureValidity else { return nil }

        var lines = ["AppRay tamper report", ""]

        func fact(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append(label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
        }

        fact("Bundle", info.url.path(percentEncoded: false))
        fact("Bundle ID", info.bundleIdentifier)
        fact("Version", info.versionSummary)
        fact("Signed by", signature.authority)
        fact("Team ID", signature.teamIdentifier)
        fact("CDHash", signature.cdHash)
        fact("Checked", Date.now.formatted(date: .long, time: .shortened))

        lines += ["", "Verdict", "", "This bundle does not match its code signature: \(clause(reason))"]

        if !tamper.isEmpty {
            lines += ["", "What changed"]
            for group in tamper.findingsByKind {
                lines += ["", "\(group.kind.title) — \(group.findings.count)"]
                for finding in group.findings {
                    let detail = finding.detail.map { " (\($0))" } ?? ""
                    lines.append("  \(finding.path)\(detail)")
                }
            }
        }

        lines += ["", "What this costs", ""]
        if tamper.breaksSeal {
            lines += [
                """
                Gatekeeper rejects this bundle. It will not open on a Mac that has not run \
                it before, and spctl --assess reports the same failure.
                """,
                "",
                """
                The designated requirement and CDHash above were read from the signature, \
                not recomputed from the files on disk. They still describe the app as its \
                developer signed it, so an MDM profile built from them targets that app and \
                not this copy.
                """,
            ]
        } else {
            lines.append(
                """
                Gatekeeper still accepts this bundle, but codesign --verify --strict rejects \
                it and codesign refuses to sign a bundle in this state, so it cannot be \
                re-signed or re-notarized until the attached data is removed.
                """
            )
        }

        lines += [
            "",
            "Reproduce with",
            "",
            "  codesign --verify --deep --strict -vvvvv \"\(info.url.path(percentEncoded: false))\"",
            "",
            "Paths are relative to the bundle. Read from Security.framework by AppRay.",
        ]

        return lines.joined(separator: "\n")
    }

    /// The verdict reads as a sentence on its own in the UI and as the tail of
    /// one here, so it changes case and picks up a full stop on the way.
    private func clause(_ reason: String) -> String {
        let body = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return body.prefix(1).lowercased() + body.dropFirst() + "."
    }
}
