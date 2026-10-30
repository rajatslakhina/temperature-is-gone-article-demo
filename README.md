# ConsistencyKit: consistency without `temperature`

Claude API version `2026-10-21` returns a 400 for `temperature`, `top_p` and `top_k`, even at their default values ([migration guide](https://platform.claude.com/docs/en/api/migration-2026-10-21)). If `temperature: 0` was your reliability strategy, this package is what replaces it:

1. **`DecisionContract`**: a closed JSON schema, decision rules with ids, worked examples and limits. The system prompt is rendered from it deterministically and fingerprinted (FNV-1a) per version.
2. **`DecisionValidator`**: deterministic post-validation of what the contract states: shape, types, enum values, the summary limit and cross-field rules ("severity 4 requires a human").
3. **`ContractPipeline`**: model → validator, with at most 3 attempts (each retry sends the previous violations back), then a deterministic escalation.
4. **`VarianceEval`**: runs each input N times and reports agreement on the routing decision (category · severity · needs-human), accuracy against each case's labeled decision, and unparseable, repaired and escalated counts. `changes(since:)` compares two reports, so a new rule only counts as a fix when accuracy moves, not just agreement.
5. **`LegacyParameterAudit`**: finds and strips the removed sampling parameters in Messages and Message Batch request bodies.

Article: [Claude’s API Now Rejects temperature: 0. It Was Never Your Reliability Strategy.](https://medium.com/@er.rajatlakhina/claudes-api-now-rejects-temperature-0-it-was-never-your-reliability-strategy-2b49cb6a0906) on Medium.

![Diagram: the contract feeds the prompt and the validator; invalid answers retry with their violations up to 3 times, then escalate; the variance eval turns unstable cases into new rules.](docs/diagram.png)

## The code that matters

```swift
let pipeline = ContractPipeline(contract: .triageV2, client: myClaudeClient)
let outcome = await pipeline.run(reviewText)
// .accepted(decision, attempts:) or .fallback(.escalation(), attempts:, lastViolations:)
```

```swift
let report = await VarianceEval.evaluate(label: "prod", cases: myCases, runs: 20) { item, _ in
    let outcome = await pipeline.run(item.text)
    return .decided(outcome.decision.key, attempts: outcome.attempts, fallback: outcome.isFallback)
}
report.unstableCases(below: 0.9)   // write a rule or an example for each of these
report.fallbackRate                // escalating everything is 100% consistent and useless
```

Wrap your real client by conforming to `ModelClient` (`func complete(_ request: ModelRequest) async throws -> String`). Send no sampling parameters.

## Results from the bundled simulation

`SimulatedModel` is a seeded stand-in so the repo runs without an API key. Its behaviour is an explicit assumption documented in the source (it follows a covering rule 96% of the time, an uncovered case 55% of the time, and sometimes breaks format on a first attempt). **These numbers describe that model, not Claude.**

8 constructed reviews × 20 runs (`VarianceEval.standardComparison()`):

| Setup | Mean agreement | Accuracy vs labels | Cases ≥ 90% | Unparseable | Runs repaired by retry | Escalated |
|---|---|---|---|---|---|---|
| Vague prompt, lenient parser | 51.9% | 50.6% | 0/8 | 20/160 | n/a | n/a |
| Contract `triage-v1` | 91.2% | 91.2% | 6/8 | 0 | 17 | 0 |
| Contract `triage-v2` (+`R-money-first`, `R-mixed`) | 99.4% | 99.4% | 8/8 | 0 | 15 | 0 |

The v1 eval flagged case 6 ("Cancelled my trial but the app still says Pro. Is that a bug?", 12/20) and case 7 (praise followed by a complaint, 14/20). v2 adds a rule for each. That improvement is built into the simulated model; the point is the loop, not the number.

![Agreement per case under the three setups](docs/chart.png)

## Agreement is not accuracy

Agreement says a decision is stable, not that it is right. A billing complaint tagged `bug` in 20 of 20 runs scores 100% agreement. (A reader's response on the article made this point, and v1.1.0 is the result.) So every case carries a labeled decision, and the eval reports both numbers:

- `CaseReport.accuracy`: share of runs that returned the labeled decision. Invalid runs count as wrong.
- `VarianceReport.stableButWrongCases()`: agreement at or above the bar, but the most common answer is not the label. Agreement alone would call these solved.
- `VarianceReport.changes(since:)`: per case, `fixed` (accuracy up, agreement not down), `stabilizedOnly` (agreement up, accuracy not), `regressed` or `unchanged`.

In the bundled run, the vague prompt's most common answer is wrong for two reviews: the cancelled trial (`bug · s2 · auto`, 7 of 20, where the label is `billing · s2 · human`) and slow iPad sync. Comparing v2 with v1 marks exactly the two cases the new rules target (6 and 7) as `fixed`. Under both contracts the simulated model's most common answer is also the labeled one, so accuracy equals agreement there. With a real model they can diverge, and that gap is the thing to watch. `testStableButWrongIsCaughtByAccuracy` covers the 20-of-20-wrong case directly.

## Simulator

![Three iPhone Simulator screenshots of the Variance tab, captured by CI: vague prompt 52%, contract v1 91%, contract v2 99%](docs/simulator.png)

The demo app has three tabs: **Variance** (the table above, live), **Runs** (one review, 10 runs, first raw answer → verdict) and **Audit** (a legacy request, its 400 findings and the migrated body).

## How to run it

```bash
git clone https://github.com/rajatslakhina/temperature-is-gone-article-demo.git
cd temperature-is-gone-article-demo
open Demo.xcodeproj   # pick an iPhone Simulator, Build & Run
```

No other setup: the app consumes the package through a local package reference. Library only:

```bash
swift build && swift test
```

## Verification status

- `swift build -Xswiftc -warnings-as-errors` and `swift test`: passed on Linux (Swift 6.1.2, 35 tests, 0 failures) and in the `library` CI job on macos-15. v1.1.0: [run 41075191451](https://github.com/rajatslakhina/temperature-is-gone-article-demo/actions/runs/41075191451) on `b1d8191`, 35 tests, 0 failures. v1.0.0: [run 41033497209](https://github.com/rajatslakhina/temperature-is-gone-article-demo/actions/runs/41033497209) on `3230cb7` and [run 41037066603](https://github.com/rajatslakhina/temperature-is-gone-article-demo/actions/runs/41037066603) on `65c5e32`.
- Simulator run: completed by the `demo-on-simulator` CI job in all three runs. Each run built `Demo.xcodeproj` for an iPhone Simulator, installed the app, launched it five times with a process-alive check after each launch, and saved the screenshots in `Demo/Screenshots/`, composed into `docs/simulator.png`. The current screenshots come from the v1.1.0 run (iPhone 17 Pro, commit `49b1c03`). It was not run by hand in a local Xcode.

## License

MIT
