import Foundation

/// One explicit decision rule. The id appears in the prompt so a rule can be
/// referenced in eval reports and code review ("case 6 needs R-money-first").
public struct DecisionRule: Hashable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// An input with the exact output we expect. Worked examples teach format and
/// judgment at the same time, which a style instruction can't.
public struct WorkedExample: Hashable, Sendable {
    public let input: String
    public let output: TriageDecision

    public init(input: String, output: TriageDecision) {
        self.input = input
        self.output = output
    }
}

/// Everything that used to hide behind `temperature: 0`, written down:
/// an output schema, explicit rules, worked examples and limits.
/// The same contract feeds the prompt and the validator, so the code enforces
/// exactly what the prompt asks for.
public struct DecisionContract: Hashable, Sendable {
    public let version: String
    public let rules: [DecisionRule]
    public let examples: [WorkedExample]
    public let maxSummaryLength: Int

    public init(version: String, rules: [DecisionRule], examples: [WorkedExample], maxSummaryLength: Int = 80) {
        self.version = version
        self.rules = rules
        self.examples = examples
        self.maxSummaryLength = maxSummaryLength
    }

    /// JSON Schema for structured outputs. Keys are sorted so the string is
    /// byte-stable across runs and platforms.
    public var jsonSchema: String {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["category", "needs_human", "severity", "summary"],
            "properties": [
                "category": ["type": "string", "enum": ReviewCategory.allCases.map(\.rawValue)],
                "severity": ["type": "integer", "minimum": 1, "maximum": 4],
                "needs_human": ["type": "boolean"],
                "summary": ["type": "string", "maxLength": maxSummaryLength],
            ] as [String: Any],
        ]
        return Self.canonicalJSON(schema)
    }

    /// The system prompt, rendered deterministically from the contract.
    public func systemPrompt() -> String {
        var lines: [String] = []
        lines.append("You triage App Store reviews for an iOS notes app. Contract \(version).")
        lines.append("Return one JSON object that matches this schema and nothing else:")
        lines.append(jsonSchema)
        lines.append("")
        lines.append("Decision rules (apply in order; the first rule that matches decides):")
        for rule in rules {
            lines.append("[\(rule.id)] \(rule.text)")
        }
        lines.append("")
        lines.append("Worked examples:")
        for example in examples {
            lines.append("Review: \(example.input)")
            lines.append("Output: \(Self.encode(example.output))")
        }
        return lines.joined(separator: "\n")
    }

    /// FNV-1a 64-bit hash of the rendered prompt. Log it with every response so
    /// an eval regression can be tied to the exact prompt that produced it.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in systemPrompt().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    public func contains(ruleID: String) -> Bool {
        rules.contains { $0.id == ruleID }
    }

    static func encode(_ decision: TriageDecision) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(decision), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func canonicalJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

public extension DecisionContract {
    static let baseRules: [DecisionRule] = [
        DecisionRule(id: "R-sev4", text: "Crash on launch or lost user data is bug, severity 4, needs_human true."),
        DecisionRule(id: "R-billing", text: "Charges, refunds and subscriptions are billing, severity 3, needs_human true."),
        DecisionRule(id: "R-sev2", text: "A feature that works but is slow or flaky is bug, severity 2, needs_human false."),
        DecisionRule(id: "R-feature", text: "A request for something the app doesn't do is feature_request, severity 1, needs_human false."),
        DecisionRule(id: "R-praise", text: "Pure praise is praise, severity 1, needs_human false."),
        DecisionRule(id: "R-other", text: "Anything with no actionable content is other, severity 1, needs_human false."),
    ]

    static let baseExamples: [WorkedExample] = [
        WorkedExample(
            input: "Widget shows yesterday's notes until I open the app.",
            output: TriageDecision(category: .bug, severity: 2, needsHuman: false, summary: "Widget content is stale until app launch")
        ),
        WorkedExample(
            input: "Please add Apple Pencil handwriting search.",
            output: TriageDecision(category: .featureRequest, severity: 1, needsHuman: false, summary: "Wants handwriting search for Pencil notes")
        ),
    ]

    /// The first version. The eval flags two cases it leaves to the model's judgment.
    static let triageV1 = DecisionContract(version: "triage-v1", rules: baseRules, examples: baseExamples)

    /// v2 adds the two rules the v1 eval asked for. Rule order matters: they sit
    /// first, because they resolve inputs that otherwise match two later rules.
    static let triageV2 = DecisionContract(
        version: "triage-v2",
        rules: [
            DecisionRule(id: "R-money-first", text: "Anything about charges, trials, subscriptions or refunds is billing, even if the user calls it a bug. Severity 3 if money was taken wrongly, otherwise 2; needs_human true."),
            DecisionRule(id: "R-mixed", text: "Praise plus a complaint: classify by the complaint, never as praise."),
        ] + baseRules,
        examples: baseExamples + [
            WorkedExample(
                input: "Great app, but search ignores accented letters.",
                output: TriageDecision(category: .bug, severity: 2, needsHuman: false, summary: "Search doesn't match accented characters")
            ),
        ]
    )
}
