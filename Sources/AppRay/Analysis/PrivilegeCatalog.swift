import Foundation

/// Turns the raw facts about a bundle into privilege findings.
///
/// The rules are deliberately conservative. A usage description or an
/// entitlement is treated as a declaration; framework linkage is only ever an
/// inference; and the services that leave no trace whatsoever in a bundle are
/// never guessed at — they are surfaced as decisions for the admin to make.
enum PrivilegeCatalog {
    /// `Info.plist` keys that state an intent outright.
    private static let usageDescriptionKeys: [String: PrivilegeService] = [
        "NSCameraUsageDescription": .camera,
        "NSMicrophoneUsageDescription": .microphone,
        "NSAppleEventsUsageDescription": .appleEvents,
        "NSBluetoothAlwaysUsageDescription": .bluetoothAlways,
        "NSBluetoothPeripheralUsageDescription": .bluetoothAlways,
        "NSLocalNetworkUsageDescription": .localNetwork,
        "NSLocationUsageDescription": .location,
        "NSLocationWhenInUseUsageDescription": .location,
        "NSLocationAlwaysAndWhenInUseUsageDescription": .location,
        "NSContactsUsageDescription": .addressBook,
        "NSCalendarsUsageDescription": .calendar,
        "NSCalendarsFullAccessUsageDescription": .calendar,
        "NSCalendarsWriteOnlyAccessUsageDescription": .calendar,
        "NSRemindersUsageDescription": .reminders,
        "NSRemindersFullAccessUsageDescription": .reminders,
        "NSPhotoLibraryUsageDescription": .photos,
        "NSPhotoLibraryAddUsageDescription": .photos,
        "NSAppleMusicUsageDescription": .mediaLibrary,
        "NSSpeechRecognitionUsageDescription": .speechRecognition,
        "NSSystemAdministrationUsageDescription": .systemPolicySysAdminFiles,
        "NSDesktopFolderUsageDescription": .systemPolicyDesktopFolder,
        "NSDocumentsFolderUsageDescription": .systemPolicyDocumentsFolder,
        "NSDownloadsFolderUsageDescription": .systemPolicyDownloadsFolder,
        "NSNetworkVolumesUsageDescription": .systemPolicyNetworkVolumes,
        "NSRemovableVolumesUsageDescription": .systemPolicyRemovableVolumes,
        "NSFileProviderPresenceUsageDescription": .fileProviderPresence,
    ]

    private static let entitlementKeys: [String: PrivilegeService] = [
        "com.apple.security.device.camera": .camera,
        "com.apple.security.device.audio-input": .microphone,
        "com.apple.security.device.microphone": .microphone,
        "com.apple.security.device.bluetooth": .bluetoothAlways,
        "com.apple.security.personal-information.addressbook": .addressBook,
        "com.apple.security.personal-information.calendars": .calendar,
        "com.apple.security.personal-information.location": .location,
        "com.apple.security.personal-information.photos-library": .photos,
        "com.apple.security.automation.apple-events": .appleEvents,
        "com.apple.security.scripting-targets": .appleEvents,
        // An Endpoint Security client cannot function without Full Disk Access.
        "com.apple.developer.endpoint-security.client": .systemPolicyAllFiles,
    ]

    private static let frameworkHints: [String: PrivilegeService] = [
        "ScreenCaptureKit": .screenCapture,
        "CoreLocation": .location,
        "Contacts": .addressBook,
        "AddressBook": .addressBook,
        "EventKit": .calendar,
        "Photos": .photos,
        "PhotosUI": .photos,
        "iTunesLibrary": .mediaLibrary,
        "MediaPlayer": .mediaLibrary,
        "Speech": .speechRecognition,
        "CoreBluetooth": .bluetoothAlways,
        "EndpointSecurity": .systemPolicyAllFiles,
    ]

    /// Services that no bundle ever reveals. Always offered, never assumed.
    private static let judgementCalls: [PrivilegeService] = [
        .accessibility, .systemPolicyAllFiles, .listenEvent, .postEvent,
    ]

    static func findings(
        info: BundleInfo,
        signature: CodeSignature,
        machO: MachOInfo
    ) -> [PrivilegeFinding] {
        var evidenceByService: [PrivilegeService: [Evidence]] = [:]
        var confidenceByService: [PrivilegeService: Confidence] = [:]

        func record(_ service: PrivilegeService, _ evidence: Evidence, _ confidence: Confidence) {
            evidenceByService[service, default: []].append(evidence)
            confidenceByService[service] = max(confidenceByService[service] ?? .manual, confidence)
        }

        for (key, service) in usageDescriptionKeys {
            guard let value = info.raw[key] else { continue }
            record(
                service,
                Evidence(source: .infoPlistKey, key: key, detail: value.stringValue),
                .declared
            )
        }

        // Bonjour service declarations are a local-network intent in all but name.
        if let services = info.raw["NSBonjourServices"]?.arrayValue, !services.isEmpty {
            record(
                .localNetwork,
                Evidence(
                    source: .infoPlistKey,
                    key: "NSBonjourServices",
                    detail: services.compactMap(\.stringValue).joined(separator: ", ")
                ),
                .declared
            )
        }

        for (key, service) in entitlementKeys {
            guard let value = signature.entitlements[key] else { continue }
            // A sandbox entitlement set to false is a statement that the app
            // does *not* want the capability.
            if value.boolValue == false { continue }
            record(
                service,
                Evidence(source: .entitlement, key: key, detail: value.displayString),
                .declared
            )
        }

        let linked = machO.linkedFrameworkNames
        for (framework, service) in frameworkHints where linked.contains(framework) {
            record(
                service,
                Evidence(
                    source: .linkedFramework,
                    key: framework,
                    detail: "The main executable links \(framework)."
                ),
                .inferred
            )
        }

        for service in judgementCalls where confidenceByService[service] == nil {
            confidenceByService[service] = .manual
            evidenceByService[service] = []
        }

        return confidenceByService
            .map { service, confidence in
                PrivilegeFinding(
                    service: service,
                    confidence: confidence,
                    evidence: (evidenceByService[service] ?? []).sorted {
                        $0.key.localizedStandardCompare($1.key) == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.confidence == $1.confidence
                    ? $0.service.displayName.localizedStandardCompare($1.service.displayName) == .orderedAscending
                    : $0.confidence > $1.confidence
            }
    }
}
