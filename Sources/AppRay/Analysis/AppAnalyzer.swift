import Foundation

enum AnalysisError: LocalizedError {
    case notAnApplication(URL)
    /// A `.app` that is neither shape AppRay knows.
    case unrecognisedLayout(URL)
    case unreadableBundle(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAnApplication(let url):
            "“\(url.lastPathComponent)” is not an application bundle."
        case .unrecognisedLayout(let url):
            "“\(url.lastPathComponent)” has no Info.plist where an app keeps one."
        case .unreadableBundle(let url, _):
            "Could not read “\(url.lastPathComponent)”."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAnApplication:
            "Drop a .app bundle — macOS or iOS — from /Applications or anywhere else on disk."
        case .unrecognisedLayout:
            """
            A macOS app keeps its Info.plist in Contents, an iOS app at the top level. \
            This bundle has neither, so there is nothing to read.
            """
        case .unreadableBundle(_, let underlying):
            underlying.localizedDescription
        }
    }
}

/// Runs the full analysis off the main actor.
enum AppAnalyzer {
    static func analyze(url: URL) async throws -> AnalyzedApp {
        try await Task.detached(priority: .userInitiated) {
            try analyzeSynchronously(url: url)
        }.value
    }

    /// Verifying the signature and asking Gatekeeper both walk every sealed
    /// resource in the bundle, which takes seconds on something the size of a
    /// browser. They run separately from the rest of the analysis, and
    /// concurrently with each other.
    static func assessTrust(layout: BundleLayout) async -> TrustAssessment {
        let url = layout.bundleURL

        async let validity = Task.detached(priority: .utility) {
            CodeSignatureReader.validate(at: url)
        }.value

        // Gatekeeper rejects every iOS bundle on sight, because macOS cannot
        // run one — a verdict that says nothing about the app. Asking would
        // put a red badge on a perfectly good app, so it is not asked. The
        // seal is still worth verifying, and that runs either way.
        guard layout.platform == .macOS else {
            return await TrustAssessment(
                gatekeeper: GatekeeperStatus(
                    verdict: .unknown("Gatekeeper does not assess iOS bundles."),
                    notarization: .unknown(
                        "Notarization is a macOS process. An iOS app goes through App Review instead."
                    ),
                    hasStapledTicket: false
                ),
                signatureValidity: validity
            )
        }

        async let gatekeeper = Task.detached(priority: .utility) {
            GatekeeperReader.read(at: url)
        }.value

        return await TrustAssessment(gatekeeper: gatekeeper, signatureValidity: validity)
    }

    static func analyzeSynchronously(url: URL) throws -> AnalyzedApp {
        guard url.pathExtension == "app" else { throw AnalysisError.notAnApplication(url) }
        guard let layout = BundleLayout.resolve(droppedURL: url) else {
            throw AnalysisError.unrecognisedLayout(url)
        }

        let info: BundleInfo
        do {
            info = try BundleReader.readInfo(in: layout)
        } catch {
            throw AnalysisError.unreadableBundle(url, underlying: error)
        }

        let signature = CodeSignatureReader.read(at: layout.bundleURL)
        let machO = BundleReader.executableURL(for: info).map(MachOReader.read(at:)) ?? .empty

        return AnalyzedApp(
            info: info,
            signature: signature,
            trust: nil,
            machO: machO,
            components: BundleReader.components(in: layout),
            findings: PrivilegeCatalog.findings(info: info, signature: signature, machO: machO)
        )
    }
}
