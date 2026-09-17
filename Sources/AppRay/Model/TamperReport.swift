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
        /// Nested code — a framework, helper or extension — failing on its own.
        case subcomponent
        /// The bundle's own executable no longer matches its code directory.
        case executable

        var title: String {
            switch self {
            case .modified: "Modified since signing"
            case .added: "Added since signing"
            case .missing: "Missing since signing"
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
    /// What the signature sealed against what is on disk now. Only a file
    /// sealed by a hash of its bytes has one.
    var digests: Digests?

    /// The pair that settles an argument with a vendor: the hash in the
    /// signature, and the hash of the file sitting in the bundle.
    struct Digests: Hashable, Sendable {
        var algorithm: String
        var sealed: String
        var onDisk: String

        /// Enough of each to tell them apart at a glance, for a row that has
        /// to fit next to a file path.
        var shortSealed: String { String(sealed.prefix(16)) + "…" }
        var shortOnDisk: String { String(onDisk.prefix(16)) + "…" }
    }
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

        // A URL that points at a directory prints with a trailing slash, which
        // reads like a typo in a ticket.
        var bundlePath = info.url.path(percentEncoded: false)
        if bundlePath.hasSuffix("/") { bundlePath.removeLast() }

        func fact(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append(label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
        }

        fact("Bundle", bundlePath)
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
                    // The full digests, not the shortened pair the row shows —
                    // a report nobody can verify against is not worth sending.
                    if let digests = finding.digests {
                        let sealed = "sealed \(digests.algorithm)"
                        lines.append("    " + sealed.padding(toLength: 15, withPad: " ", startingAt: 0) + digests.sealed)
                        lines.append("    " + "on disk".padding(toLength: 15, withPad: " ", startingAt: 0) + digests.onDisk)
                    }
                }
            }
        }

        lines += ["", "What this costs", ""] + consequences

        lines += [
            "",
            "Reproduce with",
            "",
            "  codesign --verify --deep --strict -vvvvv \"\(bundlePath)\"",
            "",
            "Paths are relative to the bundle. Read from Security.framework by AppRay.",
        ]

        return lines.joined(separator: "\n")
    }

    /// What a broken signature costs, which is not the same thing on the two
    /// platforms: macOS refuses the bundle at Gatekeeper, iOS refuses it on the
    /// device, and only one of the two output channels carries a requirement
    /// that can go stale.
    private var consequences: [String] {
        switch info.platform {
        case .macOS:
            [
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
        case .iOS:
            [
                """
                iOS will not launch this bundle. That check happens on the device, at launch, \
                and not at Gatekeeper: Gatekeeper does not assess iOS bundles, and \
                spctl --assess rejects every one of them for a reason that says nothing \
                about this one.
                """,
                "",
                """
                There is no PPPC payload on iOS, and a declaration is keyed by the bundle \
                identifier alone — which this copy carries exactly as the developer's build \
                does. Nothing AppRay can generate tells the two apart.
                """,
            ]
        }
    }

    /// The verdict reads as a sentence on its own in the UI and as the tail of
    /// one here, so it changes case and picks up a full stop on the way.
    private func clause(_ reason: String) -> String {
        let body = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return body.prefix(1).lowercased() + body.dropFirst() + "."
    }
}
