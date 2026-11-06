-- src/server/VersusStats.luau
-- Pure versus-statistics rules. Room decides what happened; this module decides
-- whether the game is rated and what each participant earned. It never touches
-- Roblox services, DataStores or the room state machine.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local ProfileSchema = require(Shared:WaitForChild("ProfileSchema"))

local VersusStats = {}

local function countParticipants(participants)
    local count = 0
    for _ in pairs(participants) do
        count += 1
    end
    return count
end

-- context = {
--   mode = "versus",
--   participants = { record, record } (includes participants that left),
--   activity = { [id] = true if they ever sent input/action },
--   left = { [id] = true if they left mid-round },
--   durationTicks = number of simulation ticks after warmup,
-- }
function VersusStats.apply(context, result)
    context = context or {}
    result = result or {}
    local participants = context.participants or {}
    local summary = {
        rated = false,
        reason = "not_versus",
        outcomes = {},
    }

    if context.mode ~= "versus" then
        return summary
    end
    if countParticipants(participants) ~= Constants.VERSUS_PLAYERS then
        summary.reason = "participants"
        return summary
    end

    local anyLeft = false
    local seenIds = {}
    for _, record in pairs(participants) do
        if type(record) ~= "table" or type(record.id) ~= "string" or type(record.profile) ~= "table" then
            summary.reason = "missing_profile"
            return summary
        end
        if seenIds[record.id] then
            summary.reason = "participants"
            return summary
        end
        seenIds[record.id] = true
        if context.left and context.left[record.id] then
            anyLeft = true
        end
        if not context.activity or context.activity[record.id] ~= true then
            summary.reason = "no_action"
            return summary
        end
    end

    -- Playing a short round normally does not count. Quitting is different: it
    -- must not let the leaver dodge the loss just because the game was short.
    local durationTicks = tonumber(context.durationTicks) or 0
    if durationTicks < Constants.VERSUS_MIN_TICKS and not anyLeft then
        summary.reason = "short_game"
        return summary
    end

    local draw = result.draw == true
    local winnerId = result.winnerId
    if draw and anyLeft then
        -- A leaver always produces a win for the player who stayed. A result
        -- claiming both a draw and an exit is inconsistent and must not rate.
        summary.reason = "invalid_result"
        return summary
    end
    if not draw then
        local found = false
        for _, record in pairs(participants) do
            if record.id == winnerId then
                found = true
                break
            end
        end
        if not found or (context.left and context.left[winnerId]) then
            summary.reason = "invalid_result"
            return summary
        end
    end

    for _, record in pairs(participants) do
        local outcome
        if context.left and context.left[record.id] then
            outcome = "loss"
        elseif draw then
            outcome = "draw"
        elseif result.winnerId == record.id then
            outcome = "win"
        else
            outcome = "loss"
        end
        summary.outcomes[record.id] = outcome
    end

    -- Apply only after every participant has been validated so a malformed
    -- context can never update one profile and skip the other.
    for _, record in pairs(participants) do
        if not ProfileSchema.recordVersus(record.profile, summary.outcomes[record.id]) then
            summary.reason = "invalid_profile"
            summary.outcomes = {}
            return summary
        end
    end

    summary.rated = true
    summary.reason = "rated"
    return summary
end

return table.freeze(VersusStats)
