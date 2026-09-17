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
            CertificateInfo(
                id: index,
                summary: SecCertificateCopySubjectSummary(certificate) as String?
                    ?? "Unnamed certificate",
                expiryDate: expiryDate(of: certificate)
            )
        }
    }

    private static func expiryDate(of certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let interval = (entry[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
        else { return nil }
        // Certificate validity values come back as seconds since the CF epoch.
        return Date(timeIntervalSinceReferenceDate: interval)
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
