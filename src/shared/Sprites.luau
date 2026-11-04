-- src/shared/Sprites.luau
-- Frame metadata for prepared BnB sheets. AssetIds holds the actual IDs; the
-- renderer falls back to shapes/colors whenever an ID is empty.
--
-- All prepared image sizes are <=1024 so Roblox does not resample them and
-- ImageRectOffset slicing stays pixel-exact.

local Sprites = {}

Sprites.TEAM_KEYS = { "red", "blue", "green", "yellow", "purple", "orange" }

Sprites.SHEETS = {
    floor_checker = { assetKey = "img_floor_checker", width = 320, height = 320, cols = 1, rows = 1 },
    box = { assetKey = "img_box", width = 160, height = 192 },
    crate = { assetKey = "img_crate", width = 160, height = 192 },
    cannon = { assetKey = "img_cannon", width = 160, height = 320 },
    mast = { assetKey = "img_mast", width = 800, height = 960 },
    explosion = {
        assetKey = "img_explosion",
        width = 980,
        height = 350,
        cols = 14,
        rows = 5,
        frameWidth = 70,
        frameHeight = 70,
    },
    big_popo = {
        assetKey = "img_big_popo",
        width = 972,
        height = 108,
        cols = 9,
        rows = 1,
        frameWidth = 108,
        frameHeight = 108,
    },
    role1_die = {
        assetKey = "img_role1_die",
        width = 792,
        height = 150,
        cols = 11,
        rows = 1,
        frameWidth = 72,
        frameHeight = 150,
    },
    role2_die = {
        assetKey = "img_role2_die",
        width = 924,
        height = 147,
        cols = 11,
        rows = 1,
        frameWidth = 84,
        frameHeight = 147,
    },
    num_strip = {
        assetKey = "img_num_strip",
        width = 480,
        height = 40,
        cols = 10,
        rows = 1,
        frameWidth = 48,
        frameHeight = 40,
    },
    win = { assetKey = "img_win", width = 816, height = 280 },
    draw = { assetKey = "img_draw", width = 816, height = 272 },
    lose = { assetKey = "img_lose", width = 816, height = 280 },
    shadow_gift = { assetKey = "img_shadow_gift", width = 36, height = 9 },
    shadow_role = { assetKey = "img_shadow_role", width = 32, height = 15 },
}

-- Rows are direction: 1 up, 2 down, 3 left, 4 right. Columns are walk frames.
Sprites.ANIM = {
    baobao = {
        frameWidth = 96,
        frameHeight = 128,
        cols = 6,
        rows = 4,
        drawHeight = 52, -- 1.3 tiles at T=40
    },
    haidao = {
        frameWidth = 112,
        frameHeight = 134,
        cols = 6,
        rows = 4,
        drawHeight = 53.6,
    },
}

Sprites.DIE = {
    baobao = {
        assetKey = "img_role1_die",
        frameWidth = 72,
        frameHeight = 150,
        frames = 11,
    },
    haidao = {
        assetKey = "img_role2_die",
        frameWidth = 84,
        frameHeight = 147,
        frames = 11,
    },
}

-- Ground-item icons. `displayWidth` matches BnB's canvas draw width at T=40.
Sprites.ITEMS = {
    potion = { assetKey = "img_gift3", frameWidth = 168, frameHeight = 180, frames = 3, displayWidth = 26 },
    bubble = { assetKey = "img_gift1", frameWidth = 168, frameHeight = 180, frames = 3, displayWidth = 26 },
    shoe = { assetKey = "img_gift2", frameWidth = 168, frameHeight = 180, frames = 3, displayWidth = 28 },
    gremlin = { assetKey = "img_item_gremlin", frameWidth = 168, frameHeight = 180, frames = 1, displayWidth = 28 },
    devil = { assetKey = "img_item_devil", frameWidth = 168, frameHeight = 180, frames = 1, displayWidth = 28 },
    turtle = { assetKey = "img_gift8", frameWidth = 144, frameHeight = 164, frames = 3, displayWidth = 34 },
    owl = { assetKey = "img_gift7", frameWidth = 144, frameHeight = 152, frames = 3, displayWidth = 34 },
    ufo = { assetKey = "img_gift9", frameWidth = 160, frameHeight = 164, frames = 3, displayWidth = 34 },
    pirateTurtle = {
        assetKey = "img_item_pirate_turtle",
        frameWidth = 144,
        frameHeight = 164,
        frames = 3,
        displayWidth = 34,
    },
    needle = { assetKey = "img_item_needle", frameWidth = 112, frameHeight = 116, frames = 1, displayWidth = 24 },
    remote = { assetKey = "img_item_remote", frameWidth = 136, frameHeight = 140, frames = 1, displayWidth = 26 },
    kick = { assetKey = "img_gift6", frameWidth = 168, frameHeight = 184, frames = 3, displayWidth = 28 },
}

Sprites.ITEM_ORDER = {
    "bubble",
    "potion",
    "shoe",
    "gremlin",
    "devil",
    "kick",
    "needle",
    "remote",
}

Sprites.ITEM_NAMES = {
    bubble = "水泡",
    potion = "威力",
    shoe = "鞋子",
    gremlin = "紫魔",
    devil = "红魔",
    kick = "踢泡",
    needle = "针",
    remote = "遥控",
    turtle = "乌龟",
    owl = "猫头鹰",
    pirateTurtle = "海盗龟",
    ufo = "飞碟",
}

-- Mount sheets: 2 columns x 4 rows; rows are directions in the same order as
-- ANIM. displayWidth/displayHeight match the original canvas draw size.
Sprites.MOUNTS = {
    turtle = {
        assetKey = "img_mount_turtle",
        frameWidth = 192,
        frameHeight = 128,
        cols = 2,
        rows = 4,
        displayWidth = 48,
        displayHeight = 32,
    },
    pirateTurtle = {
        assetKey = "img_mount_pirate_turtle",
        frameWidth = 192,
        frameHeight = 128,
        cols = 2,
        rows = 4,
        displayWidth = 48,
        displayHeight = 32,
    },
    owl = {
        assetKey = "img_mount_owl",
        frameWidth = 160,
        frameHeight = 160,
        cols = 2,
        rows = 4,
        displayWidth = 40,
        displayHeight = 40,
    },
    ufo = {
        assetKey = "img_mount_ufo",
        frameWidth = 208,
        frameHeight = 124,
        cols = 2,
        rows = 4,
        displayWidth = 52,
        displayHeight = 31,
    },
}

Sprites.POPO = {
    blue = { assetKeys = { "img_popo_b0", "img_popo_b1", "img_popo_b2" }, frames = 3 },
    remote = { assetKeys = { "img_popo_r0", "img_popo_r1", "img_popo_r2" }, frames = 3 },
}

-- colorIndex is 0-based (Game assigns i-1), matching BnB teamColors.
function Sprites.teamKey(colorIndex: number): string
    return Sprites.TEAM_KEYS[(colorIndex % #Sprites.TEAM_KEYS) + 1]
end

function Sprites.animKey(char: string, colorIndex: number): string
    return "img_anim_" .. char .. "_" .. Sprites.teamKey(colorIndex)
end

function Sprites.portraitKey(char: string, colorIndex: number): string
    return "img_chars_" .. char .. "_" .. Sprites.teamKey(colorIndex)
end

return Sprites
