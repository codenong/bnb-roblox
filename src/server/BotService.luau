-- src/server/BotService.luau
-- Owns BotBrain instances for one round. Bots are not Roblox Players; they
-- exist only inside the authoritative Game and in the roster sent to clients.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bot = require(Shared:WaitForChild("Bot"))

local BotService = {}

function BotService.build(game)
    local entries = {}
    for _, player in ipairs(game.playerOrder) do
        if player.isBot then
            table.insert(entries, {
                id = player.id,
                brain = Bot.new(player.id),
            })
        end
    end
    return entries
end

function BotService.act(game, entries)
    for _, entry in ipairs(entries) do
        local player = game.players[entry.id]
        if player and player.alive and not player.disconnected then
            local ok, decision = pcall(entry.brain.decide, entry.brain, game)
            if ok and decision then
                game:setInput(entry.id, decision.dirs or {})
                if decision.place then
                    game:placeBomb(entry.id, false)
                end
                if decision.use then
                    game:useItem(entry.id)
                end
            else
                game:setInput(entry.id, {})
                if not ok then
                    warn("[BnB] bot decision failed: " .. tostring(decision))
                end
            end
        end
    end
end

return table.freeze(BotService)
