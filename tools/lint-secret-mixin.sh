#!/usr/bin/env bash
# lint-secret-mixin.sh — guards the "secret-touching foreign mixin" invariant.
#
# Some Blizzard / foreign-addon mixin methods internally COMPARE a secret field.
# Example: DamageMeterEntryMixin:GetNameText() -> GetFormattedSourceNameText ->
# GetSourceTypeAtlasElement compares the secret `sourceDisplayType`
# (Blizzard_DamageMeter/DamageMeterEntry.lua:87). Calling such a method from our
# TAINTED execution context throws *inside the call*, before any return value we
# could guard with isSecretValue() — that was the v1.5.2 crash (Profion85, 95x in
# Val + 386x in the Sporefall raid).
#
# Fix is to only ever call these through a pcall-wrapping safe helper, never raw.
# luacheck can't see method-call receivers (it doesn't know the type of `frame`),
# so the .luacheckrc invariant can't cover this — this grep does, and the CI runs
# it before packaging so a raw call can never reach a release.
#
# To guard another risky mixin method, add a "<method-call-pattern>|<note>" line
# to FORBIDDEN below. Comment lines and the wrapper's own dot-syntax pcall
# (`pcall(frame.GetNameText, frame)`) do not match the `:Method(` call pattern.
set -uo pipefail
cd "$(dirname "$0")/.."

# Each entry: "<raw-call-pattern>|<the safe wrapper it must go through>"
FORBIDDEN=(
  ':GetNameText(|SafeGetNameText() — Blizzard DamageMeter mixin, secret sourceDisplayType'
  'GetUnitGear(|a pcall — LibOpenRaid keys its store by a raw name lookup and throws INSIDE the library on a secret'
)

status=0
for entry in "${FORBIDDEN[@]}"; do
  pat="${entry%%|*}"
  note="${entry#*|}"
  # Match the raw `:Method(` call, but skip comment lines: grep -nH prints
  # "path:lineno:code", so a comment is "...:<n>:<spaces>--...".
  hits=$(grep -rnH --include='*.lua' -- "$pat" . | grep -vE ':[0-9]+:[[:space:]]*--' || true)
  if [ -n "$hits" ]; then
    echo "::error::Raw '$pat' found — must go through $note"
    echo "$hits"
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "secret-mixin invariant OK — no raw secret-touching foreign-mixin calls."
fi
exit "$status"
