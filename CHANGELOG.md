# Changelog

## v1.5.6

### New

*   **Tier sets from an older season are shown in grey**, the current season's in green. Players swap tier a piece at a time — two old, two new, then four new — and until now the display could not tell you which set a bonus came from. The strongest bonus is still the one shown, so four old pieces plus two new still reads 4P, just in grey.

### Fixed

*   **The download is a third smaller** — 144 KB instead of 234 KB. Internal development documents were being packaged along with the addon.
*   **Rank numbers work on Chinese clients.** The game writes them as `1、Name` there rather than `1. Name`, which our name lookup did not recognise, so those rows lost both their numbering and their item level.

Full release history: [HISTORY.md](HISTORY.md)
