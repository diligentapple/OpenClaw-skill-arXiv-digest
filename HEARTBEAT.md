> **First-time setup required.** If this workspace does not yet have a populated `USER.md` (with a `## Research interests` section), stop here, read `SETUP.md`, and complete the setup flow before this skill can run.

## arxiv-morning-digest

- **Schedule**: `0 7 * * 1-5`, 7:00 AM on the configured cron days
- **Timezone**: `Asia/Tokyo`
- **Skill**: `arxiv-morning-digest`
- **Description**: Runs the personalized arXiv digest on the configured cron and delivers it to the primary channel before the workday starts.
- **On failure**: Retry once after 15 minutes. If still failing, append the error to today's Daily Log and stay silent, do not spam the channel with repeated failure messages.
- **Delivery**: Posts asynchronously to the primary channel defined in USER.md. If a conversation is already active, the digest arrives as a separate message rather than interrupting the current exchange.

## Notes

- **Cron syntax**: standard 5-field, `minute hour day-of-month month day-of-week`.
- **Schedule days**: the cron expression controls only autonomous delivery timing. It is not fetch logic; on-demand `/digest` is not date-gated and always follows the normal workflow in `SKILL.md`.
- **Missed runs**: if the Gateway is offline at the scheduled time, the task is skipped rather than run retroactively. To manually pull a missed digest, use the chat trigger `/digest` or "morning digest".
- **Adding tasks**: each task needs at minimum a Schedule, a Skill, and a Description. Keep the heading as a short kebab-case identifier, it becomes the task's ID in logs.
