# Changelog

## 0.1.2 — Forever and Retail

- Voice assignments now follow voice names when IDs change. Missing or ambiguous voices become **Not set**.
- **After updating, select your voices again once.** Existing voice assignments reset to **Not set**; all other settings are preserved.

## 0.1.1 — Forever and Retail

- Combined consecutive short sentences into larger TTS chunks for more natural narration.
- Very short sentences now join adjacent speech where possible, preferring the following sentence.
- Preserved paragraph and line boundaries, including readable-item HTML structure, while keeping stage directions intact.
- Kept Talking Head text synchronized with the new speech chunks.
