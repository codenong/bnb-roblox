-- src/shared/Constants.luau
-- Shared constants. Logic coordinates are the original BnB pixel grid (T=40),
-- not Roblox studs. The client maps these pixels to the ScreenGui board.

local Constants = {
    -- Map / simulation
    TILE = 40,
    COLS = 15,
    ROWS = 13,
    TICK_RATE = 30,
    DT = 1 / 30,

    BOMB_FUSE_TICKS = 75,
    REMOTE_FUSE = 9999,
    EXPLOSION_TICKS = 15,
    TRAP_TICKS = 120,
    ROUND_TICKS = 5400,
    WARMUP_TICKS = 90,

    ITEM_DROP_RATE = 0.35,
    SHOE_STEP = 24,
    PUSH_TICKS = 10,
    SLIDE_TICKS = 6,
    KICK_SPEED = 360,
    DEATH_DROP_RATE = 0.3,
    LOOT_FLY_BASE = 5,
    LOOT_FLY_PER_TILE = 4,
    MAX_NEEDLE = 2,
    MAX_REMOTE = 2,

    HALF = 13,
    ASSIST_RANGE = 12,

    DIRS4 = {
        { 1, 0 },
        { -1, 0 },
        { 0, 1 },
        { 0, -1 },
    },
    DIR_VEC = {
        right = { 1, 0 },
        left = { -1, 0 },
        down = { 0, 1 },
        up = { 0, -1 },
    },

    -- Teams (sprite variants / HUD colors)
    MAX_PLAYERS = 6,
    PRACTICE_PLAYERS = 2,
    TEAM_COLORS = { "red", "blue", "green", "yellow", "purple", "orange" },
    TEAM_HEX = {
        red = "#e23b3b",
        blue = "#2f7fe0",
        green = "#3fae4e",
        yellow = "#e0a92e",
        purple = "#9b59d0",
        orange = "#ef7a1a",
    },

    -- Match flow / networking
    SNAPSHOT_RATE = 20,
    WAITING_SECONDS = 4,
    RESULTS_SECONDS = 4,
    WAITING_TICKS = 4 * 30,
    RESULTS_TICKS = 4 * 30,

    -- Rendering
    BOARD_WIDTH = 15 * 40,
    BOARD_HEIGHT = 13 * 40,
    VISUAL_DY = 5,
}

return table.freeze(Constants)
