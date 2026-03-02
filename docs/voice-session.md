# Voice Session (Realtime AI Conversation)

## Agent Startup Notes
- Always read `PLAN.md`, `docs/voice-session.md`, and `issues_solutions.md` at session start.
- Keep `docs/voice-session.md` updated with detailed voice-session plan/status/implementation notes.
- Keep `issues_solutions.md` updated each round with issues + solutions.
- Debug logs are saved in `~/Downloads` (files with the latest timestamp); request permission before reading outside the repo.

## Overview
The Voice Session mode provides a real-time, streaming audio conversation with an AI model (Doubao first, OpenAI later). Users start and end the session with a single button; all confirmations happen through voice.

Key goals:
- Real-time, low-latency audio streaming.
- Minimal UI (Start/End only).
- Model proposes item changes; user confirms via voice.
- Context includes recent items and can be expanded by voice request.
- Save only the AI summary as a new note item.

## End-to-End Flow
1) **Start session**
   - App opens a streaming session and sends context: items from the last 30 days (title/type/project/tags/due).

2) **Live conversation**
   - User speech streams to the model.
   - Model responds with audio; transcripts are shown for clarity.

3) **AI proposes changes**
   - Model verbally proposes create/update actions.
   - App waits for a voice confirmation phrase.

4) **Voice confirmation**
   - User says “confirm” → app applies changes.
   - User says “reject” or “change that” → app discards or asks the model to revise.

5) **History expansion**
   - User says “last 6 months” / “all history”, or the model requests more.
   - App loads older items and sends a context expansion mid-session.

6) **End session**
   - User taps End.
   - App saves AI summary as a new note item titled:
     “Discussion with Doubao YYYY-MM-DD HH:mm–HH:mm”.

7) **Natural Conversation Like Human Being**
   - Summarize like a human, talk like human, No "JSON, TYPE, blabla"
   - AI acts as an human assistant to help user record To Do's and Ideas
   - Don't repeatly ask the user to confirm. If AI hears a clearly command from the user, just say "Got it" and execute.

## Diff-Based Session End (Proposed New Flow)
To reduce mid-session parsing and avoid accidental inbox wipes, the Voice Session can shift to a diff-based apply at the end of the conversation.

### Step-by-Step
1) **Session start**
   - App sends the model the current Inbox items (Tasks + Ideas, optionally Notes) with ids and key fields.
   - Model uses this context to spot duplicates during the conversation, but does not apply changes yet.

2) **Live conversation (no writes)**
   - The assistant chats naturally and may ask clarifying questions.
   - No data writes occur during the live session.
   - No `PROPOSAL_JSON` is required during the conversation.

3) **Session end → Diff generation**
   - App sends the full transcript + existing items back to the model.
   - Model returns a diff JSON describing proposed changes.

4) **User review UI**
   - App shows a "Proposed Changes" screen with checkboxes.
   - User approves or rejects each diff item (Create/Update/Merge/Delete).

5) **Apply selected changes**
   - Only approved diffs are applied to the Inbox.

### Diff JSON Schema (Example)
```
{
  "creates": [
    {
      "tempId": "new-1",
      "type": "task|idea|note",
      "title": "…",
      "details": "…",
      "dueDate": "YYYY-MM-DD or null",
      "priority": "low|normal|high",
      "project": "… or null",
      "tags": ["…"]
    }
  ],
  "updates": [
    {
      "id": "existing-item-id",
      "changes": {
        "title": "…",
        "details": "…",
        "dueDate": "YYYY-MM-DD or null",
        "priority": "low|normal|high",
        "project": "… or null",
        "tags": ["…"]
      }
    }
  ],
  "merges": [
    {
      "sourceTempId": "new-2",
      "targetId": "existing-item-id",
      "mergeSummary": "Reason / explanation"
    }
  ],
  "deletes": [
    {
      "id": "existing-item-id",
      "reason": "Duplicate / obsolete / user said remove"
    }
  ]
}
```

### UI Notes
- Default to showing Tasks + Ideas first; Notes optional.
- Deletes can be hidden or off by default for safety.
- Each row shows a short diff preview and a checkbox (approve/reject).

## State Machine (Session)
```
Idle → Connecting → Streaming → Ending → Idle
  ↘ (error) → Idle
```

## Sequence Sketch
```
User taps Start
  → App opens realtime session
  → App sends context.initial (last 30 days)
  → Provider sends session.started

Streaming loop:
  User speech → command.user (audio)
  Provider → audio.assistant + transcript.assistant
  Provider → proposal.pending + proposal.summary
  User says “confirm” → command.confirm → apply changes

User asks for more history (“last 6 months”)
  → App sends context.expand (older items)

User taps End
  → Provider sends session.ended
  → App saves summary note
```

## Context Payload (Example)
```
Context: Items (last 30 days)
- [task] Finish onboarding doc (project: Ops, tags: onboarding, due: 2026-02-03)
- [idea] Improve capture flow (project: Butler, tags: ux, due: none)
- [note] Meeting notes w/ Alex (project: Partnerships, tags: followup, due: none)
```

## Voice Confirmation Phrases
- Confirm: “confirm”, “apply”, “yes, apply”
- Reject: “reject”, “discard”, “no, don’t”
- Modify: “change that”, “update it”
- Expand history: “last 3 months”, “last 6 months”, “last year”, “all history”

## Event Schema (Provider → App)
- `session.started`
- `session.ended`
- `transcript.user`
- `transcript.assistant`
- `audio.assistant`
- `proposal.pending`
- `proposal.summary`
- `context.request`

## Event Schema (App → Provider)
- `context.initial`
- `context.expand`
- `command.confirm`
- `command.reject`
- `command.user`

## Provider Design (Pluggable)
- Introduce a `RealtimeSessionProvider` interface shared by providers.
- Implement `DoubaoRealtimeProvider` first.
- Add `OpenAIRealtimeProvider` later without changing the UI.

## Proposal Payload (Inline JSON)
When the assistant proposes changes, it might include a JSON object prefixed by `PROPOSAL_JSON:` to the backend so the app can easily parse and apply updates after voice confirmation. But remember this PROPOSAL_JSON should never be heard by the user as it's not natural human conversation. The Assistant should always talk like a human being.

Example:
```
I will create a task and update the meeting note. 
Flight from SFO to PVG on Saturday 1pm.
Say "confirm" to apply.
On the backgournd, it might send PROPOSAL_JSON: {"action":"create","type":"task","title":"Draft recap","details":"Write a weekly recap","priority":"normal","dueDate":null,"project":"Ops","tags":["weekly"]} to the backend.
```

## Record issues and solutions every round in issues-solutions.md

## Current Issues & Forward Plan (2026-02-25)

### Pain Points Observed
- **Duplicate call-outs are inconsistent.** The assistant sometimes only flags duplicates after the user explicitly asks.
- **End-of-session diff generation times out.** Diff requests can fail even with moderate transcript sizes.
- **No mid-session writes.** Items are not saved until the diff review is generated and approved, so any diff failure blocks updates.

### Root Causes (Hypotheses)
- **Prompt compliance drift.** The model may ignore duplicate rules unless the user explicitly asks during the conversation.
- **Provider latency.** Diff generation is a single large LLM call and appears to hit timeouts.

### Current Mitigations (Already Implemented)
- **Diff-based session end.** Conversation stays natural; only apply changes after a review screen.
- **Retry button.** Users can re-run diff generation without repeating the whole session.
- **Diff normalization.** If the model includes a create + merge for the same tempId, the create is removed.
- **Voice-diff logs.** `voice-diff-*.json` and `voice-diff-error-*.json` capture diff results and failures.
- **Task/idea snapshots.** `voice-items-before-diff-*.json` and `voice-items-after-diff-*.json` show pre/post state.

### Proposed Next Steps
1) **Improve duplicate call-out reliability**
   - Option A: Inject a hidden internal instruction (e.g., `INTERNAL_RULE`) right after context so the model sees a fresh reminder without speaking it.
   - Option B: Add a short assistant pre-amble at session start (“I’ll flag duplicates as we go”).

2) **Reduce diff timeouts**
   - Trim transcript window (last N lines) and limit context to tasks/ideas only.
   - Add hard timeout + auto-retry once with smaller payload.

3) **Operational fallback**
   - If diff fails repeatedly, allow a manual “Generate Proposed Diff” action using cached transcript + inbox snapshot.

### RAG-Style Duplicate Handling (Planned)
The goal is to improve duplicate detection without changing the existing diff-at-end workflow. Retrieval only informs conversation; all writes still happen through end-of-session diff review.

#### Core Flow
1) **Local embeddings + local search**
   - Build a local vector index for Tasks/Ideas using on-device embeddings.
   - Keep candidate count small (top 5 or fewer) for high recall without overwhelming the model.
2) **Retrieval step per utterance**
   - When the user speaks, embed the utterance and search for similar items.
   - Build a compact candidate digest (id, type, title, short details, project/tags, recency, score).
3) **LLM decision during conversation**
   - Send the utterance + candidate digest to the model for duplicate vs new judgment.
   - The assistant can ask “merge or new?” when likely duplicates appear.
4) **Diff-at-end stays unchanged**
   - No mid-session writes; final updates still happen via the proposed diff review screen.

#### Metrics + Continuous Log
- Append per session to `Documents/MyButlerLogs/voice-embedding-metrics-*.jsonl`.
- Each entry includes: timestamp, embedding model version, utterance, top-K candidates with scores, and user decision (merge/new/skip).
- Track derived metrics: Hit@K, false positives, coverage.
- Start a new log file when the embedding model changes to keep metrics comparable.

#### Current Implementation (Local Embeddings)
- **Local vector index:** On-device `NLEmbedding` vectors for Tasks/Ideas, stored in `item-embeddings.json`.
- **Live duplicate prompts:** Each user utterance triggers top-K similarity search; candidate digest is sent to the model to decide duplicate vs new.
- **Metrics logging:** Append JSONL entries to `voice-embedding-metrics-*.jsonl` with model version, utterance, candidate list, and merge/new/skip decision.
- **Settings controls:** Toggle to enable embedding duplicate prompts and slider for minimum similarity score.

### Open Questions
- Should the assistant always flag duplicates proactively, even if the user didn’t ask about duplicates in this session?
- Which model should be the default for diff generation (Doubao vs OpenAI) based on latency?

## Session Notes (2026-02-26)
- Fixed diff review/apply by keeping merge source creates (no longer stripped) and hiding merged creates from the Create section by default.
- Added readable embedding metrics log (`voice-embedding-metrics-readable-*.txt`) and included embedding metrics logs in shared artifacts.
- Added an INTERNAL_RULE line to the duplicate-candidate prompt to force duplicate call-outs when candidates are similar.

## Session Notes (2026-02-27)
- Fixed diff normalization to delete existing duplicates when the user confirms a merge, so only the merged target remains.
- Updated merge apply logic to always carry over the merged item's due date (e.g., “next Wednesday” overrides older dates).
- Debounced duplicate prompts to run on final ASR (or short silence) to avoid chunk-based embedding noise.
- Defaulted diff review delete selections on to prevent lingering duplicates after merge.
- Noted that embedding metrics logs only appear when a duplicate prompt is triggered (no prompt = no log entry).

## Session Notes (2026-02-28)
- Fixed delete requests being dropped in diff generation by appending transcript deletion hints into the diff-summary payload.
- Suppressed assistant audio/text before the first user transcript to avoid context-ack openings like “Got it…”.
- Trigger the greeting via the model (“Hi, what can I do for you?”), allow a short pre-user grace window, and delay sending context until the user speaks.
- Clear the transcript after a successful diff review is prepared.
- Send context immediately after the greeting with a “Context only” guard, while suppressing pre-user responses.
- Allow only greeting-matching assistant chunks before the first user transcript; suppress any extra pre-user text.
- Removed Mock Up Voice Session tooling and related UI/debug flows.
- Added a fallback token-overlap similarity check when embeddings miss duplicates.

## Session Notes (2026-03-01)
- Moved “Share Latest Logs” into Settings under Voice Session debug actions.
- Removed Force iCloud Sync / Show Logs Folder buttons from Settings.
- Fixed first-time blank share sheet by presenting with an item-backed payload.

## Session Notes (2026-03-02)
- Added date-time due date support in prompts and UI, plus a local `NSDataDetector` fallback for relative dates.
- Relative phrases like “next Monday 12pm” still not reliably captured in structuring results.
