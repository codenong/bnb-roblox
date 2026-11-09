-- src/shared/Constants.luau
-- Shared constants. Logic coordinates are the original BnB pixel grid (T=40),
-- not Roblox studs. The client maps these pixels to the ScreenGui board.

local Characters = require(script.Parent.Characters)

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
    TEAM_COLORS = Characters.COLOR_KEYS,
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
    WAITING_SECONDS = 10,
    RESULTS_SECONDS = 4,
    WAITING_TICKS = 10 * 30,
    RESULTS_TICKS = 4 * 30,
    -- Character selection locks for the last N seconds of the waiting countdown.
    CHAR_LOCK_SECONDS = 3,
    CHAR_LOCK_TICKS = 3 * 30,

    -- Versus tables are precreated and retained for the server's lifetime; this
    -- caps how many can exist at once. Spectators are capped per table so a
    -- popular match cannot turn into an unbounded snapshot fan-out.
    VERSUS_PLAYERS = 2,
    VERSUS_TABLES = 4,
    VERSUS_SPECTATORS = 4,
    -- Room-name/password rules. Names are measured in Unicode codepoints and are
    -- filtered by the server before they are stored. At least five codepoints
    -- must be genuinely visible, so whitespace/format padding cannot make a
    -- room name look blank in the browser.
    ROOM_NAME_MIN_VISIBLE_CODEPOINTS = 5,
    ROOM_NAME_MAX_CODEPOINTS = 30,
    ROOM_PASSWORD_MIN_DIGITS = 4,
    ROOM_PASSWORD_MAX_DIGITS = 6,
    -- Fixed-window abuse guards, per player. Nothing clears a window early, a
    -- correct password included: otherwise a second account holding a known
    -- password could hand the failure budget back and brute-force another table.
    PASSWORD_ATTEMPT_MAX = 5,
    PASSWORD_ATTEMPT_WINDOW_SECONDS = 30,
    ROOM_CONFIG_ATTEMPT_MAX = 5,
    -- Character/color picks: generous for real clicking (a full lap of the six
    -- colors fits), tight enough that spamming cannot flood a room.
    SELECT_ATTEMPT_MAX = 8,
    SELECT_ATTEMPT_WINDOW_SECONDS = 2,
    ROOM_CONFIG_WINDOW_SECONDS = 10,
    NOTICE_SECONDS = 3.5,
    -- A game must last this long to count toward versus stats. A round that ends
    -- because a participant left is still a loss/win (quitting must not dodge it).
    VERSUS_MIN_SECONDS = 15,
    VERSUS_MIN_TICKS = 15 * 30,
    -- No valid input or action for this long after the warmup forfeits the round
    -- (and the round never counts toward stats).
    VERSUS_NO_ACTION_SECONDS = 20,
    VERSUS_NO_ACTION_TICKS = 20 * 30,

    -- Rendering
    BOARD_WIDTH = 15 * 40,
    BOARD_HEIGHT = 13 * 40,
    VISUAL_DY = 5,
}

return table.freeze(Constants)
