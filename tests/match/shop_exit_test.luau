-- Opening the shop is a room exit: the client leaves the table first, then reads
-- a roomless shop snapshot. These tests pin the server-side outcome used by that
-- flow (no countdown pause exists).
-- Loaded by tests/run.sh from tests/build/match.
local TestLib = require("./testlib")
local check = TestLib.check

local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")
local ProfileSchema = require("./ProfileSchema")

local nextUserId = 27000

local function newProfile()
    return ProfileSchema.normalize(ProfileSchema.newProfile())
end

local function newPlayer(name)
    nextUserId += 1
    local player = { UserId = nextUserId, DisplayName = name }
    local record = PlayerService.add(player, newProfile())
    MatchService.onPlayerAdded(player)
    return player, record
end

local function advance(ticks)
    for _ = 1, ticks do
        MatchService.step()
    end
end

MatchService.init({
    precreateVersus = false,
    onUsageSettled = function() end,
})

---------------------------------------------------------------- 练习房：离房后商店只读，按库存自动携带

local shopper, shopperRecord = newPlayer("Shopper")
shopperRecord.profile.inventory.needle.free = 2
local practice = MatchService.getRoomFor(shopper)
check("the shopper starts in a practice room", practice ~= nil and practice.mode == "practice")
local practiceShop = MatchService.getShop(shopper)
check("practice shows the stock but carries none",
    practiceShop.items[1].stock == 2 and practiceShop.items[1].carry == 0,
    practiceShop.items[1].carry)
check("leaving the practice room succeeds", MatchService.leaveTable(shopper) == true)
check("the empty practice room is removed", MatchService.getRoomFor(shopper) == nil)
check("a roomless player has no sync state while browsing", MatchService.getSync(shopper) == nil)
local shop = MatchService.getShop(shopper)
check("the exited player can still open the shop", shop.ok == true, shop.reason)
check("the roomless shop has no lock state", shop.locked == nil)
check("the roomless shop has no room phase", shop.phase == nil and shop.mode == nil)
check("there is no loadout editor to save", MatchService.setLoadout == nil)
check("the roomless shop previews the versus carry",
    shop.items[1].carry == 2, shop.items[1].carry)

---------------------------------------------------------------- 对战桌：离房取消这张桌的倒计时

local p1 = newPlayer("VersusA")
local ok1, _, tableId = MatchService.joinVersus(p1, nil)
check("the first player creates/joins a versus table", ok1 == true, tableId)
local p2 = newPlayer("VersusB")
check("the second player joins the same table", MatchService.joinVersus(p2, tableId) == true)
local versus = MatchService.getRoomFor(p1)
check("both players share the table",
    versus ~= nil and MatchService.getRoomFor(p2) == versus and versus.mode == "versus")
advance(3)
check("the full table is counting down",
    versus:isCountdownReady() == true and versus.waitingLeft < versus.waitingTicks,
    tostring(versus.waitingLeft))

check("the shopper leaves the versus table", MatchService.leaveTable(p1) == true)
check("the leaver no longer has a room", MatchService.getRoomFor(p1) == nil)
local roomlessShop = MatchService.getShop(p1)
check("the leaver's shop is roomless",
    roomlessShop.ok == true and roomlessShop.mode == nil and roomlessShop.locked == nil,
    roomlessShop.reason)
check("the remaining seat still exists", MatchService.getRoomFor(p2) == versus)
check("one seat alone is not a countdown",
    versus.phase == "waiting" and versus:isFull() == false and versus:isCountdownReady() == false)
check("the remaining player's countdown was reset",
    versus.waitingLeft == versus.waitingTicks, tostring(versus.waitingLeft))

-- Filling the freed seat restarts the shared countdown; nothing is held by the
-- shopper's absence.
local p3 = newPlayer("VersusC")
check("the freed seat can be filled", MatchService.joinVersus(p3, tableId) == true)
advance(2)
check("the shared countdown runs again",
    versus.waitingLeft < versus.waitingTicks and versus.waitingLeft > 0,
    tostring(versus.waitingLeft))

---------------------------------------------------------------- 观战者离房不影响桌面

local watcher = newPlayer("Watcher")
check("a spectator can join the full table", MatchService.joinVersus(watcher, tableId) == true)
local watcherRecord = PlayerService.get(watcher)
check("the spectator is not seated", versus:isSeated(watcherRecord) == false)
local beforeWatcherLeaves = versus.waitingLeft
check("the spectator can leave", MatchService.leaveTable(watcher) == true)
check("the table keeps its seats",
    MatchService.getRoomFor(p1) == nil and MatchService.getRoomFor(p2) == versus
        and MatchService.getRoomFor(p3) == versus)
MatchService.step()
check("the table countdown continues after a spectator leaves",
    versus.waitingLeft == beforeWatcherLeaves - 1, tostring(versus.waitingLeft))

TestLib.finish()
