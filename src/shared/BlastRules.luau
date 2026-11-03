-- src/shared/BlastRules.luau
-- 爆炸范围计算（纯逻辑，不修改地图）

local Constants = require(script.Parent.Constants)
local Grid = require(script.Parent.Grid)
local MapRules = require(script.Parent.MapRules)

local TILE = Constants.TILE

local BlastRules = {}

local DIRECTIONS = {
    { 1, 0 },
    { -1, 0 },
    { 0, 1 },
    { 0, -1 },
}

-- 计算以 (col,row) 为中心、威力为 power 的爆炸
-- 规则：
--   * 中心格一定被炸到
--   * 向四个方向延伸最多 power 格
--   * 遇到固定墙：停止（墙本身不被炸到）
--   * 遇到箱子：该格被炸到，箱子被摧毁，然后停止
--   * 遇到其他泡泡：该格被炸到，并引爆那个泡泡，然后停止
-- 返回：
--   cells   被火焰覆盖的格子 { {col=,row=}, ... }
--   crates  被摧毁的箱子
--   chained 被连锁引爆的其他泡泡
function BlastRules.compute(map, col: number, row: number, power: number)
    local cells = { { col = col, row = row } }
    local crates = {}
    local chained = {}

    for _, dir in DIRECTIONS do
        for step = 1, power do
            local c = col + dir[1] * step
            local r = row + dir[2] * step
            local tile = MapRules.getCell(map, c, r)

            if tile == nil or tile == TILE.WALL then
                break
            end

            table.insert(cells, { col = c, row = r })

            if tile == TILE.CRATE then
                table.insert(crates, { col = c, row = r })
                break
            end

            if map.bubbles[Grid.key(c, r)] then
                table.insert(chained, { col = c, row = r })
                break
            end
        end
    end

    return cells, crates, chained
end

return table.freeze(BlastRules)
