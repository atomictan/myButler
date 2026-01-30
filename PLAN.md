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

### M6 — Today + Projects views (lightweight)
- Today = due today/overdue/high priority
- Projects grouping (from `project` metadata)

### M7 — Natural language query over items
- Ask: “What were my ideas about X?”
- Keyword search first + optional LLM summarization

### M8 — Daily/weekly digest (manual trigger)
- “Daily brief” screen: top 3, waiting on, stale items

### M9 — Workout session mode polish
- Continuous capture session with “Next item” voice command
- Low-chatter confirmations

## Current Milestone
M6 — Today + Projects views (lightweight)

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

## Next Time Start Here
- Start M6 Today view (due/overdue/high priority filters).
- Add Projects grouping using `project` metadata (data model update needed).
