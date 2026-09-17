import AppKit
import Foundation

/// Reads `Info.plist` and walks the bundle for nested executables.
enum BundleReader {
    static func readInfo(at url: URL) throws -> BundleInfo {
        let plistURL = url.appending(path: "Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = PlistValue.dictionary(fromPropertyList: raw)

        let displayName = info["CFBundleDisplayName"]?.stringValue
        let bundleName = info["CFBundleName"]?.stringValue

        return BundleInfo(
            url: url,
            name: displayName ?? bundleName ?? url.deletingPathExtension().lastPathComponent,
            displayName: displayName,
            bundleIdentifier: info["CFBundleIdentifier"]?.stringValue,
            shortVersion: info["CFBundleShortVersionString"]?.stringValue,
            buildVersion: info["CFBundleVersion"]?.stringValue,
            minimumSystemVersion: info["LSMinimumSystemVersion"]?.stringValue,
            applicationCategory: info["LSApplicationCategoryType"]?.stringValue,
            executableName: info["CFBundleExecutable"]?.stringValue,
            copyright: info["NSHumanReadableCopyright"]?.stringValue,
            isAgent: info["LSUIElement"]?.boolValue ?? false,
            urlSchemes: urlSchemes(in: info),
            raw: info
        )
    }

    static func executableURL(for info: BundleInfo) -> URL? {
        guard let executableName = info.executableName else { return nil }
        let url = info.url.appending(path: "Contents/MacOS").appending(path: executableName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Nested executables that carry privileges of their own. Each of these can
    /// need its own PPPC entry, which is exactly what admins forget.
    static func components(in bundleURL: URL) -> [BundleComponent] {
        let contents = bundleURL.appending(path: "Contents")
        let locations: [(String, BundleComponent.Kind)] = [
            ("Library/LaunchServices", .privilegedHelper),
            ("Library/LoginItems", .loginItem),
            ("Library/SystemExtensions", .systemExtension),
            ("XPCServices", .xpcService),
            ("PlugIns", .plugIn),
            ("Helpers", .helperApp),
            ("Frameworks", .helperApp),
        ]

        return locations.flatMap { path, kind in
            components(
                in: contents.appending(path: path),
                kind: kind,
                // Frameworks are scanned only for the helper apps some vendors
                // hide inside them (Chrome, Electron); the frameworks
                // themselves are not separate privilege subjects.
                appBundlesOnly: path == "Frameworks"
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func components(
        in directory: URL,
        kind: BundleComponent.Kind,
        appBundlesOnly: Bool
    ) -> [BundleComponent] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExecutableKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.flatMap { entry -> [BundleComponent] in
            if appBundlesOnly {
                // Recurse one level: Foo.framework/Versions/A/Helpers/Bar.app
                guard entry.pathExtension == "framework" else { return [] }
                return nestedApps(in: entry)
            }
            guard entry.pathExtension != "" || manager.isExecutableFile(atPath: entry.path) else {
                return []
            }
            return [component(at: entry, kind: kind)]
        }
    }

    private static func nestedApps(in framework: URL) -> [BundleComponent] {
        guard let enumerator = FileManager.default.enumerator(
            at: framework,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" }
            .map { component(at: $0, kind: .helperApp) }
    }

    private static func component(at url: URL, kind: BundleComponent.Kind) -> BundleComponent {
        let signature = CodeSignatureReader.briefSignature(at: url)
        let nestedInfo = try? readInfo(at: url)
        return BundleComponent(
            url: url,
            kind: kind,
            name: url.lastPathComponent,
            // Bare Mach-O helpers have no Info.plist, but their signing
            // identifier is a usable stand-in for a bundle ID.
            bundleIdentifier: nestedInfo?.bundleIdentifier ?? signature.signingIdentifier,
            teamIdentifier: signature.teamIdentifier,
            designatedRequirement: signature.requirement,
            cdHash: signature.cdHash
        )
    }

    private static func urlSchemes(in info: [String: PlistValue]) -> [String] {
        guard let types = info["CFBundleURLTypes"]?.arrayValue else { return [] }
        return types
            .compactMap(\.dictionaryValue)
            .flatMap { $0["CFBundleURLSchemes"]?.arrayValue ?? [] }
            .compactMap(\.stringValue)
            .sorted()
    }
}
