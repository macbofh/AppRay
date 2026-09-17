import Foundation

/// Parses the load commands of a Mach-O executable.
///
/// Framework linkage is the analyzer's strongest secondary signal: an app that
/// links ScreenCaptureKit almost certainly records the screen even when it
/// never says so in `Info.plist`.
enum MachOReader {
    // Fat headers are stored big-endian, so reading the first four bytes
    // little-endian like every other magic yields these byte-swapped values.
    private static let fatMagic: UInt32 = 0xbeba_feca
    private static let fatMagic64: UInt32 = 0xbfba_feca
    private static let machMagic64: UInt32 = 0xfeed_facf
    private static let machCigam64: UInt32 = 0xcffa_edfe
    private static let machMagic32: UInt32 = 0xfeed_face
    private static let machCigam32: UInt32 = 0xcefa_edfe

    private static let loadDylib: UInt32 = 0x0c
    private static let loadWeakDylib: UInt32 = 0x8000_0018
    private static let reexportDylib: UInt32 = 0x8000_001f
    private static let buildVersion: UInt32 = 0x32
    private static let versionMinMacOS: UInt32 = 0x24

    static func read(at url: URL) -> MachOInfo {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 8
        else { return .empty }

        var architectures: [String] = []
        var libraries: Set<String> = []
        var minimumOS: String?
        var sdk: String?

        for slice in slices(in: data) {
            guard let header = readHeader(data, at: slice) else { continue }
            architectures.append(header.architecture)
            let parsed = readLoadCommands(
                data,
                start: slice + header.headerSize,
                count: header.commandCount,
                swapped: header.swapped
            )
            libraries.formUnion(parsed.libraries)
            minimumOS = minimumOS ?? parsed.minimumOS
            sdk = sdk ?? parsed.sdk
        }

        return MachOInfo(
            architectures: architectures,
            linkedLibraries: libraries.sorted(),
            minimumOSVersion: minimumOS,
            sdkVersion: sdk
        )
    }

    /// Byte offsets of every Mach-O image in the file — one for a thin binary,
    /// several for a universal one.
    private static func slices(in data: Data) -> [Int] {
        guard let magic = data.readUInt32(at: 0, swapped: false) else { return [] }

        guard magic == fatMagic || magic == fatMagic64 else { return [0] }

        // Fat headers are always big-endian on disk.
        guard let count = data.readUInt32(at: 4, swapped: true) else { return [] }
        let entrySize = magic == fatMagic64 ? 32 : 20
        // Guard against a corrupt count claiming millions of architectures.
        guard count < 64 else { return [] }

        return (0..<Int(count)).compactMap { index in
            let entry = 8 + index * entrySize
            if magic == fatMagic64 {
                return data.readUInt64(at: entry + 8, swapped: true).map(Int.init)
            }
            return data.readUInt32(at: entry + 8, swapped: true).map(Int.init)
        }
    }

    private struct Header {
        var architecture: String
        var headerSize: Int
        var commandCount: UInt32
        var swapped: Bool
    }

    private static func readHeader(_ data: Data, at offset: Int) -> Header? {
        guard let magic = data.readUInt32(at: offset, swapped: false) else { return nil }
        let is64: Bool
        let swapped: Bool
        switch magic {
        case machMagic64: (is64, swapped) = (true, false)
        case machCigam64: (is64, swapped) = (true, true)
        case machMagic32: (is64, swapped) = (false, false)
        case machCigam32: (is64, swapped) = (false, true)
        default: return nil
        }

        guard let cpuType = data.readUInt32(at: offset + 4, swapped: swapped),
              let cpuSubtype = data.readUInt32(at: offset + 8, swapped: swapped),
              let commandCount = data.readUInt32(at: offset + 16, swapped: swapped)
        else { return nil }

        return Header(
            architecture: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
            headerSize: is64 ? 32 : 28,
            commandCount: commandCount,
            swapped: swapped
        )
    }

    private static func readLoadCommands(
        _ data: Data,
        start: Int,
        count: UInt32,
        swapped: Bool
    ) -> (libraries: [String], minimumOS: String?, sdk: String?) {
        var libraries: [String] = []
        var minimumOS: String?
        var sdk: String?
        var cursor = start

        for _ in 0..<count {
            guard let command = data.readUInt32(at: cursor, swapped: swapped),
                  let size = data.readUInt32(at: cursor + 4, swapped: swapped),
                  size >= 8,
                  cursor + Int(size) <= data.count
            else { break }

            switch command {
            case loadDylib, loadWeakDylib, reexportDylib:
                if let nameOffset = data.readUInt32(at: cursor + 8, swapped: swapped),
                   let name = data.readCString(at: cursor + Int(nameOffset), limit: cursor + Int(size)) {
                    libraries.append(name)
                }
            case buildVersion:
                minimumOS = minimumOS ?? data.readUInt32(at: cursor + 12, swapped: swapped)
                    .map(versionString)
                sdk = sdk ?? data.readUInt32(at: cursor + 16, swapped: swapped).map(versionString)
            case versionMinMacOS:
                minimumOS = minimumOS ?? data.readUInt32(at: cursor + 8, swapped: swapped)
                    .map(versionString)
                sdk = sdk ?? data.readUInt32(at: cursor + 12, swapped: swapped).map(versionString)
            default:
                break
            }
            cursor += Int(size)
        }

        return (libraries, minimumOS, sdk)
    }

    private static func versionString(_ packed: UInt32) -> String {
        let major = packed >> 16
        let minor = (packed >> 8) & 0xff
        let patch = packed & 0xff
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    private static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        switch cpuType {
        case 0x0100_0007: "x86_64"
        case 0x0000_0007: "i386"
        case 0x0100_000c: (cpuSubtype & 0x00ff_ffff) == 2 ? "arm64e" : "arm64"
        case 0x0000_000c: "arm"
        default: "cputype \(cpuType)"
        }
    }
}

private extension Data {
    func readUInt32(at offset: Int, swapped: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        let value = (0..<4).reduce(UInt32(0)) { result, index in
            result | (UInt32(self[base + index]) << (8 * UInt32(index)))
        }
        return swapped ? value.byteSwapped : value
    }

    func readUInt64(at offset: Int, swapped: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let base = startIndex + offset
        let value = (0..<8).reduce(UInt64(0)) { result, index in
            result | (UInt64(self[base + index]) << (8 * UInt64(index)))
        }
        return swapped ? value.byteSwapped : value
    }

    func readCString(at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < limit, limit <= count else { return nil }
        var bytes: [UInt8] = []
        for index in offset..<limit {
            let byte = self[startIndex + index]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
