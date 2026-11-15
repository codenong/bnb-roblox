-- src/shared/Constants.luau
-- Shared constants. Logic coordinates are the original BnB pixel grid (T=40),
-- not Roblox studs. The client maps these pixels to the ScreenGui board.

local Characters = require(script.Parent.Characters)

-- The simulation runs at a fixed TICK_RATE (Hz) driven by the Heartbeat
-- accumulator on the server and mirrored by the client's command stream and
-- snapshot cadence. Every tick-denominated duration below is derived from
-- TICK_RATE, so all timers keep their real-world length if the rate changes
-- again; px-per-second speeds need no conversion at all.
local TICK_RATE = 60

local Constants = {
    -- Map / simulation
    TILE = 40,
    COLS = 15,
    ROWS = 13,
    TICK_RATE = TICK_RATE,
    DT = 1 / TICK_RATE,

    -- Timers in ticks, expressed as wall-time durations so they survive a
    -- tick-rate change (values at 60Hz: fuse 150, explosion 30, trap 240,
    -- round 10800, warmup 180).
    BOMB_FUSE_TICKS = math.round(2.5 * TICK_RATE), -- 2.5s
    REMOTE_FUSE = 9999,
    EXPLOSION_TICKS = math.round(0.5 * TICK_RATE), -- 0.5s
    TRAP_TICKS = math.round(4 * TICK_RATE), -- 4s
    ROUND_TICKS = math.round(180 * TICK_RATE), -- 3min
    WARMUP_TICKS = math.round(3 * TICK_RATE), -- 3s

    ITEM_DROP_RATE = 0.35,
    SHOE_STEP = 24,
    PUSH_TICKS = math.round(TICK_RATE / 3), -- 1/3s of holding before a crate moves
    SLIDE_TICKS = math.round(0.2 * TICK_RATE), -- crate slide duration
    KICK_SPEED = 360,
    DEATH_DROP_RATE = 0.3,
    LOOT_FLY_BASE = math.round(TICK_RATE / 6), -- loot flight: 1/6s ...
    LOOT_FLY_PER_TILE = math.round(TICK_RATE * 2 / 15), -- ... plus 2/15s per tile
    MAX_NEEDLE = 2,
    MAX_REMOTE = 2,
    -- Post-hit invulnerability on top of the explosion itself (was a literal
    -- "+ 10" ticks at 30Hz, i.e. 1/3s).
    EXTRA_GRACE_TICKS = math.round(TICK_RATE / 3),

    HALF = 13,
    -- Corner assist: how far off a lane centre a turn still gets slid into the
    -- lane. A 40px tile has a 20px half width and a lane's centre is at most 20px
    -- from the player, so this must stay below 20 or two neighbouring lanes
    -- would both qualify. 18 gives a turn window of 37px (≈155ms at 240px/s);
    -- it was 12 (25px, ≈104ms). Shared by Game and the client predictor.
    ASSIST_RANGE = 18,
    -- Release snap (Movement.step's idle glide): how far past the cell centre
    -- behind the player still counts as "not committed". A release with more
    -- progress than this completes the crossing to the next centre (so a tap
    -- walks exactly one cell), less walks back to the centre behind (so an
    -- accidental brush cancels out). One tick of full-speed movement keeps the
    -- tap wall-time semantics identical across tick rates (8px @ 30Hz, 4px @ 60Hz).
    -- Shared by Game and the client predictor.
    SNAP_COMMIT_PX = math.round(240 / TICK_RATE),

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
    SNAPSHOT_RATE = TICK_RATE,
    -- Sequenced input commands are held for this many simulation ticks before
    -- being applied. The client predicts locally, so the added latency is hidden
    -- for movement; the buffer preserves the order/duration of direction changes
    -- instead of letting network jitter coalesce them into one "latest" state.
    -- 2 ticks at the original 30Hz ≈ 66ms; the wall time is what matters.
    INPUT_BUFFER_TICKS = math.round(2 / 30 * TICK_RATE),
    -- Hard cap on queued commands per player. A burst or a malicious client
    -- cannot grow the room's memory without bound; oldest commands are dropped
    -- first and the client reconciles from the authoritative snapshot.
    INPUT_QUEUE_LIMIT = 12,
    WAITING_SECONDS = 10,
    RESULTS_SECONDS = 4,
    WAITING_TICKS = 10 * TICK_RATE,
    RESULTS_TICKS = 4 * TICK_RATE,
    -- Character selection locks for the last N seconds of the waiting countdown.
    CHAR_LOCK_SECONDS = 3,
    CHAR_LOCK_TICKS = 3 * TICK_RATE,

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
    VERSUS_MIN_TICKS = 15 * TICK_RATE,
    -- No valid input or action for this long after the warmup forfeits the round
    -- (and the round never counts toward stats).
    VERSUS_NO_ACTION_SECONDS = 20,
    VERSUS_NO_ACTION_TICKS = 20 * TICK_RATE,

    -- Rendering
    BOARD_WIDTH = 15 * 40,
    BOARD_HEIGHT = 13 * 40,
    VISUAL_DY = 5,
}

return table.freeze(Constants)
