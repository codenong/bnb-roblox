-- src/shared/Movement.luau
-- 玩家在 2D 网格上的移动与碰撞（纯逻辑）。
-- 客户端用它做本地预测，服务端用它做权威模拟，两边用同一份代码，结果才会一致。
--
-- 位置用连续的"格坐标"(x, z) 表示：格子 (col,row) 的中心就是 (col,row)，
-- 覆盖范围 [col-0.5, col+0.5)。玩家是边长 2*HALF 的方形碰撞盒。

local Constants = require(script.Parent.Constants)

local HALF = Constants.PLAYER_HALF_SIZE
local SLIDE = Constants.CORNER_SLIDE
local EPS = 1e-4
local MAX_SUBSTEP = 1 / 30

local floor = math.floor
local abs = math.abs

local Movement = {}

-- 沿一个轴移动 delta，遇到阻挡就贴边停下。
-- pos:    本轴上的位置
-- across: 另一个轴上的位置（决定碰撞盒覆盖哪几行/列）
-- solidAt(alongCell, acrossCell) -> boolean
local function sweep(pos: number, across: number, delta: number, solidAt): number
    if delta == 0 then
        return pos
    end

    local newPos = pos + delta
    local acrossMin = floor(across - HALF + 0.5)
    local acrossMax = floor(across + HALF - EPS + 0.5)

    if delta > 0 then
        -- 只检查"新进入"的那些列：从当前前沿所在格的下一格，到新前沿所在格
        local fromCell = floor(pos + HALF - EPS + 0.5)
        local toCell = floor(newPos + HALF - EPS + 0.5)

        for cell = fromCell + 1, toCell do
            for other = acrossMin, acrossMax do
                if solidAt(cell, other) then
                    return (cell - 0.5) - HALF
                end
            end
        end
    else
        local fromCell = floor(pos - HALF + 0.5)
        local toCell = floor(newPos - HALF + 0.5)

        for cell = fromCell - 1, toCell, -1 do
            for other = acrossMin, acrossMax do
                if solidAt(cell, other) then
                    return (cell + 0.5) + HALF
                end
            end
        end
    end

    return newPos
end

-- 单个子步：先移动 X，再移动 Z，然后做拐角辅助
local function substep(isSolid, x: number, z: number, dirX: number, dirZ: number, speed: number, dt: number)
    local dx = dirX * speed * dt
    local dz = dirZ * speed * dt

    local solidX = function(col, row)
        return isSolid(col, row)
    end
    local solidZ = function(row, col)
        return isSolid(col, row)
    end

    local newX = sweep(x, z, dx, solidX)
    local newZ = sweep(z, newX, dz, solidZ)

    -- 拐角辅助：只在单方向移动且被挡住时生效。
    -- 如果偏离"车道"中心不远，并且车道前方是空的，就自动往车道中心滑，
    -- 这样略微没对齐也能顺利拐进走廊。
    local movedX = abs(newX - x)
    local movedZ = abs(newZ - z)

    if dirX ~= 0 and dirZ == 0 and movedX < abs(dx) - EPS then
        local lane = floor(newZ + 0.5)
        local offset = lane - newZ
        if abs(offset) > EPS and abs(offset) <= SLIDE then
            local probe = dirX > 0 and (newX + HALF + 0.05) or (newX - HALF - 0.05)
            local aheadCol = floor(probe + 0.5)
            if not isSolid(aheadCol, lane) then
                local step = math.min(abs(offset), speed * dt)
                newZ = sweep(newZ, newX, offset > 0 and step or -step, solidZ)
            end
        end
    elseif dirZ ~= 0 and dirX == 0 and movedZ < abs(dz) - EPS then
        local lane = floor(newX + 0.5)
        local offset = lane - newX
        if abs(offset) > EPS and abs(offset) <= SLIDE then
            local probe = dirZ > 0 and (newZ + HALF + 0.05) or (newZ - HALF - 0.05)
            local aheadRow = floor(probe + 0.5)
            if not isSolid(lane, aheadRow) then
                local step = math.min(abs(offset), speed * dt)
                newX = sweep(newX, newZ, offset > 0 and step or -step, solidX)
            end
        end
    end

    return newX, newZ
end

-- 推进一帧。dir 是输入方向（长度 <= 1），speed 单位：格/秒
-- 返回新的 (x, z)
function Movement.step(isSolid, x: number, z: number, dirX: number, dirZ: number, speed: number, dt: number): (number, number)
    if (dirX == 0 and dirZ == 0) or dt <= 0 then
        return x, z
    end

    local remaining = dt
    while remaining > 1e-6 do
        local h = math.min(remaining, MAX_SUBSTEP)
        x, z = substep(isSolid, x, z, dirX, dirZ, speed, h)
        remaining -= h
    end

    return x, z
end

-- 玩家碰撞盒是否和某个格子重叠
local function overlapsCell(x: number, z: number, col: number, row: number): boolean
    return abs(x - col) < 0.5 + HALF and abs(z - row) < 0.5 + HALF
end

Movement.overlapsCell = overlapsCell

-- 刚放下泡泡时，和泡泡重叠的玩家可以穿过它，直到完全离开
-- ignore: { [key] = {col, row} }
function Movement.addIgnoreIfOverlap(ignore, key: number, col: number, row: number, x: number, z: number)
    if overlapsCell(x, z, col, row) then
        ignore[key] = { col, row }
    end
end

-- 每帧调用：离开了泡泡的玩家，移除穿透权限（之后泡泡变成实体）
function Movement.refreshIgnore(ignore, x: number, z: number)
    for key, cell in ignore do
        if not overlapsCell(x, z, cell[1], cell[2]) then
            ignore[key] = nil
        end
    end
end

return table.freeze(Movement)
