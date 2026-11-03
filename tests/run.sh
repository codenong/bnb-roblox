#!/usr/bin/env bash
# 逻辑测试：需要 Luau 命令行（https://github.com/luau-lang/luau/releases）
# 用法: LUAU=/path/to/luau bash tests/run.sh
#
# 做法：把 src/shared 和 src/server（不含 Main.server）复制到 tests/build，
#   1. 把 Roblox 风格的 require(script.Parent.X) / require(Shared:WaitForChild("X")) 换成相对路径 require
#   2. 在每个文件开头注入 tests/Stub.luau 提供的最小 Roblox 环境
# 这样 Movement / BlastRules / 服务端玩法流程都能脱离 Roblox 直接运行。
set -euo pipefail
cd "$(dirname "$0")"
LUAU="${LUAU:-luau}"
rm -rf build && mkdir build

HEADER='local Stub = require("./Stub"); local game, workspace, Instance, Vector3, Color3, Enum, os, script = Stub.game, Stub.workspace, Stub.Instance, Stub.Vector3, Stub.Color3, Stub.Enum, Stub.os, Stub.script'

convert() {
  local src="$1" dst="build/$(basename "$1")"
  sed -E \
    -e 's/require\(script\.Parent\.([A-Za-z]+)\)/require(".\/\1")/g' \
    -e 's/require\((Shared|script\.Parent):WaitForChild\("([A-Za-z]+)"\)\)/require(".\/\2")/g' \
    "$src" > "$dst"
  sed -i "1i $HEADER" "$dst"
}

for f in ../src/shared/*.luau; do convert "$f"; done
for f in ../src/server/*.luau; do
  [ "$(basename "$f")" = "Main.server.luau" ] && continue
  convert "$f"
done

cp Stub.luau logic_test.luau server_test.luau build/

"$LUAU" build/logic_test.luau
"$LUAU" build/server_test.luau
