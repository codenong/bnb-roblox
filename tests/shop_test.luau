-- Pure shop rules: automatic versus carry, practice zero carry, inventory
-- summaries and free-first settlement. The legacy loadout field is still
-- normalized but must never influence what a round carries.
-- Loaded by tests/run.sh from tests/build.
local TestLib = require("./testlib")
local check = TestLib.check

local Shop = require("./Shop")
local ProfileSchema = require("./ProfileSchema")

local function profileWith(stock, loadout)
    local profile = ProfileSchema.normalize(ProfileSchema.newProfile())
    for itemId, buckets in pairs(stock or {}) do
        profile.inventory[itemId].free = buckets.free or 0
        profile.inventory[itemId].purchased = buckets.purchased or 0
    end
    for itemId, value in pairs(loadout or {}) do
        profile.loadout[itemId] = value
    end
    return profile
end

---------------------------------------------------------------- 目录与容量

check("three functional items", #Shop.ITEM_ORDER == 3, #Shop.ITEM_ORDER)
check("needle cap is 2", Shop.ITEMS.needle.cap == 2, Shop.ITEMS.needle.cap)
check("remote cap is 1", Shop.ITEMS.remote.cap == 1, Shop.ITEMS.remote.cap)
check("kick cap is 1", Shop.ITEMS.kick.cap == 1, Shop.ITEMS.kick.cap)
check("unknown item is rejected", Shop.isItemId("mount") == false)
check("non-string item is rejected", Shop.isItemId(1) == false)
check("a fresh loadout is empty", Shop.newLoadout().needle == 0
    and Shop.newLoadout().remote == 0
    and Shop.newLoadout().kick == 0)

---------------------------------------------------------------- 档案兼容：loadout 仍可归一化，但不参与携带

check("negative loadout clamps to zero", Shop.clampLoadoutValue("needle", -2) == 0)
check("fractional loadout floors", Shop.clampLoadoutValue("needle", 1.9) == 1)
check("loadout stops at the cap", Shop.clampLoadoutValue("needle", 9) == 2)
check("NaN loadout becomes zero", Shop.clampLoadoutValue("needle", 0 / 0) == 0)
check("infinite loadout becomes zero", Shop.clampLoadoutValue("needle", math.huge) == 0)
check("unknown item clamps to zero", Shop.clampLoadoutValue("mount", 2) == 0)

local unknown = Shop.normalizeLoadout({ needle = 7, extra = "kept" })
check("normalization clamps known fields", unknown.needle == 2, unknown.needle)
check("normalization keeps unknown fields", unknown.extra == "kept")
check("normalization fills missing fields", unknown.remote == 0 and unknown.kick == 0)

---------------------------------------------------------------- 库存与自动实带

local profile = profileWith({
    needle = { free = 1, purchased = 1 },
    remote = { purchased = 1 },
    kick = { free = 1 },
}, { needle = 0, remote = 0, kick = 0 })

local free, purchased = Shop.stock(profile, "needle")
check("stock reports both buckets", free == 1 and purchased == 1)
check("total stock adds both buckets", Shop.totalStock(profile, "needle") == 2)

local carry = Shop.effectiveCarry(profile, "versus")
check("versus carries the full needle stock up to the cap", carry.needle == 2, carry.needle)
check("versus carries the full remote stock", carry.remote == 1, carry.remote)
check("versus carries the full kick stock", carry.kick == 1, carry.kick)
check("an old zero loadout no longer limits the carry", carry.needle == 2)

profile.loadout.needle = 2
profile.inventory.needle.free = 0
profile.inventory.needle.purchased = 1
check("running out lowers the automatic carry", Shop.effectiveCarry(profile, "versus").needle == 1)
profile.inventory.needle.purchased = 0
check("an empty stock carries zero", Shop.effectiveCarry(profile, "versus").needle == 0)
check("stock changes never need a loadout edit",
    Shop.loadoutValue(profile, "needle") == 2
        and Shop.effectiveCarry(profile, "versus").needle == 0)

local capped = profileWith({
    needle = { purchased = 7 },
    remote = { purchased = 5 },
    kick = { purchased = 4 },
})
local cappedCarry = Shop.effectiveCarry(capped, "versus")
check("needle auto carry stops at 2", cappedCarry.needle == 2, cappedCarry.needle)
check("remote auto carry stops at 1", cappedCarry.remote == 1, cappedCarry.remote)
check("kick auto carry stops at 1", cappedCarry.kick == 1, cappedCarry.kick)

local practiceCarry = Shop.effectiveCarry(capped, "practice")
check("practice carries no needle", practiceCarry.needle == 0, practiceCarry.needle)
check("practice carries no remote", practiceCarry.remote == 0, practiceCarry.remote)
check("practice carries no kick", practiceCarry.kick == 0, practiceCarry.kick)

local roomlessCarry = Shop.effectiveCarry(capped)
check("a roomless player still sees the next versus carry",
    roomlessCarry.needle == 2 and roomlessCarry.remote == 1 and roomlessCarry.kick == 1)

---------------------------------------------------------------- 库存展示

local summary = Shop.inventorySummary(profileWith({
    needle = { free = 1, purchased = 2 },
    kick = { purchased = 1 },
}), "versus")
check("the inventory summary follows catalog order",
    summary[1].id == "needle" and summary[2].id == "remote" and summary[3].id == "kick")
check("the summary exposes free and purchased stock",
    summary[1].free == 1 and summary[1].purchased == 2 and summary[1].stock == 3)
check("the summary includes the automatic carry",
    summary[1].carry == 2 and summary[2].carry == 0 and summary[3].carry == 1)
check("practice summary shows zero carry",
    Shop.inventorySummary(profileWith({ needle = { purchased = 2 } }), "practice")[1].carry == 0)
check("owned description lists only owned items",
    Shop.describeOwned(summary) == "逃生针 3（免费 1 · 购买 2） · 踢泡泡 1（免费 0 · 购买 1）",
    Shop.describeOwned(summary))
check("an empty inventory is described explicitly",
    Shop.describeOwned(Shop.inventorySummary(profileWith({}), "versus")) == "还没有道具")

---------------------------------------------------------------- 用量计费

local charge = Shop.usageCharge({ needle = 1, remote = 0, kick = 1 }, {
    needle = 9,
    remote = 4,
    kick = 1,
})
check("usage is capped by the carried snapshot", charge.needle == 1, charge.needle)
check("pickups beyond the carried copy are free", charge.remote == 0, charge.remote)
check("a successful kick charges one", charge.kick == 1, charge.kick)

local noCharge = Shop.usageCharge({}, { needle = 2, remote = 2, kick = 1 })
check("using only pickups costs nothing", noCharge.needle == 0
    and noCharge.remote == 0
    and noCharge.kick == 0)
check("practice's empty carry charges nothing",
    Shop.usageCharge(Shop.effectiveCarry(capped, "practice"), { needle = 2, remote = 2, kick = 1 }).needle == 0)
local malformed = Shop.usageCharge({ needle = "x", remote = 0 / 0 }, { needle = 2, remote = 2 })
check("malformed carries never charge", malformed.needle == 0 and malformed.remote == 0)

---------------------------------------------------------------- 结算顺序与上限

local spendProfile = profileWith({
    needle = { free = 1, purchased = 2 },
    remote = { purchased = 1 },
    kick = { free = 1, purchased = 1 },
})
local spent, settledCharge = Shop.settleUsage(
    spendProfile,
    { needle = 2, remote = 1, kick = 1 },
    { needle = 2, remote = 3, kick = 1 }
)
check("needle takes free stock first", spent.needle.free == 1, spent.needle.free)
check("needle then takes purchased stock", spent.needle.purchased == 1, spent.needle.purchased)
check("remote takes purchased stock", spent.remote.purchased == 1, spent.remote.purchased)
check("kick also takes free stock first", spent.kick.free == 1, spent.kick.free)
check("charged remote use is capped by carry", settledCharge.remote == 1, settledCharge.remote)
check("balance after settlement", spendProfile.inventory.needle.free == 0
    and spendProfile.inventory.needle.purchased == 1
    and spendProfile.inventory.remote.purchased == 0
    and spendProfile.inventory.kick.free == 0
    and spendProfile.inventory.kick.purchased == 1)

local thin = profileWith({ needle = { purchased = 1 } })
local thinSpent = Shop.settleUsage(thin, { needle = 2 }, { needle = 2 })
check("settlement never exceeds the current stock", thinSpent.needle.purchased == 1)
check("current stock is not negative", thin.inventory.needle.purchased == 0)

local untouched = profileWith({ needle = { free = 1 } })
local zeroSpent = Shop.settleUsage(untouched, { needle = 0 }, { needle = 2 })
check("no carried stock means no charge", zeroSpent.needle.free == 0 and zeroSpent.needle.purchased == 0)
check("no carried stock leaves the profile alone", untouched.inventory.needle.free == 1)
local badSpent = Shop.settleUsage(nil, { needle = 1 }, { needle = 1 })
check("an invalid profile returns zero spend", badSpent.needle.free == 0 and badSpent.needle.purchased == 0)

---------------------------------------------------------------- 展示

check("empty items show as none", Shop.describeItems(nil) == "无道具")
check("zero counts show as none", Shop.describeItems({ needle = 0, remote = 0, kick = 0 }) == "无道具")
check("description lists counts and the kick ability",
    Shop.describeItems({ needle = 2, remote = 0, kick = 1 }) == "针2 踢")

TestLib.finish()
