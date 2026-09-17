import Foundation

/// Asks Gatekeeper what it makes of a bundle.
///
/// The only part of the analyzer that shells out. `SecAssessment` has no
/// supported public API for this, and `spctl` reports the assessment *source*
/// ("Notarized Developer ID", "Developer ID", "Unnotarized Developer ID"),
/// which is exactly the distinction an admin cares about.
enum GatekeeperReader {
    static func read(at url: URL) -> GatekeeperStatus {
        GatekeeperStatus(
            verdict: assess(url),
            hasStapledTicket: hasStapledTicket(url)
        )
    }

    private static func assess(_ url: URL) -> GatekeeperVerdict {
        guard let result = run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", url.path]) else {
            return .unknown("Could not run spctl.")
        }

        // spctl writes its verdict to stderr, one "key=value" per line.
        let source = result.output
            .split(separator: "\n")
            .first { $0.contains("source=") }
            .map { $0.replacingOccurrences(of: "source=", with: "").trimmingCharacters(in: .whitespaces) }

        if result.status == 0 {
            return .accepted(source: source ?? "accepted")
        }
        if result.output.contains("rejected") {
            return .rejected(reason: source ?? "rejected by Gatekeeper")
        }
        return .unknown(result.output.isEmpty ? "No verdict." : result.output)
    }

    private static func hasStapledTicket(_ url: URL) -> Bool {
        run("/usr/bin/xcrun", ["stapler", "validate", url.path])?.status == 0
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: these tools produce far less than a pipe buffer,
        // but reading first keeps the call safe if that ever changes.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
