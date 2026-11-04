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
    },
    {
        id = "haidao",
        name = "小海盗",
        desc = "爆破",
        speed = 120,
        range = 2,
        bombs = 1,
        caps = { speed = 216, range = 7, bombs = 8 },
    },
}

Characters.DEFAULT_CHAR = "baobao"

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

return table.freeze(Characters)
