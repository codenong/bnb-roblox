-- src/shared/RoomName.luau
-- Pure room-name rules shared by the server and HUD. The server still filters
-- user text through TextService before storing it; this module only normalizes
-- and validates the characters and length.

local Constants = require(script.Parent.Constants)

local RoomName = {}

local MAX_CODEPOINTS = Constants.ROOM_NAME_MAX_CODEPOINTS
local MIN_VISIBLE_CODEPOINTS = Constants.ROOM_NAME_MIN_VISIBLE_CODEPOINTS

-- Unicode spaces other than the ASCII space are invisible in the browser and
-- can therefore make a room name look blank. Reject them instead of folding
-- them to ASCII spaces: the server must never store an ambiguous display name.
local function isForbiddenSpace(code)
    return code == 0x00A0 -- no-break space
        or code == 0x1680 -- ogham space mark
        or (code >= 0x2000 and code <= 0x200A) -- en/em/thin/hair/etc. spaces
        or code == 0x202F -- narrow no-break space
        or code == 0x205F -- medium mathematical space
        or code == 0x3000 -- ideographic space
end

-- Invisible formatting characters. U+200D (zero-width joiner) is deliberately
-- allowed because emoji sequences use it; the other zero-width/bidi controls
-- are not useful in a room name and can hide or reverse text.
local function isForbiddenFormat(code)
    return code == 0x00AD -- soft hyphen
        or code == 0x061C -- Arabic letter mark
        or code == 0x180E -- Mongolian vowel separator
        or (code >= 0x200B and code <= 0x200F and code ~= 0x200D)
        or (code >= 0x202A and code <= 0x202E) -- bidi embedding/override
        or (code >= 0x2060 and code <= 0x2064)
        or (code >= 0x2066 and code <= 0x206F) -- bidi isolates
        or code == 0xFEFF -- byte-order mark / zero-width no-break space
        or (code >= 0xFFF9 and code <= 0xFFFB) -- interlinear annotation
        or (code >= 0xE0001 and code <= 0xE007F) -- tag characters
end

local function isLineSeparator(code)
    return code == 0x2028 or code == 0x2029
end

-- A few codepoints are not whitespace or format characters but still render as
-- blank glyphs. They must not count toward the five-visible-character minimum.
local function isBlankGlyph(code)
    return code == 0x034F -- combining grapheme joiner
        or (code >= 0x180B and code <= 0x180D) -- Mongolian free variation selectors
        or code == 0x180F -- Mongolian free variation selector four
        or code == 0x115F or code == 0x1160 -- Hangul fillers
        or code == 0x17B4 or code == 0x17B5 -- Khmer inherent vowels
        or code == 0x2800 -- braille pattern blank
        or code == 0x3164 -- Hangul filler
        or code == 0xFFA0 -- halfwidth Hangul filler
end

local function isVariationSelector(code)
    return (code >= 0xFE00 and code <= 0xFE0F)
        or (code >= 0xE0100 and code <= 0xE01EF)
end

-- "Visible" means a codepoint that actually contributes to the displayed name.
-- Spaces, newlines, formatting characters and variation selectors do not count,
-- so a name padded with whitespace cannot satisfy the minimum.
local function isVisible(code)
    if code == 32 or code == 10 then
        return false
    end
    if code == 0x200D or isVariationSelector(code) or isBlankGlyph(code) then
        return false
    end
    return not isForbiddenSpace(code) and not isForbiddenFormat(code) and not isLineSeparator(code)
end

-- C0 controls other than LF, DEL, and C1 controls are never allowed. CR is
-- normalized to LF before this check so Windows-style input is accepted.
local function validateBody(text)
    local length = utf8.len(text)
    if length == nil then
        return nil
    end
    local visible = 0
    for _, code in utf8.codes(text) do
        if code == 127 or (code >= 128 and code <= 159) then
            return nil
        end
        if code < 32 and code ~= 10 then
            return nil
        end
        if isForbiddenSpace(code) or isForbiddenFormat(code) or isLineSeparator(code) then
            return nil
        end
        if isVisible(code) then
            visible += 1
        end
    end
    if visible < MIN_VISIBLE_CODEPOINTS then
        return nil
    end
    if length < 1 or length > MAX_CODEPOINTS then
        return nil
    end
    return text
end

-- Normalize line endings, trim surrounding spaces/newlines, then validate.
function RoomName.normalize(raw)
    if type(raw) ~= "string" then
        return nil, "invalid_name"
    end
    local text = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("^[ \n]+", ""):gsub("[ \n]+$", "")
    local valid = validateBody(text)
    if not valid then
        return nil, "invalid_name"
    end
    return valid
end

-- Revalidate TextService output. The filter may change spacing, so do not trim
-- here, but the result still has to be safe and within the same length limit.
function RoomName.validateFiltered(text)
    if type(text) ~= "string" then
        return nil, "filter_failed"
    end
    local valid = validateBody(text)
    if not valid then
        return nil, "filter_failed"
    end
    return valid
end

-- Keep a TextBox from accepting more codepoints than the server will store.
-- Truncate on a UTF-8 boundary so emoji and other multibyte text stay valid.
function RoomName.limitInput(raw)
    if type(raw) ~= "string" then
        return ""
    end
    local ok, limited = pcall(function()
        local count = 0
        for position in utf8.codes(raw) do
            count += 1
            if count > MAX_CODEPOINTS then
                return string.sub(raw, 1, position - 1)
            end
        end
        return raw
    end)
    if not ok then
        return ""
    end
    return limited
end

-- Names may contain newlines, but table rows and titles are single-line. Keep
-- the stored value intact and collapse line breaks only for display.
function RoomName.display(name)
    if type(name) ~= "string" then
        return nil
    end
    local text = name:gsub("\r\n", "\n"):gsub("[\r\n]+", " ")
    text = text:gsub("^ +", ""):gsub(" +$", "")
    if text == "" then
        return nil
    end
    return text
end

return table.freeze(RoomName)
