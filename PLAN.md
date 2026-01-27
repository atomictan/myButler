# Plan

## Current Milestone
M4 — Inbox triage (basic metadata)

## Definition of Done
- Add basic metadata fields (priority, due date, tags)
- Edit metadata from item detail
- Show metadata in Inbox list rows
- Filter or sort Inbox by priority/due date

## Next Milestone
M5 — Today view (filter by due date)

## Completed Milestones
### M1 — Inbox list with local storage (MVP shell)
- [x] Basic tab layout (Inbox / Today / Search)
- [x] Inbox list displays saved items
- [x] Add flow creates a text item
- [x] Items persist locally (simple JSON or SwiftData)

### M2 — Text capture + item detail + search
- [x] Text input → saves to Inbox
- [x] Item detail screen
- [x] Simple search

### M3 — Voice capture → transcript (no AI)
- [x] Voice capture UI with permissions
- [x] Live transcript preview
- [x] Save transcript to Inbox

## Decisions
- Data model: single `Item` with type (task/idea/note)
- Storage: start with JSON file or SwiftData; keep swap-friendly
- UI: SwiftUI with modular folders (Models/Views/ViewModels/Services)

## Next Time Start Here
- Extend `Item` with priority, due date, tags
- Add metadata editors in item detail
- Surface metadata in Inbox + sorting
