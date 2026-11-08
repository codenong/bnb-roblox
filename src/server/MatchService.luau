-- src/server/MatchService.luau
-- Room manager. New players default to an independent practice room (1 human +
-- 1 bot). Versus tables are precreated/retained for the server's lifetime and
-- hold two humans with a bounded spectator audience; a player can move between
-- modes through joinPractice / joinVersus. All transport stays room-scoped in
-- Room.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local RoomName = require(Shared:WaitForChild("RoomName"))
local Shop = require(Shared:WaitForChild("Shop"))

local Room = require(script.Parent:WaitForChild("Room"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local ShopConfig = require(script.Parent:WaitForChild("ShopConfig"))

local MatchService = {}

-- A room that throws is closed and its members are moved to a fresh room, so one
-- bad room can never stop the others from stepping. To stop a deterministic bug
-- from churning rooms forever, a player is re-seated at most MAX_RECYCLES times
-- within RECYCLE_WINDOW_STEPS; after that they are left without a room (and the
-- failure is logged) until they rejoin.
local MAX_RECYCLES = 3
local RECYCLE_WINDOW_STEPS = 30 * Constants.TICK_RATE

local rooms = {}
local roomByPlayer = {}
local nextRoomId = 0
local stepCount = 0
local failures = {} -- [Player] = { count = n, firstStep = step }
local scratch = {} -- reused per step: rooms are stepped from a stable copy
local loadingPlayers = {} -- [Player] = true while their profile is still loading
local lobbyPlayers = {} -- [Player] = true after leaving a room, before choosing another
local settlementHandler = nil
local usageSettlementHandler = nil
local filterRoomNameHandler = function(text)
    return text
end
local notifyHandler = nil
local now = os.clock
local versusRoomSequence = 0
local passwordAttempts = {} -- [Player] = { count = n, windowStart = t }
local configAttempts = {} -- [Player] = { count = n, windowStart = t }

-- Seat a record and keep the reverse index in sync. A fresh practice room can
-- never reject its only human, but versus joins can lose a race with a seat
-- opening/closing, so callers must handle false.
local function attachPlayer(room, record): boolean
    roomByPlayer[record.player] = room
    if room:addMember(record) then
        lobbyPlayers[record.player] = nil
        return true
    end
    roomByPlayer[record.player] = nil
    return false
end

local function createPracticeRoom(record)
    nextRoomId += 1
    local room = Room.new({
        id = nextRoomId,
        mode = "practice",
        maxPlayers = Constants.PRACTICE_PLAYERS,
        fillBots = true,
        waitingTicks = Constants.WAITING_TICKS,
        resultsTicks = Constants.RESULTS_TICKS,
        random = Random.new(),
        onSettled = settlementHandler,
        onUsageSettled = usageSettlementHandler,
    })
    rooms[room.id] = room
    if not attachPlayer(room, record) then
        rooms[room.id] = nil
        return nil
    end
    return room
end

local function createVersusRoom()
    nextRoomId += 1
    versusRoomSequence += 1
    local room = Room.new({
        id = nextRoomId,
        mode = "versus",
        maxPlayers = Constants.VERSUS_PLAYERS,
        fillBots = false,
        maxSpectators = Constants.VERSUS_SPECTATORS,
        waitingTicks = Constants.WAITING_TICKS,
        resultsTicks = Constants.RESULTS_TICKS,
        defaultName = "房间 " .. tostring(versusRoomSequence),
        random = Random.new(),
        onSettled = settlementHandler,
        onUsageSettled = usageSettlementHandler,
    })
    rooms[room.id] = room
    return room
end

local function countVersusRooms(): number
    local count = 0
    for _, room in pairs(rooms) do
        if room.mode == "versus" then
            count += 1
        end
    end
    return count
end

-- Fixed-window, per-player abuse guard. The clock is injected so headless tests
-- can advance it without sleeping.
local function consumeAttempt(store, player, maxAttempts, windowSeconds): boolean
    local t = now()
    local entry = store[player]
    if not entry or t - entry.windowStart > windowSeconds then
        entry = { count = 0, windowStart = t }
        store[player] = entry
    end
    if entry.count >= maxAttempts then
        return false
    end
    entry.count += 1
    return true
end

-- Password failures are checked separately so a correct password does not count
-- as a failed attempt, and only failures consume the budget.
local function passwordBlocked(player): boolean
    local entry = passwordAttempts[player]
    if not entry then
        return false
    end
    if now() - entry.windowStart > Constants.PASSWORD_ATTEMPT_WINDOW_SECONDS then
        passwordAttempts[player] = nil
        return false
    end
    return entry.count >= Constants.PASSWORD_ATTEMPT_MAX
end

local function recordPasswordFailure(player)
    local t = now()
    local entry = passwordAttempts[player]
    if not entry or t - entry.windowStart > Constants.PASSWORD_ATTEMPT_WINDOW_SECONDS then
        entry = { count = 0, windowStart = t }
        passwordAttempts[player] = entry
    end
    entry.count += 1
end

local function sendNotice(record, message)
    if notifyHandler == nil or record == nil or record.player == nil then
        return
    end
    local ok, err = pcall(notifyHandler, record.player, message)
    if not ok then
        warn("[BnB] notice failed for " .. tostring(record.id) .. ": " .. tostring(err))
    end
end

-- A versus room with no seats has no host. Its audience is read-only and can no
-- longer see a match, so move each spectator to a fresh practice room and tell
-- them why. The room itself is retained as an empty waiting table.
local function evictSpectators(room)
    local spectators = room:getSpectatorRecords()
    for _, record in ipairs(spectators) do
        if roomByPlayer[record.player] == room then
            roomByPlayer[record.player] = nil
        end
        room:removeMember(record)
    end
    room:resetConfig()
    room:resetForWaiting()

    for _, record in ipairs(spectators) do
        local ok, practice = pcall(createPracticeRoom, record)
        if not ok then
            warn(string.format("[BnB] could not move spectator %s to practice: %s", record.id, tostring(practice)))
        elseif not practice then
            warn("[BnB] practice room rejected spectator " .. record.id)
        end
        sendNotice(record, "房间内已没有对战玩家，房主为空，已返回练习")
    end
end

-- Remove a record from whatever room it is in. This is synchronous: a versus
-- round can finish here, which reports the leaver through the settlement hook
-- before the player is seated somewhere else.
local function detachPlayer(player: Player, record): any
    local room = roomByPlayer[player]
    if not room then
        return nil
    end
    roomByPlayer[player] = nil
    if record then
        room:removeMember(record)
    end
    if room.mode == "versus" then
        -- A versus table is retained, but a room with no seats has no host and
        -- cannot continue. Move any remaining audience out.
        if room:getSeatCount() == 0 then
            evictSpectators(room)
        end
    elseif room:isEmpty() then
        rooms[room.id] = nil
    end
    return room
end

-- Prefer a waiting table with an open seat, then a newly created table, and only
-- then spectate an existing match. This keeps quick play out of the audience
-- when there is still room to play.
-- Quick join never enters a password room; the browser is the only place a
-- password can be supplied. Locked tables are skipped entirely, including their
-- spectator slots.
local function findAutoVersusRoom()
    local waiting = nil
    for _, room in pairs(rooms) do
        if room.mode == "versus" and room.phase == "waiting" and not room:isFull()
            and not room:hasPassword()
            and (waiting == nil or room.id < waiting.id) then
            waiting = room
        end
    end
    if waiting then
        return waiting
    end

    if countVersusRooms() < Constants.VERSUS_TABLES then
        return createVersusRoom()
    end

    local spectator = nil
    for _, room in pairs(rooms) do
        if room.mode == "versus" and not room:hasPassword() and room:canAddMember() then
            if spectator == nil
                or room:getSpectatorCount() < spectator:getSpectatorCount()
                or (room:getSpectatorCount() == spectator:getSpectatorCount() and room.id < spectator.id) then
                spectator = room
            end
        end
    end
    return spectator
end

function MatchService.init(opts)
    opts = opts or {}
    rooms = {}
    roomByPlayer = {}
    nextRoomId = 0
    versusRoomSequence = 0
    stepCount = 0
    failures = {}
    loadingPlayers = {}
    lobbyPlayers = {}
    passwordAttempts = {}
    configAttempts = {}
    table.clear(scratch)
    settlementHandler = opts.onSettled
    usageSettlementHandler = opts.onUsageSettled
    filterRoomNameHandler = if type(opts.filterRoomName) == "function"
        then opts.filterRoomName
        else function(text)
            return text
        end
    notifyHandler = if type(opts.notify) == "function" then opts.notify else nil
    now = if type(opts.now) == "function" then opts.now else os.clock

    -- Production runs with four persistent tables. Tests that assert exact lazy
    -- creation counts can explicitly opt out.
    if opts.precreateVersus ~= false then
        for _ = 1, Constants.VERSUS_TABLES do
            createVersusRoom()
        end
    end
end

-- Main marks a player as loading from PlayerAdded until the profile load ends
-- (loaded, failed or cancelled). While marked, GetSync answers { phase = "loading" }
-- so the client can show a loading screen instead of an empty one.
function MatchService.setLoading(player: Player, loading: boolean)
    loadingPlayers[player] = if loading then true else nil
end

local function detachRoom(room)
    rooms[room.id] = nil
    for _, record in ipairs(room.members) do
        if roomByPlayer[record.player] == room then
            roomByPlayer[record.player] = nil
        end
    end
end

-- Counts a failure for this player; false once they have exceeded the budget.
local function mayReseat(player: Player): boolean
    local entry = failures[player]
    if not entry or stepCount - entry.firstStep > RECYCLE_WINDOW_STEPS then
        entry = { count = 0, firstStep = stepCount }
        failures[player] = entry
    end
    entry.count += 1
    return entry.count <= MAX_RECYCLES
end

local function recycleRoom(room, err)
    warn(string.format(
        "[BnB] room %d (%s, phase=%s) failed and was recycled: %s",
        room.id,
        tostring(room.mode),
        tostring(room.phase),
        tostring(err)
    ))

    local members = table.clone(room.members)
    if room.mode == "versus" then
        -- Persistent tables keep their registry slot. A broken round is reset in
        -- place; the table stays browsable and reusable.
        for _, record in ipairs(members) do
            if roomByPlayer[record.player] == room then
                roomByPlayer[record.player] = nil
            end
        end
        local ok, resetErr = pcall(room.resetEmpty, room)
        if not ok then
            warn(string.format("[BnB] could not reset versus room %d: %s", room.id, tostring(resetErr)))
            rooms[room.id] = nil
        end
    else
        detachRoom(room)
    end

    for _, record in ipairs(members) do
        if mayReseat(record.player) then
            local ok, replacement = pcall(createPracticeRoom, record)
            if not ok then
                warn(string.format("[BnB] could not create a replacement room for %s: %s", record.id, tostring(replacement)))
            elseif not replacement then
                warn(string.format("[BnB] replacement room rejected %s", record.id))
            end
        else
            warn(string.format("[BnB] %s kept failing rooms; not reassigning until they rejoin", record.id))
        end
    end
end

function MatchService.step()
    stepCount += 1

    -- Rooms are created and removed while recycling, so never iterate `rooms`
    -- directly. Stepping in id order also keeps behaviour deterministic.
    table.clear(scratch)
    for _, room in pairs(rooms) do
        table.insert(scratch, room)
    end
    table.sort(scratch, function(a, b)
        return a.id < b.id
    end)

    for _, room in ipairs(scratch) do
        if rooms[room.id] == room then
            if room:isEmpty() then
                if room.mode == "practice" then
                    rooms[room.id] = nil
                elseif room.phase ~= "waiting"
                    or room.hostId ~= nil
                    or room:hasPassword()
                    or room.name ~= room.defaultName then
                    -- Empty versus tables are retained, but must not keep an old
                    -- round, host or password. This is a safety net for paths that
                    -- drop the last member without going through detachPlayer.
                    room:resetConfig()
                    room:resetForWaiting()
                end
            else
                local ok, err = pcall(room.step, room)
                if not ok then
                    recycleRoom(room, err)
                end
            end
        end
    end
end

function MatchService.onPlayerAdded(player: Player)
    loadingPlayers[player] = nil
    lobbyPlayers[player] = nil
    local record = PlayerService.get(player)
    if not record or roomByPlayer[player] then
        return
    end
    createPracticeRoom(record)
end

function MatchService.onPlayerRemoving(player: Player, record)
    failures[player] = nil
    loadingPlayers[player] = nil
    lobbyPlayers[player] = nil
    passwordAttempts[player] = nil
    configAttempts[player] = nil
    detachPlayer(player, record)
end

function MatchService.getRoomFor(player: Player)
    return roomByPlayer[player]
end

-- Move a player to a private practice room. Joining practice while already in
-- one is a no-op. Leaving a live versus round here is a forfeit, exactly like
-- any other seat exit.
function MatchService.joinPractice(player: Player): (boolean, string?, number?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded", nil
    end

    local current = roomByPlayer[player]
    if current and current.mode == "practice" then
        return true, nil, current.id
    end

    detachPlayer(player, record)
    local room = createPracticeRoom(record)
    if not room then
        return false, "join_failed", nil
    end
    return true, nil, room.id
end

-- Join a specific versus table, or pick one automatically when tableId is nil.
-- A specific table is validated and password-checked before the player leaves
-- their current room, so a failed switch never strands them. Quick join while
-- already seated at a versus table keeps that table instead of hopping around.
function MatchService.joinVersus(player: Player, tableId: number?, password: any): (boolean, string?, number?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded", nil
    end
    if tableId ~= nil and (type(tableId) ~= "number" or tableId % 1 ~= 0) then
        return false, "invalid_table", nil
    end

    local current = roomByPlayer[player]
    if current and current.mode == "versus" and (tableId == nil or tableId == current.id) then
        return true, nil, current.id
    end

    local target = nil
    if tableId == nil then
        target = findAutoVersusRoom()
        if not target then
            return false, "no_tables", nil
        end
    else
        target = rooms[tableId]
        if not target or target.mode ~= "versus" then
            return false, "no_table", nil
        end
    end

    if target ~= current and not target:canAddMember() then
        return false, "table_full", nil
    end

    if target:hasPassword() then
        if passwordBlocked(player) then
            return false, "too_many_attempts", nil
        end
        if type(password) ~= "string" then
            recordPasswordFailure(player)
            return false, "password_required", nil
        end
        if not target:checkPassword(password) then
            recordPasswordFailure(player)
            return false, "wrong_password", nil
        end
        passwordAttempts[player] = nil
    end

    if current then
        detachPlayer(player, record)
    end

    if not attachPlayer(target, record) then
        -- The old room is gone at this point; give the player a safe fallback
        -- rather than leaving them with no state to sync.
        createPracticeRoom(record)
        return false, "join_failed", nil
    end
    return true, nil, target.id
end

-- Remote-facing entry point. Accepts "practice", "versus", a table id, or a
-- { mode = "practice" | "versus", tableId = n?, password = s? } request.
function MatchService.join(player: Player, target: any): (boolean, string?, number?)
    if target == nil or target == "practice" then
        return MatchService.joinPractice(player)
    end
    if target == "versus" then
        return MatchService.joinVersus(player, nil)
    end
    if type(target) == "number" then
        return MatchService.joinVersus(player, target)
    end
    if type(target) == "table" then
        if target.mode == "practice" then
            return MatchService.joinPractice(player)
        elseif target.mode == "versus" then
            return MatchService.joinVersus(player, target.tableId, target.password)
        end
    end
    return false, "invalid_target", nil
end

local function isValidPassword(password: string): boolean
    local length = #password
    return length >= Constants.ROOM_PASSWORD_MIN_DIGITS
        and length <= Constants.ROOM_PASSWORD_MAX_DIGITS
        and password:match("^%d+$") ~= nil
end

-- Host-only room configuration. The request is validated and rate-limited here;
-- Room only applies the result. Text filtering can yield, so membership, host
-- identity and phase are rechecked before anything is written.
function MatchService.setRoomConfig(player: Player, request): (boolean, string?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded"
    end
    local room = roomByPlayer[player]
    if not room then
        return false, "not_in_room"
    end
    if room.mode ~= "versus" then
        return false, "not_versus"
    end
    if room:getHostId() ~= record.id then
        return false, "not_host"
    end
    if room.phase ~= "waiting" then
        return false, "not_waiting"
    end

    if type(request) ~= "table" then
        return false, "invalid_request"
    end
    local rawName = request.name
    local rawPassword = request.password
    if rawName == nil and rawPassword == nil then
        return false, "invalid_request"
    end
    if rawName ~= nil and type(rawName) ~= "string" then
        return false, "invalid_request"
    end
    if rawPassword ~= nil and type(rawPassword) ~= "string" then
        return false, "invalid_request"
    end

    if not consumeAttempt(
        configAttempts,
        player,
        Constants.ROOM_CONFIG_ATTEMPT_MAX,
        Constants.ROOM_CONFIG_WINDOW_SECONDS
    ) then
        return false, "config_rate_limited"
    end

    local passwordUpdate = nil
    if rawPassword ~= nil then
        if rawPassword ~= "" and not isValidPassword(rawPassword) then
            return false, "invalid_password"
        end
        passwordUpdate = rawPassword
    end

    local nameUpdate = nil
    if rawName ~= nil then
        local normalized, nameError = RoomName.normalize(rawName)
        if not normalized then
            return false, nameError or "invalid_name"
        end
        local ok, filtered = pcall(filterRoomNameHandler, normalized, player.UserId)
        if not ok or type(filtered) ~= "string" then
            return false, "filter_failed"
        end
        local validated, filterError = RoomName.validateFiltered(filtered)
        if not validated then
            return false, filterError or "filter_failed"
        end
        nameUpdate = validated
    end

    -- TextService can take a frame; the host may have left, the host may have
    -- changed, or the countdown may have started while the filter was running.
    if rooms[room.id] ~= room or roomByPlayer[player] ~= room then
        return false, "not_in_room"
    end
    if room:getHostId() ~= record.id then
        return false, "not_host"
    end
    if room.phase ~= "waiting" then
        return false, "not_waiting"
    end

    local ok, reason = room:setConfig(record.id, nameUpdate, passwordUpdate)
    if not ok then
        return false, reason
    end
    return true, nil
end

-- Public table browser data. Returned tables are copies; the client can never
-- mutate a live room through this payload, and the password itself never leaves
-- the server.
function MatchService.getTables()
    local list = {}
    for _, room in pairs(rooms) do
        if room.mode == "versus" then
            local waitingReady = room.phase == "waiting" and room:isCountdownReady()
            table.insert(list, {
                id = room.id,
                mode = room.mode,
                phase = room.phase,
                name = room:getRoomName(),
                hostId = room:getHostId(),
                hostName = room:getHostName(),
                hasPassword = room:hasPassword(),
                seats = room:getSeatSummary(),
                seatCount = room:getSeatCount(),
                maxPlayers = room.maxPlayers,
                spectatorCount = room:getSpectatorCount(),
                maxSpectators = room.maxSpectators,
                waitingForPlayers = room.phase == "waiting" and not room:isCountdownReady(),
                endsIn = if room.phase == "waiting" and waitingReady
                    then room:getWaitingSeconds()
                    elseif room.phase == "ended" then room:getResultsSeconds()
                    else 0,
                joinable = room:canAddMember(),
            })
        end
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

function MatchService.getRoomCount(): number
    local count = 0
    for _ in pairs(rooms) do
        count += 1
    end
    return count
end

---------------------------------------------------------------- 商店与道具

local function shopItem(profile, itemId: string, mode: any)
    local info = Shop.ITEMS[itemId]
    local free, purchased = Shop.stock(profile, itemId)
    local carry = Shop.effectiveCarry(profile, mode)
    local product = ShopConfig.getProduct(itemId)
    return {
        id = itemId,
        name = info.name,
        short = info.short,
        description = info.description,
        cap = info.cap,
        free = free,
        purchased = purchased,
        stock = free + purchased,
        carry = carry[itemId],
        purchasable = product ~= nil,
        productId = if product then product.productId else nil,
        amount = if product then product.amount else nil,
    }
end

-- Snapshot used by the shop panel and the lobby's "我的道具" summary. Prices
-- stay in the Roblox purchase prompt; this only exposes ids, stock and the
-- automatic carry for the current context.
function MatchService.getShop(player: Player)
    local record = PlayerService.get(player)
    if not record or type(record.profile) ~= "table" then
        return { ok = false, reason = "not_loaded" }
    end

    local room = roomByPlayer[player]
    local phase = if room then room.phase else nil
    local mode = if room then room.mode else nil

    local items = {}
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        table.insert(items, shopItem(record.profile, itemId, mode))
    end

    return {
        ok = true,
        items = items,
        phase = phase,
        mode = mode,
        practice = mode == "practice",
    }
end

-- Re-read stock after a purchase and refresh the waiting roster's carry lines.
-- Returns the fresh snapshot for the ShopUpdate event.
function MatchService.refreshShop(player: Player)
    local room = roomByPlayer[player]
    if room and room.phase == "waiting" then
        room:refreshInventory()
    end
    return MatchService.getShop(player)
end

-- BindToClose path: charge every live round exactly once before profiles are
-- released. No stats are touched here.
function MatchService.settleActiveUsage(reason: string?): number
    local count = 0
    for _, room in pairs(rooms) do
        if room.phase == "playing" then
            local ok, settled = pcall(room.settleActiveUsage, room, reason or "shutdown")
            if ok then
                count += settled
            else
                warn(string.format(
                    "[BnB] room %d item settlement during shutdown failed: %s",
                    room.id,
                    tostring(settled)
                ))
            end
        end
    end
    return count
end

function MatchService.setInput(player: Player, dirs)
    local room = roomByPlayer[player]
    if not room then
        return
    end
    room:setInput(PlayerService.get(player), dirs)
end

function MatchService.action(player: Player, action: string)
    local room = roomByPlayer[player]
    if not room then
        return
    end
    room:action(PlayerService.get(player), action)
end

function MatchService.selectChar(player: Player, charId: string): boolean
    local room = roomByPlayer[player]
    if not room then
        return false
    end
    return room:selectChar(PlayerService.get(player), charId)
end

function MatchService.selectColor(player: Player, colorKey: string): boolean
    local room = roomByPlayer[player]
    if not room then
        return false
    end
    return room:selectColor(PlayerService.get(player), colorKey)
end

-- "换桌" means leaving the current room. The old room settles/cancels exactly as
-- any other leave (a live versus round is a forfeit), and the player stays in the
-- table browser without a room until choosing practice or another table.
function MatchService.leaveTable(player: Player): (boolean, string?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded"
    end
    detachPlayer(player, record)
    lobbyPlayers[player] = true
    return true
end

function MatchService.getSync(player: Player)
    local room = roomByPlayer[player]
    if not room then
        -- A player browsing after "换桌" has deliberately left; do not recreate a
        -- practice room behind the browser. Choosing a mode clears this flag.
        if lobbyPlayers[player] then
            return nil
        end
        -- The client can invoke GetSync in the same join frame as PlayerAdded;
        -- create the practice room lazily instead of leaving it unsynced.
        local record = PlayerService.get(player)
        if record then
            room = createPracticeRoom(record)
        end
    end
    if not room then
        if loadingPlayers[player] then
            return { phase = "loading" }
        end
        return nil
    end
    return room:getSync(PlayerService.get(player))
end

return table.freeze(MatchService)
