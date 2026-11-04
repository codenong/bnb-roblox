-- src/shared/Mounts.luau
-- Same mount stats as BnB/server/mounts.js.

local Mounts = {}

Mounts.MOUNTS = {
    turtle = { id = "turtle", name = "绿乌龟", speed = 84, fly = false },
    owl = { id = "owl", name = "猫头鹰", speed = 156, fly = false },
    pirateTurtle = { id = "pirateTurtle", name = "海盗龟", speed = 204, fly = false },
    ufo = { id = "ufo", name = "飞碟", speed = 180, fly = true },
}

return table.freeze(Mounts)
