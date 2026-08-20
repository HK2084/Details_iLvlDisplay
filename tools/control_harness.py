# -*- coding: utf-8 -*-
"""Shared runner for positive controls, and the reason it exists.

A positive control removes one guard from the code under test and asserts that
the suite NOTICES. The whole point is to catch a test that would pass no matter
what the code did.

Every suite here wrote that loop by hand, and every copy had the same hole:

    try:
        held = still_ok(run(broken))
    except Exception:
        held = False          # <- "did not hold" == the control worked

An exception means the control could not be evaluated at all -- a stale anchor,
a renamed case, a chunk that no longer compiles -- and that is indistinguishable
from a control that did its job. It was not theoretical: after `classDiff` was
renamed, its control asked for a result that no longer existed, threw on the
lookup, and printed OK. A control that reports success by failing is worse than
no control, because it buys confidence it has not earned.

The second hole was quieter: a failed control did not increment the suite's
error count, so it could never turn a run red.

Both are closed here, once, for every suite:
  * execution and evaluation are separated, and a failure in either is DEFEKT
  * an anchor that matches nothing is DEFEKT
  * every DEFEKT counts as a suite failure
"""
import lupa


def run_controls(chunk, controls, runtime=None):
    """Run each control. Returns the number of failures (0 = all good).

    controls: list of (name, modified_chunk, predicate). The predicate receives
    the result table and returns True if the suite STILL passes without the
    guard -- which is the bad outcome the control is looking for.
    """
    if runtime is None:
        def runtime(src):
            return lupa.LuaRuntime(unpack_returned_tuples=False).execute(src)

    bad = 0
    for name, broken, still_ok in controls:
        if broken == chunk:
            print("  DEFEKT      '%s': der Anker greift nicht mehr, es wurde"
                  " nichts entfernt" % name)
            bad += 1
            continue
        try:
            result = runtime(broken)
        except Exception as exc:
            print("  DEFEKT      '%s' laeuft nicht: %s" % (name, exc))
            bad += 1
            continue
        try:
            held = still_ok(result)
        except Exception as exc:
            print("  DEFEKT      '%s' prueft ins Leere: %s" % (name, exc))
            bad += 1
            continue
        print("  %s  Positivkontrolle: %s"
              % ("OK  " if not held else "VERDAECHTIG", name))
        if held:
            bad += 1
    return bad
