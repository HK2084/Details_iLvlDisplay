# Changelog

## v1.6.0

### New

*   **Rows whose name Blizzard has sealed now carry an item level.** In a raid or a random group the game hides most player names from addons, and every one of those rows on the Details! bars stayed blank. They are tagged now, without ever reading or rewriting the hidden name: the row's own player ID says who it is, and the hidden text is handed straight back untouched, so the rank, the name, the realm spelling and any icons survive exactly as Details! drew them. Where the game withholds the ID as well, the row stays blank on purpose — a missing tag is fine, a wrong name is not, and `/dilvl debug` now says which of the two happened.

*   **Instant item levels via LibOpenRaid now actually work.** Anyone in your group running Details! broadcasts their gear, and those item levels appear without waiting for an inspect. This path shipped years ago and never delivered a single value: the callback was handed to the library in a shape it rejects, so it was refused at registration and silently did nothing, while the diagnostics reported it as active the whole time. It is repaired, and the report now counts values that actually arrived instead of asking whether the library is installed. Verified in a live raid before release. Entries sourced this way are marked `[LOR]` in `/dilvl cache`.

### Fixed

*   **Item levels disappeared from the Details! bars two hours after a raid.** The lookup treated its two-hour re-inspect window as a display window too, so once an entry crossed it the tag was dropped rather than shown — even for players who had long left the group, where no newer reading was ever going to arrive. Blizzard’s meter reads the same cache without that filter, so it kept showing the numbers while the Details! bars beside it went blank. It now falls back to what was measured whenever nothing fresher exists; a fresher reading still wins, and re-inspection is unchanged.

*   **“Item level left of the name” now actually puts it there.** On a row whose name the game hides, the rank and the name arrive welded into one piece that may not be taken apart, so the setting could only reach your own row and silently did nothing on everyone else’s. The tag now sits between the rank and the name on every row, hidden or not, by rebuilding the row from the pieces Details! hands out rather than trying to cut up the finished line. Where the game hides those pieces as well, the row keeps the old layout instead of losing its item level.

*   **Changing that setting had no effect at all on Blizzard’s damage meter.** The change was only ever announced to the Details! side, and Blizzard’s meter has no reason to redraw a row on its own, so it kept the old layout until the next fight. Every setting is now delivered to both meters.

*   **Switching the addon off left its item levels behind.** On Blizzard’s meter and on Danders Frames the text stayed on screen after `/dilvl off` — including when the Blizzard integration switched itself off after repeated errors. Turning it off now takes the text with it.

*   **A closed Details! window could switch off item levels in every window.** The scan walked windows in order and stopped at the first one it could not read — and a closed window stays unreadable for the rest of the session. With window 1 closed and window 2 open, nothing was tagged anywhere. It now skips what it cannot use instead of giving up, and covers all thirty windows Details! allows rather than the first ten.

*   **An inspect that timed out was never retried.** The player was dropped from the queue and, in a group where nothing else happened, carried no item level for the rest of the session. Timed-out players now get another turn, bounded so an unreachable one cannot spin forever.

*   **A tier set bonus is no longer guessed on first contact.** When a player's gear had not finished loading, whatever pieces were readable at that moment were counted and stored as final — so someone wearing four tier pieces could be recorded as `[2P]`, and it stuck. An incomplete reading now shows no tag at all and schedules another look. A missing tag is fine; a wrong one is not.

*   **More rows on Blizzard's damage meter keep their item level after a fight.** Blizzard only
    rebuilds a row while damage is still coming in, so once the last hit lands every row holds on
    to the sealed name it was drawn with, and there is nothing left to trigger a second look —
    measured in one raid, twelve of twenty-five rows sat blank until something unrelated came
    along or the interface was reloaded. The addon now reads the finished fight back from the
    game itself, where the names are readable again, and matches it to the rows on screen.
    It does so only where the match can be proven: every row whose owner the game states outright
    must land on the line it claims, no row may sit on a source of another class, and a player
    is only identified this way when every other player of that class and specialisation is
    already pinned to a confirmed line. Where that proof is not available the row stays blank,
    which in a raid full of one specialisation is still the common case. A missing tag is fine;
    another player's name is not.

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
