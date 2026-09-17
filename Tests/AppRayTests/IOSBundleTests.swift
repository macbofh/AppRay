import Foundation
import Testing

@testable import AppRay

/// These run against a real iOS bundle taken from an installed simulator
/// runtime, which is the one place a Mac reliably has one. A machine with no
/// runtime installed skips them rather than failing.
@Suite("iOS bundles")
struct IOSBundleTests {
    /// Safari on iOS: signed, with usage descriptions, app extensions and an
    /// XPC service, so one bundle exercises most of the reader.
    private static let mobileSafari: URL? = {
        let manager = FileManager.default

        // Xcode 26 puts runtimes on a mounted volume; older ones sit directly
        // under CoreSimulator.
        let volumes = (try? manager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes"),
            includingPropertiesForKeys: nil
        )) ?? []
        let parents = [URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/Runtimes")]
            + volumes.map { $0.appending(path: "Library/Developer/CoreSimulator/Profiles/Runtimes") }

        for parent in parents {
            let runtimes = (try? manager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            )) ?? []
            for runtime in runtimes where runtime.pathExtension == "simruntime" {
                let app = runtime.appending(
                    path: "Contents/Resources/RuntimeRoot/Applications/MobileSafari.app"
                )
                if manager.fileExists(atPath: app.appending(path: "Info.plist").path) {
                    return app
                }
            }
        }
        return nil
    }()

    private static var hasRuntime: Bool { mobileSafari != nil }

    @Test(
        "An iOS bundle resolves to the flat layout",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func flatLayout() throws {
        let url = try #require(Self.mobileSafari)
        let layout = try #require(BundleLayout.resolve(droppedURL: url))

        #expect(layout.platform == .iOS)
        #expect(!layout.isWrapped)
        #expect(layout.bundleURL == url)
        // Nothing sits under Contents: Info.plist, the executable and the
        // sealed-resource manifest all live at the top level.
        #expect(layout.contentsURL == url)
        #expect(layout.executableDirectoryURL == url)
        #expect(layout.infoPlistURL == url.appending(path: "Info.plist"))
        #expect(FileManager.default.fileExists(atPath: layout.codeResourcesURL.path))
        #expect(layout.sealedResourcesRootURL == url)
    }

    @Test(
        "A macOS bundle still resolves to the Contents layout",
        .enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app"))
    )
    func macOSLayoutIsUnchanged() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let layout = try #require(BundleLayout.resolve(droppedURL: url))

        #expect(layout.platform == .macOS)
        #expect(layout.contentsURL == url.appending(path: "Contents"))
        #expect(layout.executableDirectoryURL == url.appending(path: "Contents/MacOS"))
    }

    @Test(
        "An iOS app analyses, and says it is an iOS app",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func analysesAnIOSApp() throws {
        let app = try AppAnalyzer.analyzeSynchronously(url: try #require(Self.mobileSafari))

        #expect(app.info.platform == .iOS)
        #expect(app.info.bundleIdentifier == "com.apple.mobilesafari")
        #expect(app.info.executableName == "MobileSafari")
        // Read from MinimumOSVersion; the macOS key is not in an iOS bundle.
        #expect(app.info.minimumSystemVersion != nil)
        #expect(!app.machO.architectures.isEmpty)
        #expect(app.signature.designatedRequirement != nil)
    }

    @Test(
        "Usage descriptions in an iOS bundle are declarations like any other",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func readsUsageDescriptions() throws {
        let app = try AppAnalyzer.analyzeSynchronously(url: try #require(Self.mobileSafari))
        let contacts = try #require(app.findings.first { $0.service == .addressBook })

        #expect(contacts.confidence == .declared)
        #expect(contacts.evidence.contains { $0.key == "NSContactsUsageDescription" })
    }

    @Test(
        "An iOS app is never asked about the macOS judgement calls",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func noMacOSJudgementCalls() throws {
        let app = try AppAnalyzer.analyzeSynchronously(url: try #require(Self.mobileSafari))
        let macOSOnly: Set<PrivilegeService> = [
            .accessibility, .systemPolicyAllFiles, .listenEvent, .postEvent,
        ]

        for finding in app.findings {
            #expect(!macOSOnly.contains(finding.service), "\(finding.service.rawValue) offered for an iOS app")
        }
    }

    @Test(
        "Nested components are found in the iOS locations",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func findsIOSComponents() throws {
        let app = try AppAnalyzer.analyzeSynchronously(url: try #require(Self.mobileSafari))
        let kinds = Set(app.components.map(\.kind))

        #expect(!app.components.isEmpty)
        #expect(kinds.contains(.appExtension), "no .appex found in PlugIns or Extensions")
        #expect(app.components.allSatisfy { $0.kind != .privilegedHelper })
    }

    @Test(
        "The DDM identifier of an iOS app is the bundle ID on its own",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func ddmIdentifierIsTheBundleID() throws {
        let app = try AppAnalyzer.analyzeSynchronously(url: try #require(Self.mobileSafari))

        // Apple's schema: "In iOS, the app identifier is a bundle ID." The
        // composed form is a macOS-only construction.
        #expect(app.ddmComposedIdentifier == "com.apple.mobilesafari")
        #expect(app.ddmComposedIdentifier?.contains("{") == false)
    }

    /// The regression Mike hit: every iOS app read as "does not match its
    /// signature", with nothing under "What changed since signing". These
    /// bundles seal their contents with an envelope `kSecCSStrictValidate`
    /// refuses to read, which says nothing about the files.
    @Test(
        "An iOS system app with an obsolete envelope is unverifiable, not tampered with",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func obsoleteEnvelopeIsNotTampering() throws {
        let url = try #require(Self.mobileSafari)
        #expect(CodeSignatureReader.validate(at: url) == .unverifiable(.obsoleteEnvelope))
    }

    @Test(
        "Nothing about an unverifiable seal reaches the tamper report",
        .enabled(if: IOSBundleTests.hasRuntime)
    )
    func unverifiableSealHasNothingToReport() async throws {
        var app = try AppAnalyzer.analyzeSynchronously(url: try #require(Self.mobileSafari))
        app.trust = await AppAnalyzer.assessTrust(layout: app.info.layout)

        #expect(app.signatureValidity == .unverifiable(.obsoleteEnvelope))
        // The claim the bug made: tampering, with no finding behind it.
        #expect(app.tamperReportText == nil)
    }

    @Test("A wrapped iOS app resolves to the bundle inside the wrapper")
    func resolvesAWrapper() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "wrap-\(UUID().uuidString)")
        let outer = root.appending(path: "Example.app")
        let inner = outer.appending(path: "Wrapper/Example.app")
        defer { try? manager.removeItem(at: root) }

        try manager.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data().write(to: inner.appending(path: "Info.plist"))
        try manager.createSymbolicLink(
            at: outer.appending(path: "WrappedBundle"),
            withDestinationURL: URL(fileURLWithPath: "Wrapper/Example.app", relativeTo: outer)
        )

        let layout = try #require(BundleLayout.resolve(droppedURL: outer))
        #expect(layout.platform == .iOS)
        #expect(layout.isWrapped)
        #expect(layout.droppedURL == outer)
        // Compared symlink-resolved: the temporary directory is /var, which
        // standardising a path turns into /private/var.
        let resolved = inner.resolvingSymlinksInPath().path
        #expect(layout.bundleURL.resolvingSymlinksInPath().path == resolved)
        #expect(layout.contentsURL.resolvingSymlinksInPath().path == resolved)
    }

    @Test("A .app with no Info.plist anywhere is rejected on its own terms")
    func rejectsAnUnrecognisedLayout() throws {
        let manager = FileManager.default
        let url = manager.temporaryDirectory.appending(path: "Empty-\(UUID().uuidString).app")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: url) }

        #expect(BundleLayout.resolve(droppedURL: url) == nil)
        #expect(throws: AnalysisError.self) {
            try AppAnalyzer.analyzeSynchronously(url: url)
        }
    }
}

// MARK: - The iOS-only subjects

@Suite("iOS-only privileges")
struct IOSPrivilegeTests {
    private func iOSInfo(_ keys: [String: PlistValue]) -> BundleInfo {
        BundleInfo(
            layout: .iOS(bundleURL: URL(fileURLWithPath: "/tmp/Example.app")),
            name: "Example",
            bundleIdentifier: "com.example.app",
            isAgent: false,
            urlSchemes: [],
            raw: keys
        )
    }

    @Test("An iOS usage description is found and reported, not dropped")
    func iOSUsageDescriptionsAreFound() {
        let findings = PrivilegeCatalog.findings(
            info: iOSInfo([
                "NSFaceIDUsageDescription": .string("To unlock the app."),
                "NSMotionUsageDescription": .string("To count steps."),
                "NSUserTrackingUsageDescription": .string("To measure ads."),
                "NSHealthShareUsageDescription": .string("To read workouts."),
                "NSSiriUsageDescription": .string("To take dictation."),
            ]),
            signature: CodeSignature(
                entitlements: [:],
                certificates: [],
                isAdHoc: false,
                hasHardenedRuntime: false,
                hasLibraryValidation: false,
                flags: 0
            ),
            machO: .empty
        )

        let found = Set(findings.map(\.service))
        #expect(found == [.faceID, .motion, .userTracking, .health, .siri])
        #expect(findings.allSatisfy { $0.confidence == .declared })
        #expect(findings.first { $0.service == .faceID }?.evidence.first?.detail == "To unlock the app.")
    }

    @Test("Every iOS-only subject says outright that nothing can carry it")
    func iOSOnlySubjectsAreUnmanageable() {
        let iOSOnly = PrivilegeService.allCases.filter(\.isIOSOnly)
        #expect(!iOSOnly.isEmpty)

        for service in iOSOnly {
            #expect(service.pppcServiceKey == nil, "\(service.rawValue) claims a PPPC key")
            #expect(service.ddmPrivacyKey == nil, "\(service.rawValue) claims a DDM key")
            if case .unsupported = service.pppcSupport {} else {
                Issue.record("\(service.rawValue) is not marked unsupported")
            }
            #expect(service.manageabilitySummary.contains("Nothing carries this"))
        }
    }

    @Test("Neither channel can express an iOS-only subject, and both say why")
    func iOSOnlySubjectsAreOmittedWithAReason() {
        for service in PrivilegeService.allCases.filter(\.isIOSOnly) {
            let decision = ServiceDecision(service: service, isIncluded: true, authorization: .allow)
            #expect(!decision.isRepresentableInPPPC)
            #expect(!decision.isRepresentableInDDM)
            #expect(decision.exclusionReason(for: .pppc) != nil)
            #expect(decision.exclusionReason(for: .ddm) != nil)
        }
    }

    @Test("Both export channels state their iOS limit up front")
    func bothChannelsCaveatAnIOSBundle() {
        for channel in ExportChannel.allCases {
            #expect(channel.caveat(for: .iOS) != nil)
            #expect(channel.caveat(for: .macOS) == nil)
        }
    }

    @Test("An iOS declaration is keyed by the bundle ID, with no braces")
    func iOSDeclarationKeyIsThePlainBundleID() throws {
        let app = AnalyzedApp(
            info: iOSInfo(["NSCameraUsageDescription": .string("For photos.")]),
            signature: CodeSignature(
                signingIdentifier: "com.example.app",
                cdHash: String(repeating: "a", count: 40),
                designatedRequirement: #"cdhash H"aaaa""#,
                entitlements: [:],
                certificates: [],
                isAdHoc: true,
                hasHardenedRuntime: false,
                hasLibraryValidation: false,
                flags: 0
            ),
            trust: nil,
            machO: .empty,
            components: [],
            findings: []
        )

        var plan = ExportPlan(app: app)
        plan.decisions = [
            ServiceDecision(service: .camera, isIncluded: true, authorization: .allow),
        ]

        let data = try DDMDeclarationBuilder.build(app: app, plan: plan)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defaults = try #require(
            ((json["Payload"] as? [String: Any])?["Privacy"] as? [String: Any])?["PermissionDefaults"]
                as? [String: Any]
        )

        #expect(Array(defaults.keys) == ["com.example.app"])
    }
}
