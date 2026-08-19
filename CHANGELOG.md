# Changelog

## v1.6.0

### New

*   **Instant item levels via LibOpenRaid now actually work.** Anyone in your group running Details! broadcasts their gear, and those item levels appear without waiting for an inspect. This path shipped years ago and never delivered a single value: the callback was handed to the library in a shape it rejects, so it was refused at registration and silently did nothing, while the diagnostics reported it as active the whole time. It is repaired, and the report now counts values that actually arrived instead of asking whether the library is installed. Verified in a live raid before release. Entries sourced this way are marked `[LOR]` in `/dilvl cache`.

### Fixed

*   **A closed Details! window could switch off item levels in every window.** The scan walked windows in order and stopped at the first one it could not read — and a closed window stays unreadable for the rest of the session. With window 1 closed and window 2 open, nothing was tagged anywhere. It now skips what it cannot use instead of giving up, and covers all thirty windows Details! allows rather than the first ten.

*   **An inspect that timed out was never retried.** The player was dropped from the queue and, in a group where nothing else happened, carried no item level for the rest of the session. Timed-out players now get another turn, bounded so an unreachable one cannot spin forever.

*   **A tier set bonus is no longer guessed on first contact.** When a player's gear had not finished loading, whatever pieces were readable at that moment were counted and stored as final — so someone wearing four tier pieces could be recorded as `[2P]`, and it stuck. An incomplete reading now shows no tag at all and schedules another look. A missing tag is fine; a wrong one is not.

*   **The public API no longer throws on input it did not produce.** The colour helpers raised an error on anything that was not a number, and two lookups could throw inside restricted instances. Other addons reading item levels from this one no longer see errors carrying its name.

*   **Item levels come back after a boss fight.** Inside a raid or dungeon, Blizzard seals the
    names of players outside your own group: they still render on screen, but an addon can no
    longer read them, and once the fight ends Details! never rewrites those rows — so the tag
    stayed missing for the rest of the session. The row is now identified by the character ID
    Details! attaches to it rather than by its text, and the tag is spliced onto the sealed name
    without ever opening it, so the name, its rank, icons and any custom formatting stay exactly
    as Details! wrote them.

### Changed

*   **`/dilvl debug` reports outcomes instead of preconditions.** The old report could not tell "everyone is already cached" apart from "every request failed" — both printed the same line. It now shows how many inspects were sent, answered, timed out, retried, and harvested from other addons' requests, plus how many item levels LibOpenRaid actually delivered.

Full release history: [HISTORY.md](HISTORY.md)
