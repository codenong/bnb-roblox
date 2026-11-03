-- src/server/BombService.luau
-- 泡泡：放置、倒计时、爆炸、连锁、火焰、摧毁箱子

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BlastRules = require(Shared:WaitForChild("BlastRules"))
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local MapRules = require(Shared:WaitForChild("MapRules"))
local Movement = require(Shared:WaitForChild("Movement"))
local Net = require(Shared:WaitForChild("Net"))

local MapService = require(script.Parent:WaitForChild("MapService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local BombService = {}

local TILE = Constants.TILE
local CELL_SIZE = Constants.CELL_SIZE

-- [Grid.key] = { col, row, owner, power, explodeAt, part }
local bubbles = {}
-- [Grid.key] = 火焰消失的时间。火焰存在期间，踩进去的玩家也会被困
local flames = {}

local container: Folder? = nil

local function getContainer(): Folder
    if container == nil or container.Parent == nil then
        container = Instance.new("Folder")
        container.Name = "Bubbles"
        container.Parent = workspace
    end
    return container :: Folder
end

local function createBubblePart(col: number, row: number): Part
    local diameter = CELL_SIZE * 0.7
    local part = Instance.new("Part")
    part.Name = "Bubble_" .. col .. "_" .. row
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(diameter, diameter, diameter)
    part.Position = Grid.cellToWorld(col, row, diameter / 2)
    part.Anchored = true
    part.CanCollide = false -- 碰撞由网格逻辑负责，不依赖物理
    part.CanQuery = false
    part.Color = Color3.fromRGB(120, 200, 255)
    part.Material = Enum.Material.Glass
    part.Transparency = 0.3
    part.Parent = getContainer()
    return part
end

local function createFlamePart(col: number, row: number)
    local part = Instance.new("Part")
    part.Name = "Flame"
    part.Size = Vector3.new(CELL_SIZE * 0.94, 0.6, CELL_SIZE * 0.94)
    part.Position = Grid.cellToWorld(col, row, 0.5)
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Color = Color3.fromRGB(255, 150, 40)
    part.Material = Enum.Material.Neon
    part.Transparency = 0.25
    part.Parent = getContainer()
    Debris:AddItem(part, Constants.BLAST_VISIBLE_TIME)
end

-- 新的一局之前清理所有泡泡和火焰
function BombService.reset()
    for _, bubble in bubbles do
        bubble.part:Destroy()
    end
    table.clear(bubbles)
    table.clear(flames)

    if container then
        container:ClearAllChildren()
    end

    local map = MapService.map
    if map then
        table.clear(map.bubbles)
    end
end

-- 返回是否放置成功
function BombService.place(state, col: any, row: any, now: number): boolean
    local map = MapService.map
    if not map or not state.alive or state.trappedUntil then
        return false
    end

    -- 参数校验：必须是整数
    if typeof(col) ~= "number" or typeof(row) ~= "number" then
        return false
    end
    if col ~= math.floor(col) or row ~= math.floor(row) then
        return false
    end

    -- 客户端报告的位置必须和服务端位置接近（容忍网络延迟）
    if math.abs(state.x - col) > 1 or math.abs(state.z - row) > 1 then
        return false
    end

    if state.activeBubbles >= state.maxBubbles then
        return false
    end
    if MapRules.getCell(map, col, row) ~= TILE.EMPTY then
        return false
    end

    local key = Grid.key(col, row)
    if map.bubbles[key] then
        return false
    end

    map.bubbles[key] = true
    bubbles[key] = {
        col = col,
        row = row,
        owner = state,
        power = state.power,
        explodeAt = now + Constants.BUBBLE_FUSE,
        part = createBubblePart(col, row),
    }
    state.activeBubbles += 1

    -- 和泡泡重叠的玩家可以走出来（放泡泡的人自己，以及恰好站在旁边的人）
    for _, other in PlayerService.all() do
        if other.alive then
            Movement.addIgnoreIfOverlap(other.ignore, key, col, row, other.x, other.z)
        end
    end

    Net.broadcast("BubblePlaced", col, row, state.userId)
    return true
end

-- 引爆一批泡泡（包含连锁）。所有爆炸基于同一时刻的地图计算，结果和顺序无关。
local function explode(startKeys: { number }, now: number)
    local exploded = {}
    local blasts = {}
    local cratesToBreak = {}
    local map = MapService.map

    local stack = table.clone(startKeys)
    while #stack > 0 do
        local key = table.remove(stack) :: number
        local bubble = bubbles[key]

        if bubble and not exploded[key] then
            exploded[key] = true

            local cells, crates, chained = BlastRules.compute(map, bubble.col, bubble.row, bubble.power)
            table.insert(blasts, cells)

            for _, crate in crates do
                cratesToBreak[Grid.key(crate.col, crate.row)] = crate
            end
            for _, cell in chained do
                local chainKey = Grid.key(cell.col, cell.row)
                if not exploded[chainKey] then
                    table.insert(stack, chainKey)
                end
            end
        end
    end

    -- 应用结果
    local removedBubbles = {}
    for key in exploded do
        local bubble = bubbles[key]
        bubbles[key] = nil
        map.bubbles[key] = nil
        bubble.part:Destroy()
        table.insert(removedBubbles, bubble.col)
        table.insert(removedBubbles, bubble.row)

        if bubble.owner then
            bubble.owner.activeBubbles = math.max(0, bubble.owner.activeBubbles - 1)
        end
    end

    local brokenCrates = {}
    for _, crate in cratesToBreak do
        MapService.destroyCrate(crate.col, crate.row)
        table.insert(brokenCrates, crate.col)
        table.insert(brokenCrates, crate.row)
    end

    local flameCells = {}
    for _, cells in blasts do
        for _, cell in cells do
            local key = Grid.key(cell.col, cell.row)
            if not flames[key] then
                createFlamePart(cell.col, cell.row)
                table.insert(flameCells, cell.col)
                table.insert(flameCells, cell.row)
            end
            flames[key] = now + Constants.BLAST_VISIBLE_TIME
        end
    end

    -- 客户端据此更新本地地图（用于预测碰撞）和播放效果
    Net.broadcast("Explosion", removedBubbles, brokenCrates, flameCells)
end

function BombService.update(now: number)
    local map = MapService.map
    if not map then
        return
    end

    local due = {}
    for key, bubble in bubbles do
        if now >= bubble.explodeAt then
            table.insert(due, key)
        end
    end
    if #due > 0 then
        explode(due, now)
    end

    -- 火焰：到期清除；存在期间持续困住站在里面的玩家
    local activeFlames = nil
    for key, expireAt in flames do
        if now >= expireAt then
            flames[key] = nil
        else
            activeFlames = activeFlames or {}
            activeFlames[key] = true
        end
    end
    if activeFlames then
        PlayerService.trapInCells(activeFlames, now)
    end
end

-- 当前的泡泡列表（扁平数组 col,row,col,row...），用于新加入的客户端同步
function BombService.flatList(): { number }
    local list = {}
    for _, bubble in bubbles do
        table.insert(list, bubble.col)
        table.insert(list, bubble.row)
    end
    return list
end

return BombService
