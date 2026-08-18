# Changelog

## v1.5.9

### Fixed

*   **Item level colours fell back to the old fixed scale after logging in** — everything from 280 upwards painted orange. The boundaries are read from this season's Mythic+ reward levels, and a freshly logged-in client has not received those yet.
*   **The colours now correct themselves within a second.** The addon requests the season data the same way the game's own dungeon panel does, instead of giving up for the rest of the session.

### Changed

*   **The fallback scale follows the current season** and has gained the gold band used by the derived scale — so the top colour stays meaningful even when the season data cannot be read at all.

Full release history: [HISTORY.md](HISTORY.md)
