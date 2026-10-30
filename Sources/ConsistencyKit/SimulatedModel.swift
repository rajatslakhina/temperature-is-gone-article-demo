import Foundation

/// A small, fast, seeded PRNG so every simulated run is reproducible.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// A stand-in for a model sampling at its default temperature, so the repo runs
/// without an API key. Its behaviour is an explicit, documented assumption:
///
/// * Without a contract it samples one of the case's plausible readings and
///   returns it in one of several output styles (clean JSON, fenced JSON,
///   title-cased or synonym categories, prose, a missing field).
/// * With a contract it follows a rule that covers the case 96% of the time,
///   and a case no rule covers only 55% of the time, otherwise it samples a
///   reading. First attempts sometimes break format (long summary, a broken
///   cross-field rule, an extra field); a retry with feedback repairs format
///   90% of the time.
///
/// Numbers produced with it describe this model of the world, not Claude.
/// Point `ContractPipeline` and `VarianceEval` at a real client to measure yours.
public struct SimulatedModel: ModelClient {
    public let seed: UInt64
    public let cases: [SampleCase]

    public static let pFollowCovered = 0.96
    public static let pFollowUncovered = 0.55
    public static let pRepair = 0.90

    public init(seed: UInt64, cases: [SampleCase] = SampleCase.all) {
        self.seed = seed
        self.cases = cases
    }

    public func complete(_ request: ModelRequest) async throws -> String {
        var rng = SplitMix64(seed: seed ^ Self.hash(request.input) ^ (UInt64(request.attempt) &* 0x2545_F491_4F6C_DD1D))
        guard let item = cases.first(where: { $0.text == request.input }) else {
            return Self.json(TriageDecision(category: .other, severity: 1, needsHuman: false, summary: "Unknown input"))
        }
        if request.system.contains("Decision rules") {
            return structured(item, request: request, rng: &rng)
        }
        return unstructured(item, rng: &rng)
    }

    // MARK: - Behaviour

    private func unstructured(_ item: SampleCase, rng: inout SplitMix64) -> String {
        let key = Self.pick(item.readings, rng: &rng)
        let decision = TriageDecision(category: key.category, severity: key.severity, needsHuman: key.needsHuman, summary: item.expected.summary)
        let style = rng.unit()
        switch style {
        case ..<0.55: return Self.json(decision)
        case ..<0.70: return "```json\n\(Self.json(decision))\n```"
        case ..<0.80: return Self.json(decision, category: Self.titleCase(key.category))
        case ..<0.88: return Self.json(decision, category: Self.synonym(key.category))
        case ..<0.94: return "This reads like \(Self.synonym(key.category)) to me, severity \(key.severity) of 4."
        default: return "{\"category\":\"\(key.category.rawValue)\",\"severity\":\(key.severity),\"summary\":\"\(item.expected.summary)\"}"
        }
    }

    private func structured(_ item: SampleCase, request: ModelRequest, rng: inout SplitMix64) -> String {
        let covered = item.coveredBy.contains { request.system.contains("[\($0)]") }
        let pFollow = covered ? Self.pFollowCovered : Self.pFollowUncovered
        let key = rng.unit() < pFollow ? item.expected.key : Self.pick(item.readings, rng: &rng)
        var decision = TriageDecision(category: key.category, severity: key.severity, needsHuman: key.needsHuman, summary: item.expected.summary)

        let repairing = request.attempt > 1 && !request.feedback.isEmpty
        let roll = rng.unit()
        if repairing ? roll < Self.pRepair : roll < 0.86 {
            return Self.json(decision)
        }
        switch rng.unit() {
        case ..<0.40:
            decision.summary += " The user also describes how long they have used the app and asks for a reply."
            return Self.json(decision)
        case ..<0.75:
            // A decision that breaks a mechanical rule.
            decision.severity = 4
            decision.needsHuman = false
            return Self.json(decision)
        default:
            return "```json\n" + Self.json(decision).dropLast() + ",\"confidence\":0.9}\n```"
        }
    }

    // MARK: - Helpers

    static func pick(_ readings: [SampleCase.Reading], rng: inout SplitMix64) -> DecisionKey {
        let total = readings.map(\.weight).reduce(0, +)
        var target = rng.unit() * total
        for reading in readings {
            target -= reading.weight
            if target < 0 { return reading.key }
        }
        // Rounding can leave a sliver; fall back to the last reading, or a safe default.
        return readings.last?.key ?? DecisionKey(category: .other, severity: 1, needsHuman: false)
    }

    static func json(_ d: TriageDecision, category: String? = nil) -> String {
        let summary = d.summary.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"category\":\"\(category ?? d.category.rawValue)\",\"severity\":\(d.severity),\"needs_human\":\(d.needsHuman),\"summary\":\"\(summary)\"}"
    }

    static func titleCase(_ c: ReviewCategory) -> String {
        switch c {
        case .bug: return "Bug"
        case .billing: return "Billing"
        case .featureRequest: return "Feature Request"
        case .praise: return "Praise"
        case .other: return "Other"
        }
    }

    static func synonym(_ c: ReviewCategory) -> String {
        switch c {
        case .bug: return "bug report"
        case .billing: return "payment issue"
        case .featureRequest: return "suggestion"
        case .praise: return "positive feedback"
        case .other: return "n/a"
        }
    }

    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
