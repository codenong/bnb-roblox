-- Bots are deliberately inert in the match-flow test; this verifies the
-- waiting/playing/ended/next-round state machine, not Bot AI.
local BotService = {}

function BotService.build(_game)
    return {}
end

function BotService.act(_game, _entries) end

return BotService
