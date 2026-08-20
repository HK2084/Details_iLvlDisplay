#!/usr/bin/env bash
# lint-package-contents.sh — guards what actually reaches the user's download.
#
# v1.5.5 shipped 217 KB of internal, German-language review documents
# (EDGE_CASE_SWEEP, CODE_REVIEW, ROADMAP_RESEARCH, PLUGIN_ARCHITEKTUR). The zip
# was 234 KB where the addon itself is 144 KB — 38 % of every download was
# working notes no user will ever read. Nothing failed; the files were simply
# never added to the ignore list in .pkgmeta, and nobody looked.
#
# A denylist cannot prevent that: it only ever catches what someone remembered
# to write down, and the next document is by definition the one nobody thought
# of. So this gate is an ALLOWLIST. A file type that is not addon content has to
# be added here on purpose, in a commit, with a reason — it can no longer ship
# by accident.
#
# Internal documents belong under docs/, which .pkgmeta ignores wholesale.
set -uo pipefail
cd "$(dirname "$0")/.."

# Everything a packaged WoW addon legitimately contains.
#   code      .lua .xml .toc
#   media     .tga .blp (in-game textures; .png is NOT loadable by WoW)
#   by name   the three files users and CurseForge actually read
is_allowed() {
    case "$1" in
        CHANGELOG.md|README.md|LICENSE) return 0 ;;
    esac
    case "$1" in
        *.lua|*.xml|*.toc|*.tga|*.blp) return 0 ;;
    esac
    return 1
}

# Read the ignore list straight out of .pkgmeta rather than keeping a second
# copy here — one source of truth, so the two cannot drift apart.
ignored=()
while IFS= read -r line; do
    ignored+=("$line")
done < <(awk '
    /^ignore:/            { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
        sub(/^[[:space:]]*-[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
        next
    }
    inlist && /^[^[:space:]#]/ { inlist = 0 }
' .pkgmeta)

is_ignored() {
    local path="$1" top="${1%%/*}" entry
    for entry in "${ignored[@]}"; do
        [ -z "$entry" ] && continue
        # .pkgmeta entries are either an exact path or a directory whose whole
        # subtree is excluded.
        [ "$path" = "$entry" ] && return 0
        [ "$top" = "$entry" ] && return 0
    done
    return 1
}

# Every .lua the addon actually LOADS, straight from the .toc. A Lua file the
# .toc does not name is not addon code however much it looks like it: WoW never
# runs it, so in the download it is dead weight at best. Extension alone cannot
# tell the difference, which is how 18 KB of test harness came to sit in the
# addon root with this gate reporting OK.
loaded=()
while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    case "$line" in *.lua) loaded+=("${line//\\//}") ;; esac
done < <(cat ./*.toc 2>/dev/null)

is_loaded() {
    local entry
    for entry in "${loaded[@]}"; do
        [ "$1" = "$entry" ] && return 0
    done
    return 1
}

status=0
offenders=()
unloaded=()
check_file() {
    local file="$1"
    is_ignored "$file" && return
    case "$file" in
        *.lua)
            is_loaded "$file" && return
            unloaded+=("$file")
            status=1
            return
            ;;
    esac
    is_allowed "$file" && return
    offenders+=("$file")
    status=1
}

# Tracked AND untracked. The packager zips the folder, not the index, so a file
# git never heard of ships exactly like one it did.
while IFS= read -r file; do
    [ -z "$file" ] && continue
    check_file "$file"
done < <({ git ls-files; git ls-files --others --exclude-standard; } | sort -u)

if [ "$status" -ne 0 ]; then
    for f in "${offenders[@]}"; do
        echo "::error file=$f::'$f' would be shipped to users but is not addon content"
    done
    for f in "${unloaded[@]}"; do
        echo "::error file=$f::'$f' is Lua the .toc never loads - dead weight in the download"
    done
    echo
    echo "Every file above lands in the zip that users download."
    echo "Fix it one of two ways:"
    echo "  * internal notes, reviews, scratch work  ->  move under docs/"
    echo "  * genuinely part of the addon            ->  add its type to is_allowed()"
    echo "Do not add a one-off entry to .pkgmeta's ignore list for a document;"
    echo "that is exactly how the 217 KB got in."
else
    echo "package-contents invariant OK — only addon files would be shipped."
fi

exit "$status"
