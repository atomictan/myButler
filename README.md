<p align="center">
  <img src="./myButler/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="110" alt="myButler app icon">
</p>

<h1 align="center">myButler</h1>

<p align="center">
  A voice-first capture assistant for iOS — talk to it, and it turns what you said into
  structured tasks, ideas, and notes you can actually find again.
</p>

---

## The idea

Capture tools fail at the moment of capture. By the time you have unlocked the phone, picked
a list, and typed a title, the thought is gone or mangled. myButler collapses that to one
button and a sentence.

The core loop is **Capture → Structure → Save → Retrieve**:

1. **Capture** — hold a button and talk, or run a full real-time conversation with the model.
2. **Structure** — an LLM turns raw speech into a typed `Item`: title, details, type
   (task / idea / note), due date, priority, project, tags, people.
3. **Save** — you review the proposed structure before anything is written. Nothing is
   silently committed on your behalf.
4. **Retrieve** — ask in natural language ("what did I say about the radar demo?") and get
   answers over your own items, matched semantically rather than by keyword.

## Features

**Voice Session** — a streaming real-time audio conversation. Start and stop with one
button; everything else happens by voice. At the end the model proposes a **diff** — items
to add, fields to change — and you approve or reject it. The diff-at-end design is
deliberate: a conversation shouldn't write to your inbox line by line while you're still
thinking out loud.

**Quick voice capture** — press, speak, release. For when you don't want a conversation.

**Typed entry** — the To Do / Ideas / Notes tabs save directly, with no AI in the path.
AI review is for voice, where the input is messy; typing is already structured.

**Natural-language query** — semantic search over your items via an on-device embedding
index, so retrieval works without shipping your notes anywhere.

**Weekly digest** — a periodic summary of what came in and what's still open.

**Undo history** — every AI-applied change is reviewable and reversible.

## Architecture

SwiftUI, iOS, Swift 6 concurrency (`MainActor`-isolated by default). Roughly 40 Swift files
across three layers:

| Layer | What's in it |
|---|---|
| `Models/` | `Item` (the one unified record type), `StructuredDraft`, `VoiceSessionDiff`, `InboxExport` |
| `Services/` | Realtime audio, LLM providers, structuring, embedding index, query, due-date parsing, logging |
| `Views/` | Inbox, Today, Projects, Search, Voice Session, diff review, undo history, settings |

Notable pieces:

- **`DoubaoRealtimeClient` / `DoubaoRealtimeProtocol`** — a hand-written client for the
  Doubao realtime streaming-audio protocol, including the binary framing and event model.
  OpenAI is supported as an alternative provider behind `RealtimeSessionProvider`.
- **`LocalEmbeddingIndex`** — on-device embeddings with Apple's `NaturalLanguage`
  framework, persisted with a model version so the index can be rebuilt when the model
  changes. Semantic retrieval without a server.
- **`VoiceSessionDiffService`** — builds the reviewable diff between what you said and what
  is already stored, including duplicate detection so the same task doesn't land twice.
- **`AppPerformanceLogger` / `VoiceSessionDebugLogger`** — on-device instrumentation with an
  export path, because most of the interesting failures only happen on a real phone in a
  real room.

## Setup

Requires Xcode and an iOS device or simulator.

```bash
git clone https://github.com/atomictan/myButler.git
open myButler.xcodeproj
```

API credentials are entered in the app's **Settings** screen and stored in `@AppStorage` —
they are not in source, and not in this repo:

- **Doubao** — App Key and Access Key, for the realtime voice session
- **OpenAI** — API key, if you use it as the structuring or session provider

## Status

Personal project, actively developed. Milestones M0–M9 are complete: inbox and local
storage, text and voice capture, AI structuring, Today and Projects views, natural-language
query, weekly digest, and the realtime voice session. **M10 — voice session polish and the
diff-at-end review workflow — is in progress.**

Not on the App Store; this is a build-for-myself project that happens to be public.

## Notes from the build

A representative bug, preserved because the shape of it was more interesting than the fix:
due dates spoken as *"april fifteenth"* were saving as **April 1**. Apple's date detector
doesn't parse `"april fifteenth"` at all — but the speech recognizer rendered it as
`"April 1 5 th"`, which the detector happily parsed as *April 1*. A partial match beat no
match, and the wrong date won silently. The fix normalizes spoken ordinals before date
detection ever runs.

Design and decision history: [`PLAN.md`](./PLAN.md),
[`docs/voice-session.md`](./docs/voice-session.md),
[`docs/decisions.md`](./docs/decisions.md), and
[`issues_solutions.md`](./issues_solutions.md).
