# Development Guide

Implementation reference, testing commands, and in-game diagnostic helpers for
[Out Loud](../README.md). See the main README for capabilities and project status.

## Runtime modules and initialization

Runtime services use singleton tables in the `OutLoud` namespace. `OutLoud.toc`
loads generated data, Core services, UI components, and initialization in order.
On addon load, initialization prepares the database, Options, Talking Head UI,
and QuestFrame/Quest Log/GossipFrame integrations. `Core/Narration.lua` shares
presentation ownership and TTS callbacks between these UI entry points.
`Core/NPCInspection.lua` owns one lazy, persistent inspection PlayerModel shared
by quest and gossip narration, independently of Blizzard UI initialization.
The speech event frame is created on the first valid speech request.
VoiceSelection creates a separate voice-list update observer during addon loading.
The addon initialization frame unregisters `ADDON_LOADED` and releases its handler
after setup. UI integrations each create at most one deferred-load observer;
it unregisters and clears its handler when the required Blizzard UI globals exist.

## Voice data, resolution, and saved settings

- `OutLoudDB.voices[family][sex]` stores voice assignments. Families are stable
  string identities, rather than numeric DB2 RaceIDs. Runtime `UnitSex` values
  are `2` for Male and `3` for Female.
- `OutLoudDB.voiceMode` is `"single"` or `"raceGender"`; missing/invalid values
  default to `"raceGender"`. `OutLoudDB.singleVoice` stores the optional narrator
  voice ID using the same numeric ID convention as existing family assignments.
  The schema adds no migration and does not rewrite the family assignment table.
  Switching modes preserves both settings and never calls TTS start/stop.
- `Data/VoiceMappings.lua` contains `VoiceMappings.Families` and direct
  `VoiceMappings.Models[FileDataID]` family mappings. It can be replaced with
  generator output and contains no gender data or addon runtime helpers.
- Options derives its rows from unique `VoiceMappings.Families` values, including
  families without model entries. Display labels convert keys such as `NIGHT_ELF`
  into readable names such as "Night Elf".
- In Race & Gender mode, `OutLoud.VoiceSelection:Resolve(unit, model)` accepts a PlayerModel already
  loaded for that unit and returns the configured voice ID plus inspection
  details. Unknown models, unavailable models/units, unknown sex, and unset voices
  return no voice, with a reason in the details. The resolver does not start speech.
- In Race & Gender mode, `OutLoud.VoiceSelection:ResolvePlayer()` uses the locale-stable token from
  `UnitRace("player")`, checks its explicit mapping against `VoiceMappings.Families`,
  and combines that family with `UnitSex("player")` and the existing database.
  It requires no inspection model. Unknown race tokens, unknown sex, and unset
  voices return no voice, with a reason; there is no fallback for custom races.

Both resolvers select the assignment mode inside `VoiceSelection`. Single Voice
uses `Database:GetSingleVoice()` and checks it against the existing
`TTS:GetVoices()` enumeration. It requires no family/race/gender lookup and
returns `single-voice-not-set` or `single-voice-unavailable` for an unusable
selection, without choosing a fallback voice or clearing the saved value.
The existing resolver paths remain unchanged. Presentation is selected separately:
Single Voice QuestFrame narration always shows the player model and captured quest
title. Multiple Voices keeps NPC model/name presentation and player fallback.
Quest Log always shows the player model and captured quest title in both modes.
Gossip Single Voice shows the player model and captured NPC name. Multiple Voices
shows the NPC model/name when resolution succeeds; player fallback retains the
captured NPC name while using the player's model and configured voice.

Both assignment modes now use `VoiceSelection:IsVoiceAvailable(voiceID)` against
the same cached API list. An unavailable family assignment returns
`voice-unavailable`; the existing QuestFrame player fallback still applies.
An unavailable Single Voice never changes mode or chooses a different voice.
Saved IDs are retained in both cases.

`VoiceSelection:RefreshVoices()` is the centralized refresh entry point. It calls
`TTS:RefreshVoices()`, updates the existing UI options table in place, and refreshes
selected/disabled presentation without restarting narration or rebuilding rows.
Refresh occurs on `VOICE_CHAT_TTS_VOICES_UPDATE` and Settings opening, with no
polling or enumeration per streamed sentence. Native enumeration exceptions retain
the last known list and release the reentrancy guard; the error is reported.
The documented getter and update event support refreshing the addon's snapshot,
but the local export does not guarantee native re-discovery of Windows voices
installed or removed while the client is running. A client restart may be needed.

Voice metadata exposes only `voiceID` and display `name`; no stable SAPI token is
available in the local API export. Existing numeric assignments and SavedVariables
remain compatible, with no migration or name matching (including duplicate names).
ID stability across restart/enumeration changes is unverified. If the client reuses
an ID for another voice, Out Loud cannot reliably detect/remap it from this schema;
verify the displayed selection after changing installed voices.

The Voice Assignment radio group uses the existing `UIRadioButtonTemplate`.
Both configuration areas stay visible. `ComboBox:SetEnabled()` delegates to
the native `SettingsDropdownWithButtonsTemplate` mixin, disabling the dropdown
and both steppers; disabled callbacks are also guarded and open menus close.
Labels use native disabled fonts. Mode clicks and Settings reopening refresh
checked/enabled states and selected text. All selectors share `GetVoiceOptions()`.
Unavailable choices display `Unavailable (voice ID)` and Settings no longer
deletes unavailable family assignments when rebuilding rows.
The native `SetEnabled`, `SetSelectionText`, `GenerateMenu`, and `CloseMenu`
behavior was inspected in the local Forever export's setting controls, shared
panel templates, and menu code. Mock checks do not verify their in-game styling
or interaction; those still require a manual check.

NPC and player resolution share gender naming and configured-voice lookup;
their model/race lookups and failure reasons remain distinct. Missing or malformed
family settings return no voice. Selecting a voice repairs that family's table
without replacing other assignments. Reading mode is normalized to `full` or
`split` during initialization and through database access; invalid values use the
existing `full` default. Voice settings use only the current family-keyed schema;
the development addon does not migrate earlier numeric race settings.

## Speech controller API

Callers supply text and an already-resolved voice ID to the `OutLoud.TTS` singleton:

- `SpeakStreaming(text, voiceID)` normalizes whitespace and uses the tested
  `.`, `!`, `?` sentence splitter. The first sentence is submitted immediately;
  each valid sentence ownership bookmark submits only the next sentence. Duplicate bookmarks
  cannot queue a sentence twice. No timers or artificial delays are used.
- `SpeakWholeText(text, voiceID)` submits the sanitized complete text in one
  request, preceded by one ownership bookmark. It never splits or prefetches.
- `Speak(text, voiceID)` reads the existing saved `readingMode` through the
  database: `"split"` selects streaming and `"full"` selects whole text. The
  default is `"full"`.
- `Stop()` cancels active Out Loud speech. Calling it while idle leaves other
  TTS alone.

`TTS:SanitizeSpeechText(text)` replaces `/`, `\`, `|`, `_`, and `~` with spaces,
also replaces forbidden XML ASCII controls (`0x00`-`0x08`, `0x0B`, `0x0C`,
`0x0E`-`0x1F`) with spaces, collapses whitespace, and trims it. Tab, LF, and CR
continue through whitespace normalization. Punctuation and UTF-8 bytes are
preserved. This is a control-byte filter, not a general UTF-8 validity parser.
Both reading modes use this helper before payload construction. Speech is then
escaped for XML text (`&`, `<`, `>`) before the unchanged ownership bookmark is
prepended, so user text and pre-encoded entities cannot introduce markup.
The controller previously appended raw text; it had no escaping helper.

Full mode retains the exact original text for display callbacks. Split mode keeps
the existing splitter's original normalized sentences and indexes alongside
sanitized speech sentences. Empty speech sentences are skipped without queuing a
request or accepting a bookmark for that index. Completion follows the last
nonempty speech sentence, including when a trailing separator-only sentence was
skipped. Entirely empty sanitized input returns `false, "invalid-text"` before
starting a session, preserving the existing invalid-input cancellation policy.
The shared narration coordinator already hides Talking Head and clears loading
when submission is rejected. No synthetic bookmarks or timers are added.

The controller's existing event frame also handles `PLAYER_LOGOUT`, including
UI teardown for `/reload`, by calling `Stop()` before the Lua state is discarded.
This cancels the active session and stops native playback. The shutdown event and
actual audio interruption still require verification in WoW: Forever.
Native stop errors are caught and printed in red, with the synchronous-event
guard released and the session-end callback still notified. A native engine that
rejects stopping may continue audio; Lua cleanup cannot guarantee native recovery.

All three Speak methods accept an optional third argument, `onSessionEnded`.
The controller calls `onSessionEnded(reason, sessionID)` when that session ends:
`"finished"` after the final owned utterance, `"cancelled"` on stop/replacement,
or `"failed"` on a native call error or owned playback failure. Callback errors
are caught and diagnosed. Invalid input creates no session and invokes no callback.

An optional fourth argument, `onPlaybackStarted`, receives the session ID once,
at the first valid ownership bookmark for the current session. Duplicate and
later bookmarks do not notify again. Submission return and unowned playback-start
events do not invoke this callback. Callback errors are caught silently.

An optional fifth argument, `onTextProgress(text, chunk, offset, sessionID)`,
receives the full original text in full mode (`chunk = 0`), or the normalized
active sentence and its index in split mode. An ownership bookmark sends offset
0 once per active text. Callback errors are caught and printed in red.
Speech payloads always retain the existing ownership-only format, including when
the display callback is supplied.
`TTS:SplitSentences(text)` exposes the same splitter used by streaming, so Talking
Head can prepare exactly the first sentence before its entrance animation.

Word-level `OUTLOUD:PROGRESS` bookmarks were removed after the user reported
degraded speech quality. The controller adds only the original ownership bookmark
at the start of the complete text or streamed sentence. It ignores the removed
UI markers. Full mode still makes one native request, and streaming still
prefetches one sentence ahead. A display callback cannot alter the generation text.

Speak methods return `true` when submission succeeds, or `false` plus a reason:
`invalid-text`, `invalid-voice`, `no-sentences`, or `speech-failed`. A supplied
voice ID must be a nonnegative integer; `0` is valid. Rate comes from
`Database:GetSpeechRate()` on each request (default `0`), volume is `100`, and
overlap is `false`. Initialization creates the event frame once and
disables Blizzard's line-separator sound once.

## Sessions, cancellation, and known limitations

Both modes share cancellation and monotonically increasing session IDs. Starting
valid new speech cancels the active session before submitting immediately.
Sessions record `state` (`active`, `completed`, `failed`, `cancelled`), creation/end
times, stop reason, and replacement ID. A request identity is reserved before
replacement callbacks run, so narration requested by a callback cannot be
overwritten by the enclosing request. A superseded Speak call returns
`false, "session-replaced"`. The public speech methods and presentation callback
signatures are unchanged. Full still uses one request and its `WHOLE` bookmark.

Split's authoritative records live in `CurrentSession.sentenceStates[index]`:

- `state`: `planned`, `skipped`, `submitted`, `playback-confirmed`, `completed`,
  `failed`, `cancelled`, or `closed-unresolved`.
- Session ID, original sentence index, submission state, ownership bookmark,
  primary native utterance ID, playback confirmation, and logical cancellation.
- `attempts`: submission attempts identified by session ID, sentence index, and
  attempt ordinal. Currently only attempt 1 is submitted; there is no retry path.
  Future retries would also need distinct wire bookmarks before being enabled.

An attempt records `submissionState` (`calling`, `returned`, `error`), submission
time, submitted voice/rate, ownership and native-event evidence, and global-stop
exposure (count, last stop ID/time/result). A returned call is not proof of queue
acceptance. `nativeState` is `waiting-unconfirmed`, `bookmark-observed`,
`finished-reported`, `failed-reported`, or `unknown-after-stop`. Terminal evidence
and logical cancellation are independent: a cancelled sentence can later produce
owned playback or terminal events without reactivating narration. A terminal
emitted during stop is marked `duringStop`; it does not prove all text was spoken.
Failed unfinished requests also lose playback authorization while retaining their
`failed` logical outcome; a submission exception does not prove native removal.

The first ownership bookmark authorizes the existing one-sentence-ahead prefetch.
Repeated bookmarks and secondary native utterances never authorize additional
progression. At most two native utterance observations are retained per attempt;
further IDs set `evidenceOverflow` and leave its native disposition unresolved.
Conflicting ownership of a reused utterance ID is treated as ambiguous. Events
with ambiguous ownership cannot complete/fail narration. Additional native IDs
are duplicate candidates, not proof that audible speech happened twice.

Final-chunk finish retains the existing session-end behavior. Earlier chunks with
no confirmed terminal become `closed-unresolved`, not implicitly completed.
That logical label records their disposition at session end; later native evidence
can resolve an attempt without reopening the retired session.
Empty sanitized sentences remain indexed as `skipped` and never get attempts.
Split's `queued`, `completedTokens`, and `completedUtterances` are compatibility
views; controller decisions use sentence/attempt records.

Ended Split sessions release display/speech text, callbacks, bindings, and pending
event buffers. `TTS.SplitHistory` keeps compact metadata for at most eight sessions
and 128 submitted attempts, without text, callbacks or completed session objects.
Metadata eviction is loss of correlation evidence, never proof of native removal.
Historical known utterances can still receive observations. Unowned event buffers
are reset between controller epochs; they never carry a cached terminal into a
new session. Full retains its existing ephemeral session and cancellation summary.

`Stop()` retains the existing `TTS.CancelledSession` stop-authorization summary:
only the latest cancellation, with at most 128 submitted unfinished tokens that
were not identified at cancellation, preferring the most recent submissions.
This is independent of historical observation
metadata. `GetSplitRecoveryEligibility(attempt)` exposes `idleStopEligible`,
`emergencyStopEligible`, `retryEligible`, and the decision reason. Active newer
narration can receive the experimental recovery below. Native uncertainty alone
never authorizes resubmission, and retries remain disabled.

Emergency STOP is considered only on a fresh, exact ownership bookmark of a
retained, previously submitted Split attempt from a logically cancelled session.
The attempt must have returned from submission and an earlier addon stop call,
have no ownership at cancellation, and have no terminal, ambiguous or excess
native-utterance evidence. The newer session must be active in Split mode, with
no ownership evidence at all and no previous emergency recovery attempt. Full
sources and active Full sessions keep their existing playback policy.

STARTED alone is not ownership. Its native ID is correlated when a matching
bookmark arrives. Another unidentified STARTED, BOOKMARK, FINISHED or FAILED
blocks recovery; lack of events does not prove exclusive native audio ownership.
Up to 128 unidentified IDs are retained as metadata, including through logical
replacement/stop. Ownership correlation clears a matching ID, but a successful
global stop does not clear unidentified evidence. Evidence loss or ambiguous
ownership blocks recovery conservatively; unresolved evidence may keep it blocked.

An eligible stale bookmark requests exactly one additional native
`StopSpeakingText()` for that newer session. Its budget is consumed before native
code executes, even if the call raises an error. This never calls logical `Stop()`
on the newer session and never resubmits its pending sentence. Existing records,
callbacks and normal ownership-driven prefetching remain in place. Both old and
new unresolved attempts record exposure to that global stop. Performed/skipped
decisions and reasons are recorded by the optional diagnostic observer.

The existing single idle follow-up stop is preserved for an eligible, newly owned
cancelled request with unresolved native disposition. Its stop-authorization token
is consumed even during active replacement narration, preventing a later repeat
from stopping audio while idle. Already identified, completed, unsubmitted,
wrong-mode and forgotten tokens cannot authorize that follow-up. Older retained
cancellations can also supply evidence for the guarded emergency recovery.
No automatic retry, timeout, timer, or artificial delay is introduced.

Only owned utterances can finish or fail a session. Native call errors are caught
and printed in red regardless of the diagnostic flag. Bookmarks establish ownership. An
asynchronous failure before the first ownership bookmark cannot immediately be
distinguished from unrelated TTS and does not change session state.
Each controller epoch retains up to 128 recent terminal-event records by utterance ID,
discarding the oldest records when full. An exact current-session ownership
bookmark is required before a retained failure or finish can be applied.
Duplicate events within the current session do not duplicate cleanup. A late finish is applied without
restarting playback notifications, scrolling, or text transitions. In split mode,
a recovered intermediate finish submits only the next sentence; completed chunk
and utterance guards prevent repeated progression or resurrection.
Split also retains at most 128 unowned STARTED records, which can be associated
after an exact issued bookmark arrives. STARTED alone cannot establish ownership.
During an ordinary native stop, Split evidence is recorded passively. During an
emergency stop, up to 128 synchronous playback events are deferred, then dispatched
after the native call returns so valid newer ownership/terminals are not consumed
without their normal Lua state transitions, callbacks and prefetching. Deferred
events do not advance narration inside the stop call. Overflow is reported as
evidence loss, never treated as native silence or retry permission. Unowned
evidence from an ended controller epoch cannot claim a subsequent replacement.
Unowned records are evidence to correlate later, never ownership by themselves.
STARTED/terminal buffers do not survive session replacement; only unidentified-ID
metadata is carried for conservative recovery eligibility. A discarded/evicted
terminal cannot be recovered without another terminal event.

The local `VoiceChatDocumentation.lua` documents no return value for `SpeakText`.
`STARTED`, `FAILED`, `FINISHED`, and `VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE` carry an
utterance ID/status but no addon caller or submitted request token. The latter
event is not used to infer ownership. `SynchronousEvent` metadata does not
establish event order or correlate an event with a particular Lua call.
Consequently, a failed request that never delivers its bookmark remains unresolved.
Missing bookmarks also prevent reliable completion and split progression.
No watchdog or timeout is added: there is no established safe generation/playback
deadline for Pocket TTS or other engines, and a global stop could interrupt valid
long-running narration or unrelated audio. Close Talking Head, call `TTS:Stop()`,
or start replacement narration to release the session explicitly.

The local Blizzard TTS implementation notes that purged utterances do not emit
`FINISHED`. No documented purge notification or per-utterance cancellation API
is exposed. Arbitrary external purges therefore remain undetectable; Lua cleanup
cannot guarantee native silence after a failed global stop. The idle follow-up is
still global and can interrupt unrelated TTS; the API cannot establish exclusive
audio ownership or selectively cancel an old utterance. If old audio survives
cancellation while newer narration is active, a guarded experimental global stop
may interrupt it. That stop can also purge newer or unrelated requests; Lua has no
selective cancellation or queue inspection. A purged newer request may never emit
a terminal and remains unresolved without resubmission. Received FINISHED events
report a native terminal, not proof that the full sentence was audibly spoken.
In Split, stale evidence and performed/skipped recovery decisions are recorded.
Only the newest cancellation
can authorize the idle follow-up. Tokens beyond retention limits, or delayed output
after that follow-up, receive no further stop requests.
These limits preserve bounded state and avoid speculative synchronization.
Early-event buffering, current-session ownership, completed-token guards,
sanitization/escaping, Speech Rate and one-sentence-ahead prefetch remain unchanged.
Standalone/mock checks cover explicit sentence/attempt states, stop exposure,
recovery eligibility predicates, deferred-event dispatch, ambiguous IDs, bounded
duplicate evidence, rapid switches, callback reentrancy, recorder removal, idle cancellation, active replacements in TTS and
Quest/Gossip integrations, normal completion, repeated bookmarks, submitted-token
validation, summary eviction/bounds and unchanged progression. The user verified
the earlier idle-stop protection in-game, and independently reported successful
native ALPHA/BRAVO/CHARLIE cancellation/replacement with Pocket TTS at 2- and
8-second delays. Those results do not verify this revised addon flow. Check
Talking Head close with a prefetched sentence, rapid QuestFrame/Quest Log/Gossip
replacement, new narration completion and both Full/Split modes in-game.
Speech methods do not
extract quest text, resolve voices, or control Talking Head behavior.

For the Emergency STOP investigation, the user confirmed audible old prefetched
playback in Forever: replacement/initial stop at 2101.680, cancelled chunk 3's
bookmark at 2102.177, its FINISHED at 2104.268, then newer playback. Earlier Toolbox
experiments with replacement delays 0.0, 0.2 and 1.0 seconds interrupted stale audio
using another STOP without resubmission; at 5.0 seconds the initial stop sufficed.
Resubmission produced duplicates. These observations motivate the experiment;
they do not establish queue-removal or newer-request-survival guarantees.

The mock native layer has no queue or automatic stop acknowledgements. Removed
scenario fixtures manufactured callbacks inside SpeakText/StopSpeakingText,
terminal-before-bookmark playback recovery and completion followed by a submission exception.
The observed trace checks only addon reactions. Deferral is checked directly with
the Lua stop guard, not by asserting that native STOP emits a particular sequence.
Remaining logic checks do not establish native event ordering or playback timing.

### Temporary lifecycle diagnostics

`Core/TTSDiagnostics.lua` is a removable observer loaded immediately before TTS.
It keeps the latest 200 timestamped events in a ring buffer, plus formats bounded
current/retired state snapshots. The recorder uses IDs and decisions, never quest
text or callbacks, and prints nothing. Times use the client `GetTime()` timebase.
Recorder errors are isolated from playback decisions. Removing this file and its
TOC entry leaves essential state tracking and cancellation functional; recorder
removal is covered by standalone mocks.

`_G.OutLoud.GetTTSReport()` returns the complete report as one string. In Toolbox
Lua Console, run this standalone script to open its existing export dialog directly:

```lua
Toolbox.UI.ExportDialog:Show("Out Loud TTS report", _G.OutLoud.GetTTSReport(), 900, 650)
```

Alternatively, `return _G.OutLoud.GetTTSReport()` returns one Console result for
the Console's EXPORT TEXT action. Neither approach prints report lines to chat.
The export call was checked against local Toolbox source; its live rendering is
not established by the mocks.

For manual verification after `/reload`, use Pocket TTS in Split with at least
three sentences. Check normal sentence transitions and completion, close while B
plays and C is prefetched, replace that narration with another quest, and repeat
several rapid replacements. Capture the report promptly after stale audio or an
unexpected spinner/completion. Confirm newer requests are submitted once and
stale bookmarks do not advance presentation. On a qualifying stale bookmark,
check for one `emergency-stop-performed` record and listen for interruption of old
audio followed by the original newer request playing once. Check skipped recovery
when newer ownership is already known, another native ID is unidentified, or that
session has already used its recovery budget. A reported successful stop is not
proof that the newer request survived; capture unresolved cases without retrying.
Also verify Split-to-Full and Full-to-Split replacement, ordinary Full playback,
and completion/cancel through QuestFrame, Quest Log and Gossip. Native stopping,
silently purged requests, audible duplicates, event timing and UI rendering still
require these WoW: Forever checks. No live TTS tests were run for this redesign.

The user reported successful Pocket TTS and Microsoft Zira Desktop narration in
both Full and Split modes before this hardening pass. The revised event recovery
and voice-refresh paths have standalone/mock coverage, not new in-game verification.
For manual regression checks, use each voice in both reading modes through manual
and automatic QuestFrame narration and Quest Log. Verify spinner removal, original
displayed text, sentence transitions/prefetch, completion, close/cancel, rapid
replacement, and `/reload`. Open Settings again to refresh voices and confirm
unavailable labels and retained assignments. Whether Windows voice changes cause
the documented update event/native list refresh remains an in-game check; perform
any voice installation/removal separately and manually. This addon never registers
or unregisters SAPI engines.

## Development testing

Run the mocked checks from the addon root with standalone Lua 5.1:

```text
lua Tests/VoiceSelection.lua
lua Tests/TTS.lua
lua Tests/QuestIntegration.lua
lua Tests/GossipIntegration.lua
```

Voice-selection tests exercise the generated mappings, real Options controls,
saved settings, and addon load order. Speech tests mock the native
engine and playback events to check streaming, mode dispatch, cancellation,
stale/duplicate bookmarks, completion, failures, and input validation. Model
loading, rendering, and actual audio still require in-game checks.
Reliability checks cover terminal-before-bookmark recovery, duplicate completion,
missing-bookmark isolation, bounded early-event retention, stale/reentrant callback
safety, global-stop cleanup, and control-byte removal. Voice tests cover event and
Settings refresh, shared menu/runtime availability, unchanged saved selections,
duplicate display names, and enumeration exceptions without playback polling.
Sanitization checks cover separator replacement, punctuation and Unicode,
literal XML/entity escaping, original display callbacks, single-request full
mode, split indexes/prefetch, and empty speech cleanup. Quest checks exercise
both QuestFrame and Quest Log speech paths with the real TTS dispatcher and a
mock Talking Head. These are standalone/mock checks; actual speech, XML/entity
handling by Forever's native TTS, bookmark timing, and sentence display/animation
still require manual in-game verification.
The Settings mocks model the modern checkbox, slider/stepper callbacks, and
scrollbar percentages. The TOC is loaded in order, but Talking Head initialization
is stubbed because standalone Lua cannot instantiate its XML template. XML paths
and animation targets must be checked separately; these tests do not render it.

Quest-integration tests exercise the real UI module and voice resolver with mocked
frames, units, model loading, Talking Head presentation, and the native speech
engine. They cover visibility and transitions, exact state-specific text passed
to Talking Head and TTS, call ordering, repeated clicks, deferred UI loading,
unresolved inputs, and failed speech submission. Additional checks use the real
TTS dispatcher to verify saved reading modes and session replacement. The mocks
do not prove Forever's actual event ordering, UI rendering, or model readiness.
They also check player fallback and cancellation of pending automatic requests
on manual click, close, disabling, quest/page replacement, or another TTS session,
including a callback delivered after cancellation.

Gossip-integration checks load the real generated mappings, inspection helper,
voice resolver, database, narration controller, and TTS dispatcher. They cover
manual-only visibility and updates, current greeting extraction, both voice modes,
player fallback, deferred initialization in both UI orders, alternating quest/gossip
model reuse, session replacement, sanitization/escaping/rate, stale bookmarks,
owned completion, and failure cleanup. Talking Head and Blizzard frames are mocked;
these checks do not establish event order, model readiness, layout or audible playback.

## Quest narration

`OutLoud.UI.QuestIntegration` creates one unnamed `UIPanelButtonTemplate` button
parented to `QuestFrame` and retains the shared inspection `PlayerModel` as
`QuestIntegration.Model`. `OutLoud.NPCInspection:GetModel()` creates it once using
`CreateFrame("PlayerModel")` without a parent or explicit `Hide()`, matching the
user's working in-game inspection script. The button
is 100 by 22, labelled **Out Loud**, and anchored with
a separate gap frame between the current panel's native left and right action
buttons. If only one action button is shown, Out Loud sits beside it; if neither
is shown, Out Loud hides. Blizzard controls are not moved or resized; placement
still needs a client check.

`UpdateButtonVisibility()` centralizes visibility. It requires an open
`QuestFrame`, exactly one shown dialogue panel, a usable text API, and nonempty
dialogue. A shown `QuestFrameGreetingPanel` always hides the button, including
transitions where an older panel may still be shown. No panel or ambiguous panels
also hide it. Each click re-reads the panel and text instead of caching event state.

| Shown panel | Dialogue source |
| --- | --- |
| `QuestFrameDetailPanel` | `GetQuestText()` |
| `QuestFrameProgressPanel` | `GetProgressText()` |
| `QuestFrameRewardPanel` | `GetRewardText()` |
| `QuestFrameGreetingPanel` | None; button hidden |

Initialization adds `HookScript` callbacks after Blizzard's handlers:

- `QuestFrame`: `OnEvent`, `OnShow`, and `OnHide`.
- All four panels above: `OnShow` and `OnHide`.
- Available native action buttons: `OnShow` and `OnHide`.

The `OnEvent` hook refreshes after the frame's existing registered events, including
`QUEST_GREETING`, `QUEST_DETAIL`, `QUEST_PROGRESS`, `QUEST_COMPLETE`,
`QUEST_FINISHED`, and item/text refreshes. The module does not register quest events
on a second frame or maintain a separate quest state machine. If required frame
globals are absent, one temporary observer retries initialization on
`ADDON_LOADED`; it unregisters and releases its callback after setup succeeds.
Initialization and show/hide hooks never start speech. The single `OnEvent`
hook can also request narration for the three opt-in events described below.

On click, the module obtains current dialogue and tries the NPC first. When
`questnpc` and the inspection model are available, it clears the previous model,
calls `SetUnit("questnpc")`, then calls
`OutLoud.VoiceSelection:Resolve("questnpc", model)`. A nonnegative integer voice
ID, including `0`, keeps the NPC as speaker. Missing NPC/model, unresolved model
or family, unsupported gender, and missing or invalid configured voice instead
fall back once to the existing `VoiceSelection:ResolvePlayer()` used by Quest Log.
Those family/gender failure rules apply in Multiple Voices mode. Single Voice
overrides the displayed unit to `"player"` after the existing voice resolution,
and captures `GetTitleText()` alongside the dialogue at narration start.
The chosen model unit, title, and unchanged dialogue enter the same presentation lifecycle:

```lua
local ok, reason = OutLoud.Narration:Speak(speakerUnit, text, voiceID, displayTitle)
```

The existing Talking Head singleton is under `OutLoud.UI.TalkingHead`, not a
separate `OutLoud.TalkingHead`. Show receives the current dialogue and prepares
the complete text or first normalized sentence according to the saved reading mode.
`TalkingHead:Show(unit, text, displayTitle)` accepts an optional independent title;
omitting it retains `UnitName(unit)`, preserving Multiple Voices speaker names.
Quest narration passes an empty override if its title is missing, which displays
`"Quest"` instead of a previous title or a unit name. The title is set once per
Show; loading, sentence transitions, and completion never reread quest UI state.
The title getters were checked against the local Forever export's `QuestInfo.lua`,
`QuestFrame.lua`, and `QuestLogDocumentation.lua`; their live results across
Detail/Progress/Reward and Quest Log still require in-game verification.
The TTS dispatcher applies the existing reading mode and owns cancellation/restart;
quest integration never selects streaming/full methods or splits sentences itself.
If `Speak()` returns `false`, integration calls `talkingHead:Hide()`, which also
clears the loading spinner, and preserves the failure return values.

The spinner turns on before speech submission. The shared `OutLoud.Narration`
controller supplies a session-end callback that hides Talking Head and clears
the spinner on completion,
stop, or failure. Each narration request gets a new presentation ownership token before speech
is submitted, so cancellation of the previous session cannot hide the new display.
The callback also handles completion during the native submission call. A
playback-start callback clears loading at the first valid current session
bookmark, once per session in both reading modes, and checks the same presentation
ownership token. The spinner stays on while speech is generating; submission
return and unowned playback-start events do not clear it. TTS does not depend on
the UI.
Closing or changing the quest window updates button visibility and cancels a
pending automatic request; it neither stops active narration nor hides Talking
Head. The Talking Head close button hides the
presentation and spinner, then calls `OutLoud.TTS:Stop()` to cancel narration.

### Automatic QuestFrame narration

`OutLoudDB.autoNarrateQuests` defaults to `false` when absent; existing saved
values and voice/reading-mode settings are preserved. Database access uses
`GetAutoNarrateQuests()` and `SetAutoNarrateQuests(enabled)`.

`OutLoudDB.autoNarrationDelay` stores seconds, defaulting to `2`. Database access
uses `GetAutoNarrationDelay()` and `SetAutoNarrationDelay(delay)`. Initialization
and the setter clamp numeric values to 0–5 and round to the nearest 0.5-second
step; invalid values use the default. Valid existing values are preserved.
`Database.AutoNarrationDelay` supplies the shared default, bounds, and step.

The Settings section is labelled **Narration**, with the existing **Reading Mode**
choices and **Automatically read quest text** checkbox. The checkbox uses
`SettingsCheckboxTemplate`, `SettingsCheckboxMixin:Init()`, and its
`OnValueChanged` callback from the local Forever export's
`Blizzard_Settings_Shared/Blizzard_SettingControls.xml` and `.lua`. Its tooltip
handlers and large hover highlight are disabled; interaction covers only the
checkbox and label. The visible description shares the existing description
font/wrapping and is included in the page's scroll height.

Below it, **Automatic narration delay** uses `MinimalSliderWithSteppersTemplate`
from `Blizzard_SharedXML/Shared/Slider/MinimalSlider.xml` and `.lua`, the same
control used by native Settings sliders. `Init(value, min, max, steps, formatters)`
receives 10 steps across 0–5 seconds. The right-label formatter displays values
such as `0 s`, `0.5 s`, and `2 s`; `OnValueChanged` saves changes. `SetEnabled()`
disables both the slider and its stepper buttons when automatic narration is off.
Checkbox changes and opening the controls refresh the saved value and enabled
state, with programmatic refreshes excluded from saving.

**Speech Rate** follows the delay control and reuses
`MinimalSliderWithSteppersTemplate`, with 20 steps across -10 to +10. The local
Forever export's `Blizzard_ChatFrame/Shared/TextToSpeechCommands.lua` defines
`TEXTTOSPEECH_RATE_MIN = -10` and `TEXTTOSPEECH_RATE_MAX = 10`;
`VoiceChatDocumentation.lua` confirms the numeric `SpeakText` rate argument.
The slider displays the integer value, prefixes positive values with `+`, and
labels its endpoints Slower/Faster. A native `UIPanelButtonTemplate` button
resets it to 0. Both controls remain enabled independently of automatic narration.

`OutLoudDB.speechRate` defaults to `0`. `Database.SpeechRate` supplies the shared
bounds and step; initialization, `GetSpeechRate()`, and `SetSpeechRate(rate)`
validate values. Out-of-range integers are clamped; missing, nonnumeric,
fractional, or nonfinite values fall back to 0. Existing settings are retained.
The shared TTS submission reads this setting for every full-text or sentence
request. Changing it does not restart playback; an already prefetched sentence
retains its submitted rate. No global Blizzard speech-rate setting is modified.

Standalone/mock checks cover validation, saved-value reloads, slider step and
formatters, reset, and Full/Split request parameters with unchanged bookmarks
and lifecycle. In-game verification is still required for slider rendering,
stepper/drag interaction, `/reload` persistence, and audible speed at -10, 0,
and +10 in both reading modes. Check rate changes during split playback and
confirm subsequent submissions adopt the new rate without interrupting audio.

Only the existing `QuestFrame` `OnEvent` post-hook schedules automatic narration,
after Blizzard handles the event and Out Loud refreshes button visibility:

| Event | Current dialogue source |
| --- | --- |
| `QUEST_DETAIL` | `GetQuestText()` |
| `QUEST_PROGRESS` | `GetProgressText()` |
| `QUEST_COMPLETE` | `GetRewardText()` |

These events were verified in-game by the user. The local shared
`Mainline/QuestFrame.lua` registers them and shows their corresponding panels;
the panels' `OnShow` handlers hide the previous panels before the post-hook runs.
When enabled, the event hook calls `ScheduleAutoNarration(event)`. A zero delay
calls `StartCurrentNarration()` immediately; other values create one cancellable
`C_Timer.NewTimer()` in `QuestIntegration.PendingAutoNarration`. The request
captures `GetQuestID()`, the current text, and its source. Before reading, the
callback checks that this is still the pending request, automatic narration is
enabled, and the same quest/page/text is still available. It then calls the same
`StartCurrentNarration()` wrapper as the manual button, which invokes
`SpeakCurrentText()` with existing error handling, text validation, NPC-to-player
fallback, and shared narration lifecycle.

Replacing the automatic event, closing QuestFrame, changing the quest/page/text,
disabling automatic narration, or starting manual QuestFrame narration cancels
and clears the pending timer. Existing frame lifecycle hooks check context;
a post-hook on `Database:SetAutoNarrateQuests()` handles disabling the setting.
A post-hook on `TTS:StartSession()` also cancels pending automatic narration when
another narration session starts, including Quest Log or direct TTS calls.
Cancelled callbacks cannot revive an old request. There are no extra event
frames, polling, or show/hide narration triggers; the timer only schedules the
automatic path, without changing TTS generation or streaming.

The manual button's visibility and placement are independent of these settings.
Manual QuestFrame narration cancels any pending automatic request and starts
immediately. Quest Log retains its explicit-click path, never consults the delay,
and starts immediately.

Check the default-off state, slider layout and disabled state, 0.5-second steps,
seconds formatting, default delay and persistence after reload in-game. Verify
all three automatic page reads with zero and nonzero delays in both modes,
NPC/player fallback, cancellation on close/page change/disable/replacement, and
immediate manual QuestFrame and Quest Log reads without a later duplicate.

### Quest Log player narration

`OutLoud.UI.QuestLogIntegration` uses the actual shared layout loaded for
Forever/Camelot by `Blizzard_UIPanels_Game.toc`: `Mainline/QuestMapFrame.xml`
and `.lua`, with `Camelot/QuestMapFrameOverrides.lua` and
`Camelot/QuestMapFrameUtils.lua`. These files are under
`DevResources/BlizzardInterfaceCode/Interface/AddOns/Blizzard_UIPanels_Game/`.
`Blizzard_WorldMap/QuestLogOwnerMixin.lua` supplies the parent map/log lifecycle.

The frame is `QuestMapFrame`, whose `DetailsFrame` aliases
`QuestMapFrame.QuestsFrame.DetailsFrame`. `DetailsFrame.BackFrame.BackButton`
is Blizzard's **Back** control. Out Loud creates a sibling button in `BackFrame`,
mirrors Back's left inset at the right edge, and uses the same vertical offset
and button size. The exported Back anchor is `LEFT`, inset 11, offset Y 4.
Neither the native button nor the quest description scroll child is modified.

Visibility requires the log and description detail viewport to be visible,
a positive selected quest ID matching `DetailsFrame.questID`, a valid log index,
and a nonempty description. `HookScript` follows the existing frame events and
show/hide handlers. Post-hooks on `QuestMapFrame_ShowQuestDetails` and
`QuestMapFrame_CloseQuestDetails` also cover quest switching and returning Back.
Initialization waits on `ADDON_LOADED` if the native UI has not loaded;
there is no polling or forced Blizzard addon loading.

Every click rereads `C_QuestLog.GetSelectedQuest()`, resolves its log index with
`C_QuestLog.GetLogIndexForQuestID()`, then obtains only the first return value of
`GetQuestLogQuestText(questIndex)`. Objectives are never submitted. It resolves
the player's configured voice with `VoiceSelection:ResolvePlayer()` and captures
`C_QuestLog.GetTitleForQuestID(questID)` using the same validated ID as the description.
It calls `OutLoud.Narration:Speak("player", description, voiceID, displayTitle)`.
Later selection changes cannot replace the active narration's title.

Explicit player token mappings are:

| Race token | Voice Family |
| --- | --- |
| `Human` | `HUMAN` |
| `Orc` | `ORC` |
| `Dwarf` | `DWARF` |
| `NightElf` | `NIGHT_ELF` |
| `Scourge` | `UNDEAD` |
| `Tauren` | `TAUREN` |
| `Gnome` | `GNOME` |
| `Troll` | `TROLL` |
| `BloodElf` | `BLOOD_ELF` |
| `Draenei` | `DRAENEI` |
| `Goblin` | `GOBLIN` |

No speculative Forever/custom race aliases, including a player token for
`SKYBORNE`, are added. Gender remains `UnitSex("player")`: 2 Male, 3 Female.

Both entry points share one presentation ownership token in `OutLoud.Narration`.
It forwards the existing end, playback-start, and text-progress callbacks from
`TTS:Speak()` to the same Talking Head. New narration replaces ownership before
TTS cancels the previous session, so a stale callback cannot hide the new speaker.
Both reading modes, loading, sentence fades, paged scrolling, and close/cancel
behavior remain in their existing services. Closing the Quest Log only hides
its button; narration can continue.

Button placement/visibility, player rendering and voice tokens, description-only
audio in both modes, and replacement between QuestFrame and Quest Log narration
require in-game verification.

### Gossip narration

`OutLoud.UI.GossipIntegration` adds one persistent 100 by 22
`UIPanelButtonTemplate` button parented to the standard `GossipFrame`. Its anchor
is `RIGHT` to `GossipFrame.GreetingPanel.GoodbyeButton`, `LEFT`, offset `-8, 0`.
The native Goodbye button, scroll box, gossip options and quest lists are unchanged.
The Out Loud button hides when the frame/greeting panel closes, Goodbye is hidden,
or the current gossip text is empty, invalid or unavailable.

The local Forever export loads `Shared/GossipFrameShared.lua` and
`Mainline/GossipFrame.lua`/`.xml` through `Blizzard_UIPanels_Game.toc`.
`GossipFrameSharedMixin:Update()` inserts `C_GossipInfo.GetText()` as the greeting
before inserting separate quest and option entries. `GossipInfoDocumentation.lua`
also declares this API. Out Loud reads only `C_GossipInfo.GetText()` at the click;
it never extracts option labels, player responses or quest-list text.

`Mainline/CustomGossipFrameBase.lua` routes `GOSSIP_SHOW` and `GOSSIP_CLOSED`
through `CustomGossipFrameManager` to the standard frame's `HandleShow()` and
`HandleHide()`. `HandleShow()` calls `Update()`. Out Loud installs a post-hook on
the frame's `Update()` method, plus show/hide hooks on the frame, greeting panel
and Goodbye. These hooks only refresh visibility, including page changes with
the frame already open. There are no extra gossip-event registrations, polling,
automatic narration triggers or model-loading timers. Initialization uses one
guarded `ADDON_LOADED` observer if the native layout is absent, without force-loading UI.

`Core/NPCInspection.lua` retains one unparented, unhidden PlayerModel.
`GetModel()` creates it once; `LoadUnit(unit)` clears the previous model and calls
`SetUnit(unit)` before returning it. Gossip can initialize and read before
QuestFrame exists. QuestIntegration retains an alias to this same frame and uses
the same load helper for `"questnpc"`; gossip uses `"npc"`. Talking Head's portrait
model remains separate. A failed/unready model uses the existing player fallback,
without guessing a previous model or delaying speech.

On each manual click, gossip captures current text and the NPC name. Single Voice
uses `VoiceSelection:ResolvePlayer()` to select the configured narrator without
requiring NPC model/family/gender readiness; it displays the player model and NPC
name. Multiple Voices loads `"npc"` and calls `VoiceSelection:Resolve("npc", model)`:
FileDataID selects the generated Voice Family and `UnitSex("npc")` selects gender.
It never calls `UnitRace("npc")`. Failed NPC resolution uses the player's model
and configured voice while retaining the captured NPC name. A missing NPC name
uses `Unknown`; an unusable player/narrator voice stops the request.

`Narration:Speak()` receives the original text and captured title, so later gossip
pages cannot change an active display. The existing TTS dispatcher handles Full
and Split modes, rate, sanitization, XML escaping, ownership and replacement.
Closing GossipFrame hides its button and prevents another read; as with QuestFrame,
it does not stop an existing narration. Subsequent reads recapture identity/text
and clear the shared inspection model before loading. Starting manual gossip
speech also cancels a pending automatic quest request through the existing TTS
`StartSession` hook. Opening or updating gossip never starts speech.

Source inspection establishes the API/layout and routed lifecycle above. The user
reported in-game `"npc"` availability, name, sex, `SetUnit("npc")` and a valid model
ID for Daniel (`1011653`, `HUMAN`). Greeting retrieval, new button placement,
actual hook/event order, immediate readiness when switching quest/gossip NPCs,
portrait/title rendering, audio/bookmarks and scrolling remain unverified in-game.
Check both voice modes and reading modes, empty greeting/options-only pages,
repeated clicks, NPC/page changes, close/reopen, fallback, and Gossip-before-QuestFrame
loading. Repeat with automatic quest narration enabled to confirm gossip stays manual.

### Talking Head visual animations

`UI/TalkingHead.xml` defines an independent `OutLoudTalkingHeadTemplate`, using
the hierarchy, fonts, decorative atlases, and native animation definitions from
the local export at
`DevResources/BlizzardInterfaceCode/Interface/AddOns/Blizzard_FrameXML/TalkingHeadUI.xml`
and sequencing from the adjacent `TalkingHeadUI.lua`. Out Loud does not instantiate
Blizzard's live `TalkingHeadFrame` or attach its conversation/model mixins.
The root retains size 570 by 155 and scale 1.05. It is centered horizontally,
anchored to `UIParent`'s top with a Y offset of -60, on the `BACKGROUND` strata.
Faction atlas selection and `PlayerModel:SetUnit(unit)` remain unchanged; name
colors, text styling, and internal text anchors follow the Blizzard reference.

The root stays at alpha 1. Animated regions reset to alpha 0.01, including the
portrait backdrop, which now belongs to the model as in Blizzard's hierarchy.
`Fadein` and `TalkingHeadsInAnim` use these timings in seconds:

| Element | Start delay | Fade duration |
| --- | --- | --- |
| Portrait frame, model, model backdrop | 0 | 0.75 |
| Text background | 0.4 | 0.75 |
| Name | 0.5 | 0.25 |
| Dialogue text | 0.75 | 0.25 |
| Close button | 0.75 | 0.75 |

The name/text delays encode the offsets from Blizzard's `FadeinFrames()` timers
directly in animation groups, so stopping a group cancels pending fades too.
All animations use order 1 and retain Blizzard's `setToFinalAlpha` behavior.
Decorative alpha peaks at 0.7 and returns to 0:

- Top glow: starts at 0.15, fades in over 0.25 and out at 0.4 over 0.5;
  horizontal scale grows from 0.25 to 1.5 over 0.25.
- Side glows: start at 0.35, fade in over 0.25, translate down 10 units over
  0.8, and scale vertically from 0.5 to 1.6 over 0.7 with a top origin.
  Left fades out at 0.85 and right at 0.95, each over 0.25.
- Name sheen: starts at 0.5, fades in over 0.5 and out at 1 over 0.5;
  horizontal scale grows from 0.25 to 1 over 0.25 with a left origin.
- Text sheen: starts at 0.75, fades in over 0.5 and out at 1.25 over 0.5;
  the same scale animation lasts 0.25 with a left origin.

`Hide()` stops entrance effects and runs the five Blizzard-style `Close` groups,
which fade the model/backdrop, portrait, background, name, text, and close button
from 1 to 0 over one second. The main close group's completion hides the root.
Repeated Hide calls keep the running exit; Show stops all groups, resets alpha
and animation transforms, replaces the NPC/text, and starts a fresh entrance.
Unused name/text `Fadeout` groups have been removed; Out Loud does not perform
Blizzard's automatic conversation-line transitions.
Conversation timers, sound playback, and model animation kits requiring
`C_TalkingHead` are deliberately excluded.

The spinner stays outside these animation groups and remains controlled by
`SetLoading()`. The close button still cancels speech immediately; animations
affect only presentation. In-game checks are required for native XML/template
loading, fonts/atlases, model/backdrop opacity, movement, and interrupted reuse.

### Speaker model idle pose

The shared Talking Head uses `PlayerModel:SetAnimation(0, 0)` after loading either
the NPC or player, and on playback finish/cancellation and close. Playback does
not start model gestures or animation timers. The randomized conversation
controller, its completion callbacks, and its state have been removed.
Blizzard-style frame animations, sentence transitions, scrolling, and loading
remain independent and unchanged. Verify the default idle pose on NPC/player
models in-game.

### Playback-following text viewport

`TextFrame.Scroll` clips a scroll-child FontString inside the original dialogue
bounds, with the existing font and color and a narrow scrollbar gutter. The
Blizzard text-fit mixin is omitted here so overflow scrolls at the existing font
size instead of shrinking the text. The entrance/exit groups still animate only
their original targets; their dialogue target now resolves through
`Scroll.Content.Text`. The text sheen anchors to
the fixed viewport, so it does not move with the scroll content.

Full mode prepares all text before the entrance and never replaces it during
playback. Split mode prepares the first sentence using `TTS:SplitSentences()`.
Quest integration forwards the fifth TTS callback only while its existing
presentation ownership token is current. Sentence ownership notifications change
the display; prefetch submissions do not. Later changes use native `SentenceOut`
and `SentenceIn` alpha groups, each lasting 0.08 seconds. The new sentence replaces
the old text between them and resets scrolling. These groups do not animate the
portrait, name, background, close button, or spinner. A rapid new sentence replaces
the pending display rather than starting an obsolete transition.

The existing current-session ownership callback starts UI auto-scroll, once for
full text or for each active split sentence after its fade swaps the text.
In `UI/TalkingHead.lua`, `INITIAL_SCROLL_DELAY = 10` waits ten seconds before the
first page moves. `SCROLL_PAGE_FACTOR = 1.0` sets each page distance to one viewport
height, and `SCROLL_SPEED = 18` moves it at eighteen UI pixels per second. Between
pages, `SCROLL_PAUSE = 10` waits another ten seconds. A cancellable timer owns
each wait; its callback checks timer identity and current display state before
starting movement. One `OnUpdate` handler advances the native vertical scroll
offset only while a page is moving. Scrollbar updates disable native interpolation
so it does not introduce a second movement controller. There is no text Translation
animation or compensating FontString-anchor movement. Motion stops at the bottom
or when playback ends, text changes, or Talking Head hides. This fixed UI speed
does not estimate audio duration or follow individual words; no word-level or
intra-sentence UI bookmarks are inserted into speech.

Blizzard's native `MinimalScrollBar` sits beside the clipped viewport, clear of
the close button and spinner, and hides when text fits. Its ends are inset from
the dialogue bounds and its native track has compact arrow gaps suitable for this
short viewport. Its visible extent and
scroll percentage follow the text layout and viewport position. Thumb dragging,
native scrollbar controls, and mouse-wheel input over the viewport pause auto-scroll
for the current text. A new narration or split sentence enables it again.
Programmatic scrollbar updates are guarded because native `SetScrollPercentage`
also emits `OnScroll`; they cannot be mistaken for manual input or recurse.
All scroll positions are clamped to the measured vertical overflow.

New narration and displayed sentences reset to the top. Finish stops text motion
and retains the final text at its current position during the existing closing
sequence.
Cancellation stops pending fades/motion and resets to the top. Hide stops updates
immediately, then resets the scroll position when the visual exit finishes;
Show during that exit cancels it and resets immediately. Existing quest integration
still closes Talking Head when narration ends. Loading and TTS cancellation are
unchanged. Scrollbar placement/dragging, scrolling speed, text clipping, sentence
transitions, and cancellation/reuse need visual in-game verification.

Missing text produces no new Talking Head presentation or speech. In Race & Gender mode, NPC resolution
failure uses the player's configured voice and `"player"` Talking Head model/name;
there is no generic default voice. If player resolution also fails, a red error
is shown and no new narration starts. The inspection model is cleared before
each NPC load to prevent reuse of the previous NPC's FileDataID. An asynchronous
load returning `model-unavailable` immediately takes the player fallback;
there is no model-loading retry timer or fallback loop. Normal NPC narration,
item/no-NPC quests, both reading modes, and failed player resolution require
in-game verification.

For voice assignment verification in-game, open Options and switch between
Single Voice and Race & Gender. Confirm the selected radio, disabled dropdowns
and steppers, retained selections, and scroll layout after reopening and `/reload`.
In Single Voice, try a mapped NPC, an unmapped NPC with a usable model, an item
quest without an NPC, and Quest Log narration. Check portrait/name independently
of voice in both full and split modes, including automatic narration with its
configured delay. Clear Narrator Voice and confirm a graceful error without
speech. Changing mode during playback should leave that session running.

### Narration diagnostics

Normal narration is silent in chat. Failed reads, caught button errors, native
`SpeakText` errors, owned playback failures, and session-end callback errors use
`OutLoud:Error(...)` to print a red `[Out Loud]` message. Stopping or finishing
narration normally does not print an error. Unidentified playback failures do
not produce an error message because they may belong to unrelated TTS.

Enable detailed diagnostics for the current login with this Toolbox Console command:

```lua
OutLoud.DebugEnabled = true
```

These optional diagnostics include voice resolution, submission, bookmarks, and
session state. Set the flag to `false` to disable them. It is not saved; a UI
reload disables routine diagnostics again. Error messages remain enabled.

### Blizzard source reference and verification limits

Implementation was checked against the exported `forever` branch at commit
`15666a6e67938a1ab5caf041406464251db111ca`, labelled **1.60.1 (70245)**:

- [Vanilla QuestFrame.xml](https://github.com/Gethe/wow-ui-source/blob/15666a6e67938a1ab5caf041406464251db111ca/Interface/AddOns/Blizzard_UIPanels_Game/Vanilla/QuestFrame.xml)
  declares the four panels, native button template, and action-button anchors.
- [QuestFrame handlers in the export](https://github.com/Gethe/wow-ui-source/blob/15666a6e67938a1ab5caf041406464251db111ca/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/QuestFrame.lua)
  show the event/panel transitions and `GetProgressText()` source.
- [Vanilla QuestInfo.lua](https://github.com/Gethe/wow-ui-source/blob/15666a6e67938a1ab5caf041406464251db111ca/Interface/AddOns/Blizzard_UIPanels_Game/Vanilla/QuestInfo.lua)
  uses `GetQuestText()` for live dialogue and `GetRewardText()` for rewards.
- [SimpleModel API export](https://github.com/Gethe/wow-ui-source/blob/15666a6e67938a1ab5caf041406464251db111ca/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleModelAPIDocumentation.lua)
  includes `ClearModel()` and `GetModelFileID()`.

The user subsequently verified all three text sources directly in WoW: Forever:
`GetQuestText()` returned the visible offer dialogue for Shadow Priest Sarvis;
`GetProgressText()` and `GetRewardText()` returned the visible progress and final
reward dialogue. The existing resolver was also verified for Junior Apothecary
Holland: model `959310`, family `UNDEAD`, `UnitSex = 2`, configured voice `1`.
These user-reported checks establish the API choices, not the full integration.

The source export remains the reference for frame names and hooks. The export's
game/family file selection, actual panel/event behavior, template layout,
immediate reusable PlayerModel readiness, Talking Head portrait/name/text rendering,
spinner behavior, and actual audio in the combined click flow still require
verification in WoW: Forever. No in-game execution was performed by the agent.

### In-game QuestFrame checklist

Select Multiple Voices and configure the NPC's family/gender voice first, then:

1. Open an NPC quest greeting/list: button hidden.
2. Select a quest offer/detail: button visible without overlapping native controls.
3. Click Out Loud: current offer dialogue uses the configured NPC voice and chosen
   reading mode. Talking Head shows the NPC portrait/name and exact
   `GetQuestText()` result, with loading on before submission. Click again to
   check presentation update and narration restart.
4. Return to an incomplete/in-progress quest with dialogue: button visible;
   clicking displays and narrates the exact `GetProgressText()` result.
5. Turn in a completed quest: button visible for concrete progress/turn-in text.
6. Advance to completion/reward: button visible; clicking displays and narrates
   the exact `GetRewardText()` result.
7. Close QuestFrame: button disappears.
8. Return to greeting/list: button hidden again.

Repeat the three dialogue-page click checks in both **Split text** and
**Read full text** Options modes. Both modes should use the same configured voice
and speaker, while Talking Head displays full text or the current sentence
according to the mode. Talking Head closes
and clears its spinner after the full text or final streamed sentence finishes.
Click again during narration to check that restarting keeps the new presentation
visible. Closing Talking Head stops narration; calling `OutLoud.TTS:Stop()` also
closes the presentation. With an unset NPC voice or an unavailable/unmapped model,
clicking should use the configured player voice and player portrait/name for the
same dialogue. Check an item quest with no `questnpc` as well. If player resolution
also fails, no new presentation or speech should start and a red error should
explain the failure.

For the quest-title presentation change, repeat Detail, Progress, and Reward with
Single Voice and confirm the player model plus current quest title for manual and
automatic narration. Check Quest Log in both assignment modes. In Full and Split,
verify the title through loading, sentence transitions, and completion; switch quest
selection during playback and confirm it stays captured. Check long titles for
clipping and missing titles for the generic `"Quest"` fallback. This presentation
change was source-inspected only; no automated tests were added or run for it.

### Inspect the current quest NPC

With a quest dialog open, run this Lua command in Toolbox Console. It uses a
separate model and prints once after a short loading delay. If the reason is
`model-unavailable`, rerun after the model loads. The delay belongs only to this
inspection command, not the speech controller.

```lua
local model = CreateFrame("PlayerModel")
model:SetUnit("questnpc")
C_Timer.After(0.5, function()
    local voice, info = OutLoud.VoiceSelection:Resolve("questnpc", model)
    print("NPC:", tostring(info.name), "ModelFileID:", tostring(info.modelFileID),
        "Family:", tostring(info.family), "UnitSex:", tostring(info.sex),
        "Gender:", info.gender or "UNKNOWN", "Voice:", tostring(voice),
        "Reason:", info.reason or "resolved")
end)
```

### Test speech directly

Run one Toolbox Console line at a time, replacing `voiceID` with your supplied
numeric WoW TTS voice ID:

```lua
OutLoud.TTS:SpeakStreaming("First sentence. Second sentence. Third sentence.", voiceID)
OutLoud.TTS:SpeakWholeText("First sentence. Second sentence. Third sentence.", voiceID)
OutLoud.TTS:Speak("First sentence. Second sentence. Third sentence.", voiceID)
OutLoud.TTS:Stop()
```
