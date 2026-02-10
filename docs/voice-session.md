# Voice Session (Realtime AI Conversation)

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
When the assistant proposes changes, it should include a JSON object prefixed by `PROPOSAL_JSON:` in the same response so the app can parse and apply updates after voice confirmation.

Example:
```
I will create a task and update the meeting note. Say "confirm" to apply.
PROPOSAL_JSON: {"action":"create","type":"task","title":"Draft recap","details":"Write a weekly recap","priority":"normal","dueDate":null,"project":"Ops","tags":["weekly"]}
```
