import Foundation

/// Why a raw model response was rejected. Each case is specific enough to be
/// sent back to the model as feedback on the next attempt.
public enum Violation: Hashable, Sendable, CustomStringConvertible {
    case notJSON
    case missingField(String)
    case wrongType(String)
    case unknownCategory(String)
    case severityOutOfRange(Int)
    case summaryTooLong(Int)
    case unexpectedField(String)
    case ruleBroken(String)
    case clientError(String)

    public var description: String {
        switch self {
        case .notJSON: return "Response was not a single JSON object."
        case .missingField(let name): return "Missing field \"\(name)\"."
        case .wrongType(let name): return "Field \"\(name)\" has the wrong type."
        case .unknownCategory(let value): return "Unknown category \"\(value)\"."
        case .severityOutOfRange(let value): return "Severity \(value) is outside 1...4."
        case .summaryTooLong(let count): return "Summary is \(count) characters; the limit is lower."
        case .unexpectedField(let name): return "Unexpected field \"\(name)\"."
        case .ruleBroken(let text): return "Rule broken: \(text)"
        case .clientError(let text): return "Client error: \(text)"
        }
    }

    /// Format problems a retry can fix. Judgment problems (a valid but wrong
    /// category) never show up here: validation checks shape, the eval checks judgment.
    public var isFormatProblem: Bool {
        switch self {
        case .ruleBroken, .clientError: return false
        default: return true
        }
    }
}

public struct ValidationFailure: Error, Hashable, Sendable {
    public let violations: [Violation]
}

/// Deterministic post-validation. Same input, same verdict, every time.
public struct DecisionValidator: Sendable {
    public let maxSummaryLength: Int

    public init(maxSummaryLength: Int = 80) {
        self.maxSummaryLength = maxSummaryLength
    }

    public init(contract: DecisionContract) {
        self.maxSummaryLength = contract.maxSummaryLength
    }

    static let knownFields: Set<String> = ["category", "severity", "needs_human", "summary"]

    public func validate(_ raw: String) -> Result<TriageDecision, ValidationFailure> {
        let text = Self.stripCodeFence(raw)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            return .failure(ValidationFailure(violations: [.notJSON]))
        }

        var violations: [Violation] = []
        for name in fields.keys.sorted() where !Self.knownFields.contains(name) {
            violations.append(.unexpectedField(name))
        }

        var category: ReviewCategory?
        if let value = fields["category"] {
            if let string = value as? String {
                category = ReviewCategory(rawValue: string.trimmingCharacters(in: .whitespaces).lowercased())
                if category == nil { violations.append(.unknownCategory(string)) }
            } else {
                violations.append(.wrongType("category"))
            }
        } else {
            violations.append(.missingField("category"))
        }

        var severity: Int?
        if let value = fields["severity"] {
            // JSONSerialization gives NSNumber; reject booleans and fractions explicitly.
            if let number = value as? NSNumber, !Self.isBool(number), number.doubleValue == number.doubleValue.rounded() {
                let int = number.intValue
                if (1...4).contains(int) { severity = int } else { violations.append(.severityOutOfRange(int)) }
            } else {
                violations.append(.wrongType("severity"))
            }
        } else {
            violations.append(.missingField("severity"))
        }

        var needsHuman: Bool?
        if let value = fields["needs_human"] {
            if let number = value as? NSNumber, Self.isBool(number) {
                needsHuman = number.boolValue
            } else {
                violations.append(.wrongType("needs_human"))
            }
        } else {
            violations.append(.missingField("needs_human"))
        }

        var summary: String?
        if let value = fields["summary"] {
            if let string = value as? String {
                if string.count > maxSummaryLength { violations.append(.summaryTooLong(string.count)) } else { summary = string }
            } else {
                violations.append(.wrongType("summary"))
            }
        } else {
            violations.append(.missingField("summary"))
        }

        if let category, let severity, let needsHuman, let summary {
            let decision = TriageDecision(category: category, severity: severity, needsHuman: needsHuman, summary: summary)
            violations.append(contentsOf: Self.crossFieldViolations(decision))
            if violations.isEmpty { return .success(decision) }
        }
        return .failure(ValidationFailure(violations: violations))
    }

    /// The decision rules that can be checked mechanically. The prompt asks for
    /// them; this enforces them.
    public static func crossFieldViolations(_ decision: TriageDecision) -> [Violation] {
        var result: [Violation] = []
        if decision.severity == 4 && !decision.needsHuman {
            result.append(.ruleBroken("severity 4 requires needs_human true"))
        }
        if decision.severity == 4 && decision.category != .bug {
            result.append(.ruleBroken("severity 4 is reserved for bugs"))
        }
        if decision.category == .billing && !decision.needsHuman {
            result.append(.ruleBroken("billing always needs a human"))
        }
        if decision.category == .praise && (decision.severity != 1 || decision.needsHuman) {
            result.append(.ruleBroken("praise is severity 1 with no human"))
        }
        return result
    }

    static func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        } else {
            return ""
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isBool(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return String(describing: type(of: number)) == "__NSCFBoolean"
        #endif
    }
}
