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

---------------------------------------------------------------- 付费道具收据

do
    local profile = ProfileSchema.newProfile()
    check("a new profile has no receipts", profile.receipts ~= nil and next(profile.receipts) == nil)
    check("an unknown receipt is not consumed", not ProfileSchema.hasReceipt(profile, "p1"))

    local badProfile, badReason = ProfileSchema.grantPurchase({}, "p1", "needle", 1)
    check("a malformed profile refuses a grant", badProfile == false and badReason == "invalid_profile", badReason)
    check("an empty receipt id is rejected", ProfileSchema.grantPurchase(profile, "", "needle", 1) == false)
    check("a non-string receipt id is rejected", ProfileSchema.grantPurchase(profile, 42, "needle", 1) == false)
    check("an unknown item is rejected", ProfileSchema.grantPurchase(profile, "p2", "mount", 1) == false)
    check("a zero amount is rejected", ProfileSchema.grantPurchase(profile, "p3", "needle", 0) == false)
    check("a fractional amount is rejected", ProfileSchema.grantPurchase(profile, "p4", "needle", 1.5) == false)
    check("a NaN amount is rejected", ProfileSchema.grantPurchase(profile, "p5", "needle", 0 / 0) == false)
    check("a rejected grant leaves no receipt", not ProfileSchema.hasReceipt(profile, "p4"))
    check("a rejected grant leaves stock alone", ProfileSchema.totalStock(profile, "needle") == 0)

    local granted, grantReason = ProfileSchema.grantPurchase(profile, "receipt-1", "needle", 2)
    check("a valid grant succeeds", granted == true, grantReason)
    check("a valid grant adds purchased stock",
        profile.inventory.needle.purchased == 2, profile.inventory.needle.purchased)
    check("a valid grant records the receipt", ProfileSchema.hasReceipt(profile, "receipt-1"))

    local duplicate, duplicateReason = ProfileSchema.grantPurchase(profile, "receipt-1", "needle", 5)
    check("a duplicate receipt is not granted", duplicate == false and duplicateReason == "duplicate", duplicateReason)
    check("a duplicate receipt does not add stock",
        profile.inventory.needle.purchased == 2, profile.inventory.needle.purchased)

    local rollback = ProfileSchema.newProfile()
    rollback.inventory.needle = nil
    local ok, reason = ProfileSchema.grantPurchase(rollback, "receipt-2", "needle", 1)
    check("an unusable inventory fails cleanly", ok == false and reason == "invalid_item", reason)
    check("a failed inventory grant rolls back its receipt",
        not ProfileSchema.hasReceipt(rollback, "receipt-2"))

    local normalized = ProfileSchema.normalize({ receipts = { ["old"] = true } })
    check("receipts survive normalization", ProfileSchema.hasReceipt(normalized, "old"))
end

---------------------------------------------------------------- 装备意向的持久化

do
    local profile = ProfileSchema.newProfile()
    profile.inventory.needle.free = 2
    profile.inventory.remote.purchased = 1
    check("loadout defaults to empty", profile.loadout.needle == 0
        and profile.loadout.remote == 0
        and profile.loadout.kick == 0)

    local saved = ProfileSchema.normalize({
        loadout = { needle = 99, remote = 1.5, kick = -2, extra = "kept" },
    })
    check("saved loadout is capped", saved.loadout.needle == 2, saved.loadout.needle)
    check("saved loadout floors", saved.loadout.remote == 1, saved.loadout.remote)
    check("saved loadout clamps negatives", saved.loadout.kick == 0, saved.loadout.kick)
    check("unknown loadout fields are preserved", saved.loadout.extra == "kept")

    -- Loadout intent is independent from current stock: normalization must not
    -- erase a preference just because the player owns nothing right now.
    local empty = ProfileSchema.normalize({ loadout = { needle = 2 }, inventory = {} })
    check("loadout survives an empty inventory", empty.loadout.needle == 2, empty.loadout.needle)
end

TestLib.finish()
