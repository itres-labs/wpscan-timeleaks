# CODEX_TASK.md

## Task title
Integrate JetGhost-inspired media timeleak detection into WPScan in an upstream-friendly way

## Context
You are working on a fork of WPScan:
- Target repo: `itres-labs/wpscan-timeleaks`

This task is inspired by:
- Research article: `CMS Media Timeleaks in Jetpack, WordPress and beyond`
- Research article: `How We “Stole” a Non-Public CVE: Draft Artifacts as an Attack Surface`
- Reference tooling repo: `itres-labs/JetGhost-Suite`
- Upstream design proposal: WPScan issue `#1956`

This file is intentionally self-contained. Do **not** assume prior knowledge of JetGhost-Suite or the research write-ups. Use the summary below as the source of truth for scope and intent.

---

## What JetGhost-Suite is
JetGhost-Suite is a small research toolset focused on **CMS media timeleaks**:
- cases where media files remain publicly reachable or trivially discoverable outside the editorial intent
- especially when media lifecycle differs from post/page lifecycle
- especially when sitemaps or predictable filenames expose the artifacts

### Relevant components in JetGhost-Suite
Use these as **conceptual references**, not as code to port literally:

- `tools/jetghost/jetghost.py`
  - Main auditor
  - Diffs sitemap-declared media against live HTML
  - Core idea: if media is public and announced in sitemap but absent from rendered HTML, it may be a meaningful anomaly

- `tools/jetpack/jetpack-detect.py`
  - Fast fingerprinting of Jetpack / WP.com style sitemap behavior
  - Core idea: vendor-aware behavior matters

- `tools/jetpack/jetpack-leak.py`
  - Bulk pre-filter for likely Jetpack leak candidates
  - Core idea: use cheap heuristics before expensive validation

- `tools/patterns/leakloom.py`
  - Predictable media naming / versioning analysis
  - Core idea: bounded filename prediction can surface “future” or redacted artifacts when filenames follow deterministic patterns

- `tools/wp/wp_media_explorer.py`
  - Enumerates `/wp-json/wp/v2/media` and analyzes filename patterns
  - Useful as inspiration only; **not** primary scope for v1

### Important translation rule
Do **not** port JetGhost-Suite line-by-line to Ruby.
Instead, translate the **detection ideas** into WPScan’s own architecture and UX.

---

## Security problem statement
There are two closely related exposure patterns:

### 1) “Leak the past”
An editor uploads an original media file, later replaces it in the post HTML with a redacted/sanitized version, but the old attachment remains public and may still appear in sitemaps.

Typical signal:
- media URL is still public
- media URL appears in an attachment or image sitemap
- media URL is not observed in the current rendered HTML of public pages

### 2) “Leak the future”
Draft assets may become publicly reachable before publication if the site stores uploads on a public origin with predictable paths and filenames.

Typical signal:
- observed media filenames follow a deterministic pattern
- nearby or unsuffixed variants are publicly reachable
- assets are accessible even though no public page links them yet

WPScan should detect **bounded, practical, low-noise indicators** of these problems.

---

## Architecture constraints from WPScan
WPScan already has a native structure for:
- `InterestingFindings`
- targeted `Finders`
- enumeration flows via `--enumerate`
- media enumeration tied to `attachment_id` / plain permalinks

You must fit the new capability into the **existing WPScan model**, not redesign WPScan.

### Meaningful implications
- Sitemap-based anomaly detection belongs naturally in **Interesting Findings**
- The current `medias` enumeration should **not** be repurposed for filename prediction
- Anything higher-risk / noisier must be **opt-in** and clearly marked as aggressive

---

## Implementation goal
Add two capabilities:

### A) `MediaAnomalies`
A new **Interesting Finding** that detects sitemap-based media exposure anomalies.

### B) `PredictableMedia`
A new **opt-in / aggressive** capability that tries a very small set of filename predictions based only on passively observed media URLs.

---

## Design principles
1. **Upstream-friendly first**
   - small, reviewable PRs
   - minimal diff footprint
   - no unrelated refactors

2. **Low noise over maximum coverage**
   - prefer missing edge cases over spamming false positives

3. **Passive by default, aggressive only when explicit**
   - default scan behavior should remain stable

4. **Tests and fixtures first**
   - every new parser / classifier should have fixtures

5. **Explainability matters**
   - findings must say what was observed, not overclaim certainty

---

## Non-goals for v1
Do **not** include the following in the first implementation unless explicitly required later:

- broad CMS support outside WordPress
- mass scanning / bulk helper workflows
- large dictionary brute forcing
- aggressive crawling beyond sampled sitemap/pages
- `/wp-json/wp/v2/media` as a primary signal
- claims like “this file is definitely private” or “not linked anywhere on the site”
- a literal port of Python tool CLI behavior into WPScan CLI

---

## Required implementation plan
Deliver the work in **three phases / PRs**.

# PR1 — Sitemap discovery, validation and vendor classification

## Goal
Create reusable sitemap infrastructure required by later finders.

## Required behavior
Implement helpers to:
- discover sitemap locations from `/robots.txt` via `Sitemap:` directives
- fall back to common endpoints when needed, including:
  - `/wp-sitemap.xml`
  - `/sitemap_index.xml`
  - `/sitemap.xml`
  - `/news-sitemap.xml`
  - gzip variants when relevant
- validate that a response is an actual sitemap:
  - parseable XML
  - root element is `sitemapindex` or `urlset`
  - namespaces tolerated
  - gzip supported
  - reject HTML / WAF / error pages pretending to be XML
- classify vendor with confidence and reasons:
  - `:wordpress_core`
  - `:yoast`
  - `:jetpack`
  - `:unknown`

## Expected output of PR1
- reusable helpers/classes
- fixtures for valid and invalid sitemap cases
- tests covering discovery, validation, gzip and vendor classification

## Out of scope for PR1
- no user-visible findings yet
- no CLI changes
- no filename prediction

---

# PR2 — `MediaAnomalies` Interesting Finding

## Goal
Add a new Interesting Finding for sitemap-based media anomalies.

## Expected behavior
Implement a finder that runs when a valid sitemap context exists and detects:

### A1 — orphan attachment candidates via sitemap
Definition:
- attachment/media URLs present in attachment/image sitemap data
- not observed in a bounded sample of rendered public HTML
- optionally verified to be real media resources

Implementation rules:
- sample a bounded number of public pages/posts from sitemap data
- fetch sampled HTML and extract candidate media references from:
  - `img[src]`
  - `img[srcset]`
  - `source[srcset]`
  - `a[href]` to uploads/media
  - common lazyload attributes where easy and safe
- compare rendered media set vs sitemap media set
- report only meaningful discrepancies

### A2 — Jetpack shadow leak
Definition:
- vendor is Jetpack or evidence strongly suggests Jetpack behavior
- sitemap-declared media differs from what sampled rendered HTML exposes
- discrepancy is verified and worth reporting

Implementation rules:
- only run Jetpack-specific logic when classifier confidence is sufficient and/or plugin evidence exists
- keep verification bounded

## Reporting rules
The finding must include:
- short risk-oriented description
- count
- up to about 10 examples
- confidence level
- references

## Language constraints
Do say things like:
- `declared in sitemap but absent from sampled rendered HTML`
- `not observed in sampled public pages`

Do **not** say things like:
- `not linked anywhere`
- `definitively hidden`
- `private file`

## Request budget
Keep it bounded, approximately:
- max extra requests: `~80`
- max sampled posts/pages: `50`
- max sitemap attachment URLs processed: `500`
- max verification requests: `20`

---

# PR3 — `PredictableMedia` opt-in / aggressive detection

## Goal
Add a strictly bounded predictive media finder.

## Critical gating
This must **not** run by default.
It must be clearly marked as **opt-in / aggressive**.
It must **not** hijack or semantically overload the existing media enumeration behavior tied to attachment IDs.

## Seed source
Use only **passively observed media URLs** gathered during normal scanning / already-fetched pages.
No extra crawling for seeds.

## Candidate generation
Generate **very few** candidates per seed.
Allowed ideas:
- small numeric neighbor windows
  - preserve zero padding
  - tiny increments/decrements only
- removal of a single sensitive suffix such as:
  - `-draft`
  - `-borrador`
  - `-redacted`
  - `-private`

Do **not** expand into broad combinatorial guessing.

## False-positive controls
These are mandatory:
- establish a 404 baseline
- handle `200-for-404` style applications
- reject HTML resembling baseline/error pages
- prefer reporting only when `content-type` is non-HTML
- ignore trivial/ambiguous responses

## Request budget
Keep it bounded, approximately:
- max seeds: `200`
- max candidates per seed: `8`
- max candidate requests: `300`
- 404 baseline requests: `1-2`

---

## Likely WPScan areas to inspect before coding
Use this as guidance, not a hardcoded patch plan.

Potentially relevant files/modules include:
- `app/finders/interesting_findings.rb`
- `app/models/interesting_finding.rb`
- `app/controllers/enumeration.rb`
- `app/controllers/enumeration/cli_options.rb`
- `app/controllers/enumeration/enum_methods.rb`
- current media finder code
- any existing sitemap parsing helpers or XML helper abstractions
- target/page fetching helpers already used by WPScan finders

Prefer adding **small new classes** over modifying many old ones.

---

## Expected code style
- idiomatic Ruby
- WPScan naming/style conventions
- small classes with clear responsibilities
- parsing logic separated from reporting logic
- no giant god-class
- no speculative abstractions unless they remove obvious duplication

---

## Delivery protocol
When you work on this task, follow this exact order:

1. Inspect the current WPScan codebase and summarize:
   - which files are relevant
   - where Interesting Findings are registered
   - how current media enumeration works
   - where a new aggressive capability should live

2. Propose a concrete file plan:
   - files to create
   - files to modify
   - brief purpose of each

3. Implement **PR1 only** first.

4. After PR1, provide a concise review note:
   - files changed
   - tests added
   - design decisions made
   - open risks / ambiguities

5. Only then move to PR2.

6. Only after PR2 is stable, move to PR3.

---

## Acceptance criteria

### Global
- no broad regressions
- no unrelated cleanup
- easy to review in small commits
- clear tests and fixtures

### PR1 accepted when
- sitemap discovery works from robots and common endpoints
- gzip/XML validation works
- fake XML / HTML error pages are rejected
- vendor classification is covered by tests

### PR2 accepted when
- `MediaAnomalies` appears as an Interesting Finding
- output is readable and bounded
- Jetpack-specific logic is gated
- wording avoids overclaiming

### PR3 accepted when
- predictive checks are strictly opt-in
- existing media enumeration semantics remain intact
- baseline filtering clearly reduces false positives

---

## Things to avoid
- Don’t port the Python CLI UX directly
- Don’t add a huge configuration surface up front
- Don’t turn this into a generic crawler
- Don’t use “future leak” logic without strict caps
- Don’t assume Jetpack everywhere
- Don’t claim certainty where we only have sampled evidence

---

## If you are unsure
Prefer this decision order:
1. lower noise
2. easier upstream review
3. smaller diff
4. better explainability
5. more coverage

---

## Final instruction
The goal is **not** to recreate JetGhost-Suite inside WPScan.
The goal is to **embed the relevant detection ideas from JetGhost-Suite and the research articles into WPScan’s native architecture** so the result feels like a natural WPScan feature and can realistically be proposed upstream later.
