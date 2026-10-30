import Foundation

/// The categories a review can land in. The raw values are the exact strings
/// the model must return; anything else is a validation failure.
public enum ReviewCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case bug
    case billing
    case featureRequest = "feature_request"
    case praise
    case other
}

/// The typed output of one triage call.
public struct TriageDecision: Codable, Hashable, Sendable {
    public var category: ReviewCategory
    /// 1 (cosmetic) ... 4 (crash or lost user data; bugs only).
    public var severity: Int
    public var needsHuman: Bool
    /// Free text. Allowed to vary between runs; it is not part of the decision key.
    public var summary: String

    public init(category: ReviewCategory, severity: Int, needsHuman: Bool, summary: String) {
        self.category = category
        self.severity = severity
        self.needsHuman = needsHuman
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case category, severity, summary
        case needsHuman = "needs_human"
    }

    /// The fields that must be identical across runs for the same input.
    public var key: DecisionKey {
        DecisionKey(category: category, severity: severity, needsHuman: needsHuman)
    }

    /// The deterministic answer the pipeline gives when the model can't produce
    /// a valid decision within its retry budget: route to a person.
    public static func escalation(_ summary: String = "Escalated: no valid model decision") -> TriageDecision {
        TriageDecision(category: .other, severity: 3, needsHuman: true, summary: summary)
    }
}

/// The part of a decision that consistency is measured on. Summaries are
/// deliberately excluded: wording may vary, the routing decision may not.
public struct DecisionKey: Hashable, Sendable, CustomStringConvertible {
    public let category: ReviewCategory
    public let severity: Int
    public let needsHuman: Bool

    public init(category: ReviewCategory, severity: Int, needsHuman: Bool) {
        self.category = category
        self.severity = severity
        self.needsHuman = needsHuman
    }

    public var description: String {
        "\(category.rawValue) · s\(severity) · \(needsHuman ? "human" : "auto")"
    }
}
