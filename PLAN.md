# Plan

## Agent Startup Notes
- Always read `PLAN.md`, `docs/voice-session.md`, and `issues_solutions.md` at session start.
- Keep `PLAN.md` updated with top-level plan/status and non-voice-session milestones.
- Keep `docs/voice-session.md` updated with detailed voice-session plan/status/implementation notes.
- Keep `issues_solutions.md` updated each round with issues + solutions.
    - Debug logs are saved in `~/Downloads` (files with the latest timestamp); user consents to reading those logs when requested, but tool approval may still be required by the sandbox.

## Guiding Principles (Stage 1)
- Voice-first but always show text + structured output after each capture.
- Start with one killer loop: Capture → Structure → Save → Retrieve.
- Keep the app UI tiny early; invest in the data model + pipeline.
- Design so Stage 2 execution can plug in later (actions as future hooks).

## Minimal Architecture That Scales
On-device (iOS app)
- Recording UI ("Run Session" later)
- Transcript viewer
- Saved items list + search
- Local storage (JSON now; SwiftData/CoreData later)

Backend (optional early, recommended)
- Speech-to-text (if not on-device)
- LLM calls for structuring + chat
- User auth (later)
- Sync / backups (later)
- Rationale: iterate prompts + logic without App Store review delays

## Data Model (Future-Proof)
One unified object with a type:
- Item
    - id, createdAt, source (voice/text/screenshot)
    - rawText (verbatim)
    - type = task | idea | note
    - title
    - details
    - dueDate (optional)
    - priority (optional)
    - project (optional)
    - tags[]
    - people[]
    - status (inbox/today/done)
    - links[] (future)

## Milestones (Each One Works)
### M0 — Dev setup + Hello World ✅
- App runs on iPhone from Xcode
- GitHub repo connected; can commit/push

### M1 — Inbox list with local storage ✅
- Tab layout (Inbox / Today / Search)
- Inbox list displays saved items
- Add flow creates a text item
- Items persist locally (JSON)

### M2 — Text capture + item detail + search ✅
- Text input saves to Inbox
- Item detail screen
- Simple search

### M3 — Voice capture → transcript ✅
- Voice capture UI with permissions
- Live transcript preview
- Save transcript to Inbox

### M4 — Inbox metadata (triage) ✅
- Data model extended with `priority`, `dueDate`, `tags`
- Metadata editable in Item Detail
- Metadata visible in Inbox + Search rows
- Sorting by priority or due date
- Metadata inputs in Add flow

### M5 — AI auto-structure (the “wow” moment) ✅
- After transcript/text, call ChatGPT to return structured JSON
    - type/task/idea
    - title
    - due date guess
    - project/tags
- Show “Proposed structure” → user can edit → Save
- Focus: capture → structure → save → retrieve loop

### M6 — Today + Projects views (lightweight) ✅
- Today = due today/overdue/high priority
- Projects grouping (from `project` metadata)

### M7 — Natural language query over items ✅
- Ask: “What were my ideas about X?”
- Keyword search first + optional LLM summarization
- Voice-first query tab with transcript + AI summary + playback

### M8 — Weekly digest (manual trigger) ✅
- “Weekly brief” screen: top 3, waiting on, stale items

### M9 — Voice Session (Realtime AI Conversation) ✅
- Realtime streaming audio conversation with Doubao (start/end only, no extra UI taps).
- Pluggable provider interface (Doubao now, OpenAI later) with session manager.
- Context sent on session start + voice-driven history expansion (“last 6 months”, “all history”).
- Voice confirmations for create/update actions (“confirm”, “reject”).
- Session-end summary saved as a note item ("Discussion with Doubao YYYY-MM-DD HH:mm–HH:mm").
- Audio routing stabilized (speaker/Bluetooth) with voice processing + echo suppression.
- Transcript improvements: merged assistant chunks, optional local speech toggle, Doubao ASR websocket, source picker.
- Debug meters and packet stats available behind Debug-only toggle.
- Transcript boxes now scroll and auto-scroll to latest line.
- See `docs/voice-session.md` for the full flow + event schema.

### M10 — Voice Session polish + workflow
- Add wrap-up voice command to summarize the session into Tasks/Ideas/Notes saved to Inbox.
  - Accept natural phrasing ("wrap it up", "summarize our discussion", etc.) instead of exact keywords.
  - Tasks default to `task` type with `Normal` priority and empty due date unless explicitly provided.
- Verify Doubao ASR transcript in-device sessions.
- Trim debug UI for production polish.

## Current Milestone
M10 — Voice session polish + workflow (diff-at-end review)

## Definition of Done (M5)
- Transcript/text sends prompt to structuring service
- Structured JSON preview rendered in UI
- User edits proposed structure before saving
- Saved items retain both raw text and structured metadata

## Decisions
- Data model: single `Item` with type (task/idea/note)
- Storage: JSON now; keep swap-friendly for SwiftData later
- UI: SwiftUI with modular folders (Models/Views/ViewModels/Services)

## Session Notes (2026-01-27)
- M5 flow implemented with mock + OpenAI/Doubao providers.
- OpenAI works after API key + model set in Settings.
- Doubao still failing: ATS overrides added, but device reports TLS/DNS errors.
- Need confirmed Doubao base URL/hostname for the account/region.

## Session Notes (2026-01-28)
- Doubao endpoint updated to `https://ark.cn-beijing.volces.com/api/v3/chat/completions`.
- Doubao request switched to `messages` payload and correct JSON parsing.
- Verified models `doubao-seed-1-6-lite-251015` and `doubao-seed-1-8-251228` work in-app.
- M5 flow verified end-to-end (text + voice capture).

## Session Notes (2026-01-29)
- M6 implemented: Today view (overdue/due today/high priority), Projects grouping tab.
- Added `project` metadata across model + AI structuring + capture/edit flows.
- Item detail is fully editable (title/type/details/raw text/metadata).
- Deletion: swipe-to-delete in lists + detail delete + multi-level undo history (10 items).
- Undo history accessible from Settings with restore + metadata.

## Session Notes (2026-01-30)
- M7 completed: Voice tab with transcript-based queries, keyword match list, AI summary.
- Added streaming-style summary display and voice playback controls.
- Playback uses `AVAudioSession` configuration to avoid OSStatus errors.

## Session Notes (2026-01-31)
- M8 completed: Weekly digest view with top/waiting/stale sections.
- Added weekly local reminder with selectable day/time and settings toggle.
- Inbox now supports type filter (All/Tasks/Ideas/Notes) for cleaner triage.

## Session Notes (2026-02-01)
- M9 in progress: realtime voice session wiring (Doubao client/protocol, audio capture/playback, context send, voice confirmation scaffolding).
- Session starts and audio playback works; still missing stable ASR transcript + voice response loop.
- Added debug logging for realtime payloads and transcript printing (Xcode Debug Area).

## Session Notes (2026-02-02)
- Realtime voice session stable: speaker + Bluetooth routing works; audio output and input confirmed.
- Assistant transcript cleaned up (merged chunks, no duplicates).
- Provider does not emit user ASR text in audio mode; added optional local speech transcript toggle in Settings (off by default).
- Added Voice Session debug meters (mic/output levels, packet stats) behind Debug-only toggle.

## Session Notes (2026-02-09)
- Added speaker routing toggle and improved audio session mode + voice processing (echo suppression).
- Added Doubao ASR websocket stream for user transcript when local speech is off.
- Parsed additional realtime payload fields to surface user ASR (extra.origin_text/results.text).
- Added transcript source picker (Doubao vs Local) with Doubao default.
- Tightened voice command matching to avoid accidental proposal discard.
- Ignored occasional invalid realtime frames to prevent session error popups.

## Session Notes (2026-02-10)
- Transcript boxes now scroll and auto-scroll to the latest line in Voice Session and Voice Capture.

## Session Notes (2026-02-12)
- M10 wrap-up flow implemented: voice command triggers spoken summary + JSON item extraction for Inbox.
- Added summary buffering/debounce, JSON parsing normalization, and task/idea/note save pipeline.
- Added debug logging toggle + in-app log viewer; logs saved to `MyButlerLogs` (iCloud if enabled, otherwise app Documents).
- Summary still too short and JSON/metadata is occasionally spoken; needs more natural spoken summary and stricter TTS suppression.

## Session Notes (2026-02-18)
- Fixed wrap-up JSON/TTS leakage by muting playback during summary items, waiting for audio silence, and tightening summary-item prompt context.
- Added file sharing via explicit Info.plist so Finder can access `Documents/MyButlerLogs`.
- Auto-export logs (voice-session + debug info) to Documents on session end; added auto-share sheet for one-tap AirDrop.
- Added debug log tooling in Settings (show folder, debug info file, share link) and cleaned up Settings view to compile reliably.

## Session Notes (2026-03-01)
- Moved “Share Latest Logs” into Settings, removed extra debug buttons (Force iCloud Sync / Show Logs Folder), and fixed first-time blank share sheet.
- Removed Inbox “All” filter to leave To Do / Ideas / Notes only.
- Added JSON inbox export/import with merge/replace/skip modes via Settings → Inbox Backup.

## Current Issues & Forward Plan (M10)

### Pain Points Observed
- Duplicate call-outs are inconsistent.
- End-of-session diff generation can time out.
- No mid-session writes; diff failure blocks updates.

### Current Mitigations (Already Implemented)
- Diff-based session end with review UI.
- Retry button for diff generation; cached transcript/items for retry.
- Diff normalization to remove create entries referenced by merges.
- Voice diff logs and task/idea snapshots before/after diff apply.

### Proposed Next Steps
1) Improve duplicate call-out reliability
   - Option A: Inject a hidden internal reminder after context.
   - Option B: Add a short assistant preamble (“I’ll flag duplicates as we go”).

2) Reduce diff timeouts
   - Trim transcript window and limit context to tasks/ideas only.
   - Add hard timeout + auto-retry once with smaller payload.

3) Operational fallback
   - Keep “Generate Proposed Diff” available using cached transcript + inbox snapshot.

### RAG-Style Duplicate Handling (Planned)
- Local embeddings + local search for tasks/ideas.
- Per-utterance retrieval; send a compact candidate digest to the model.
- Log embedding metrics to `voice-embedding-metrics-*.jsonl` per session.

## Next Time Start Here
- Focus M10 voice session reliability work.
- Verify Doubao ASR transcript in device sessions.

## Project Logs
- Voice session tracking (voice-session-only details): `docs/voice-session.md`
- Issues and fixes: `issues_solutions.md`
