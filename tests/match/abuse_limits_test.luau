-- Abuse limits found in review, each pinned down as a regression:
--   1. character/color picks are throttled and a pick that changes nothing is not broadcast
--   2. a correct password does not hand back the failure budget (accomplice brute force)
--   3. an oversized room name is rejected before it is scanned
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local MatchService = require("./MatchService")
local Net = require("./Net")
local PlayerService = require("./PlayerService")
local RoomName = require("./RoomName")
local TestEnv = require("./TestEnv")

TestEnv.silent = true

local clock = 1000
local nextUserId = 70000

local function setup()
    clock = 1000
    MatchService.init({
        now = function()
            return clock
        end,
        filterRoomName = function(text)
            return text
        end,
    })
    PlayerService.refreshNames()
    Net.reset()
end

local function addPlayer(name)
    nextUserId += 1
    local player = { UserId = nextUserId, DisplayName = name }
    PlayerService.add(player)
    MatchService.onPlayerAdded(player)
    return player
end

local COLORS = { "red", "blue", "green", "yellow", "purple", "orange" }

---------------------------------------------------------------- 1. 选角/选色限流

do
    setup()
    local a, b = addPlayer("A"), addPlayer("B")
    local tid = MatchService.getTables()[1].id
    check("A sits", MatchService.joinVersus(a, tid) == true)
    check("B sits", MatchService.joinVersus(b, tid) == true)
    for i = 1, Constants.VERSUS_SPECTATORS do
        check("spectator " .. i .. " joins", MatchService.joinVersus(addPlayer("W" .. i), tid) == true)
    end
    local members = MatchService.getRoomFor(a):getMemberCount()
    check("a full audience is in the room", members == 2 + Constants.VERSUS_SPECTATORS, members)

    local roundStates = 0
    Net.sendHook = function(_, name)
        if name == "RoundState" then
            roundStates += 1
        end
    end

    -- One client hammering SelectColor.
    local accepted = 0
    for i = 1, 300 do
        if MatchService.selectColor(a, COLORS[i % #COLORS + 1]) then
            accepted += 1
        end
    end
    check("a spammer is held to the pick budget", accepted == Constants.SELECT_ATTEMPT_MAX, accepted)
    check("so the room is not flooded", roundStates <= Constants.SELECT_ATTEMPT_MAX * members, roundStates)

    -- The budget is per player: B is unaffected.
    check("another player can still pick", MatchService.selectColor(b, "green") == true)

    -- Character and color picks share one budget.
    check("a character pick is also refused", MatchService.selectChar(a, "haidao") == false)

    -- The window expires on its own.
    clock += Constants.SELECT_ATTEMPT_WINDOW_SECONDS + 0.1
    check("picking works again after the window", MatchService.selectColor(a, "purple") == true)
end

do
    -- Real clicking is never throttled: a full lap of every color fits.
    setup()
    local a = addPlayer("Clicker")
    local tid = MatchService.getTables()[1].id
    MatchService.joinVersus(a, tid)
    local all = true
    for _, color in ipairs(COLORS) do
        if not MatchService.selectColor(a, color) then
            all = false
        end
        clock += 0.1
    end
    check("a quick lap over all six colors is accepted", all)
    check("the lap fits inside the budget", #COLORS <= Constants.SELECT_ATTEMPT_MAX)
end

do
    -- A pick that changes nothing costs the room nothing.
    setup()
    local a, b = addPlayer("A"), addPlayer("B")
    local tid = MatchService.getTables()[1].id
    MatchService.joinVersus(a, tid)
    MatchService.joinVersus(b, tid)
    -- Each character remembers its own color, so pick the character first.
    check("first character pick", MatchService.selectChar(a, "haidao") == true)
    check("first color pick", MatchService.selectColor(a, "purple") == true)
    clock += Constants.SELECT_ATTEMPT_WINDOW_SECONDS + 0.1

    local roundStates = 0
    Net.sendHook = function(_, name)
        if name == "RoundState" then
            roundStates += 1
        end
    end
    check("repeating the same color is accepted", MatchService.selectColor(a, "purple") == true)
    check("repeating the same character is accepted", MatchService.selectChar(a, "haidao") == true)
    check("but neither is broadcast", roundStates == 0, roundStates)

    check("a different color still is", MatchService.selectColor(a, "orange") == true)
    check("and reaches both members", roundStates == 2, roundStates)
    check("an invalid color is still refused", MatchService.selectColor(a, "not-a-color") == false)
end

---------------------------------------------------------------- 2. 正确密码不再退还失败额度

do
    setup()
    local victim, accomplice, attacker = addPlayer("Victim"), addPlayer("Accomplice"), addPlayer("Attacker")
    local tables = MatchService.getTables()
    local t1, t2 = tables[1].id, tables[2].id

    check("victim sits at table 1", MatchService.joinVersus(victim, t1) == true)
    check("victim sets the target password", MatchService.setRoomConfig(victim, { password = "4821" }) == true)
    check("accomplice sits at table 2", MatchService.joinVersus(accomplice, t2) == true)
    check("accomplice sets a password the attacker knows", MatchService.setRoomConfig(accomplice, { password = "1111" }) == true)

    -- The trick: four wrong guesses, then a correct join elsewhere to get the budget back.
    local wrong, blocked = 0, false
    for cycle = 1, 6 do
        for _ = 1, 4 do
            local ok, reason = MatchService.joinVersus(attacker, t1, string.format("%04d", wrong + 1))
            if reason == "too_many_attempts" then
                blocked = true
            elseif not ok then
                wrong += 1
            end
        end
        MatchService.joinVersus(attacker, t2, "1111")
        MatchService.leaveTable(attacker)
    end
    check("the guess budget cannot be topped up", wrong <= Constants.PASSWORD_ATTEMPT_MAX, wrong)
    check("the attacker is blocked", blocked)

    -- The window still expires on its own.
    clock += Constants.PASSWORD_ATTEMPT_WINDOW_SECONDS + 1
    local ok, reason = MatchService.joinVersus(attacker, t1, "0000")
    check("a fresh window allows guessing again", ok == false and reason == "wrong_password", reason)
end

---------------------------------------------------------------- 3. 房名：超长输入先拒绝

do
    local t0 = os.clock()
    local v, why = RoomName.normalize(string.rep("a", 2 * 1024 * 1024))
    local elapsed = os.clock() - t0
    check("a 2MB name is rejected", v == nil and why == "invalid_name", why)
    check("without scanning it", elapsed < 0.25, elapsed)

    t0 = os.clock()
    v = RoomName.normalize(string.rep(" ", 1024 * 1024))
    check("1MB of spaces is rejected quickly too", v == nil and os.clock() - t0 < 0.25)

    check("30 ASCII characters are accepted", RoomName.normalize(string.rep("a", 30)) ~= nil)
    check("31 characters are rejected", RoomName.normalize(string.rep("a", 31)) == nil)
    check("30 emoji (4 bytes each) are accepted", RoomName.normalize(string.rep("\u{1F3AE}", 30)) ~= nil)
    check("30 CJK characters are accepted", RoomName.normalize(string.rep("\u{623F}", 30)) ~= nil)
    check("31 CJK characters are rejected", RoomName.normalize(string.rep("\u{623F}", 31)) == nil)
    check("modest padding around a name is trimmed", RoomName.normalize(string.rep(" ", 40) .. "Hello World" .. string.rep(" ", 40)) == "Hello World")
    check("a normal name is unchanged", RoomName.normalize("Hello World") == "Hello World")
    check("the filtered text is length-checked first", select(1, RoomName.validateFiltered(string.rep("a", 31))) == nil)
end

TestEnv.silent = false
TestLib.finish()
