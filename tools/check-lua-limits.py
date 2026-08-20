# -*- coding: utf-8 -*-
"""Lua 5.1 refuses a closure with more than 60 upvalues and a chunk with more
than 200 file-scope locals. luacheck does not model either, and lupa ships Lua
5.5 where the ceilings are far higher -- so a file can pass every offline check
here and still be rejected by the game client with

    core.lua:1 core.lua:NNNN: function at line NNNN has more than 60 upvalues

which is exactly what happened on 20.08.2026 after the slash handler grew.

Counting is deliberately pessimistic: every file-scope local NAME appearing
anywhere in a function's text, comments included. The real upvalue count is the
same or lower, so a pass here is a genuine pass.

Functions are delimited by indentation rather than token matching. Lua's `end`
closes if/for/while/do/function alike, `elseif` takes none, and one-line
`if x then y end` nets to zero -- a depth counter gets all of that wrong. Every
Lua file in this addon indents consistently, so a function opened at column 0 is
closed by the next line that begins with `end` at column 0.
"""
import io, os, re, sys

LIMIT_UP = 60
LIMIT_LOCALS = 200
MIN_LINES = 40          # smaller functions cannot plausibly reach 60


def strip_noise(line):
    line = re.sub(r'--.*$', ' ', line)
    line = re.sub(r'"(\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(\\.|[^'\\])*'", "''", line)
    return line


def file_scope_locals(lines):
    names = set()
    for line in lines:
        if not line.startswith("local"):
            continue
        m = re.match(r'^local\s+function\s+(\w+)', line)
        if m:
            names.add(m.group(1))
            continue
        m = re.match(r'^local\s+([^=]+)', line)
        if m:
            for part in m.group(1).split(','):
                part = part.strip().split('--')[0].strip()
                if re.match(r'^\w+$', part):
                    names.add(part)
    return names


def top_level_functions(lines):
    out = []
    for i, raw in enumerate(lines):
        clean = strip_noise(raw)
        if not clean[:1].strip():
            continue                      # indented -> nested, skip
        if 'function' not in clean:
            continue
        end = len(lines) - 1
        for j in range(i + 1, len(lines)):
            if re.match(r'^end\b|^end\)', lines[j]):
                end = j
                break
        out.append((i, end, raw.strip()[:64]))
    return out


def check(path):
    lines = io.open(path, "rb").read().decode("utf-8").replace("\r\n", "\n").split("\n")
    scope = file_scope_locals(lines)
    print("%s" % os.path.basename(path))
    over = 0
    if len(scope) > LIMIT_LOCALS:
        print("  !! Datei-Ebene locals: %d / %d" % (len(scope), LIMIT_LOCALS))
        over += 1
    else:
        print("  Datei-Ebene locals: %d / %d" % (len(scope), LIMIT_LOCALS))

    ranked = []
    for a, b, head in top_level_functions(lines):
        if b - a < MIN_LINES:
            continue
        body = "\n".join(lines[a:b + 1])
        used = set(re.findall(r'\b([A-Za-z_]\w*)\b', body)) & scope
        ranked.append((len(used), a + 1, b + 1, head))
    ranked.sort(reverse=True)
    for n, a, b, head in ranked[:6]:
        bad = n > LIMIT_UP
        over += 1 if bad else 0
        print("  %s%3d Upvalues  Zeile %5d-%-5d  %s" % ("!! " if bad else "   ", n, a, b, head))
    return over


if __name__ == "__main__":
    os.chdir(r"e:/dev/gaming/wow-addons/Details_iLvlDisplay")
    targets = sys.argv[1:] or ["core.lua", "blizzdm.lua", "util.lua", "init.lua",
                               "danders_integration.lua", "elvui_tags.lua",
                               "grid2_status.lua", "secrets.lua"]
    total = 0
    for t in targets:
        total += check(t)
        print()
    print("UEBER DEM LIMIT: %d" % total)
    sys.exit(1 if total else 0)
