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
    '\bio\.'
    '\bos\.'
    '\bdebug\.'
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
        # Search for pattern, excluding comments (lines starting with --)
        matches=$(grep -nE "$pattern" "$file" | grep -v '^\s*--' || true)
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
