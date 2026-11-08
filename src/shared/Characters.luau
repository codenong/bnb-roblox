-- src/shared/Characters.luau
-- Same stats as BnB/server/characters.js.

local Characters = {}

Characters.CHARACTERS = {
    {
        id = "baobao",
        name = "宝宝",
        desc = "速度",
        speed = 144,
        range = 1,
        bombs = 1,
        caps = { speed = 240, range = 7, bombs = 6 },
        defaultColor = "red",
    },
    {
        id = "haidao",
        name = "小海盗",
        desc = "爆破",
        speed = 120,
        range = 2,
        bombs = 1,
        caps = { speed = 216, range = 7, bombs = 8 },
        defaultColor = "blue",
    },
}

Characters.DEFAULT_CHAR = "baobao"

-- One ordered palette shared by the game engine, sprites and the HUD. Colors are
-- stored by key, not by index, so reordering this list cannot recolor old saves.
Characters.COLOR_KEYS = table.freeze({ "red", "blue", "green", "yellow", "purple", "orange" })
Characters.COLOR_COUNT = #Characters.COLOR_KEYS

local COLOR_SET = {}
for _, key in ipairs(Characters.COLOR_KEYS) do
    COLOR_SET[key] = true
end

function Characters.getChar(id: string?)
    for _, character in ipairs(Characters.CHARACTERS) do
        if character.id == id then
            return character
        end
    end
    return Characters.CHARACTERS[1]
end

function Characters.isValidChar(id: string): boolean
    for _, character in ipairs(Characters.CHARACTERS) do
        if character.id == id then
            return true
        end
    end
    return false
end

function Characters.isValidColor(key: any): boolean
    return type(key) == "string" and COLOR_SET[key] == true
end

-- 0-based index, matching Game/Sprites. Unknown keys return nil.
function Characters.colorIndex(key: any): number?
    if not Characters.isValidColor(key) then
        return nil
    end
    for index, candidate in ipairs(Characters.COLOR_KEYS) do
        if candidate == key then
            return index - 1
        end
    end
    return nil
end

-- 0-based index; wraps safely for callers that only have an index.
function Characters.colorKey(index: any): string
    if type(index) ~= "number" or index ~= index or index == math.huge or index == -math.huge then
        return Characters.COLOR_KEYS[1]
    end
    local slot = math.floor(index) % Characters.COLOR_COUNT
    return Characters.COLOR_KEYS[slot + 1]
end

function Characters.defaultColor(charId: any): string
    local character = Characters.getChar(if type(charId) == "string" then charId else nil)
    return character.defaultColor or Characters.COLOR_KEYS[1]
end

-- Fresh map every time; callers may own and mutate it without touching another
-- profile or record.
function Characters.defaultColors(): { [string]: string }
    local result = {}
    for _, character in ipairs(Characters.CHARACTERS) do
        result[character.id] = character.defaultColor
    end
    return result
end

-- Copies the input (never mutates it), repairs missing/invalid values for known
-- characters and keeps unknown keys for forward compatibility.
function Characters.normalizeColors(value: any): { [string]: string }
    local result = {}
    if type(value) == "table" then
        for key, color in pairs(value) do
            result[key] = color
        end
    end
    for _, character in ipairs(Characters.CHARACTERS) do
        if not Characters.isValidColor(result[character.id]) then
            result[character.id] = character.defaultColor
        end
    end
    return result
end

function Characters.colorOf(charColors: any, charId: any): string
    if type(charColors) == "table" then
        local color = charColors[charId]
        if Characters.isValidColor(color) then
            return color
        end
    end
    return Characters.defaultColor(charId)
end

-- Clamp a network/save-supplied index into the palette. Invalid values use the
-- caller's fallback (normally the seat index), so a malformed def cannot create
-- an out-of-range sprite key.
function Characters.sanitizeColorIndex(value: any, fallback: any): number
    local fallbackIndex = 0
    if type(fallback) == "number"
        and fallback == fallback
        and fallback ~= math.huge
        and fallback ~= -math.huge
    then
        fallbackIndex = math.floor(fallback) % Characters.COLOR_COUNT
    end
    if type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
    then
        return fallbackIndex
    end
    local index = math.floor(value)
    if index < 0 or index >= Characters.COLOR_COUNT then
        return fallbackIndex
    end
    return index
end

return table.freeze(Characters)
