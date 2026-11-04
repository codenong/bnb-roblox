-- src/shared/Bot.luau
-- Port of BnB/server/bot.js: danger maps + BFS state machine.
-- Randomness goes through game.random so tests and matches are deterministic.

local Constants = require(script.Parent.Constants)
local Grid = require(script.Parent.Grid)
local Map = require(script.Parent.Map)
local Flame = require(script.Parent.Flame)

local TILE = Constants.TILE
local COLS = Constants.COLS
local ROWS = Constants.ROWS
local DIRS4 = Constants.DIRS4

local key = Grid.key
local tileOf = Grid.tileOf

local Bot = {}

local function isSoftAt(game, x: number, y: number): boolean
    if x < 0 or y < 0 or x >= COLS or y >= ROWS then
        return false
    end
    return Map.isSoft(game.grid[y][x])
end

-- All future flame cells of non-remote bombs. Soft danger: passable, but not
-- somewhere to stand.
function Bot.flameDangerMap(game)
    local danger = {}
    for _, bomb in ipairs(game.bombs) do
        if not bomb.remote then
            for _, cell in ipairs(Flame.computeFlameCells(game.grid, bomb.tx, bomb.ty, bomb.range)) do
                danger[key(cell[1], cell[2])] = true
            end
        end
    end
    return danger
end

-- Cells currently covered by an explosion. Hard danger: never step in.
function Bot.explosionSet(game)
    local set = {}
    for _, explosion in ipairs(game.explosions) do
        for _, cell in ipairs(explosion.cells) do
            set[key(cell[1], cell[2])] = true
        end
    end
    return set
end

local function mergeSets(a, b)
    local out = {}
    for k in pairs(a) do
        out[k] = true
    end
    for k in pairs(b) do
        out[k] = true
    end
    return out
end

local function cellIn(cells, x, y): boolean
    for _, cell in ipairs(cells) do
        if cell[1] == x and cell[2] == y then
            return true
        end
    end
    return false
end

local BotBrain = {}
BotBrain.__index = BotBrain

function Bot.new(id: string)
    return setmetatable({
        id = id,
        path = {},
        lastX = 0,
        lastY = 0,
        stuck = 0,
        escape = false,
        _wp = nil,
        _pdx = 0,
        _pdy = 0,
    }, BotBrain)
end

function BotBrain:walkable(game, x: number, y: number): boolean
    if x < 0 or y < 0 or x >= COLS or y >= ROWS then
        return false
    end
    if game.grid[y][x] ~= Map.EMPTY then
        return false
    end
    return not game:bombAt(x, y)
end

-- BFS shortest path. `avoid` cells are neither entered nor accepted as goal.
-- Returns a path excluding the start, nil when no path exists.
function BotBrain:bfs(game, sx, sy, isGoal, opts)
    opts = opts or {}
    local avoid = opts.avoid or {}
    local blocked = opts.blocked or {}
    local maxDepth = opts.maxDepth or 64

    if isGoal(sx, sy) and not avoid[key(sx, sy)] then
        return {}
    end

    local visited = { [key(sx, sy)] = true }
    for k in pairs(blocked) do
        visited[k] = true
    end

    local queue = { { sx, sy, {} } }
    local head = 1
    while head <= #queue do
        local node = queue[head]
        head += 1
        local x, y, path = node[1], node[2], node[3]
        if #path < maxDepth then
            for _, direction in ipairs(DIRS4) do
                local nx, ny = x + direction[1], y + direction[2]
                local nk = key(nx, ny)
                if not visited[nk] and self:walkable(game, nx, ny) then
                    visited[nk] = true
                    local np = {}
                    for i = 1, #path do
                        np[i] = path[i]
                    end
                    np[#np + 1] = { nx, ny }
                    if isGoal(nx, ny) and not avoid[nk] then
                        return np
                    end
                    if not avoid[nk] then
                        queue[#queue + 1] = { nx, ny, np }
                    end
                end
            end
        end
    end
    return nil
end

function BotBrain:followPath(me)
    while #self.path > 0 do
        local node = self.path[1]
        local nx, ny = node[1], node[2]
        local dx = nx * TILE + TILE / 2 - me.x
        local dy = ny * TILE + TILE / 2 - me.y
        local wp = key(nx, ny)
        if self._wp ~= wp then
            self._wp = wp
            self._pdx = dx
            self._pdy = dy
        end
        local crossed = (dx ~= 0 and self._pdx ~= 0 and Grid.sign(dx) ~= Grid.sign(self._pdx))
            or (dy ~= 0 and self._pdy ~= 0 and Grid.sign(dy) ~= Grid.sign(self._pdy))
        if (math.abs(dx) <= 3 and math.abs(dy) <= 3) or crossed then
            table.remove(self.path, 1)
            self._wp = nil
        else
            self._pdx = dx
            self._pdy = dy
            if math.abs(dx) >= math.abs(dy) then
                return { if dx > 0 then "right" else "left" }
            end
            return { if dy > 0 then "down" else "up" }
        end
    end
    return {}
end

function BotBrain:pathInvalid(game, union, boom): boolean
    if #self.path == 0 then
        return false
    end
    for _, node in ipairs(self.path) do
        local x, y = node[1], node[2]
        if boom[key(x, y)] or game:bombAt(x, y) then
            return true
        end
        if not self.escape and union[key(x, y)] then
            return true
        end
    end
    local last = self.path[#self.path]
    return union[key(last[1], last[2])] == true
end

function BotBrain:randomStep(game, tx: number, ty: number, danger)
    local options = {}
    for _, direction in ipairs(DIRS4) do
        local x, y = tx + direction[1], ty + direction[2]
        if self:walkable(game, x, y) and not danger[key(x, y)] then
            table.insert(options, { x, y })
        end
    end
    if #options == 0 then
        return {}
    end
    return { options[math.floor(game.random() * #options) + 1] }
end

function BotBrain:findObjective(game, me, tx: number, ty: number, danger)
    local items = game.items
    local enemies = {}
    for _, player in ipairs(game.playerOrder) do
        if player.id ~= self.id and player.alive and not player.trapped then
            table.insert(enemies, player)
        end
    end

    local itemGoal = function(x, y)
        for _, item in ipairs(items) do
            if item.x == x and item.y == y then
                return true
            end
        end
        return false
    end
    local enemyGoal = function(x, y)
        for _, enemy in ipairs(enemies) do
            if tileOf(enemy.x) == x and tileOf(enemy.y) == y then
                return true
            end
        end
        return false
    end
    local softGoal = function(x, y)
        for _, direction in ipairs(DIRS4) do
            if isSoftAt(game, x + direction[1], y + direction[2]) then
                return true
            end
        end
        return false
    end

    local chase = math.min(0.25 + (game.tickCount / Constants.ROUND_TICKS) * 0.5, 0.75)
    local tries
    if game.random() < chase and #enemies > 0 then
        tries = { enemyGoal, itemGoal, softGoal }
    else
        tries = { itemGoal, softGoal, enemyGoal }
    end

    for _, goal in ipairs(tries) do
        local path = self:bfs(game, tx, ty, goal, { avoid = danger })
        if path and #path > 0 then
            return path
        end
    end
    return nil
end

function BotBrain:tryPlace(game, me, tx: number, ty: number, flame, boom)
    local owned = 0
    for _, bomb in ipairs(game.bombs) do
        if bomb.ownerId == self.id then
            owned += 1
        end
    end
    if owned >= me.maxBombs or game:bombAt(tx, ty) then
        return nil
    end

    local nearSoft = false
    for _, direction in ipairs(DIRS4) do
        if isSoftAt(game, tx + direction[1], ty + direction[2]) then
            nearSoft = true
            break
        end
    end

    local nearEnemy = false
    for _, player in ipairs(game.playerOrder) do
        if player.id ~= self.id and player.alive and not player.trapped
            and math.abs(player.x - me.x) < TILE * 1.5
            and math.abs(player.y - me.y) < TILE * 1.5 then
            nearEnemy = true
            break
        end
    end
    if not nearSoft and not nearEnemy then
        return nil
    end

    local ownFlame = {}
    for _, cell in ipairs(Flame.computeFlameCells(game.grid, tx, ty, me.range)) do
        ownFlame[key(cell[1], cell[2])] = true
    end
    local soft = mergeSets(flame, ownFlame)
    local escape = self:bfs(game, tx, ty, function(x, y)
        return not soft[key(x, y)] and not boom[key(x, y)]
    end, {
        avoid = boom,
        blocked = { [key(tx, ty)] = true },
    })

    local desperation = game.tickCount / Constants.ROUND_TICKS
    local margin = Constants.BOMB_FUSE_TICKS
        - math.floor(0.6 * Constants.TICK_RATE + 0.5)
        - math.floor(desperation * 1.5 * Constants.TICK_RATE)
    local path = nil
    if escape and #escape > 0 then
        local ticksToWalk = #escape * (TILE / game:effSpeed(me) / Constants.DT)
        if ticksToWalk <= margin then
            path = escape
        end
    end
    if not path and not (nearEnemy and game.random() < math.max(0, desperation - 0.4)) then
        return nil
    end

    self.path = path or {}
    self.escape = path ~= nil

    if nearEnemy and not nearSoft and me.inv.remote > 0 then
        return { dirs = self:followPath(me), place = false, use = true }
    end
    return { dirs = self:followPath(me), place = true, use = false }
end

-- Returns {dirs, place, use}.
function BotBrain:decide(game)
    local me = game.players[self.id]
    if not me or not me.alive then
        return { dirs = {}, place = false, use = false }
    end
    if me.trapped then
        return { dirs = {}, place = false, use = me.inv.needle > 0 }
    end

    local tx = tileOf(me.x)
    local ty = tileOf(me.y)
    local k = key(tx, ty)
    local flame = Bot.flameDangerMap(game)
    local boom = Bot.explosionSet(game)
    local union = mergeSets(flame, boom)

    -- Own remote bomb: once out of its future flame, detonate it.
    for _, bomb in ipairs(game.bombs) do
        if bomb.remote and bomb.ownerId == self.id then
            local cells = Flame.computeFlameCells(game.grid, bomb.tx, bomb.ty, bomb.range)
            if not cellIn(cells, tx, ty) then
                return { dirs = self:followPath(me), place = true, use = false }
            end
        end
    end

    -- Stuck detection: no movement for ~1.25s clears the path.
    if math.abs(me.x - self.lastX) < 1 and math.abs(me.y - self.lastY) < 1 then
        self.stuck += 1
    else
        self.stuck = 0
    end
    self.lastX = me.x
    self.lastY = me.y
    if self.stuck > math.floor(1.25 * Constants.TICK_RATE + 0.5) then
        self.path = {}
        self.escape = false
        self.stuck = 0
    end

    local invalid = self:pathInvalid(game, union, boom)
    if invalid or (union[k] and #self.path == 0) then
        self.path = self:bfs(game, tx, ty, function(x, y)
            return not union[key(x, y)]
        end, { avoid = boom }) or self:randomStep(game, tx, ty, union)
        self.escape = true
    elseif #self.path == 0 then
        local placed = self:tryPlace(game, me, tx, ty, flame, boom)
        if placed then
            return placed
        end
        self.path = self:findObjective(game, me, tx, ty, union)
            or self:randomStep(game, tx, ty, union)
            or {}
        self.escape = false
    end
    return { dirs = self:followPath(me), place = false, use = false }
end

Bot.BotBrain = BotBrain

return table.freeze(Bot)
