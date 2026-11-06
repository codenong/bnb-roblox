-- tests/profile/profile_schema_test.luau
local TestLib = require("./testlib")
local check = TestLib.check

local ProfileSchema = require("./ProfileSchema")

---------------------------------------------------------------- 默认档案

do
    local profile = ProfileSchema.newProfile()
    check("default currency", profile.currency == 0, profile.currency)
    check("default character", profile.settings.char == "baobao", profile.settings.char)
    check("default free stock is zero", profile.inventory.needle.free == 0)
    check("default purchased stock is zero", profile.inventory.needle.purchased == 0)
    check("default needle progress", profile.freeNeedle.progress == 2, profile.freeNeedle.progress)
    check("default versus stats", profile.stats.versus.games == 0)
    check("default loadout", profile.loadout.needle == 0)

    profile.inventory.needle.free = 99
    profile.settings.char = "haidao"
    local second = ProfileSchema.newProfile()
    check("newProfile does not share inventory", second.inventory.needle.free == 0)
    check("newProfile does not share settings", second.settings.char == "baobao")
end

---------------------------------------------------------------- 免费 / 购买分开

do
    local profile = ProfileSchema.newProfile()
    check("add free", ProfileSchema.addStock(profile, "needle", "free", 2) == true)
    check("add purchased", ProfileSchema.addStock(profile, "remote", "purchased", 3) == true)
    check("free bucket", profile.inventory.needle.free == 2)
    check("purchased bucket", profile.inventory.needle.purchased == 0)
    check("other item untouched", profile.inventory.remote.free == 0)
    check("other item purchased", profile.inventory.remote.purchased == 3)
    check("total stock", ProfileSchema.totalStock(profile, "needle") == 2)

    check("reject unknown item", ProfileSchema.addStock(profile, "nope", "free", 1) == false)
    check("reject unknown bucket", ProfileSchema.addStock(profile, "needle", "other", 1) == false)
    check("reject negative add", ProfileSchema.addStock(profile, "needle", "free", -1) == false)
    check("reject non-number add", ProfileSchema.addStock(profile, "needle", "free", "x") == false)
end

---------------------------------------------------------------- 消耗：先免费后购买，不足时整体不变

do
    local profile = ProfileSchema.newProfile()
    profile.inventory.needle.free = 2
    profile.inventory.needle.purchased = 3

    local ok, taken = ProfileSchema.consumeStock(profile, "needle", 4)
    check("consume succeeds", ok == true)
    check("takes free first", taken and taken.free == 2, taken and taken.free)
    check("then purchased", taken and taken.purchased == 2, taken and taken.purchased)
    check("free bucket reduced", profile.inventory.needle.free == 0)
    check("purchased bucket reduced", profile.inventory.needle.purchased == 1)
    check("total conserved", ProfileSchema.totalStock(profile, "needle") == 1)

    profile.inventory.needle.free = 1
    profile.inventory.needle.purchased = 1
    local beforeFree, beforePurchased = profile.inventory.needle.free, profile.inventory.needle.purchased
    local insufficient, none = ProfileSchema.consumeStock(profile, "needle", 3)
    check("insufficient fails", insufficient == false)
    check("insufficient returns no take", none == nil)
    check("insufficient leaves free untouched", profile.inventory.needle.free == beforeFree)
    check("insufficient leaves purchased untouched", profile.inventory.needle.purchased == beforePurchased)

    local zeroOk, zero = ProfileSchema.consumeStock(profile, "needle", 0)
    check("zero consume succeeds", zeroOk == true)
    check("zero takes nothing", zero and zero.free == 0 and zero.purchased == 0)
    check("invalid consume fails", ProfileSchema.consumeStock(profile, "nope", 1) == false)
end

---------------------------------------------------------------- 迁移 / 归一化

do
    local input = ProfileSchema.newProfile()
    input.currency = -5
    input.inventory.needle.free = "bad"
    input.inventory.needle.purchased = -3
    input.inventory.extra = { note = "kept" }
    input.loadout.needle = -9
    input.stats.versus.games = -2
    input.freeNeedle.progress = 99
    input.freeNeedle.day = 123
    input.settings.char = 123
    input.unknownTopLevel = { keep = true }

    local normalized = ProfileSchema.normalize(input)
    check("negative currency clamps", normalized.currency == 0, normalized.currency)
    check("non-number free clamps", normalized.inventory.needle.free == 0, normalized.inventory.needle.free)
    check("negative purchased clamps", normalized.inventory.needle.purchased == 0)
    check("unknown inventory entry kept", normalized.inventory.extra.note == "kept")
    check("negative loadout clamps", normalized.loadout.needle == 0)
    check("negative stats clamp", normalized.stats.versus.games == 0)
    check("progress clamps to the goal", normalized.freeNeedle.progress == ProfileSchema.FREE_NEEDLE_GOAL)
    check("non-string day becomes empty", normalized.freeNeedle.day == "")
    check("invalid character falls back", normalized.settings.char == "baobao")
    check("unknown top-level field kept", normalized.unknownTopLevel.keep == true)

    check("normalize does not mutate currency", input.currency == -5, input.currency)
    check("normalize does not mutate char", input.settings.char == 123, input.settings.char)
    check("normalize does not mutate unknown input", input.unknownTopLevel.keep == true)

    local valid = ProfileSchema.newProfile()
    valid.settings.char = "haidao"
    check("valid character is preserved", ProfileSchema.normalize(valid).settings.char == "haidao")
end

---------------------------------------------------------------- 免费针规则常量（与 detail.md 定稿一致）

do
    check("goal: 5 valid games per free needle", ProfileSchema.FREE_NEEDLE_GOAL == 5)
    check("new players start at 2/5", ProfileSchema.FREE_NEEDLE_START_PROGRESS == 2)
    check("daily cap is 3", ProfileSchema.FREE_NEEDLE_DAILY_CAP == 3)
    check("stock cap is 4", ProfileSchema.FREE_NEEDLE_STOCK_CAP == 4)

    check("start progress is below the goal", ProfileSchema.FREE_NEEDLE_START_PROGRESS < ProfileSchema.FREE_NEEDLE_GOAL)
    check("a day's earnings fit in the stock cap", ProfileSchema.FREE_NEEDLE_DAILY_CAP <= ProfileSchema.FREE_NEEDLE_STOCK_CAP)
    check("old ambiguous names are gone", ProfileSchema.FREE_NEEDLE_MAX == nil and ProfileSchema.FREE_NEEDLE_DAILY == nil)

    local fresh = ProfileSchema.newProfile()
    check("new profile starts at the start progress", fresh.freeNeedle.progress == ProfileSchema.FREE_NEEDLE_START_PROGRESS)
    local missing = ProfileSchema.normalize({ freeNeedle = { progress = "bad" } })
    check("invalid progress falls back to the start progress", missing.freeNeedle.progress == ProfileSchema.FREE_NEEDLE_START_PROGRESS, missing.freeNeedle.progress)
    local zero = ProfileSchema.normalize({ freeNeedle = { progress = 0 } })
    check("an explicit 0 is kept", zero.freeNeedle.progress == 0, zero.freeNeedle.progress)
end

TestLib.finish()
