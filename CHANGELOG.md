# Changelog

## v1.5.7

### New

*   **The AddOn list is no longer English-only.** The description under the addon's name now reads in German, Russian, Simplified and Traditional Chinese, and Korean — in each case using the client's own wording for item level and set bonus, not a dictionary rendering of the English.
*   **ElvUI's tag browser explains `[dilvl]` and `[dilvl:plain]` in German.** Those two descriptions — what you read when you search the browser for `dilvl` — were the last text in the addon that stayed English on every client. Any language without a translation falls back to English as before.

### Fixed

*   **Nobody is shown under a name the addon invented.** Details! rewrites the text on its own bars: a guild nickname another player set for you, the realm suffix stripped off, a Cyrillic name romanised. That rendered text was being kept as the player's identity for up to seven days and written onto Blizzard's damage-meter rows. Only a name from the group roster or the combat log is stored now — and where there is neither, the row simply keeps no tag. A missing tag is fine, a wrong name is not.

Full release history: [HISTORY.md](HISTORY.md)
