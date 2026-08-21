#!/usr/bin/env bash
# lint-no-setscript.sh - no script handlers on frames we do not own.
#
# A SetScript installed from addon code runs TAINTED, and an OnUpdate on one of
# Blizzard's meter frames would spread that taint every tick into state that
# Blizzard's secure paths read - the worst freeze class this addon can cause.
# Interaction with Blizzard's meter is hooksecurefunc + reads + our own frames,
# nothing else. (Deep analysis 21.08.2026, ship item #3.)
#
# blizzdm.lua may therefore call SetScript ONLY on frames this file creates:
# refreshFrame and eventFrame. Anything else fails the build.
set -uo pipefail
cd "$(dirname "$0")/.."

bad=$(grep -n "SetScript" blizzdm.lua | grep -v "refreshFrame:SetScript" \
    | grep -v "eventFrame:SetScript" | grep -v "^\s*--" | grep -v "never SetScript" || true)
if [ -n "$bad" ]; then
    echo "SetScript on a frame blizzdm.lua does not own:"
    echo "$bad"
    exit 1
fi
echo "no-setscript invariant OK - blizzdm.lua only scripts its own frames."
