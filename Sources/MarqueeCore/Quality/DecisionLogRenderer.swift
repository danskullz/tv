import Foundation

public struct DecisionLogFactor: Sendable, Equatable {
    public var name: String
    public var points: Double?
    public var note: String?
}

public struct DecisionLogSummary: Sendable, Equatable {
    public var headline: String
    public var summary: String?
    public var reasons: [String]
    public var quality: String?
    public var profile: String?
    public var formatScore: Int?
    public var streamabilityScore: Double?
    public var streamability: [DecisionLogFactor]
    public var rejectionCounts: [String: Int]
    public var failure: String?
    public var failureDetail: String?
}

/// Turns the version-tolerant JSON snapshot stored on a grab into plain, display-ready facts.
public enum DecisionLogRenderer {
    public static func render(_ value: JSONValue) -> DecisionLogSummary {
        let factors: [DecisionLogFactor] = (value["streamability"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return DecisionLogFactor(name: name, points: entry["points"]?.numberValue, note: entry["note"]?.stringValue)
        }
        let rejectionCounts = value["candidates"]?["rejections"]?.objectValue?.compactMapValues(\.intValue) ?? [:]
        return DecisionLogSummary(
            headline: value["headline"]?.stringValue ?? "Release decision",
            summary: value["summary"]?.stringValue,
            reasons: value["reasons"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            quality: value["quality"]?.stringValue, profile: value["profile"]?.stringValue,
            formatScore: value["formatScore"]?.intValue, streamabilityScore: value["streamabilityScore"]?.numberValue,
            streamability: factors, rejectionCounts: rejectionCounts, failure: value["failure"]?.stringValue,
            failureDetail: value["failureDetail"]?.stringValue)
    }
}

private extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var intValue: Int? { if case .int(let value) = self { value } else { nil } }
    var numberValue: Double? {
        switch self { case .int(let value): Double(value); case .double(let value): value; default: nil }
    }
    var arrayValue: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let values) = self { values } else { nil } }
}
