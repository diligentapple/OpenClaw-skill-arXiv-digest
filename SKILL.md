---
name: arxiv-morning-digest
description: Produces a personalized digest of recent arXiv papers ranked by relevance to the researcher's stated interests in USER.md. Use when the user wants a morning paper digest, a personalized arXiv feed, or asks "what's new on arxiv", "arxiv digest", "arxiv morning digest", "today's papers", "morning digest", or "/digest". Also handles first-run setup, triggered by phrases like "set up arxiv digest", "configure arxiv digest", or "reconfigure my interests". Supports daily heartbeat-style runs and on-demand chat runs.
---

# ArXiv Morning Digest

Follow this workflow to fetch, rank, log, and deliver a personalized arXiv digest. On first use, run the Onboarding subflow before producing a digest.

## Step 1, read research interests (with onboarding)

Read `USER.md` and look for the `## Research interests` section.

**Branch on what you find:**

- If the section exists and contains at least one interest, proceed to Step 2.
- If the section is missing or empty AND this is an on-demand chat run, run the **Onboarding subflow** (below). After it completes, re-read `USER.md` and proceed to Step 2.
- If the section is missing or empty AND this is a HEARTBEAT-triggered run, do not start onboarding (no user is present to answer). Instead, post once to the primary channel:

  *"No research interests configured yet. Type 'set up arxiv digest' to configure, then I'll start delivering each morning."*

  Append the same message to today's Daily Log and stop.

If the user explicitly says "set up arxiv digest", "configure arxiv digest", or "reconfigure my interests", run the Onboarding subflow regardless of whether interests are already present. Show existing interests as the starting point and let the user revise.

Optionally read `## Explicit non-interests` and use it to deprioritize or exclude papers in later steps.

## Onboarding subflow

This subflow is conversational. Keep prompts short. Do not ask all questions at once.

**1. Greet and confirm.** Open with one sentence:

*"I haven't seen your research interests yet. I can set you up in about a minute, want to go through it now?"*

If the user declines, respond *"No problem, just trigger the digest again or say 'set up arxiv digest' when you're ready."* and stop.

**2. Free-form description.** Ask:

*"What do you work on? A couple of sentences in your own words is enough, I'll help shape it."*

**3. Propose specific interest phrasings.** From the user's free-form answer, draft 3 to 5 specific interests. Each should:
- Be specific enough to rank against (not "machine learning" or "AI").
- Use the user's own framing where possible.
- Cover the major areas they mentioned, without inventing topics they didn't.

Show the proposed list as a numbered draft. Example format:

```
1. Mechanistic interpretability of transformer attention heads
2. Retrieval-augmented generation with long-context models
3. Parameter-efficient fine-tuning, especially LoRA and adapters
```

**4. Iterate.** Ask: *"Does this look right? You can add, remove, or rephrase any of them. Also tell me if there's anything you specifically want excluded, for example 'no pure theory papers'."*

Loop until the user confirms.

**5. Suggest arXiv categories.** Map the confirmed interests to arXiv category codes. Use these defaults:

- LLM, NLP, language topics → `cs.CL`, `cs.AI`
- General ML methods, optimization, training → `cs.LG`, `stat.ML`
- Vision-language, multimodal → `cs.CV`, `cs.CL`
- Robotics, agents in physical environments → `cs.RO`, `cs.AI`
- Security, privacy → `cs.CR`, `cs.LG`
- If unsure, default to `cs.LG`, `cs.CL`.

Show the proposed categories with one-line explanations and ask for approval. Faculty unfamiliar with arXiv codes do not need to defend the choice, just confirm.

**6. Show the diff before writing.** Display exactly what will be appended or changed in `USER.md`:

```markdown
## Research interests
- [interest 1]
- [interest 2]
- [interest 3]

## Explicit non-interests
- [exclusion 1]   (only if the user named exclusions)
```

If the user wants `ARXIV_CATEGORIES` set to something other than the default, also note that as an environment variable to add.

**7. Confirm.** Ask: *"Save this to your profile?"* Do not write without an explicit yes.

**8. Write.** Use the Write tool to update `USER.md`. Append the new sections; preserve everything else in the file. Do not modify unrelated content like name, timezone, or notes.

**9. Hand off.** Confirm: *"Saved. Running today's digest now."* Then continue to Step 2.

## Step 2, determine the time window (incremental sync)

The window covers everything since the last successful digest, capped at `MAX_LOOKBACK_DAYS` days (default `4`).

Use `TIMEZONE` for human-readable date display. arXiv queries always use UTC.

**Weekend short-circuit.** If today is Saturday or Sunday and `SKIP_WEEKENDS=true` (default), respond exactly:

*"arXiv doesn't publish on weekends, the next digest will catch up Monday morning."*

Then stop.

**Find the watermark.** Scan `memory/YYYY-MM-DD.md` files for the last 14 days, most recent first. Look for a `## ArXiv Digest` section containing a `**Window:**` line. The first one found defines the watermark.

Parse the right-hand side of that `**Window:**` line as the previous run's `WINDOW_END_UTC`. That value is the new watermark.

**First-run fallback.** If no prior digest is found within 14 days, treat this as a first run. Use `(now_utc - 24h)` as the watermark.

**Compute the new window.**

```
WATERMARK_UTC      = parsed from last digest, or (now - 24h) for first run
WINDOW_START_UTC   = max(WATERMARK_UTC - 12h, now_utc - MAX_LOOKBACK_DAYS days)
WINDOW_END_UTC     = now_utc
```

The 12-hour buffer subtracted from the watermark accounts for the gap between arXiv's `submittedDate` (upload time) and the announcement cycle that makes a paper publicly visible. Dedup in Step 7 will catch any overlap.

The `MAX_LOOKBACK_DAYS` cap prevents catastrophic windows after long absences (vacations, gateway downtime). If the user has been away longer, they get the most recent 4 days, not 4 weeks.

**Same-day re-trigger.** If `WINDOW_END_UTC - WINDOW_START_UTC < 1h`, respond:

*"No new window since the last run at [time]. Re-run later or use 'reconfigure my interests' to change settings."*

Then stop.

**Format for arXiv API.** Convert both timestamps to `YYYYMMDDHHMM` for the `submittedDate:[A TO B]` query clause.

## Step 3, plan queries in-model

Do not issue one compound query for all interests.

Plan one query per interest, or one query per cluster of closely related interests. Cap total queries at 4.

For each query, identify semantic groups and build an `all:` search with `OR` within groups and `AND` across groups, then append the date window and category filter.

Pattern:

```text
(all:"<domain term>" OR all:"<synonym>") AND (all:"<method term>" OR all:"<synonym>") AND submittedDate:[<WINDOW_START_UTC> TO <WINDOW_END_UTC>] AND (cat:...)
```

Default categories come from `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`.

## Step 4, set fetch size

Set `max_results = MAX_RESULTS_PER_QUERY` per query (default `200`).

The date filter from Step 2 already bounds how many papers can be in scope. `max_results` is just an upper bound to ensure the full window is captured even on busy days. Raise to `500` for very active categories or windows near the 4-day cap.

There is no oversample multiplier in this design. Recall is bounded by the window, not by a heuristic count.

## Step 5, fetch papers serially

Use a single shell call that performs all arXiv fetches serially with `curl` against `https://export.arxiv.org/api/query`.

Use `curl --globoff -A "openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)" -L -f -sS` so bracketed `submittedDate:[...]` queries are not treated as URL globs and requests identify the caller clearly.

Respect arXiv rate limits by waiting at least `ARXIV_MIN_INTERVAL_SEC` seconds between calls, default `5`.

If one query fails with HTTP 429, another non-200 result, timeout, or transport error, retry it once after 15 seconds. If it still fails, skip that query and continue.

If all queries fail, respond exactly:

*"arXiv API unreachable, try again in a few minutes."*

Then stop.

## Step 6, parse and union results

From each Atom XML response, extract:

- arXiv id
- title
- summary
- authors
- published date
- primary category
- abs link

Union results across queries and deduplicate by arXiv id.

## Step 7, deduplicate against recent digests

Read `memory/YYYY-MM-DD.md` for the last 7 days when present.

Extract arXiv ids already briefed and remove them from the current candidate set. With incremental sync, dedup is mostly a backstop for the 12-hour buffer overlap, but it also defends against watermark-detection failures.

If a current paper is a revision of a previously briefed paper, keep it and annotate the brief with: *"revision of earlier digest entry."*

## Step 8, rank by relevance

Rank by semantic relevance to the stated interests, not mere keyword overlap.

A paper can match even if it uses neighboring terminology.

Use non-interests to deprioritize or drop mismatches.

If two papers are equally relevant, prefer the more recently submitted one.

If nothing is strongly relevant, say so instead of padding.

## Step 9, select top N

Keep the top `DIGEST_SIZE` meaningfully relevant papers (default `3`).

If fewer than `DIGEST_SIZE` qualify, deliver only those and mention the shortfall.

## Step 10, generate briefs

For each selected paper, use exactly this structure:

```text
📄 [Title]
Authors: [First author et al., or up to 3 names]
Submitted: [YYYY-MM-DD]
Link: https://arxiv.org/abs/[id]

TL;DR: [one sentence, plain language]
Contribution: [what's new or different, one sentence]
Why relevant to you: [reference a specific interest from USER.md by name]
Verdict: Read / Skim / Skip
```

Verdict rubric:

- `Read`: directly extends a stated interest with a non-trivial result
- `Skim`: adjacent, or uses a technique the researcher would want to know about
- `Skip`: tangential but surfaced for completeness

## Step 11, write to the Daily Log

Append the digest to `memory/YYYY-MM-DD.md` under `## ArXiv Digest`.

The header must include a `**Window:**` line in this exact format, because Step 2 of the next run parses it as the watermark:

```text
## ArXiv Digest
**Run at:** YYYY-MM-DD HH:MM ±HH:MM
**Window:** YYYY-MM-DDTHH:MMZ → YYYY-MM-DDTHH:MMZ
**Categories:** cs.LG, cs.CL
**Queries:** N
**Scanned:** N candidates
**After dedup:** N
**Briefed:** N

[full briefs from Step 10]
```

Both timestamps in the `**Window:**` line are UTC, with `Z` suffix and `→` separator.

If the skill is running from an automated schedule and fails after its retry policy, append the error to today's Daily Log and stay silent. In failure cases, do not write a `**Window:**` line — the next run should use the previous successful run's watermark, not this failed one.

## Step 12, return to the active channel

Lead with:

*"Digest for [date], window [WINDOW_START → WINDOW_END], scanned [N] papers, [K] after dedup, top [M] below."*

Then include the selected briefs.

For asynchronous scheduled delivery, post as a separate message rather than interrupting an active exchange.

## Proactive tuning

If fewer than `DIGEST_SIZE` relevant papers surface for 2 or more days in a row, suggest broadening `ARXIV_CATEGORIES` or loosening the phrasing in `USER.md`.

If the user rejects multiple papers as irrelevant, suggest tightening interests or adding `## Explicit non-interests`.

If the user consistently reads every brief carefully, suggest increasing `DIGEST_SIZE`.

If many runs hit the `MAX_LOOKBACK_DAYS` cap (returning to find a backlog), suggest enabling HEARTBEAT or setting a longer cap.

If the user has not yet completed onboarding, do not run proactive tuning.

Offer suggestions, do not edit `USER.md` without asking.

## Environment variables

- `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`
- `DIGEST_SIZE`, default `3`
- `MAX_RESULTS_PER_QUERY`, default `200`
- `MAX_LOOKBACK_DAYS`, default `4`. Caps how far back the window extends if the last successful run was long ago (vacation, downtime, etc.).
- `SKIP_WEEKENDS`, default `true`
- `TIMEZONE`, default server local time
- `ARXIV_MIN_INTERVAL_SEC`, default `5`
- `SKIP_ONBOARDING`, default `false`. When `true`, missing interests produce the original error message and stop, without running the Onboarding subflow.

## Expected USER.md sections

```markdown
## Research interests
- [specific topic 1]
- [specific topic 2]
- [specific topic 3]

## Explicit non-interests
- [topic to exclude]
```

Prefer 3 to 5 specific interests.

## Tools required

- Read
- Write
- Bash or equivalent shell with `curl`

## Scope boundaries

This skill is for daily discovery and triage.

Use a dedicated paper-reading workflow for deep reads, a search-collector workflow for broader literature collection, and separate review workflows for peer-review preparation.
