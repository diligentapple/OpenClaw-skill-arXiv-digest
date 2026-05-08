---
name: arxiv-morning-digest-setup
description: One-time provisioning for the arxiv-morning-digest skill. Verifies install integrity, walks the user through profile onboarding, optionally enables the daily HEARTBEAT schedule, and prints a configuration summary. Trigger after install with phrases like "run arxiv digest setup", "set up arxiv digest", or "configure arxiv digest". Safe to re-run — every step is idempotent.
---

# ArXiv Morning Digest — Setup

> **First-time setup required.** Read this file directly after installing the skill. Follow the instructions here before reading other instruction files.

This document is the install-time companion to `SKILL.md`. Run it once after installing the skill. It is conversational, asks for explicit confirmation before writing files, and is safe to re-run.

The skill itself (`SKILL.md`) handles the daily workflow. This file handles provisioning.

## When to run

- Immediately after installing the skill from a GitHub repo or ClawHub.
- Whenever the user says "run arxiv digest setup", "set up arxiv digest", "configure arxiv digest", or "reconfigure my interests".
- Triggered automatically by `SKILL.md` Step 1 if a user runs `/digest` before setup has been completed.

## Pre-flight checks

Before any conversation with the user, silently verify the workspace is sane. Each check is **report and continue**, not abort — fix what is trivially fixable, ask the user about anything else.

**1. Verify SKILL.md is in place.** Confirm `<workspace>/skills/arxiv-morning-digest/SKILL.md` exists and contains valid YAML frontmatter with `name: arxiv-morning-digest`. If missing or malformed, respond:

*"I can't find a valid SKILL.md for arxiv-morning-digest in your workspace. Please reinstall the skill, then re-run setup."*

Then stop.

**2. Ensure the memory directory exists.** Check for `<workspace>/memory/`. If missing, create it. The skill writes Daily Logs there.

**3. Detect prior setup.** Look for these markers:
- `USER.md` exists with a non-empty `## Research interests` section
- `HEARTBEAT.md` exists with an `arxiv-morning-digest` task

If both are present, this is a **re-run**. Open with:

*"Looks like setup has already run — interests configured, HEARTBEAT installed. Want to reconfigure interests, change the schedule, or just see the current setup summary?"*

Branch on the user's reply. "Reconfigure interests" jumps to step 1 of Onboarding. "Change schedule" jumps to the HEARTBEAT section. "Show summary" jumps directly to the Setup Summary section. Anything else: ask which they meant.

If only one marker is present, mention what's already in place and continue with the missing pieces.

If neither is present, this is a **fresh install** — proceed to Onboarding.

## Onboarding

**Begin immediately when triggered — no "ready to begin?" preamble.** The user just asked for setup; do not ask again whether they want it. Open straight into Q1 below.

**Auto-detect the primary channel.** Before asking anything, identify the channel where this setup was triggered (Telegram, Slack, WhatsApp, email, web chat, etc.) from the harness/runtime context. Use that as the default primary channel — never ask "where should I deliver digests" if the user is obviously sitting in Telegram. If the channel cannot be inferred (e.g. setup triggered locally with no clear source), fall back to asking explicitly during the confirmation loop below.

Then ask the user **three questions**, in this order:

**Q1 — Identity (combined).** Ask:

*"What should I call you, your timezone, and your role? (e.g. 'Patrick, Asia/Tokyo, postgraduate researcher')"*

If `USER.md` already has a populated `## Identity` section (re-run case), skip this question.

**Q2 — Research interests.** Ask:

*"What do you work on? A couple of sentences in your own words — I'll shape them into 3–5 specific interest topics."*

From the user's free-form answer, draft 3–5 specific interests. Each should be:
- Specific enough to rank against (not "machine learning" or "AI").
- Phrased in the user's own framing where possible.
- Covering the major areas they mentioned, without inventing topics they didn't.

**Q3 — Explicit non-interests.** Ask:

*"Anything you specifically want excluded? (e.g. 'no pure theory papers', 'no computer vision without language'). Type 'none' to skip."*

**Silent derivations** (no user prompt — these are computed and shown in the confirmation step below):

- **arXiv categories** from the interests, written to `## Skill-specific settings` as `ARXIV_CATEGORIES: <comma-separated codes>`. Mapping:
  - LLM, NLP, language topics → `cs.CL`, `cs.AI`
  - General ML methods, optimization, training → `cs.LG`, `stat.ML`
  - Vision-language, multimodal → `cs.CV`, `cs.CL`
  - Robotics, agents in physical environments → `cs.RO`, `cs.AI`
  - Security, privacy → `cs.CR`, `cs.LG`
  - Default if unsure → `cs.LG`, `cs.CL`
- **Primary channel** from the auto-detected source above.

**Show the filled USER.md and iterate to confirmation.** Display the complete USER.md content the agent intends to write — every section: `## Identity`, `## Communication preferences`, `## Research interests`, `## Explicit non-interests`, `## Skill-specific settings`.

**Lead the display with the proposed arXiv categories**, since they were silently derived and the user hasn't seen them yet. Format like this:

```
Proposed arXiv categories: cs.CL, cs.AI
(derived from your interests — say "use cs.CV" or similar to change)

—————————

[then the full filled USER.md below]
```

After the display, ask:

*"Here's your profile. Anything to change? Type 'looks good' to save, or describe what you'd like adjusted."*

If the user requests changes (e.g. "remove the third interest", "change role to PhD student", "use cs.CV instead", "deliver to Slack instead"), apply them and **re-display the full updated USER.md**. Loop until the user explicitly confirms. Never write before confirmation.

**Write.** Once confirmed, use the Write tool to create or update `USER.md`:
- If the file does not exist, create it from `USER.md.template` and fill in all collected values across the relevant sections.
- If it exists, update only the sections you wrote during this onboarding pass. Preserve everything else, including unrelated sections like `## Context`.
- Never overwrite `USER.md` wholesale.

## Q4 — Schedule

After USER.md is confirmed and written, propose the daily HEARTBEAT schedule.

**Detect existing HEARTBEAT state first.** Read `<workspace>/HEARTBEAT.md` if present and look for an `arxiv-morning-digest` task:

- **Task present and active** → ask *"HEARTBEAT is already set up — runs at [Schedule] [Timezone]. Change it?"* If no, skip to Setup Summary. If yes, propose the default below as the new value (user can override).
- **Task present but `[DISABLED]`** → ask *"HEARTBEAT exists but is disabled. Enable it with the default schedule (7am weekdays)?"* If yes, write the active task block. If no, skip.
- **No task or HEARTBEAT.md absent** → propose the default below.

**Q4 — Confirm the schedule.** Propose the default directly — do not ask "do you want autonomous delivery at all?", just propose and let the user opt out:

*"I'll deliver the digest at 7:00 AM your timezone (`<TIMEZONE from USER.md>`), Monday through Friday. You can always trigger an on-demand digest anytime by typing `/digest`, regardless of the schedule. Sound good? Type 'yes' to save, a different time (e.g. '6:30 AM' or '8 AM weekdays'), or 'manual only' to skip autonomous delivery."*

Parse the response:

- **"yes"** → use the default `0 7 * * 1-5` with the user's timezone.
- **Different time / day pattern** → convert to standard cron (e.g. "6:30 AM weekdays" → `30 6 * * 1-5`; "every day at 7" → `0 7 * * *`). If the user wants weekends, also flip `SKIP_WEEKENDS: false` in `## Skill-specific settings` of USER.md and mention: *"Updated USER.md to allow weekend runs."*
- **"manual only"** → skip writing HEARTBEAT.md; note the user will need to type `/digest` manually each day.

**Write HEARTBEAT.md.** On confirmation, write or update HEARTBEAT.md with this task block. Use the timezone collected in Q1 (do not hardcode):

```
## arxiv-morning-digest

- **Schedule**: <resolved cron>
- **Timezone**: <user's timezone from USER.md>
- **Skill**: arxiv-morning-digest
- **Description**: Runs the personalized arXiv digest each weekday morning and delivers it to the primary channel.
- **On failure**: Retry once after 15 minutes; if still failing, append the error to today's Daily Log and stay silent.
- **Delivery**: Posts asynchronously to the primary channel defined in USER.md. If a conversation is already active, the digest arrives as a separate message rather than interrupting the current exchange.
```

Preserve any unrelated tasks already in HEARTBEAT.md. Never overwrite wholesale.

**Note about Gateway restart.** After writing HEARTBEAT.md for the first time, mention:

*"HEARTBEAT changes take effect on Gateway restart. Run `openclaw gateway restart` when you're ready."*

Do not restart the Gateway from inside the skill.

## Setup summary

Print a single recap so the user sees exactly what was configured. Use this structure:

```
✅ Setup complete. Here's how the digest will behave:

📋 Profile  (in USER.md)
   Name: [Name]
   Channel: [primary channel]
   Interests: [N] topics
     • [interest 1]
     • [interest 2]
     ...
   Non-interests: [M] exclusions   (or "none set")

🔍 Search
   Categories: [comma-separated arXiv codes]
   Papers per digest: [DIGEST_SIZE]
   Lookback cap: [MAX_LOOKBACK_DAYS] days
   Skip weekends: [yes/no]

⏰ Schedule  (in HEARTBEAT.md)
   [resolved schedule line OR "manual trigger only — type /digest to run"]

📂 Files touched
   USER.md           [created / updated]
   HEARTBEAT.md      [created / updated / unchanged / not present]
   memory/           [exists]

To change anything later:
  • Interests / non-interests → edit USER.md or say "reconfigure my interests"
  • Schedule → edit HEARTBEAT.md or say "change my digest schedule"
  • Defaults (size, lookback, etc.) → edit the "Skill-specific settings"
    section in USER.md

Want me to run the first digest now? (yes / no)
```

The "Skill-specific settings" reference assumes the project's `USER.md.template` convention. If the user opted for non-default values during onboarding (e.g., `DIGEST_SIZE: 5`), include that section in the diff at write time.

## First digest

If the user says yes to "run the first digest now," hand off to `SKILL.md` Step 2. The skill will read the `USER.md` you just wrote and produce the first digest using the normal workflow.

If the user says no, end with:

*"Setup is done. Trigger me anytime with `/digest`, or wait for the morning HEARTBEAT if you scheduled one."*

## Failure modes

- **User abandons setup midway.** If the user stops responding, do not write anything partial to `USER.md` or `HEARTBEAT.md`. The next setup invocation should pick up from a clean state.
- **`USER.md` exists but is malformed.** If the file exists but has structural problems (broken Markdown, missing required sections after a previous failed write), report what's wrong and offer to back it up to `USER.md.bak` before rewriting. Never silently overwrite a file the user might have edited by hand.
- **HEARTBEAT.md write conflict.** If `HEARTBEAT.md` contains other tasks that don't parse cleanly, do not modify the file — instead, print the proposed task block and ask the user to add it manually.
- **Workspace permissions.** If a Write call fails (permission denied, disk full), surface the actual error message — don't pretend success.

## What this file does NOT do

For clarity:

- Does not run the digest workflow itself — that's `SKILL.md`.
- Does not register the skill with OpenClaw — the install step (cloning the repo into `<workspace>/skills/`) does that.
- Does not configure unrelated skills — only `arxiv-morning-digest`.
- Does not modify environment variables or system configuration outside the workspace.
