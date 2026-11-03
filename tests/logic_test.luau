local Constants = require("./Constants")
local Grid = require("./Grid")
local MapRules = require("./MapRules")
local BlastRules = require("./BlastRules")
local Movement = require("./Movement")

local TILE = Constants.TILE
local HALF = Constants.PLAYER_HALF_SIZE

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed += 1
    else
        failed += 1
        print("FAIL: " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-3)
end

-- 用地图字符串快速搭测试场景。'#'=墙 'x'=箱子 '.'=空地
local function mapFrom(rows)
    local map = MapRules.createEmptyMap(#rows[1], #rows)
    for r, line in ipairs(rows) do
        for c = 1, #line do
            local ch = line:sub(c, c)
            map.cells[r][c] = ch == "#" and TILE.WALL or (ch == "x" and TILE.CRATE or TILE.EMPTY)
        end
    end
    return map
end

local function run(map, x, z, dirX, dirZ, seconds, ignore, speed)
    local isSolid = MapRules.makeSolidFn(map, ignore)
    local dt = 1 / 60
    for _ = 1, math.floor(seconds / dt) do
        x, z = Movement.step(isSolid, x, z, dirX, dirZ, speed or Constants.PLAYER_BASE_SPEED, dt)
        if ignore then
            Movement.refreshIgnore(ignore, x, z)
        end
    end
    return x, z
end

---------------------------------------------------------------- Grid
do
    local k = Grid.key(7, 12)
    local c, r = Grid.fromKey(k)
    check("grid key roundtrip", c == 7 and r == 12)
    local col, row = Grid.cellOf(2.49, 3.5)
    check("cellOf rounding", col == 2 and row == 4, col .. "," .. row)
end

---------------------------------------------------------------- 默认地图
do
    local map = MapRules.createDefaultMap()
    for _, p in MapRules.getSpawnPoints(map) do
        check("spawn is empty " .. p[1] .. "," .. p[2], MapRules.getCell(map, p[1], p[2]) == TILE.EMPTY)
    end
    -- 出生点旁边两格也应是空地
    check("spawn neighbor right", MapRules.getCell(map, 3, 2) == TILE.EMPTY)
    check("spawn neighbor down", MapRules.getCell(map, 2, 3) == TILE.EMPTY)
    check("border wall", MapRules.getCell(map, 1, 1) == TILE.WALL)
    check("inner wall pattern", MapRules.getCell(map, 3, 3) == TILE.WALL and MapRules.getCell(map, 4, 3) ~= TILE.WALL)

    local flat = MapRules.flatten(map)
    local back = MapRules.unflatten(map.width, map.height, flat)
    local same = true
    for row = 1, map.height do
        for col = 1, map.width do
            if back.cells[row][col] ~= map.cells[row][col] then
                same = false
            end
        end
    end
    check("flatten/unflatten roundtrip", same and #flat == map.width * map.height)
end

---------------------------------------------------------------- 移动 / 碰撞
do
    local map = MapRules.createDefaultMap()

    -- 出生点 (2,2) 向右走，(4,2) 是箱子，应停在 4-0.5-HALF
    local x, z = run(map, 2, 2, 1, 0, 3)
    check("stops at crate (right)", near(x, 3.5 - HALF) and near(z, 2), x .. "," .. z)

    -- 向左走撞外墙 (1,2)
    x, z = run(map, 2, 2, -1, 0, 3)
    check("stops at border wall (left)", near(x, 1.5 + HALF), x)

    -- 向下走，(2,4) 是箱子
    x, z = run(map, 2, 2, 0, 1, 3)
    check("stops at crate (down)", near(z, 3.5 - HALF) and near(x, 2), x .. "," .. z)

    -- 巨大 dt 不会穿墙
    local isSolid = MapRules.makeSolidFn(map, nil)
    x, z = Movement.step(isSolid, 2, 2, 1, 0, 3.4, 5)
    check("no tunneling with big dt", x < 3.5, x)

    -- 斜向移动靠墙时可以沿墙滑动
    local open = mapFrom({
        "#######",
        "#.....#",
        "#.....#",
        "#.....#",
        "#######",
    })
    x, z = run(open, 2, 2, -1, 1, 0.5)
    check("slides along wall", near(x, 1.5 + HALF) and z > 2.3, x .. "," .. z)

    -- 不会走出地图
    x, z = run(open, 4, 3, 1, 0, 10)
    check("stays inside map", x <= 6.5 - HALF + 1e-3, x)
end

---------------------------------------------------------------- 拐角辅助
do
    local map = mapFrom({
        "#########",
        "#.......#",
        "#.#.#.#.#",
        "#.......#",
        "#########",
    })
    -- 在第 2 行走廊，z 偏了 0.3，被 (3,3) 的墙挡住，应自动滑回车道并通过
    local x, z = run(map, 2, 2.3, 1, 0, 1.0)
    check("corner assist passes lane", x > 3.4 and math.abs(z - 2) < 0.2, x .. "," .. z)

    -- 偏离车道中心 0.5（超过 0.45 的容差）就不辅助，应被墙挡住
    x, z = run(map, 2, 2.5, 1, 0, 1.0)
    check("no assist when too far", x < 3 - 0.5 - HALF + 1e-3, x .. "," .. z)

    -- 前方车道是墙时，即便靠近车道中心也不能滑进去
    x, z = run(map, 2, 2.8, 1, 0, 1.0)
    check("no assist into wall lane", x < 3 - 0.5 - HALF + 1e-3, x .. "," .. z)
end

---------------------------------------------------------------- 泡泡阻挡 / 穿透
do
    local map = mapFrom({
        "#######",
        "#.....#",
        "#######",
    })
    local ignore = {}
    local key = Grid.key(2, 2)
    map.bubbles[key] = true
    Movement.addIgnoreIfOverlap(ignore, key, 2, 2, 2, 2)
    check("overlapping player may pass", ignore[key] ~= nil)

    local x = run(map, 2, 2, 1, 0, 0.6, ignore)
    check("walks out of bubble", x > 2.5, x)
    check("ignore cleared after leaving", ignore[key] == nil)

    -- 离开后泡泡变成实体：走回去会被挡住
    x = run(map, x, 2, -1, 0, 2, ignore)
    check("bubble blocks after leaving", x >= 2.5 + HALF - 1e-3, x)

    -- 本来就没重叠的玩家不能穿过
    local other = {}
    Movement.addIgnoreIfOverlap(other, key, 2, 2, 5, 2)
    check("non-overlapping player gets no pass", next(other) == nil)
    x = run(map, 5, 2, -1, 0, 3, other)
    check("other player blocked by bubble", x >= 2.5 + HALF - 1e-3, x)
end

---------------------------------------------------------------- 爆炸
do
    local map = MapRules.createDefaultMap()
    -- (2,2) 威力 3：右边 (3,2) 空 -> (4,2) 箱子停；下边 (2,3) 空 -> (2,4) 箱子停
    local cells, crates, chained = BlastRules.compute(map, 2, 2, 3)
    check("default blast cell count", #cells == 5, #cells)
    check("default blast crates", #crates == 2, #crates)
    check("no chain", #chained == 0)

    -- 墙挡住火焰，且墙本身不被炸到
    local cells2 = BlastRules.compute(map, 3, 2, 3)
    local hitWall = false
    for _, c in cells2 do
        if c.col == 3 and c.row == 3 then
            hitWall = true
        end
    end
    check("wall blocks blast", not hitWall)

    -- 威力限制
    local open = mapFrom({
        "#########",
        "#.......#",
        "#########",
    })
    local c3 = BlastRules.compute(open, 5, 2, 2)
    check("power limits range", #c3 == 5, #c3)

    -- 连锁：另一个泡泡在范围内，被引爆并挡住后面的火焰
    open.bubbles[Grid.key(7, 2)] = true
    local c4, _, chain = BlastRules.compute(open, 5, 2, 3)
    check("chain detected", #chain == 1 and chain[1].col == 7, #chain)
    local reachesPast = false
    for _, c in c4 do
        if c.col == 8 then
            reachesPast = true
        end
    end
    check("bubble stops blast", not reachesPast)

    -- 出界
    local edge = mapFrom({ "...", "...", "..." })
    local c5 = BlastRules.compute(edge, 1, 1, 5)
    check("blast stays in bounds", #c5 == 1 + 2 + 2, #c5)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    error("tests failed")
end
