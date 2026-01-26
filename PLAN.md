# Plan

## Current Milestone
M3 — Voice capture → transcript (no AI)

## Definition of Done
- Text input → saves to Inbox
- Item detail screen
- Simple search

## Next Milestone
M4 — Inbox triage (basic metadata)

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

## Decisions
- Data model: single `Item` with type (task/idea/note)
- Storage: start with JSON file or SwiftData; keep swap-friendly
- UI: SwiftUI with modular folders (Models/Views/ViewModels/Services)

## Next Time Start Here
- Implement M3 voice capture flow with transcript
- Decide on audio storage and transcription service
- Update docs/decisions.md with voice capture plan
