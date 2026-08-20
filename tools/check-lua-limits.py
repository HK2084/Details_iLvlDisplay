# -*- coding: utf-8 -*-
"""Compile every Lua file with a REAL Lua 5.1, exactly as the game client does.

WoW runs Lua 5.1, which refuses AT COMPILE TIME any closure with more than 60
upvalues or any chunk with more than 200 locals. Nothing else in this repo models
that: luacheck does not know the limits, and the runtime the behaviour suites use
is Lua 5.5, where the ceilings are far higher. On 20.08.2026 core.lua passed every
offline check and the client rejected it with

    core.lua:1 core.lua:3753: function at line 2741 has more than 60 upvalues

so the addon was, briefly, entirely dead.

TWO PARTS, AND THE DIFFERENCE MATTERS.

The COMPILE is the gate: exact, because it is the same compiler the client runs.
If loadstring succeeds under Lua 5.1 the file is safe, full stop.

The upvalue figure is an UPPER BOUND, not a measurement, and it exists only to
warn before the next helper pushes a function over. It counts every file-scope
name appearing anywhere inside a top-level function, comments included, so it
reads high on purpose -- an earlier version of this script reported 53 for
functions the compiler puts at 45. Never quote it as a fact; quote the compiler.
"""
import io, os, re, sys

try:
    from lupa import lua51
except ImportError:
    sys.exit("needs lupa with a Lua 5.1 runtime: pip install lupa")

MAX_UPVALUES = 60
WARN_AT = 45


def upper_bound_upvalues(path):
    """Deliberate over-estimate of the worst closure in a file. Reads high.

    Function extent comes from indentation, not token matching: `end` closes
    if/for/while/do/function alike, `elseif` closes nothing, and a one-line
    `if x then y end` nets to zero, so a depth counter gets all of it wrong.
    Every Lua file here is consistently indented, so a function opened at column
    0 is closed by the next line starting with `end` at column 0.
    """
    lines = io.open(path, "rb").read().decode("utf-8").replace("\r\n", "\n").split("\n")

    scope = set()
    for line in lines:
        if not line.startswith("local"):
            continue
        m = re.match(r"^local\s+function\s+(\w+)", line)
        if m:
            scope.add(m.group(1))
            continue
        m = re.match(r"^local\s+([^=]+)", line)
        if m:
            for part in m.group(1).split(","):
                part = part.strip().split("--")[0].strip()
                if re.match(r"^\w+$", part):
                    scope.add(part)

    worst_n, worst_line = 0, 0
    for i, raw in enumerate(lines):
        clean = re.sub(r"--.*$", " ", raw)
        if not clean[:1].strip() or "function" not in clean:
            continue
        stop = len(lines) - 1
        for j in range(i + 1, len(lines)):
            if re.match(r"^end\b|^end\)", lines[j]):
                stop = j
                break
        if stop - i < 40:
            continue
        body = "\n".join(lines[i:stop + 1])
        n = len(set(re.findall(r"\b([A-Za-z_]\w*)\b", body)) & scope)
        if n > worst_n:
            worst_n, worst_line = n, i + 1
    return worst_n, worst_line


def check(path):
    src = io.open(path, "rb").read()
    name = os.path.basename(path)
    # encoding=None keeps Lua strings as raw bytes: an error message may contain
    # anything, and decoding it eagerly can fail on a file we are trying to
    # report an error about.
    L = lua51.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    compile_only = L.eval(
        b'function(s, n) local f, err = loadstring(s, n)'
        b' if f then return true end return false, err end')
    res = compile_only(src, name.encode("utf-8"))
    ok, err = res if isinstance(res, tuple) else (res, None)
    if not ok:
        print("  %-26s !! COMPILE-FEHLER, wortgleich zum Client:" % name)
        print("     %s" % (err or b"?").decode("utf-8", "replace"))
        return 1

    n, line = upper_bound_upvalues(path)
    if n >= WARN_AT:
        print("  %-26s uebersetzt   ~ hoechstens %d Upvalues ab Zeile %d (Grenze %d)"
              % (name, n, line, MAX_UPVALUES))
    else:
        print("  %-26s uebersetzt" % name)
    return 0


if __name__ == "__main__":
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    targets = sys.argv[1:]
    if not targets:
        targets = sorted(f for f in os.listdir(".") if f.endswith(".lua"))
        for sub in ("ui", "locales"):
            if os.path.isdir(sub):
                targets += [os.path.join(sub, f)
                            for f in sorted(os.listdir(sub)) if f.endswith(".lua")]
    bad = sum(check(t) for t in targets)
    print()
    print("ALLE %d DATEIEN UEBERSETZEN UNTER LUA 5.1" % len(targets) if not bad
          else "%d DATEI(EN) WUERDEN VOM CLIENT ABGELEHNT" % bad)
    sys.exit(1 if bad else 0)
