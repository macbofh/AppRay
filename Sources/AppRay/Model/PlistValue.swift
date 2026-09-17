import Foundation

/// A property-list value in a form that is `Sendable` and `Hashable`, so parsed
/// `Info.plist` and entitlement dictionaries can travel across actors and drive
/// SwiftUI diffing without dragging `Any` around.
indirect enum PlistValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    init?(any value: Any) {
        // NSNumber bridges to Bool, Int and Double alike, so the boolean check
        // has to come first and has to go through CFBooleanGetTypeID — plain
        // `as? Bool` happily turns the integer 1 into `true`.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
            return
        }
        switch value {
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = .data(data)
        case let array as [Any]: self = .array(array.compactMap { PlistValue(any: $0) })
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.compactMapValues { PlistValue(any: $0) })
        default: return nil
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .integer(let value): value
        case .double(let value): value
        case .date(let value): value
        case .data(let value): value
        case .array(let values): values.map(\.anyValue)
        case .dictionary(let values): values.mapValues(\.anyValue)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [PlistValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var dictionaryValue: [String: PlistValue]? {
        if case .dictionary(let values) = self { return values }
        return nil
    }

    /// A one-line rendering for list rows. Containers report their size rather
    /// than their contents; the detail views expand those separately.
    var displayString: String {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .double(let value): String(value)
        case .date(let value): value.formatted(date: .abbreviated, time: .shortened)
        case .data(let value): "\(value.count) bytes"
        case .array(let values): values.count == 1 ? "1 item" : "\(values.count) items"
        case .dictionary(let values): values.count == 1 ? "1 key" : "\(values.count) keys"
        }
    }

    var isContainer: Bool {
        switch self {
        case .array, .dictionary: true
        default: false
        }
    }

    static func dictionary(fromPropertyList value: Any?) -> [String: PlistValue] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { PlistValue(any: $0) }
    }
}
