# Plan

Agent instructions live in `AGENTS.md`.

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
- Align typed entry UX with explicit user intent:
  - Typed entry from `To Do`, `Ideas`, and `Notes` tabs saves directly without mandatory AI structuring/proposal.
  - Respect the selected tab as the saved item type; allow lightweight metadata parsing without type switching.
  - Keep full AI structuring/proposal as the default flow for Voice Session only.

## Current Milestone
M10 — Voice session polish + workflow (diff-at-end review)

## Product Direction (2026-03-12)
- Treat typed tab entry as explicit user intent: if the user enters from `To Do`, `Ideas`, or `Notes`, save directly into that type.
- Remove mandatory pre-save `structuring` / `proposal` for typed tab entry.
- Allow only lightweight typed-save enrichment:
  - derive `title`
  - preserve `rawText`
  - parse confident `dueDate` / explicit `priority` for `task` items
- Do not auto-reclassify typed tab entry into another type.
- Keep `Voice Session` as the primary `Smart Add` surface with AI structuring, duplicate handling, and review.
- Optional future enhancement: add post-save `Review with AI` actions for typed items rather than blocking save.
- Implementation status:
  - `InboxView` now passes the selected filter type into `AddItemView`.
  - `AddItemView` now saves typed entries directly into the selected type without calling `StructuringService` or showing `ProposedStructureView`.
  - `VoiceCaptureView` remains on the AI structuring/proposal path.
  - Repo-local no-signing `xcodebuild` validation succeeded after the change.
  - User validated on-device/in-app behavior: typed entry now saves immediately after item entry as intended.

## Visual Polish (2026-03-12)
- Replaced the plain app icon with a custom cute pink dino icon set.
- Added light, dark, and tinted `1024x1024` icon assets in `myButler/Assets.xcassets/AppIcon.appiconset`.
- Added a selectable UI color theme in Settings, with `Pink` included as one of the app-wide accent options.
- Extended the selected theme with a soft background wash across the main screens so the app feels more branded without becoming overly saturated.

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

## Session Notes (2026-03-08)
- Reproduced the current Xcode build locally with `xcodebuild` using repo-local derived data.
- Fixed Swift 6 concurrency warnings in log sharing by making `VoiceSessionDebugLogger.exportLogsForFileSharing(urls:)` nonisolated, so `Task.detached` does not hop back to the main actor.
- Current CLI build is green; remaining non-app warning is the Xcode `AppIntents` metadata skip message because the target does not use `AppIntents.framework`.
- Imported the latest AirDrop logs and analyzed the newest run (`20260308-213520`) for startup/share slowness and due-date mismatch.
- The current latest logs do not include `app-performance.log`, so startup/share latency cannot be measured from exported device traces yet.
- Root causes identified in code/log correlation: `VoiceSessionDebugLogger.clearAllLogs()` deletes `app-performance.log` during voice-session start, and transcript due-date extraction misreads spoken `April fifteenth` corrections.
- Re-imported after another device share; the new files were just Finder/AirDrop duplicates (`* 2`) of the same `20260308-213520` session artifacts, still without `app-performance.log`.
- Fixed the missing performance-log root cause by preserving `app-performance.log` during voice-session cleanup and recreating it on write if it was deleted.
- Reduced startup work on the main actor by moving `ItemStore` disk load off the launch path and applying the loaded items back on the main actor.
- Fixed transcript due-date extraction to normalize spoken ordinals (`april fifteenth`, `April 1 5 th`) and prefer late correction-style user lines over stale earlier mentions.
- Rebuilt with `xcodebuild`; only the existing Xcode App Intents metadata warning remains.
- Imported a fresh post-fix device log set (`20260308-215907`) and confirmed `app-performance.log` is now exported alongside the voice-session log.
- Latest run shows due-date extraction is fixed for spoken ordinals: the diff now creates a flight task for `2026-04-16`, matching the transcript’s `april sixteenth` request.
- Startup is improved structurally but still slow in practice: `ContentView first appear` is at `+5.631s`, while `ItemStore load` completes in the background at `+11.815s`, so another uninstrumented startup cost remains before first paint.
- Share-log timing is only partially visible in the exported performance log because the copied `app-performance.log` snapshot is taken before the later `export completed` / `sheet presented` log lines are appended.
- Duplicate/similar-item handling still missed this run: despite existing Shanghai→San Francisco flight items, the assistant did not call out similarity and the diff proposed a brand-new task instead of a merge/update candidate.
- Added more startup instrumentation around `VoiceSessionView` and `VoiceSessionViewModel` initialization/first appearance so the remaining pre-first-paint delay can be localized on the next device run.
- Changed log sharing to export a dedicated `app-performance-share-*.log` snapshot that is written after the export-complete marker, so the shared bundle captures later share timing instead of a stale pre-export copy.
- Strengthened similar-item heuristics for live duplicate prompts and diff generation with route-aware matching (`from X to Y`) plus token-overlap hints passed into the diff prompt.
- Rebuilt after these follow-up fixes; only the existing Xcode App Intents metadata warning remains.
- Imported a fresh run (`20260308-221239`): due date/time parsing is now correct for `April seventeenth one pm`, but duplicate handling still failed and created a second Shanghai→San Francisco flight item instead of surfacing a merge/update.
- The new share-performance snapshot is still not visible in `logs/airdrop`; the current import script only copies `app-performance.log`, not `app-performance-share-*.log`, so exported share-completion timing is still missing from repo analysis.
- Extended `scripts/import-airdrop-logs.sh` to import `app-performance-share-*.log` snapshots.
- Added post-diff normalization that converts near-date same-route task creates into updates against an existing matching travel item, biasing the review flow toward update/merge instead of duplicate creation.
- Rebuilt after these changes; only the existing Xcode App Intents metadata warning remains.
- Verified the new imported performance snapshot `app-performance-share-20260308-221353.log`; it now captures `Share Latest Logs export completed`, so share completion timing is visible in repo logs.
- The snapshot also localizes more startup cost: `ContentView first appear` happens at about `+6.0s`, but `VoiceSessionViewModel init` is delayed until about `+10.2s` and `VoiceSessionView first appear` until about `+11.5s`, pointing to remaining startup latency in the voice-tab/view-model path rather than the store load alone.
- Multiple later `VoiceSessionView init` entries appear during session/review/share flow, so view-init logging is useful for sequencing but noisy for counting unique view constructions.
- Deferred `RealtimeAudioService` creation by making it lazy in `VoiceSessionViewModel`, and made the audio engine/player/speech recognizer lazy inside `RealtimeAudioService` so voice-tab startup no longer pays audio-engine setup before the user starts a session.
- Added `RealtimeAudioService init` timing logs so the next device run can confirm audio setup moved from startup to session start.
- Verified on fresh run `20260308-222659` that `RealtimeAudioService init` now happens at `+24.497s`, well after startup and just before the session starts, so audio-service eager init is no longer on the startup path.
- Duplicate handling is now materially better for the flight case: the assistant called out a similar reminder during the conversation, and the diff produced an update+merge+delete flow that left a single Shanghai→San Francisco flight item dated `2026-04-18`.
- Startup first paint is still not good (`ContentView first appear` at about `+8.062s`), so deferring audio-service creation helped target the right path but did not solve the remaining startup latency.
- Diff latency regressed on this run to about `43.9s` TTFB-dominated, likely because the longer duplicate/merge conversation increased prompt size and model latency again.
- Added persisted completion state to `Item` with UI toggles, strike-through styling, and Today-view exclusion for completed items.
- Completed items are now retained instead of deleted, which keeps historical context searchable while removing them from the main “Today” action surface.
- Added an Inbox-level `Show Completed` toggle so completed items stay hidden by default but can still be revealed when needed.
- Latest shared run `20260308-224720` confirms completion UI is working, and same-route diff normalization now updates the existing flight item instead of creating a duplicate.
- The assistant still did not proactively call out the similar flight during the live conversation in this run; only the diff path merged it afterward.
- The due date day is correct, but the due time is wrong by one hour for `1 pm` (`2026-04-11T04:00:00Z` instead of `05:00:00Z`).
- First-time voice-session failure is not clearly captured in the current logs: the imported bundle only shows the later successful session, while many `VoiceSessionView init` entries appear earlier with no corresponding session-start or audio-error markers.
- Diff latency remained very high again on this run (~56.9s, dominated by TTFB).
- Added phase-level performance logs for voice-session startup (`start tapped`, provider setup, provider connect, permissions, ASR setup/start, audio capture start, playback start, initial greeting request, and start failure) so first-attempt failures are captured before the session logger becomes available.
- Improved spoken time normalization in `DueDateParser` for phrases like `one pm`, and added date+time match combining so transcripts with route text between date and time can still resolve the intended hour correctly.
- Rebuilt after these changes; only the existing Xcode App Intents metadata warning remains.
- Excluded completed items from assistant-facing inbox/history context, duplicate matching, and diff item snapshots so voice answers only reflect active items.
- Confirmed on the latest manual check that the assistant no longer mentions completed items.
- Pending for next session: verify first-attempt voice-session audio failure with the new early startup logs, and verify whether spoken `1 pm` time parsing is now fixed in a fresh device run.

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

## Session Notes (2026-03-03)
- Restored Voice Session debug sharing controls in Settings (Save Debug Logs + Share Latest Logs).
- Fixed Share Latest Logs to persist diff artifacts appended after session stop.
- Strengthened diff prompt to resolve relative dates into `dueDate`.
- Added remote due-date fallback for missing `dueDate` in diff results.

## Session Notes (2026-03-05)
- Trimmed diff transcript payloads to reduce review prep latency.
- Skipped the summary API call for short transcripts to speed up diff generation.
- Kept debug logging active through diff generation for timing visibility.
- Added transcript-based due date validation to fix “next Tuesday” mismatches.
- Defaulted Doubao diff model to `doubao-seed-2-0-mini-260215` for faster responses.
- Reduced diff payload limits and max tokens to further cut proposal latency.

## Session Notes (2026-03-08)
- Added fine-grained diff-prep timing logs for prompt sizing, request encoding, HTTP time, response decoding, JSON parsing, and due-date fallback.
- Next debug step is a real iPhone run to capture where “Preparing Review” time is actually spent.
- Added `URLSessionTaskMetrics` logging for diff/summary requests to split DNS/connect/TLS/request/TTFB/download timing.
- Added `scripts/replay-diff-models.py` to replay a fixed imported voice-session case against multiple Doubao models for apples-to-apples latency comparison from the shell.
- Replayed the same captured diff prompt against Doubao models; `doubao-seed-2-0-mini-260215` averaged ~5.0s vs `doubao-seed-2-0-pro-260215` ~10.2s, confirming model TTFB is the main bottleneck.
- Added a dedicated Doubao review-model setting so end-of-session diff generation defaults to `doubao-seed-2-0-mini-260215` without changing the main chat model.
- Ran a 5x repeated shell benchmark on the same captured prompt: `doubao-seed-1-6-lite-251015` averaged ~4.8s, `doubao-seed-2-0-mini-260215` ~5.6s, `doubao-seed-1-8-251228` ~6.7s, and `doubao-seed-2-0-pro-260215` ~10.6s.
- Trimmed the diff prompt by removing existing-item `details` and compacting item JSON; benchmark prompt shrank from ~6117 to ~5061 chars, with modest latency gains (~6–10% on most tested models).
- Synthetic conversation-length benchmarks on `doubao-seed-2-0-mini-260215` show the main jump happens once transcript length crosses the 1200-char summary threshold: review prep rises from ~5s to ~14–16s because of the extra summary call.
- Direct long-transcript comparison on `doubao-seed-2-0-mini-260215` shows the current 1200-char summary threshold is too low: even at ~1772 and ~3230 transcript chars, skipping summary was still much faster (~5.4–5.6s) than using summary (~12.6–14.2s).
- A 20k-char synthetic transcript still favored the no-summary path on `doubao-seed-2-0-mini-260215`: no-summary averaged ~5.36s despite a ~40.6k-char diff prompt, while summary averaged ~15.24s.
- Raised the diff-summary bypass threshold to `100000` chars so current review generation effectively skips the summary step; benchmarks showed summary remained a latency loss even at ~20k transcript chars.
- Improved live duplicate detection to use a rolling buffer of recent user utterances instead of matching only a single ASR fragment, which helps catch duplicates when intent is split across multiple short speech chunks.
- Hardened diff decoding to tolerate numeric `priority` values and missing `details`, and added raw content snippet logging on parse failures for faster diagnosis.
- Deferred `LocalEmbeddingIndex` initialization until it is actually needed and moved debug-log export off the main thread to reduce first-launch and first-share UI stalls.
- Added `app-performance.log` with launch/share timing markers and included it in shared latest-log bundles for future startup/UI-latency debugging.

## Restart Handoff (2026-03-08)
- Diff review speed work completed:
  - Added stage-level diff timing logs, HTTP metrics, and shell replay benchmarking.
  - Benchmarked multiple Doubao models; `1-6-lite` was fastest on tested prompts, `2-0-pro` slowest.
  - Added dedicated `doubaoDiffModel` setting and UI.
  - Removed existing-item `details` from diff context and compacted item JSON.
  - Raised diff summary bypass threshold to `100000` chars after benchmarks showed summary is slower even at ~20k chars.
- Reliability work completed:
  - Live duplicate detection now uses a rolling recent-user buffer instead of one ASR fragment.
  - Diff decoding now tolerates numeric `priority` and missing `details`, and logs raw content snippets on parse failure.
- Startup/share responsiveness work completed:
  - Deferred `LocalEmbeddingIndex` initialization.
  - Moved Share Latest Logs export off the main thread and added `Preparing logs…` UI.
  - Added `app-performance.log` and included it in latest-log sharing/import.
- Build verification status:
  - Fixed Swift type-check issues in `SettingsScreen.swift` and `SettingsView.swift` by splitting large view expressions.
  - Replaced all `#Preview` macros with `PreviewProvider` to avoid sandbox preview-plugin failures.
  - Latest sandbox `xcodebuild` no longer fails on Swift compile errors; current remaining failure is packaging/codesign: `resource fork, Finder information, or similar detritus not allowed` on the built app bundle.
- Suggested next step after restart:
  - Clean the build products / detritus causing the codesign failure and rerun `xcodebuild`.
  - Then validate on-device whether duplicate reminder callout now triggers and whether first-share/startup responsiveness improved, using `app-performance.log`.

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
