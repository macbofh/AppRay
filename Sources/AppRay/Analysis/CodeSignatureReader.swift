import Foundation
import Security

/// Reads a bundle's code signature through Security.framework.
///
/// This is the same information `codesign -dvvv --entitlements -` prints, but
/// obtained directly from the API, so there is no output to parse and no
/// subprocess to spawn.
enum CodeSignatureReader {
    // CSCommon.h code signature flags. Redeclared here because the C enum does
    // not import into Swift with usable types.
    private static let adhocFlag: UInt32 = 0x0000_0002
    private static let runtimeFlag: UInt32 = 0x0001_0000
    private static let libraryValidationFlag: UInt32 = 0x0000_2000

    static func read(at url: URL) -> CodeSignature {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return CodeSignature(
                failure: message(for: createStatus),
                entitlements: [:],
                certificates: [],
                isAdHoc: false,
                hasHardenedRuntime: false,
                hasLibraryValidation: false,
                flags: 0
            )
        }

        let flags = SecCSFlags(rawValue:
            kSecCSSigningInformation
            | kSecCSRequirementInformation
            | kSecCSInternalInformation
        )
        var rawInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, flags, &rawInformation)
        guard infoStatus == errSecSuccess,
              let information = rawInformation as? [String: Any]
        else {
            return CodeSignature(
                failure: message(for: infoStatus),
                entitlements: [:],
                certificates: [],
                isAdHoc: false,
                hasHardenedRuntime: false,
                hasLibraryValidation: false,
                flags: 0
            )
        }

        let signatureFlags = (information[kSecCodeInfoFlags as String] as? NSNumber)?
            .uint32Value ?? 0

        // An unsigned bundle still produces a signing-information dictionary,
        // just a nearly empty one. The absence of an identifier is the tell.
        let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String

        return CodeSignature(
            failure: signingIdentifier == nil ? "This bundle is not signed." : nil,
            signingIdentifier: signingIdentifier,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: hexString(from: information[kSecCodeInfoUnique as String] as? Data),
            designatedRequirement: designatedRequirement(of: staticCode),
            entitlements: PlistValue.dictionary(
                fromPropertyList: information[kSecCodeInfoEntitlementsDict as String]
            ),
            certificates: certificates(from: information),
            signedDate: information[kSecCodeInfoTimestamp as String] as? Date,
            isAdHoc: signatureFlags & adhocFlag != 0,
            hasHardenedRuntime: signatureFlags & runtimeFlag != 0,
            hasLibraryValidation: signatureFlags & libraryValidationFlag != 0,
            flags: signatureFlags
        )
    }

    /// The signing facts needed for a DDM binary identifier, read for a nested
    /// component without paying for entitlements and certificates.
    static func briefSignature(
        at url: URL
    ) -> (signingIdentifier: String?, teamIdentifier: String?, requirement: String?, cdHash: String?) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return (nil, nil, nil, nil) }

        var rawInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSInternalInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &rawInformation) == errSecSuccess,
              let information = rawInformation as? [String: Any]
        else { return (nil, nil, nil, nil) }

        return (
            information[kSecCodeInfoIdentifier as String] as? String,
            information[kSecCodeInfoTeamIdentifier as String] as? String,
            designatedRequirement(of: staticCode),
            hexString(from: information[kSecCodeInfoUnique as String] as? Data)
        )
    }

    private static func designatedRequirement(of staticCode: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement
        else { return nil }

        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func certificates(from information: [String: Any]) -> [CertificateInfo] {
        guard let raw = information[kSecCodeInfoCertificates as String] else { return [] }
        // The array bridges as [Any]; each element is a SecCertificate.
        let certificates = (raw as? [Any])?.compactMap { element -> SecCertificate? in
            guard CFGetTypeID(element as CFTypeRef) == SecCertificateGetTypeID() else { return nil }
            return (element as! SecCertificate)
        } ?? []

        return certificates.enumerated().map { index, certificate in
            let window = validityWindow(of: certificate)
            return CertificateInfo(
                id: index,
                summary: SecCertificateCopySubjectSummary(certificate) as String?
                    ?? "Unnamed certificate",
                notBefore: window.notBefore,
                expiryDate: window.notAfter
            )
        }
    }

    private static func validityWindow(
        of certificate: SecCertificate
    ) -> (notBefore: Date?, notAfter: Date?) {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any]
        else { return (nil, nil) }

        // Certificate validity values come back as seconds since the CF epoch.
        func date(for oid: CFString) -> Date? {
            guard let entry = values[oid as String] as? [String: Any],
                  let interval = (entry[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
            else { return nil }
            return Date(timeIntervalSinceReferenceDate: interval)
        }

        return (date(for: kSecOIDX509V1ValidityNotBefore), date(for: kSecOIDX509V1ValidityNotAfter))
    }

    /// Verifies the signature against what is actually on disk: every sealed
    /// resource in the bundle, for every architecture.
    ///
    /// Strict validation is deliberate. Without `kSecCSStrictValidate` the
    /// check tolerates files added to the bundle after signing, which is
    /// exactly the tampering an admin wants to hear about — and which
    /// Gatekeeper rejects anyway. This matches `codesign --verify --strict`.
    ///
    /// Slow on a large bundle — this is the expensive half of the analysis and
    /// belongs on a background task.
    static func validate(at url: URL) -> SignatureValidity {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return .unsigned }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, nil, &errors)
        let detail = errors?.takeRetainedValue() as Error?

        switch status {
        case errSecSuccess:
            return .valid
        case errSecCSUnsigned:
            return .unsigned
        default:
            // The OSStatus message is the sentence codesign prints ("a sealed
            // resource is missing or invalid"). The CFError's own
            // localizedDescription is only the number, so it is no use here —
            // its value is the lists of offending files in its user info.
            let reason = message(for: status)
            return .invalid(
                reason: reason.prefix(1).uppercased() + reason.dropFirst(),
                tamper: TamperReport(
                    findings: tamperFindings(from: detail, status: status, bundleURL: url)
                )
            )
        }
    }

    /// Every file the validation objected to, not just the first.
    ///
    /// `SecStaticCodeCheckValidityWithErrors` walks the whole bundle and
    /// collects each problem into an array in the error's user info, keyed by
    /// what went wrong. This is where `codesign -vvv` gets its "file added /
    /// file modified / file missing" lines; reading the same dictionary keeps
    /// AppRay's account as complete as codesign's without a subprocess.
    private static func tamperFindings(
        from error: Error?,
        status: OSStatus,
        bundleURL: URL
    ) -> [TamperFinding] {
        guard let info = (error as? NSError)?.userInfo else { return [] }

        let bundle = resolvedPath(of: bundleURL)

        func urls(_ key: CFString) -> [URL] {
            (info[key as String] as? [URL]) ?? []
        }

        var findings: [TamperFinding] = []

        var manifests = ManifestCache()
        findings += urls(kSecCFErrorResourceAltered).map {
            modifiedFinding(for: $0, in: bundle, manifests: &manifests)
        }
        findings += urls(kSecCFErrorResourceAdded).map {
            TamperFinding(kind: .added, path: path(of: $0, in: bundle), detail: facts(about: $0))
        }
        findings += urls(kSecCFErrorResourceMissing).map {
            TamperFinding(kind: .missing, path: path(of: $0, in: bundle), detail: nil)
        }
        // A nested framework or helper that fails on its own is named here
        // rather than in any of the lists above.
        if let component = info[kSecCFErrorPath as String] as? URL {
            findings.append(
                TamperFinding(
                    kind: .subcomponent,
                    path: path(of: component, in: bundle),
                    detail: message(for: status)
                )
            )
        } else if status == errSecCSBadMainExecutable {
            // Nothing named means the bundle's own executable is the one that
            // stopped matching.
            let executable = Bundle(url: bundleURL)?.executableURL
            findings.append(
                TamperFinding(
                    kind: .executable,
                    path: executable.map { path(of: $0, in: bundle) } ?? bundleURL.lastPathComponent,
                    detail: nil
                )
            )
        }

        return findings
    }

    /// A file that is still there but no longer hashes to what was sealed —
    /// with the two hashes side by side, so the claim can be checked without
    /// AppRay.
    ///
    /// Every URL the validation hands back carries the directory its own seal
    /// was written against as its base, which is `layout.sealedResourcesRootURL`
    /// for the bundle that sealed it — the app's own, or a nested component's.
    /// Taking the manifest from there rather than from the bundle root keeps
    /// this right for both bundle shapes, and right for nested code.
    private static func modifiedFinding(
        for url: URL,
        in bundlePath: String,
        manifests: inout ManifestCache
    ) -> TamperFinding {
        let finding = TamperFinding(
            kind: .modified,
            path: path(of: url, in: bundlePath),
            detail: facts(about: url)
        )
        // Where there is no hash to show, say which of the reasons it is
        // rather than leaving the row looking incomplete.
        func explaining(_ note: String) -> TamperFinding {
            var copy = finding
            copy.detail = [copy.detail, note].compactMap { $0 }.joined(separator: " — ")
            return copy
        }

        guard let root = url.baseURL else { return finding }

        // The manifest keys files by the same relative path the URL carries.
        guard let manifest = manifests.manifest(sealedUnder: root) else {
            return explaining("the sealed manifest could not be read, so there is nothing to compare against")
        }
        guard let seal = manifest[url.relativePath] else {
            return explaining("the sealed manifest does not list this file")
        }

        switch seal {
        case .nestedCode:
            return explaining("sealed as nested code, by its own signature rather than by a hash of its bytes")
        case .symlink(let target):
            let current = try? FileManager.default.destinationOfSymbolicLink(
                atPath: url.path(percentEncoded: false)
            )
            guard let current, current != target else {
                return explaining("sealed as a symbolic link to \(target)")
            }
            return explaining("sealed as a symbolic link to \(target), now pointing at \(current)")
        case .sha256, .sha1:
            guard let algorithm = seal.algorithm,
                  let sealed = seal.sealedDigest,
                  let onDisk = seal.digestOnDisk(at: url)
            else {
                return explaining("the file could not be read, so its hash could not be taken")
            }
            var annotated = finding
            annotated.digests = TamperFinding.Digests(
                algorithm: algorithm, sealed: sealed, onDisk: onDisk
            )
            return annotated
        }
    }

    /// One bundle can hold several sealed roots, and a manifest is worth
    /// reading once rather than once per offending file.
    private struct ManifestCache {
        private var manifests: [URL: SealedResourceManifest?] = [:]

        mutating func manifest(sealedUnder root: URL) -> SealedResourceManifest? {
            if let known = manifests[root] { return known }
            // The same place `layout.codeResourcesURL` points at, relative to
            // the sealed-resources root rather than to the bundle.
            let read = SealedResourceManifest.read(
                at: root.appending(path: "_CodeSignature/CodeResources")
            )
            manifests[root] = read
            return read
        }
    }

    /// The offending file's location the way an admin would type it, relative
    /// to the bundle rather than to whichever directory the seal is written
    /// against — so a macOS and an iOS bundle read the same way.
    private static func path(of url: URL, in bundlePath: String) -> String {
        let full = resolvedPath(of: url)
        guard full.hasPrefix(bundlePath + "/") else { return url.relativePath }
        return String(full.dropFirst(bundlePath.count + 1))
    }

    /// Both sides of that comparison have to spell the same file the same way,
    /// and a URL that points at a directory carries a trailing slash that would
    /// stop the prefix from ever matching.
    private static func resolvedPath(of url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Size and last-modified date, for a file that is still there. The API
    /// says a file changed; this says how big it is now and when it happened,
    /// which is what an admin chases next.
    private static func facts(about url: URL) -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = values.fileSize else { return nil }

        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        guard let modified = values.contentModificationDate else { return bytes }
        return "\(bytes), modified \(modified.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func hexString(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func message(for status: OSStatus) -> String {
        if status == errSecCSUnsigned { return "This bundle is not signed." }
        let text = SecCopyErrorMessageString(status, nil) as String?
        return text ?? "Could not read the code signature (OSStatus \(status))."
    }
}
