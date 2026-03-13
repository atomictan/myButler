# Voice Session (Realtime AI Conversation)

## Agent Startup Notes
- Always read `PLAN.md`, `docs/voice-session.md`, and `issues_solutions.md` at session start.
- Keep `docs/voice-session.md` updated with detailed voice-session plan/status/implementation notes.
- Keep `issues_solutions.md` updated each round with issues + solutions.
- Debug logs are saved in `~/Downloads` (files with the latest timestamp); request permission before reading outside the repo.

## Overview
The Voice Session mode provides a real-time, streaming audio conversation with an AI model (Doubao first, OpenAI later). Users start and end the session with a single button; all confirmations happen through voice.

## Status Notes (2026-03-08)
- Product direction update: typed entry from the explicit `To Do`, `Ideas`, and `Notes` tabs should save directly without pre-save AI review; Voice Session remains the main `Smart Add` path that uses structuring/proposal before save.
- Implemented the typed-entry split: `InboxView` now opens `AddItemView` with the currently selected inbox type, and typed saves no longer call `StructuringService`; Voice capture/session flows still use proposal-based AI review.
- Validation update: local no-signing `xcodebuild` succeeds after the typed-entry change, and user verification confirms typed items now save directly without the intermediate proposal screen.
- Rebuilt the app with `xcodebuild` and confirmed the active project warnings were in the Settings log-sharing flow, not the voice session runtime itself.
- The warning came from `Task.detached` calling `VoiceSessionDebugLogger.exportLogsForFileSharing(urls:)` while the project default actor isolation is `MainActor`.
- `exportLogsForFileSharing(urls:)` is now `nonisolated`, which keeps log export work off the main actor and removes the Swift 6 warning in both Settings screens.
- The remaining build log line about App Intents metadata is an Xcode tool message, not an app-source warning.
- Imported the newest AirDrop artifacts and inspected run `20260308-213520` for startup/share slowness and the wrong diff due date.
- The exported log set still does not contain `app-performance.log`; debug info lists only `voice-session-20260308-213520.log` among `.log`/`.txt` files, so device startup/share timing is currently missing from exported diagnostics.
- Code review explains the missing performance log: voice-session start calls `VoiceSessionDebugLogger.clearAllLogs()`, which deletes every file in the logs directory, including `app-performance.log`; later logger writes then fail silently because the file was removed.
- The wrong diff date is reproducible from the transcript itself: Apple date detection does not parse `april fifteenth`, but it does parse the assistant ASR text `April 1 5 th` as `April 1`, so transcript-based override currently locks in the wrong day.
- A second import after re-sharing logs produced only duplicate `* 2` copies of the same seven artifacts for session `20260308-213520`, confirming the current share flow still is not exporting any additional timing log.
- Implemented fixes: preserve `app-performance.log` during `clearAllLogs()`, recreate it automatically if a write occurs after deletion, move `ItemStore` disk load off the startup critical path, and make transcript due-date matching normalize spoken ordinals plus correction phrases.
- Validation: repo-local `xcodebuild` now succeeds with no app-source warnings; the only remaining warning is Xcode’s `AppIntents.framework` metadata skip message.
- Fresh device logs from session `20260308-215907` now include `app-performance.log`, confirming the export path fix worked.
- The latest transcript/diff pair shows the due-date fix working: user said `april sixteenth`, assistant ASR rendered `April 1 6 th`, and the diff saved `2026-04-16T00:00:00Z`.
- Performance log analysis still shows a slow startup window before first paint (`App init` → `ContentView first appear` about `5.6s`) even though `ItemStore load` now finishes later in the background (`+11.8s`), so more startup instrumentation is still needed outside store loading.
- The exported `app-performance.log` only contains `Share Latest Logs tapped`; because the file itself is copied as part of export, later `export completed` / `sheet presented` lines are not present in the shared snapshot even when the share flow succeeds.
- Duplicate/similar-item detection remains incomplete in this run: no spoken duplicate callout occurred, and the diff created a new Shanghai→San Francisco flight task instead of surfacing a merge/update option against existing related flight items.
- Follow-up implementation adds startup timing markers for `VoiceSessionView` / `VoiceSessionViewModel`, exports a dedicated post-export `app-performance-share-*.log` snapshot, and strengthens duplicate heuristics with route-aware matching plus diff-prompt similarity hints.
- Validation: repo-local `xcodebuild` still succeeds with no app-source warnings after these follow-up changes; only the Xcode `AppIntents.framework` metadata skip warning remains.
- Fresh device logs from session `20260308-221239` show the due-date/time fix holding up: the user said `april seventeenth one pm in the afternoon`, and the diff created `2026-04-17T05:00:00Z` (1pm local UTC+8).
- Duplicate handling is still not acceptable in this scenario: the inbox already had `Take flight from Shanghai to San Francisco` for `2026-04-16`, but neither the assistant nor the diff proposed a merge/update; a second near-duplicate task was created for `2026-04-17` instead.
- The dedicated performance snapshot still did not arrive in the imported repo logs because `scripts/import-airdrop-logs.sh` currently imports `app-performance.log` only, not `app-performance-share-*.log`.
- Follow-up fix: `scripts/import-airdrop-logs.sh` now imports `app-performance-share-*.log` as well.
- Follow-up fix: `VoiceSessionDiffService` now post-processes model diffs so a same-route task create (for example, Shanghai → San Francisco) within roughly two weeks of an existing matching task is normalized into an `update` candidate rather than a second duplicate `create`.
- Validation: repo-local `xcodebuild` still succeeds with no app-source warnings after these changes; only the Xcode `AppIntents.framework` metadata skip warning remains.
- Verified from `app-performance-share-20260308-221353.log` that share timing is now captured through `Share Latest Logs export completed`.
- Startup timing is clearer now: `ContentView first appear` is about `+5.985s`, `VoiceSessionViewModel init` about `+10.234s`, `VoiceSessionView first appear` about `+11.505s`, and `ItemStore load` finishes at about `+11.549s`; the remaining delay is no longer explained only by store loading.
- Several extra `VoiceSessionView init` log lines appear later during the same run, indicating SwiftUI view re-instantiation/recomposition; useful for sequencing, but not a reliable count of unique screen presentations.
- Follow-up startup optimization: `VoiceSessionViewModel` now creates `RealtimeAudioService` lazily, and `RealtimeAudioService` defers `AVAudioEngine`, `AVAudioPlayerNode`, and `SFSpeechRecognizer` construction until first use.
- Added `RealtimeAudioService init` timing logs so the next imported performance snapshot can verify that audio setup moved off the initial voice-tab startup path.
- Fresh device run `20260308-222659` confirms the lazy-audio change worked: `RealtimeAudioService init` appears at about `+24.497s`, not during startup.
- The same run also shows improved duplicate handling: the assistant verbally called out a similar reminder, and the diff updated the existing April 17 flight item to April 18 while deleting the extra older duplicate.
- Startup is still slow before first paint (`ContentView first appear` about `+8.062s`), so another startup hotspot remains beyond store loading and audio-service eager init.
- Diff generation latency was high again on this run (`~43.9s`, dominated by TTFB), likely because the extra duplicate/merge dialogue made the prompt larger and the model slower to respond.
- Non-voice workflow update: items now support persisted completion state (`isCompleted`) with strike-through rendering and explicit complete/uncomplete controls; completed items are preserved for future reference instead of being deleted.
- Inbox polish: completed items are hidden by default in Inbox behind a `Show Completed` toggle, while remaining searchable and preserved in storage.
- Fresh run `20260308-224720` shows mixed results: completion UI works, same-route diff normalization works, but live duplicate callout still did not happen and due-time parsing for `1 pm` was still off by one hour.
- The resulting diff updated the existing Shanghai → San Francisco item to April 11 rather than creating a duplicate, so the post-diff normalization is doing useful safety work even when the live assistant misses the duplicate.
- The imported logs do not clearly capture the reported first-attempt voice-session audio failure; they only show the later successful session start, plus many earlier `VoiceSessionView init` events with no matching audio/session error markers.
- Diff generation latency on this run was again very high (~56.9s total, TTFB ~56.2s), reinforcing that duplicate-heavy or otherwise longer prompts still push the selected Doubao model into slow response territory.
- Follow-up instrumentation now logs early voice-start phases to `app-performance.log` before a session is fully active, so first-attempt provider/audio failures should finally show up in the next shared bundle.
- Follow-up date/time parsing now normalizes spoken hour phrases (for example `one pm`) and combines separate date-only and time-only detector matches when transcript wording splits them apart with route text.
- Assistant-facing context now excludes completed items, so prompts like “what’s in my inbox?” should return only active items and duplicate matching should ignore completed history.
- Verified manually that completed items are no longer read back by the assistant.
- Remaining checks for next session:
  - Confirm the first-attempt voice-session audio failure is now captured by the new early start/error logs.
  - Confirm spoken `1 pm` phrases now resolve to the correct due time in the diff output on-device.

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
- **Stage timing logs.** Diff prep now logs provider/model, prompt/body size, request encoding time, HTTP time, response decoding, JSON parsing, and due-date fallback timing.
- **Network metrics logs.** Diff/summary requests now log `URLSessionTaskMetrics` so we can compare DNS, connect, TLS, request send, TTFB, and download time.
- **Replay benchmark script.** `scripts/replay-diff-models.py` replays one imported `voice-monitor` + `voice-items-before-diff` case against multiple Doubao models so latency comparisons use the same content each time.

### Proposed Next Steps
1) **Improve duplicate call-out reliability**
   - Option A: Inject a hidden internal instruction (e.g., `INTERNAL_RULE`) right after context so the model sees a fresh reminder without speaking it.
   - Option B: Add a short assistant pre-amble at session start (“I’ll flag duplicates as we go”).

## Debug Notes (2026-03-08)
- Current evidence points to the delay happening inside the diff provider request window, not the summary bypass path.
- The next verification run should inspect the latest voice-session log for lines like:
  - `Diff proposal payload ready`
  - `Doubao diff request prepared`
  - `Doubao diff request encoded`
  - `HTTP metrics collected`
  - `HTTP metrics tx1`
  - `Doubao diff HTTP completed`
  - `Doubao diff response decoded`
  - `Doubao diff JSON parsed`
  - `Diff due-date resolution completed`
- If `Doubao diff HTTP completed` consumes most of the time, the issue is network/server/model-side.
- If the HTTP step is fast, compare decode/parse/fallback timings to isolate app-side work.
- For apples-to-apples provider testing outside the phone, run `scripts/replay-diff-models.py` with a fixed imported session and a shell token.
- Replay benchmark on the same captured prompt showed:
  - `doubao-seed-2-0-mini-260215`: ~5.0s average total, ~4.45s average TTFB.
  - `doubao-seed-2-0-pro-260215`: ~10.2s average total, ~9.73s average TTFB.
  - `doubao-seed-1-6-lite-251015`: ~5.4s average total, ~4.89s average TTFB.
- Conclusion: for diff review prep, model choice dominates latency; the `pro` model is roughly 2x slower than `mini` on the same prompt.
- The app now keeps a dedicated `Review Model` setting for diff generation, with `mini` as the default and a separate main Doubao model for other uses.
- Future model switching remains simple because the settings UI supports both presets and free-form model IDs.
- Repeated 5x shell benchmark on the same captured prompt ranked current tested models by speed:
  - `doubao-seed-1-6-lite-251015`: ~4.79s average total, ~4.31s average TTFB.
  - `doubao-seed-2-0-mini-260215`: ~5.58s average total, ~5.04s average TTFB.
  - `doubao-seed-1-8-251228`: ~6.70s average total, ~6.21s average TTFB.
  - `doubao-seed-2-0-pro-260215`: ~10.56s average total, ~10.04s average TTFB.
- On this prompt, `1-6-lite` is the fastest tested review model, while `mini` remains a strong default if you prefer the newer 2.0 family.
- After removing existing-item `details` and compacting item JSON, the benchmark prompt shrank from ~6117 chars to ~5061 chars on the same captured case.
- Post-trim 5x benchmark results on that same case:
  - `doubao-seed-1-6-lite-251015`: ~4.36s average total, ~3.85s average TTFB.
  - `doubao-seed-2-0-mini-260215`: ~5.08s average total, ~4.60s average TTFB.
  - `doubao-seed-1-8-251228`: ~6.95s average total, ~6.46s average TTFB.
  - `doubao-seed-2-0-pro-260215`: ~9.87s average total, ~9.37s average TTFB.
- Conclusion: trimming the prompt helps, but only modestly; model/server TTFB still dominates overall latency.
- Synthetic mini-model benchmarks with larger conversations showed:
  - Below the 1200-char transcript threshold, review prep stays around ~5s on average because only the diff request runs.
  - Above the threshold, total review prep jumps to ~14–16s because the app adds a summary request before diff generation.
  - The diff request itself stays roughly ~5s even for longer conversations; the extra cost comes mainly from the summary step.
  - Repeated deletion wording in a long transcript can also bloat the final diff prompt because deletion hints are appended from the full transcript.
- Direct comparison on the same long synthetic transcripts showed summary is still a losing tradeoff at current sizes:
  - At ~1772 transcript chars: no-summary ~5.55s vs summary ~12.59s.
  - At ~3230 transcript chars: no-summary ~5.42s vs summary ~14.17s.
- Conclusion: for the mini diff model, the current 1200-char summary threshold is far too low; a much higher threshold (or disabling summary for diff entirely) is more appropriate unless transcripts become substantially larger than the current 4k trimmed window.
- A 20k-char synthetic transcript still showed the same pattern on the mini model:
  - no-summary: ~5.36s average total with a ~40.6k-char diff prompt.
  - summary path: ~15.24s average total, with ~10.75s spent in summary and ~4.49s in diff.
- This suggests the sweet spot threshold is far above current app limits; for the current diff path, summary is not a latency win even for very large transcripts.
- The app now sets the diff-summary bypass threshold to `100000` chars, which effectively disables summary for current review-generation workloads while keeping the code path available for future reconsideration.
- Live duplicate detection now uses a short rolling buffer of recent user utterances before similarity matching, which makes duplicate callouts more reliable when ASR splits one request across multiple short fragments.
- Diff decoding now tolerates numeric `priority` values and missing `details` fields, and parse failures log a raw content snippet so malformed model output is easier to diagnose.
- Startup/share responsiveness improved by deferring `LocalEmbeddingIndex` initialization until duplicate matching is first used, and by preparing exported log files on a background task before presenting the share sheet.
- `app-performance.log` now records app init, first root appearance, item-store load timing, embedding-index init timing, share-button tap timing, export completion, and share-sheet presentation; it is included in shared latest-log bundles.

## Restart Handoff (2026-03-08)
- Current diff pipeline state:
  - Summary step is effectively disabled for current workloads via `summaryBypassCharLimit = 100000`.
  - Diff prompt uses compact existing-item JSON and omits existing-item `details`.
  - Dedicated review model is configured via `doubaoDiffModel`.
- Benchmarks completed:
  - Multi-model shell replay established `doubao-seed-1-6-lite-251015` as the fastest tested review model on captured prompts.
  - Long-transcript and 20k-char tests showed summary is still slower than direct diff generation on `doubao-seed-2-0-mini-260215`.
- Reliability fixes completed:
  - Duplicate detection now combines recent user utterances before similarity matching.
  - Diff decoding tolerates numeric `priority` and missing `details` and logs raw parse snippets on failure.
- UX/perf instrumentation completed:
  - `app-performance.log` added for launch/share timings.
  - Share Latest Logs export moved off the main thread.
- Latest observed runtime issue before restart:
  - One phone diff run still showed very slow provider TTFB and high response variance.
  - A reminder-related session exposed ambiguous model behavior around create vs update; duplicate-callout fix was added afterward and still needs fresh device verification.
- Latest build status before restart:
  - Swift compiler complexity issues in settings views were fixed.
  - Preview macros were replaced with `PreviewProvider`.
  - Remaining sandbox build failure is non-Swift: app bundle codesign failed due to `resource fork, Finder information, or similar detritus not allowed`.

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

## Session Notes (2026-03-03)
- Restored Voice Session debug controls in Settings, including Save Debug Logs and Share Latest Logs for upload.
- Fixed Share Latest Logs to include diff artifacts appended after session stop.
- Strengthened diff prompt to resolve relative dates (e.g., next Monday) into `dueDate` using current date/time.
- Added remote due-date fallback for diff items when `dueDate` is missing.

## Session Notes (2026-03-05)
- Trimmed diff transcript payload (line/character limits) to speed up review preparation.
- Skipped the summary API call for short transcripts to reduce latency.
- Kept the debug logger alive through diff generation to capture timing in logs.
- Added transcript-based due date validation to correct “next Tuesday” style mismatches.
- Switched the default Doubao diff model to `doubao-seed-2-0-mini-260215` for faster proposals.
- Reduced diff item/transcript limits and max tokens to cut proposal latency further.
