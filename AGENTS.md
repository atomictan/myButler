# Agent Instructions

## Startup
- Always read `PLAN.md`, `docs/voice-session.md`, and `issues_solutions.md` at session start.
- Keep `PLAN.md` updated with top-level plan/status and non-voice-session milestones.
- Keep `docs/voice-session.md` updated with detailed voice-session plan/status/implementation notes (voice-session only).
- Keep `issues_solutions.md` updated each round with issues + solutions.

## Permissions
- Approved to run git commands (`status`, `diff`, `add`, `commit`, `push`) when requested to update the repo.
- Approved to edit files in the repo, add new files, and delete generated artifacts (swap files, build logs, temp files).
- Approved to read the latest debug logs in `~/Downloads` when requested (sandbox approvals may still apply).
- Approved to open Xcode and build/run the app when requested.

## Notes
- Sandbox/approval rules still apply even if permissions are listed here.
- AirDrop Debug logs land in `~/Downloads`; When try to analyze debug logs, use `scripts/import-airdrop-logs.sh` to copy all the debug logs into `logs/airdrop` first.
- After making a code fix for a reported build/compiler issue, always run a local build yourself before asking the user to run/verify it.
- When checking debug logs, pay attention to following things:
	- whether the diff proposal makes sense or not, including both title and due date/time,  with regard to the transcript
	- performance in app-performance.log make sense or not
	- whether duplicate/similar items have been called out by Assistant and also in the diff proposal
