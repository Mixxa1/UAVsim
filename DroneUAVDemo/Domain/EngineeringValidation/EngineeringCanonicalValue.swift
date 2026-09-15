import CryptoKit
import Foundation

/// A value in the form engineering data is compared and fingerprinted in.
///
/// The Validation Engine decides what to recalculate by comparing fingerprints of what a test
/// consumed with fingerprints of the configuration now. That only works if the same
/// engineering content always produces the same bytes, whatever path built it: a dictionary
/// filled in a different order, a `Float` that went through `Double` and back, a `-0.0` left
/// behind by a mirrored mount, a blueprint decoded from disk rather than built in memory.
/// `JSONEncoder` gives no such promise, so this type owns its serialisation.
///
/// Rules of the canonical form:
/// - object keys sorted by their UTF-8 bytes;
/// - numbers written as the shortest string that round-trips a `Double`, with `-0.0` folded
///   into `0.0` and non-finite values spelled out, so they never compare equal to a number;
/// - arrays keep their order, because order is meaning (mount 0 is not mount 3).
///
/// There is deliberately no tolerance here. Whether a 0.1 mm shift should keep a structural
/// result valid is an engineering decision that belongs to a test definition, stated where it
/// can be argued with — not a rounding step hidden inside a hash.
indirect enum EngineeringCanonicalValue: Hashable, Codable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([EngineeringCanonicalValue])
    case object([String: EngineeringCanonicalValue])

    static func vector(_ v: SIMD3<Float>) -> EngineeringCanonicalValue {
        .array([.number(Double(v.x)), .number(Double(v.y)), .number(Double(v.z))])
    }

    static func vector(_ v: SIMD3<Double>) -> EngineeringCanonicalValue {
        .array([.number(v.x), .number(v.y), .number(v.z)])
    }

    static func vector(_ v: CodableVector3D) -> EngineeringCanonicalValue {
        .array([.number(v.x), .number(v.y), .number(v.z)])
    }

    static func numbers(_ values: [String: Double]) -> EngineeringCanonicalValue {
        .object(values.mapValues { .number($0) })
    }

    // MARK: Canonical bytes

    var canonicalString: String {
        var output = ""
        write(into: &output)
        return output
    }

    private func write(into output: inout String) {
        switch self {
        case let .number(value):
            output += Self.canonicalNumber(value)
        case let .string(value):
            output += "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": output += "\\\""
                case "\\": output += "\\\\"
                default:
                    if scalar.value < 0x20 {
                        output += String(format: "\\u%04x", scalar.value)
                    } else {
                        output.unicodeScalars.append(scalar)
                    }
                }
            }
            output += "\""
        case let .bool(value):
            output += value ? "true" : "false"
        case let .array(values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(into: &output)
            }
            output += "]"
        case let .object(values):
            output += "{"
            let keys = values.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                EngineeringCanonicalValue.string(key).write(into: &output)
                output += ":"
                values[key]!.write(into: &output)
            }
            output += "}"
        }
    }

    static func canonicalNumber(_ value: Double) -> String {
        if value.isNaN { return "\"nan\"" }
        if value.isInfinite { return value > 0 ? "\"+inf\"" : "\"-inf\"" }
        if value == 0 { return "0" }
        return "\(value)"
    }

    var fingerprint: String {
        EngineeringFingerprint.of(canonicalString)
    }

    // MARK: Codable
    //
    // Stored as plain JSON so a snapshot on disk reads like the data it describes. Decoding
    // cannot tell `1` from `1.0` or a number from a bool without help, so numbers and bools
    // are tried in the order that keeps a JSON `true` a bool.

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicKey.self) {
            var values: [String: EngineeringCanonicalValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(EngineeringCanonicalValue.self, forKey: key)
            }
            self = .object(values)
        } else if var array = try? decoder.unkeyedContainer() {
            var values: [EngineeringCanonicalValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(EngineeringCanonicalValue.self))
            }
            self = .array(values)
        } else {
            let single = try decoder.singleValueContainer()
            if let bool = try? single.decode(Bool.self) {
                self = .bool(bool)
            } else if let number = try? single.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try single.decode(String.self))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .number(value):
            var single = encoder.singleValueContainer()
            if value.isFinite {
                try single.encode(value == 0 ? 0.0 : value)
            } else {
                try single.encode(value.isNaN ? "nan" : (value > 0 ? "+inf" : "-inf"))
            }
        case let .string(value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case let .bool(value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case let .array(values):
            var array = encoder.unkeyedContainer()
            for value in values { try array.encode(value) }
        case let .object(values):
            var object = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in values {
                try object.encode(value, forKey: DynamicKey(stringValue: key))
            }
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// SHA-256 over canonical bytes, hex-encoded.
///
/// A cryptographic hash rather than the FNV-1a CADNext uses for file change detection: a
/// fingerprint here decides that a strength result is still true for a changed aircraft, and
/// an accidental collision would say so silently.
enum EngineeringFingerprint {
    static let absent = "absent"

    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of a keyed set of fingerprints — order-independent by construction.
    static func combine(_ items: [String: String]) -> String {
        EngineeringCanonicalValue.object(items.mapValues { .string($0) }).fingerprint
    }

    static func short(_ fingerprint: String) -> String {
        String(fingerprint.prefix(10))
    }
}
