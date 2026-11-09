-- src/shared/Game.luau
-- Pure Luau port of BnB/server/game.js. No Roblox APIs.
--
-- Coordinates are original BnB pixels (TILE=40, 0-based tiles). All movement,
-- bombs, flames, items, mounts, pushing, kicking, traps and win/loss live here.

local Constants = require(script.Parent.Constants)
local Grid = require(script.Parent.Grid)
local Map = require(script.Parent.Map)
local Characters = require(script.Parent.Characters)
local Mounts = require(script.Parent.Mounts)
local Flame = require(script.Parent.Flame)
local Movement = require(script.Parent.Movement)

local TILE = Constants.TILE
local COLS = Constants.COLS
local ROWS = Constants.ROWS
local HALF = Constants.HALF
local DIRS4 = Constants.DIRS4
local DIR_VEC = Constants.DIR_VEC

local Game = {}
Game.__index = Game

local EMPTY = Map.EMPTY
local WALL = Map.WALL
local HOUSE = Map.HOUSE
local CRATE = Map.CRATE

local function key(x: number, y: number): string
    return Grid.key(x, y)
end

local function bombExists(self, bomb): boolean
    for i = 1, #self.bombs do
        if self.bombs[i] == bomb then
            return true
        end
    end
    return false
end

local function removeBomb(self, bomb)
    for i = #self.bombs, 1, -1 do
        if self.bombs[i] == bomb then
            table.remove(self.bombs, i)
            break
        end
    end
    local pos = key(bomb.tx, bomb.ty)
    if self.bombsByPos[pos] == bomb then
        self.bombsByPos[pos] = nil
    end
end

local function carriedCount(carry, itemId, maximum)
    local value = if type(carry) == "table" then carry[itemId] else 0
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return math.clamp(math.floor(value), 0, maximum)
end

function Game.new(playerDefs, opts)
    opts = opts or {}
    local self = setmetatable({}, Game)

    self.random = opts.random or math.random
    self.grid = Map.buildMap()
    self.tickCount = 0
    self.players = {}
    self.playerOrder = {}
    self.bombs = {}
    self.bombsByPos = {}
    self.explosions = {}
    self.crateSlides = {}
    self.items = {}
    self.lootShots = {}
    self.warmup = if opts.warmup ~= nil then opts.warmup else Constants.WARMUP_TICKS
    self.over = false
    self.winner = nil
    self.gridVer = 0
    self._sentGridVer = -1
    self._bombSeq = 0
    self._explosionSeq = 0

    for i, def in ipairs(playerDefs or {}) do
        local spawn = Map.SPAWNS[((i - 1) % #Map.SPAWNS) + 1]
        local char = Characters.getChar(def.char)
        -- Brought items are a snapshot for this round. `used` counts real uses,
        -- including items picked up from the map; settlement later charges at
        -- most the number that was brought, so a map pickup is free only once
        -- the brought stock for that item is exhausted.
        local carry = def.carry
        local carried = {
            needle = carriedCount(carry, "needle", Constants.MAX_NEEDLE),
            remote = carriedCount(carry, "remote", Constants.MAX_REMOTE),
            kick = carriedCount(carry, "kick", 1),
        }
        local player = {
            id = def.id,
            name = def.name,
            isBot = def.isBot == true,
            colorIndex = Characters.sanitizeColorIndex(def.colorIndex, i - 1),
            char = char.id,
            x = spawn[1] * TILE + TILE / 2,
            y = spawn[2] * TILE + TILE / 2,
            dirs = {},
            -- Last sequenced input command the server applied for this player.
            -- Snapshots carry it back so the client can replay only newer input.
            ack = 0,
            speed = char.speed,
            maxBombs = char.bombs,
            range = char.range,
            caps = {
                speed = char.caps.speed,
                range = char.caps.range,
                bombs = char.caps.bombs,
            },
            inv = { needle = carried.needle, remote = carried.remote },
            carried = carried,
            used = { needle = 0, remote = 0, kick = 0 },
            eaten = {},
            kick = carried.kick > 0,
            pushKey = nil,
            pushAcc = 0,
            mount = nil,
            grace = 0,
            alive = true,
            trapped = false,
            trapTicks = 0,
            disconnected = false,
        }
        self.players[player.id] = player
        table.insert(self.playerOrder, player)
    end

    for _, spot in ipairs(Map.MOUNT_SPOTS) do
        table.insert(self.items, { x = spot[1], y = spot[2], kind = spot[3] })
    end

    return self
end

function Game:gridRows()
    return Grid.gridToRows(self.grid)
end

function Game:setInput(id: string, dirs, seq: number?)
    local player = self.players[id]
    if not player then
        return
    end
    local valid = { up = true, down = true, left = true, right = true }
    local filtered = {}
    for _, direction in ipairs(dirs or {}) do
        if valid[direction] then
            table.insert(filtered, direction)
        end
    end
    if #filtered > 4 then
        local tail = {}
        for i = #filtered - 3, #filtered do
            table.insert(tail, filtered[i])
        end
        filtered = tail
    end
    player.dirs = filtered
    if type(seq) == "number" then
        player.ack = seq
    end
end

function Game:bombAt(tx: number, ty: number)
    return self.bombsByPos[key(tx, ty)]
end

function Game:hasRemoteOut(id: string): boolean
    for _, bomb in ipairs(self.bombs) do
        if bomb.remote and bomb.ownerId == id then
            return true
        end
    end
    return false
end

function Game:detonate(id: string): boolean
    local any = false
    for _, bomb in ipairs(self.bombs) do
        if bomb.remote and bomb.ownerId == id then
            bomb.fuse = 0
            any = true
        end
    end
    return any
end

function Game:placeBomb(id: string, remote: boolean?): boolean
    local player = self.players[id]
    if not player or not player.alive or player.trapped or self.over or self.warmup > 0 then
        return false
    end
    if not remote and self:hasRemoteOut(id) then
        return self:detonate(id)
    end
    if remote and player.inv.remote <= 0 then
        return false
    end

    local tx = math.floor(player.x / TILE)
    local ty = math.floor(player.y / TILE)
    if self:bombAt(tx, ty) then
        return false
    end

    local owned = 0
    for _, bomb in ipairs(self.bombs) do
        if bomb.ownerId == id then
            owned += 1
        end
    end
    if owned >= player.maxBombs then
        return false
    end

    if remote then
        player.inv.remote -= 1
        player.used.remote += 1
    end

    self._bombSeq += 1
    local bomb = {
        id = self._bombSeq,
        tx = tx,
        ty = ty,
        range = player.range,
        ownerId = id,
        px = tx * TILE + TILE / 2,
        py = ty * TILE + TILE / 2,
        slide = nil,
        fuse = if remote then Constants.REMOTE_FUSE else Constants.BOMB_FUSE_TICKS,
        remote = remote == true,
        pass = {},
    }
    for _, other in ipairs(self.playerOrder) do
        if other.alive and self:overlapsTile(other, tx, ty) then
            bomb.pass[other.id] = true
        end
    end
    table.insert(self.bombs, bomb)
    self.bombsByPos[key(tx, ty)] = bomb
    return true
end

function Game:useItem(id: string): boolean
    local player = self.players[id]
    if not player or not player.alive or self.over then
        return false
    end
    if player.trapped then
        if player.inv.needle <= 0 then
            return false
        end
        player.inv.needle -= 1
        player.used.needle += 1
        player.trapped = false
        player.trapTicks = 0
        player.grace = Constants.EXPLOSION_TICKS + 10
        return true
    end
    return self:placeBomb(id, true)
end

-- Copy of the round's actual item usage and the carried snapshot it is charged
-- against. Map pickups only change `inv`, never these two tables.
function Game:getItemUsage(id: string)
    local player = self.players[id]
    if not player then
        return nil
    end
    return {
        needle = player.used.needle,
        remote = player.used.remote,
        kick = player.used.kick,
    }, {
        needle = player.carried.needle,
        remote = player.carried.remote,
        kick = player.carried.kick,
    }
end

function Game:overlapsTile(player, tx: number, ty: number): boolean
    return player.x + HALF > tx * TILE
        and player.x - HALF < tx * TILE + TILE
        and player.y + HALF > ty * TILE
        and player.y - HALF < ty * TILE + TILE
end

-- Movement itself lives in the shared Movement module so client prediction runs
-- exactly the same collision and corner-assist code as the server. These
-- wrappers keep the existing Game-facing API used by tests and other modules.
function Game:solidFor(tx: number, ty: number, player): boolean
    return Movement.solidFor(self, tx, ty, player)
end

function Game:collides(player, x: number, y: number): boolean
    return Movement.collides(self, player, x, y)
end

function Game:tryMove(player, dx: number, dy: number): boolean
    return Movement.tryMove(self, player, dx, dy)
end

function Game:effSpeed(player): number
    return Movement.effSpeed(player)
end

function Game:movePlayer(player)
    local status = Movement.step(self, player)
    if status == "blocked" then
        local dir = player.dirs[#player.dirs]
        if dir then
            self:tryKick(player, dir)
            self:tryPush(player, dir)
        end
    end
end

function Game:frontTiles(player, dir)
    local vec = DIR_VEC[dir]
    local bx = math.floor((player.x + vec[1] * HALF) / TILE)
    local by = math.floor((player.y + vec[2] * HALF) / TILE)
    return { { bx, by }, { bx + vec[1], by + vec[2] } }
end

function Game:pushCandidate(player, dir)
    for _, tile in ipairs(self:frontTiles(player, dir)) do
        local tx, ty = tile[1], tile[2]
        local row = self.grid[ty]
        if row and row[tx] == CRATE then
            return { tx, ty }
        end
    end
    return nil
end

function Game:tryKick(player, dir)
    if not player.kick or player.mount then
        return
    end
    local vec = DIR_VEC[dir]
    local bomb = nil
    for _, tile in ipairs(self:frontTiles(player, dir)) do
        bomb = self:bombAt(tile[1], tile[2])
        if bomb then
            break
        end
    end
    if not bomb or bomb.slide then
        return
    end
    bomb.slide = { dx = vec[1], dy = vec[2] }
    -- The kick ability lasts the whole match; a successful kick is charged once.
    player.used.kick = 1
end

function Game:updateBombSlides()
    for i = 1, #self.bombs do
        local bomb = self.bombs[i]
        if bomb.slide then
            local dx, dy = bomb.slide.dx, bomb.slide.dy
            bomb.px += dx * Constants.KICK_SPEED * Constants.DT
            bomb.py += dy * Constants.KICK_SPEED * Constants.DT
            local tx = math.floor(bomb.px / TILE)
            local ty = math.floor(bomb.py / TILE)
            if tx ~= bomb.tx or ty ~= bomb.ty then
                local blocked = tx < 0 or ty < 0 or tx >= COLS or ty >= ROWS
                    or self.grid[ty][tx] ~= EMPTY
                local other = self:bombAt(tx, ty)
                if other and other ~= bomb then
                    blocked = true
                end
                if not blocked then
                    for _, player in ipairs(self.playerOrder) do
                        if player.alive and self:overlapsTile(player, tx, ty) then
                            blocked = true
                            break
                        end
                    end
                end
                if blocked then
                    bomb.px = bomb.tx * TILE + TILE / 2
                    bomb.py = bomb.ty * TILE + TILE / 2
                    bomb.slide = nil
                    bomb.pass = {}
                    for _, player in ipairs(self.playerOrder) do
                        if player.alive and self:overlapsTile(player, bomb.tx, bomb.ty) then
                            bomb.pass[player.id] = true
                        end
                    end
                else
                    self.bombsByPos[key(bomb.tx, bomb.ty)] = nil
                    bomb.tx = tx
                    bomb.ty = ty
                    self.bombsByPos[key(tx, ty)] = bomb
                    bomb.pass = {}
                    for _, player in ipairs(self.playerOrder) do
                        if player.alive and self:overlapsTile(player, tx, ty) then
                            bomb.pass[player.id] = true
                        end
                    end
                end
            end
        end
    end
end

function Game:tryPush(player, dir)
    local candidate = self:pushCandidate(player, dir)
    local pushKey = if candidate then key(candidate[1], candidate[2]) .. "," .. dir else nil
    if candidate and pushKey == player.pushKey then
        player.pushAcc += 1
    else
        player.pushKey = pushKey
        player.pushAcc = if candidate then 1 else 0
    end
    if not candidate or player.pushAcc < Constants.PUSH_TICKS then
        return
    end
    player.pushAcc = 0

    local vec = DIR_VEC[dir]
    local tx, ty = candidate[1], candidate[2]
    local nx, ny = tx + vec[1], ty + vec[2]

    for _, slide in ipairs(self.crateSlides) do
        if slide.tx == nx and slide.ty == ny then
            return
        end
        if slide.fx == tx and slide.fy == ty then
            return
        end
    end
    if nx < 0 or ny < 0 or nx >= COLS or ny >= ROWS then
        return
    end
    if self.grid[ny][nx] ~= EMPTY then
        return
    end
    if self:bombAt(nx, ny) then
        return
    end
    for _, item in ipairs(self.items) do
        if item.x == nx and item.y == ny then
            return
        end
    end
    for _, other in ipairs(self.playerOrder) do
        if other.alive and self:overlapsTile(other, nx, ny) then
            return
        end
    end

    table.insert(self.crateSlides, {
        fx = tx,
        fy = ty,
        tx = nx,
        ty = ny,
        left = Constants.SLIDE_TICKS,
        total = Constants.SLIDE_TICKS,
    })
end

function Game:updateCrateSlides()
    for i = #self.crateSlides, 1, -1 do
        local slide = self.crateSlides[i]
        slide.left -= 1
        if slide.left <= 0 then
            table.remove(self.crateSlides, i)
            if self.grid[slide.fy][slide.fx] == CRATE then
                self.grid[slide.fy][slide.fx] = EMPTY
                self.grid[slide.ty][slide.tx] = CRATE
                self.gridVer += 1
            end
        end
    end
end

function Game:updateBombPass()
    for _, bomb in ipairs(self.bombs) do
        local ids = {}
        for id in pairs(bomb.pass) do
            table.insert(ids, id)
        end
        for _, id in ipairs(ids) do
            local player = self.players[id]
            if not player or not player.alive or not self:overlapsTile(player, bomb.tx, bomb.ty) then
                bomb.pass[id] = nil
            end
        end
    end
end

function Game:updateBombs()
    local queue = {}
    for _, bomb in ipairs(self.bombs) do
        if not bomb.remote then
            bomb.fuse -= 1
        end
        if bomb.fuse <= 0 then
            table.insert(queue, bomb)
        end
    end

    local destroyedSet = {}
    local destroyed = {}

    while #queue > 0 do
        local bomb = table.remove(queue, 1)
        if bombExists(self, bomb) then
            removeBomb(self, bomb)
            local cells = Flame.computeFlameCells(self.grid, bomb.tx, bomb.ty, bomb.range)
            self._explosionSeq += 1
            table.insert(self.explosions, {
                id = self._explosionSeq,
                cells = cells,
                ttl = Constants.EXPLOSION_TICKS,
                ownerId = bomb.ownerId,
            })

            local cellSet = {}
            for _, cell in ipairs(cells) do
                cellSet[key(cell[1], cell[2])] = true
            end
            local keptItems = {}
            for _, item in ipairs(self.items) do
                if not cellSet[key(item.x, item.y)] then
                    table.insert(keptItems, item)
                end
            end
            self.items = keptItems

            for _, cell in ipairs(cells) do
                local x, y = cell[1], cell[2]
                if Map.isSoft(self.grid[y][x]) and not destroyedSet[key(x, y)] then
                    destroyedSet[key(x, y)] = true
                    table.insert(destroyed, { x, y })
                end
                local chained = self:bombAt(x, y)
                if chained then
                    table.insert(queue, chained)
                end
            end
        end
    end

    for _, cell in ipairs(destroyed) do
        local x, y = cell[1], cell[2]
        if Map.isSoft(self.grid[y][x]) then
            self.grid[y][x] = EMPTY
            self.gridVer += 1
            if self.random() < Constants.ITEM_DROP_RATE then
                table.insert(self.items, { x = x, y = y, kind = self:rollItem() })
            end
        end
    end
end

function Game:rollItem(): string
    local r = self.random()
    if r < 0.28 then
        return "potion"
    elseif r < 0.48 then
        return "bubble"
    elseif r < 0.64 then
        return "shoe"
    elseif r < 0.72 then
        return "needle"
    elseif r < 0.8 then
        return "remote"
    elseif r < 0.88 then
        return "kick"
    elseif r < 0.945 then
        return "gremlin"
    elseif r < 0.965 then
        return "devil"
    elseif r < 0.9775 then
        return "pirateTurtle"
    elseif r < 0.99 then
        return "owl"
    end
    return "ufo"
end

function Game:updateExplosions()
    for i = #self.explosions, 1, -1 do
        local explosion = self.explosions[i]
        explosion.ttl -= 1
        if explosion.ttl <= 0 then
            table.remove(self.explosions, i)
        end
    end
end

function Game:applyFlameDamage()
    if #self.explosions == 0 then
        return
    end
    local danger = {}
    for _, explosion in ipairs(self.explosions) do
        for _, cell in ipairs(explosion.cells) do
            danger[key(cell[1], cell[2])] = true
        end
    end
    for _, player in ipairs(self.playerOrder) do
        if player.alive and not player.trapped then
            local pos = key(math.floor(player.x / TILE), math.floor(player.y / TILE))
            if danger[pos] and player.grace <= 0 then
                if player.mount then
                    player.mount = nil
                    player.grace = Constants.EXPLOSION_TICKS + 10
                else
                    player.trapped = true
                    player.trapTicks = Constants.TRAP_TICKS
                    player.dirs = {}
                end
            end
        end
    end
end

function Game:kill(player)
    player.alive = false
    player.trapped = false
    player.dirs = {}
    self:dropLoot(player)
end

function Game:dropLoot(player)
    local tx = math.floor(player.x / TILE)
    local ty = math.floor(player.y / TILE)
    for _, kind in ipairs(player.eaten) do
        if self.random() < Constants.DEATH_DROP_RATE then
            local shot = self:makeLootShot(kind, tx, ty)
            if shot then
                table.insert(self.lootShots, shot)
            end
        end
    end
    player.eaten = {}
end

function Game:makeLootShot(kind: string, tx: number, ty: number)
    local dirs = {}
    for i, direction in ipairs(DIRS4) do
        dirs[i] = { direction[1], direction[2] }
    end
    for i = #dirs, 2, -1 do
        local j = math.floor(self.random() * i) + 1
        dirs[i], dirs[j] = dirs[j], dirs[i]
    end

    local reserved = {}
    for _, shot in ipairs(self.lootShots) do
        reserved[key(shot.tx, shot.ty)] = true
    end

    for _, direction in ipairs(dirs) do
        local vx, vy = direction[1], direction[2]
        local dist = 1 + math.floor(self.random() * 3)
        local land = nil
        for d = 1, dist do
            local x, y = tx + vx * d, ty + vy * d
            if not self:lootLandable(x, y, reserved) then
                break
            end
            land = { x, y }
        end
        if land then
            return self:lootShot(kind, tx, ty, land[1], land[2])
        end
    end
    if self:lootLandable(tx, ty, reserved) then
        return self:lootShot(kind, tx, ty, tx, ty)
    end
    return nil
end

function Game:lootShot(kind: string, fx: number, fy: number, tx: number, ty: number)
    local dist = math.abs(tx - fx) + math.abs(ty - fy)
    local total = Constants.LOOT_FLY_BASE + dist * Constants.LOOT_FLY_PER_TILE
    return {
        kind = kind,
        tx = tx,
        ty = ty,
        x0 = fx * TILE + TILE / 2,
        y0 = fy * TILE + TILE / 2,
        x1 = tx * TILE + TILE / 2,
        y1 = ty * TILE + TILE / 2,
        left = total,
        total = total,
    }
end

function Game:lootLandable(x: number, y: number, reserved): boolean
    if x < 0 or y < 0 or x >= COLS or y >= ROWS then
        return false
    end
    if self.grid[y][x] ~= EMPTY then
        return false
    end
    if self:bombAt(x, y) then
        return false
    end
    for _, item in ipairs(self.items) do
        if item.x == x and item.y == y then
            return false
        end
    end
    return not reserved[key(x, y)]
end

function Game:updateLootShots()
    local i = 1
    while i <= #self.lootShots do
        local shot = self.lootShots[i]
        shot.left -= 1
        if shot.left > 0 then
            i += 1
        else
            table.remove(self.lootShots, i)
            if shot.tx >= 0 and shot.ty >= 0 and shot.tx < COLS and shot.ty < ROWS
                and self.grid[shot.ty][shot.tx] == EMPTY then
                table.insert(self.items, { x = shot.tx, y = shot.ty, kind = shot.kind })
            end
        end
    end
end

function Game:updateTraps()
    for _, player in ipairs(self.playerOrder) do
        if player.alive and player.trapped then
            player.trapTicks -= 1
            if player.trapTicks <= 0 then
                self:kill(player)
            end
        end
    end

    local trapped = {}
    local free = {}
    for _, player in ipairs(self.playerOrder) do
        if player.alive then
            if player.trapped then
                table.insert(trapped, player)
            else
                table.insert(free, player)
            end
        end
    end

    for _, victim in ipairs(trapped) do
        for _, other in ipairs(free) do
            if math.abs(victim.x - other.x) < TILE * 0.7
                and math.abs(victim.y - other.y) < TILE * 0.7 then
                self:kill(victim)
                break
            end
        end
    end
end

function Game:updateItems()
    for _, player in ipairs(self.playerOrder) do
        if player.alive and not player.trapped and player.mount ~= "ufo" then
            local tx = math.floor(player.x / TILE)
            local ty = math.floor(player.y / TILE)
            local index = nil
            for i, item in ipairs(self.items) do
                if item.x == tx and item.y == ty then
                    index = i
                    break
                end
            end
            if index then
                local item = table.remove(self.items, index)
                table.insert(player.eaten, item.kind)
                if item.kind == "potion" then
                    player.range = math.min(player.range + 1, player.caps.range)
                elseif item.kind == "bubble" then
                    player.maxBombs = math.min(player.maxBombs + 1, player.caps.bombs)
                elseif item.kind == "shoe" then
                    player.speed = math.min(player.speed + Constants.SHOE_STEP, player.caps.speed)
                elseif item.kind == "gremlin" then
                    player.range = player.caps.range
                elseif item.kind == "devil" then
                    player.speed = player.caps.speed
                elseif item.kind == "needle" then
                    player.inv.needle = math.min(player.inv.needle + 1, Constants.MAX_NEEDLE)
                elseif item.kind == "remote" then
                    player.inv.remote = math.min(player.inv.remote + 1, Constants.MAX_REMOTE)
                elseif item.kind == "kick" then
                    player.kick = true
                elseif Mounts.MOUNTS[item.kind] then
                    player.mount = item.kind
                end
            end
        end
    end
end

function Game:markDisconnected(id: string)
    local player = self.players[id]
    if not player then
        return
    end
    player.disconnected = true
    if player.alive then
        self:kill(player)
    end
    self:checkOver()
end

function Game:checkOver()
    if self.over then
        return
    end
    local hasRealPlayer = false
    local alive = {}
    for _, player in ipairs(self.playerOrder) do
        if not player.isBot and not player.disconnected then
            hasRealPlayer = true
        end
        if player.alive then
            table.insert(alive, player)
        end
    end
    if not hasRealPlayer then
        self.over = true
        self.winner = nil
        return
    end
    if #alive <= 1 then
        self.over = true
        self.winner = alive[1]
    end
end

function Game:tick()
    if self.over then
        self:updateLootShots()
        return
    end
    if self.warmup > 0 then
        self.warmup -= 1
        return
    end

    self.tickCount += 1
    for _, player in ipairs(self.playerOrder) do
        if player.grace > 0 then
            player.grace -= 1
        end
    end
    self:updateCrateSlides()
    self:updateBombSlides()
    self:updateBombPass()
    for _, player in ipairs(self.playerOrder) do
        if player.alive and not player.trapped and not player.disconnected then
            self:movePlayer(player)
        end
    end
    self:updateBombs()
    self:updateExplosions()
    self:applyFlameDamage()
    self:updateTraps()
    self:updateItems()
    self:updateLootShots()
    self:checkOver()

    if not self.over and self.tickCount >= Constants.ROUND_TICKS then
        self.over = true
        self.winner = nil
    end
end

-- forceGrid is for one-client syncs (late join / GetSync): always include the
-- map without consuming the pending "grid changed" flag that the regular
-- broadcast still needs to deliver.
function Game:snapshot(forceGrid: boolean?)
    local withGrid = forceGrid == true or self.gridVer ~= self._sentGridVer
    if not forceGrid then
        self._sentGridVer = self.gridVer
    end

    local players = {}
    for _, player in ipairs(self.playerOrder) do
        table.insert(players, {
            id = player.id,
            x = math.floor(player.x + 0.5),
            y = math.floor(player.y + 0.5),
            -- Sub-pixel authoritative position for client reconciliation. The
            -- integer x/y stay for the existing renderer/tests.
            fx = math.floor(player.x * 10 + 0.5) / 10,
            fy = math.floor(player.y * 10 + 0.5) / 10,
            -- Last command sequence applied by the server for this player.
            ack = player.ack or 0,
            alive = player.alive,
            trapped = player.trapped,
            mount = player.mount,
            kick = player.kick,
            speed = self:effSpeed(player),
            maxBombs = player.maxBombs,
            range = player.range,
            inv = { needle = player.inv.needle, remote = player.inv.remote },
        })
    end

    local bombs = {}
    for _, bomb in ipairs(self.bombs) do
        local pass = {}
        for id in pairs(bomb.pass) do
            table.insert(pass, id)
        end
        table.sort(pass)
        table.insert(bombs, {
            id = bomb.id,
            x = bomb.tx,
            y = bomb.ty,
            sx = math.floor(bomb.px * 10 + 0.5) / 10,
            sy = math.floor(bomb.py * 10 + 0.5) / 10,
            fuse = bomb.fuse,
            remote = bomb.remote,
            owner = bomb.ownerId,
            -- Players currently allowed to stand on this bomb. Client prediction
            -- needs the same exception; otherwise it would stop at a bomb the
            -- server lets the owner walk off.
            pass = pass,
        })
    end

    local explosions = {}
    for _, explosion in ipairs(self.explosions) do
        table.insert(explosions, {
            id = explosion.id,
            cells = explosion.cells,
            ttl = explosion.ttl,
        })
    end

    local items = {}
    for _, item in ipairs(self.items) do
        table.insert(items, { x = item.x, y = item.y, kind = item.kind })
    end

    local loot = {}
    for _, shot in ipairs(self.lootShots) do
        table.insert(loot, {
            kind = shot.kind,
            x0 = shot.x0,
            y0 = shot.y0,
            x1 = shot.x1,
            y1 = shot.y1,
            left = shot.left,
            total = shot.total,
        })
    end

    local slides = {}
    for _, slide in ipairs(self.crateSlides) do
        table.insert(slides, {
            fx = slide.fx,
            fy = slide.fy,
            tx = slide.tx,
            ty = slide.ty,
            left = slide.left,
            total = slide.total,
        })
    end

    local snapshot = {
        tick = self.tickCount,
        warmup = self.warmup,
        timeLeft = math.max(0, math.ceil((Constants.ROUND_TICKS - self.tickCount) / Constants.TICK_RATE)),
        players = players,
        bombs = bombs,
        expl = explosions,
        items = items,
        loot = loot,
        crateSlides = slides,
    }
    if withGrid then
        snapshot.grid = self:gridRows()
    end
    return snapshot
end

return Game
