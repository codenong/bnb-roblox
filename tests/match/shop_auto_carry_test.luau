-- Shop snapshots and automatic inventory through the room manager: versus
-- carries min(stock, cap), practice carries zero, there is no loadout editor,
-- and shutdown still settles a live versus round.
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

local function newProfile(stock)
    local profile = ProfileSchema.normalize(ProfileSchema.newProfile())
    for itemId, buckets in pairs(stock or {}) do
        profile.inventory[itemId].free = buckets.free or 0
        profile.inventory[itemId].purchased = buckets.purchased or 0
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

local function findUsage(recordId)
    for _, event in ipairs(usageEvents) do
        if event.record.id == recordId then
            return event
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
        if context.mode ~= "practice" then
            Shop.settleUsage(record.profile, carried, used)
        end
    end,
})

---------------------------------------------------------------- 未加载 / 无房间

local unloaded = { UserId = nextUserId + 1, DisplayName = "Unloaded" }
local snapshot = MatchService.getShop(unloaded)
check("an unseated unknown player has no shop", snapshot.ok == false and snapshot.reason == "not_loaded",
    snapshot.reason)
check("loadout editing has been removed from the service",
    MatchService.setLoadout == nil)

local noProfilePlayer, noProfileRecord = newPlayer("NoProfile", nil)
check("a record without a profile has no shop",
    MatchService.getShop(noProfilePlayer).reason == "not_loaded")
noProfileRecord.profile = newProfile()
snapshot = MatchService.getShop(noProfilePlayer)
check("a profile added later unlocks the shop", snapshot.ok == true, snapshot.reason)

local soloProfile = newProfile({
    needle = { free = 1, purchased = 2 },
    remote = { purchased = 1 },
})
local soloPlayer = newPlayer("Solo", soloProfile)
snapshot = MatchService.getShop(soloPlayer)
check("a roomless player can open the shop", snapshot.ok == true, snapshot.reason)
check("a roomless shop has no mode", snapshot.phase == nil and snapshot.mode == nil)
check("a roomless shop has no lock state", snapshot.locked == nil)
check("a roomless shop has no practice switch", snapshot.consumeInPractice == nil)
check("the shop lists items in catalog order",
    #snapshot.items == 3
        and snapshot.items[1].id == "needle"
        and snapshot.items[2].id == "remote"
        and snapshot.items[3].id == "kick")
local needle = itemById(snapshot, "needle")
check("stock counts both buckets", needle.stock == 3, needle.stock)
check("the shop no longer exposes a loadout intent", needle.loadout == nil)
check("automatic carry is stock capped by the entry cap", needle.carry == 2, needle.carry)
check("an owned remote auto-carries one", itemById(snapshot, "remote").carry == 1)
check("an unowned item has no carry", itemById(snapshot, "kick").carry == 0)
check("configured products are purchasable",
    needle.purchasable == true and type(needle.productId) == "number")

---------------------------------------------------------------- 练习房：库存可见，实带为零

local seatedProfile = newProfile({
    needle = { free = 1, purchased = 1 },
    remote = { purchased = 1 },
})
local seated, record = seatPlayer("Seated", seatedProfile)
local room = MatchService.getRoomFor(seated)
check("the player is seated in a practice room", room ~= nil and room.mode == "practice")

snapshot = MatchService.getShop(seated)
check("the in-room snapshot names practice", snapshot.mode == "practice" and snapshot.practice == true)
check("practice reports no carried needle", itemById(snapshot, "needle").carry == 0)
check("practice reports no carried remote", itemById(snapshot, "remote").carry == 0)

local state = MatchService.getSync(seated)
local rosterEntry = findEntry(state.roster, record.id)
check("the waiting roster shows no practice carry",
    rosterEntry.items.needle == 0 and rosterEntry.items.remote == 0)
check("the waiting state includes the owned inventory",
    type(state.inventory) == "table" and state.inventory[1].stock == 2
        and state.inventory[2].stock == 1)
check("the waiting inventory rows carry zero in practice",
    state.inventory[1].carry == 0 and state.inventory[2].carry == 0)

-- Buying while waiting updates visible stock but still does not carry it.
seatedProfile.inventory.needle.purchased = 3
snapshot = MatchService.refreshShop(seated)
check("refreshShop sees the new stock", itemById(snapshot, "needle").stock == 4,
    itemById(snapshot, "needle").stock)
check("practice carry stays zero after a purchase", itemById(snapshot, "needle").carry == 0)
rosterEntry = findEntry(MatchService.getSync(seated).roster, record.id)
check("the waiting roster stays at zero after a purchase", rosterEntry.items.needle == 0,
    rosterEntry.items.needle)

---------------------------------------------------------------- 离房后按库存自动携带，进入对战房间同样自动

check("the player leaves the practice room", MatchService.leaveTable(seated) == true)
snapshot = MatchService.getShop(seated)
check("a roomless shop reports the next versus carry", snapshot.mode == nil
    and itemById(snapshot, "needle").carry == 2)

local partnerProfile = newProfile({ remote = { purchased = 1 } })
local partner, partnerRecord = seatPlayer("Partner", partnerProfile)
check("a versus table can be joined", MatchService.joinVersus(seated) == true)
local versus = MatchService.getRoomFor(seated)
check("the player is now on a versus table", versus ~= nil and versus.mode == "versus")
snapshot = MatchService.getShop(seated)
check("versus snapshots carry automatically", snapshot.mode == "versus"
    and itemById(snapshot, "needle").carry == 2 and itemById(snapshot, "remote").carry == 1)
check("versus snapshots no longer lock an editor", snapshot.locked == nil)
local versusRoster = MatchService.getSync(seated).roster
check("the versus waiting roster shows the automatic carry",
    findEntry(versusRoster, record.id).items.needle == 2)

check("the partner joins the same table", MatchService.joinVersus(partner, versus.id) == true)
check("both seats are filled", versus:isFull() == true)
advance(Constants.WAITING_TICKS)
check("the versus round has started", versus.phase == "playing", versus.phase)

local inGame = versus.game.players[record.id]
check("the game received the automatic carry",
    inGame.inv.needle == 2 and inGame.inv.remote == 1)
inGame.used.needle = 2
inGame.used.remote = 1
inGame.used.kick = 1

---------------------------------------------------------------- shutdown settlement

local settled = MatchService.settleActiveUsage("shutdown")
check("shutdown settles every participant once", settled == 2, settled)
local usage = findUsage(record.id)
check("shutdown reports the usage", usage ~= nil)
check("shutdown names itself as the reason", usage.context.reason == "shutdown",
    usage.context.reason)
check("shutdown uses the automatic carry", usage.carried.needle == 2
    and usage.carried.remote == 1, tostring(usage.carried.needle) .. "/" .. tostring(usage.carried.remote))
check("shutdown spends free stock before purchased",
    seatedProfile.inventory.needle.free == 0 and seatedProfile.inventory.needle.purchased == 2,
    seatedProfile.inventory.needle.free .. "/" .. seatedProfile.inventory.needle.purchased)
check("shutdown spends the carried remote", seatedProfile.inventory.remote.purchased == 0)
check("shutdown does not charge an unowned kick", seatedProfile.inventory.kick.purchased == 0)
check("a second shutdown settlement is a no-op", MatchService.settleActiveUsage("shutdown") == 0)
check("a second shutdown does not charge again", seatedProfile.inventory.needle.purchased == 2)

TestLib.finish()
