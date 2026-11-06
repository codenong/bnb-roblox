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

# --- profile data layer: pure Luau modules with a fake DataStore ---
PROFILE_BUILD=build/profile
mkdir -p "$PROFILE_BUILD"
cp build/ProfileSchema.luau "$PROFILE_BUILD/"
cp ../src/server/ProfileStore.luau ../src/server/ProfileService.luau "$PROFILE_BUILD/"
cp profile/FakeDataStore.luau profile/profile_schema_test.luau profile/profile_store_test.luau profile/profile_store_faults_test.luau profile/profile_service_test.luau testlib.luau "$PROFILE_BUILD/"

echo "== profile_schema_test.luau (defaults, free/purchased stock, normalization)"
"$LUAU" "$PROFILE_BUILD/profile_schema_test.luau"
echo "== profile_store_test.luau (DataStore locks, retries, reload)"
"$LUAU" "$PROFILE_BUILD/profile_store_test.luau"
echo "== profile_store_faults_test.luau (lost responses, re-run transforms)"
"$LUAU" "$PROFILE_BUILD/profile_store_faults_test.luau"
echo "== profile_service_test.luau (load/commit/release/shutdown)"
"$LUAU" "$PROFILE_BUILD/profile_service_test.luau"

# --- match flow: server modules with lightweight Roblox/Net/service stubs ---
MATCH_BUILD=build/match
mkdir -p "$MATCH_BUILD"
for f in ../src/shared/*.luau; do
  cp "build/$(basename "$f")" "$MATCH_BUILD/"
done
for name in MatchService PlayerService Room SnapshotService; do
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
cp match/StubNet.luau "$MATCH_BUILD/Net.luau"
cp match/match_test.luau "$MATCH_BUILD/"
cp match/room_test.luau "$MATCH_BUILD/"
cp match/isolation_test.luau "$MATCH_BUILD/"
cp testlib.luau "$MATCH_BUILD/"

echo "== match_test.luau (room manager, stubbed server)"
"$LUAU" "$MATCH_BUILD/match_test.luau"
echo "== room_test.luau (per-room audience)"
"$LUAU" "$MATCH_BUILD/room_test.luau"
echo "== isolation_test.luau (a failing room must not stop the others)"
"$LUAU" "$MATCH_BUILD/isolation_test.luau"

# --- client entry: the real Main.client.luau with stubbed UI modules and remotes ---
CLIENT_BUILD=build/client
mkdir -p "$CLIENT_BUILD"
{
  printf 'local __env = require("./ClientEnv")\n'
  printf 'local game, Instance, Enum, script, task = __env.game, __env.Instance, __env.Enum, __env.script, __env.task\n'
  sed -E \
    -e 's/require\(Shared:WaitForChild\("([A-Za-z0-9_]+)"\)\)/require(".\/\1")/g' \
    -e 's/require\(script\.Parent:WaitForChild\("([A-Za-z0-9_]+)"\)\)/require(".\/\1")/g' \
    ../src/client/Main.client.luau
  # Main is a script (returns nothing); give the test copy a return value so require() accepts it.
  printf '\nreturn true\n'
} > "$CLIENT_BUILD/Main.luau"
cp ../src/client/Interpolation.luau "$CLIENT_BUILD/Interpolation.luau"
cp client/ClientEnv.luau client/Stubs.luau client/client_test.luau client/client_loading_test.luau testlib.luau "$CLIENT_BUILD/"
for name in Board Hud Input Audio Renderer Net; do
  printf 'return require("./Stubs").%s\n' "$name" > "$CLIENT_BUILD/$name.luau"
done

echo "== client_test.luau (Main.client with stubs)"
"$LUAU" "$CLIENT_BUILD/client_test.luau"

# Main runs once per process, so every startup scenario gets its own process.
for scenario in event poll empty limit; do
  echo "== client_loading_test.luau ($scenario)"
  "$LUAU" "$CLIENT_BUILD/client_loading_test.luau" -a "$scenario"
done

# --- the real Input.luau with stubbed UserInputService / GuiService ---
INPUT_BUILD=build/input
mkdir -p "$INPUT_BUILD"
{
  printf 'local __env = require("./ClientEnv")\n'
  printf 'local game, Instance, Enum, warn = __env.game, __env.Instance, __env.Enum, print\n'
  cat ../src/client/Input.luau
} > "$INPUT_BUILD/Input.luau"
cp client/ClientEnv.luau client/input_test.luau testlib.luau "$INPUT_BUILD/"

echo "== input_test.luau (keyboard / arrows / gamepad mapping)"
"$LUAU" "$INPUT_BUILD/input_test.luau"
