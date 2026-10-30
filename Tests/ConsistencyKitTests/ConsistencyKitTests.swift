import XCTest
@testable import ConsistencyKit

final class ValidatorTests: XCTestCase {
    let validator = DecisionValidator()

    func testAcceptsCleanDecision() throws {
        let raw = #"{"category":"bug","severity":2,"needs_human":false,"summary":"Sync is slow"}"#
        let decision = try validator.validate(raw).get()
        XCTAssertEqual(decision.key, DecisionKey(category: .bug, severity: 2, needsHuman: false))
    }

    func testStripsCodeFence() throws {
        let raw = "```json\n{\"category\":\"praise\",\"severity\":1,\"needs_human\":false,\"summary\":\"Nice\"}\n```"
        XCTAssertNoThrow(try validator.validate(raw).get())
    }

    func testRejectsProse() {
        XCTAssertEqual(failure(validator.validate("This is a billing issue, severity 3.")), [.notJSON])
    }

    func testRejectsEmptyAndFenceOnly() {
        XCTAssertEqual(failure(validator.validate("")), [.notJSON])
        XCTAssertEqual(failure(validator.validate("```")), [.notJSON])
    }

    func testRejectsTopLevelArray() {
        XCTAssertEqual(failure(validator.validate("[1,2]")), [.notJSON])
    }

    func testReportsEveryViolationAtOnce() {
        let raw = #"{"category":"payment issue","severity":7,"confidence":0.9}"#
        let violations = failure(validator.validate(raw))
        XCTAssertEqual(violations, [
            .unexpectedField("confidence"),
            .unknownCategory("payment issue"),
            .severityOutOfRange(7),
            .missingField("needs_human"),
            .missingField("summary"),
        ])
    }

    func testRejectsBooleanSeverityAndNumericFlag() {
        let raw = #"{"category":"bug","severity":true,"needs_human":1,"summary":"x"}"#
        XCTAssertEqual(failure(validator.validate(raw)), [.wrongType("severity"), .wrongType("needs_human")])
    }

    func testRejectsFractionalSeverity() {
        let raw = #"{"category":"bug","severity":2.5,"needs_human":false,"summary":"x"}"#
        XCTAssertEqual(failure(validator.validate(raw)), [.wrongType("severity")])
    }

    func testSummaryLimitIsInclusive() {
        let ok = String(repeating: "a", count: 80)
        let long = String(repeating: "a", count: 81)
        XCTAssertNoThrow(try validator.validate(#"{"category":"other","severity":1,"needs_human":false,"summary":"\#(ok)"}"#).get())
        XCTAssertEqual(failure(validator.validate(#"{"category":"other","severity":1,"needs_human":false,"summary":"\#(long)"}"#)), [.summaryTooLong(81)])
    }

    func testCrossFieldRules() {
        let raw = #"{"category":"billing","severity":4,"needs_human":false,"summary":"x"}"#
        XCTAssertEqual(failure(validator.validate(raw)), [
            .ruleBroken("severity 4 requires needs_human true"),
            .ruleBroken("severity 4 is reserved for bugs"),
            .ruleBroken("billing always needs a human"),
        ])
        let praise = #"{"category":"praise","severity":2,"needs_human":false,"summary":"x"}"#
        XCTAssertEqual(failure(validator.validate(praise)), [.ruleBroken("praise is severity 1 with no human")])
    }

    func testEscalationPassesItsOwnValidator() {
        XCTAssertTrue(DecisionValidator.crossFieldViolations(.escalation()).isEmpty)
    }

    private func failure(_ result: Result<TriageDecision, ValidationFailure>) -> [Violation] {
        if case .failure(let failure) = result { return failure.violations }
        XCTFail("expected a validation failure")
        return []
    }
}

final class ContractTests: XCTestCase {
    func testPromptAndFingerprintAreDeterministic() {
        XCTAssertEqual(DecisionContract.triageV1.systemPrompt(), DecisionContract.triageV1.systemPrompt())
        XCTAssertEqual(DecisionContract.triageV1.fingerprint, DecisionContract.triageV1.fingerprint)
        XCTAssertNotEqual(DecisionContract.triageV1.fingerprint, DecisionContract.triageV2.fingerprint)
        XCTAssertEqual(DecisionContract.triageV1.fingerprint.count, 16)
    }

    func testSchemaListsEveryCategoryAndIsClosed() {
        let schema = DecisionContract.triageV1.jsonSchema
        for category in ReviewCategory.allCases { XCTAssertTrue(schema.contains("\"\(category.rawValue)\"")) }
        XCTAssertTrue(schema.contains("\"additionalProperties\":false"))
        XCTAssertTrue(schema.contains("\"maxLength\":80"))
    }

    func testPromptCarriesRulesAndExamples() {
        let prompt = DecisionContract.triageV2.systemPrompt()
        XCTAssertTrue(prompt.contains("[R-money-first]"))
        XCTAssertTrue(prompt.contains("[R-mixed]"))
        XCTAssertFalse(DecisionContract.triageV1.systemPrompt().contains("[R-mixed]"))
        XCTAssertTrue(prompt.contains("Worked examples:"))
    }

    func testWorkedExamplesObeyTheirOwnRules() {
        for contract in [DecisionContract.triageV1, .triageV2] {
            for example in contract.examples {
                XCTAssertTrue(DecisionValidator.crossFieldViolations(example.output).isEmpty, example.input)
            }
        }
    }

    func testExpectedDecisionsAreValid() {
        for item in SampleCase.all {
            XCTAssertTrue(DecisionValidator.crossFieldViolations(item.expected).isEmpty, item.title)
            XCTAssertLessThanOrEqual(item.expected.summary.count, 80, item.title)
        }
    }
}

struct ScriptedClient: ModelClient {
    let responses: [String]
    func complete(_ request: ModelRequest) async throws -> String {
        let index = request.attempt - 1
        guard responses.indices.contains(index) else { throw URLError(.badServerResponse) }
        return responses[index]
    }
}

final class PipelineTests: XCTestCase {
    let good = #"{"category":"bug","severity":2,"needs_human":false,"summary":"Slow sync"}"#

    func testAcceptsFirstValidAnswer() async {
        let outcome = await ContractPipeline(contract: .triageV1, client: ScriptedClient(responses: [good])).run("x")
        XCTAssertEqual(outcome, .accepted(try! DecisionValidator().validate(good).get(), attempts: 1))
    }

    func testRepairsOnSecondAttempt() async {
        let outcome = await ContractPipeline(contract: .triageV1, client: ScriptedClient(responses: ["nope", good])).run("x")
        XCTAssertEqual(outcome.attempts, 2)
        XCTAssertFalse(outcome.isFallback)
    }

    func testFallsBackDeterministicallyAfterBudget() async {
        let outcome = await ContractPipeline(contract: .triageV1, client: ScriptedClient(responses: ["a", "b", "c", good]), maxAttempts: 3).run("x")
        XCTAssertTrue(outcome.isFallback)
        XCTAssertEqual(outcome.attempts, 3)
        XCTAssertEqual(outcome.decision, .escalation())
    }

    func testClientErrorsConsumeAttempts() async {
        let outcome = await ContractPipeline(contract: .triageV1, client: ScriptedClient(responses: []), maxAttempts: 2).run("x")
        XCTAssertTrue(outcome.isFallback)
        if case .fallback(_, _, let last) = outcome {
            XCTAssertEqual(last.count, 1)
            XCTAssertFalse(last[0].isFormatProblem)
        }
    }

    func testZeroAttemptsIsClampedToOne() async {
        let pipeline = ContractPipeline(contract: .triageV1, client: ScriptedClient(responses: [good]), maxAttempts: 0)
        XCTAssertEqual(pipeline.maxAttempts, 1)
        let outcome = await pipeline.run("x")
        XCTAssertEqual(outcome.attempts, 1)
    }

    func testFeedbackReachesTheModel() {
        let request = ModelRequest(system: "s", input: "review", attempt: 2, feedback: [.missingField("summary")])
        XCTAssertTrue(request.userMessage.contains("Missing field \"summary\"."))
        XCTAssertEqual(ModelRequest(system: "s", input: "review").userMessage, "review")
    }
}

final class BaselineAndAuditTests: XCTestCase {
    func testLenientBaselineParser() {
        XCTAssertEqual(UnstructuredBaseline.parse(#"{"category":"Feature Request","severity":1,"needs_human":false}"#),
                       DecisionKey(category: .featureRequest, severity: 1, needsHuman: false))
        XCTAssertNil(UnstructuredBaseline.parse(#"{"category":"bug report","severity":1,"needs_human":false}"#))
        XCTAssertNil(UnstructuredBaseline.parse("A bug, severity 2."))
    }

    func testAuditFindsLegacyParameters() throws {
        let findings = try LegacyParameterAudit.audit(Data(LegacyParameterAudit.legacyExample.utf8))
        XCTAssertEqual(findings.map(\.parameter), ["temperature", "top_k"])
    }

    func testAuditCoversBatches() throws {
        let body = #"{"requests":[{"custom_id":"a","params":{"top_p":0.9,"max_tokens":10}},{"custom_id":"b","params":{"max_tokens":10}}]}"#
        let findings = try LegacyParameterAudit.audit(Data(body.utf8))
        XCTAssertEqual(findings, [LegacyParameterAudit.Finding(path: "$.requests[0].params", parameter: "top_p", value: "0.9")])
        let migrated = try LegacyParameterAudit.migrate(Data(body.utf8))
        XCTAssertTrue(try LegacyParameterAudit.audit(migrated).isEmpty)
    }

    func testMigrateKeepsEverythingElse() throws {
        let migrated = try LegacyParameterAudit.migrate(Data(LegacyParameterAudit.legacyExample.utf8))
        let text = String(decoding: migrated, as: UTF8.self)
        XCTAssertFalse(text.contains("temperature"))
        XCTAssertTrue(text.contains("\"max_tokens\":256"))
        XCTAssertTrue(text.contains("claude-sonnet-4-6"))
    }

    func testAuditRejectsNonObject() {
        XCTAssertThrowsError(try LegacyParameterAudit.audit(Data("[]".utf8)))
    }
}

final class EvalTests: XCTestCase {
    func testSimulatedModelIsReproducible() async throws {
        let item = SampleCase.all[5]
        let a = try await SimulatedModel(seed: 7).complete(ModelRequest(system: "x", input: item.text))
        let b = try await SimulatedModel(seed: 7).complete(ModelRequest(system: "x", input: item.text))
        XCTAssertEqual(a, b)
    }

    func testPickHandlesEmptyReadings() {
        var rng = SplitMix64(seed: 1)
        XCTAssertEqual(SimulatedModel.pick([], rng: &rng), DecisionKey(category: .other, severity: 1, needsHuman: false))
    }

    func testAgreementCountsInvalidRunsAgainst() async {
        let item = SampleCase.all[0]
        let report = await VarianceEval.evaluate(label: "t", cases: [item], runs: 4) { _, run in
            run < 3 ? .decided(item.expected.key, attempts: 1, fallback: false) : .invalid
        }
        XCTAssertEqual(report.cases.first?.agreement, 0.75)
        XCTAssertEqual(report.cases.first?.distinctKeys, 2)
    }

    func testZeroRunsDoesNotDivideByZero() async {
        let report = await VarianceEval.evaluate(label: "t", cases: SampleCase.all, runs: 0) { _, _ in .invalid }
        XCTAssertEqual(report.meanAgreement, 0)
        XCTAssertEqual(report.fallbackRate, 0)
    }

    func testStandardComparisonIsStableAndImproves() async {
        let first = await VarianceEval.standardComparison()
        let second = await VarianceEval.standardComparison()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 3)
        XCTAssertLessThan(first[0].meanAgreement, first[1].meanAgreement)
        XCTAssertLessThan(first[1].meanAgreement, first[2].meanAgreement)
        XCTAssertGreaterThan(first[1].unstableCases().count, first[2].unstableCases().count)
        XCTAssertEqual(first[1].totalInvalid, 0, "the pipeline never returns an unparseable answer")

        for report in first {
            print("REPORT \(report.label): mean=\(String(format: "%.3f", report.meanAgreement)) stable=\(report.stableCaseCount)/\(report.cases.count) invalid=\(report.totalInvalid) retried=\(report.totalRetried) fallback=\(report.totalFallback) runs=\(report.totalRuns)")
            for c in report.cases {
                let dist = c.counts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                print("  case \(c.id) \(c.title): \(c.modalCount)/\(c.runs) modal=\(c.modalKey?.description ?? "-") invalid=\(c.invalidCount) fb=\(c.fallbackCount) retried=\(c.retriedRuns) [\(dist)]")
            }
        }
        print("FINGERPRINT v1=\(DecisionContract.triageV1.fingerprint) v2=\(DecisionContract.triageV2.fingerprint)")
    }
}
