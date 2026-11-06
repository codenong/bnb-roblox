-- Pure versus-statistics rules. Loaded by tests/run.sh from tests/build/match.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local ProfileSchema = require("./ProfileSchema")
local VersusStats = require("./VersusStats")

local function newProfile()
    return ProfileSchema.normalize(ProfileSchema.newProfile())
end

local function versus(profile)
    return profile.stats.versus
end

local function record(id: string, profile)
    return { id = id, profile = profile }
end

local function context(a, b, opts)
    opts = opts or {}
    return {
        mode = opts.mode or "versus",
        participants = opts.participants or { a, b },
        activity = opts.activity or { [a.id] = true, [b.id] = true },
        left = opts.left or {},
        noAction = opts.noAction or {},
        durationTicks = if opts.durationTicks ~= nil then opts.durationTicks else Constants.VERSUS_MIN_TICKS,
        reason = opts.reason or "elimination",
    }
end

local function noStats(profile): boolean
    local s = versus(profile)
    return s.games == 0 and s.wins == 0 and s.losses == 0 and s.draws == 0
end

---------------------------------------------------------------- 只计对战

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)
    local result = VersusStats.apply(context(a, b, { mode = "practice" }), { winnerId = "a" })
    check("practice is not rated", result.rated == false and result.reason == "not_versus", result.reason)
    check("practice does not touch stats", noStats(pa) and noStats(pb))
end

---------------------------------------------------------------- 参战者校验

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)
    local result = VersusStats.apply(context(a, b, { participants = { a } }), { winnerId = "a" })
    check("one participant is not rated", result.reason == "participants", result.reason)

    local missing = { id = "b", profile = "not a profile" }
    result = VersusStats.apply(context(a, missing), { winnerId = "a" })
    check("missing profile is not rated", result.reason == "missing_profile", result.reason)
    check("a bad participant cannot partially update the other", noStats(pa) and noStats(pb))

    local duplicateA = record("a", newProfile())
    result = VersusStats.apply(context(a, duplicateA, { participants = { a, duplicateA } }), { winnerId = "a" })
    check("duplicate ids are not rated", result.reason == "participants", result.reason)
end

---------------------------------------------------------------- 无操作 / 时长门槛

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)

    local result = VersusStats.apply(
        context(a, b, { activity = { [a.id] = true, [b.id] = false } }),
        { winnerId = "a" }
    )
    check("an inactive participant voids the game", result.rated == false and result.reason == "no_action", result.reason)
    check("a no-action game does not count", noStats(pa) and noStats(pb))

    result = VersusStats.apply(
        context(a, b, { durationTicks = Constants.VERSUS_MIN_TICKS - 1 }),
        { winnerId = "a" }
    )
    check("a short game is excluded", result.rated == false and result.reason == "short_game", result.reason)
    check("a short game does not count", noStats(pa) and noStats(pb))

    result = VersusStats.apply(
        context(a, b, { durationTicks = Constants.VERSUS_MIN_TICKS, reason = "timeout" }),
        { draw = true, reason = "timeout" }
    )
    check("a timeout after the minimum is rated", result.rated == true, result.reason)
    check("a timeout counts as a game", versus(pa).games == 1 and versus(pb).games == 1)
    check("a timeout counts as a draw, not a win",
        versus(pa).draws == 1 and versus(pb).draws == 1
        and versus(pa).wins == 0 and versus(pb).losses == 0)
end

---------------------------------------------------------------- 胜负与平局

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)
    local result = VersusStats.apply(context(a, b), { winnerId = "a" })
    check("a full win is rated", result.rated == true and result.reason == "rated", result.reason)
    check("winner gets one win and one game", versus(pa).games == 1 and versus(pa).wins == 1)
    check("loser gets one loss and one game", versus(pb).games == 1 and versus(pb).losses == 1)
    check("summary reports both outcomes",
        result.outcomes["a"] == "win" and result.outcomes["b"] == "loss")

    local pc, pd = newProfile(), newProfile()
    local c, d = record("c", pc), record("d", pd)
    result = VersusStats.apply(context(c, d), { draw = true })
    check("a draw is rated", result.rated == true, result.reason)
    check("both sides get one draw", versus(pc).draws == 1 and versus(pd).draws == 1)
    check("a draw is not a win", versus(pc).wins == 0 and versus(pd).wins == 0)
end

---------------------------------------------------------------- 无效结果不写档案

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)
    check("no winner is invalid", VersusStats.apply(context(a, b), {}).reason == "invalid_result")
    check("an outsider winner is invalid",
        VersusStats.apply(context(a, b), { winnerId = "outsider" }).reason == "invalid_result")
    check("a leaver cannot be the winner",
        VersusStats.apply(context(a, b, { left = { [a.id] = true } }), { winnerId = "a" }).reason == "invalid_result")
    check("a draw cannot contain a leaver",
        VersusStats.apply(context(a, b, { left = { [b.id] = true } }), { draw = true }).reason == "invalid_result")
    check("invalid results never touch stats", noStats(pa) and noStats(pb))
end

---------------------------------------------------------------- 中途退出：短局也判负

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)
    local result = VersusStats.apply(
        context(a, b, {
            left = { [b.id] = true },
            durationTicks = 0,
            reason = "leave",
        }),
        { winnerId = "a", reason = "leave" }
    )
    check("quitting is rated even in a very short game", result.rated == true, result.reason)
    check("the player who stayed gets the win", versus(pa).games == 1 and versus(pa).wins == 1)
    check("the leaver gets the loss", versus(pb).games == 1 and versus(pb).losses == 1)
    check("the summary records the leaver's loss", result.outcomes["b"] == "loss")

    -- The no-action rule is stricter than the quit rule: a game where someone
    -- never acted is never rated, even if the opponent eventually wins.
    local pc, pd = newProfile(), newProfile()
    local c, d = record("c", pc), record("d", pd)
    result = VersusStats.apply(
        context(c, d, {
            left = { [d.id] = true },
            activity = { [c.id] = true, [d.id] = false },
            durationTicks = 0,
        }),
        { winnerId = "c" }
    )
    check("a no-action quit is still unrated", result.reason == "no_action", result.reason)
    check("a no-action quit does not count", noStats(pc) and noStats(pd))
end

---------------------------------------------------------------- 累计与独立档案

do
    local pa, pb = newProfile(), newProfile()
    local a, b = record("a", pa), record("b", pb)
    VersusStats.apply(context(a, b), { winnerId = "a" })
    VersusStats.apply(context(a, b), { winnerId = "b" })
    VersusStats.apply(context(a, b), { draw = true })
    check("games accumulate once per rated round", versus(pa).games == 3 and versus(pb).games == 3)
    check("wins/losses/draws add up", versus(pa).wins == 1 and versus(pa).losses == 1 and versus(pa).draws == 1)
    check("the other profile is independent", versus(pb).wins == 1 and versus(pb).losses == 1 and versus(pb).draws == 1)
end

TestLib.finish()
