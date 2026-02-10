# Plan

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

### M9 — Voice Session (Realtime AI Conversation)
- Realtime streaming audio conversation with Doubao (start/end only, no extra UI taps).
- Make model pluggable (support Doubao now, OpenAI later) via shared session provider interface.
- On session start, send last 30 days of item context (title/type/project/tags/due).
- Allow user to expand history via voice (“last 6 months”, “all history”); app refreshes context mid-session.
- AI proposes create/update actions verbally; user confirms via voice (“confirm”, “reject”).
- No automatic summaries; user prompts AI when needed.
- On session end, save AI summary as a new note item titled “Discussion with Doubao YYYY-MM-DD HH:mm–HH:mm”.
- Use voice-only confirmations for applying changes; minimal on-screen indicators allowed.
- See `docs/voice-session.md` for the full flow + event schema.

#### M9 Implementation Phases
- Confirm provider API details (realtime streaming endpoints + event schema).
- Add realtime session abstractions (provider protocol + session manager).
- Build voice session UI (Start/End, transcripts, session status).
- Wire context + voice confirmation flow (history expansion + apply changes).
- Persist summary note on session end.

## Current Milestone
M9 — Workout session mode polish (voice transcript + audio routing improvements in progress)

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
- Verified model `doubao-seed-1-6-lite-251015` works in-app.
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

## Next Steps (M9)
- ASR approach chosen: separate Doubao realtime ASR alongside local speech toggle.
- Implement Doubao ASR stream (voice-api websocket) + transcript merge.
- Trim debug UI for production polish.

## Next Time Start Here
- Start M9 workout session mode polish.
- Add continuous capture session + “Next item” voice command.
- Verify Doubao ASR transcript in-device sessions.
