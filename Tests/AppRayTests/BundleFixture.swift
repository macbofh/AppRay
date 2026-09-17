import Foundation

/// Builds a small signed bundle on disk, so a test can tamper with a shape the
/// machine does not happen to have installed — a macOS app with an extension
/// inside it, and the flat layout an iOS app uses.
///
/// `codesign` here is the test's own tool. AppRay itself never shells out to
/// it; that is the point of the tests that compare the two.
enum BundleFixture {
    /// A macOS-shaped app with a signed `.appex` inside it, the appex holding a
    /// sealed resource of its own. Tampering with that resource is the case a
    /// bundle's outer seal cannot see by itself.
    static func nested(in directory: URL) throws -> URL {
        let app = directory.appending(path: "Fixture.app")
        let appex = app.appending(path: "Contents/PlugIns/Inner.appex")

        try write(
            plist: ["CFBundleExecutable": "Inner", "CFBundleIdentifier": "com.appray.fixture.inner"],
            executable: "Inner",
            resources: ["Resources/data.txt": "sealed payload\n"],
            contentsOf: appex.appending(path: "Contents")
        )
        try write(
            plist: ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "com.appray.fixture"],
            executable: "Fixture",
            resources: [:],
            contentsOf: app.appending(path: "Contents")
        )

        // Inside out: the outer seal records the signed appex, so the appex has
        // to be signed first.
        try sign(appex)
        try sign(app)
        return app
    }

    /// The layout an iOS app uses: no `Contents` directory, the executable and
    /// `_CodeSignature` both sitting at the bundle root.
    static func flat(in directory: URL) throws -> URL {
        let app = directory.appending(path: "Flat.app")
        try write(
            plist: [
                "CFBundleExecutable": "Flat",
                "CFBundleIdentifier": "com.appray.flat",
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
            ],
            executable: "Flat",
            resources: ["data.txt": "sealed payload\n"],
            contentsOf: app
        )
        try sign(app)
        return app
    }

    // MARK: - Pieces

    /// A real Mach-O is needed for anything codesign will accept, and the
    /// smallest one every Mac has is already on disk.
    private static let stockExecutable = URL(fileURLWithPath: "/bin/echo")

    private static func write(
        plist: [String: Any],
        executable: String,
        resources: [String: String],
        contentsOf root: URL
    ) throws {
        var plist = plist
        plist["CFBundleName"] = executable
        plist["CFBundlePackageType"] = "APPL"
        plist["CFBundleShortVersionString"] = "1.0"

        let executableDirectory = root.lastPathComponent == "Contents"
            ? root.appending(path: "MacOS")
            : root
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: stockExecutable,
            to: executableDirectory.appending(path: executable)
        )

        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appending(path: "Info.plist"))

        for (path, contents) in resources {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
    }

    private static func sign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
