-- Persistent versus rooms, the temporary host, room names and entry passwords.
-- The server modules run against the same lightweight stubs as the other match
-- tests; TextService is injected so filtering can be exercised and yielded.
local TestLib = require("./testlib")
local check = TestLib.check

local TestEnv = require("./TestEnv")
local Constants = require("./Constants")
local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")
local Net = require("./Net")
local Room = require("./Room")
local RoomName = require("./RoomName")

local nextUserId = 21000
local notices = {}
local filters = {}
local envClock = 1000
local filterImpl = nil

local function setup(opts)
    opts = opts or {}
    notices = {}
    filters = {}
    envClock = opts.clock or 1000
    filterImpl = opts.filter or function(text)
        return text
    end
    MatchService.init({
        precreateVersus = opts.precreateVersus,
        onSettled = opts.onSettled,
        filterRoomName = function(text, userId)
            table.insert(filters, { text = text, userId = userId })
            return filterImpl(text, userId)
        end,
        notify = function(player, message)
            notices[player] = notices[player] or {}
            table.insert(notices[player], message)
        end,
        now = function()
            return envClock
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

local function removePlayer(player)
    local record = PlayerService.remove(player)
    MatchService.onPlayerRemoving(player, record)
    return record
end

local function advance(ticks)
    for _ = 1, ticks do
        MatchService.step()
    end
end

local function getTableById(id)
    for _, entry in ipairs(MatchService.getTables()) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

local function firstTable()
    return MatchService.getTables()[1]
end

local function hasPasswordField(payload)
    return payload ~= nil and rawget(payload, "password") ~= nil
end

local function noticeContains(player, text)
    for _, message in ipairs(notices[player] or {}) do
        if string.find(message, text, 1, true) then
            return true
        end
    end
    return false
end

---------------------------------------------------------------- 房名规则（纯逻辑）
do
    check("room name: 30 Chinese codepoints accepted", RoomName.normalize(string.rep("字", 30)) == string.rep("字", 30))
    local tooLong, tooLongErr = RoomName.normalize(string.rep("字", 31))
    check("room name: 31 codepoints rejected", tooLong == nil and tooLongErr == "invalid_name")
    check("room name: five visible codepoints accepted", RoomName.normalize("abcde") == "abcde")
    check("room name: four visible codepoints rejected", RoomName.normalize("abcd") == nil)
    check("room name: spaces do not count as visible",
        RoomName.normalize("a b c d") == nil and RoomName.normalize("a b c d e") == "a b c d e")
    check("room name: newlines do not count as visible",
        RoomName.normalize("ab\ncd") == nil and RoomName.normalize("abc\nde") == "abc\nde")

    check("room name: CRLF and CR normalize to LF",
        RoomName.normalize("  abcde\r\nfghij\rklmno  ") == "abcde\nfghij\nklmno")
    check("room name: a plain LF is allowed", RoomName.normalize("abcde\nfghij") == "abcde\nfghij")
    check("room name: leading/trailing spaces and newlines are trimmed",
        RoomName.normalize(" \n 名字五个字 \n ") == "名字五个字")
    check("room name: tab rejected (even with enough visible text)", RoomName.normalize("abcde\tf") == nil)
    check("room name: NUL rejected", RoomName.normalize("abcde" .. string.char(0) .. "f") == nil)
    check("room name: DEL rejected", RoomName.normalize("abcde" .. string.char(127) .. "f") == nil)
    check("room name: C1 control rejected", RoomName.normalize("abcde" .. string.char(0xC2, 0x9B) .. "f") == nil)
    check("room name: invalid UTF-8 rejected", RoomName.normalize(string.char(0xFF)) == nil)
    check("room name: all whitespace rejected", RoomName.normalize(" \n  ") == nil)
    check("room name: empty rejected", RoomName.normalize("") == nil)
    check("room name: non-string rejected", RoomName.normalize(5) == nil)

    local invisible = {
        { "no-break space", 0x00A0 },
        { "soft hyphen", 0x00AD },
        { "ogham space mark", 0x1680 },
        { "en space", 0x2002 },
        { "zero-width space", 0x200B },
        { "zero-width non-joiner", 0x200C },
        { "left-to-right mark", 0x200E },
        { "right-to-left mark", 0x200F },
        { "line separator", 0x2028 },
        { "paragraph separator", 0x2029 },
        { "right-to-left override", 0x202E },
        { "narrow no-break space", 0x202F },
        { "word joiner", 0x2060 },
        { "right-to-left isolate", 0x2066 },
        { "ideographic space", 0x3000 },
        { "byte-order mark", 0xFEFF },
        { "tag character", 0xE0041 },
    }
    for _, entry in ipairs(invisible) do
        check("room name: " .. entry[1] .. " rejected",
            RoomName.normalize("abcde" .. utf8.char(entry[2]) .. "f") == nil)
    end

    local blankGlyphs = { 0x034F, 0x180B, 0x115F, 0x17B4, 0x2800, 0x3164, 0xFFA0 }
    for _, code in ipairs(blankGlyphs) do
        check(string.format("room name: blank glyph U+%04X does not count", code),
            RoomName.normalize(string.rep(utf8.char(code), 5)) == nil)
    end
    check("room name: blank glyphs cannot pad four visible characters",
        RoomName.normalize("abcd" .. string.rep(utf8.char(0x2800), 10)) == nil)

    local fancy = "泡泡🎉！？"
    check("room name: Chinese/emoji/punctuation accepted", RoomName.normalize(fancy) == fancy)
    local family = "👨‍👩‍👧‍👦"
    check("room name: ZWJ emoji accepted", RoomName.normalize(family .. "房间名") == family .. "房间名")
    check("room name: display folds CR/LF to spaces", RoomName.display(" a\r\nb ") == "a b")
    check("room name: display of blank is nil", RoomName.display(" \n ") == nil)
    check("room name: filtered text revalidated", RoomName.validateFiltered(" 过滤后的名 ") == " 过滤后的名 ")
    check("room name: filtered text still needs five visible codepoints",
        RoomName.validateFiltered(" 过滤 ") == nil)
    check("room name: overlong filtered text rejected", RoomName.validateFiltered(string.rep("x", 31)) == nil)
    check("room name: empty filtered text rejected", RoomName.validateFiltered("") == nil)

    check("room input: exactly 30 codepoints unchanged",
        RoomName.limitInput(string.rep("a", 30)) == string.rep("a", 30))
    check("room input: 31 codepoints truncate to 30",
        RoomName.limitInput(string.rep("a", 31)) == string.rep("a", 30))
    check("room input: multibyte truncation stays valid",
        RoomName.limitInput(string.rep("字", 31)) == string.rep("字", 30))
    check("room input: emoji truncation stays valid",
        RoomName.limitInput(string.rep("🎉", 31)) == string.rep("🎉", 30))
    check("room input: non-string becomes empty", RoomName.limitInput(nil) == "")
end

---------------------------------------------------------------- 默认预创建常驻房
do
    setup({})
    check("default init precreates four tables", MatchService.getRoomCount() == Constants.VERSUS_TABLES,
        MatchService.getRoomCount())
    local tables = MatchService.getTables()
    check("browser lists four tables", #tables == 4, #tables)
    for i, entry in ipairs(tables) do
        check("precreated table " .. i .. " has the default name", entry.name == "房间 " .. i, entry.name)
        check("precreated table " .. i .. " is empty and waiting", entry.seatCount == 0 and entry.phase == "waiting")
        check("precreated table " .. i .. " has no host", entry.hostId == nil and entry.hostName == nil)
        check("precreated table " .. i .. " has no password", entry.hasPassword == false and not hasPasswordField(entry))
        check("precreated table " .. i .. " is browseable", entry.joinable == true)
    end

    local player = addPlayer("Practice")
    local practice = MatchService.getRoomFor(player)
    check("a new player still gets a practice room", practice ~= nil and practice.mode == "practice")
    check("the practice room is created after the precreated tables", practice ~= nil and practice.id > 4,
        practice and practice.id)
    local sync = MatchService.getSync(player)
    check("practice state has no versus config", sync.roomName == nil and sync.hostId == nil
        and sync.hostName == nil and sync.hasPassword == false and sync.isHost == false)
    check("practice rooms are not in the table browser", #MatchService.getTables() == 4)
end

---------------------------------------------------------------- 懒创建上限与密码门
do
    setup({ precreateVersus = false })
    check("lazy init starts with no tables", #MatchService.getTables() == 0)

    local hosts = {}
    for i = 1, 4 do
        local host = addPlayer("Host" .. i)
        local ok, reason, id = MatchService.joinVersus(host)
        check("quick join creates table " .. i, ok == true, tostring(reason))
        local room = MatchService.getRoomFor(host)
        check("table " .. i .. " was created", room ~= nil and room.mode == "versus" and room.id == id)
        check("table " .. i .. " default name", room:getRoomName() == "房间 " .. i, room:getRoomName())
        check("table " .. i .. " first seat is host", room:getHostId() ~= nil
            and room:getHostId() == PlayerService.get(host).id)
        check("table " .. i .. " password set", MatchService.setRoomConfig(host, { password = tostring(1000 + i) }) == true)
        hosts[i] = { player = host, room = room }
    end

    local tables = MatchService.getTables()
    check("lazy creation stops at the table cap", #tables == 4, #tables)
    for _, entry in ipairs(tables) do
        check("lazy table " .. entry.id .. " is locked", entry.hasPassword == true and not hasPasswordField(entry))
        check("lazy table " .. entry.id .. " never exposes a password", not hasPasswordField(entry))
    end

    local quick = addPlayer("Quick")
    local quickPractice = MatchService.getRoomFor(quick)
    local ok, reason = MatchService.joinVersus(quick)
    check("quick join with every table locked returns no_tables", ok == false and reason == "no_tables", reason)
    check("a rejected quick join leaves the player in practice", MatchService.getRoomFor(quick) == quickPractice)

    check("the first host can clear the password",
        MatchService.setRoomConfig(hosts[1].player, { password = "" }) == true)
    ok, reason = MatchService.joinVersus(quick)
    check("quick join skips still-locked tables and takes the unlocked one", ok == true, tostring(reason))
    check("quick join landed in the unlocked table", MatchService.getRoomFor(quick) == hosts[1].room)
    local quickSync = MatchService.getSync(quick)
    check("the quick-joiner is a seat, not the host", quickSync.spectating == false and quickSync.isHost == false)
    check("the existing host is unchanged", hosts[1].room:getHostId() == PlayerService.get(hosts[1].player).id)
end

---------------------------------------------------------------- 房主、状态字段与设置权限
do
    setup({ precreateVersus = false })
    local a = addPlayer("A")
    local b = addPlayer("B")
    local c = addPlayer("C")

    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)
    local aId = PlayerService.get(a).id
    local bId = PlayerService.get(b).id
    local ok, reason = MatchService.joinVersus(b, room.id)
    check("second human takes the second seat", ok == true, tostring(reason))
    ok, reason = MatchService.joinVersus(c, room.id)
    check("third human becomes a spectator", ok == true, tostring(reason))

    local syncA = MatchService.getSync(a)
    local syncB = MatchService.getSync(b)
    local syncC = MatchService.getSync(c)
    check("first seated player is host", syncA.isHost == true and syncA.hostId == aId and syncA.hostName == "A")
    check("second seated player is not host", syncB.isHost == false and syncB.hostId == aId)
    check("spectator is not host", syncC.isHost == false and syncC.spectating == true and syncC.hostId == aId)
    check("room state starts with the default name", syncA.roomName == "房间 1", syncA.roomName)
    check("room state starts without a password", syncA.hasPassword == false)

    ok, reason = MatchService.setRoomConfig(b, { name = "hacked" })
    check("second seat cannot rename", ok == false and reason == "not_host", reason)
    ok, reason = MatchService.setRoomConfig(c, { name = "hacked" })
    check("spectator cannot rename", ok == false and reason == "not_host", reason)
    local outsider = addPlayer("Outsider")
    ok, reason = MatchService.setRoomConfig(outsider, { name = "hacked" })
    check("practice player cannot rename", ok == false and reason == "not_versus", reason)
    MatchService.leaveTable(outsider)
    ok, reason = MatchService.setRoomConfig(outsider, { name = "hacked" })
    check("player browsing without a room cannot rename", ok == false and reason == "not_in_room", reason)
    ok, reason = MatchService.setRoomConfig({ UserId = 987654, DisplayName = "Ghost" }, { name = "x" })
    check("unloaded player cannot rename", ok == false and reason == "not_loaded", reason)

    ok, reason = MatchService.setRoomConfig(a, nil)
    check("nil request rejected", ok == false and reason == "invalid_request", reason)
    ok, reason = MatchService.setRoomConfig(a, {})
    check("empty request rejected", ok == false and reason == "invalid_request", reason)
    ok, reason = MatchService.setRoomConfig(a, { name = 1 })
    check("non-string name rejected", ok == false and reason == "invalid_request", reason)
    ok, reason = MatchService.setRoomConfig(a, { password = 1234 })
    check("non-string password rejected", ok == false and reason == "invalid_request", reason)

    -- Five configuration writes are allowed per window. This block uses exactly
    -- five to also cover the field semantics.
    filters = {}
    ok, reason = MatchService.setRoomConfig(a, { name = " 朋友们的\r\n房 ", password = "1234" })
    check("host sets name and password together", ok == true, tostring(reason))
    check("the filter receives the normalized name", filters[#filters] and filters[#filters].text == "朋友们的\n房",
        filters[#filters] and filters[#filters].text)
    check("the filter receives the player's UserId", filters[#filters] and filters[#filters].userId == a.UserId)
    syncA = MatchService.getSync(a)
    syncB = MatchService.getSync(b)
    check("the new name reaches the other seat", syncB.roomName == "朋友们的\n房", syncB.roomName)
    check("the other seat sees the password flag", syncB.hasPassword == true and syncB.isHost == false)
    local entry = getTableById(room.id)
    check("the browser shows the new name", entry and entry.name == "朋友们的\n房", entry and entry.name)
    check("the browser shows the host name", entry and entry.hostName == "A", entry and entry.hostName)
    check("the browser never carries the password", not hasPasswordField(entry))
    check("sync never carries the password", not hasPasswordField(syncB))
    check("the server checks the password exactly", room:checkPassword("1234") == true
        and room:checkPassword("1235") == false)

    ok = MatchService.setRoomConfig(a, { password = "5678" })
    syncB = MatchService.getSync(b)
    check("password-only update leaves the name unchanged", ok == true and syncB.roomName == "朋友们的\n房")
    check("password-only update replaces the password", room:checkPassword("5678") == true)

    ok = MatchService.setRoomConfig(a, { name = "新的房间名" })
    check("name-only update leaves the password set", ok == true and room:checkPassword("5678") == true)
    check("name-only update changes the name", MatchService.getSync(b).roomName == "新的房间名")

    ok = MatchService.setRoomConfig(a, { password = "" })
    check("an empty password clears the password", ok == true and room:hasPassword() == false)

    ok = MatchService.setRoomConfig(a, { name = "朋友们的\n房", password = "1234" })
    check("the fifth write in the window still succeeds", ok == true, tostring(reason))

    advance(Constants.WAITING_TICKS + 5)
    check("the full table starts playing", MatchService.getSync(a).phase == "playing",
        MatchService.getSync(a).phase)
    ok, reason = MatchService.setRoomConfig(a, { name = "late" })
    check("the host cannot rename after the countdown", ok == false and reason == "not_waiting", reason)
    ok, reason = MatchService.setRoomConfig(b, { name = "late" })
    check("a non-host cannot rename during play", ok == false and reason == "not_host", reason)
    ok, reason = MatchService.setRoomConfig(c, { name = "late" })
    check("a spectating non-host cannot rename", ok == false and reason == "not_host", reason)

    local spectators = room:getSpectatorRecords()
    check("getSpectatorRecords returns the audience", #spectators == 1 and spectators[1].player == c)
    table.remove(spectators, 1)
    check("getSpectatorRecords returns a copy", #room:getSpectatorRecords() == 1
        and room:getSpectatorRecords()[1].player == c)

    -- Leaving mid-round forfeits and transfers the host before settlement.
    removePlayer(a)
    local afterA = MatchService.getSync(b)
    check("host leaving mid-round settles the round", afterA.phase == "ended", afterA.phase)
    check("host leaving mid-round forfeits", afterA.lastResult and afterA.lastResult.reason == "leave",
        afterA.lastResult and afterA.lastResult.reason)
    check("the earliest remaining seat becomes host", afterA.isHost == true and afterA.hostId == bId)
    check("host transfer resets the name", afterA.roomName == "房间 1", afterA.roomName)
    check("host transfer resets the password", afterA.hasPassword == false)
    check("host transfer keeps the spectator", MatchService.getSync(c).spectating == true)

    -- The last seat leaving evicts the audience and retains the table.
    removePlayer(b)
    local afterB = MatchService.getSync(c)
    check("the last seat leaving evicts the spectator", afterB and afterB.spectating == false
        and afterB.mode == "practice" and afterB.roomId ~= room.id)
    check("the spectator is told the room has no host", noticeContains(c, "房主为空"))
    local empty = getTableById(room.id)
    check("the empty versus room is retained", empty ~= nil)
    check("the retained room is waiting and empty", empty and empty.phase == "waiting" and empty.seatCount == 0)
    check("the retained room has no host or password", empty and empty.hostId == nil
        and empty.hasPassword == false)
    check("the retained room is back to its default name", empty and empty.name == "房间 1", empty and empty.name)
    check("the evicted spectator did not take a seat", empty and empty.spectatorCount == 0)
    check("no room was created for the removed seats", MatchService.getRoomFor(a) == nil
        and MatchService.getRoomFor(b) == nil)

    advance(60)
    local stillThere = getTableById(room.id)
    check("stepping does not delete an empty versus room", stillThere ~= nil and stillThere.phase == "waiting")

    local d = addPlayer("D")
    ok, reason = MatchService.joinVersus(d, room.id)
    check("the retained table can be joined again", ok == true, tostring(reason))
    check("the next first seat becomes host", room:getHostId() == PlayerService.get(d).id)
    check("the retained table is reused, not replaced", MatchService.getRoomFor(d) == room)
end

---------------------------------------------------------------- 配置字段校验
do
    setup({ precreateVersus = false })
    local a = addPlayer("Config")
    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)

    local ok, reason = MatchService.setRoomConfig(a, { name = "" })
    check("an empty name is rejected", ok == false and reason == "invalid_name", reason)
    ok, reason = MatchService.setRoomConfig(a, { name = "   " })
    check("a whitespace-only name is rejected", ok == false and reason == "invalid_name", reason)
    ok, reason = MatchService.setRoomConfig(a, { name = "abcde\tf" })
    check("a control character in the name is rejected", ok == false and reason == "invalid_name", reason)
    ok, reason = MatchService.setRoomConfig(a, { name = "abcd" })
    check("a name with too few visible characters is rejected",
        ok == false and reason == "invalid_name", reason)
    ok, reason = MatchService.setRoomConfig(a, { name = "abcde" .. utf8.char(0x200B) .. "f" })
    check("an invisible character in the name is rejected",
        ok == false and reason == "invalid_name", reason)
    -- Five rejected writes exhaust the short config window; move past it so the
    -- password checks below exercise validation rather than rate limiting.
    envClock += Constants.ROOM_CONFIG_WINDOW_SECONDS + 1
    ok, reason = MatchService.setRoomConfig(a, { password = "123" })
    check("a three-digit password is rejected", ok == false and reason == "invalid_password", reason)
    ok, reason = MatchService.setRoomConfig(a, { password = "1234567" })
    check("a seven-digit password is rejected", ok == false and reason == "invalid_password", reason)
    check("rejected configurations leave the room unchanged",
        room:getRoomName() == "房间 1" and not room:hasPassword())
end

---------------------------------------------------------------- 密码进入座位和观战
do
    setup({ precreateVersus = false })
    local a = addPlayer("Host")
    local b = addPlayer("Guest")
    local c = addPlayer("Viewer")
    local d = addPlayer("Other")

    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)
    check("password room setup", MatchService.setRoomConfig(a, { name = "密室房间名", password = "1234" }) == true)

    local bPractice = MatchService.getRoomFor(b)
    local ok, reason = MatchService.joinVersus(b, room.id)
    check("a seat requires the password", ok == false and reason == "password_required", reason)
    check("a missing password does not move the player", MatchService.getRoomFor(b) == bPractice)
    ok, reason = MatchService.joinVersus(b, room.id, 1234)
    check("a non-string password is rejected", ok == false and reason == "password_required", reason)
    ok, reason = MatchService.joinVersus(b, room.id, "0000")
    check("a wrong password is rejected", ok == false and reason == "wrong_password", reason)
    check("a wrong password does not move the player", MatchService.getRoomFor(b) == bPractice)
    ok, reason = MatchService.joinVersus(b, room.id, "1234")
    check("the correct password takes the second seat", ok == true and MatchService.getRoomFor(b) == room, tostring(reason))

    advance(31)
    local countdownBeforeSpectator = MatchService.getSync(a).endsIn
    ok, reason = MatchService.join(c, { mode = "versus", tableId = room.id })
    check("spectating requires the password", ok == false and reason == "password_required", reason)
    ok, reason = MatchService.join(c, { mode = "versus", tableId = room.id, password = "9999" })
    check("a wrong spectator password is rejected", ok == false and reason == "wrong_password", reason)
    ok, reason = MatchService.join(c, { mode = "versus", tableId = room.id, password = "1234" })
    check("the correct password admits a spectator", ok == true, tostring(reason))
    check("the admitted spectator is not seated", MatchService.getSync(c).spectating == true
        and MatchService.getRoomFor(c) == room)
    check("a spectator does not restart the countdown",
        MatchService.getSync(a).endsIn == countdownBeforeSpectator,
        tostring(countdownBeforeSpectator) .. " -> " .. tostring(MatchService.getSync(a).endsIn))

    local entry = getTableById(room.id)
    check("the browser shows the locked room", entry and entry.hasPassword == true and entry.name == "密室房间名")
    check("the browser hides the host's password", not hasPasswordField(entry))
    check("sync hides the host's password", not hasPasswordField(MatchService.getSync(b)))

    -- Quick join skips locked tables and creates the next persistent slot.
    ok, reason = MatchService.joinVersus(d)
    check("quick join skips a locked waiting table", ok == true and MatchService.getRoomFor(d) ~= room,
        tostring(reason))
    local dRoom = MatchService.getRoomFor(d)
    check("the skipped-to room is unlocked", dRoom:hasPassword() == false and dRoom:getRoomName() == "房间 2")

    -- A failed switch from an existing versus room keeps that room.
    ok, reason = MatchService.joinVersus(d, room.id, "0000")
    check("a wrong password on another table is rejected", ok == false and reason == "wrong_password", reason)
    check("a failed switch keeps the current table", MatchService.getRoomFor(d) == dRoom)
    ok, reason = MatchService.joinVersus(d, 99999)
    check("an unknown table is rejected", ok == false and reason == "no_table", reason)
    check("an unknown table keeps the current table", MatchService.getRoomFor(d) == dRoom)
    ok, reason = MatchService.joinVersus(d, 1.5)
    check("a fractional table id is rejected", ok == false and reason == "invalid_table", reason)
end

---------------------------------------------------------------- 密码尝试限流
do
    setup({ precreateVersus = false, clock = 1000 })
    local a = addPlayer("Locked")
    local b = addPlayer("Guesser")
    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)
    check("rate-limit setup", MatchService.setRoomConfig(a, { password = "1234" }) == true)
    local practice = MatchService.getRoomFor(b)

    for i = 1, Constants.PASSWORD_ATTEMPT_MAX do
        local ok, reason = MatchService.joinVersus(b, room.id, "0000")
        check("password failure " .. i .. " is rejected", ok == false and reason == "wrong_password", reason)
    end
    local ok, reason = MatchService.joinVersus(b, room.id, "1234")
    check("the correct password is blocked after too many failures", ok == false and reason == "too_many_attempts", reason)
    check("the blocked player stays in practice", MatchService.getRoomFor(b) == practice)

    envClock += Constants.PASSWORD_ATTEMPT_WINDOW_SECONDS + 1
    ok, reason = MatchService.joinVersus(b, room.id, "1234")
    check("the correct password works after the window expires", ok == true, tostring(reason))
    check("the successful player is seated", MatchService.getRoomFor(b) == room)

    -- A success must NOT hand the failure budget back. Otherwise a second account
    -- holding a known password could reset it after every few guesses.
    MatchService.leaveTable(b)
    check("leaving a password room succeeds", MatchService.getRoomFor(b) == nil)
    for i = 1, 4 do
        ok, reason = MatchService.joinVersus(b, room.id, "0000")
        check("post-success failure " .. i, ok == false and reason == "wrong_password", reason)
    end
    ok, reason = MatchService.joinVersus(b, room.id, "1234")
    check("a correct password is still accepted while under the limit", ok == true, tostring(reason))
    MatchService.leaveTable(b)
    ok, reason = MatchService.joinVersus(b, room.id, "0000")
    check("the fifth failure is still counted", ok == false and reason == "wrong_password", reason)
    ok, reason = MatchService.joinVersus(b, room.id, "1234")
    check("the earlier success did not reset the budget", ok == false and reason == "too_many_attempts", reason)
end

---------------------------------------------------------------- 配置限流
do
    setup({ precreateVersus = false, clock = 2000 })
    local a = addPlayer("ConfigRate")
    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)

    for i = 1, Constants.ROOM_CONFIG_ATTEMPT_MAX - 1 do
        check("config write " .. i .. " succeeds", MatchService.setRoomConfig(a, { name = "name" .. i }) == true)
    end
    check("the last allowed config write succeeds",
        MatchService.setRoomConfig(a, { password = "1234" }) == true)
    local ok, reason = MatchService.setRoomConfig(a, { name = "blocked" })
    check("config writes are rate-limited", ok == false and reason == "config_rate_limited", reason)
    check("the blocked change was not applied", room:getRoomName() ~= "blocked")

    envClock += Constants.ROOM_CONFIG_WINDOW_SECONDS + 1
    ok, reason = MatchService.setRoomConfig(a, { name = "after" })
    check("config writes work again after the window", ok == true and room:getRoomName() == "after", tostring(reason))
    check("the password survives the window", room:checkPassword("1234") == true)
end

---------------------------------------------------------------- 注入的文本过滤
do
    setup({ precreateVersus = false })
    local a = addPlayer("FilterHost")
    local b = addPlayer("FilterGuest")
    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)

    filters = {}
    filterImpl = function(text)
        return "过滤:" .. text
    end
    local ok, reason = MatchService.setRoomConfig(a, { name = "abcde" })
    check("the filtered result is stored", ok == true and room:getRoomName() == "过滤:abcde", tostring(reason))
    check("the filter records text and UserId", filters[1] and filters[1].text == "abcde"
        and filters[1].userId == a.UserId)

    filterImpl = function()
        return nil
    end
    ok, reason = MatchService.setRoomConfig(a, { name = "nil-name" })
    check("a filter returning nil is rejected", ok == false and reason == "filter_failed", reason)
    check("a rejected filter leaves the name unchanged", room:getRoomName() == "过滤:abcde")

    filterImpl = function()
        error("filter exploded")
    end
    ok, reason = MatchService.setRoomConfig(a, { name = "throw" })
    check("a throwing filter is rejected", ok == false and reason == "filter_failed", reason)
    check("a throwing filter leaves the name unchanged", room:getRoomName() == "过滤:abcde")

    filterImpl = function()
        return string.rep("x", Constants.ROOM_NAME_MAX_CODEPOINTS + 1)
    end
    ok, reason = MatchService.setRoomConfig(a, { name = "long-name" })
    check("an overlong filtered name is rejected", ok == false and reason == "filter_failed", reason)

    -- The filter may yield; leaving the room inside it must stop the write.
    check("the guest joins for the recheck", MatchService.joinVersus(b, room.id) == true)
    filterImpl = function()
        MatchService.leaveTable(a)
        return "late-name"
    end
    ok, reason = MatchService.setRoomConfig(a, { name = "late-name" })
    check("a host that leaves during filtering is rejected", ok == false and reason == "not_in_room", reason)
    check("a stale filtered name is not applied", room:getRoomName() == "房间 1", room:getRoomName())
    check("the remaining seat became host after the leave", room:getHostId() == PlayerService.get(b).id)
end

---------------------------------------------------------------- 等待阶段房主转移
do
    setup({ precreateVersus = false })
    local a = addPlayer("WaitHost")
    local b = addPlayer("WaitGuest")
    local c = addPlayer("WaitViewer")
    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)
    check("waiting transfer setup", MatchService.setRoomConfig(a, { name = "旧房间名字", password = "1234" }) == true)
    check("the guest joins", MatchService.joinVersus(b, room.id, "1234") == true)
    check("the viewer joins", MatchService.joinVersus(c, room.id, "1234") == true)

    removePlayer(a)
    local syncB = MatchService.getSync(b)
    check("a waiting host leaving transfers to the remaining seat",
        syncB.phase == "waiting" and syncB.isHost == true and syncB.hostId == PlayerService.get(b).id)
    check("a waiting transfer resets the name and password",
        syncB.roomName == "房间 1" and syncB.hasPassword == false)
    check("a waiting transfer keeps the spectator", MatchService.getSync(c).spectating == true)
    check("the table is still waiting for a second seat", room:getSeatCount() == 1)
end

---------------------------------------------------------------- 出错回收：常驻房保留并重置
do
    setup({ precreateVersus = false })
    local a = addPlayer("RecycleA")
    local b = addPlayer("RecycleB")
    MatchService.joinVersus(a)
    local room = MatchService.getRoomFor(a)
    check("the recycle guest joins", MatchService.joinVersus(b, room.id) == true)
    check("recycle setup has a full table", room:getSeatCount() == 2)

    TestEnv.silent = true
    TestEnv.warnings = {}
    room.step = function()
        error("boom")
    end
    MatchService.step()
    TestEnv.silent = false

    local warnings = 0
    for _, message in ipairs(TestEnv.warnings) do
        if string.find(message, "failed and was recycled", 1, true) then
            warnings += 1
        end
    end
    check("a failing versus room is logged once", warnings == 1, warnings)
    check("the failed versus room is retained", getTableById(room.id) ~= nil)
    check("the retained room is reset", room:getPhase() == "waiting" and room:getSeatCount() == 0
        and room:getHostId() == nil and room:getRoomName() == "房间 1" and not room:hasPassword())
    check("the members were moved to practice rooms", MatchService.getRoomFor(a) ~= nil
        and MatchService.getRoomFor(a).mode == "practice" and MatchService.getRoomFor(b) ~= nil
        and MatchService.getRoomFor(b).mode == "practice")
    check("the members did not get the same practice room", MatchService.getRoomFor(a) ~= MatchService.getRoomFor(b))
    check("the room count is table plus two practice rooms", MatchService.getRoomCount() == 3,
        MatchService.getRoomCount())

    -- Restore the real step and prove the retained room is still usable.
    room.step = Room.step
    local c = addPlayer("RecycleC")
    local ok, reason = MatchService.joinVersus(c, room.id)
    check("the retained room accepts a new player", ok == true, tostring(reason))
    check("the retained room is reused", MatchService.getRoomFor(c) == room)
    check("the new first seat is the host", room:getHostId() == PlayerService.get(c).id)
end

TestLib.finish()
