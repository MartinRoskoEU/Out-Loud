# Out Loud

Out Loud is a World of Warcraft: Forever addon in development for reading quest
and NPC gossip text, books, letters, scrolls, and other readable items aloud with
configurable voices.

## Overview

Out Loud can use one narrator voice for all speech or choose a configured voice
from the speaker's family and runtime gender. A Blizzard-style Talking Head shows the speaker and dialogue
while speech is generated and played.

Manual Out Loud buttons connect current quest and gossip dialogue to the NPC's voice, or
selected Quest Log descriptions to the player's voice, Talking Head, and speech.
QuestFrame and readable-item narration can also start automatically when enabled in Options;
Quest Log and gossip narration remain manual. Talking Head closes when narration ends,
and the loading spinner clears when owned playback begins.

## Current Features

- Options UI with Single Voice and Multiple Voices assignment modes, plus saved
  Male and Female voice assignments for each Voice Family.
- Generated mappings from NPC model FileDataIDs to Voice Families.
- A runtime voice resolver that combines the model family with `UnitSex(unit)`
  and returns the configured voice.
- A custom Talking Head UI with a speaker portrait, name, dialogue text, faction
  styling, opening/closing fades, a close button that stops narration, and a
  controllable loading spinner.
- A speech controller that accepts supplied text and a WoW TTS voice ID,
  streams sentences and can cancel narration.
- Optional automatic narration for quest offer, progress, and reward pages,
  disabled by default. Manual buttons remain available.
- A manual **Out Loud** button for quest offer, progress, and reward dialogue.
  Single Voice shows the player portrait and quest title. Multiple Voices uses
  the NPC portrait/name, with the existing player fallback, and reads the same dialogue.
  Talking Head closes when narration finishes or stops.
  The button hides on quest greeting/list screens and when the quest window closes.
- A manual **Out Loud** button opposite **Back** in selected Quest Log details.
  It reads the description using the player's portrait, the selected quest title, and configured
  voice. Gameplay objectives are excluded.
- A manual **Out Loud** button beside **Goodbye** in the standard GossipFrame.
  It reads the current NPC greeting, excluding options and quest lists. Single
  Voice shows the player portrait with the NPC name; Multiple Voices uses the NPC
  portrait and family/gender voice, with the existing player narrator fallback.
- An **Out Loud** button near the bottom-right of readable item pages. It uses
  the player's configured voice and reads from the displayed page onward. Each
  page finishes before the addon turns to the next; manual Next/Prev navigation
  switches narration to the selected page. Closing the item stops its narration.

## How Voice Selection Works

**Single Voice** uses the selected Narrator Voice for NPC, player, automatic,
and Quest Log narration. Talking Head shows the player model, with the quest
title for quest sources and the NPC name for gossip. An unset or unavailable narrator voice stops narration
with an error. Quest Log also shows the player model and quest title when using
Multiple Voices. Readable items always show the player model and item title.

**Multiple Voices** is the default and preserves the existing resolution and
player fallback. The resolver reads two independent properties of the NPC:

```text
NPC visual model -> Model FileDataID -> Voice Family
NPC UnitSex      -> Male / Female
```

It combines the family and gender to choose the configured voice for that family.
Gender comes from the live NPC, rather than the model mapping.

If QuestFrame or GossipFrame cannot resolve a usable NPC voice, the player reads
the same dialogue using their configured race and gender voice.

Quest Log narration uses the player's race and runtime gender to select from the
same Voice Family assignments. Unmapped races and unset voices produce an error
instead of selecting a fallback voice.

Multiple model IDs can share one Voice Family and the same voice configuration.
For example, the two Skyborne model IDs in the Forever mapping both use
`SKYBORNE`, with separate Male and Female voice choices.

## Voice Configuration

The **Voice Assignment** radio group selects **Single Voice** or **Multiple Voices**.
The Narrator Voice selector and the existing family rows remain visible. Only the
active mode's selectors can be used; the other controls appear disabled.
Switching modes preserves both sets of assignments and leaves current playback running.

Each family row provides separate Male and Female selectors. All selectors list
the same TTS voices available to the game and include a **Not set** option.
Unavailable selections are indicated without erasing the stored setting.

Available families come from generated mapping data. Each unique family appears
once, regardless of how many models use it. Assignments are saved between sessions.

## Narration

**Split Text** is the only supported reading mode. It reads sentence by sentence,
submitting the first sentence as Talking Head starts opening and
prefetching one sentence ahead as playback begins.

Talking Head displays the currently spoken sentence. Sentence changes use a brief
fade shared by the text and its scrollbar.
Overflowing text scrolls gently once playback begins and has a scrollbar for
manual reading. Scrolling manually pauses automatic movement for that text.

All Out Loud narration buttons use Split Text. Each valid request captures its
dialogue and voice; later quest navigation does not cancel it. Speech is submitted
immediately when Talking Head starts opening. Clicking again stops speech
immediately, finishes closing, then opens the latest requested dialogue.

Enable **Automatically read quest and item text** in the same section to start
narration when quest details, progress, reward pages, or readable items open. It
defaults to off and does not apply to Quest Log or gossip. **Automatic narration
delay** waits before automatically opening Talking Head for quests and readable
items, starting when their text is ready. It defaults to 2 seconds, adjustable
from 0 to 5 seconds in 0.5-second steps. Manual requests skip this delay; item page
continuation adds no extra delay. All use the same Talking Head opening/closing lifecycle.

**Speech Rate** adjusts narration speed from -10 (Slower) to +10 (Faster) in
integer steps. The default is 0 (Normal), restored with **Reset to 0**. It is
available regardless of automatic narration and affects subsequent speech
requests without restarting current playback.

## Project Status

The mappings, saved voice configuration, voice resolver, Talking Head UI, TTS
controller, manual QuestFrame, Quest Log and GossipFrame narration, and optional automatic
QuestFrame narration are implemented. Readable-item narration is also integrated;
its button placement, native navigation hooks, and page-to-page audio lifecycle
still require in-game verification. The underlying ItemText APIs have been
verified by the user with single-page items and an eight-page book.
The user has manually tested the current snapshot-based Talking Head lifecycle
successfully in WoW: Forever. The subsequent immediate opening-start submission
and synchronized scrollbar fading still require targeted in-game verification. The dialogue text APIs and NPC voice resolver also have user-reported
in-game verification. These checks do not establish exhaustive correctness across
all Settings controls, NPC appearances, voices, or native TTS cancellation edge cases.

## Architecture

The addon separates voice resolution, speech, and presentation:

- Generated Voice Family mappings connect NPC visual models to configurable families.
- `VoiceSelection` selects the configured narrator in Single Voice mode, or
  resolves an NPC model or player race to a family and uses `UnitSex` gender
  detection in Multiple Voices mode.
- The TTS controller streams supplied text sentence by sentence with a supplied voice.
- Talking Head provides the speaker portrait, dialogue display, and loading state.
- Quest and gossip integrations supply live dialogue and choose the displayed model and title
  independently of voice resolution. A shared narration controller coordinates
  Talking Head with the TTS lifecycle.
- One reusable NPC inspection model serves both quest and gossip voice resolution.

## Development

Debug logging is off by default and resets after login or `/reload`. Use
`/outloud debug on`, `/outloud debug off`, or `/outloud debug` to enable, disable,
or check it for the current session. Normal errors remain visible.

Implementation details, the explicit-approval testing policy, and in-game
diagnostic helpers are documented in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
