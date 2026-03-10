# AGENTS.md

## Project context

This repository is a fork of WPScan used to prototype **media timeleak detection** features inspired by:

- our research on WordPress / Jetpack media exposure
- the JetGhost-Suite research tooling
- the upstream proposal around `MediaAnomalies` and `PredictableMedia`

The goal is **not** to port JetGhost-Suite line-by-line into Ruby.
The goal is to **translate the relevant ideas** into WPScan's native architecture, coding style, and operational model.

## What JetGhost-Suite is, for the purposes of this repo

Treat JetGhost-Suite as a **research reference implementation** that demonstrates useful ideas:

- comparing sitemap-declared media vs publicly observed rendered HTML
- detecting media that remains publicly reachable but is not obvious in sampled public pages
- identifying Jetpack-related sitemap/render discrepancies
- deriving a very small set of plausible media filename candidates from already observed media URLs

Do **not** assume JetGhost-Suite's structure should be mirrored here.
Do **not** translate Python files one-to-one into Ruby files.
Do **not** import broad crawling, mass scanning, or lab-only helper behavior unless explicitly requested.

## Product goal

Add two capabilities to WPScan in an upstream-friendly way:

1. `MediaAnomalies`
   - a new **Interesting Finding**
   - low-noise, bounded, default-safe
   - based on sitemap analysis and sampled rendered HTML comparison

2. `PredictableMedia`
   - **opt-in / aggressive** only
   - seeded only from already observed media URLs
   - very small candidate generation space
   - strong anti-false-positive controls

## Non-goals for v1

Do not implement the following unless the task explicitly asks for them:

- a literal port of JetGhost-Suite
- broad crawling beyond the bounded sampling model
- mass internet-wide detection workflows
- generic CMS support outside WordPress
- brute-force filename enumeration
- large wordlists or combinatorial guessing
- deep `/wp-json/wp/v2/media` integration in the first phase
- changes unrelated to sitemap/media timeleaks

## Required implementation philosophy

- Prefer **small, reviewable diffs**.
- Prefer **helpers + tests first** over large feature drops.
- Prefer **low false-positive rate** over coverage.
- Prefer **bounded request budgets** over aggressive discovery.
- Prefer **native WPScan abstractions** over convenience wrappers.
- If a design choice is ambiguous, choose the option most likely to be accepted upstream.

## Expected work split

### PR1 — Sitemap infrastructure

Implement reusable helpers for:

- discovering sitemaps from `robots.txt`
- trying common fallback endpoints
- validating real sitemap XML
- supporting `sitemapindex`, `urlset`, namespaces, and `.gz`
- rejecting HTML/WAF pages disguised as XML
- classifying sitemap vendor as:
  - `wordpress_core`
  - `yoast`
  - `jetpack`
  - `unknown`

This PR should be mostly helpers, fixtures, and tests.
It should not yet add the final user-facing finding.

### PR2 — MediaAnomalies

Implement a new **Interesting Finding** that reports:

- **A1**: public attachment URLs declared in sitemap but **not observed in sampled public pages**
- **A2**: Jetpack-style discrepancies where media is declared in sitemap but absent from sampled rendered HTML

Reporting must be conservative.
Never claim absolute hiddenness.
Use wording like:

- `not observed in sampled public pages`
- `declared in sitemap but absent from sampled rendered HTML`

Do not use wording like:

- `not linked anywhere`
- `definitively hidden`

### PR3 — PredictableMedia

Implement an **opt-in / aggressive** capability that:

- uses only already observed media URLs as seeds
- generates a very small set of plausible candidates
- validates candidates with strong baseline logic

Allowed candidate families for v1:

- nearby numeric sequence variants
- removing a single sensitive suffix such as:
  - `-draft`
  - `-borrador`
  - `-redacted`
  - `-private`

Do not add broad mutation engines.
Do not add dictionaries.
Do not brute-force.

## Request budgets and bounds

Respect these budgets unless the task explicitly changes them.

### MediaAnomalies

- ~80 extra requests maximum
- at most 50 sampled public posts/pages
- at most 500 attachment URLs from sitemap inputs
- at most 20 active verification requests

### PredictableMedia

- at most 200 seeds
- at most 8 candidates per seed
- at most 300 candidate requests
- 1–2 baseline requests for 404 / 200-for-404 detection

If a possible implementation exceeds these limits, stop and redesign.

## WPScan-specific architectural guidance

Use WPScan's native layout and style.
Do not introduce a parallel architecture.

Prefer changes in areas such as:

- `app/finders/...`
- `app/models/...`
- shared parsing / helper code where appropriate
- specs / fixtures for deterministic coverage

Keep the distinction clear between:

- **Interesting Findings**
- **enumeration features**

Do not overload the existing media enumeration by `attachment_id` with filename prediction semantics.
If `PredictableMedia` needs CLI surface, keep it clearly separate and explicitly opt-in.

## Testing expectations

Write tests first or alongside implementation.
Every meaningful parser / classification / baseline branch should have coverage.

Minimum expected tests by phase:

### PR1
- sitemap discovery from `robots.txt`
- fallback endpoint discovery
- valid `urlset`
- valid `sitemapindex`
- `.gz` handling
- namespace handling
- HTML response masquerading as XML
- vendor classification cases

### PR2
- no-evidence case
- orphan attachment candidate case
- Jetpack-style discrepancy case
- output formatting / counting behavior
- request-bound enforcement

### PR3
- baseline 404 case
- 200-for-404 case
- HTML-like false positive rejection
- non-HTML candidate acceptance
- suffix-removal candidate case
- nearby-number candidate case
- request-budget enforcement

## Commit and patch discipline

- Make small, logical commits.
- Do not bundle unrelated refactors.
- Do not rename files unless needed.
- Do not reformat unrelated code.
- Do not change public behavior unless the task requires it.
- If a refactor is necessary, keep it isolated and explain why.

## Output expectations when working on a task

When given a large task, respond in this order:

1. list the files you plan to touch
2. explain the design in a few concise bullets
3. implement the requested phase only
4. summarize:
   - files changed
   - tests added
   - remaining risks / follow-ups

Do not silently implement later phases.
Do not expand scope on your own.

## Decision rules

If you are unsure whether to choose a more powerful or more conservative behavior:

- choose conservative
- choose bounded
- choose upstream-friendly
- choose low-noise

If you are unsure whether something belongs in v1:
leave it out and note it as future work.

## What success looks like

A successful contribution in this repo:

- feels like native WPScan code
- is small enough to review comfortably
- is testable and deterministic
- avoids noisy results
- preserves existing semantics
- can plausibly be proposed upstream in pieces

## Execution plan for media timeleaks work

For the WPScan media timeleaks feature, read `/CODEX_TASK.md` before making any code changes.

Treat `/CODEX_TASK.md` as the project execution plan for:
- PR1: sitemap discovery, validation and vendor classification
- PR2: MediaAnomalies interesting finding
- PR3: PredictableMedia opt-in detection

Do not start implementation until you have read that file fully.
Follow its scope, request budgets, non-goals and acceptance criteria.
