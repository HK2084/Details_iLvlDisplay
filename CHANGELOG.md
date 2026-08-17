# Changelog

## v1.5.8

### New

*   **Item level colours now follow the season instead of fixed numbers.** The boundaries are read from this season's Mythic+ reward levels, so they move when the season does. A new gold sits above anything Mythic+ awards — reaching it means the gear came from somewhere else — and it is meant to be empty for the first weeks. The old fixed scale had drifted far enough that 43 % of everyone you met showed up in the top colour; with season 2's gear it would have been all of them.

### Fixed

*   **The description no longer advertises instant item levels via LibOpenRaid.** That path was wired up years ago but its callback was rejected the moment it registered, so it has never delivered a single value — every item level you have ever seen came from the inspect route. Nothing about the addon got worse; a claim that was not true was removed. The path itself will be repaired in a later release, and will not be advertised again until it can be shown working.

Full release history: [HISTORY.md](HISTORY.md)
