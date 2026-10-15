# AGENTS.md

## Project

This repository contains **Out Loud**, a World of Warcraft: Forever addon in development for quest text-to-speech narration.

The addon is built around these responsibilities:

- quest text acquisition and narration flow
- NPC visual model detection
- Voice Family resolution from model FileDataID
- runtime gender detection through `UnitSex(unit)`
- user-configurable Male/Female voices per Voice Family
- text-to-speech playback through the WoW TTS API
- sentence-streamed Split Text narration
- a custom Blizzard-style Talking Head UI

Follow the existing project architecture and conventions. Do not introduce a new architecture unless explicitly requested.

---

## Core Development Rules

### Inspect before changing

Before modifying code:

1. Inspect the existing implementation.
2. Identify the real dependency path.
3. Reuse existing modules, namespaces, settings, helpers, and conventions.
4. Change only what is necessary for the requested task.

Do not mechanically implement assumptions from a task description when the repository already contains an established implementation.

Do not refactor unrelated code.

### Do not guess WoW behavior

World of Warcraft: Forever may differ from Retail or other WoW versions.

Do not assume Blizzard API behavior from memory when the task depends on runtime details.

Clearly distinguish between:

- behavior proven by standalone tests
- behavior previously verified in-game
- behavior inferred from Blizzard APIs/source
- behavior that still requires in-game verification

If something cannot be verified outside the game client, say so.

Do not present mocked or standalone Lua tests as proof that WoW runtime behavior works.

### In-game verification

The following generally require an actual in-game check:

- Blizzard event behavior and ordering
- `questnpc` availability
- PlayerModel loading/readiness
- model FileDataID retrieval
- `UnitSex(unit)`
- QuestFrame state and layout
- Blizzard templates and atlases
- Talking Head rendering
- TTS playback
- TTS bookmark timing
- native TTS voice availability
- interaction with Blizzard UI

Standalone tests may validate Out Loud's own logic but do not replace in-game verification.

---

## Architecture Boundaries

Keep responsibilities separated.

### Voice mappings

`Data/VoiceMappings.lua` is generated data.

Its runtime responsibility is conceptually:

`FileDataID -> Voice Family`

Do not add runtime gender information to generated model mappings.

Do not manually maintain generated mappings when the correct fix belongs in the generator.

Voice Families are addon identities and are not necessarily equivalent to DB2 RaceIDs.

Multiple DB2 races or model IDs may intentionally resolve to one Voice Family.

Example:

- High Order Skyborne -> `SKYBORNE`
- Windshaper Skyborne -> `SKYBORNE`

Do not create speculative family aliases without explicit requirements.

### Gender

Runtime gender comes from:

`UnitSex(unit)`

Relevant WoW runtime values:

- `2` = Male
- `3` = Female
- `1`, `nil`, or unexpected values = unresolved

Do not derive runtime gender from model FileDataID.

Do not use DB2 SexID as the runtime gender source.

Do not silently fall back unknown gender to Male or Female.

### Voice selection

Voice selection follows:

`NPC model -> FileDataID -> Voice Family`

and independently:

`UnitSex(unit) -> Gender`

then:

`Voice Family + Gender -> configured voice`

The current settings identity is conceptually:

`OutLoudDB.voices[family][sex]`

Do not assume a Voice Family has a numeric DB2 RaceID.

Do not create one Options row per model.

Options should expose one family with separate Male and Female voice selectors.

### TTS

The TTS controller receives:

- text
- an already-resolved WoW TTS voice ID

It should not own:

- quest extraction
- NPC classification
- Voice Family resolution

unless the existing architecture explicitly requires it.

Keep the existing public speech responsibilities separated:

- sentence streaming
- the shared speech entry point
- stop/cancel

Do not add artificial delays unless in-game testing proves they are necessary.

Preserve the intentional, manually validated 0.5-second narration submission delay
measured from Talking Head opening start. This belongs to Narration, not sentence
streaming inside the TTS controller.

### Sentence streaming

The tested streaming behavior is:

- normalize whitespace
- split on `.`, `!`, `?`
- submit the first sentence immediately when the TTS controller is called
- use playback bookmarks to identify the active sentence
- prefetch exactly one sentence ahead
- do not queue all sentences at once
- do not use artificial timers
- protect against stale/cancelled sessions
- prevent duplicate sentence submission

Preserve this behavior unless a change is explicitly requested and then verified in-game.
The timer-free streaming path starts after Narration's intentional 0.5-second gate.

### Quest integration

Quest-specific code should own:

- quest-state detection
- quest text extraction
- determining the speaking NPC/unit
- deciding when Out Loud controls are visible
- calling VoiceSelection
- passing captured narration data to the shared Narration coordinator

The shared Narration coordinator owns request replacement, Talking Head lifecycle
coordination, delayed TTS submission, and presentation callback ownership.

Do not move quest-specific logic into generic TTS modules.

### Talking Head UI

The custom Talking Head is Out Loud's own UI.

Do not use Blizzard's live `TalkingHeadFrame` or `C_TalkingHead` as the implementation.

The current UI intentionally reproduces Blizzard's Talking Head appearance using native Blizzard atlases and a custom `PlayerModel`.

Preserve the tested visual implementation unless a redesign is explicitly requested.

### Loading spinner

Use Blizzard's native `LoadingSpinnerTemplate`.

Do not replace it with a custom animation unless explicitly requested.

---

## QuestFrame Integration

Out Loud controls should only be shown where relevant quest dialogue text is available.

Do not assume that every visible `QuestFrame` state contains narration text.

Relevant states may include:

- quest offer/detail
- quest progress/turn-in
- quest completion/reward

Quest greeting/list-only states should generally not show narration controls.

Before implementing permanent hooks, verify the actual World of Warcraft: Forever QuestFrame behavior and events in-game.

Do not assume Retail event/layout behavior without verification.

---

## Generated Data

Treat generated files as generated artifacts.

If data is produced by an external generator:

- do not hand-edit generated mappings as a permanent fix
- do not add manual fallback rows to generated output
- fix the generator or runtime consumer instead
- keep generated output deterministic
- preserve the generator/runtime contract

For `VoiceMappings.lua`:

- families are string identities
- model entries map directly to families
- gender is not stored in model mappings
- model ambiguity must not be guessed
- multiple model IDs may share one family

---

## SavedVariables

Preserve existing user settings unless a migration is actually required.

Do not silently reset SavedVariables because the internal representation changes.

When changing the settings schema:

- inspect the existing migration logic
- preserve existing assignments where possible
- never overwrite a newer user value with migrated legacy data
- avoid repeated migrations
- do not add migration complexity unless needed

Do not change existing SavedVariables keys unnecessarily.

---

## Blizzard API Verification

Prefer verified APIs already proven in this project.

Known tested behavior includes:

- `questnpc` is usable as a UnitToken while appropriate quest dialogue is open
- `UnitSex("questnpc")` works
- `PlayerModel:SetUnit(unit)` works
- `PlayerModel:GetModelFileID()` returns the NPC model FileDataID
- `LoadingSpinnerTemplate` works in WoW: Forever

Do not replace known working paths with speculative alternatives.

If a new Blizzard API is needed:

1. inspect available source/documentation where possible
2. after explicit user approval, create the smallest possible in-game test
3. verify it in WoW: Forever
4. only then integrate it into production code

---

## Testing

### Approval and scope

Do not automatically create or execute tests without explicit user approval.
When tests have not been requested, prefer source inspection and logical code review.

Do not build simulated World of Warcraft environments as substitutes for the real
client. Mocked Blizzard APIs, events, frames, animations, and native TTS are not
authoritative runtime behavior. Actual WoW behavior must be verified in the game client.

Isolated pure Lua logic tests are acceptable when explicitly requested and their
scope is clear. Useful subjects include sentence splitting, settings normalization,
voice-family lookup, speech forwarding, and controller predicates/state management.
Exercise production modules where practical rather than duplicate their logic.
Minimal supplied inputs or API doubles may isolate those checks; they must not
simulate a client, native queue, or authoritative event ordering.

### What tests do not prove

A passing mocked test does not prove:

- Blizzard emitted an event
- Blizzard emitted events in the expected order
- a template exists in Forever
- a model loaded successfully
- actual sound played
- bookmark timing behaved as expected
- QuestFrame positioning is correct

When reporting results, explicitly separate:

`standalone/mock verification passed`

from:

`in-game verification passed`

Never describe the former as the latter.

### Test scope

Do not create elaborate test infrastructure for trivial changes.

Do not add tests merely to inflate assertion counts.

When tests are explicitly requested, focus on meaningful logic likely to regress.

### Diagnostic retention

Keep `Core/TTSDiagnostics.lua` and its TOC entry unless the user explicitly approves
their removal. Successful lifecycle testing does not make native TTS diagnostics
obsolete. Historical temporary/removal wording in runtime comments is not permission
to remove the recorder, diagnostics, or playback safeguards.

---

## Toolbox Console Tests

When providing an in-game Toolbox Console script:

- make it fully standalone
- assume the user will copy and run the entire script
- do not provide fragments that depend on locals from previous runs
- clean up temporary globals/frames where appropriate
- keep diagnostic output focused on the thing being tested
- do not permanently modify production addon state unless explicitly required

Temporary test code must not be committed into production modules.

---

## Documentation

### README.md

`README.md` is primarily the main project/addon overview.

It should explain:

- what Out Loud is
- what it currently does
- major features
- how voice selection works at a high level
- sentence-streamed narration
- current project status
- major components at a high level

Do not turn README into an internal debug log or test manual.

Do not place long Toolbox scripts, mock-test details, migration internals, bookmark internals, or low-level implementation edge cases in the main README.

### docs/DEVELOPMENT.md

Put developer-focused material here, including:

- test commands
- Toolbox Console diagnostic scripts
- internal APIs
- implementation details
- session/bookmark behavior
- SavedVariables migrations
- known technical limitations
- mocked-vs-in-game verification notes

### Documentation accuracy

Do not document planned functionality as completed.

Before updating documentation, inspect the current source and distinguish:

- implemented
- integrated
- tested with mocks
- verified in-game
- planned

Do not remove useful technical documentation merely because it does not belong in README; move it to an appropriate developer document.

---

## Code Style

Follow the existing Out Loud Lua style and namespace conventions.

Prefer existing singleton/module patterns under:

`OutLoud`

Do not introduce global variables unless Blizzard requires a named global frame/template.

Avoid unnecessary globals.

Keep functions focused.

Prefer early returns for invalid states.

Do not add noisy `print()` calls to production code.

Use the project's existing debug/logging mechanism if one exists and logging is genuinely needed.

Do not leave temporary diagnostic timing code in production.

---

## Scope Control

For every task:

- make the smallest correct change
- do not redesign unrelated systems
- do not rename unrelated APIs
- do not reformat unrelated files
- do not change UI styling unless requested
- do not change SavedVariables unless required
- do not modify generated data manually unless explicitly requested
- do not touch native TTS/SAPI components from an addon-only task

If a requested change exposes a separate problem, report it instead of silently expanding the task.

---

## Native TTS / SAPI Boundary

Out Loud may interact with separately developed native TTS components, but addon work must not alter their deployment or registration unless explicitly requested.

In particular:

- do not register or unregister the SAPI DLL automatically
- do not add automatic registration to scripts
- do not run registration/unregistration as part of tests
- do not assume it is safe to replace or register DLLs while World of Warcraft is running

DLL/SAPI registration is performed manually by the user.

If registration scripts are modified in a related project, they should provide clear visible progress and verification output, but they must not be executed automatically.

---

## Completion Reports

After implementing a task, report only relevant facts.

Include as applicable:

- files created
- files modified
- behavior changed
- tests run
- test result
- whether in-game verification is still required
- exact remaining limitation or unresolved decision

Do not claim something was verified in-game unless it actually was.

Do not bury unresolved issues behind a successful mock-test count.

---

## Important Existing Design Decisions

Preserve these unless explicitly changed:

- Voice Family is separate from DB2 RaceID.
- Runtime gender comes from `UnitSex(unit)`.
- Generated model mappings do not contain gender.
- Multiple models may share one Voice Family.
- `SKYBORNE` is one shared Voice Family.
- Options provides Male and Female voice selection per Voice Family.
- Split Text sentence streaming is the only supported reading mode.
- Sentence streaming prefetches exactly one sentence ahead.
- No artificial delay is used inside the tested sentence-streaming path.
- Narration submits TTS 0.5 seconds after Talking Head opening begins; preserve this manually validated delay.
- Talking Head is custom Out Loud UI using Blizzard-style assets.
- Native SAPI registration remains manual.
- WoW-dependent behavior requires in-game verification.

When uncertain, preserve existing working behavior and report the uncertainty instead of inventing a solution.
