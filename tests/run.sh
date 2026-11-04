#!/usr/bin/env bash
# Headless shared-engine tests. Requires the Luau CLI:
#   https://github.com/luau-lang/luau/releases
# Usage:
#   LUAU=/path/to/luau bash tests/run.sh
#   bash tests/run.sh              # uses `luau` from PATH
set -euo pipefail
cd "$(dirname "$0")"
LUAU="${LUAU:-luau}"

if ! command -v "$LUAU" >/dev/null 2>&1; then
  echo "luau CLI not found. Install it or set LUAU=/path/to/luau." >&2
  echo "  brew install luau  (or download a release from luau-lang/luau)" >&2
  exit 1
fi

rm -rf build && mkdir build

# Copy shared modules, rewriting Roblox instance requires to relative requires.
for f in ../src/shared/*.luau; do
  base="$(basename "$f")"
  sed -E 's/require\(script\.Parent\.([A-Za-z0-9_]+)\)/require(".\/\1")/g' "$f" > "build/$base"
done

cp ./*.luau build/
rm -f build/run.sh

for test_file in build/*_test.luau; do
  echo "== $(basename "$test_file")"
  "$LUAU" "$test_file"
done

# --- match flow: server modules with lightweight Roblox/Net/service stubs ---
MATCH_BUILD=build/match
mkdir -p "$MATCH_BUILD"
for f in ../src/shared/*.luau; do
  cp "build/$(basename "$f")" "$MATCH_BUILD/"
done
for name in MatchService PlayerService; do
  {
    printf 'local __env = require("./TestEnv")\n'
    printf 'local game = __env.game\n'
    printf 'local Random = __env.Random\n'
    printf 'local warn = __env.warn\n'
    sed -E \
      -e 's/require\(Shared:WaitForChild\("([A-Za-z0-9_]+)"\)\)/require(".\/\1")/g' \
      -e 's/require\(script\.Parent:WaitForChild\("([A-Za-z0-9_]+)"\)\)/require(".\/\1")/g' \
      "../src/server/$name.luau"
  } > "$MATCH_BUILD/$name.luau"
done
cp match/TestEnv.luau "$MATCH_BUILD/TestEnv.luau"
cp match/StubBotService.luau "$MATCH_BUILD/BotService.luau"
cp match/StubSnapshotService.luau "$MATCH_BUILD/SnapshotService.luau"
cp match/StubNet.luau "$MATCH_BUILD/Net.luau"
cp match/match_test.luau "$MATCH_BUILD/"
cp testlib.luau "$MATCH_BUILD/"

echo "== match_test.luau (stubbed server)"
"$LUAU" "$MATCH_BUILD/match_test.luau"
