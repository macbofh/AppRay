import Foundation
import Testing

@testable import AppRay

/// These run against real bundles on the machine and cross-check the result
/// against `codesign`, which is the tool an admin would otherwise use by hand.
@Suite("Analysis of real bundles")
struct AnalysisTests {
    private static let safari = URL(fileURLWithPath: "/Applications/Safari.app")

    /// Runs `codesign` and returns its combined output.
    private func codesign(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(
        "The designated requirement matches `codesign -d -r-`",
        .enabled(if: FileManager.default.fileExists(atPath: AnalysisTests.safari.path))
    )
    func designatedRequirementMatchesCodesign() throws {
        let signature = CodeSignatureReader.read(at: Self.safari)
        let requirement = try #require(signature.designatedRequirement)

        let output = try codesign(["-d", "-r-", Self.safari.path])
        let expected = try #require(
            output
                .split(separator: "\n")
                .first { $0.hasPrefix("designated =>") }?
                .replacingOccurrences(of: "designated => ", with: "")
                .trimmingCharacters(in: .whitespaces)
        )

        #expect(requirement == expected)
    }

    @Test(
        "Team identifier and CDHash match codesign",
        .enabled(if: FileManager.default.fileExists(atPath: AnalysisTests.safari.path))
    )
    func identityMatchesCodesign() throws {
        let signature = CodeSignatureReader.read(at: Self.safari)
        let output = try codesign(["-dvvv", Self.safari.path])

        // Apple's own binaries carry no team identifier, so only assert when
        // codesign reports one.
        if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }),
           case let reported = line.replacingOccurrences(of: "TeamIdentifier=", with: ""),
           reported != "not set" {
            #expect(signature.teamIdentifier == reported)
        }

        let cdHash = try #require(signature.cdHash)
        #expect(cdHash.count == 40)
        #expect(output.lowercased().contains(cdHash.lowercased()))
    }

    @Test(
        "A universal system binary reports its architectures and linked frameworks",
        .enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app"))
    )
    func machOReadsRealBinary() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let info = try BundleReader.readInfo(at: url)
        let executable = try #require(BundleReader.executableURL(for: info))
        let machO = MachOReader.read(at: executable)

        #expect(!machO.architectures.isEmpty)
        #expect(machO.linkedLibraries.contains { $0.contains("libSystem") })
        #expect(machO.sdkVersion != nil)
    }

    @Test(
        "Info.plist parsing produces an identifier and a version",
        .enabled(if: FileManager.default.fileExists(atPath: AnalysisTests.safari.path))
    )
    func bundleInfo() throws {
        let info = try BundleReader.readInfo(at: Self.safari)
        #expect(info.bundleIdentifier == "com.apple.Safari")
        #expect(info.versionSummary != nil)
    }

    @Test("A non-application path is rejected")
    func rejectsNonApplication() {
        #expect(throws: AnalysisError.self) {
            try AppAnalyzer.analyzeSynchronously(url: URL(fileURLWithPath: "/usr/bin/codesign"))
        }
    }

    @Test("The quarantine attribute round-trips, and its absence reads as nil")
    func quarantineAttribute() throws {
        var url = FileManager.default.temporaryDirectory
            .appending(path: "AppRayQuarantineTest-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(QuarantineReader.read(at: url) == nil)

        let downloaded = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "AppRayTests",
            kLSQuarantineTimeStampKey as String: downloaded,
        ]
        try url.setResourceValues(values)

        let quarantine = try #require(QuarantineReader.read(at: url))
        #expect(quarantine.agentName == "AppRayTests")
        #expect(quarantine.timestamp == downloaded)
    }
}

@Suite("Privilege catalog")
struct PrivilegeCatalogTests {
    private func info(_ keys: [String: PlistValue]) -> BundleInfo {
        BundleInfo(
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            name: "Example",
            isAgent: false,
            urlSchemes: [],
            raw: keys
        )
    }

    private func signature(entitlements: [String: PlistValue] = [:]) -> CodeSignature {
        CodeSignature(
            entitlements: entitlements,
            certificates: [],
            isAdHoc: false,
            hasHardenedRuntime: false,
            hasLibraryValidation: false,
            flags: 0
        )
    }

    @Test("A usage description is a declaration, and its purpose string is kept as evidence")
    func usageDescriptionIsDeclared() {
        let findings = PrivilegeCatalog.findings(
            info: info(["NSCameraUsageDescription": .string("For video calls.")]),
            signature: signature(),
            machO: .empty
        )
        let camera = try? #require(findings.first { $0.service == .camera })
        #expect(camera?.confidence == .declared)
        #expect(camera?.evidence.first?.detail == "For video calls.")
        #expect(camera?.evidence.first?.source == .infoPlistKey)
    }

    @Test("Framework linkage is only ever an inference")
    func frameworkLinkageIsInferred() {
        let findings = PrivilegeCatalog.findings(
            info: info([:]),
            signature: signature(),
            machO: MachOInfo(
                architectures: ["arm64"],
                linkedLibraries: ["/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit"]
            )
        )
        let capture = try? #require(findings.first { $0.service == .screenCapture })
        #expect(capture?.confidence == .inferred)
    }

    @Test("A declaration outranks an inference for the same service")
    func declarationBeatsInference() {
        let findings = PrivilegeCatalog.findings(
            info: info(["NSLocationWhenInUseUsageDescription": .string("Maps.")]),
            signature: signature(),
            machO: MachOInfo(
                architectures: ["arm64"],
                linkedLibraries: ["/System/Library/Frameworks/CoreLocation.framework/CoreLocation"]
            )
        )
        let location = try? #require(findings.first { $0.service == .location })
        #expect(location?.confidence == .declared)
        #expect(location?.evidence.count == 2)
    }

    @Test("A sandbox entitlement set to false is not treated as a request")
    func falseEntitlementIsIgnored() {
        let findings = PrivilegeCatalog.findings(
            info: info([:]),
            signature: signature(entitlements: ["com.apple.security.device.camera": .bool(false)]),
            machO: .empty
        )
        #expect(!findings.contains { $0.service == .camera })
    }

    @Test("The invisible services are always offered, never assumed")
    func judgementCallsArePresentButUnproven() {
        let findings = PrivilegeCatalog.findings(info: info([:]), signature: signature(), machO: .empty)
        for service in [PrivilegeService.accessibility, .systemPolicyAllFiles, .listenEvent, .postEvent] {
            let finding = findings.first { $0.service == service }
            #expect(finding?.confidence == .manual)
            #expect(finding?.evidence.isEmpty == true)
        }
    }

    @Test("An Endpoint Security client implies Full Disk Access")
    func endpointSecurityImpliesFullDisk() {
        let findings = PrivilegeCatalog.findings(
            info: info([:]),
            signature: signature(
                entitlements: ["com.apple.developer.endpoint-security.client": .bool(true)]
            ),
            machO: .empty
        )
        let fullDisk = try? #require(findings.first { $0.service == .systemPolicyAllFiles })
        #expect(fullDisk?.confidence == .declared)
    }
}

@Suite("Service manageability")
struct ServiceManageabilityTests {
    @Test("Only the three services Apple names are deny-only")
    func denyOnlyMatchesAppleSchema() {
        let denyOnly = PrivilegeService.allCases.filter { $0.pppcSupport == .denyOnly }
        #expect(Set(denyOnly) == [.camera, .microphone, .screenCapture])
    }

    @Test("Location and Local Network have no PPPC key")
    func ddmOnlyServices() {
        #expect(PrivilegeService.location.pppcServiceKey == nil)
        #expect(PrivilegeService.localNetwork.pppcServiceKey == nil)
        #expect(PrivilegeService.location.ddmPrivacyKey == "Location")
    }

    @Test("Every PPPC key deprecated in macOS 27 has a DDM replacement")
    func deprecationsHaveASuccessor() {
        for service in PrivilegeService.allCases where service.isPPPCDeprecatedInMacOS27 {
            #expect(service.ddmPrivacyKey != nil, "\(service.rawValue) has no DDM successor")
        }
    }

    @Test("Only ListenEvent and ScreenCapture accept a standard-user override")
    func standardUserOverride() {
        let overridable = PrivilegeService.allCases.filter(\.allowsStandardUserOverride)
        #expect(Set(overridable) == [.listenEvent, .screenCapture])
    }
}
