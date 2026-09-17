import Foundation

/// Which platform's bundle layout an app uses.
///
/// Apple silicon Macs run iOS and iPadOS apps, and those bundles are laid out
/// flat — there is no `Contents` directory at all. Anything that walks a
/// bundle has to ask which shape it is looking at rather than assume.
enum BundlePlatform: String, Hashable, Sendable {
    case macOS
    case iOS
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
}
