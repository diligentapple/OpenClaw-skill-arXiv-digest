---
name: arxiv-morning-digest-setup
description: One-time provisioning for the arxiv-morning-digest skill. Verifies install integrity, walks the user through profile onboarding, optionally enables the daily HEARTBEAT schedule, and prints a configuration summary. Trigger after install with phrases like "run arxiv digest setup", "set up arxiv digest", or "configure arxiv digest". Safe to re-run — every step is idempotent.
---

# ArXiv Morning Digest — Setup

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

Conversational. Keep prompts short. Do not ask all questions at once.

**1. Greet and confirm.** Open with one sentence:

*"I'll set up your arXiv digest now — takes about a minute. Ready?"*

If the user declines, respond *"No problem, just say 'set up arxiv digest' when you're ready."* and stop.

**2. Identity (only if missing from USER.md).** If `USER.md` does not exist, or exists but has no `## Identity` section with at least a name, ask:

*"What should I call you, and what's your timezone? (e.g. 'Patrick, Asia/Tokyo')"*

If `USER.md` already has identity info, skip this question — don't make returning users re-answer.

**3. Primary channel (only if missing).** If `USER.md` does not specify a primary channel, ask:

*"Where should I deliver digests — WhatsApp, Telegram, Slack, or email?"*

**4. Free-form research description.** Ask:

*"What do you work on? A couple of sentences in your own words is enough — I'll help shape it into specific interests."*

**5. Propose specific interest phrasings.** From the user's free-form answer, draft 3 to 5 specific interests. Each should be:
- Specific enough to rank against (not "machine learning" or "AI").
- Phrased in the user's own framing where possible.
- Covering the major areas they mentioned, without inventing topics they didn't.

Show as a numbered draft:

```
1. Mechanistic interpretability of transformer attention heads
2. Retrieval-augmented generation with long-context models
3. Parameter-efficient fine-tuning, especially LoRA and adapters
```

**6. Iterate.** Ask: *"Does this look right? You can add, remove, or rephrase any of them. Also tell me anything you specifically want excluded — for example 'no pure theory papers'."*

Loop until the user confirms.

**7. Suggest arXiv categories.** Map confirmed interests to arXiv category codes:

- LLM, NLP, language topics → `cs.CL`, `cs.AI`
- General ML methods, optimization, training → `cs.LG`, `stat.ML`
- Vision-language, multimodal → `cs.CV`, `cs.CL`
- Robotics, agents in physical environments → `cs.RO`, `cs.AI`
- Security, privacy → `cs.CR`, `cs.LG`
- Default if unsure: `cs.LG`, `cs.CL`

Show the proposed categories with one-line explanations. Faculty unfamiliar with arXiv codes need to confirm, not defend.

**8. Show the diff.** Display exactly what will be written or changed in `USER.md`. Use the project's `USER.md.template` structure if `USER.md` does not yet exist; otherwise show only the new/changed sections.

**9. Confirm.** Ask: *"Save this to your profile?"* Do not write without an explicit yes.

**10. Write.** Use the Write tool to update `USER.md`:
- If the file does not exist, create it from `USER.md.template` and fill in collected values.
- If it exists, append or replace only the relevant sections (`## Identity`, `## Communication preferences`, `## Research interests`, `## Explicit non-interests`). Preserve everything else, including unrelated sections like `## Context`.
- Never overwrite `USER.md` wholesale.

## Schedule

Ask whether the user wants daily autonomous delivery.

**1. Detect HEARTBEAT state.** Read `<workspace>/HEARTBEAT.md` if present and look for an `arxiv-morning-digest` task. Three cases:

- **Task present and not `[DISABLED]`** → say *"HEARTBEAT is already set up — runs at [Schedule] [Timezone]. Change it?"* and offer y/n. If yes, branch to step 2. If no, skip to Setup Summary.
- **Task present but `[DISABLED]`** → say *"HEARTBEAT exists but is disabled. Enable it?"* If yes, remove the `[DISABLED]` prefix (with confirmation). Otherwise continue.
- **Task missing or HEARTBEAT.md absent** → ask: *"Want me to deliver a digest automatically each weekday morning, or only when you ask for it?"*

**2. Configure the schedule.** Default offer:

*"I'll schedule it for 7:00 AM your local time, Monday through Friday. Sound good, or pick a different time?"*

Accept overrides like "8 AM", "6:30 AM weekdays", "every day including weekends". Convert to standard cron format. If the user wants weekends included, also flip `SKIP_WEEKENDS` in the skill-specific settings (and mention this).

**3. Show the diff for HEARTBEAT.md.** Display the task block that will be added or modified:

```
## arxiv-morning-digest

- **Schedule**: 0 7 * * 1-5
- **Timezone**: Asia/Tokyo
- **Skill**: arxiv-morning-digest
- **Description**: Runs the personalized arXiv digest each weekday morning.
- **On failure**: Retry once after 15 minutes; then stay silent.
```

**4. Confirm and write.** Ask: *"Save this schedule?"* On yes, write or update `HEARTBEAT.md`. Preserve any unrelated tasks already in the file. Never overwrite wholesale.

**5. Note about Gateway restart.** After writing HEARTBEAT.md for the first time, mention:

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
