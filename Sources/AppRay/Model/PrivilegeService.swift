import Foundation

/// How far a `com.apple.TCC.configuration-profile-policy` payload reaches for a
/// given service.
///
/// The distinction matters a lot in practice: a PPPC profile can *grant* Full
/// Disk Access, but for Camera it can only ever *deny*. Getting this wrong is a
/// common reason an admin's profile silently does nothing.
///
/// Source: `Reference/com.apple.TCC.configuration-profile-policy.yaml`, which
/// spells out "A profile can't grant access … it can only deny it" for exactly
/// three services.
enum PPPCSupport: Sendable {
    /// `Authorization` may be `Allow` or `Deny`.
    case grantAndDeny
    /// `Authorization` may only be `Deny`; the user has to grant it themselves.
    case denyOnly
    /// The service has no PPPC key at all.
    case unsupported
}

/// The values a DDM `app.settings` privacy key accepts.
enum DDMPrivacyValues: Sendable {
    /// `None` | `Allow`
    case allow
    /// `None` | `WhileUsing` | `Always`
    case location

    var grantOptions: [String] {
        switch self {
        case .allow: ["Allow"]
        case .location: ["WhileUsing", "Always"]
        }
    }
}

/// A privacy-relevant capability of an application.
///
/// The raw value is the TCC service name as it appears in a PPPC payload.
/// Services that only exist in declarative management carry their DDM name,
/// and the iOS-only subjects carry the name their `Info.plist` keys use.
enum PrivilegeService: String, CaseIterable, Identifiable, Sendable {
    case accessibility = "Accessibility"
    case addressBook = "AddressBook"
    case appleEvents = "AppleEvents"
    case bluetoothAlways = "BluetoothAlways"
    case calendar = "Calendar"
    case camera = "Camera"
    case fileProviderPresence = "FileProviderPresence"
    case listenEvent = "ListenEvent"
    case localNetwork = "LocalNetwork"
    case location = "Location"
    case mediaLibrary = "MediaLibrary"
    case microphone = "Microphone"
    case photos = "Photos"
    case postEvent = "PostEvent"
    case reminders = "Reminders"
    case screenCapture = "ScreenCapture"
    case speechRecognition = "SpeechRecognition"
    case systemPolicyAllFiles = "SystemPolicyAllFiles"
    case systemPolicyAppBundles = "SystemPolicyAppBundles"
    case systemPolicyAppData = "SystemPolicyAppData"
    case systemPolicyDesktopFolder = "SystemPolicyDesktopFolder"
    case systemPolicyDocumentsFolder = "SystemPolicyDocumentsFolder"
    case systemPolicyDownloadsFolder = "SystemPolicyDownloadsFolder"
    case systemPolicyNetworkVolumes = "SystemPolicyNetworkVolumes"
    case systemPolicyRemovableVolumes = "SystemPolicyRemovableVolumes"
    case systemPolicySysAdminFiles = "SystemPolicySysAdminFiles"

    // Subjects that exist only on iOS and iPadOS. macOS has no TCC service for
    // any of them and no declaration carries one, so they can only ever be
    // reported. They are here so an iOS analysis is complete rather than
    // quietly short of what the app actually asks for.
    case alarmKit = "AlarmKit"
    case faceID = "FaceID"
    case focusStatus = "FocusStatus"
    case health = "Health"
    case homeKit = "HomeKit"
    case identity = "Identity"
    case motion = "Motion"
    case siri = "Siri"
    case userNotifications = "UserNotifications"
    case userTracking = "UserTracking"

    var id: String { rawValue }

    /// Whether this is one of the iOS-only subjects above.
    var isIOSOnly: Bool {
        switch self {
        case .alarmKit, .faceID, .focusStatus, .health, .homeKit, .identity,
             .motion, .siri, .userNotifications, .userTracking: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .addressBook: "Contacts"
        case .appleEvents: "Apple Events"
        case .bluetoothAlways: "Bluetooth"
        case .calendar: "Calendar"
        case .camera: "Camera"
        case .fileProviderPresence: "File Provider Presence"
        case .listenEvent: "Input Monitoring"
        case .localNetwork: "Local Network"
        case .location: "Location Services"
        case .mediaLibrary: "Media & Apple Music"
        case .microphone: "Microphone"
        case .photos: "Photos"
        case .postEvent: "Send Keystrokes"
        case .reminders: "Reminders"
        case .screenCapture: "Screen & System Audio Recording"
        case .speechRecognition: "Speech Recognition"
        case .systemPolicyAllFiles: "Full Disk Access"
        case .systemPolicyAppBundles: "App Management"
        case .systemPolicyAppData: "App Data"
        case .systemPolicyDesktopFolder: "Desktop Folder"
        case .systemPolicyDocumentsFolder: "Documents Folder"
        case .systemPolicyDownloadsFolder: "Downloads Folder"
        case .systemPolicyNetworkVolumes: "Network Volumes"
        case .systemPolicyRemovableVolumes: "Removable Volumes"
        case .systemPolicySysAdminFiles: "System Administration"
        case .alarmKit: "Alarms & Timers"
        case .faceID: "Face ID"
        case .focusStatus: "Focus Status"
        case .health: "Health"
        case .homeKit: "Home"
        case .identity: "Identity Documents"
        case .motion: "Motion & Fitness"
        case .siri: "Siri"
        case .userNotifications: "Notifications"
        case .userTracking: "Tracking"
        }
    }

    var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .addressBook: "person.crop.circle"
        case .appleEvents: "arrow.left.arrow.right.square"
        case .bluetoothAlways: "wave.3.right"
        case .calendar: "calendar"
        case .camera: "camera"
        case .fileProviderPresence: "externaldrive.badge.icloud"
        case .listenEvent: "keyboard"
        case .localNetwork: "network"
        case .location: "location"
        case .mediaLibrary: "music.note"
        case .microphone: "mic"
        case .photos: "photo.on.rectangle"
        case .postEvent: "keyboard.badge.ellipsis"
        case .reminders: "checklist"
        case .screenCapture: "rectangle.dashed.badge.record"
        case .speechRecognition: "waveform"
        case .systemPolicyAllFiles: "externaldrive"
        case .systemPolicyAppBundles: "app.badge.checkmark"
        case .systemPolicyAppData: "shippingbox"
        case .systemPolicyDesktopFolder: "menubar.dock.rectangle"
        case .systemPolicyDocumentsFolder: "folder"
        case .systemPolicyDownloadsFolder: "arrow.down.circle"
        case .systemPolicyNetworkVolumes: "externaldrive.connected.to.line.below"
        case .systemPolicyRemovableVolumes: "externaldrive.badge.plus"
        case .systemPolicySysAdminFiles: "gearshape.2"
        case .alarmKit: "alarm"
        case .faceID: "faceid"
        case .focusStatus: "moon"
        case .health: "heart"
        case .homeKit: "house"
        case .identity: "person.text.rectangle"
        case .motion: "figure.walk"
        case .siri: "sparkles"
        case .userNotifications: "bell"
        case .userTracking: "hand.raised.slash"
        }
    }

    /// The `Services` key in a PPPC payload, when one exists.
    var pppcServiceKey: String? {
        switch self {
        case _ where isIOSOnly: nil
        case .localNetwork, .location: nil
        default: rawValue
        }
    }

    var pppcSupport: PPPCSupport {
        switch self {
        case _ where isIOSOnly: .unsupported
        case .localNetwork, .location: .unsupported
        // Apple's schema: "A profile can't grant access … it can only deny it."
        case .camera, .microphone, .screenCapture: .denyOnly
        default: .grantAndDeny
        }
    }

    /// `AllowStandardUserToSetSystemService` is only valid for these two.
    var allowsStandardUserOverride: Bool {
        self == .listenEvent || self == .screenCapture
    }

    /// Deprecated as a PPPC key in macOS 27 in favour of the DDM privacy keys.
    var isPPPCDeprecatedInMacOS27: Bool {
        switch self {
        case .camera, .microphone, .accessibility, .speechRecognition, .bluetoothAlways: true
        default: false
        }
    }

    /// The key inside `Privacy.PermissionDefaults` of a
    /// `com.apple.configuration.app.settings` declaration, if one exists.
    var ddmPrivacyKey: String? {
        switch self {
        case .accessibility: "Accessibility"
        case .bluetoothAlways: "Bluetooth"
        case .camera: "Camera"
        case .speechRecognition: "Dictation"
        case .localNetwork: "LocalNetwork"
        case .location: "Location"
        case .microphone: "Microphone"
        default: nil
        }
    }

    var ddmPrivacyValues: DDMPrivacyValues? {
        guard ddmPrivacyKey != nil else { return nil }
        return self == .location ? .location : .allow
    }

    /// A short, honest sentence about how far MDM reaches for this service.
    /// Shown verbatim in the UI so nobody ships a profile that cannot work.
    var manageabilitySummary: String {
        switch (pppcSupport, ddmPrivacyKey != nil) {
        case _ where isIOSOnly:
            """
            Nothing carries this. There is no TCC service for it and no DDM privacy key \
            for it, on any platform — the user grants it in the app, or it stays off.
            """
        case (.grantAndDeny, true):
            "A PPPC profile can allow or deny this, but the key is deprecated in macOS 27 — prefer the DDM declaration."
        case (.grantAndDeny, false):
            "A PPPC profile can allow or deny this. There is no DDM privacy key for it."
        case (.denyOnly, true):
            "A PPPC profile can only deny this. Use the DDM declaration on macOS 27 and later to allow it."
        case (.denyOnly, false):
            "A PPPC profile can only deny this — no MDM can grant it. The user has to approve it themselves."
        case (.unsupported, true):
            "Only manageable through the DDM declaration, on macOS 27 and later."
        case (.unsupported, false):
            "Not manageable through MDM at all."
        }
    }
}
