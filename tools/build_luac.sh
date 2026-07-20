#!/usr/bin/env bash
# Build Lua 5.5.0 tools with LUA_32BITS=1 (32-bit int + float).
# Produces bytecode and runtime compatible with ESP32-C3 (Zap gateway).
#
# Usage:
#   bash tools/build_luac.sh                    # builds ./luac55
#   bash tools/build_luac.sh /tmp/luac          # custom output path
#   bash tools/build_luac.sh --with-interpreter  # also builds ./lua55
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/lua55-src"

BUILD_INTERPRETER=false
OUTPUT=""

for arg in "$@"; do
    case "$arg" in
        --with-interpreter) BUILD_INTERPRETER=true ;;
        *) OUTPUT="$arg" ;;
    esac
done

OUTPUT="${OUTPUT:-./luac55}"

if [ ! -f "$SRC_DIR/onelua.c" ]; then
    echo "ERROR: Lua 5.5.0 source not found in $SRC_DIR"
    echo "Expected onelua.c from vendored Lua source."
    exit 1
fi

echo "Building luac from Lua 5.5.0 source (LUA_32BITS=1)..."
gcc -O2 -std=c99 -DMAKE_LUAC \
    -I"$SRC_DIR" \
    -o "$OUTPUT" \
    "$SRC_DIR/onelua.c" \
    -lm

echo "Built: $OUTPUT"
"$OUTPUT" -v

if [ "$BUILD_INTERPRETER" = true ]; then
    INTERP_DIR="$(dirname "$OUTPUT")"
    INTERP_PATH="$INTERP_DIR/lua55"
    echo ""
    echo "Building lua interpreter from Lua 5.5.0 source (LUA_32BITS=1)..."
    gcc -O2 -std=c99 -DLUA_USE_POSIX \
        -I"$SRC_DIR" \
        -o "$INTERP_PATH" \
        "$SRC_DIR/onelua.c" \
        -lm
    echo "Built: $INTERP_PATH"
    "$INTERP_PATH" -v
fi
