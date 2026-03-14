local addonName, ns = ...

-------------------------------------------------------------------------------
-- RaidInspect — main addon file
--
-- Inspects every member of the current raid/party and populates a scrollable
-- table with:  Name · Guild · GearScore · Items (hover) · Talents (hover)
--             · Gemmed ✓ · Enchanted ✓
--
-- Rows are tinted with the player's class colour.
-- AceComm (COMM_PREFIX "RI1") is used to share full gear/talent data with
-- out-of-range group members running the addon.
-------------------------------------------------------------------------------

local RaidInspect = LibStub("AceAddon-3.0"):NewAddon(addonName,
    "AceEvent-3.0",
    "AceConsole-3.0",
    "AceComm-3.0",
    "AceTimer-3.0"
)

local LGT = LibStub("LibGroupTalents-1.0", true)

-- ============================================================
-- Constants
-- ============================================================

local CLASS_COLORS = {
    WARRIOR     = {r=0.78, g=0.61, b=0.43},
    PALADIN     = {r=0.96, g=0.55, b=0.73},
    HUNTER      = {r=0.67, g=0.83, b=0.45},
    ROGUE       = {r=1.00, g=0.96, b=0.41},
    PRIEST      = {r=1.00, g=1.00, b=1.00},
    DEATHKNIGHT = {r=0.77, g=0.12, b=0.23},
    SHAMAN      = {r=0.00, g=0.44, b=0.87},
    MAGE        = {r=0.41, g=0.80, b=0.94},
    WARLOCK     = {r=0.58, g=0.51, b=0.79},
    DRUID       = {r=1.00, g=0.49, b=0.04},
}

local CLASS_SPEC_NAMES = {
    WARRIOR     = {"Arms",        "Fury",           "Protection"},
    PALADIN     = {"Holy",        "Protection",     "Retribution"},
    HUNTER      = {"Beast Mastery","Marksmanship",  "Survival"},
    ROGUE       = {"Assassination","Combat",        "Subtlety"},
    PRIEST      = {"Discipline",  "Holy",           "Shadow"},
    DEATHKNIGHT = {"Blood",       "Frost",          "Unholy"},
    SHAMAN      = {"Elemental",   "Enhancement",    "Restoration"},
    MAGE        = {"Arcane",      "Fire",           "Frost"},
    WARLOCK     = {"Affliction",  "Demonology",     "Destruction"},
    DRUID       = {"Balance",     "Feral Combat",   "Restoration"},
}

-- Inventory slots to inspect (skip shirt=4)
local GEAR_SLOTS = {1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18}

local SLOT_NAMES = {
    [1]="Head",     [2]="Neck",      [3]="Shoulder", [5]="Chest",
    [6]="Waist",    [7]="Legs",      [8]="Feet",     [9]="Wrist",
    [10]="Hands",   [11]="Ring 1",   [12]="Ring 2",  [13]="Trinket 1",
    [14]="Trinket 2",[15]="Back",    [16]="Main Hand",[17]="Off Hand",
    [18]="Ranged",
}

-- Tooltip text for socket types (localisation-independent would need
-- GetSocketItemBonuses; the English strings cover the default locale used
-- on most WotLK private servers).
local SOCKET_TEXTS = {
    ["Meta Socket"]=true, ["Red Socket"]=true,  ["Blue Socket"]=true,
    ["Yellow Socket"]=true, ["Prismatic Socket"]=true,
}

local COMM_PREFIX    = "RI1"        -- kept ≤ 16 chars for ChatThrottle
local DATA_REQ_MSG   = "DR"         -- request full gear/talent/glyph data
local DATA_RESP_MSG  = "DD"         -- response with full player data

-- UI sizing
local WINDOW_W      = 560
local WINDOW_H      = 476     -- 450px of list area + 26px scale-slider row
local SCALE_ROW_H   = 26      -- height of the item/talent scale slider row
local ROW_H         = 18
local HEADER_H      = 22
local COL_NAME      = 120
local COL_GUILD     = 100
local COL_GS        = 55
local COL_ITEMS     = 46
local COL_TALENTS   = 78
local COL_GEMMED    = 38
local COL_ENCHANTED = 46
local COL_TOTAL = COL_NAME + COL_GUILD + COL_GS + COL_ITEMS
               + COL_TALENTS + COL_GEMMED + COL_ENCHANTED

local ICON_CHECK    = "Interface\\RaidFrame\\ReadyCheck-Ready"
local ICON_CROSS    = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local ICON_WAIT     = "Interface\\RaidFrame\\ReadyCheck-Waiting"

-- Paperdoll hover frame layout
-- Left column:  Head, Neck, Shoulder, Back, Chest, Wrist, Trinket 1, Trinket 2
-- Right column: Hands, Waist, Legs, Feet, Ring 1, Ring 2, Main Hand, Off Hand, Ranged
local PDOLL_LEFT    = {1, 2, 3, 15, 5, 9, 13, 14}
local PDOLL_RIGHT   = {10, 6, 7, 8, 11, 12, 16, 17, 18}
local PDOLL_ICON    = 28     -- item icon pixel size
local PDOLL_ROW     = 32     -- row height (px)
local PDOLL_COLW    = 160    -- total column width (icon + text)
local PDOLL_LPAD    = 12     -- left/right inner padding

-- Talent hover frame layout (read-only inspection tree)
local TALHOV_BTN       = 22    -- talent icon pixel size
local TALHOV_SPC       = 27    -- icon spacing, center-to-center (px)
local TALHOV_COLS      = 4     -- max columns per talent tree
local TALHOV_TABS      = 3     -- talent trees
local TALHOV_LPAD      = 12    -- left/right inner padding
local TALHOV_TABSEP    = 4     -- gap between adjacent talent trees (px)
local TALHOV_TITLE_H   = 13    -- height of the title text row (px)
local TALHOV_HEADER_H  = 15    -- height of the per-tree spec-name row (px)
local TALHOV_GLYPH_SEP = 5     -- top gap before the "Glyphs:" label (px)
local TALHOV_GLYPH_LH  = 14    -- line height for each glyph entry (px)
local TALHOV_DIM       = 0.25  -- vertex-colour brightness for unallocated talents

-- ============================================================
-- Inlined GearScore tables (previously from GearScoreLite)
-- ============================================================

local GS_ItemTypes = {
    ["INVTYPE_RELIC"]           = { SlotMOD = 0.3164, ItemSlot = 18, Enchantable = false },
    ["INVTYPE_TRINKET"]         = { SlotMOD = 0.5625, ItemSlot = 33, Enchantable = false },
    ["INVTYPE_2HWEAPON"]        = { SlotMOD = 2.000,  ItemSlot = 16, Enchantable = true  },
    ["INVTYPE_WEAPONMAINHAND"]  = { SlotMOD = 1.0000, ItemSlot = 16, Enchantable = true  },
    ["INVTYPE_WEAPONOFFHAND"]   = { SlotMOD = 1.0000, ItemSlot = 17, Enchantable = true  },
    ["INVTYPE_RANGED"]          = { SlotMOD = 0.3164, ItemSlot = 18, Enchantable = true  },
    ["INVTYPE_THROWN"]          = { SlotMOD = 0.3164, ItemSlot = 18, Enchantable = false },
    ["INVTYPE_RANGEDRIGHT"]     = { SlotMOD = 0.3164, ItemSlot = 18, Enchantable = false },
    ["INVTYPE_SHIELD"]          = { SlotMOD = 1.0000, ItemSlot = 17, Enchantable = true  },
    ["INVTYPE_WEAPON"]          = { SlotMOD = 1.0000, ItemSlot = 36, Enchantable = true  },
    ["INVTYPE_HOLDABLE"]        = { SlotMOD = 1.0000, ItemSlot = 17, Enchantable = false },
    ["INVTYPE_HEAD"]            = { SlotMOD = 1.0000, ItemSlot = 1,  Enchantable = true  },
    ["INVTYPE_NECK"]            = { SlotMOD = 0.5625, ItemSlot = 2,  Enchantable = false },
    ["INVTYPE_SHOULDER"]        = { SlotMOD = 0.7500, ItemSlot = 3,  Enchantable = true  },
    ["INVTYPE_CHEST"]           = { SlotMOD = 1.0000, ItemSlot = 5,  Enchantable = true  },
    ["INVTYPE_ROBE"]            = { SlotMOD = 1.0000, ItemSlot = 5,  Enchantable = true  },
    ["INVTYPE_WAIST"]           = { SlotMOD = 0.7500, ItemSlot = 6,  Enchantable = false },
    ["INVTYPE_LEGS"]            = { SlotMOD = 1.0000, ItemSlot = 7,  Enchantable = true  },
    ["INVTYPE_FEET"]            = { SlotMOD = 0.7500, ItemSlot = 8,  Enchantable = true  },
    ["INVTYPE_WRIST"]           = { SlotMOD = 0.5625, ItemSlot = 9,  Enchantable = true  },
    ["INVTYPE_HAND"]            = { SlotMOD = 0.7500, ItemSlot = 10, Enchantable = true  },
    ["INVTYPE_FINGER"]          = { SlotMOD = 0.5625, ItemSlot = 31, Enchantable = false },
    ["INVTYPE_CLOAK"]           = { SlotMOD = 0.5625, ItemSlot = 15, Enchantable = true  },
    ["INVTYPE_BODY"]            = { SlotMOD = 0,      ItemSlot = 4,  Enchantable = false },
}

local GS_Formula = {
    ["A"] = {
        [4] = { A = 91.4500, B = 0.6500 },
        [3] = { A = 81.3750, B = 0.8125 },
        [2] = { A = 73.0000, B = 1.0000 },
    },
    ["B"] = {
        [4] = { A = 26.0000, B = 1.2000 },
        [3] = { A = 0.7500,  B = 1.8000 },
        [2] = { A = 8.0000,  B = 2.0000 },
        [1] = { A = 0.0000,  B = 2.2500 },
    },
}

local GS_Quality = {
    [6000] = {
        Red   = { A = 0.94, B = 5000, C = 0.00006, D =  1 },
        Green = { A = 0.47, B = 5000, C = 0.00047, D = -1 },
        Blue  = { A = 0,    B = 0,    C = 0,        D =  0 },
        Description = "Legendary",
    },
    [5000] = {
        Red   = { A = 0.69, B = 4000, C = 0.00025, D =  1 },
        Green = { A = 0.28, B = 4000, C = 0.00019, D =  1 },
        Blue  = { A = 0.97, B = 4000, C = 0.00096, D = -1 },
        Description = "Epic",
    },
    [4000] = {
        Red   = { A = 0.0, B = 3000, C = 0.00069, D =  1 },
        Green = { A = 0.5, B = 3000, C = 0.00022, D = -1 },
        Blue  = { A = 1,   B = 3000, C = 0.00003, D = -1 },
        Description = "Superior",
    },
    [3000] = {
        Red   = { A = 0.12, B = 2000, C = 0.00012, D = -1 },
        Green = { A = 1,    B = 2000, C = 0.00050, D = -1 },
        Blue  = { A = 0,    B = 2000, C = 0.001,   D =  1 },
        Description = "Uncommon",
    },
    [2000] = {
        Red   = { A = 1, B = 1000, C = 0.00088, D = -1 },
        Green = { A = 1, B = 0,    C = 0,        D =  0 },
        Blue  = { A = 1, B = 1000, C = 0.001,   D = -1 },
        Description = "Common",
    },
    [1000] = {
        Red   = { A = 0.55, B = 0, C = 0.00045, D = 1 },
        Green = { A = 0.55, B = 0, C = 0.00045, D = 1 },
        Blue  = { A = 0.55, B = 0, C = 0.00045, D = 1 },
        Description = "Trash",
    },
}

-- ============================================================
-- Inlined GearScore functions (previously from GearScoreLite)
-- ============================================================

-- Returns (Red, Blue, Green) colour triple for a given score value.
-- NOTE: the second and third return values use the GS_Quality "Green" and
-- "Blue" keys respectively — this matches the original GearScoreLite
-- naming quirk that PopulateRow already accounts for.
local function GearScore_GetQuality(ItemScore)
    if not ItemScore then return 0.1, 0.1, 0.1 end
    if ItemScore > 5999 then ItemScore = 5999 end
    for i = 0, 6 do
        if ItemScore > i * 1000 and ItemScore <= (i + 1) * 1000 then
            local q = GS_Quality[(i + 1) * 1000]
            local r = q.Red["A"]   + ((ItemScore - q.Red["B"])   * q.Red["C"])   * q.Red["D"]
            local b = q.Green["A"] + ((ItemScore - q.Green["B"]) * q.Green["C"]) * q.Green["D"]
            local g = q.Blue["A"]  + ((ItemScore - q.Blue["B"])  * q.Blue["C"])  * q.Blue["D"]
            return r, b, g
        end
    end
    return 0.1, 0.1, 0.1
end

-- Returns the enchant-penalty multiplier for an item (1 = no penalty).
local function GearScore_GetEnchantInfo(ItemLink, ItemEquipLoc)
    if not ItemLink or not ItemEquipLoc then return 1 end
    local typeInfo = GS_ItemTypes[ItemEquipLoc]
    if not typeInfo or not typeInfo.Enchantable then return 1 end
    local parts = {}
    local s = ItemLink:match("|H(item:[^|]+)|h")
    if not s then return 1 end
    for p in s:gmatch("[^:]+") do parts[#parts + 1] = p end
    local enchantID = tonumber(parts[3] or "0") or 0
    if enchantID == 0 then
        local percent = floor((-2 * typeInfo.SlotMOD) * 100) / 100
        return 1 + (percent / 100)
    end
    return 1
end

-- Returns (score, itemLevel) for a single item link.
local function GearScore_GetItemScore(ItemLink)
    if not ItemLink then return 0, 0 end
    local _, _, ItemRarity, ItemLevel, _, _, _, _, ItemEquipLoc =
        GetItemInfo(ItemLink)
    if not ItemLevel then return 0, 0 end
    local QualityScale = 1
    local Scale = 1.8618
    if     ItemRarity == 5 then QualityScale = 1.3;   ItemRarity = 4
    elseif ItemRarity == 1 then QualityScale = 0.005; ItemRarity = 2
    elseif ItemRarity == 0 then QualityScale = 0.005; ItemRarity = 2 end
    if ItemRarity == 7 then ItemRarity = 3; ItemLevel = 187.05 end
    local typeInfo = GS_ItemTypes[ItemEquipLoc]
    if not typeInfo then return -1, ItemLevel end
    local Table = (ItemLevel > 120) and GS_Formula["A"] or GS_Formula["B"]
    if not (ItemRarity >= 2 and ItemRarity <= 4) then return -1, ItemLevel end
    local GearScore = floor(
        ((ItemLevel - Table[ItemRarity].A) / Table[ItemRarity].B)
        * typeInfo.SlotMOD * Scale * QualityScale)
    if ItemLevel == 187.05 then ItemLevel = 0 end
    if GearScore < 0 then GearScore = 0 end
    local percent = GearScore_GetEnchantInfo(ItemLink, ItemEquipLoc) or 1
    GearScore = floor(GearScore * percent)
    return GearScore, ItemLevel
end

-- Returns (totalScore, averageItemLevel) for a unit's equipped gear.
local function GearScore_GetScore(_, Target)
    if not UnitIsPlayer(Target) then return 0, 0 end
    local _, PlayerEnglishClass = UnitClass(Target)
    local GearScore = 0; local ItemCount = 0; local LevelTotal = 0; local TitanGrip = 1

    -- Detect Titan's Grip: two-handed weapon in main-hand while off-hand is also equipped
    if GetInventoryItemLink(Target, 16) and GetInventoryItemLink(Target, 17) then
        local _, _, _, _, _, _, _, _, ItemEquipLoc = GetItemInfo(GetInventoryItemLink(Target, 16))
        if ItemEquipLoc == "INVTYPE_2HWEAPON" then TitanGrip = 0.5 end
    end

    -- Off-hand slot (17) scored separately to apply Titan's Grip multiplier
    local offLink = GetInventoryItemLink(Target, 17)
    if offLink then
        local _, _, _, _, _, _, _, _, ItemEquipLoc = GetItemInfo(offLink)
        if ItemEquipLoc == "INVTYPE_2HWEAPON" then TitanGrip = 0.5 end
        local TempScore, ItemLevel = GearScore_GetItemScore(offLink)
        if PlayerEnglishClass == "HUNTER" then TempScore = TempScore * 0.3164 end
        GearScore = GearScore + TempScore * TitanGrip
        ItemCount = ItemCount + 1
        LevelTotal = LevelTotal + ItemLevel
    end

    -- All remaining slots
    for i = 1, 18 do
        if i ~= 4 and i ~= 17 then
            local ItemLink = GetInventoryItemLink(Target, i)
            if ItemLink then
                local TempScore, ItemLevel = GearScore_GetItemScore(ItemLink)
                if i == 16 and PlayerEnglishClass == "HUNTER" then TempScore = TempScore * 0.3164 end
                if i == 18 and PlayerEnglishClass == "HUNTER" then TempScore = TempScore * 5.3224 end
                if i == 16 then TempScore = TempScore * TitanGrip end
                GearScore = GearScore + TempScore
                ItemCount = ItemCount + 1
                LevelTotal = LevelTotal + ItemLevel
            end
        end
    end

    if ItemCount == 0 then return 0, 0 end
    return floor(GearScore), floor(LevelTotal / ItemCount)
end

-- ============================================================
-- Saved-variable defaults
-- ============================================================

local defaults = {
    profile = {
        windowX          = 0,
        windowY          = 0,
        itemFrameScale   = 1.0,
        talentFrameScale = 1.0,
    },
}

-- ============================================================
-- Runtime state
-- ============================================================

local cache              = {}     -- [playerName] = data record
local inspQueue          = {}     -- list of unit tokens queued for inspection
local inspecting         = nil    -- unit token currently being inspected
local inspTimer          = nil    -- timeout timer handle
local inspDelayTimer     = nil    -- handle for the inter-inspect delay timer
local inspectingGUID     = nil    -- GUID of the inspected unit captured at NotifyInspect time;
                                  -- used to validate INSPECT_TALENT_READY which carries no GUID arg
local pendingCommRequest = false  -- true when a group-wide data/glyph request is needed
local inspRetries        = {}     -- [playerName] = retry count for no-item-data re-inspects
local MAX_INSPECT_RETRIES  = 9    -- re-inspect at most this many times when item data is missing
                                  -- (1 initial attempt + 9 retries = 10 total scan attempts per player)
local INSPECT_RETRY_DELAY  = 3    -- seconds to wait before a retry inspect (gives server time to push data)
local INTER_INSPECT_DELAY  = 3    -- minimum seconds between consecutive player-to-player inspect transitions
local INSPECT_TIMEOUT      = 10   -- seconds before giving up on a non-responding inspect
local POST_TIMEOUT_DELAY   = 2.0  -- seconds to wait after a timeout before trying the next player

-- Set to true to enable verbose [RI] diagnostic messages in the chat frame.
-- These are intentionally off by default; they are only needed when debugging
-- inspect queue or data-collection issues.
local DEBUG = false
local function dprint(s)
    if DEBUG then RaidInspect:Print(s) end
end

-- Hidden tooltip used to count socket slots on item links
local scanTip = CreateFrame("GameTooltip", "RaidInspect_ScanTip",
                            nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Reusable table row frames (pre-created, max 40 = full raid)
local rows = {}
-- Frame references
local mainFrame, scrollChild

-- Hover frame state (created lazily the first time they are shown)
local paperdollFrame     = nil   -- RaidInspect_PaperdollHover
local paperdollSlots     = {}    -- [slotID] -> slot row Button
local paperdollHideTimer = nil   -- AceTimer handle for delayed hide
local talentHoverFrame     = nil   -- RaidInspect_TalentHover
local talentHoverButtons   = {}    -- flat list of talent icon Buttons (3×30)
local talentHoverHideTimer = nil   -- AceTimer handle for delayed hide

-- ============================================================
-- Gem / enchant helpers
-- ============================================================

-- Extract the colon-separated fields from an item hyperlink.
-- Returns a table: [1]="item" [2]=itemID [3]=enchant [4-7]=gem1-4 …
local function ParseLink(link)
    if not link then return nil end
    local s = link:match("|H(item:[^|]+)|h")
    if not s then return nil end
    local t = {}
    for p in s:gmatch("[^:]+") do t[#t+1] = p end
    return t
end

-- Builds the internal glyph table from LibGroupTalents' stored data for a unit.
-- LGT returns up to 6 glyph spell IDs (sockets 1-6 of the active talent group).
-- In WotLK, sockets 1-3 are Major glyphs (glyphType = 1) and 4-6 are Minor
-- (glyphType = 2).  Returns nil when LGT is absent or has no data for the unit.
local function GlyphsFromLGT(unit)
    if not LGT then return nil end
    local a, b, c, d, e, f = LGT:GetUnitGlyphs(unit)
    local spells = {a, b, c, d, e, f}
    local glyphs = {}
    for socket, spellID in ipairs(spells) do
        if spellID and spellID > 0 then
            local _, _, icon = GetSpellInfo(spellID)
            glyphs[socket] = {
                spellID   = spellID,
                icon      = icon,
                glyphType = socket <= 3 and 1 or 2,
            }
        end
    end
    return next(glyphs) and glyphs or nil
end

-- Returns (filledCount, totalSocketCount) for an item link.
-- totalSocketCount is determined from a hidden tooltip scan so it works
-- for items with any combination of socket colours.
local function GetSocketCounts(link)
    if not link then return 0, 0 end

    -- Count total sockets via the scan tooltip
    local total = 0
    local ok = pcall(function() scanTip:SetHyperlink(link) end)
    if ok then
        for i = 1, scanTip:NumLines() do
            local line = _G["RaidInspect_ScanTipTextLeft"..i]
            if line then
                local txt = line:GetText() or ""
                if SOCKET_TEXTS[txt] then
                    total = total + 1
                end
            end
        end
        scanTip:ClearLines()
    end

    -- Count filled gems from the link string (gem fields 4-7)
    local filled = 0
    local parts = ParseLink(link)
    if parts then
        for i = 4, 7 do
            local gemID = tonumber(parts[i] or "0") or 0
            if gemID > 0 then filled = filled + 1 end
        end
    end

    return filled, total
end

-- Returns true when the item is fully gemmed (or has no sockets).
-- An item is fully gemmed when it has zero empty sockets remaining.
local function IsFullyGemmed(link)
    local _, emptyCount = GetSocketCounts(link)
    return emptyCount == 0
end

-- Returns true when the item has an enchant or does not need one.
local function IsEnchanted(link, equipLoc)
    if not link or not equipLoc then return true end
    local info = GS_ItemTypes[equipLoc]
    if not info or not info.Enchantable then return true end
    local parts = ParseLink(link)
    if not parts then return true end
    return (tonumber(parts[3] or "0") or 0) > 0
end

-- Returns the display name of the permanent enchant on an item link, or nil.
-- The enchant field in WotLK item links is a SpellItemEnchantment.dbc entry ID,
-- which is NOT the same as a spell ID — GetSpellInfo() cannot be used here.
-- Instead, we scan the hidden tooltip: enchant descriptions appear as bright-green
-- lines that do NOT carry the "Equip:" or "Use:" prefix used by the item's own
-- built-in bonus effects.
-- Excluded patterns (not real enchants):
--   "Heroic"            — quality badge on heroic items
--   "[digits] Armor"    — armour value line (e.g. "1234 Armor")
local function GetEnchantText(link)
    local parts = ParseLink(link)
    if not parts then return nil end
    local enchantID = tonumber(parts[3] or "0") or 0
    if enchantID == 0 then return nil end

    local ok = pcall(function() scanTip:SetHyperlink(link) end)
    if not ok then return "Enchanted" end

    local result = nil
    for i = 2, scanTip:NumLines() do   -- skip line 1 = item name
        local lineL = _G["RaidInspect_ScanTipTextLeft"..i]
        if lineL then
            local txt = lineL:GetText() or ""
            local r, g, b = lineL:GetTextColor()
            -- Enchant lines are bright lime-green (R < 0.25, G > 0.75, B < 0.15)
            -- and do NOT start with "Equip:" or "Use:" (item-own bonus lines).
            -- Also skip the "Heroic" quality badge and bare armour-value lines
            -- (e.g. "1234 Armor") which share the same green colour.
            if r and g and b
            and r < 0.25 and g > 0.75 and b < 0.15
            and not txt:match("^Equip:")
            and not txt:match("^Use:")
            and txt ~= "Heroic"
            and not txt:match("^%d+ Armor$")
            and txt ~= "" then
                result = txt
                break
            end
        end
    end
    scanTip:ClearLines()
    return result or "Enchanted"
end

-- Returns ({gemName, …}, filledCount, totalSocketCount) for an item link.
-- Gem names come from GetItemInfo on each gem item ID embedded in the link.
-- totalSocketCount = filled gems + empty sockets, so it is non-zero whenever
-- the item has sockets at all (regardless of how many are filled).
local function GetGemInfo(link)
    local parts = ParseLink(link)
    if not parts then return {}, 0, 0 end
    local names = {}
    for i = 4, 7 do
        local gemID = tonumber(parts[i] or "0") or 0
        if gemID > 0 then
            local gn = GetItemInfo(gemID)
            names[#names + 1] = gn or "Gem"
        end
    end
    local _, emptyCount = GetSocketCounts(link)
    local totalSockets = #names + emptyCount   -- filled gems + empty sockets
    return names, #names, totalSockets
end

-- ============================================================
-- Data collection (called after INSPECT_TALENT_READY)
-- ============================================================

local function CollectData(unit)
    if not unit or not UnitIsPlayer(unit) then
        dprint(string.format("[RI] CollectData('%s') – not a player unit, aborting", tostring(unit)))
        return nil
    end

    local name, realm = UnitName(unit)
    if realm and realm ~= "" then name = name.."-"..realm end
    if not name or name == "Unknown" then
        dprint(string.format("[RI] CollectData('%s') – name is '%s', aborting", tostring(unit), tostring(name)))
        return nil
    end
    dprint(string.format("[RI] CollectData: collecting data for '%s'", tostring(name)))

    local _, class = UnitClass(unit)
    local guild     = GetGuildInfo(unit) or ""

    -- Item links
    local items = {}
    for _, slot in ipairs(GEAR_SLOTS) do
        items[slot] = GetInventoryItemLink(unit, slot)
    end

    -- GearScore
    local gs = GearScore_GetScore(name, unit) or 0

    -- Gem and enchant status (scan all gear slots)
    local missingGems, missingEnchants = false, false
    for _, slot in ipairs(GEAR_SLOTS) do
        local link = items[slot]
        if link then
            if not IsFullyGemmed(link) then
                missingGems = true
            end
            local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
            if not IsEnchanted(link, equipLoc) then
                missingEnchants = true
            end
        end
    end

    -- Talent point distribution across the three trees.
    -- When LibGroupTalents is available and this is not the local player, read
    -- from LGT's stored data (which is guaranteed current once LibGroupTalents_
    -- Update has fired).  Fall back to the raw WoW inspect-buffer API otherwise.
    local isnotplayer = not UnitIsUnit(unit, "player")
    local talentData  = {0, 0, 0}
    local talentPoints = {}          -- [talentName] = currentRank (> 0 only)
    local numTabs = 3                -- WotLK always has exactly 3 talent trees
    for tab = 1, numTabs do
        local numTalents
        if LGT and isnotplayer then
            numTalents = LGT:GetNumTalents(unit, tab) or 0
        else
            numTalents = (GetNumTalents and GetNumTalents(tab, isnotplayer)) or 0
        end
        for idx = 1, numTalents do
            local talName, _, _, _, rank
            if LGT and isnotplayer then
                talName, _, _, _, rank = LGT:GetTalentInfo(unit, tab, idx)
            else
                talName, _, _, _, rank = GetTalentInfo(tab, idx, isnotplayer)
            end
            talentData[tab] = (talentData[tab] or 0) + (rank or 0)
            if talName and rank and rank > 0 then
                talentPoints[talName] = rank
            end
        end
    end

    -- Glyph data (major + minor, sockets 1-6).
    -- For non-local players, prefer LGT's stored glyph data (received via
    -- LGT's own comm protocol, which is more reliable than the inspect buffer
    -- on private servers where GetGlyphSocketInfo with isnotplayer=true can
    -- return the local player's own glyphs instead of the inspected player's).
    -- Fall back to the inspect buffer only when LGT has no data for this unit.
    -- For the local player, always read directly from the API.
    -- glyphType == 1 → Major glyph; glyphType == 2 → Minor glyph
    local glyphs = {}
    if isnotplayer then
        local lgtGlyphs = GlyphsFromLGT(unit)
        if lgtGlyphs then
            glyphs = lgtGlyphs
        else
            -- Fallback: inspect buffer (may not be accurate on all servers)
            for socket = 1, 6 do
                local _, glyphType, glyphSpellID, icon = GetGlyphSocketInfo(socket, 1, true)
                if glyphSpellID and glyphSpellID > 0 then
                    glyphs[socket] = {
                        spellID   = glyphSpellID,
                        icon      = icon,
                        glyphType = glyphType,
                    }
                end
            end
        end
    else
        -- Local player: read directly
        for socket = 1, 6 do
            local _, glyphType, glyphSpellID, icon = GetGlyphSocketInfo(socket)
            if glyphSpellID and glyphSpellID > 0 then
                glyphs[socket] = {
                    spellID   = glyphSpellID,
                    icon      = icon,
                    glyphType = glyphType,
                }
            end
        end
    end

    local glyphCount = 0
    for _ in pairs(glyphs) do glyphCount = glyphCount + 1 end
    dprint(string.format("[RI] CollectData: done for '%s' – gs=%.0f gems=%s enchants=%s talents=%d/%d/%d glyphs=%d",
        name, gs,
        missingGems and "missing" or "ok", missingEnchants and "missing" or "ok",
        talentData[1] or 0, talentData[2] or 0, talentData[3] or 0,
        glyphCount))
    return {
        name      = name,
        class     = class,
        guild     = guild,
        gearscore = gs,
        items     = items,
        gemmed    = not missingGems,
        enchanted = not missingEnchants,
        talentData   = talentData,
        talentPoints = talentPoints,
        glyphs    = glyphs,
        timestamp = GetTime(),
    }
end

-- ============================================================
-- Inspect queue
-- ============================================================

-- Forward declaration so that scheduleNextInspect's closure can capture the
-- NextInspect upvalue before the function body is assigned.  Without this,
-- Lua would resolve the bare name 'NextInspect' as a global (_G.NextInspect),
-- which is always nil, causing a runtime crash when the timer fires.
local NextInspect

-- Schedule the next inspection step after a short delay.
-- Cancels any already-pending delay timer first so that only one
-- NextInspect chain is ever active at a time.
local function scheduleNextInspect(delay)
    if inspDelayTimer then
        RaidInspect:CancelTimer(inspDelayTimer)
    end
    inspDelayTimer = RaidInspect:ScheduleTimer(function()
        inspDelayTimer = nil
        NextInspect()
    end, delay or 0.5)
end

NextInspect = function()
    dprint(string.format("[RI] NextInspect called – queue=%d inspecting=%s", #inspQueue, tostring(inspecting)))
    if #inspQueue == 0 then
        inspecting    = nil
        inspectingGUID = nil
        dprint("[RI] Queue empty – scan complete")
        -- When the queue drains, send a group-wide data request if any player
        -- was skipped (out of range) or had missing/changed data.
        if pendingCommRequest then
            pendingCommRequest = false
            dprint("[RI] Sending deferred data comm request")
            RaidInspect:RequestData(true)   -- silent = true (no chat spam)
        end
        return
    end

    local unit = table.remove(inspQueue, 1)
    dprint(string.format("[RI] Processing unit '%s' (queue remaining: %d)", tostring(unit), #inspQueue))

    -- The local player is always accessible without a server-side inspect request.
    -- CanInspect returns false for yourself regardless of unit token, so bypass the
    -- queue mechanism.  The token may be "player" (solo/party) or "raidN" (raid group).
    if unit == "player" or UnitIsUnit(unit, "player") then
        dprint("[RI] Unit is local player – collecting data directly")
        local data = CollectData("player")
        if data then
            cache[data.name] = data
            RaidInspect:RefreshTable()
            dprint(string.format("[RI] Collected local player data for '%s'", tostring(data.name)))
        else
            dprint("[RI] CollectData returned nil for local player")
        end
        -- Minimum inter-inspect gap before the next player.
        scheduleNextInspect(INTER_INSPECT_DELAY)
        return
    end

    if not UnitExists(unit) then
        dprint(string.format("[RI] Unit '%s' does not exist – skipping", tostring(unit)))
        pendingCommRequest = true
        scheduleNextInspect(0)
        return
    end

    if not CheckInteractDistance(unit, 1) then
        dprint(string.format("[RI] CheckInteractDistance('%s', 1) = false (out of range?) – skipping", tostring(unit)))
        -- Player is out of range or offline.  Flag a deferred comm request so
        -- that when the queue empties we ask group members running the addon to
        -- share their own data (covers the out-of-range case).
        pendingCommRequest = true
        -- Schedule asynchronously to avoid deep recursion when many players
        -- are out of range or offline; a 0-second timer fires on the next frame.
        scheduleNextInspect(0)
        return
    end

    inspecting    = unit
    inspectingGUID = UnitGUID(unit)
    -- When LibGroupTalents is available, route the inspect request through it.
    -- LGT delegates to LibTalentQuery which serialises all NotifyInspect calls
    -- across every addon using LGT, preventing duplicate inspect requests and
    -- the server-side rate-limiting that comes from multiple addons each calling
    -- NotifyInspect independently.  When LGT is absent, fall back to NotifyInspect.
    -- On WotLK 3.3.5, NotifyInspect fires INSPECT_TALENT_READY (not INSPECT_READY)
    -- and makes inventory link data available immediately; gem data arrives after
    -- UNIT_INVENTORY_CHANGED.  We only listen for INSPECT_TALENT_READY.
    if LGT then
        dprint(string.format("[RI] Requesting inspect for '%s' via LGT (GUID=%s)", tostring(unit), tostring(inspectingGUID)))
        LGT:GetUnitTalents(unit, true)
    else
        dprint(string.format("[RI] Calling NotifyInspect on '%s' (GUID=%s)", tostring(unit), tostring(inspectingGUID)))
        NotifyInspect(unit)
    end

    -- Failsafe timeout so we never get stuck if INSPECT_TALENT_READY never fires
    -- (e.g. unit went offline mid-scan or the server throttled the request).
    if inspTimer then RaidInspect:CancelTimer(inspTimer) end
    inspTimer = RaidInspect:ScheduleTimer(function()
        dprint(string.format("[RI] Inspect TIMEOUT for '%s' – moving on", tostring(inspecting)))
        ClearInspectPlayer()
        inspecting    = nil
        inspectingGUID = nil
        -- Use scheduleNextInspect rather than a direct call so that we honour
        -- a small post-timeout gap before the next request, reducing the chance
        -- of immediately hitting the same server throttle again.
        scheduleNextInspect(POST_TIMEOUT_DELAY)
    end, INSPECT_TIMEOUT)
end

local function Enqueue(unit)
    if inspecting == unit then
        dprint(string.format("[RI] Enqueue('%s') – skipped, already inspecting", tostring(unit)))
        return
    end
    for _, u in ipairs(inspQueue) do
        if u == unit then
            dprint(string.format("[RI] Enqueue('%s') – skipped, already in queue", tostring(unit)))
            return
        end
    end
    dprint(string.format("[RI] Enqueue('%s') – added (queue size now %d)", tostring(unit), #inspQueue + 1))
    inspQueue[#inspQueue+1] = unit
end

function RaidInspect:ScanRaid()
    wipe(inspQueue)
    wipe(cache)
    wipe(inspRetries)
    if inspTimer then self:CancelTimer(inspTimer); inspTimer = nil end
    if inspDelayTimer then self:CancelTimer(inspDelayTimer); inspDelayTimer = nil end
    inspecting         = nil
    inspectingGUID     = nil
    pendingCommRequest = false
    self:RefreshTable()   -- immediately clear stale rows from any previous scan

    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid"..i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                -- Use "player" token for the local player so NextInspect can
                -- bypass CanInspect (which always returns false for yourself).
                Enqueue(UnitIsUnit(unit, "player") and "player" or unit)
            end
        end
    else
        Enqueue("player")
        local numParty = GetNumPartyMembers()
        for i = 1, numParty do
            local unit = "party"..i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                Enqueue(unit)
            end
        end
    end

    local total = #inspQueue + (inspecting and 1 or 0)
    self:Print(string.format("Queueing %d member(s) for inspection…", total))
    if not inspecting then NextInspect() end
end

-- AutoScan enqueues current group members WITHOUT wiping the cache.
-- Called automatically on group roster changes so that new members are
-- picked up and changed players are re-inspected incrementally.
function RaidInspect:AutoScan()
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid"..i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                Enqueue(UnitIsUnit(unit, "player") and "player" or unit)
            end
        end
    else
        Enqueue("player")
        local numParty = GetNumPartyMembers()
        for i = 1, numParty do
            local unit = "party"..i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                Enqueue(unit)
            end
        end
    end
    -- Only kick off a new chain if neither an active inspection nor a pending
    -- inter-inspect delay is already running; the existing chain will pick up
    -- any newly enqueued units on its own.
    if not inspecting and not inspDelayTimer then NextInspect() end
end

-- ============================================================
-- Event: inspection data ready
-- ============================================================

-- Shared logic executed by INSPECT_TALENT_READY (or the LGT callback) once
-- inspect data is confirmed to be ready for the unit we are waiting on.
-- "source" is the triggering event name, used only in debug print messages.
local function FinishInspect(source)
    if inspTimer then RaidInspect:CancelTimer(inspTimer); inspTimer = nil end

    -- Save both the unit token and its GUID now; both will be nilled before we
    -- finish, and the GUID is needed to validate the retry callback.
    local unit      = inspecting
    local savedGUID = inspectingGUID

    local data = CollectData(unit)
    if data then
        local oldData = cache[data.name]

        -- Decide whether a group-wide comm request is needed for this player.
        -- Request if gear or talents changed since the last scan (the remote
        -- data may have been updated by the player since we last saw them).
        if not pendingCommRequest and oldData then
            if (oldData.gearscore or 0) ~= (data.gearscore or 0) then
                dprint(string.format("[RI] %s – '%s' gearscore changed (%.0f→%.0f), flagging deferred comm request", source, tostring(data.name), oldData.gearscore or 0, data.gearscore or 0))
                pendingCommRequest = true
            elseif oldData.talentData and data.talentData then
                for i = 1, 3 do
                    if (oldData.talentData[i] or 0) ~= (data.talentData[i] or 0) then
                        dprint(string.format("[RI] %s – '%s' talent tree %d changed, flagging deferred comm request", source, tostring(data.name), i))
                        pendingCommRequest = true
                        break
                    end
                end
            end
        end

        cache[data.name] = data
        RaidInspect:RefreshTable()

        -- On private servers the first inspect event sometimes arrives before
        -- item data is fully populated in the client cache.  If GetInventoryItemLink
        -- returns nothing for every slot, the server hasn't pushed any item data yet.
        -- Retry up to MAX_INSPECT_RETRIES times to give the server time to respond.
        local hasItems = next(data.items) ~= nil
        local needsRetry = not hasItems
        if needsRetry then
            local retries = inspRetries[data.name] or 0
            if retries < MAX_INSPECT_RETRIES then
                inspRetries[data.name] = retries + 1
                dprint(string.format("[RI] %s – '%s' returned no item data – retry %d/%d",
                    source, data.name, retries + 1, MAX_INSPECT_RETRIES))
                -- Wait INSPECT_RETRY_DELAY seconds before re-inspecting to allow the
                -- item cache to populate on the server side.  Validate the unit token
                -- still maps to the same player before re-enqueueing (roster may shift).
                RaidInspect:ScheduleTimer(function()
                    if UnitGUID(unit) == savedGUID then
                        Enqueue(unit)
                        if not inspecting and not inspDelayTimer then NextInspect() end
                    end
                end, INSPECT_RETRY_DELAY)
            end
        else
            inspRetries[data.name] = nil  -- good item data: reset counter
        end
    else
        dprint(string.format("[RI] %s – CollectData returned nil for '%s'", source, tostring(unit)))
    end

    ClearInspectPlayer()
    inspecting    = nil
    inspectingGUID = nil

    -- Minimum inter-inspect gap before the next player.
    scheduleNextInspect(INTER_INSPECT_DELAY)
end

-- On WotLK 3.3.5, NotifyInspect fires INSPECT_TALENT_READY (not INSPECT_READY —
-- that event is Cataclysm+).  INSPECT_TALENT_READY carries no GUID argument, so
-- we validate using the GUID captured at NotifyInspect time.
-- When LGT is available it fires LibGroupTalents_Update before this handler
-- runs (LibTalentQuery was loaded earlier), so this only acts as a fallback
-- for the LGT-less code path.
function RaidInspect:INSPECT_TALENT_READY()
    dprint(string.format("[RI] INSPECT_TALENT_READY fired – inspecting=%s", tostring(inspecting)))
    if not inspecting then
        dprint("[RI] INSPECT_TALENT_READY – no active inspection, ignoring")
        return
    end
    -- Validate the unit token still refers to the player we requested.
    if inspectingGUID and UnitGUID(inspecting) ~= inspectingGUID then
        dprint(string.format("[RI] INSPECT_TALENT_READY – GUID mismatch (expected %s, got %s), ignoring", tostring(inspectingGUID), tostring(UnitGUID(inspecting))))
        return
    end
    FinishInspect("INSPECT_TALENT_READY")
end

-- ============================================================
-- LibGroupTalents callbacks
-- ============================================================

-- Fired by LGT when fresh talent data arrives for any roster member.
-- When it matches the unit we are currently waiting on, it drives FinishInspect
-- instead of the raw INSPECT_TALENT_READY event, so only ONE NotifyInspect per
-- player is ever issued (via LibTalentQuery's serialised inspect queue).
function RaidInspect:OnLGTUpdate(_, guid, unit)
    if not inspecting or guid ~= inspectingGUID then return end
    dprint(string.format("[RI] LibGroupTalents_Update – '%s' GUID=%s matches, finishing inspect", tostring(unit), tostring(guid)))
    FinishInspect("LGT:Update")
end

-- Fired by LGT when glyph data arrives for a group member via LGT's own comm
-- protocol (independent of our inspect buffer).  Update the cache entry and
-- refresh the table so the talent hover frame shows the latest glyphs.
function RaidInspect:OnLGTGlyphUpdate(_, guid, unit)
    if not unit or not guid then return end
    local name, realm = UnitName(unit)
    if realm and realm ~= "" then name = name.."-"..realm end
    if not name or name == "Unknown" then return end
    local data = cache[name]
    if not data then return end
    local newGlyphs = GlyphsFromLGT(unit)
    if newGlyphs then
        data.glyphs = newGlyphs
        dprint(string.format("[RI] LibGroupTalents_GlyphUpdate – updated glyphs for '%s'", name))
        self:RefreshTable()
    end
end

-- ============================================================
-- AceComm: data request / response (for out-of-range players)
-- ============================================================

function RaidInspect:OnCommReceived(prefix, message, _, sender)
    if prefix ~= COMM_PREFIX then return end

    local AceSerializer = LibStub("AceSerializer-3.0")

    if message == DATA_REQ_MSG then
        -- Respond with our own complete gear / talent / glyph data so that the
        -- requester can inspect us even when we are out of their inspect range.
        local myData = CollectData("player")
        if myData then
            local payload = AceSerializer:Serialize(DATA_RESP_MSG, {
                name         = myData.name,
                class        = myData.class,
                guild        = myData.guild,
                gearscore    = myData.gearscore,
                items        = myData.items,
                gemmed       = myData.gemmed,
                enchanted    = myData.enchanted,
                talentData   = myData.talentData,
                talentPoints = myData.talentPoints,
                glyphs       = myData.glyphs,
            })
            self:SendCommMessage(COMM_PREFIX, payload, "WHISPER", sender)
        end

    else
        -- Try to deserialise as a full data response
        local ok, msgType, payload = AceSerializer:Deserialize(message)
        if not ok then return end

        if msgType == DATA_RESP_MSG then
            -- Full player data response — merge into cache.
            -- The sender reports their OWN data, so it is authoritative.
            local incoming = payload
            if not incoming or not incoming.name then return end
            incoming.timestamp = GetTime()

            local existing = cache[incoming.name]
            if existing then
                -- Preserve any locally-inspected fields that the remote client
                -- did not include (e.g. gearscore may differ across clients).
                for k, v in pairs(incoming) do
                    existing[k] = v
                end
            else
                cache[incoming.name] = incoming
            end
            self:RefreshTable()
        end
    end
end

-- Broadcasts a full-data request to all group members running RaidInspect.
-- Each responding client sends back their own gear, talents, and glyphs so
-- that players who are out of inspect range can still be shown in the table.
-- silent suppresses the chat confirmation (used for auto-triggered requests)
function RaidInspect:RequestData(silent)
    local numRaid = GetNumRaidMembers()
    local channel = numRaid > 0 and "RAID" or "PARTY"
    self:SendCommMessage(COMM_PREFIX, DATA_REQ_MSG, channel)
    if not silent then
        self:Print("Requested gear/talent data from raid/party members running RaidInspect.")
    end
end

-- ============================================================
-- Paperdoll hover frame
-- ============================================================

-- Schedules (or re-schedules) a delayed hide of the paperdoll frame.
local function HidePaperdollHover()
    if paperdollHideTimer then return end
    paperdollHideTimer = RaidInspect:ScheduleTimer(function()
        paperdollHideTimer = nil
        if paperdollFrame then paperdollFrame:Hide() end
    end, 0.15)
end

local function CancelPaperdollHide()
    if paperdollHideTimer then
        RaidInspect:CancelTimer(paperdollHideTimer)
        paperdollHideTimer = nil
    end
end

-- Creates the shared paperdoll hover frame on first use.
local function CreatePaperdollFrame()
    if paperdollFrame then return end

    local maxRows = math.max(#PDOLL_LEFT, #PDOLL_RIGHT)
    local fW = PDOLL_LPAD + PDOLL_COLW + 4 + PDOLL_COLW + PDOLL_LPAD
    local fH = PDOLL_LPAD + 14 + maxRows * PDOLL_ROW + PDOLL_LPAD

    local f = CreateFrame("Frame", "RaidInspect_PaperdollHover", UIParent)
    ns.SetFlat(f)
    f:SetSize(fW, fH)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)

    local titleFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    titleFS:SetPoint("TOP", f, "TOP", 0, -7)
    f.titleFS = titleFS

    -- Helper that creates one row for a single gear slot
    local function MakeSlotRow(slotID, col, rowIdx)
        local xOff = PDOLL_LPAD + (col - 1) * (PDOLL_COLW + 4)
        local yOff = -(PDOLL_LPAD + 13 + (rowIdx - 1) * PDOLL_ROW)

        local rf = CreateFrame("Button", nil, f)
        rf:SetSize(PDOLL_COLW, PDOLL_ROW)
        rf:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, yOff)
        rf:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

        local iconTex = rf:CreateTexture(nil, "ARTWORK")
        iconTex:SetSize(PDOLL_ICON, PDOLL_ICON)
        iconTex:SetPoint("LEFT", rf, "LEFT", 0, 0)
        rf.iconTex = iconTex

        local nameFS = rf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFS:SetPoint("TOPLEFT", iconTex, "TOPRIGHT", 4, -1)
        nameFS:SetWidth(PDOLL_COLW - PDOLL_ICON - 6)
        nameFS:SetJustifyH("LEFT")
        nameFS:SetWordWrap(false)
        rf.nameFS = nameFS

        local statusFS = rf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusFS:SetPoint("BOTTOMLEFT", iconTex, "BOTTOMRIGHT", 4, 1)
        statusFS:SetWidth(PDOLL_COLW - PDOLL_ICON - 6)
        statusFS:SetJustifyH("LEFT")
        statusFS:SetWordWrap(false)
        rf.statusFS = statusFS

        -- Slot buttons cancel the hide timer while hovered so that moving the
        -- mouse over individual slots (or their item tooltips) keeps the frame up.
        rf:SetScript("OnEnter", function(btn)
            CancelPaperdollHide()
            -- Show the item's own tooltip when hovering the icon area
            if btn.itemLink then
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(btn.itemLink)
                GameTooltip:Show()
            end
        end)
        rf:SetScript("OnLeave", function()
            GameTooltip:Hide()
            HidePaperdollHover()
        end)

        rf.slotID = slotID
        paperdollSlots[slotID] = rf
    end

    for i, slotID in ipairs(PDOLL_LEFT)  do MakeSlotRow(slotID, 1, i) end
    for i, slotID in ipairs(PDOLL_RIGHT) do MakeSlotRow(slotID, 2, i) end

    -- Cancel hide when the cursor re-enters the frame itself (gap between slots)
    f:SetScript("OnEnter", CancelPaperdollHide)
    f:SetScript("OnLeave", HidePaperdollHover)

    f:Hide()
    paperdollFrame = f
end

-- Populates and shows the paperdoll hover frame anchored near `anchor`.
local function ShowPaperdollHover(anchor, data)
    if not data then return end
    if not paperdollFrame then CreatePaperdollFrame() end
    CancelPaperdollHide()

    paperdollFrame.titleFS:SetText(data.name .. "'s Equipment")

    for _, slotList in ipairs({PDOLL_LEFT, PDOLL_RIGHT}) do
        for _, slotID in ipairs(slotList) do
            local rf = paperdollSlots[slotID]
            if rf then
                local link = data.items and data.items[slotID]
                rf.itemLink = link
                if link then
                    local itemName, _, quality, itemLevel, _, _, _, _, equipLoc, icon =
                        GetItemInfo(link)
                    if itemName then
                        rf.iconTex:SetTexture(icon or "Interface\\Buttons\\UI-EmptySlot-Disabled")
                        rf.iconTex:SetVertexColor(1, 1, 1, 1)

                        -- Quality-coloured item name + ilvl
                        local r, g, b = 0.8, 0.8, 0.8
                        if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
                            r = ITEM_QUALITY_COLORS[quality].r
                            g = ITEM_QUALITY_COLORS[quality].g
                            b = ITEM_QUALITY_COLORS[quality].b
                        end
                        local ilvlStr = itemLevel and " ("..itemLevel..")" or ""
                        rf.nameFS:SetText(itemName .. ilvlStr)
                        rf.nameFS:SetTextColor(r, g, b, 1)

                        -- Status line: enchant then gems
                        local parts = {}

                        local enchantText = GetEnchantText(link)
                        local needsEnchant = GS_ItemTypes[equipLoc or ""]
                            and GS_ItemTypes[equipLoc or ""].Enchantable
                        if enchantText then
                            parts[#parts + 1] = "|cff00dd00" .. enchantText .. "|r"
                        elseif needsEnchant then
                            parts[#parts + 1] = "|cffff4444No enchant|r"
                        end

                        local gemNames, _, total = GetGemInfo(link)
                        if total > 0 then
                            for _, gn in ipairs(gemNames) do
                                parts[#parts + 1] = "|cff66ccff" .. gn .. "|r"
                            end
                            for _ = #gemNames + 1, total do
                                parts[#parts + 1] = "|cffff4444Empty|r"
                            end
                        end

                        rf.statusFS:SetText(table.concat(parts, "  "))
                    else
                        -- Item data not yet in client cache
                        rf.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                        rf.iconTex:SetVertexColor(1, 1, 1, 1)
                        rf.nameFS:SetText(SLOT_NAMES[slotID] or ("Slot "..slotID))
                        rf.nameFS:SetTextColor(0.5, 0.5, 0.5, 1)
                        rf.statusFS:SetText("")
                    end
                else
                    -- Empty slot
                    rf.iconTex:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
                    rf.iconTex:SetVertexColor(1, 1, 1, 0.4)
                    rf.nameFS:SetText(SLOT_NAMES[slotID] or ("Slot "..slotID))
                    rf.nameFS:SetTextColor(0.4, 0.4, 0.4, 1)
                    rf.statusFS:SetText("")
                end
            end
        end
    end

    paperdollFrame:ClearAllPoints()
    paperdollFrame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    paperdollFrame:SetScale(RaidInspect.db and RaidInspect.db.profile.itemFrameScale or 1.0)
    paperdollFrame:Show()
    paperdollFrame:Raise()
end

-- ============================================================
-- Talent hover frame (read-only inspect tree)
-- ============================================================

-- Schedules (or re-schedules) a delayed hide of the talent hover frame.
local function HideTalentHover()
    if talentHoverHideTimer then return end
    talentHoverHideTimer = RaidInspect:ScheduleTimer(function()
        talentHoverHideTimer = nil
        if talentHoverFrame then talentHoverFrame:Hide() end
    end, 0.15)
end

local function CancelTalentHide()
    if talentHoverHideTimer then
        RaidInspect:CancelTimer(talentHoverHideTimer)
        talentHoverHideTimer = nil
    end
end

-- Returns the x offset (from frame TOPLEFT) for a talent button at
-- tree-tab `tab` (1-3) and column `col` (1-4).
local function TalHovX(tab, col)
    return TALHOV_LPAD
        + (tab - 1) * (TALHOV_COLS * TALHOV_SPC + TALHOV_TABSEP)
        + (col - 1) * TALHOV_SPC
end

-- Creates the shared talent hover frame on first use.
local function CreateTalentHoverFrame()
    if talentHoverFrame then return end

    -- Pre-compute fixed frame width from the rightmost button position
    local fW = TalHovX(TALHOV_TABS, TALHOV_COLS) + TALHOV_BTN + TALHOV_LPAD
    -- Height is set dynamically in ShowTalentHover; start with a reasonable default
    local fH = 400

    local f = CreateFrame("Frame", "RaidInspect_TalentHover", UIParent)
    ns.SetFlat(f)
    f:SetSize(fW, fH)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)

    -- Title and per-tree spec-name headers
    local titleFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    titleFS:SetPoint("TOP", f, "TOP", 0, -7)
    f.titleFS = titleFS

    local treeHeaders = {}
    for t = 1, TALHOV_TABS do
        local hfs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hfs:SetPoint("TOPLEFT", f, "TOPLEFT",
            TalHovX(t, 1), -(TALHOV_LPAD + TALHOV_TITLE_H))
        hfs:SetWidth(TALHOV_COLS * TALHOV_SPC)
        hfs:SetJustifyH("CENTER")
        treeHeaders[t] = hfs
    end
    f.treeHeaders = treeHeaders

    -- Pre-create 3 × MAX_NUM_TALENTS talent icon buttons
    local maxTalents = MAX_NUM_TALENTS or 30
    for i = 1, maxTalents * TALHOV_TABS do
        local tab = math.ceil(i / maxTalents)

        local btn = CreateFrame("Button", nil, f)
        btn:SetSize(TALHOV_BTN, TALHOV_BTN)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", -2000, 0)  -- hidden initially

        local iconTex = btn:CreateTexture(nil, "ARTWORK")
        iconTex:SetAllPoints()
        btn.iconTex = iconTex

        -- Small rank-count label in the bottom-right corner of the icon
        local rankFS = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rankFS:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, 1)
        rankFS:SetText("")
        btn.rankFS = rankFS

        btn:SetScript("OnEnter", function(self)
            CancelTalentHide()
            if self.talentName then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(self.talentName, 1, 1, 1)
                if self.rank and self.maxRank then
                    GameTooltip:AddLine(
                        (self.rank) .. " / " .. (self.maxRank) .. " pts",
                        0.8, 0.8, 0.8)
                end
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
            HideTalentHover()
        end)

        btn:Hide()
        btn.tab = tab
        talentHoverButtons[i] = btn
    end

    -- Glyph section elements (positioned dynamically in ShowTalentHover)
    local glyphSep = f:CreateTexture(nil, "ARTWORK")
    glyphSep:SetHeight(1)
    glyphSep:SetTexture(0.3, 0.3, 0.3, 1)
    f.glyphSep = glyphSep

    local glyphTitleFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    glyphTitleFS:SetText("Glyphs:")
    f.glyphTitleFS = glyphTitleFS

    local glyphLines = {}
    for i = 1, 6 do
        local lfs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lfs:SetJustifyH("LEFT")
        lfs:SetWidth(fW - TALHOV_LPAD * 2)
        lfs:Hide()
        glyphLines[i] = lfs
    end
    f.glyphLines = glyphLines

    f:SetScript("OnEnter", CancelTalentHide)
    f:SetScript("OnLeave", HideTalentHover)

    f:Hide()
    talentHoverFrame = f
end

-- Populates and shows the talent hover frame anchored near `anchor`.
local function ShowTalentHover(anchor, data)
    if not data then return end
    if not talentHoverFrame then CreateTalentHoverFrame() end
    CancelTalentHide()

    local f          = talentHoverFrame
    local maxTalents = MAX_NUM_TALENTS or 30
    local specNames  = CLASS_SPEC_NAMES[data.class] or {"Tree 1", "Tree 2", "Tree 3"}
    local talPts     = data.talentData   or {0, 0, 0}
    local talRanks   = data.talentPoints or {}

    f.titleFS:SetText(data.name .. "'s Talents")

    -- Update per-tree headers (spec name + point total)
    for t = 1, TALHOV_TABS do
        f.treeHeaders[t]:SetText(
            (specNames[t] or ("Tree "..t)) .. "  " .. (talPts[t] or 0))
    end

    -- Reset all buttons
    for _, btn in ipairs(talentHoverButtons) do
        btn:Hide()
        btn.talentName = nil
        btn.rank       = nil
        btn.maxRank    = nil
    end

    -- Populate buttons from LibGroupTalents class data
    local classData = LGT and LGT.classTalentData and LGT.classTalentData[data.class]
    local maxTier   = 0

    if classData then
        for treeIdx = 1, math.min(#classData, TALHOV_TABS) do
            local tree = classData[treeIdx]
            if tree and tree.list then
                for _, entry in ipairs(tree.list) do
                    local btnIdx = (treeIdx - 1) * maxTalents + entry.index
                    local btn    = talentHoverButtons[btnIdx]
                    if btn then
                        local rank = talRanks[entry.name] or 0

                        btn.iconTex:SetTexture(entry.icon)
                        if rank > 0 then
                            btn.iconTex:SetVertexColor(1, 1, 1, 1)
                            btn.rankFS:SetText(tostring(rank))
                            btn.rankFS:SetTextColor(1, 1, 0, 1)
                        else
                            btn.iconTex:SetVertexColor(TALHOV_DIM, TALHOV_DIM, TALHOV_DIM, 1)
                            btn.rankFS:SetText("")
                        end

                        btn.talentName = entry.name
                        btn.rank       = rank
                        btn.maxRank    = entry.maxRank

                        -- Pixel position inside the frame
                        local xOff = TalHovX(treeIdx, entry.column)
                        local yOff = -(TALHOV_LPAD + TALHOV_TITLE_H + TALHOV_HEADER_H
                                       + TALHOV_SPC * (entry.tier - 1))
                        btn:ClearAllPoints()
                        btn:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, yOff)
                        btn:Show()

                        if entry.tier > maxTier then maxTier = entry.tier end
                    end
                end
            end
        end
    end

    -- y-offset directly below the talent-tree area
    local treeSectionH = TALHOV_LPAD + TALHOV_TITLE_H + TALHOV_HEADER_H
                       + maxTier * TALHOV_SPC

    -- Populate glyph section
    local glyphCount = 0
    if data.glyphs and next(data.glyphs) then
        for socket = 1, 6 do
            local g = data.glyphs[socket]
            if g then
                local spellName = GetSpellInfo(g.spellID)
                if spellName then
                    glyphCount = glyphCount + 1
                    local lfs = f.glyphLines[glyphCount]
                    if lfs then
                        local typeStr = (g.glyphType == 1)
                            and "|cffffcc00[Major]|r"
                            or  "|cff99ccff[Minor]|r"
                        lfs:SetText("  " .. typeStr .. " " .. spellName)
                        lfs:SetPoint("TOPLEFT", f, "TOPLEFT",
                            TALHOV_LPAD,
                            -(treeSectionH + TALHOV_GLYPH_SEP + TALHOV_GLYPH_LH
                              + (glyphCount - 1) * TALHOV_GLYPH_LH))
                        lfs:Show()
                    end
                end
            end
        end
    end
    for i = glyphCount + 1, 6 do
        if f.glyphLines[i] then f.glyphLines[i]:Hide() end
    end

    if glyphCount > 0 then
        f.glyphSep:SetPoint("TOPLEFT",  f, "TOPLEFT",  TALHOV_LPAD,  -treeSectionH)
        f.glyphSep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -TALHOV_LPAD, -treeSectionH)
        f.glyphTitleFS:SetPoint("TOPLEFT", f, "TOPLEFT",
            TALHOV_LPAD, -(treeSectionH + TALHOV_GLYPH_SEP))
        f.glyphSep:Show()
        f.glyphTitleFS:Show()
    else
        f.glyphSep:Hide()
        f.glyphTitleFS:Hide()
    end

    -- Resize frame to fit content
    local glyphH = (glyphCount > 0)
        and (TALHOV_GLYPH_SEP + TALHOV_GLYPH_LH + glyphCount * TALHOV_GLYPH_LH + TALHOV_LPAD)
        or  TALHOV_LPAD
    f:SetHeight(treeSectionH + glyphH)

    -- Position the frame
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    f:SetScale(RaidInspect.db and RaidInspect.db.profile.talentFrameScale or 1.0)
    f:Show()
    f:Raise()
end

-- ============================================================
-- Status icon helper
-- ============================================================

-- Sets a texture widget to show a green checkmark, red cross,
-- or grey question mark depending on status (true/false/nil).
local function SetStatusIcon(tex, status)
    if status == true then
        tex:SetTexture(ICON_CHECK)
        tex:SetVertexColor(0, 1, 0, 1)
    elseif status == false then
        tex:SetTexture(ICON_CROSS)
        tex:SetVertexColor(1, 0, 0, 1)
    else
        tex:SetTexture(ICON_WAIT)
        tex:SetVertexColor(0.7, 0.7, 0.7, 1)
    end
end

-- ============================================================
-- Table row creation
-- ============================================================

local function CreateRow(parent, rowIndex)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(COL_TOTAL, ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(rowIndex - 1) * ROW_H)

    -- Row background (zebra-striped, overridden later with class colour)
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, (rowIndex % 2 == 0) and 0.25 or 0.1)
    row.bg = bg

    local x = 0

    -- Helper: create a left-aligned font string in this row
    local function FS(width, anchor)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", row, "LEFT", anchor or x, 0)
        fs:SetWidth(width - 4)
        fs:SetJustifyH("LEFT")
        return fs
    end

    -- Name
    row.nameText = FS(COL_NAME)
    x = x + COL_NAME

    -- Guild
    row.guildText = FS(COL_GUILD)
    row.guildText:SetPoint("LEFT", row, "LEFT", x, 0)
    x = x + COL_GUILD

    -- GearScore (centred)
    local gsText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gsText:SetPoint("LEFT", row, "LEFT", x, 0)
    gsText:SetWidth(COL_GS - 4)
    gsText:SetJustifyH("CENTER")
    row.gsText = gsText
    x = x + COL_GS

    -- Items button (bag icon, hover = item list)
    local itemsBtn = CreateFrame("Button", nil, row)
    itemsBtn:SetSize(COL_ITEMS - 4, ROW_H - 2)
    itemsBtn:SetPoint("LEFT", row, "LEFT", x + 2, 0)
    itemsBtn:SetNormalTexture("Interface\\Buttons\\Button-Backpack-Up")
    itemsBtn:GetNormalTexture():SetAllPoints()
    itemsBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    row.itemsBtn = itemsBtn
    x = x + COL_ITEMS

    -- Talent distribution text button (hover = talent tree tooltip)
    local talBtn = CreateFrame("Button", nil, row)
    talBtn:SetSize(COL_TALENTS - 4, ROW_H - 2)
    talBtn:SetPoint("LEFT", row, "LEFT", x + 2, 0)
    talBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local talText = talBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    talText:SetAllPoints()
    talText:SetJustifyH("CENTER")
    talText:SetText("--/--/--")
    row.talBtn  = talBtn
    row.talText = talText
    x = x + COL_TALENTS

    -- Gemmed icon
    local gemTex = row:CreateTexture(nil, "OVERLAY")
    gemTex:SetSize(COL_GEMMED - 4, ROW_H - 2)
    gemTex:SetPoint("LEFT", row, "LEFT", x + 2, 0)
    row.gemTex = gemTex
    x = x + COL_GEMMED

    -- Enchanted icon
    local enchTex = row:CreateTexture(nil, "OVERLAY")
    enchTex:SetSize(COL_ENCHANTED - 4, ROW_H - 2)
    enchTex:SetPoint("LEFT", row, "LEFT", x + 2, 0)
    row.enchTex = enchTex

    return row
end

-- ============================================================
-- Populate a row with cached player data
-- ============================================================

local function PopulateRow(row, data)
    if not data then row:Hide(); return end

    local cc = CLASS_COLORS[data.class] or {r=1, g=1, b=1}

    -- Class-coloured background
    row.bg:SetTexture(cc.r, cc.g, cc.b, 0.2)

    -- Name (class colour)
    row.nameText:SetText(data.name or "?")
    row.nameText:SetTextColor(cc.r, cc.g, cc.b, 1)

    -- Guild
    row.guildText:SetText(data.guild or "")
    row.guildText:SetTextColor(0.9, 0.9, 0.9, 1)

    -- GearScore with colour coding
    if data.gearscore then
        -- GearScore_GetQuality's internal variables are mislabelled: it returns
        -- (Red_value, Blue_value, Green_value) even though the locals inside the
        -- function are named Red/Green/Blue.  Capture them with the correct names
        -- so the final SetTextColor call is unambiguous.
        local gsRed, gsBlue, gsGreen = GearScore_GetQuality(data.gearscore)
        row.gsText:SetText(tostring(data.gearscore))
        row.gsText:SetTextColor(gsRed, gsGreen, gsBlue, 1)
    else
        row.gsText:SetText("?")
        row.gsText:SetTextColor(0.5, 0.5, 0.5, 1)
    end

    -- Items button — opens the paperdoll hover frame
    row.itemsBtn:SetScript("OnEnter", function(btn) ShowPaperdollHover(btn, data) end)
    row.itemsBtn:SetScript("OnLeave", HidePaperdollHover)

    -- Talent distribution
    local td  = data.talentData or {0, 0, 0}
    local str = string.format("%d/%d/%d", td[1] or 0, td[2] or 0, td[3] or 0)
    row.talText:SetText(str)
    row.talText:SetTextColor(0.9, 0.9, 0.9, 1)
    row.talBtn:SetScript("OnEnter", function(btn) ShowTalentHover(btn, data) end)
    row.talBtn:SetScript("OnLeave", HideTalentHover)

    -- Gemmed
    SetStatusIcon(row.gemTex, data.gemmed)

    -- Enchanted
    SetStatusIcon(row.enchTex, data.enchanted)

    row:Show()
end

-- ============================================================
-- Main window
-- ============================================================

local function CreateHeaderRow(parent)
    local COLS = {
        {label="Name",       w=COL_NAME},
        {label="Guild",      w=COL_GUILD},
        {label="GS",         w=COL_GS},
        {label="Items",      w=COL_ITEMS},
        {label="Talents",    w=COL_TALENTS},
        {label="Gem",        w=COL_GEMMED},
        {label="Ench",       w=COL_ENCHANTED},
    }
    local header = CreateFrame("Frame", nil, parent)
    header:SetSize(COL_TOTAL, HEADER_H)
    local x = 0
    for _, col in ipairs(COLS) do
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWidth(col.w - 4)
        fs:SetPoint("LEFT", header, "LEFT", x + 2, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(col.label)
        x = x + col.w
    end
    return header
end

function RaidInspect:CreateMainFrame()
    if mainFrame then return end

    local f = CreateFrame("Frame", "RaidInspect_Main", UIParent)
    ns.SetFlat(f)
    f:SetSize(WINDOW_W, WINDOW_H)
    f:SetPoint("CENTER", UIParent, "CENTER",
        self.db.profile.windowX, self.db.profile.windowY)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        RaidInspect.db.profile.windowX = math.floor(x + 0.5)
        RaidInspect.db.profile.windowY = math.floor(y + 0.5)
    end)
    f:SetToplevel(true)
    f:Hide()
    f:SetFrameStrata("MEDIUM")

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("RaidInspect")
    title:SetTextColor(unpack(ns.C.gold))

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    ns.SkinCloseButton(closeBtn)

    -- Scan button
    local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    scanBtn:SetSize(80, 22)
    scanBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -7)
    scanBtn:SetText("Scan Raid")
    scanBtn:SetScript("OnClick", function() RaidInspect:ScanRaid() end)
    ns.SkinFlatButton(scanBtn)

    -- Request Data button — asks out-of-range addon users to share their
    -- gear, talent, and glyph data via AceComm.
    local dataBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    dataBtn:SetSize(100, 22)
    dataBtn:SetPoint("LEFT", scanBtn, "RIGHT", 4, 0)
    dataBtn:SetText("Request Data")
    dataBtn:SetScript("OnClick", function() RaidInspect:RequestData() end)
    ns.SkinFlatButton(dataBtn)

    -- Scale sliders — a second compact row below the main buttons.
    -- Each slider adjusts the scale of the corresponding hover frame (0.5 – 2.0).
    local function MakeScaleSlider(labelText, xAnchor, initKey)
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetText(labelText)
        -- Align the label vertically centred within the scale-slider row.
        -- HEADER_H (22px) matches the button height of the first row (scanBtn/dataBtn).
        lbl:SetPoint("TOPLEFT", xAnchor, "BOTTOMLEFT", 0, -(SCALE_ROW_H - HEADER_H) / 2 - 4)

        local sliderName = "RaidInspect_ScaleSlider_" .. initKey
        local sl = CreateFrame("Slider", sliderName, f, "OptionsSliderTemplate")
        sl:SetSize(110, 16)
        sl:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        sl:SetMinMaxValues(0.5, 2.0)
        sl:SetValueStep(0.05)

        local initVal = RaidInspect.db and RaidInspect.db.profile[initKey] or 1.0
        sl:SetValue(initVal)

        -- Replace the template's default "Low"/"High"/"Label" strings
        local lo  = _G[sliderName .. "Low"]
        local hi  = _G[sliderName .. "High"]
        local txt = _G[sliderName .. "Text"]
        if lo  then lo:SetText("0.5") end
        if hi  then hi:SetText("2.0") end
        if txt then txt:SetText(string.format("%.2f", initVal)) end

        sl:SetScript("OnValueChanged", function(self, val)
            -- Snap to the nearest 0.05 step (20 = 1/0.05, the number of steps per unit).
            val = math.floor(val * 20 + 0.5) / 20
            if txt then txt:SetText(string.format("%.2f", val)) end
            if RaidInspect.db then
                RaidInspect.db.profile[initKey] = val
            end
        end)
        return sl
    end

    MakeScaleSlider("Item Scale:",   scanBtn, "itemFrameScale")
    MakeScaleSlider("Talent Scale:", dataBtn, "talentFrameScale")

    -- Column header row (pushed down to make room for the scale slider row)
    local headerRow = CreateHeaderRow(f)
    headerRow:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -34 - SCALE_ROW_H)

    -- Separator line under headers
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetTexture(0.3, 0.3, 0.3, 1)
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  12, -34 - SCALE_ROW_H - HEADER_H)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -34 - SCALE_ROW_H - HEADER_H)

    -- Scroll frame
    local sf = CreateFrame("ScrollFrame", "RaidInspect_ScrollFrame",
                           f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",  12, -34 - SCALE_ROW_H - HEADER_H - 4)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(COL_TOTAL)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    scrollChild = sc

    -- Pre-create enough rows for a full 40-person raid
    for i = 1, 40 do
        local row = CreateRow(sc, i)
        row:Hide()
        rows[i] = row
    end

    mainFrame = f
end

-- ============================================================
-- Table refresh
-- ============================================================

function RaidInspect:RefreshTable()
    if not mainFrame or not mainFrame:IsShown() then return end

    -- Sort by class then by name for a readable layout
    local sorted = {}
    for _, d in pairs(cache) do sorted[#sorted+1] = d end
    table.sort(sorted, function(a, b)
        if a.class ~= b.class then
            return (a.class or "") < (b.class or "")
        end
        return (a.name or "") < (b.name or "")
    end)

    for i, data in ipairs(sorted) do
        if rows[i] then PopulateRow(rows[i], data) end
    end
    for i = #sorted + 1, #rows do
        if rows[i] then rows[i]:Hide() end
    end

    scrollChild:SetHeight(math.max(#sorted * ROW_H, 1))
end

function RaidInspect:ToggleWindow()
    if not mainFrame then self:CreateMainFrame() end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
        self:RefreshTable()
    end
end

-- ============================================================
-- Lifecycle
-- ============================================================

function RaidInspect:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("RaidInspectDB", defaults, true)

    self:RegisterChatCommand("raidinspect", "SlashCommand")
    self:RegisterChatCommand("ri", "SlashCommand")

    self:RegisterComm(COMM_PREFIX, "OnCommReceived")
end

function RaidInspect:OnEnable()
    -- On WotLK 3.3.5, INSPECT_READY does not fire — only INSPECT_TALENT_READY does.
    -- (INSPECT_READY was introduced in Cataclysm.)  Register only INSPECT_TALENT_READY.
    -- When LGT is available, LibGroupTalents_Update fires first (because
    -- LibTalentQuery was loaded before us), making this handler act as a fallback
    -- for the LGT-less code path only.
    self:RegisterEvent("INSPECT_TALENT_READY")
    -- Hook into LibGroupTalents so we can piggyback on its unified inspect
    -- queue rather than issuing duplicate NotifyInspect calls ourselves.
    if LGT then
        LGT.RegisterCallback(self, "LibGroupTalents_Update",      "OnLGTUpdate")
        LGT.RegisterCallback(self, "LibGroupTalents_GlyphUpdate", "OnLGTGlyphUpdate")
    end
    -- Automatically re-scan whenever the group roster changes so that new
    -- members are inspected without requiring a manual /ri scan.
    self:RegisterEvent("RAID_ROSTER_UPDATE")
    self:RegisterEvent("PARTY_MEMBERS_CHANGED")
    self:Print("RaidInspect ready. /ri to open · /ri scan · /ri data")
    -- If we are already in a group when the addon loads, kick off scanning
    -- immediately without waiting for a roster-change event or manual /ri scan.
    self:AutoScan()
end

function RaidInspect:OnDisable()
    if LGT then
        LGT.UnregisterAllCallbacks(self)
    end
    wipe(cache)
    wipe(inspQueue)
    wipe(inspRetries)
    if inspTimer then self:CancelTimer(inspTimer); inspTimer = nil end
    if inspDelayTimer then self:CancelTimer(inspDelayTimer); inspDelayTimer = nil end
    inspecting         = nil
    inspectingGUID     = nil
    pendingCommRequest = false
end

-- Auto-scan handlers — fired by the server when group membership changes.
function RaidInspect:RAID_ROSTER_UPDATE()
    self:AutoScan()
end

function RaidInspect:PARTY_MEMBERS_CHANGED()
    self:AutoScan()
end

function RaidInspect:SlashCommand(input)
    local cmd = strtrim(input or ""):lower()
    if cmd == "scan" then
        self:ScanRaid()
    elseif cmd == "data" then
        self:RequestData()
    else
        self:ToggleWindow()
    end
end
