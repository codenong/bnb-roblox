-- src/client/Audio.luau
-- Sound effects and background music. Empty AssetIds mean silent fallback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AssetIds = require(Shared:WaitForChild("AssetIds"))

local Audio = {}

local group
local bgm
local sounds = {}
local muted = false
local ready = false
local lastExplodeAt = 0

local SFX = {
    bomb_set = { key = "sfx_bomb_set", volume = 0.55 },
    explode = { key = "sfx_explode", volume = 0.6 },
    get = { key = "sfx_get", volume = 0.45 },
    save = { key = "sfx_save", volume = 0.5 },
    role_die = { key = "sfx_role_die", volume = 0.55 },
    start = { key = "sfx_start", volume = 0.6 },
    victory = { key = "sfx_victory", volume = 0.6 },
    lose = { key = "sfx_lose", volume = 0.55 },
    draw = { key = "sfx_draw", volume = 0.5 },
}

local function createSound(name, id, volume, looped)
    local sound = Instance.new("Sound")
    sound.Name = name
    sound.SoundId = id
    sound.Volume = volume
    sound.Looped = looped == true
    sound.SoundGroup = group
    sound.Parent = SoundService
    return sound
end

function Audio.init()
    if ready then
        return
    end
    ready = true

    group = Instance.new("SoundGroup")
    group.Name = "BnB_Audio"
    group.Volume = 1
    group.Parent = SoundService

    for name, def in pairs(SFX) do
        local id = AssetIds[def.key] or ""
        if id ~= "" then
            sounds[name] = createSound("SFX_" .. name, id, def.volume, false)
        end
    end

    local bgmId = AssetIds.bgm_game or ""
    if bgmId ~= "" then
        bgm = createSound("BGM_Game", bgmId, 0.3, true)
        bgm:Play()
    end
end

function Audio.play(name)
    if muted then
        return
    end
    local sound = sounds[name]
    if not sound then
        return
    end
    if name == "explode" then
        local now = os.clock()
        if now - lastExplodeAt < 0.06 then
            return
        end
        lastExplodeAt = now
    end
    sound.TimePosition = 0
    sound:Play()
end

function Audio.onFx(event)
    if type(event) ~= "table" or type(event.kind) ~= "string" then
        return
    end
    local kind = event.kind
    if kind == "bomb_set" or kind == "explode" or kind == "get"
        or kind == "save" or kind == "role_die" or kind == "start" then
        Audio.play(kind)
    end
end

function Audio.playResult(result, yourId)
    if type(result) ~= "table" then
        return
    end
    if result.draw then
        Audio.play("draw")
    elseif result.winnerId and yourId and result.winnerId == yourId then
        Audio.play("victory")
    elseif yourId then
        Audio.play("lose")
    end
end

function Audio.setMuted(value)
    muted = value == true
    if group then
        group.Volume = if muted then 0 else 1
    end
end

function Audio.isMuted(): boolean
    return muted
end

function Audio.toggleMuted(): boolean
    Audio.setMuted(not muted)
    return muted
end

return Audio
