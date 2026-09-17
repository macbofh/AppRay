import CoreServices
import Foundation

/// Reads the `com.apple.quarantine` extended attribute off a bundle.
enum QuarantineReader {
    /// `nil` when the attribute is not present.
    static func read(at url: URL) -> QuarantineInfo? {
        guard
            let properties = try? url
                .resourceValues(forKeys: [.quarantinePropertiesKey])
                .quarantineProperties
        else { return nil }

        return QuarantineInfo(
            agentName: properties[kLSQuarantineAgentNameKey as String] as? String,
            timestamp: properties[kLSQuarantineTimeStampKey as String] as? Date
        )
    }
}
