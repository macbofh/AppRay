import Foundation

enum AnalysisError: LocalizedError {
    case notAnApplication(URL)
    case unreadableBundle(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAnApplication(let url):
            "“\(url.lastPathComponent)” is not an application bundle."
        case .unreadableBundle(let url, _):
            "Could not read “\(url.lastPathComponent)”."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAnApplication:
            "Drop a .app bundle from /Applications or anywhere else on disk."
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
    static func assessTrust(url: URL) async -> TrustAssessment {
        async let gatekeeper = Task.detached(priority: .utility) {
            GatekeeperReader.read(at: url)
        }.value
        async let validity = Task.detached(priority: .utility) {
            CodeSignatureReader.validate(at: url)
        }.value

        return await TrustAssessment(gatekeeper: gatekeeper, signatureValidity: validity)
    }

    static func analyzeSynchronously(url: URL) throws -> AnalyzedApp {
        guard url.pathExtension == "app" else { throw AnalysisError.notAnApplication(url) }

        let info: BundleInfo
        do {
            info = try BundleReader.readInfo(at: url)
        } catch {
            throw AnalysisError.unreadableBundle(url, underlying: error)
        }

        let signature = CodeSignatureReader.read(at: url)
        let machO = BundleReader.executableURL(for: info).map(MachOReader.read(at:)) ?? .empty

        return AnalyzedApp(
            info: info,
            signature: signature,
            trust: nil,
            machO: machO,
            components: BundleReader.components(in: url),
            findings: PrivilegeCatalog.findings(info: info, signature: signature, machO: machO)
        )
    }
}
