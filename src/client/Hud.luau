-- src/client/Hud.luau
-- ScreenGui layout: board host, side panel, waiting/character-select screen,
-- 3-2-1 countdown and the results card. No game logic lives here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Sprites = require(Shared:WaitForChild("Sprites"))
local AssetIds = require(Shared:WaitForChild("AssetIds"))

local Hud = {}

Hud.charSelected = Instance.new("BindableEvent")
Hud.mutePressed = Instance.new("BindableEvent")

local PANEL = Color3.fromRGB(12, 27, 42)
local PANEL_2 = Color3.fromRGB(18, 38, 57)
local PANEL_3 = Color3.fromRGB(24, 49, 71)
local ACCENT = Color3.fromRGB(92, 198, 255)
local TEXT = Color3.fromRGB(235, 246, 255)
local SUBTLE = Color3.fromRGB(143, 177, 198)
local GOLD = Color3.fromRGB(255, 215, 128)
local LOCKED_VEIL = Color3.fromRGB(88, 92, 98) -- veil over unselected cards once locked
local LOCKED_TINT = Color3.fromRGB(150, 150, 150) -- dims the portrait under the veil
local DANGER = Color3.fromRGB(255, 104, 96)
local SURVIVE = Color3.fromRGB(120, 226, 147)

local CHAR_INFO = {
    baobao = {
        name = "宝宝",
        tagline = "均衡 · 新手友好",
        stats = "速度 144 · 威力 1 · 水泡 1\n上限 240 / 7 / 6",
    },
    haidao = {
        name = "小海盗",
        tagline = "远射 · 控场",
        stats = "速度 120 · 威力 2 · 水泡 1\n上限 216 / 7 / 8",
    },
}

local gui
local stage
local uiScale
local boardHost
local sidebar
local compact
local titleLabel
local subtitleLabel
local soundButton
local timerLabel
local compactTimer
local compactStatus
local selfName
local selfStatus
local selfStats
local playerRows = {}
local waitingOverlay
local loadingOverlay
local waitingTitle
local waitingSubtitle
local waitingInfo
local waitingCountdown
local waitingHint
local waitingSlots = {}
local waitingCards = {}
local countdownOverlay
local countdownImage
local countdownFallback
local resultOverlay
local resultArt
local resultFallback
local resultPortrait
local resultPortraitFallback
local resultWinner
local resultDetail
local resultNext
local resultConfetti = {}

local state = nil
local lastSnapshot = nil
local rosterById = {}
local selectedChar = "baobao"
local muted = false
local lastWarmup = nil
local goUntil = 0
local confettiRound = nil

---------------------------------------------------------------- 基础组件

local function newFrame(parent, name, size, position, color, transparency)
    local frame = Instance.new("Frame")
    frame.Name = name
    frame.Size = size
    frame.Position = position or UDim2.fromOffset(0, 0)
    frame.BackgroundColor3 = color or PANEL_2
    frame.BackgroundTransparency = transparency or 0
    frame.BorderSizePixel = 0
    frame.Parent = parent
    return frame
end

local function round(frame, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(radius, 0)
    corner.Parent = frame
end

local function outline(frame, color, thickness, transparency)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = thickness
    stroke.Transparency = transparency or 0
    stroke.Parent = frame
    return stroke
end

local function label(parent, name, text, size, position, color, textSize, bold)
    local textLabel = Instance.new("TextLabel")
    textLabel.Name = name
    textLabel.BackgroundTransparency = 1
    textLabel.BorderSizePixel = 0
    textLabel.Size = size
    textLabel.Position = position
    textLabel.Font = if bold == false then Enum.Font.Gotham else Enum.Font.GothamBold
    textLabel.Text = text
    textLabel.TextColor3 = color or TEXT
    textLabel.TextSize = textSize or 13
    textLabel.TextXAlignment = Enum.TextXAlignment.Left
    textLabel.TextYAlignment = Enum.TextYAlignment.Center
    textLabel.TextTruncate = Enum.TextTruncate.AtEnd
    textLabel.Parent = parent
    return textLabel
end

local function centeredLabel(parent, name, text, size, position, color, textSize, bold)
    local textLabel = label(parent, name, text, size, position, color, textSize, bold)
    textLabel.TextXAlignment = Enum.TextXAlignment.Center
    return textLabel
end

local function setZRecursive(root, z)
    root.ZIndex = z
    for _, child in ipairs(root:GetDescendants()) do
        if child:IsA("GuiObject") then
            child.ZIndex = z
        end
    end
end

local function asset(key)
    return AssetIds[key] or ""
end

local function teamColor(index)
    local key = Sprites.teamKey(index or 0)
    local hex = Constants.TEAM_HEX[key] or "#ffffff"
    return Color3.fromRGB(
        tonumber(string.sub(hex, 2, 3), 16) or 255,
        tonumber(string.sub(hex, 4, 5), 16) or 255,
        tonumber(string.sub(hex, 6, 7), 16) or 255
    )
end

local function formatClock(seconds)
    local value = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(value / 60), value % 60)
end

local function findPlayer(id)
    if not id or not lastSnapshot then
        return nil
    end
    for _, player in ipairs(lastSnapshot.players or {}) do
        if player.id == id then
            return player
        end
    end
    return nil
end

local function charName(char)
    return (CHAR_INFO[char] or CHAR_INFO.baobao).name
end

local function makeEyes(parent, circleSize)
    local function eye(xOffset)
        local eyeFrame = newFrame(
            parent,
            "Eye",
            UDim2.fromOffset(circleSize * 0.16, circleSize * 0.18),
            UDim2.fromOffset(circleSize / 2 + xOffset, circleSize * 0.36),
            Color3.fromRGB(255, 255, 255),
            0
        )
        round(eyeFrame, 0.5)
        local pupil = newFrame(
            eyeFrame,
            "Pupil",
            UDim2.fromOffset(4, 5),
            UDim2.fromOffset(6, 5),
            Color3.fromRGB(22, 28, 36),
            0
        )
        round(pupil, 0.5)
    end
    eye(-circleSize * 0.17)
    eye(circleSize * 0.17)
end

local function makePortrait(parent, size)
    local portrait = Instance.new("ImageLabel")
    portrait.Name = "Portrait"
    portrait.BackgroundTransparency = 1
    portrait.BorderSizePixel = 0
    portrait.Size = UDim2.fromOffset(size, size)
    portrait.AnchorPoint = Vector2.new(0.5, 0.5)
    portrait.ScaleType = Enum.ScaleType.Fit
    portrait.Visible = false
    portrait.Parent = parent

    local fallback = newFrame(
        parent,
        "PortraitFallback",
        UDim2.fromOffset(size * 0.8, size * 0.8),
        UDim2.fromOffset(0, 0),
        teamColor(0),
        0
    )
    fallback.AnchorPoint = Vector2.new(0.5, 0.5)
    round(fallback, 0.5)
    outline(fallback, Color3.fromRGB(255, 255, 255), 2, 0.45)
    makeEyes(fallback, size * 0.8)

    return portrait, fallback
end

---------------------------------------------------------------- 侧栏

local function buildSidebar()
    sidebar = newFrame(
        stage,
        "Sidebar",
        UDim2.fromOffset(324, 520),
        UDim2.fromOffset(636, 64),
        PANEL,
        0.04
    )
    round(sidebar, 0.035)
    outline(sidebar, Color3.fromRGB(56, 99, 126), 1.5, 0.4)

    label(sidebar, "Title", "对局", UDim2.fromOffset(110, 24), UDim2.fromOffset(14, 10), TEXT, 17)
    timerLabel = label(
        sidebar,
        "Timer",
        "等待中",
        UDim2.fromOffset(184, 24),
        UDim2.fromOffset(126, 10),
        ACCENT,
        13,
        true
    )
    timerLabel.TextXAlignment = Enum.TextXAlignment.Right

    local separator = newFrame(sidebar, "Separator", UDim2.new(1, -28, 0, 1), UDim2.fromOffset(14, 42))
    separator.BackgroundColor3 = Color3.fromRGB(55, 94, 119)
    separator.BackgroundTransparency = 0.4

    local selfCard = newFrame(
        sidebar,
        "SelfCard",
        UDim2.new(1, -28, 0, 82),
        UDim2.fromOffset(14, 52),
        PANEL_2,
        0
    )
    round(selfCard, 0.07)
    outline(selfCard, Color3.fromRGB(52, 100, 127), 1, 0.5)

    selfName = label(selfCard, "Name", "观战席", UDim2.fromOffset(190, 24), UDim2.fromOffset(10, 6), TEXT, 15)
    selfStatus = label(
        selfCard,
        "Status",
        "观战",
        UDim2.fromOffset(86, 20),
        UDim2.fromOffset(220, 7),
        SUBTLE,
        11
    )
    selfStatus.TextXAlignment = Enum.TextXAlignment.Right
    selfStats = label(
        selfCard,
        "Stats",
        "下一局加入",
        UDim2.new(1, -20, 0, 44),
        UDim2.fromOffset(10, 32),
        SUBTLE,
        10,
        false
    )
    selfStats.TextWrapped = true
    selfStats.TextYAlignment = Enum.TextYAlignment.Top

    label(sidebar, "PlayersTitle", "对战玩家", UDim2.fromOffset(160, 18), UDim2.fromOffset(14, 140), SUBTLE, 10)

    for i = 1, 6 do
        local row = newFrame(
            sidebar,
            "PlayerRow" .. i,
            UDim2.new(1, -28, 0, 30),
            UDim2.fromOffset(14, 160 + (i - 1) * 32),
            PANEL_2,
            1
        )
        round(row, 0.18)
        local dot = newFrame(
            row,
            "Dot",
            UDim2.fromOffset(8, 8),
            UDim2.fromOffset(10, 11),
            teamColor(i - 1),
            0
        )
        round(dot, 0.5)
        local name = label(row, "Name", "", UDim2.fromOffset(164, 30), UDim2.fromOffset(25, 0), TEXT, 11)
        local role = label(
            row,
            "Role",
            "",
            UDim2.fromOffset(104, 30),
            UDim2.fromOffset(190, 0),
            SUBTLE,
            9
        )
        role.TextXAlignment = Enum.TextXAlignment.Right
        playerRows[i] = { row = row, dot = dot, name = name, role = role }
    end

    label(sidebar, "LegendTitle", "道具", UDim2.fromOffset(160, 18), UDim2.fromOffset(14, 360), SUBTLE, 10)
    local legendOrder = Sprites.ITEM_ORDER
    for i, kind in ipairs(legendOrder) do
        local col = (i - 1) % 4
        local row = math.floor((i - 1) / 4)
        local cell = newFrame(
            sidebar,
            "Legend_" .. kind,
            UDim2.fromOffset(70, 24),
            UDim2.fromOffset(14 + col * 74, 382 + row * 28),
            PANEL_2,
            1
        )
        local sprite = Sprites.ITEMS[kind]
        local id = if sprite then asset(sprite.assetKey) else ""
        if id ~= "" and sprite then
            local image = Instance.new("ImageLabel")
            image.BackgroundTransparency = 1
            image.BorderSizePixel = 0
            image.Size = UDim2.fromOffset(20, 20)
            image.Position = UDim2.fromOffset(3, 2)
            image.ScaleType = Enum.ScaleType.Fit
            image.Image = id
            image.ImageRectSize = Vector2.new(sprite.frameWidth, sprite.frameHeight)
            image.ImageRectOffset = Vector2.zero
            image.Parent = cell
        else
            local badge = centeredLabel(
                cell,
                "Badge",
                string.sub(Sprites.ITEM_NAMES[kind] or "?", 1, 1),
                UDim2.fromOffset(20, 20),
                UDim2.fromOffset(3, 2),
                ACCENT,
                11
            )
            badge.TextXAlignment = Enum.TextXAlignment.Center
        end
        label(
            cell,
            "Name",
            Sprites.ITEM_NAMES[kind] or kind,
            UDim2.fromOffset(45, 24),
            UDim2.fromOffset(25, 0),
            TEXT,
            9
        )
    end

    local controls = label(
        sidebar,
        "Controls",
        "WASD / 方向键  移动\n空格  放泡 / 引爆遥控\nCtrl · Shift · E  使用道具",
        UDim2.new(1, -28, 0, 50),
        UDim2.fromOffset(14, 444),
        SUBTLE,
        10,
        false
    )
    controls.TextWrapped = true
    controls.TextYAlignment = Enum.TextYAlignment.Top

    setZRecursive(sidebar, 30000)
end

local function buildCompact()
    compact = newFrame(
        stage,
        "Compact",
        UDim2.fromOffset(600, 60),
        UDim2.fromOffset(10, 8),
        PANEL,
        0.08
    )
    round(compact, 0.05)
    outline(compact, Color3.fromRGB(54, 96, 122), 1, 0.5)

    label(compact, "Title", "泡泡堂 · 海盗14", UDim2.fromOffset(210, 26), UDim2.fromOffset(12, 5), TEXT, 15)
    compactTimer = label(
        compact,
        "Timer",
        "等待中",
        UDim2.fromOffset(150, 22),
        UDim2.fromOffset(12, 30),
        ACCENT,
        11
    )
    compactStatus = label(
        compact,
        "Status",
        "观战",
        UDim2.fromOffset(260, 30),
        UDim2.fromOffset(166, 16),
        SUBTLE,
        10,
        false
    )
    compactStatus.TextXAlignment = Enum.TextXAlignment.Right
    compactStatus.TextWrapped = true
    setZRecursive(compact, 31000)
end

---------------------------------------------------------------- 等待 / 选角

-- Shown while the server is still loading this player's saved profile, before any
-- room exists. Covers the board area, same footprint as the waiting overlay.
local function buildLoading()
    loadingOverlay = newFrame(
        stage,
        "LoadingOverlay",
        UDim2.fromOffset(600, 520),
        UDim2.fromOffset(20, 64),
        Color3.fromRGB(6, 18, 30),
        0.08
    )
    loadingOverlay.ClipsDescendants = true
    loadingOverlay.Visible = false
    round(loadingOverlay, 0.015)
    outline(loadingOverlay, Color3.fromRGB(54, 107, 132), 1.5, 0.45)

    centeredLabel(
        loadingOverlay,
        "Title",
        "正在加载数据…",
        UDim2.fromOffset(600, 40),
        UDim2.fromOffset(0, 214),
        TEXT,
        28,
        true
    )
    centeredLabel(
        loadingOverlay,
        "Hint",
        "正在读取你的存档，请稍候",
        UDim2.fromOffset(600, 24),
        UDim2.fromOffset(0, 264),
        SUBTLE,
        16,
        false
    )
    setZRecursive(loadingOverlay, 100000)
end

local function buildWaiting()
    waitingOverlay = newFrame(
        stage,
        "WaitingOverlay",
        UDim2.fromOffset(600, 520),
        UDim2.fromOffset(20, 64),
        Color3.fromRGB(6, 18, 30),
        0.08
    )
    waitingOverlay.ClipsDescendants = true
    round(waitingOverlay, 0.015)
    outline(waitingOverlay, Color3.fromRGB(54, 107, 132), 1.5, 0.45)

    local wipe = newFrame(
        waitingOverlay,
        "Glow",
        UDim2.fromOffset(600, 180),
        UDim2.fromOffset(0, 0),
        Color3.fromRGB(22, 74, 100),
        0.55
    )
    wipe.BackgroundTransparency = 0.55

    waitingTitle = centeredLabel(
        waitingOverlay,
        "Title",
        "海盗14  ·  练习模式",
        UDim2.fromOffset(600, 32),
        UDim2.fromOffset(0, 18),
        TEXT,
        24
    )
    waitingSubtitle = centeredLabel(
        waitingOverlay,
        "Subtitle",
        "1v1 · 选择角色，对战 Bot",
        UDim2.fromOffset(600, 20),
        UDim2.fromOffset(0, 51),
        SUBTLE,
        12,
        false
    )

    local cardXs = { 48, 312 }
    local chars = { "baobao", "haidao" }
    for i, char in ipairs(chars) do
        local info = CHAR_INFO[char]
        local card = Instance.new("TextButton")
        card.Name = "Card_" .. char
        card.Size = UDim2.fromOffset(240, 238)
        card.Position = UDim2.fromOffset(cardXs[i], 100)
        card.BackgroundColor3 = PANEL_2
        card.BackgroundTransparency = 0.02
        card.BorderSizePixel = 0
        card.AutoButtonColor = false
        card.Text = ""
        card.Parent = waitingOverlay
        round(card, 0.05)
        local stroke = outline(card, Color3.fromRGB(55, 100, 124), 2, 0.35)

        local portrait, fallback = makePortrait(card, 92)
        portrait.Position = UDim2.fromOffset(120, 70)
        fallback.Position = UDim2.fromOffset(120, 70)

        centeredLabel(card, "Name", info.name, UDim2.fromOffset(220, 28), UDim2.fromOffset(10, 124), TEXT, 20)
        centeredLabel(
            card,
            "Tagline",
            info.tagline,
            UDim2.fromOffset(220, 18),
            UDim2.fromOffset(10, 151),
            ACCENT,
            11
        )
        local stats = centeredLabel(
            card,
            "Stats",
            info.stats,
            UDim2.fromOffset(220, 42),
            UDim2.fromOffset(10, 174),
            SUBTLE,
            10,
            false
        )
        stats.TextWrapped = true
        stats.TextYAlignment = Enum.TextYAlignment.Top

        local selected = centeredLabel(
            card,
            "Selected",
            "已选择",
            UDim2.fromOffset(90, 20),
            UDim2.fromOffset(75, 214),
            GOLD,
            11
        )
        selected.Visible = false

        -- Grey veil shown on unselected cards once the selection is locked.
        local mask = Instance.new("Frame")
        mask.Name = "LockMask"
        mask.Size = UDim2.fromScale(1, 1)
        mask.BackgroundColor3 = LOCKED_VEIL
        mask.BackgroundTransparency = 0.38
        mask.BorderSizePixel = 0
        mask.Visible = false
        mask.Parent = card
        round(mask, 0.05)

        waitingCards[char] = {
            card = card,
            stroke = stroke,
            portrait = portrait,
            fallback = fallback,
            selected = selected,
            mask = mask,
        }
        card.Activated:Connect(function()
            if state and state.phase == "waiting" and not state.charLocked then
                Hud.charSelected:Fire(char)
            end
        end)
    end

    waitingInfo = centeredLabel(
        waitingOverlay,
        "Info",
        "练习模式 · 真人 1 / 2 · Bot 1",
        UDim2.fromOffset(580, 20),
        UDim2.fromOffset(10, 352),
        SUBTLE,
        11,
        false
    )

    for i = 1, 6 do
        local slot = newFrame(
            waitingOverlay,
            "Slot" .. i,
            UDim2.fromOffset(88, 30),
            UDim2.fromOffset(16 + (i - 1) * 96, 378),
            PANEL_3,
            0.25
        )
        round(slot, 0.18)
        local dot = newFrame(
            slot,
            "Dot",
            UDim2.fromOffset(7, 7),
            UDim2.fromOffset(8, 11),
            Color3.fromRGB(80, 105, 120),
            0
        )
        round(dot, 0.5)
        local name = label(slot, "Name", "Bot 对手", UDim2.fromOffset(70, 30), UDim2.fromOffset(19, 0), SUBTLE, 9)
        waitingSlots[i] = { frame = slot, dot = dot, name = name }
    end

    waitingCountdown = centeredLabel(
        waitingOverlay,
        "Countdown",
        "等待玩家加入…",
        UDim2.fromOffset(600, 30),
        UDim2.fromOffset(0, 420),
        GOLD,
        18
    )
    waitingHint = centeredLabel(
        waitingOverlay,
        "Hint",
        "点击角色卡选择，击败 Bot 赢得对局",
        UDim2.fromOffset(600, 20),
        UDim2.fromOffset(0, 462),
        SUBTLE,
        10,
        false
    )
    setZRecursive(waitingOverlay, 100000)
    for _, entry in pairs(waitingCards) do
        entry.mask.ZIndex = 100001
    end
end

local function updateWaiting()
    if not waitingOverlay or not state then
        return
    end
    waitingOverlay.Visible = state.phase == "waiting"
    if not waitingOverlay.Visible then
        return
    end

    local yourEntry = rosterById[state.yourId]
    local colorIndex = if yourEntry then yourEntry.colorIndex else 0
    local color = teamColor(colorIndex)
    local locked = state.charLocked == true
    for char, entry in pairs(waitingCards) do
        local portraitKey = Sprites.portraitKey(char, colorIndex)
        local id = asset(portraitKey)
        if id ~= "" then
            entry.portrait.Image = id
            entry.portrait.Visible = true
            entry.fallback.Visible = false
        else
            entry.portrait.Visible = false
            entry.fallback.Visible = true
            entry.fallback.BackgroundColor3 = color
            for _, child in ipairs(entry.fallback:GetDescendants()) do
                if child:IsA("GuiObject") then
                    child.ZIndex = 100000
                end
            end
        end
        local isSelected = char == (state.selectedChar or selectedChar)
        local greyedOut = locked and not isSelected
        entry.selected.Visible = isSelected
        entry.stroke.Color = if isSelected then GOLD else Color3.fromRGB(55, 100, 124)
        entry.stroke.Thickness = if isSelected then 3 else 2
        entry.stroke.Transparency = if isSelected then 0.05 else 0.35
        entry.card.BackgroundColor3 = if isSelected then Color3.fromRGB(30, 60, 82) else PANEL_2
        -- Locked: the unselected card is dimmed and veiled grey; the pick stays vivid.
        entry.mask.Visible = greyedOut
        entry.portrait.ImageColor3 = if greyedOut then LOCKED_TINT else Color3.new(1, 1, 1)
    end

    local maxPlayers = state.maxPlayers or Constants.MAX_PLAYERS
    local practice = state.practice == true or state.mode == "practice"
    local real = #state.roster

    if waitingTitle then
        waitingTitle.Text = if practice then "海盗14  ·  练习模式" else "海盗14  ·  对战"
    end
    if waitingSubtitle then
        waitingSubtitle.Text = if practice then "1v1 · 选择角色，对战 Bot" else "选择你的角色"
    end

    waitingInfo.Text = if practice
        then string.format("练习模式  ·  真人 %d / %d  ·  Bot %d", real, maxPlayers, state.botFill or math.max(0, maxPlayers - real))
        else string.format("真人 %d / %d  ·  Bot 补位 %d", real, maxPlayers, state.botFill or math.max(0, maxPlayers - real))

    for i = 1, 6 do
        local slot = waitingSlots[i]
        local entry = state.roster[i]
        if i > maxPlayers then
            slot.frame.Visible = false
        else
            slot.frame.Visible = true
            if entry then
                slot.dot.BackgroundColor3 = teamColor(entry.colorIndex)
                slot.dot.BackgroundTransparency = 0
                local name = entry.name
                if #name > 8 then
                    name = string.sub(name, 1, 8)
                end
                slot.name.Text = (if entry.isBot then "BOT " else "") .. name
                slot.name.TextColor3 = teamColor(entry.colorIndex)
            else
                slot.dot.BackgroundColor3 = Color3.fromRGB(80, 105, 120)
                slot.dot.BackgroundTransparency = 0.2
                slot.name.Text = if practice then "Bot 对手" else "Bot 补位"
                slot.name.TextColor3 = SUBTLE
            end
        end
    end

    if state.endsIn and state.endsIn > 0 then
        waitingCountdown.Text = string.format("%d 秒后开始", state.endsIn)
        waitingHint.Text = if locked
            then "角色已锁定 · 即将开始"
            elseif practice
            then "点击角色卡选择 · 击败 Bot 赢得对局"
            else "点击角色卡选择 · 开局后自动补 Bot"
    else
        waitingCountdown.Text = "等待玩家加入…"
        waitingHint.Text = "第一名玩家加入后开始倒计时"
    end
end

---------------------------------------------------------------- 321

local function buildCountdown()
    countdownOverlay = newFrame(
        stage,
        "CountdownOverlay",
        UDim2.fromOffset(600, 520),
        UDim2.fromOffset(20, 64),
        Color3.fromRGB(0, 0, 0),
        1
    )
    countdownOverlay.Visible = false
    countdownOverlay.Active = false

    countdownImage = Instance.new("ImageLabel")
    countdownImage.Name = "Number"
    countdownImage.BackgroundTransparency = 1
    countdownImage.BorderSizePixel = 0
    countdownImage.AnchorPoint = Vector2.new(0.5, 0.5)
    countdownImage.Position = UDim2.fromOffset(300, 238)
    countdownImage.Size = UDim2.fromOffset(120, 100)
    countdownImage.ScaleType = Enum.ScaleType.Fit
    countdownImage.Visible = false
    countdownImage.Parent = countdownOverlay

    countdownFallback = centeredLabel(
        countdownOverlay,
        "Fallback",
        "3",
        UDim2.fromOffset(260, 140),
        UDim2.fromOffset(170, 168),
        Color3.fromRGB(255, 242, 188),
        92
    )
    countdownFallback.TextStrokeTransparency = 0.2
    countdownFallback.TextStrokeColor3 = Color3.fromRGB(65, 118, 140)
    setZRecursive(countdownOverlay, 120000)
end

local function showCountdownDigit(digit)
    countdownOverlay.Visible = true
    local sheet = Sprites.SHEETS.num_strip
    local id = asset(sheet.assetKey)
    local now = os.clock()
    local scale = 1 + 0.09 * math.sin(now * 9)
    if id ~= "" then
        countdownImage.Visible = true
        countdownImage.Image = id
        countdownImage.ImageRectSize = Vector2.new(sheet.frameWidth, sheet.frameHeight)
        countdownImage.ImageRectOffset = Vector2.new((digit - 1) * sheet.frameWidth, 0)
        countdownImage.Size = UDim2.fromOffset(120 * scale, 100 * scale)
        countdownFallback.Visible = false
    else
        countdownImage.Visible = false
        countdownFallback.Visible = true
        countdownFallback.Text = tostring(digit)
        countdownFallback.Size = UDim2.fromOffset(260 * scale, 140 * scale)
        countdownFallback.Position = UDim2.fromOffset(300 - 130 * scale, 238 - 70 * scale)
    end
end

local function showGo()
    countdownOverlay.Visible = true
    countdownImage.Visible = false
    countdownFallback.Visible = true
    countdownFallback.Text = "GO!"
    countdownFallback.TextColor3 = SURVIVE
    countdownFallback.Size = UDim2.fromOffset(300, 120)
    countdownFallback.Position = UDim2.fromOffset(150, 178)
end

local function hideCountdown()
    countdownOverlay.Visible = false
    countdownFallback.TextColor3 = Color3.fromRGB(255, 242, 188)
end

local function updateCountdown()
    if not state or state.phase ~= "playing" or not lastSnapshot then
        hideCountdown()
        lastWarmup = nil
        goUntil = 0
        return
    end

    local warmup = lastSnapshot.warmup or 0
    if warmup > 0 then
        local digit = math.clamp(math.ceil(warmup / Constants.TICK_RATE), 1, 3)
        showCountdownDigit(digit)
        lastWarmup = warmup
        goUntil = 0
    else
        if lastWarmup and lastWarmup > 0 then
            goUntil = os.clock() + 0.65
        end
        lastWarmup = 0
        if goUntil > 0 and os.clock() < goUntil then
            showGo()
        else
            goUntil = 0
            hideCountdown()
        end
    end
end

---------------------------------------------------------------- 结算

local function clearConfetti()
    for _, part in ipairs(resultConfetti) do
        if part.Parent then
            part:Destroy()
        end
    end
    resultConfetti = {}
end

local function spawnConfetti()
    local random = Random.new(math.floor(state.roundId or 0) * 97 + 11)
    for i = 1, 26 do
        local part = newFrame(
            resultOverlay,
            "Confetti",
            UDim2.fromOffset(random:NextNumber(4, 9), random:NextNumber(7, 14)),
            UDim2.fromOffset(random:NextInteger(0, 596), random:NextInteger(-80, -10)),
            Color3.fromHSV(random:NextNumber(), 0.72, 1),
            0
        )
        part.Rotation = random:NextInteger(0, 180)
        part.ZIndex = 131000
        table.insert(resultConfetti, part)
        local tween = TweenService:Create(
            part,
            TweenInfo.new(random:NextNumber(1.5, 2.6), Enum.EasingStyle.Linear),
            {
                Position = UDim2.fromOffset(part.Position.X.Offset + random:NextInteger(-40, 40), 540),
                Rotation = part.Rotation + random:NextInteger(180, 540),
                BackgroundTransparency = 0.15,
            }
        )
        tween:Play()
    end
end

local function buildResult()
    resultOverlay = newFrame(
        stage,
        "ResultOverlay",
        UDim2.fromOffset(600, 520),
        UDim2.fromOffset(20, 64),
        Color3.fromRGB(5, 16, 27),
        0.07
    )
    resultOverlay.ClipsDescendants = true
    resultOverlay.Visible = false
    round(resultOverlay, 0.015)
    outline(resultOverlay, Color3.fromRGB(56, 104, 128), 1.5, 0.45)

    resultArt = Instance.new("ImageLabel")
    resultArt.Name = "Art"
    resultArt.BackgroundTransparency = 1
    resultArt.BorderSizePixel = 0
    resultArt.AnchorPoint = Vector2.new(0.5, 0.5)
    resultArt.Position = UDim2.fromOffset(300, 76)
    resultArt.Size = UDim2.fromOffset(300, 104)
    resultArt.ScaleType = Enum.ScaleType.Fit
    resultArt.Visible = false
    resultArt.Parent = resultOverlay

    resultFallback = centeredLabel(
        resultOverlay,
        "ArtFallback",
        "胜利",
        UDim2.fromOffset(400, 60),
        UDim2.fromOffset(100, 46),
        GOLD,
        38
    )

    resultPortrait = Instance.new("ImageLabel")
    resultPortrait.Name = "WinnerPortrait"
    resultPortrait.BackgroundTransparency = 1
    resultPortrait.BorderSizePixel = 0
    resultPortrait.AnchorPoint = Vector2.new(0.5, 0.5)
    resultPortrait.Position = UDim2.fromOffset(300, 178)
    resultPortrait.Size = UDim2.fromOffset(84, 84)
    resultPortrait.ScaleType = Enum.ScaleType.Fit
    resultPortrait.Visible = false
    resultPortrait.Parent = resultOverlay

    resultPortraitFallback = centeredLabel(
        resultOverlay,
        "WinnerFallback",
        "胜",
        UDim2.fromOffset(84, 84),
        UDim2.fromOffset(258, 136),
        teamColor(0),
        30
    )
    resultPortraitFallback.BackgroundColor3 = PANEL_3
    resultPortraitFallback.BackgroundTransparency = 0
    round(resultPortraitFallback, 0.5)
    outline(resultPortraitFallback, Color3.fromRGB(255, 255, 255), 2, 0.45)

    resultWinner = centeredLabel(
        resultOverlay,
        "Winner",
        "",
        UDim2.fromOffset(560, 28),
        UDim2.fromOffset(20, 226),
        GOLD,
        18
    )
    resultDetail = centeredLabel(
        resultOverlay,
        "Detail",
        "",
        UDim2.fromOffset(560, 20),
        UDim2.fromOffset(20, 258),
        SUBTLE,
        11,
        false
    )
    resultNext = centeredLabel(
        resultOverlay,
        "Next",
        "",
        UDim2.fromOffset(560, 24),
        UDim2.fromOffset(20, 410),
        ACCENT,
        13
    )
    setZRecursive(resultOverlay, 130000)
end

local function showResult()
    if not state or state.phase ~= "ended" then
        resultOverlay.Visible = false
        clearConfetti()
        confettiRound = nil
        return
    end

    local result = state.lastResult
    if not result then
        resultOverlay.Visible = false
        return
    end
    resultOverlay.Visible = true

    local draw = result.draw == true
    local youWin = not draw and result.winnerId ~= nil and result.winnerId == state.yourId
    local youLose = not draw and state.yourId ~= nil and not youWin
    local artKey = if draw then "img_draw" elseif youWin then "img_win" elseif youLose then "img_lose" else nil
    local artId = if artKey then asset(artKey) else ""
    if artId ~= "" then
        resultArt.Image = artId
        resultArt.Visible = true
        resultFallback.Visible = false
    else
        resultArt.Visible = false
        resultFallback.Visible = true
        resultFallback.Text = if draw then "平局" elseif youWin then "胜利" elseif youLose then "失败" else "本局结束"
        resultFallback.TextColor3 = if draw then SUBTLE elseif youWin then GOLD elseif youLose then DANGER else TEXT
    end

    if draw or not result.winnerChar then
        resultPortrait.Visible = false
        resultPortraitFallback.Visible = false
        resultWinner.Text = "平局 · 无人存活"
        resultWinner.TextColor3 = SUBTLE
    else
        resultWinner.Text = "胜者  " .. (result.winnerName or "?")
        resultWinner.TextColor3 = teamColor(result.winnerColorIndex or 0)
        local portraitKey = Sprites.portraitKey(result.winnerChar, result.winnerColorIndex or 0)
        local portraitId = asset(portraitKey)
        if portraitId ~= "" then
            resultPortrait.Image = portraitId
            resultPortrait.Visible = true
            resultPortraitFallback.Visible = false
        else
            resultPortrait.Visible = false
            resultPortraitFallback.Visible = true
            resultPortraitFallback.Text = string.sub(charName(result.winnerChar), 1, 1)
            resultPortraitFallback.TextColor3 = teamColor(result.winnerColorIndex or 0)
        end
    end

    resultDetail.Text = string.format(
        "用时 %s  ·  存活 %d / %d",
        formatClock(result.duration or 0),
        result.aliveCount or 0,
        state.maxPlayers or Constants.MAX_PLAYERS
    )
    resultNext.Text = if (state.endsIn or 0) > 0
        then string.format("下一局 %d 秒后开始", state.endsIn)
        else "下一局即将开始"

    if youWin and confettiRound ~= state.roundId then
        confettiRound = state.roundId
        clearConfetti()
        spawnConfetti()
    elseif not youWin then
        confettiRound = nil
        clearConfetti()
    end
end

---------------------------------------------------------------- 状态刷新

local function updateRoster()
    if not state then
        return
    end

    rosterById = {}
    for _, entry in ipairs(state.roster or {}) do
        rosterById[entry.id] = entry
    end

    local maxPlayers = state.maxPlayers or Constants.MAX_PLAYERS
    local practice = state.practice == true or state.mode == "practice"

    for i = 1, 6 do
        local row = playerRows[i]
        local entry = (state.roster or {})[i]
        if i > maxPlayers then
            row.row.Visible = false
        elseif entry then
            row.row.Visible = true
            local color = teamColor(entry.colorIndex)
            local player = findPlayer(entry.id)
            local status = "准备"
            local alive = player and player.alive
            local trapped = player and player.trapped
            if state.phase == "waiting" then
                status = if entry.isBot then "Bot" else "待机"
            elseif player then
                if not alive then
                    status = "阵亡"
                elseif trapped then
                    status = "被困"
                elseif player.mount then
                    status = "骑乘"
                else
                    status = "存活"
                end
            end

            local displayName = entry.name
            if entry.isBot then
                displayName = "BOT " .. displayName
            end
            row.name.Text = displayName
            row.name.TextColor3 = if alive == false then SUBTLE else color
            row.name.TextTransparency = if alive == false then 0.55 else 0
            local role = charName(entry.char)
            row.role.Text = role .. " · " .. status
            row.role.TextColor3 = if alive == false
                then SUBTLE
                else if trapped then GOLD else teamColor(entry.colorIndex)
            row.dot.BackgroundColor3 = if alive == false then Color3.fromRGB(76, 93, 103) else color
            row.dot.BackgroundTransparency = if alive == false then 0.35 else 0
            row.row.BackgroundColor3 = if entry.id == state.yourId
                then Color3.fromRGB(35, 75, 98)
                else PANEL_2
            row.row.BackgroundTransparency = if entry.id == state.yourId then 0.05 else 1
        else
            if state.phase == "waiting" then
                row.row.Visible = true
                row.name.Text = if practice then "Bot 对手" else "Bot 补位"
                row.name.TextColor3 = SUBTLE
                row.name.TextTransparency = 0.35
                row.role.Text = if practice then "练习模式" else "自动匹配"
                row.role.TextColor3 = SUBTLE
                row.dot.BackgroundColor3 = Color3.fromRGB(80, 105, 120)
                row.dot.BackgroundTransparency = 0.2
                row.row.BackgroundColor3 = PANEL_2
                row.row.BackgroundTransparency = 1
            else
                row.row.Visible = false
            end
        end
    end
end

local function updateSelf()
    if not state then
        return
    end
    local entry = rosterById[state.yourId]
    local player = findPlayer(state.yourId)
    local color = if entry then teamColor(entry.colorIndex) else ACCENT

    if not entry then
        selfName.Text = "观战席"
        selfName.TextColor3 = TEXT
        selfStatus.Text = "观战"
        selfStatus.TextColor3 = SUBTLE
        selfStats.Text = if state.phase == "waiting"
            then "等待下一局开始"
            else "本局观战 · 下一局加入"
        return
    end

    selfName.Text = entry.name
    selfName.TextColor3 = color
    local status = "准备"
    if state.phase ~= "waiting" and player then
        if not player.alive then
            status = "阵亡"
        elseif player.trapped then
            status = "被困"
        else
            status = "存活"
        end
    elseif state.phase == "waiting" then
        status = "准备"
    end
    selfStatus.Text = status
    selfStatus.TextColor3 = if status == "阵亡"
        then SUBTLE
        else if status == "被困" then GOLD else if status == "存活" then SURVIVE else ACCENT

    if state.phase == "waiting" or not player then
        selfStats.Text = string.format("%s · 等待开局", charName(entry.char))
        if state.phase == "playing" then
            selfStats.Text = "本局观战 · 下一局加入"
        end
        return
    end

    local inv = player.inv or {}
    local first = string.format(
        "水泡 %d · 威力 %d · 速度 %d",
        player.maxBombs or 0,
        player.range or 0,
        math.floor(player.speed or 0)
    )
    local second = string.format("针 ×%d · 遥控 ×%d", inv.needle or 0, inv.remote or 0)
    if player.mount then
        second ..= " · " .. (Sprites.ITEM_NAMES[player.mount] or player.mount)
    end
    if player.kick then
        second ..= " · 踢泡"
    end
    selfStats.Text = first .. "\n" .. second
end

local function aliveText()
    if not state then
        return ""
    end
    if state.phase == "waiting" then
        return string.format("真人 %d", #(state.roster or {}))
    end
    local alive = 0
    local total = 0
    if lastSnapshot then
        for _, player in ipairs(lastSnapshot.players or {}) do
            total += 1
            if player.alive then
                alive += 1
            end
        end
    else
        total = #(state.roster or {})
    end
    return string.format("存活 %d/%d", alive, math.max(total, 1))
end

local function timerText()
    if not state then
        return "等待中"
    end
    if state.phase == "waiting" then
        if state.endsIn and state.endsIn > 0 then
            return string.format("开始 %d 秒", state.endsIn)
        end
        return "等待玩家"
    elseif state.phase == "playing" then
        local warmup = lastSnapshot and lastSnapshot.warmup or state.warmup or 0
        local seconds = lastSnapshot and lastSnapshot.timeLeft or state.timeLeft or 0
        if warmup > 0 then
            return string.format("准备 %d · %s", math.ceil(warmup / Constants.TICK_RATE), aliveText())
        end
        return string.format("%s · %s", formatClock(seconds), aliveText())
    end
    if state.endsIn and state.endsIn > 0 then
        return string.format("结算 %d 秒", state.endsIn)
    end
    return "结算"
end

local function updateChrome()
    local text = timerText()
    if timerLabel then
        timerLabel.Text = text
    end
    if compactTimer then
        compactTimer.Text = text
    end
    if compactStatus then
        local entry = state and rosterById[state.yourId]
        if not entry then
            compactStatus.Text = if state and state.phase == "waiting"
                then "等待开局 · 点击角色卡选择"
                else "观战中 · 下一局加入"
        else
            local player = findPlayer(entry.id)
            local status = "准备"
            if player then
                if not player.alive then
                    status = "阵亡"
                elseif player.trapped then
                    status = "被困"
                else
                    status = "存活"
                end
            end
            compactStatus.Text = string.format("%s · %s", charName(entry.char), status)
        end
    end
end

local function updateAll()
    if not state then
        return
    end
    updateRoster()
    updateSelf()
    updateWaiting()
    showResult()
    updateChrome()
    updateCountdown()
end

---------------------------------------------------------------- 布局

local function positionOverlays()
    if not boardHost or not waitingOverlay then
        return
    end
    local position = boardHost.Position
    local size = boardHost.Size
    waitingOverlay.Position = position
    waitingOverlay.Size = size
    if loadingOverlay then
        loadingOverlay.Position = position
        loadingOverlay.Size = size
    end
    countdownOverlay.Position = position
    countdownOverlay.Size = size
    resultOverlay.Position = position
    resultOverlay.Size = size
end

local function layout()
    local camera = workspace.CurrentCamera
    if not camera or not stage then
        return
    end
    local viewport = camera.ViewportSize
    local mobile = viewport.X < 760

    if mobile then
        stage.Size = UDim2.fromOffset(620, 640)
        titleLabel.Visible = false
        subtitleLabel.Visible = false
        sidebar.Visible = false
        compact.Visible = true
        boardHost.Position = UDim2.fromOffset(10, 76)
        compact.Position = UDim2.fromOffset(10, 8)
        soundButton.Position = UDim2.fromOffset(550, 16)
    else
        stage.Size = UDim2.fromOffset(980, 600)
        titleLabel.Visible = true
        subtitleLabel.Visible = true
        sidebar.Visible = true
        compact.Visible = false
        boardHost.Position = UDim2.fromOffset(20, 64)
        sidebar.Position = UDim2.fromOffset(636, 64)
        soundButton.Position = UDim2.fromOffset(900, 20)
    end
    positionOverlays()

    local margin = if mobile then 8 else 28
    local sx = (viewport.X - margin * 2) / stage.Size.X.Offset
    local sy = (viewport.Y - margin * 2) / stage.Size.Y.Offset
    uiScale.Scale = math.clamp(math.min(sx, sy), 0.35, 1.15)
end

---------------------------------------------------------------- 初始化

function Hud.init(screenGui)
    gui = screenGui

    local background = newFrame(
        gui,
        "Background",
        UDim2.fromScale(1, 1),
        UDim2.fromOffset(0, 0),
        Color3.fromRGB(6, 15, 24),
        0
    )
    background.ZIndex = 0
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(8, 23, 38)),
        ColorSequenceKeypoint.new(0.55, Color3.fromRGB(9, 19, 31)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 11, 18)),
    })
    gradient.Rotation = 120
    gradient.Parent = background

    stage = newFrame(
        gui,
        "Stage",
        UDim2.fromOffset(980, 600),
        UDim2.fromScale(0.5, 0.5),
        Color3.fromRGB(0, 0, 0),
        1
    )
    stage.AnchorPoint = Vector2.new(0.5, 0.5)
    stage.ZIndex = 10
    uiScale = Instance.new("UIScale")
    uiScale.Parent = stage

    boardHost = newFrame(
        stage,
        "BoardHost",
        UDim2.fromOffset(600, 520),
        UDim2.fromOffset(20, 64),
        Color3.fromRGB(0, 0, 0),
        1
    )
    boardHost.ClipsDescendants = false

    titleLabel = label(
        stage,
        "GameTitle",
        "泡泡堂 · 海盗14",
        UDim2.fromOffset(500, 26),
        UDim2.fromOffset(20, 10),
        TEXT,
        21
    )
    subtitleLabel = label(
        stage,
        "GameSubtitle",
        "BnB 练习模式 · 1v1 对战 Bot",
        UDim2.fromOffset(500, 20),
        UDim2.fromOffset(21, 35),
        SUBTLE,
        10,
        false
    )

    soundButton = Instance.new("TextButton")
    soundButton.Name = "SoundButton"
    soundButton.Size = UDim2.fromOffset(60, 24)
    soundButton.Position = UDim2.fromOffset(900, 20)
    soundButton.BackgroundColor3 = PANEL_2
    soundButton.BackgroundTransparency = 0.15
    soundButton.BorderSizePixel = 0
    soundButton.AutoButtonColor = false
    soundButton.Font = Enum.Font.GothamBold
    soundButton.Text = "声音开"
    soundButton.TextColor3 = TEXT
    soundButton.TextSize = 10
    soundButton.Parent = stage
    round(soundButton, 0.5)
    outline(soundButton, Color3.fromRGB(75, 120, 145), 1, 0.45)
    soundButton.Activated:Connect(function()
        Hud.mutePressed:Fire()
    end)
    soundButton.ZIndex = 140000

    buildSidebar()
    buildCompact()
    buildLoading()
    buildWaiting()
    buildCountdown()
    buildResult()
    layout()

    local cameraConnection = nil
    local function watchCamera()
        if cameraConnection then
            cameraConnection:Disconnect()
            cameraConnection = nil
        end
        local camera = workspace.CurrentCamera
        if camera then
            cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
        end
        layout()
    end
    workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
    watchCamera()
end

function Hud.getBoardHost()
    return boardHost
end

function Hud.setState(newState)
    if not newState then
        return
    end
    local previousPhase = state and state.phase
    state = newState
    selectedChar = state.selectedChar or selectedChar

    if loadingOverlay then
        loadingOverlay.Visible = state.phase == "loading"
    end
    if state.phase == "loading" then
        -- No room, roster or board yet: show only the loading screen and leave
        -- every round-related view hidden.
        waitingOverlay.Visible = false
        resultOverlay.Visible = false
        hideCountdown()
        layout()
        return
    end

    if state.phase == "waiting" then
        lastSnapshot = nil
        lastWarmup = nil
        goUntil = 0
        hideCountdown()
        resultOverlay.Visible = false
        clearConfetti()
        confettiRound = nil
    end

    if state.phase ~= "ended" then
        resultOverlay.Visible = false
        clearConfetti()
        confettiRound = nil
    end

    if previousPhase ~= state.phase and state.phase == "playing" then
        lastWarmup = nil
        goUntil = 0
    end

    updateAll()
    layout()
end

function Hud.applySnapshot(snapshot)
    if not snapshot or not state then
        return
    end
    lastSnapshot = snapshot
    if state.phase == "playing" or state.phase == "ended" then
        updateRoster()
        updateSelf()
        updateChrome()
        updateCountdown()
        if state.phase == "ended" then
            showResult()
        end
    end
end

function Hud.setMuted(value)
    muted = value
    if soundButton then
        soundButton.Text = if muted then "已静音" else "声音开"
        soundButton.TextColor3 = if muted then SUBTLE else TEXT
        soundButton.BackgroundTransparency = if muted then 0.35 else 0.15
    end
end

return Hud
