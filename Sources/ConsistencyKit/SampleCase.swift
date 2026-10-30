import Foundation

/// A constructed review with the decision the v2 rules imply, the rule ids
/// that cover it, and the plausible readings a model falls back on when no
/// rule decides. These are illustrative inputs, not production data.
public struct SampleCase: Identifiable, Hashable, Sendable {
    public struct Reading: Hashable, Sendable {
        public let key: DecisionKey
        public let weight: Double
    }

    public let id: Int
    public let title: String
    public let text: String
    public let expected: TriageDecision
    public let coveredBy: [String]
    public let readings: [Reading]

    public init(id: Int, title: String, text: String, expected: TriageDecision, coveredBy: [String], readings: [Reading]) {
        self.id = id
        self.title = title
        self.text = text
        self.expected = expected
        self.coveredBy = coveredBy
        self.readings = readings
    }
}

private func r(_ category: ReviewCategory, _ severity: Int, _ human: Bool, _ weight: Double) -> SampleCase.Reading {
    SampleCase.Reading(key: DecisionKey(category: category, severity: severity, needsHuman: human), weight: weight)
}

public extension SampleCase {
    static let all: [SampleCase] = [
        SampleCase(
            id: 1, title: "Crash opening a shared note",
            text: "App crashes every time I open a shared note since the update. Lost the draft I was writing.",
            expected: TriageDecision(category: .bug, severity: 4, needsHuman: true, summary: "Crash opening shared notes after update; draft lost"),
            coveredBy: ["R-sev4"],
            readings: [r(.bug, 4, true, 0.55), r(.bug, 3, true, 0.30), r(.bug, 4, false, 0.15)]
        ),
        SampleCase(
            id: 2, title: "Charged twice for Pro",
            text: "Charged twice for Pro this month. Please refund one of them.",
            expected: TriageDecision(category: .billing, severity: 3, needsHuman: true, summary: "Double charge for Pro; wants a refund"),
            coveredBy: ["R-billing", "R-money-first"],
            readings: [r(.billing, 3, true, 0.50), r(.billing, 4, true, 0.25), r(.billing, 2, true, 0.25)]
        ),
        SampleCase(
            id: 3, title: "Dark mode for the widget",
            text: "Would love a dark mode for the home screen widget.",
            expected: TriageDecision(category: .featureRequest, severity: 1, needsHuman: false, summary: "Wants a dark widget"),
            coveredBy: ["R-feature"],
            readings: [r(.featureRequest, 1, false, 0.75), r(.featureRequest, 2, false, 0.25)]
        ),
        SampleCase(
            id: 4, title: "Instant sync praise",
            text: "Best notes app I've used. Sync is instant.",
            expected: TriageDecision(category: .praise, severity: 1, needsHuman: false, summary: "Praises instant sync"),
            coveredBy: ["R-praise"],
            readings: [r(.praise, 1, false, 0.90), r(.other, 1, false, 0.10)]
        ),
        SampleCase(
            id: 5, title: "Slow iPad sync",
            text: "Sync is slow sometimes. Takes a minute for notes to show up on my iPad.",
            expected: TriageDecision(category: .bug, severity: 2, needsHuman: false, summary: "Sync to iPad sometimes takes a minute"),
            coveredBy: ["R-sev2"],
            readings: [r(.bug, 2, false, 0.50), r(.bug, 3, false, 0.30), r(.bug, 2, true, 0.20)]
        ),
        SampleCase(
            id: 6, title: "Trial cancelled, still Pro",
            text: "Cancelled my trial but the app still says Pro. Is that a bug?",
            expected: TriageDecision(category: .billing, severity: 2, needsHuman: true, summary: "Trial cancelled but app still shows Pro"),
            coveredBy: ["R-money-first"],
            readings: [r(.billing, 2, true, 0.35), r(.bug, 2, false, 0.35), r(.billing, 3, true, 0.15), r(.bug, 3, false, 0.15)]
        ),
        SampleCase(
            id: 7, title: "Praise, then lost formatting",
            text: "Love this app, but the new export button wiped my formatting.",
            expected: TriageDecision(category: .bug, severity: 3, needsHuman: false, summary: "Export removes note formatting"),
            coveredBy: ["R-mixed"],
            readings: [r(.praise, 1, false, 0.40), r(.bug, 3, false, 0.35), r(.bug, 2, false, 0.25)]
        ),
        SampleCase(
            id: 8, title: "Keyboard test",
            text: "asdf test",
            expected: TriageDecision(category: .other, severity: 1, needsHuman: false, summary: "No actionable content"),
            coveredBy: ["R-other"],
            readings: [r(.other, 1, false, 0.85), r(.other, 2, false, 0.15)]
        ),
    ]
}
