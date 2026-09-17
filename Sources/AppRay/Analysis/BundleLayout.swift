import Foundation

/// Which platform's bundle layout an app uses.
///
/// Apple silicon Macs run iOS and iPadOS apps, and those bundles are laid out
/// flat — there is no `Contents` directory at all. Anything that walks a
/// bundle has to ask which shape it is looking at rather than assume.
enum BundlePlatform: String, Hashable, Sendable {
    case macOS
    case iOS

    /// What to call it in the interface. One name covers iOS and iPadOS
    /// because nothing in a bundle tells the two apart.
    var label: String {
        switch self {
        case .macOS: "macOS app"
        case .iOS: "iOS or iPadOS app"
        }
    }

    /// What has to be said before any of the app's manageability answers can
    /// be trusted. `nil` for macOS, which is the ground the rest of AppRay
    /// stands on.
    var manageabilityCaveat: String? {
        switch self {
        case .macOS: nil
        case .iOS:
            """
            Every answer here describes macOS. Apple's own schema lists the PPPC payload \
            as unavailable on iOS, so no profile carries any of this to an iPhone or iPad — \
            a declaration is the only channel that reaches an app there.
            """
        }
    }
}

/// Where the pieces of a bundle live.
///
/// This is the one place the macOS and iOS layouts differ, and every reader
/// goes through it instead of hard-coding `Contents/`.
struct BundleLayout: Hashable, Sendable {
    var platform: BundlePlatform
    /// The bundle the user pointed at.
    var droppedURL: URL
    /// The bundle actually analysed. Differs from `droppedURL` when an iOS app
    /// arrives inside a macOS wrapper bundle.
    var bundleURL: URL
    /// The directory holding `Info.plist` and `_CodeSignature`: `Contents` on
    /// macOS, the bundle root on iOS.
    var contentsURL: URL
    /// The directory holding the main executable: `Contents/MacOS` on macOS,
    /// the bundle root on iOS.
    var executableDirectoryURL: URL

    var infoPlistURL: URL { contentsURL.appending(path: "Info.plist") }

    /// The sealed-resource manifest the signature was built from.
    var codeResourcesURL: URL {
        contentsURL.appending(path: "_CodeSignature/CodeResources")
    }

    /// The directory the paths inside `CodeResources` are relative to.
    var sealedResourcesRootURL: URL { contentsURL }

    /// True when what was analysed is not what was dropped.
    var isWrapped: Bool { bundleURL != droppedURL }

    static func macOS(bundleURL: URL) -> BundleLayout {
        let contents = bundleURL.appending(path: "Contents")
        return BundleLayout(
            platform: .macOS,
            droppedURL: bundleURL,
            bundleURL: bundleURL,
            contentsURL: contents,
            executableDirectoryURL: contents.appending(path: "MacOS")
        )
    }

    /// A flat bundle: `Info.plist`, the executable and `_CodeSignature` all sit
    /// at the top level.
    static func iOS(bundleURL: URL, droppedURL: URL? = nil) -> BundleLayout {
        BundleLayout(
            platform: .iOS,
            droppedURL: droppedURL ?? bundleURL,
            bundleURL: bundleURL,
            contentsURL: bundleURL,
            executableDirectoryURL: bundleURL
        )
    }

    /// Works out which shape a bundle is by looking at what is on disk, rather
    /// than by trusting what the bundle says about itself. A macOS app keeps
    /// its `Info.plist` in `Contents`; an iOS app keeps it at the top level.
    ///
    /// `nil` when neither is there, which means this is not a bundle AppRay
    /// can read.
    static func resolve(droppedURL url: URL) -> BundleLayout? {
        let manager = FileManager.default

        let mac = macOS(bundleURL: url)
        if manager.fileExists(atPath: mac.infoPlistURL.path) { return mac }

        if let inner = wrappedBundleURL(in: url) {
            return iOS(bundleURL: inner, droppedURL: url)
        }

        let flat = iOS(bundleURL: url)
        return manager.fileExists(atPath: flat.infoPlistURL.path) ? flat : nil
    }

    // MARK: - The Mac App Store wrapper
    //
    // An iOS app installed on an Apple silicon Mac arrives inside an outer
    // bundle: the real iOS app sits in `Wrapper/`, and a `WrappedBundle`
    // symlink at the top level points at it.
    //
    // UNVERIFIED. No iOS app from the Mac App Store was installed on the
    // machine this was written on, so this one function is written from
    // Apple's description of the format and has never been run against a real
    // wrapper. It is kept separate so it can be corrected on its own.

    private static func wrappedBundleURL(in url: URL) -> URL? {
        let manager = FileManager.default

        func isBundle(_ candidate: URL) -> Bool {
            manager.fileExists(atPath: candidate.appending(path: "Info.plist").path)
        }

        let link = url.appending(path: "WrappedBundle")
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            let inner = URL(fileURLWithPath: destination, relativeTo: url).standardizedFileURL
            if isBundle(inner) { return inner }
        }

        // The symlink is the documented way in; the directory it points at is
        // the fallback for a bundle that was copied without preserving it.
        let wrapper = url.appending(path: "Wrapper")
        let entries = (try? manager.contentsOfDirectory(
            at: wrapper,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.first { $0.pathExtension == "app" && isBundle($0) }
    }
}
