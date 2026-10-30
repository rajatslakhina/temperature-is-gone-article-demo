import SwiftUI
import ConsistencyKit

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Launch arguments drive the CI screenshots:
/// `-tab variance|runs|audit`, `-report 0|1|2`, `-case 1...8`, `-contract v1|v2|vague`.
struct RootView: View {
    @State private var tab: String = UserDefaults.standard.string(forKey: "tab") ?? "variance"

    var body: some View {
        TabView(selection: $tab) {
            VarianceView()
                .tabItem { Label("Variance", systemImage: "chart.bar.xaxis") }
                .tag("variance")
            RunsView()
                .tabItem { Label("Runs", systemImage: "list.number") }
                .tag("runs")
            AuditView()
                .tabItem { Label("Audit", systemImage: "checkmark.shield") }
                .tag("audit")
        }
    }
}

// MARK: - Variance

struct VarianceView: View {
    @State private var reports: [VarianceReport] = []
    @State private var selected: Int = min(max(UserDefaults.standard.integer(forKey: "report"), 0), 2)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Setup", selection: $selected) {
                        Text("Vague").tag(0)
                        Text("Contract v1").tag(1)
                        Text("Contract v2").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                if reports.indices.contains(selected) {
                    let report = reports[selected]
                    Section {
                        HStack {
                            Metric(value: String(format: "%.0f%%", report.meanAgreement * 100), label: "mean agreement")
                            Metric(value: "\(report.stableCaseCount)/\(report.cases.count)", label: "cases ≥ 90%")
                        }
                        HStack {
                            Metric(value: "\(report.totalInvalid)", label: "unparseable")
                            Metric(value: "\(report.totalRetried)", label: "repaired by retry")
                            Metric(value: "\(report.totalFallback)", label: "escalated")
                        }
                    } footer: {
                        Text("8 constructed reviews × 20 seeded runs on a simulated model. Agreement = share of runs returning the most common category · severity · routing.")
                    }
                    Section("Per case") {
                        ForEach(report.cases) { item in
                            CaseRow(item: item)
                        }
                    }
                } else {
                    ProgressView("Running eval…")
                }
            }
            .navigationTitle("Run-to-run variance")
        }
        .task {
            if reports.isEmpty { reports = await VarianceEval.standardComparison() }
        }
    }
}

struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CaseRow: View {
    let item: CaseReport
    var stable: Bool { item.agreement >= 0.9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(item.id). \(item.title)").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(item.modalCount)/\(item.runs)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(stable ? .green : .orange)
            }
            ProgressView(value: item.agreement)
                .tint(stable ? .green : .orange)
            HStack(spacing: 8) {
                Text(item.modalKey?.description ?? "no valid answer")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !stable {
                    Text("needs a rule").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                if item.invalidCount > 0 {
                    Text("\(item.invalidCount) unparseable").font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Runs

struct RunLine: Identifiable {
    let id: Int
    let firstRaw: String
    let verdict: String
    let ok: Bool
}

struct RunsView: View {
    @State private var caseID: Int = {
        let id = UserDefaults.standard.integer(forKey: "case")
        return SampleCase.all.contains { $0.id == id } ? id : 6
    }()
    @State private var setup: String = UserDefaults.standard.string(forKey: "contract") ?? "v1"
    @State private var lines: [RunLine] = []

    var item: SampleCase { SampleCase.all.first { $0.id == caseID } ?? SampleCase.all[0] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Review", selection: $caseID) {
                        ForEach(SampleCase.all) { Text("\($0.id). \($0.title)").tag($0.id) }
                    }
                    Picker("Setup", selection: $setup) {
                        Text("Vague").tag("vague")
                        Text("v1").tag("v1")
                        Text("v2").tag("v2")
                    }
                    .pickerStyle(.segmented)
                    Text("“\(item.text)”").font(.callout).italic()
                }
                Section("10 runs · first raw answer → verdict") {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.firstRaw)
                                .font(.caption2.monospaced())
                                .lineLimit(3)
                                .foregroundStyle(.secondary)
                            Label(line.verdict, systemImage: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(line.ok ? .green : .orange)
                        }
                    }
                }
            }
            .navigationTitle("Same input, 10 runs")
        }
        .task(id: "\(caseID)-\(setup)") { lines = await runLines() }
    }

    func runLines() async -> [RunLine] {
        var result: [RunLine] = []
        let contract: DecisionContract? = setup == "v1" ? .triageV1 : setup == "v2" ? .triageV2 : nil
        for run in 0..<10 {
            let model = SimulatedModel(seed: 2026_10_21 &+ UInt64(run))
            let system = contract?.systemPrompt() ?? UnstructuredBaseline.systemPrompt
            let raw = (try? await model.complete(ModelRequest(system: system, input: item.text))) ?? ""
            if let contract {
                let outcome = await ContractPipeline(contract: contract, client: model).run(item.text)
                let suffix = outcome.attempts > 1 ? " (after \(outcome.attempts) attempts)" : ""
                let verdict = outcome.isFallback ? "escalated to a person" : outcome.decision.key.description + suffix
                result.append(RunLine(id: run, firstRaw: raw, verdict: verdict, ok: outcome.decision.key == item.expected.key))
            } else {
                let key = UnstructuredBaseline.parse(raw)
                result.append(RunLine(id: run, firstRaw: raw, verdict: key?.description ?? "unparseable", ok: key == item.expected.key))
            }
        }
        return result
    }
}

// MARK: - Audit

struct AuditView: View {
    private let legacy = Data(LegacyParameterAudit.legacyExample.utf8)

    var body: some View {
        NavigationStack {
            List {
                Section("Request a lot of backends still send") {
                    Text(LegacyParameterAudit.legacyExample.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption2.monospaced())
                }
                Section("400 on API version 2026-10-21") {
                    ForEach((try? LegacyParameterAudit.audit(legacy)) ?? [], id: \.self) { finding in
                        Label(finding.description, systemImage: "xmark.octagon.fill")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
                Section("Migrated body") {
                    Text((try? LegacyParameterAudit.migrate(legacy)).map { String(decoding: $0, as: UTF8.self) } ?? "")
                        .font(.caption2.monospaced())
                }
                Section("What replaces temperature: 0") {
                    Label("Output schema (\(ReviewCategory.allCases.count) categories, closed object)", systemImage: "curlybraces")
                    Label("\(DecisionContract.triageV2.rules.count) explicit rules, \(DecisionContract.triageV2.examples.count) worked examples", systemImage: "list.bullet.rectangle")
                    Label("Validator + 3-attempt repair, then escalate", systemImage: "arrow.uturn.backward.circle")
                    Label("Variance eval, 20 runs per case", systemImage: "chart.bar.xaxis")
                    LabeledContent("v1 prompt", value: DecisionContract.triageV1.fingerprint).font(.caption.monospaced())
                    LabeledContent("v2 prompt", value: DecisionContract.triageV2.fingerprint).font(.caption.monospaced())
                }
            }
            .navigationTitle("Temperature audit")
        }
    }
}
