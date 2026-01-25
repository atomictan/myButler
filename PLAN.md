# Plan

## Current Milestone
M2 — Text capture + item detail + search

## Definition of Done
- Text input → saves to Inbox
- Item detail screen
- Simple search

## Next Milestone
M3 — Voice capture → transcript (no AI)

## Completed Milestones
### M1 — Inbox list with local storage (MVP shell)
- [x] Basic tab layout (Inbox / Today / Search)
- [x] Inbox list displays saved items
- [x] Add flow creates a text item
- [x] Items persist locally (simple JSON or SwiftData)

## Decisions
- Data model: single `Item` with type (task/idea/note)
- Storage: start with JSON file or SwiftData; keep swap-friendly
- UI: SwiftUI with modular folders (Models/Views/ViewModels/Services)

## Next Time Start Here
- Implement M2 text capture flow and detail view
- Add basic search over title/details
- Confirm storage approach and update docs/decisions.md
