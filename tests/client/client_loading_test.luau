-- Startup while the server is still loading the player's profile. Main.client runs
-- once per process, so each scenario is a separate run: luau client_loading_test.luau -a <scenario>
--   event  the real state arrives as a RoundState event
--   poll   the event is missed; the poll loop finds the real state
--   empty  GetSync answers nothing at all
--   limit  the state never arrives; polling must stop and offer a retry
local TestLib = require("./testlib")
local Env = require("./ClientEnv")
local check = TestLib.check

local scenario = ...
local realState = { phase = "waiting", roundId = 1, roster = {}, yourId = "u1", charLocked = false, grid = { "real" } }

local function lastHud()
    local log = Env.hudStates or {}
    return log[#log]
end
local function getSync()
    return Env.remotes.GetSync
end

if scenario == "empty" then
    Env.syncResponse = nil
else
    Env.syncResponse = { phase = "loading" }
end
require("./Main")

check("loading screen is shown first", lastHud() ~= nil and lastHud().phase == "loading", lastHud() and lastHud().phase)
check("input is off while loading", Env.inputEnabled == false)
check("a poll loop is waiting", #Env.threads == 1 and coroutine.status(Env.threads[1]) == "suspended")

if scenario == "event" then
    -- The server seats the player and pushes the room state.
    Env.remotes.RoundState.handler(realState)
    check("the real state replaces the loading screen", lastHud().phase == "waiting", lastHud().phase)
    check("the board grid is applied", Env.lastGrid == realState.grid)

    -- A late loading answer must not bring the loading screen back.
    local shown = #Env.hudStates
    Env.remotes.RoundState.handler({ phase = "loading" })
    check("a stale placeholder is ignored", lastHud().phase == "waiting" and #Env.hudStates == shown)

    -- The poll loop notices and stops asking.
    local before = getSync().invokes
    Env.advanceTasks()
    check("the poll loop stops once a real state exists", coroutine.status(Env.threads[1]) == "dead")
    check("it did not ask the server again", getSync().invokes == before, getSync().invokes - before)

elseif scenario == "poll" then
    check("startup asked once", getSync().invokes == 1, getSync().invokes)

    -- Still loading: the next poll gets the placeholder again and nothing changes.
    Env.advanceTasks()
    check("still loading after one poll", lastHud().phase == "loading")
    check("it asked again", getSync().invokes == 2, getSync().invokes)

    -- The event was missed, but the next poll returns the real state.
    Env.syncResponse = realState
    Env.advanceTasks()
    check("the poll picked up the real state", lastHud().phase == "waiting", lastHud().phase)
    check("the grid arrived with it", Env.lastGrid == realState.grid)
    Env.advanceTasks()
    check("the poll loop ended", coroutine.status(Env.threads[1]) == "dead")

elseif scenario == "empty" then
    check("an empty answer still shows the loading screen", lastHud().phase == "loading")
    Env.syncResponse = realState
    Env.advanceTasks()
    check("the next poll finds the state", lastHud().phase == "waiting", lastHud().phase)

elseif scenario == "limit" then
    -- Never answered: polling is bounded and the loop ends instead of running forever.
    local rounds = 0
    while coroutine.status(Env.threads[1]) == "suspended" and rounds < 200 do
        Env.advanceTasks()
        rounds += 1
    end
    check("the poll loop gives up", coroutine.status(Env.threads[1]) == "dead")
    check("at most 60 polls after the first request", getSync().invokes <= 61, getSync().invokes)
    check("it did poll many times first", getSync().invokes >= 30, getSync().invokes)
    check("the loading screen is still up", lastHud().phase == "loading")
    check("the failure state replaces the loading text", Env.loadingTimedOut == true)

    -- The failure state offers a retry, which starts a fresh bounded poll.
    local beforeRetry = getSync().invokes
    local threadsBefore = #Env.threads
    Env.syncResponse = realState
    Env.signals.loadingRetryPressed()
    check("retry clears the failure state", Env.loadingTimedOut == false)
    check("retry starts a new poll loop", #Env.threads == threadsBefore + 1, #Env.threads)
    Env.advanceTasks()
    check("the retried poll found the real state", lastHud().phase == "waiting", lastHud().phase)
    check("the retried poll asked the server", getSync().invokes == beforeRetry + 1, getSync().invokes - beforeRetry)
    Env.advanceTasks()
    check("the retried poll loop ends", coroutine.status(Env.threads[#Env.threads]) == "dead")

else
    error("unknown scenario: " .. tostring(scenario))
end

TestLib.finish()
