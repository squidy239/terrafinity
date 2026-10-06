#!/usr/bin/env bash
# Runs the asd-ste100 linter over the comments of each Zig file, never its code.
# Non-comment lines become blank lines, so reported line numbers match the file.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/../../asd-ste100/scripts/ste-lint.py"
status=0
for file in "$@"; do
    echo "== $file"
    awk '{ i = index($0, "//"); if (i == 0) print ""; else { s = substr($0, i + 2); sub(/^[\/!]? ?/, "", s); print s } }' "$file" |
        python3 "$lint" | sed "s#^<stdin>#$file#" || status=1
done
exit $status
