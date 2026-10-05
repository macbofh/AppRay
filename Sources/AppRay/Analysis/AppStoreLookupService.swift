import Foundation

enum AppStoreLookupError: LocalizedError {
    case emptyTerm
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .emptyTerm: "Type something to search for."
        case .network(let error): error.localizedDescription
        }
    }
}

/// Looks up an app's Bundle ID by name through Apple's public App Store
/// Search API — for an app the admin has no local copy of, and so cannot
/// read a Bundle ID from directly.
///
/// `applepreinstalled` is a search term Apple's own catalog recognises: it
/// finds Apple's built-in apps (Safari, Camera, Calculator) and their
/// Bundle IDs, which otherwise never show up in a name search.
enum AppStoreLookupService {
    private struct Response: Decodable {
        var results: [Result]
    }

    /// Every field this app surfaces from Apple's catalog. Apple documents
    /// none of this formally — the shape is reverse-engineered from what the
    /// endpoint actually returns — so everything stays optional.
    private struct Result: Decodable {
        var trackId: Int
        var trackName: String
        var trackCensoredName: String?
        var bundleId: String?
        var artistName: String
        var artistId: Int?
        var artistViewUrl: String?
        var sellerName: String?
        var sellerUrl: String?
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
        var genres: [String]?
        var minimumOsVersion: String?
        var fileSizeBytes: String?
        var releaseDate: String?
        var currentVersionReleaseDate: String?
        var releaseNotes: String?
        var description: String?
        var trackViewUrl: String?
        var contentAdvisoryRating: String?
        var trackContentRating: String?
        var advisories: [String]?
        var features: [String]?
        var supportedDevices: [String]?
        var languageCodesISO2A: [String]?
        var isVppDeviceBasedLicensingEnabled: Bool?
        var artworkUrl60: String?
        var artworkUrl100: String?
        var artworkUrl512: String?
        var screenshotUrls: [String]?
        var ipadScreenshotUrls: [String]?
        var appletvScreenshotUrls: [String]?
    }

    static func search(
        term: String,
        session: URLSession = .shared
    ) async throws -> [AppStoreLookupResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppStoreLookupError.emptyTerm }

        async let mac = results(for: trimmed, entity: "macSoftware", platform: .macOS, session: session)
        async let ios = results(for: trimmed, entity: "software", platform: .iOS, session: session)
        return try await mac + (try await ios)
    }

    private static func results(
        for term: String,
        entity: String,
        platform: AppStoreLookupResult.Platform,
        session: URLSession
    ) async throws -> [AppStoreLookupResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components.url else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let formatter = ISO8601DateFormatter()
            return response.results.compactMap { result -> AppStoreLookupResult? in
                guard let bundleId = result.bundleId else { return nil }
                return AppStoreLookupResult(
                    trackId: result.trackId,
                    name: result.trackName,
                    censoredName: result.trackCensoredName,
                    bundleIdentifier: bundleId,
                    developerName: result.artistName,
                    developerId: result.artistId,
                    developerViewURL: result.artistViewUrl.flatMap(URL.init(string:)),
                    sellerName: result.sellerName,
                    sellerURL: result.sellerUrl.flatMap(URL.init(string:)),
                    platform: platform,
                    kind: result.kind,
                    wrapperType: result.wrapperType,
                    version: result.version,
                    price: result.price,
                    currency: result.currency,
                    formattedPrice: result.formattedPrice,
                    averageUserRating: result.averageUserRating,
                    userRatingCount: result.userRatingCount,
                    averageUserRatingForCurrentVersion: result.averageUserRatingForCurrentVersion,
                    userRatingCountForCurrentVersion: result.userRatingCountForCurrentVersion,
                    genres: result.genres ?? [],
                    minimumOSVersion: result.minimumOsVersion,
                    fileSizeBytes: result.fileSizeBytes,
                    releaseDate: result.releaseDate.flatMap(formatter.date(from:)),
                    currentVersionReleaseDate: result.currentVersionReleaseDate.flatMap(formatter.date(from:)),
                    releaseNotes: result.releaseNotes,
                    appDescription: result.description,
                    appStoreURL: result.trackViewUrl.flatMap(URL.init(string:)),
                    contentAdvisoryRating: result.contentAdvisoryRating,
                    trackContentRating: result.trackContentRating,
                    advisories: result.advisories ?? [],
                    features: result.features ?? [],
                    supportedDevices: result.supportedDevices ?? [],
                    languageCodesISO2A: result.languageCodesISO2A ?? [],
                    isVppDeviceBasedLicensingEnabled: result.isVppDeviceBasedLicensingEnabled,
                    artworkURL60: result.artworkUrl60.flatMap(URL.init(string:)),
                    artworkURL100: result.artworkUrl100.flatMap(URL.init(string:)),
                    artworkURL512: result.artworkUrl512.flatMap(URL.init(string:)),
                    screenshotURLs: (result.screenshotUrls ?? []).compactMap(URL.init(string:)),
                    ipadScreenshotURLs: (result.ipadScreenshotUrls ?? []).compactMap(URL.init(string:)),
                    appletvScreenshotURLs: (result.appletvScreenshotUrls ?? []).compactMap(URL.init(string:))
                )
            }
        } catch {
            throw AppStoreLookupError.network(error)
        }
    }
}
