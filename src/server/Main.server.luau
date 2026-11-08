-- src/server/Main.server.luau
-- Server entry point: remotes, player lifecycle and the fixed-step match loop.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

-- The game is rendered entirely in a ScreenGui; never spawn a Roblox character.
Players.CharacterAutoLoads = false

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local ProfileSchema = require(Shared:WaitForChild("ProfileSchema"))
local Shop = require(Shared:WaitForChild("Shop"))

Net.init()

local MatchService = require(script.Parent:WaitForChild("MatchService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local ProfileService = require(script.Parent:WaitForChild("ProfileService"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))
local VersusStats = require(script.Parent:WaitForChild("VersusStats"))

---------------------------------------------------------------- 数据层

local LOAD_FAILED_MESSAGE = "数据加载失败，请稍后再试（Studio 需开启 API 访问）。"
local DUPLICATE_LOAD_RETRIES = 20
local DUPLICATE_LOAD_RETRY_SECONDS = 0.5

local function getProfileDataStore()
    local ok, store = pcall(function()
        return DataStoreService:GetDataStore("BnB_Profiles_v1")
    end)
    if not ok then
        warn("[BnB] DataStore unavailable: " .. tostring(store))
        return nil
    end
    return store
end

local function makeSessionId(): string
    local ok, guid = pcall(function()
        return HttpService:GenerateGUID(false)
    end)
    local suffix = if ok then tostring(guid) else tostring(os.clock())
    return tostring(game.JobId) .. ":" .. suffix
end

local departed = {}
local loading = {}

local profileStore = ProfileStore.new({
    dataStore = getProfileDataStore(),
    schema = ProfileSchema,
    sessionId = makeSessionId(),
    now = os.time,
    sleep = task.wait,
    logger = warn,
})

local profiles = ProfileService.new({
    store = profileStore,
    isActive = function(player)
        return not departed[player] and player.Parent ~= nil
    end,
    spawn = task.spawn,
    sleep = task.wait,
    warn = warn,
    autoSaveSeconds = 30,
    onLockLost = function(player, reason)
        if departed[player] or player.Parent == nil then
            warn(string.format("[BnB] profile lock lost after leaving for %s: %s", tostring(player.UserId), tostring(reason)))
            return
        end
        warn(string.format("[BnB] profile lock lost for %s: %s", tostring(player.UserId), tostring(reason)))
        pcall(function()
            player:Kick("数据会话已失效，请重新加入。")
        end)
    end,
})

-- Stats are applied before the commit so the profile worker persists them. The
-- participant list (not the current roster) includes someone who left mid-round,
-- which is exactly who needs the loss written.
local function onSettled(members, result, context)
    if context then
        VersusStats.apply(context, result)
        profiles:commitMany(context.participants or members)
    else
        profiles:commitMany(members)
    end
end

-- Item settlement is deliberately separate from stats settlement: BindToClose
-- charges used items but must not record a versus result for an unfinished
-- round. Practice never carries stock, so its carried snapshot is all zeros and
-- settlement has nothing to charge.
local function onUsageSettled(record, used, carried, context)
    if not record or type(record.profile) ~= "table" then
        return
    end
    local mode = if context then context.mode else nil
    if mode == "practice" then
        return
    end

    local spent = Shop.settleUsage(record.profile, carried, used)
    local changed = false
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        local bucket = spent[itemId]
        if bucket and (bucket.free > 0 or bucket.purchased > 0) then
            changed = true
            break
        end
    end
    if changed then
        profiles:commitMany({ record })
    end
end

-- Room names are user text shown to every player browsing the table list, so they
-- must go through Roblox filtering before they are stored. Filtering can yield;
-- MatchService rechecks host/phase after this returns.
local function filterRoomName(text: string, userId: number): string?
    local ok, result = pcall(function()
        return TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
    end)
    if not ok or not result then
        return nil
    end
    local okFiltered, filtered = pcall(function()
        return result:GetNonChatStringForBroadcastAsync()
    end)
    if not okFiltered or type(filtered) ~= "string" or filtered == "" then
        return nil
    end
    return filtered
end

local function notify(player: Player, message: string)
    Net.send(player, "Notice", { message = message })
end

MatchService.init({
    onSettled = onSettled,
    onUsageSettled = onUsageSettled,
    filterRoomName = filterRoomName,
    notify = notify,
})

local shopService = ShopService.new({
    profiles = profiles,
    store = profileStore,
    flushSeconds = 10,
    logger = warn,
    onGranted = function(player)
        if player and player.Parent == nil then
            return
        end
        local snapshot = MatchService.refreshShop(player)
        if snapshot.ok then
            Net.send(player, "ShopUpdate", snapshot)
        end
    end,
})

game:BindToClose(function()
    -- Charge live rounds before ProfileService closes/releases every profile.
    MatchService.settleActiveUsage("shutdown")
    profiles:shutdown()
end)

---------------------------------------------------------------- 网络事件

Net.get("Input").OnServerEvent:Connect(function(player, dirs)
    MatchService.setInput(player, dirs)
end)

Net.get("Action").OnServerEvent:Connect(function(player, action)
    if type(action) == "string" then
        MatchService.action(player, action)
    end
end)

Net.get("SelectChar").OnServerEvent:Connect(function(player, charId)
    MatchService.selectChar(player, charId)
end)

Net.get("SelectColor").OnServerEvent:Connect(function(player, colorKey)
    if type(colorKey) == "string" then
        MatchService.selectColor(player, colorKey)
    end
end)

-- "换桌" is a real seat exit, decided by the server. The old room cancels its
-- countdown/settles as usual; the player remains roomless until choosing a mode.
Net.get("LeaveTable").OnServerInvoke = function(player)
    local ok, reason = MatchService.leaveTable(player)
    return { ok = ok == true, reason = reason }
end

Net.get("GetSync").OnServerInvoke = function(player)
    return MatchService.getSync(player)
end

Net.get("GetTables").OnServerInvoke = function(_player)
    return MatchService.getTables()
end

Net.get("JoinTable").OnServerInvoke = function(player, target)
    local ok, reason, roomId = MatchService.join(player, target)
    return { ok = ok == true, reason = reason, roomId = roomId }
end

Net.get("SetRoomConfig").OnServerInvoke = function(player, request)
    local ok, reason = MatchService.setRoomConfig(player, request)
    return { ok = ok == true, reason = reason }
end

Net.get("GetShop").OnServerInvoke = function(player)
    local ok, snapshot = pcall(MatchService.getShop, player)
    if not ok then
        warn("[BnB] GetShop failed for " .. tostring(player.UserId) .. ": " .. tostring(snapshot))
        return { ok = false, reason = "server_error" }
    end
    return snapshot
end

-- Roblox gives ProcessReceipt time to yield (profile flush/direct DataStore save).
-- NotProcessedYet means "call me again"; a retry sees the stored PurchaseId and
-- cannot double-grant.
MarketplaceService.ProcessReceipt = function(receiptInfo)
    local player = nil
    if type(receiptInfo) == "table" and type(receiptInfo.PlayerId) == "number" then
        player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if player == nil then
            -- The player may have disconnected after buying. A lightweight
            -- identity is enough for the direct load/release path; there is no
            -- live UI or room to refresh.
            player = { UserId = receiptInfo.PlayerId, Parent = nil }
        end
    end
    if player == nil then
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local ok, granted, reason = pcall(shopService.processReceipt, shopService, player, receiptInfo)
    if not ok then
        warn("[BnB] ProcessReceipt crashed: " .. tostring(granted))
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end
    if not granted then
        warn(string.format(
            "[BnB] receipt %s deferred: %s",
            tostring(receiptInfo and receiptInfo.PurchaseId),
            tostring(reason)
        ))
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end
    return Enum.ProductPurchaseDecision.PurchaseGranted
end

---------------------------------------------------------------- 玩家进出

local function loadFailureMessage(reason: string?): string
    if reason == "locked" then
        return "该账号已在其他服务器登录，请稍后再试。"
    elseif reason == "duplicate" then
        return "账号数据正在同步，请稍后重新加入。"
    elseif reason == "newer_version" then
        return "存档版本过新，请更新游戏后再试。"
    elseif reason == "corrupt" then
        return "存档损坏，请联系管理员。"
    end
    return LOAD_FAILED_MESSAGE
end

local function kickIfOnline(player: Player, message: string)
    if player.Parent == nil then
        return
    end
    pcall(function()
        player:Kick(message)
    end)
end

local function onPlayerAdded(player: Player)
    if PlayerService.get(player) or loading[player] then
        return
    end

    departed[player] = nil
    player.CharacterAdded:Connect(function(character)
        PlayerService.destroyCharacter(character)
    end)
    if player.Character then
        PlayerService.destroyCharacter(player.Character)
    end

    loading[player] = true
    -- Until the profile is loaded the client has no room to sync with; tell it so
    -- it can show a loading screen (GetSync answers { phase = "loading" }).
    MatchService.setLoading(player, true)
    -- return
    task.spawn(function()
        local ok, profile, reason = pcall(function()
            return profiles:load(player, {
                duplicateRetries = DUPLICATE_LOAD_RETRIES,
                duplicateRetrySeconds = DUPLICATE_LOAD_RETRY_SECONDS,
            })
        end)
        loading[player] = nil
        MatchService.setLoading(player, false)

        if not ok then
            warn("[BnB] profile load crashed for " .. tostring(player.UserId) .. ": " .. tostring(profile))
            kickIfOnline(player, LOAD_FAILED_MESSAGE)
            return
        end

        if not profile then
            if reason == "cancelled" or reason == "inactive" or reason == "shutdown" then
                return
            end
            if reason == "duplicate" then
                warn("[BnB] profile still busy after the rejoin wait for " .. tostring(player.UserId))
            end
            kickIfOnline(player, loadFailureMessage(reason))
            return
        end

        -- The player can leave while the profile is loading. The profile
        -- service detected most of these cases already; this closes the last
        -- race between its return and seating.
        if departed[player] or player.Parent == nil then
            profiles:release(player)
            return
        end

        PlayerService.add(player, profile)
        MatchService.onPlayerAdded(player)
    end)
end

local function onPlayerRemoving(player: Player)
    departed[player] = true
    loading[player] = nil
    MatchService.setLoading(player, false)

    local record = PlayerService.remove(player)
    if record then
        MatchService.onPlayerRemoving(player, record)
    end
    profiles:release(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
    onPlayerAdded(player)
end

---------------------------------------------------------------- 主循环

local accumulator = 0

RunService.Heartbeat:Connect(function(dt)
    profiles:step(dt)
    accumulator += math.min(dt, 0.25)

    local steps = 0
    while accumulator >= Constants.DT and steps < 4 do
        MatchService.step()
        accumulator -= Constants.DT
        steps += 1
    end

    -- Do not spiral after a long frame; drop the excess backlog.
    if steps == 4 then
        accumulator = math.min(accumulator, Constants.DT)
    end
end)
