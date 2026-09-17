import CryptoKit
import Foundation

/// The hashes a bundle's `CodeResources` sealed, keyed the way that file keys
/// them: relative to the directory the seal was written against.
///
/// Read only to explain a file that has *already* failed validation — never to
/// decide whether it failed. Security.framework owns the verdict; this only
/// answers "what was it supposed to be?".
struct SealedResourceManifest: Sendable {
    /// How `CodeResources` seals one path. Not every entry is a file hash, so
    /// not every offending file has a hash to show.
    enum Seal: Hashable, Sendable {
        /// A `files2` entry: SHA-256 of the file's bytes.
        case sha256(String)
        /// A `files` entry with no `files2` counterpart, from an older
        /// signature: SHA-1.
        case sha1(String)
        /// Nested code, sealed by its own code directory and its own manifest
        /// rather than by a hash of its bytes.
        case nestedCode
        /// A symbolic link, sealed by where it points rather than by contents.
        case symlink(target: String)
    }

    private let seals: [String: Seal]

    /// `nil` when the manifest is absent or unreadable — which is itself worth
    /// saying out loud rather than papering over.
    static func read(at manifestURL: URL) -> SealedResourceManifest? {
        guard let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any]
        else { return nil }

        var seals: [String: Seal] = [:]
        // `files` is the legacy half and `files2` supersedes it, so v2 wins
        // wherever both describe the same path.
        for (path, entry) in plist["files"] as? [String: Any] ?? [:] {
            seals[path] = legacySeal(from: entry)
        }
        for (path, entry) in plist["files2"] as? [String: Any] ?? [:] {
            if let seal = seal(from: entry) { seals[path] = seal }
        }
        return SealedResourceManifest(seals: seals)
    }

    /// `nil` when the manifest does not list the path at all.
    subscript(path: String) -> Seal? { seals[path] }

    private static func seal(from entry: Any) -> Seal? {
        guard let entry = entry as? [String: Any] else { return nil }
        if let target = entry["symlink"] as? String { return .symlink(target: target) }
        if entry["cdhash"] != nil { return .nestedCode }
        if let hash = entry["hash2"] as? Data { return .sha256(hexString(from: hash)) }
        if let hash = entry["hash"] as? Data { return .sha1(hexString(from: hash)) }
        return nil
    }

    /// A v1 entry is either the raw digest or a dictionary wrapping it.
    private static func legacySeal(from entry: Any) -> Seal? {
        if let hash = entry as? Data { return .sha1(hexString(from: hash)) }
        if let hash = (entry as? [String: Any])?["hash"] as? Data {
            return .sha1(hexString(from: hash))
        }
        return nil
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

extension SealedResourceManifest.Seal {
    /// The same digest of the file as it is on disk now, so the two can be put
    /// side by side. `nil` for a seal that is not a file hash.
    func digestOnDisk(at url: URL) -> String? {
        switch self {
        case .sha256: FileDigest.sha256(of: url)
        case .sha1: FileDigest.sha1(of: url)
        case .nestedCode, .symlink: nil
        }
    }

    var algorithm: String? {
        switch self {
        case .sha256: "SHA-256"
        case .sha1: "SHA-1"
        case .nestedCode, .symlink: nil
        }
    }

    var sealedDigest: String? {
        switch self {
        case .sha256(let hash), .sha1(let hash): hash
        case .nestedCode, .symlink: nil
        }
    }
}

/// Digests a file without reading it into memory. A modified framework can be
/// hundreds of megabytes, and this runs on a bundle that is already failing.
enum FileDigest {
    private static let chunkSize = 1 << 20

    static func sha256(of url: URL) -> String? {
        var hasher = SHA256()
        return stream(url) { hasher.update(data: $0) }
            ? hasher.finalize().map { String(format: "%02x", $0) }.joined()
            : nil
    }

    static func sha1(of url: URL) -> String? {
        var hasher = Insecure.SHA1()
        return stream(url) { hasher.update(data: $0) }
            ? hasher.finalize().map { String(format: "%02x", $0) }.joined()
            : nil
    }

    private static func stream(_ url: URL, into absorb: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            absorb(chunk)
        }
        return true
    }
}
