import Foundation

/// What a model client receives. `feedback` carries the previous attempt's
/// violations so the model can repair its output instead of guessing again.
public struct ModelRequest: Hashable, Sendable {
    public let system: String
    public let input: String
    public let attempt: Int
    public let feedback: [Violation]

    public init(system: String, input: String, attempt: Int = 1, feedback: [Violation] = []) {
        self.system = system
        self.input = input
        self.attempt = attempt
        self.feedback = feedback
    }

    /// The user turn as it would be sent: the review, plus repair notes on retries.
    public var userMessage: String {
        guard !feedback.isEmpty else { return input }
        let notes = feedback.map { "- \($0.description)" }.joined(separator: "\n")
        return "\(input)\n\nYour previous answer was rejected:\n\(notes)\nReturn a corrected JSON object."
    }
}

/// Wrap your real Claude client (URLSession, the SDK, a gateway) in this.
/// Send no `temperature`, `top_p` or `top_k`: API version 2026-10-21 rejects them.
public protocol ModelClient: Sendable {
    func complete(_ request: ModelRequest) async throws -> String
}

public enum PipelineOutcome: Hashable, Sendable {
    case accepted(TriageDecision, attempts: Int)
    case fallback(TriageDecision, attempts: Int, lastViolations: [Violation])

    public var decision: TriageDecision {
        switch self {
        case .accepted(let decision, _), .fallback(let decision, _, _): return decision
        }
    }

    public var attempts: Int {
        switch self {
        case .accepted(_, let attempts), .fallback(_, let attempts, _): return attempts
        }
    }

    public var isFallback: Bool {
        if case .fallback = self { return true }
        return false
    }
}

/// Contract → model → validator, with a bounded number of repair attempts and
/// a deterministic fallback. The bound is the point: an unbounded retry loop
/// turns a format problem into a latency and cost problem.
public struct ContractPipeline<Client: ModelClient>: Sendable {
    public let contract: DecisionContract
    public let client: Client
    public let maxAttempts: Int
    private let validator: DecisionValidator
    private let system: String

    public init(contract: DecisionContract, client: Client, maxAttempts: Int = 3) {
        self.contract = contract
        self.client = client
        self.maxAttempts = max(1, maxAttempts)
        self.validator = DecisionValidator(contract: contract)
        self.system = contract.systemPrompt()
    }

    public func run(_ input: String) async -> PipelineOutcome {
        var feedback: [Violation] = []
        for attempt in 1...maxAttempts {
            let request = ModelRequest(system: system, input: input, attempt: attempt, feedback: feedback)
            let raw: String
            do {
                raw = try await client.complete(request)
            } catch {
                feedback = [.clientError(String(describing: error))]
                continue
            }
            switch validator.validate(raw) {
            case .success(let decision):
                return .accepted(decision, attempts: attempt)
            case .failure(let failure):
                feedback = failure.violations
            }
        }
        return .fallback(.escalation(), attempts: maxAttempts, lastViolations: feedback)
    }
}

/// The baseline most teams shipped: one call, a vague instruction, a lenient
/// parser, and default sampling (what `temperature: 0` becomes on 2026-10-21).
public enum UnstructuredBaseline {
    public static let systemPrompt = "You help triage App Store reviews for a notes app. Classify the review, rate how serious it is and say whether a person should look at it. Answer in JSON. Be consistent."

    /// Lenient on purpose: strips fences, lowercases, maps spaces to underscores.
    /// Whatever still doesn't parse counts as an invalid run.
    public static func parse(_ raw: String) -> DecisionKey? {
        let text = DecisionValidator.stripCodeFence(raw)
        guard let data = text.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawCategory = fields["category"] as? String,
              let severity = (fields["severity"] as? NSNumber)?.intValue,
              let needsHuman = (fields["needs_human"] as? NSNumber)?.boolValue else {
            return nil
        }
        let normalized = rawCategory.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard let category = ReviewCategory(rawValue: normalized) else { return nil }
        return DecisionKey(category: category, severity: severity, needsHuman: needsHuman)
    }
}
