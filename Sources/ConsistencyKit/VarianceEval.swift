import Foundation

/// The result of one sampled run of one case.
public enum RunOutcome: Hashable, Sendable {
    case decided(DecisionKey, attempts: Int, fallback: Bool)
    case invalid
}

public struct CaseReport: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let runs: Int
    public let modalKey: DecisionKey?
    public let modalCount: Int
    public let distinctKeys: Int
    public let invalidCount: Int
    public let fallbackCount: Int
    public let retriedRuns: Int
    public let counts: [DecisionKey: Int]
    /// The labeled answer for this input, when the case has one.
    public let expectedKey: DecisionKey?
    /// Runs whose decision matched the label. Invalid runs never match.
    public let correctCount: Int

    /// Share of runs that returned the most common decision. Invalid runs count
    /// against agreement: an answer you can't parse is not a consistent answer.
    public var agreement: Double {
        runs == 0 ? 0 : Double(modalCount) / Double(runs)
    }

    /// Share of runs that returned the labeled decision. Agreement says a
    /// decision is stable; accuracy says it is right. A billing complaint
    /// tagged "bug" in 20 of 20 runs has agreement 1.0 and accuracy 0.
    public var accuracy: Double {
        runs == 0 ? 0 : Double(correctCount) / Double(runs)
    }

    /// The most common answer is the labeled one.
    public var modalIsCorrect: Bool {
        modalKey != nil && modalKey == expectedKey
    }
}

public struct VarianceReport: Hashable, Sendable {
    public let label: String
    public let cases: [CaseReport]

    public var meanAgreement: Double {
        cases.isEmpty ? 0 : cases.map(\.agreement).reduce(0, +) / Double(cases.count)
    }

    public var totalRuns: Int { cases.map(\.runs).reduce(0, +) }
    public var totalInvalid: Int { cases.map(\.invalidCount).reduce(0, +) }
    public var totalFallback: Int { cases.map(\.fallbackCount).reduce(0, +) }
    public var totalRetried: Int { cases.map(\.retriedRuns).reduce(0, +) }
    public var stableCaseCount: Int { cases.filter { $0.agreement >= 0.9 }.count }

    /// Cases below the bar. These are the inputs that need a rule or a worked
    /// example, not a lower temperature.
    public func unstableCases(below threshold: Double = 0.9) -> [CaseReport] {
        cases.filter { $0.agreement < threshold }
    }

    /// Fallbacks are consistent by construction, so report them separately:
    /// a pipeline that escalates everything scores 100% agreement and is useless.
    public var fallbackRate: Double {
        totalRuns == 0 ? 0 : Double(totalFallback) / Double(totalRuns)
    }

    /// Mean share of runs that returned the labeled decision.
    public var meanAccuracy: Double {
        cases.isEmpty ? 0 : cases.map(\.accuracy).reduce(0, +) / Double(cases.count)
    }

    /// Cases that are consistent but wrong: agreement at or above the bar,
    /// most common answer different from the label. Agreement alone scores
    /// these as solved, which is why the labels sit next to the variance eval.
    public func stableButWrongCases(threshold: Double = 0.9) -> [CaseReport] {
        cases.filter { $0.agreement >= threshold && $0.expectedKey != nil && !$0.modalIsCorrect }
    }

    /// Compares this report with an earlier one, case by case, so a rule change
    /// only counts as a fix when accuracy moves, not just agreement.
    public func changes(since baseline: VarianceReport) -> [CaseChange] {
        let before = Dictionary(baseline.cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cases.compactMap { after in
            guard let old = before[after.id] else { return nil }
            return CaseChange(id: after.id, title: after.title, before: old, after: after)
        }
    }
}

/// How one case moved between two reports.
public struct CaseChange: Identifiable, Hashable, Sendable {
    public enum Verdict: String, Hashable, Sendable {
        /// Accuracy went up and agreement did not drop.
        case fixed
        /// Agreement went up, accuracy did not: the variance moved, the decision didn't.
        case stabilizedOnly
        /// Accuracy went down.
        case regressed
        case unchanged
    }

    public let id: Int
    public let title: String
    public let before: CaseReport
    public let after: CaseReport

    public var agreementDelta: Double { after.agreement - before.agreement }
    public var accuracyDelta: Double { after.accuracy - before.accuracy }

    public var verdict: Verdict {
        let epsilon = 1e-9
        if accuracyDelta < -epsilon { return .regressed }
        if accuracyDelta > epsilon { return agreementDelta < -epsilon ? .regressed : .fixed }
        return agreementDelta > epsilon ? .stabilizedOnly : .unchanged
    }
}

/// Runs every case `runs` times and measures run-to-run agreement, and
/// accuracy against each case's labeled decision.
public enum VarianceEval {
    public static func evaluate(
        label: String,
        cases: [SampleCase],
        runs: Int,
        sample: (SampleCase, Int) async -> RunOutcome
    ) async -> VarianceReport {
        var reports: [CaseReport] = []
        for item in cases {
            var counts: [DecisionKey: Int] = [:]
            var invalid = 0, fallback = 0, retried = 0, correct = 0
            let expected = item.expected.key
            for run in 0..<max(0, runs) {
                switch await sample(item, run) {
                case .invalid:
                    invalid += 1
                case .decided(let key, let attempts, let isFallback):
                    counts[key, default: 0] += 1
                    if isFallback { fallback += 1 }
                    if attempts > 1 { retried += 1 }
                    if key == expected { correct += 1 }
                }
            }
            // Ties break on the description so the report itself is deterministic.
            let modal = counts.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.description > rhs.key.description : lhs.value < rhs.value
            }
            reports.append(CaseReport(
                id: item.id,
                title: item.title,
                runs: max(0, runs),
                modalKey: modal?.key,
                modalCount: modal?.value ?? 0,
                distinctKeys: counts.count + (invalid > 0 ? 1 : 0),
                invalidCount: invalid,
                fallbackCount: fallback,
                retriedRuns: retried,
                counts: counts,
                expectedKey: expected,
                correctCount: correct
            ))
        }
        return VarianceReport(label: label, cases: reports)
    }

    /// The three runs the article and the demo app show, all seeded.
    public static func standardComparison(runs: Int = 20, seed: UInt64 = 2026_10_21) async -> [VarianceReport] {
        let cases = SampleCase.all
        let baseline = await evaluate(label: "Vague prompt", cases: cases, runs: runs) { item, run in
            let model = SimulatedModel(seed: seed &+ UInt64(run), cases: cases)
            let request = ModelRequest(system: UnstructuredBaseline.systemPrompt, input: item.text)
            guard let raw = try? await model.complete(request),
                  let key = UnstructuredBaseline.parse(raw) else { return .invalid }
            return .decided(key, attempts: 1, fallback: false)
        }
        var reports = [baseline]
        for contract in [DecisionContract.triageV1, .triageV2] {
            let report = await evaluate(label: "Contract \(contract.version)", cases: cases, runs: runs) { item, run in
                let model = SimulatedModel(seed: seed &+ UInt64(run), cases: cases)
                let outcome = await ContractPipeline(contract: contract, client: model).run(item.text)
                return .decided(outcome.decision.key, attempts: outcome.attempts, fallback: outcome.isFallback)
            }
            reports.append(report)
        }
        return reports
    }
}
