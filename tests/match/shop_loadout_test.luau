-- Shop snapshot and loadout editing through the room manager: entry caps,
-- replacement semantics, lock windows and the shutdown settlement path.
-- Loaded by tests/run.sh from tests/build/match.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")
local ProfileSchema = require("./ProfileSchema")
local Shop = require("./Shop")

local nextUserId = 22000
local usageEvents = {}
local loadoutCommits = {}

local function newProfile(stock, loadout)
    local profile = ProfileSchema.normalize(ProfileSchema.newProfile())
    for itemId, buckets in pairs(stock or {}) do
        profile.inventory[itemId].free = buckets.free or 0
        profile.inventory[itemId].purchased = buckets.purchased or 0
    end
    for itemId, value in pairs(loadout or {}) do
        profile.loadout[itemId] = value
    end
    return profile
end

local function newPlayer(name, profile)
    nextUserId += 1
    local player = { UserId = nextUserId, DisplayName = name }
    local record = PlayerService.add(player, profile)
    return player, record
end

local function seatPlayer(name, profile)
    local player, record = newPlayer(name, profile)
    MatchService.onPlayerAdded(player)
    return player, record
end

local function itemById(snapshot, itemId)
    for _, item in ipairs(snapshot.items or {}) do
        if item.id == itemId then
            return item
        end
    end
    return nil
end

local function findEntry(roster, id)
    for _, entry in ipairs(roster or {}) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

local function advance(ticks)
    for _ = 1, ticks do
        MatchService.step()
    end
end

MatchService.init({
    precreateVersus = false,
    onUsageSettled = function(record, used, carried, context)
        table.insert(usageEvents, {
            record = record,
            used = used,
            carried = carried,
            context = context,
        })
        Shop.settleUsage(record.profile, carried, used)
    end,
    onLoadoutChanged = function(record)
        table.insert(loadoutCommits, record.id)
    end,
})

---------------------------------------------------------------- 未加载 / 无房间

local unloaded = { UserId = nextUserId + 1, DisplayName = "Unloaded" }
local snapshot = MatchService.getShop(unloaded)
check("an unseated unknown player has no shop", snapshot.ok == false and snapshot.reason == "not_loaded",
    snapshot.reason)
local loadoutResult = MatchService.setLoadout(unloaded, { loadout = { needle = 1 } })
check("an unseated unknown player cannot set a loadout",
    loadoutResult.ok == false and loadoutResult.reason == "not_loaded", loadoutResult.reason)

local noProfilePlayer, noProfileRecord = newPlayer("NoProfile", nil)
check("a record without a profile has no shop",
    MatchService.getShop(noProfilePlayer).reason == "not_loaded")
noProfileRecord.profile = newProfile()
snapshot = MatchService.getShop(noProfilePlayer)
check("a profile added later unlocks the shop", snapshot.ok == true, snapshot.reason)

local soloProfile = newProfile({
    needle = { free = 5, purchased = 2 },
    remote = { purchased = 1 },
}, { needle = 2, remote = 1 })
local soloPlayer = newPlayer("Solo", soloProfile)
snapshot = MatchService.getShop(soloPlayer)
check("a roomless player can open the shop", snapshot.ok == true, snapshot.reason)
check("a roomless shop is editable", snapshot.locked == false)
check("a roomless shop has no mode", snapshot.phase == nil and snapshot.mode == nil)
check("the practice switch is reported", snapshot.consumeInPractice == false)
check("a roomless shop is not practice-free", snapshot.practiceFree == false)
check("the shop lists items in catalog order",
    #snapshot.items == 3
        and snapshot.items[1].id == "needle"
        and snapshot.items[2].id == "remote"
        and snapshot.items[3].id == "kick")
local needle = itemById(snapshot, "needle")
check("stock counts both buckets", needle.stock == 7, needle.stock)
check("carry respects stock", needle.carry == 2, needle.carry)
check("carry respects the entry cap", itemById(snapshot, "remote").cap == 1)
check("disabled products are not purchasable",
    needle.purchasable == false and needle.productId == nil)
check("an unowned item has no carry", itemById(snapshot, "kick").carry == 0)

---------------------------------------------------------------- 装备编辑：整数校验、上限、整表替换

local function setLoadout(player, loadout)
    return MatchService.setLoadout(player, { loadout = loadout })
end

local result = MatchService.setLoadout(soloPlayer, nil)
check("a nil request is rejected", result.ok == false and result.reason == "invalid_request", result.reason)
result = MatchService.setLoadout(soloPlayer, {})
check("a request without a loadout table is rejected",
    result.ok == false and result.reason == "invalid_request", result.reason)
result = setLoadout(soloPlayer, { needle = -1 })
check("a negative value is rejected", result.reason == "invalid_request", result.reason)
result = setLoadout(soloPlayer, { needle = 1.5 })
check("a fractional value is rejected", result.reason == "invalid_request", result.reason)
result = setLoadout(soloPlayer, { needle = 0 / 0 })
check("a NaN value is rejected", result.reason == "invalid_request", result.reason)
result = setLoadout(soloPlayer, { remote = math.huge })
check("an infinite value is rejected", result.reason == "invalid_request", result.reason)
result = setLoadout(soloPlayer, { kick = "1" })
check("a string value is rejected", result.reason == "invalid_request", result.reason)
check("a rejected edit leaves the stored intent alone",
    soloProfile.loadout.needle == 2 and soloProfile.loadout.remote == 1)
check("a rejected edit does not commit", #loadoutCommits == 0, #loadoutCommits)

soloProfile.loadout.extra = "kept"
result = setLoadout(soloPlayer, { needle = 9, remote = 3, kick = 1 })
check("an over-cap edit succeeds", result.ok == true, result.reason)
check("needle is clamped to 2", soloProfile.loadout.needle == 2, soloProfile.loadout.needle)
check("remote is clamped to 1", soloProfile.loadout.remote == 1, soloProfile.loadout.remote)
check("kick is clamped to 1", soloProfile.loadout.kick == 1, soloProfile.loadout.kick)
check("unknown loadout fields survive an edit", soloProfile.loadout.extra == "kept",
    soloProfile.loadout.extra)
check("an accepted edit commits once", #loadoutCommits == 1, #loadoutCommits)
check("the edit returns a fresh snapshot",
    result.shop.ok == true and itemById(result.shop, "needle").loadout == 2)

result = setLoadout(soloPlayer, { needle = 1 })
check("an omitted item resets to zero", soloProfile.loadout.remote == 0
    and soloProfile.loadout.kick == 0, soloProfile.loadout.remote .. "/" .. tostring(soloProfile.loadout.kick))
check("an included item is kept", soloProfile.loadout.needle == 1)
check("the cap is not a stock check: intent can exceed owned stock",
    (function()
        local empty = newProfile()
        empty.loadout.needle = 2
        local player = newPlayer("Empty", empty)
        local ok = setLoadout(player, { needle = 2 })
        return ok.ok == true and empty.loadout.needle == 2
    end)())

---------------------------------------------------------------- 等待房间：名册刷新、锁定窗口、对局开始

local seatedProfile = newProfile({
    needle = { purchased = 1 },
    remote = { purchased = 1 },
}, { needle = 1, remote = 1 })
local seated, record = seatPlayer("Seated", seatedProfile)
local room = MatchService.getRoomFor(seated)
check("the player is seated in a practice room", room ~= nil and room.mode == "practice")

local rosterEntry = findEntry(MatchService.getSync(seated).roster, record.id)
check("the waiting roster shows the effective carry",
    rosterEntry.items.needle == 1 and rosterEntry.items.remote == 1)

result = setLoadout(seated, { needle = 2, kick = 1 })
check("a waiting player can edit the loadout", result.ok == true, result.reason)
rosterEntry = findEntry(MatchService.getSync(seated).roster, record.id)
check("the waiting roster follows the edit",
    rosterEntry.items.needle == 1 and rosterEntry.items.kick == 0,
    tostring(rosterEntry.items.needle) .. "/" .. tostring(rosterEntry.items.kick))

-- Buying more while waiting refreshes the snapshot and the roster line.
seatedProfile.inventory.needle.purchased = 3
snapshot = MatchService.refreshShop(seated)
check("refreshShop sees the new stock", itemById(snapshot, "needle").stock == 3,
    itemById(snapshot, "needle").stock)
rosterEntry = findEntry(MatchService.getSync(seated).roster, record.id)
check("refreshShop also updates the waiting roster", rosterEntry.items.needle == 2,
    rosterEntry.items.needle)

advance(Constants.WAITING_TICKS - Constants.CHAR_LOCK_TICKS - 1)
snapshot = MatchService.getShop(seated)
check("the shop is open just before the lock window", snapshot.locked == false)
result = setLoadout(seated, { needle = 1, remote = 1 })
check("an edit is accepted just before the lock window", result.ok == true, result.reason)

advance(1)
snapshot = MatchService.getShop(seated)
check("the shop locks for the final countdown", snapshot.locked == true)
local lockedBefore = seatedProfile.loadout.needle
result = setLoadout(seated, { needle = 2 })
check("an edit is rejected inside the lock window",
    result.ok == false and result.reason == "locked", result.reason)
check("a rejected locked edit keeps the intent", seatedProfile.loadout.needle == lockedBefore)

advance(Constants.CHAR_LOCK_TICKS)
check("the round has started", room.phase == "playing", room.phase)
snapshot = MatchService.getShop(seated)
check("the shop stays locked during play", snapshot.locked == true)
result = setLoadout(seated, { needle = 2 })
check("an edit is rejected during play",
    result.ok == false and result.reason == "not_waiting", result.reason)

---------------------------------------------------------------- shutdown settlement

local game = room.game
local inGame = game.players[record.id]
inGame.used.needle = 1
inGame.used.remote = 1
inGame.used.kick = 0
local settled = MatchService.settleActiveUsage("shutdown")
check("shutdown settles the live round once", settled == 1, settled)
check("shutdown reports the usage", #usageEvents == 1, #usageEvents)
check("shutdown names itself as the reason", usageEvents[1].context.reason == "shutdown",
    usageEvents[1].context.reason)
check("shutdown uses the round-start carry", usageEvents[1].carried.needle == 1,
    usageEvents[1].carried.needle)
check("shutdown deducted the purchased needle", seatedProfile.inventory.needle.purchased == 2,
    seatedProfile.inventory.needle.purchased)
check("shutdown deducted the purchased remote", seatedProfile.inventory.remote.purchased == 0,
    seatedProfile.inventory.remote.purchased)
check("shutdown does not charge an unused kick", seatedProfile.inventory.kick.purchased == 0)
check("a second shutdown settlement is a no-op", MatchService.settleActiveUsage("shutdown") == 0)
check("a second shutdown does not charge again", seatedProfile.inventory.needle.purchased == 2)

TestLib.finish()
