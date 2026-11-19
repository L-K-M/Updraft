# AGENTS.md

Guidance for AI coding agents working in the **Updraft** repository.

## What Updraft Is

The "is there a newer release on GitHub?" checker shared by the L-K-M menu-bar
and desktop apps (Zap, Jetty, Invoque, Top Drawer, Gans, RepoMen, Lucerne,
Vervellum, Wrapybara).

- `UpdraftCore` (Foundation only, builds on Linux): `SemanticVersion`,
  `GitHubRelease`, `GitHubReleaseClient`, `UpdateVersionComparison` and
  `UpdateDownloader`.
- `UpdraftKit` (AppKit): `UpdateChecker`, which schedules checks, remembers
  the user's choices and presents the alerts.

## Compatibility Contracts

- **Persisted state belongs to the app.** `UpdateChecker` stores its enabled
  flag, last-check date and skipped version in `UserDefaults` under a
  configurable key prefix. Each app passes the prefix it already used, so
  existing users keep their settings. Never change how a key is named or what
  type it holds.
- **Updraft never installs anything.** It downloads a release asset to the
  user's Downloads folder (or opens the release page) and leaves installation
  to the user and Gatekeeper. Downloaded files carry the quarantine attribute
  so Gatekeeper evaluates them on first open.
- **Unauthenticated GitHub API only**, no telemetry, no other network calls.
  Background checks never show an error; only user-initiated checks report
  failures.
- **Version strings are untrusted input.** An unparseable tag or installed
  version is reported as such, never as "up to date".
- Apps that run as menu-bar agents set `deferWhileInactive`, so an update found
  by a background check while the app is inactive waits until the app is next
  activated instead of stealing focus.

## Versioning and consumers

- Releases are semantic-version tags (`vX.Y.Z`) cut with
  `bash scripts/release.sh X.Y.Z --push`. CI re-runs the full checks on the tag
  before publishing the GitHub release.
- Consumers reference this package by tag with an *up to next minor* rule and
  commit their `Package.resolved`, so a release reaches an app only when that
  app updates its pin and its own CI passes. Never ask a consumer to track
  `main` or a branch.
- While the version is `0.x`, a minor bump may change public API; a patch
  release must stay source-compatible and must not change a stored format.
- Before tagging, build and test every consumer against the release candidate
  (see the consumer table in `README.md`). A green package suite alone does not
  show that the apps still build.
- Record every change a user of a consuming app could notice in
  `CHANGELOG.md` under the release that introduces it.

## Conventions

- Swift tools 5.9, Swift 5 language mode, macOS 13 minimum, matching the
  oldest consumer. Code must build with both Xcode 16 (macOS 15 SDK) and
  Xcode 26 or later (macOS 26 SDK). Guard macOS 26 SDK symbols with
  `#if compiler(>=6.2)` plus `#available(macOS 26, *)`.
- The `*Core` target imports Foundation only and must build and pass its tests
  on Linux. Everything that needs AppKit, SwiftUI or Carbon goes in the `*Kit`
  target.
- Everything a consumer touches is `public`, including explicit `public init`s
  on structs. Keep everything else internal or private, and keep the public
  surface small: every public symbol is a commitment to several apps.
- No third-party dependencies.
- One primary type per file; file name matches the type; `// MARK:` sections.
- Comments explain why, especially where a choice looks arbitrary. Most of the
  code here came out of the apps with its reasons attached; keep them.
- Avoid force-unwraps outside tests.

## Build and test

```bash
swift build
swift test
swift build -c release
```

`bash scripts/build.sh` runs the same checks. CI runs them on macOS with
Xcode 16.4 and Xcode 26, and builds and tests the Core target on Linux.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->
