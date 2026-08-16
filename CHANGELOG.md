# Changelog

## v1.5.6

### New

*   **Tier sets are colour-coded by season.** The current season's set bonus renders in green, an older season's in grey. The strongest bonus is still the one displayed, so four older pieces alongside a single current one still reads 4P, in grey.

### Optimised

*   **Package reduced to runtime files only.** The download is roughly a third smaller: 144 KB.

### Fixed

*   **Rank prefixes are read from the client's own format string** instead of assuming a full stop. zhCN and zhTW use a different separator (`1、Name`), which previously broke both the name lookup and the rank display on those clients.

Full release history: [HISTORY.md](HISTORY.md)
