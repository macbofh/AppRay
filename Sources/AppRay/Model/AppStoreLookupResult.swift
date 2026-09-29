import Foundation

/// One match from an App Store search — everything Apple's public catalog
/// says about an app the admin does not have a local copy of. There is no
/// binary here, so nothing below ever carries a code signature, an
/// entitlement, or a privilege finding — only what the App Store itself
/// shows a shopper, and what its licensing metadata tells an MDM.
struct AppStoreLookupResult: Hashable, Sendable, Identifiable {
    enum Platform: String, Sendable {
        case macOS
        case iOS

        var label: String {
            switch self {
            case .macOS: "macOS"
            case .iOS: "iOS / iPadOS"
            }
        }
    }

    // A universal-purchase app can share the same trackId across its macOS
    // and iOS/iPadOS listings, so the platform has to be part of identity —
    // otherwise merging both searches produces duplicate IDs in the list.
    var id: String { "\(trackId).\(platform.rawValue)" }
    var trackId: Int
    var name: String
    var censoredName: String?
    var bundleIdentifier: String
    var developerName: String
    var developerId: Int?
    var developerViewURL: URL?
    var sellerName: String?
    var sellerURL: URL?
    var platform: Platform
    var kind: String?
    var wrapperType: String?

    var version: String?
    var price: Double?
    var currency: String?
    var formattedPrice: String?
    var averageUserRating: Double?
    var userRatingCount: Int?
    var averageUserRatingForCurrentVersion: Double?
    var userRatingCountForCurrentVersion: Int?
    var genres: [String]
    var minimumOSVersion: String?
    var fileSizeBytes: String?
    var releaseDate: Date?
    var currentVersionReleaseDate: Date?
    var releaseNotes: String?
    var appDescription: String?
    var appStoreURL: URL?
    var contentAdvisoryRating: String?
    var trackContentRating: String?
    var advisories: [String]
    var features: [String]
    var supportedDevices: [String]
    var languageCodesISO2A: [String]
    var isVppDeviceBasedLicensingEnabled: Bool?

    /// Icon artwork, largest first. Apple serves these at fixed sizes; there
    /// is no way to ask for a bigger one than whatever it published.
    var artworkURL60: URL?
    var artworkURL100: URL?
    var artworkURL512: URL?

    var screenshotURLs: [URL]
    var ipadScreenshotURLs: [URL]
    var appletvScreenshotURLs: [URL]

    /// The best icon Apple's catalog offers for this app.
    var largestArtworkURL: URL? {
        artworkURL512 ?? artworkURL100 ?? artworkURL60
    }

    var genre: String? { genres.first }

    var formattedFileSize: String? {
        guard let fileSizeBytes, let bytes = Int64(fileSizeBytes) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var formattedRating: String? {
        guard let averageUserRating else { return nil }
        let rounded = String(format: "%.1f", averageUserRating)
        guard let userRatingCount, userRatingCount > 0 else { return "\(rounded) ★" }
        return "\(rounded) ★ (\(userRatingCount.formatted()) ratings)"
    }

    var formattedCurrentVersionRating: String? {
        guard let averageUserRatingForCurrentVersion else { return nil }
        let rounded = String(format: "%.1f", averageUserRatingForCurrentVersion)
        guard let userRatingCountForCurrentVersion, userRatingCountForCurrentVersion > 0 else {
            return "\(rounded) ★"
        }
        return "\(rounded) ★ (\(userRatingCountForCurrentVersion.formatted()) ratings)"
    }
}
