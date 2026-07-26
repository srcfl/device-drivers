#!/usr/bin/env bash
# Check Lua drivers for sandbox safety violations.
#
# Drivers must not use:
#   - require, dofile, loadfile (module loading)
#   - io.*, os.*, debug.* (system access)
#   - loadstring (dynamic code execution)
#
# Usage:
#   ./tools/check_sandbox.sh [drivers/*.lua]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Patterns that indicate sandbox escape attempts
FORBIDDEN_PATTERNS=(
    '\brequire\s*[\("]'
    '\bdofile\s*[\("]'
    '\bloadfile\s*[\("]'
    '\bloadstring\s*[\("]'
    '(^|[^A-Za-z0-9_."-])io\.'
    '(^|[^A-Za-z0-9_."-])os\.'
    '(^|[^A-Za-z0-9_."-])debug\.'
)

# Get files to check
if [ $# -gt 0 ]; then
    FILES=("$@")
else
    FILES=("$REPO_ROOT"/drivers/lua/*.lua)
fi

ERRORS=0

for file in "${FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "WARN: File not found: $file"
        continue
    fi

    basename="$(basename "$file")"

    for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
        # Search for the pattern, excluding comment lines. grep -n prefixes
        # each hit with "NN:", so the exclusion has to allow for that; without
        # it the filter never matched and every commented mention of os. or
        # io. was a hard failure.
        matches=$(grep -nE "$pattern" "$file" | grep -vE '^[0-9]+:[[:space:]]*--' || true)
        if [ -n "$matches" ]; then
            echo "FAIL $basename: forbidden pattern '$pattern'"
            echo "$matches" | while IFS= read -r line; do
                echo "  $line"
            done
            ERRORS=$((ERRORS + 1))
        fi
    done
done

if [ "$ERRORS" -eq 0 ]; then
    echo "OK   All ${#FILES[@]} drivers pass sandbox safety check."
    exit 0
else
    echo ""
    echo "FAIL $ERRORS sandbox violation(s) found."
    exit 1
fi
