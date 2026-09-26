# Independent review and Claude Final Review

## Why author != reviewer

RESEARCH_FINDINGS.md is explicit: "never allow the model that authored a substantial patch
to be its sole reviewer." `SameModelReviewException`
(`lib/core/review/reviewer.dart`) enforces this in code — `ModelReviewer.review()` throws if
the reviewer's own `ModelId` matches the `authorModelId` passed in, rather than relying on
prompt discipline. This is covered by
`test/core/review/reviewer_test.dart` (`refuses to let a model review a patch it authored
itself`).

## Reviewer abstraction

`Reviewer` (`lib/core/review/reviewer.dart`) is the single interface both the ordinary
Independent Review Agent step and the optional Claude Final Review step implement.
`ModelReviewer` is the concrete implementation — configure it with any `ModelProvider` and
model name; using an `AnthropicProvider` + a Claude model makes it the Claude Final
Reviewer, using any other provider/model makes it the "different review model" required
for a same-provider independent review. The pipeline code that calls a `Reviewer` never
knows which one it's talking to — swapping or supplementing Claude later is a
configuration change, per the brief's "make the reviewer provider abstract."

## Review Package

`ReviewPackage` (`lib/core/review/review_package.dart`) is the compact bundle handed to a
reviewer instead of the full development transcript: task, original problem, requirements,
implementation summary, architectural changes, diff, files changed, tests run, build
result, before/after notes, known limitations, security/performance notes.
`ReviewPackage.render()` produces the single prompt sent to the reviewer — no raw
conversation history is ever forwarded. Assembling a `ReviewPackage` from a completed
`Task`'s Git diff and step notes is the Final Review Preparation Agent's job
(`AgentRole.finalReviewPreparation` in `lib/core/agents/agent_role.dart`).

## Verdicts

`ReviewOutcome`: `pass`, `passWithConcerns`, `rework`, `fail`. `ModelReviewer._parseVerdict()`
looks for an explicit `VERDICT: ...` line (or `APPROVE`/`REWORK REQUIRED` for a
Claude-style response) and **fails closed to `rework`** if the response doesn't contain a
recognisable verdict — an unparsable review is never silently treated as a pass. Findings
are extracted as bulleted lines from the response body.

## Rework loop

```
WORKER AGENT -> REPAIR -> TEST -> REVIEW PACKAGE -> REVIEWER -> REWORK -> WORKER -> RETEST -> REVIEWER
```

`ReviewCycleRunner.run()` (`lib/core/review/reviewer.dart`) implements this loop, bounded by
`maxCycles` (mirrored in `Task.maxReviewCycles`, default 3, tracked via
`Task.reviewCycleCount`/`TaskManager.recordReviewCycle()`). It calls the reviewer, and on a
`requiresRework` verdict, calls the caller-supplied `performRework` callback (which should
push a fix and retest) before reviewing again — stopping the moment the reviewer passes, or
once `maxCycles` is exhausted, whichever comes first. See
`test/core/review/reviewer_test.dart` for both terminating conditions exercised.

## Configuring Claude Final Review

Set the `anthropic_api_key` secret (Settings panel or `SecretsStore` directly), then
construct a `ModelReviewer(reviewerId: 'claude-final', provider: AnthropicProvider(...),
modelName: 'claude-sonnet-5')` (or another current Claude model — see
`AnthropicProvider.knownModelIds`) and pass it as the final stage of a task's review
pipeline. No undocumented API or CLI hack is used — this goes through the same public
Anthropic Messages API as any other Anthropic API integration.
