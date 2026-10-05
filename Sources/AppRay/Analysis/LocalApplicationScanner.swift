import Foundation

/// Lists installed applications well enough to search by name, without
/// running the full analysis on any of them.
///
/// Scanned one level deep in each directory only — enough for how admins
/// actually organise these folders, without walking the whole filesystem.
enum LocalApplicationScanner {
    private static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
    }

    static func scan() async -> [LocalApplicationSummary] {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    private static func scanSynchronously() -> [LocalApplicationSummary] {
        let manager = FileManager.default
        var seenURLs = Set<URL>()
        var results: [LocalApplicationSummary] = []

        for directory in searchDirectories {
            guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                let resolved = entry.resolvingSymlinksInPath()
                guard seenURLs.insert(resolved).inserted else { continue }
                guard let layout = BundleLayout.resolve(droppedURL: resolved),
                      let info = try? BundleReader.readInfo(in: layout) else { continue }
                results.append(LocalApplicationSummary(
                    url: resolved,
                    name: info.name,
                    bundleIdentifier: info.bundleIdentifier
                ))
            }
        }

        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
