# Changelog

## v1.5.9

### Fixed

*   **Item level colours dropped back to the old fixed scale after logging in.** The boundaries are read from this season's Mythic+ reward levels, but on a fresh login the client has not received those levels yet, so the first attempt found nothing and the addon stayed on the fallback scale for the rest of the session — everything from 280 upwards painted orange. It now requests that data the way Blizzard's own dungeon UI does and re-derives the boundaries the moment it arrives, which takes a second at most. A `/reload` never showed the problem because the client still had the data in memory by then.

*   **The fallback scale now matches the current season.** It still carried season 1's numbers, so on the rare occasion it is reached it was far too generous. It now follows season 2 and has gained the same gold band as the derived scale, which keeps the top colour meaningful even when the season data cannot be read at all.

Full release history: [HISTORY.md](HISTORY.md)
