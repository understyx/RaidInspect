local addonName, ns = ...

-------------------------------------------------------------------------------
-- RaidInspect — main addon file
--
-- Inspects every member of the current raid/party and populates a scrollable
-- table with:  Name · Guild · GearScore · Items (hover) · Talents (hover)
--             · Spec ✓  · Gemmed ✓ · Enchanted ✓
--
-- Rows are tinted with the player's class colour.  Per-class acceptable specs
-- are configured via AceConfig toggles and shown as checkmarks in the table.
-- Per-talent required/excluded filters can additionally be set through the
-- talent-filter editor (opened via "Edit Talent Filters" per class in Config).
--
-- AceComm (COMM_PREFIX "RI1") is used to request glyph data from other users
-- of the addon in the same group.
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

local CLASS_LOCAL_NAMES = {
    WARRIOR="Warrior",   PALADIN="Paladin",   HUNTER="Hunter",
    ROGUE="Rogue",       PRIEST="Priest",     DEATHKNIGHT="Death Knight",
    SHAMAN="Shaman",     MAGE="Mage",         WARLOCK="Warlock",
    DRUID="Druid",
}

local CLASS_ORDER = {
    "WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST",
    "DEATHKNIGHT","SHAMAN","MAGE","WARLOCK","DRUID",
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
local GLYPH_REQ_MSG  = "GR"
local GLYPH_RESP_MSG = "GD"

-- UI sizing
local WINDOW_W      = 560
local WINDOW_H      = 450
local ROW_H         = 18
local HEADER_H      = 22
local COL_NAME      = 120
local COL_GUILD     = 100
local COL_GS        = 55
local COL_ITEMS     = 46
local COL_TALENTS   = 78
local COL_SPEC      = 32
local COL_GEMMED    = 38
local COL_ENCHANTED = 46
local COL_TOTAL = COL_NAME + COL_GUILD + COL_GS + COL_ITEMS
               + COL_TALENTS + COL_SPEC + COL_GEMMED + COL_ENCHANTED

local ICON_CHECK    = "Interface\\RaidFrame\\ReadyCheck-Ready"
local ICON_CROSS    = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local ICON_WAIT     = "Interface\\RaidFrame\\ReadyCheck-Waiting"

local BACKDROP_DEF = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true, tileSize = 32, edgeSize = 32,
    insets   = {left=11, right=12, top=12, bottom=11},
}

-- ============================================================
-- Saved-variable defaults
-- ============================================================

local defaults = {
    profile = {
        acceptableSpecs = {},   -- [class] = {[1]=bool,[2]=bool,[3]=bool}
        talentFilters   = {},   -- [class] = {[talentName]=true/false}
        gsThreshold     = 5000,
        windowX         = 0,
        windowY         = 0,
    },
}

-- ============================================================
-- Runtime state
-- ============================================================

local cache        = {}     -- [playerName] = data record
local inspQueue    = {}     -- list of unit tokens queued for inspection
local inspecting   = nil    -- unit token currently being inspected
local inspTimer    = nil    -- timeout timer handle

-- Hidden tooltip used to count socket slots on item links
local scanTip = CreateFrame("GameTooltip", "RaidInspect_ScanTip",
                            nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Reusable table row frames (pre-created, max 40 = full raid)
local rows = {}
-- Frame references
local mainFrame, scrollChild

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
local function IsFullyGemmed(link)
    local filled, total = GetSocketCounts(link)
    return total == 0 or filled >= total
end

-- Returns true when the item has an enchant or does not need one.
-- Uses GS_ItemTypes (populated by GearScoreLite/informationLite.lua).
local function IsEnchanted(link, equipLoc)
    if not link or not equipLoc then return true end
    local info = GS_ItemTypes and GS_ItemTypes[equipLoc]
    if not info or not info.Enchantable then return true end
    local parts = ParseLink(link)
    if not parts then return true end
    return (tonumber(parts[3] or "0") or 0) > 0
end

-- ============================================================
-- Talent helpers
-- ============================================================

-- Returns the index of the tree with the most points and the
-- three-element point array {tree1, tree2, tree3}.
local function PrimarySpec(talentData)
    if not talentData then return 1, {0,0,0} end
    local maxPts, primary = 0, 1
    for i = 1, 3 do
        if (talentData[i] or 0) > maxPts then
            maxPts  = talentData[i]
            primary = i
        end
    end
    return primary, talentData
end

-- Returns true/false/nil (yes/no/not-configured) for whether the
-- inspected player's primary spec is in the acceptable-spec list.
local function IsSpecAcceptable(class, talentData)
    if not class or not talentData then return nil end
    local cfg = RaidInspect.db and RaidInspect.db.profile.acceptableSpecs[class]
    if not cfg then return nil end
    -- Check if the user has configured anything for this class
    local hasAny = false
    for i = 1, 3 do
        if cfg[i] ~= nil then hasAny = true; break end
    end
    if not hasAny then return nil end
    local primary = PrimarySpec(talentData)
    return cfg[primary] == true
end

-- Returns true/false/nil (all-pass/any-fail/not-configured) for whether
-- the inspected player's per-talent point counts satisfy the saved filters.
-- Filters: true = talent must have at least 1 rank; false = must have 0 ranks.
local function IsTalentFilterSatisfied(class, talentPoints)
    if not class or not talentPoints then return nil end
    local db = RaidInspect.db and RaidInspect.db.profile
    if not db then return nil end
    local classFilter = db.talentFilters and db.talentFilters[class]
    if not classFilter or not next(classFilter) then return nil end
    for talentName, required in pairs(classFilter) do
        local rank = talentPoints[talentName] or 0
        if required == true  and rank == 0 then return false end
        if required == false and rank >  0 then return false end
    end
    return true
end

-- ============================================================
-- Data collection (called immediately after INSPECT_READY)
-- ============================================================

local function CollectData(unit)
    if not unit or not UnitIsPlayer(unit) then return nil end

    local name, realm = UnitName(unit)
    if realm and realm ~= "" then name = name.."-"..realm end
    if not name or name == "Unknown" then return nil end

    local _, class = UnitClass(unit)
    local guild     = GetGuildInfo(unit) or ""

    -- Item links
    local items = {}
    for _, slot in ipairs(GEAR_SLOTS) do
        items[slot] = GetInventoryItemLink(unit, slot)
    end

    -- GearScore (from GearScoreLite)
    local gs = 0
    if GearScore_GetScore then
        gs = GearScore_GetScore(name, unit) or 0
    end

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
    -- Pass isnotplayer so we read the inspected unit's talents rather than
    -- the player's own; for "player" both values are equivalent.
    local isnotplayer = not UnitIsUnit(unit, "player")
    local talentData  = {0, 0, 0}
    local talentPoints = {}          -- [talentName] = currentRank (> 0 only)
    local numTabs = (GetNumTalentTabs and GetNumTalentTabs(isnotplayer)) or 3
    for tab = 1, math.min(numTabs, 3) do
        local numTalents = (GetNumTalents and GetNumTalents(tab, isnotplayer)) or 0
        for idx = 1, numTalents do
            local talName, _, _, _, rank = GetTalentInfo(tab, idx, isnotplayer)
            talentData[tab] = (talentData[tab] or 0) + (rank or 0)
            if talName and rank and rank > 0 then
                talentPoints[talName] = rank
            end
        end
    end

    -- Glyph data (major + minor, sockets 1-6)
    local glyphs = {}
    for socket = 1, 6 do
        local glyphType, _, glyphSpellID, icon = GetGlyphSocketInfo(socket)
        if glyphSpellID and glyphSpellID > 0 then
            glyphs[socket] = {
                spellID   = glyphSpellID,
                icon      = icon,
                glyphType = glyphType,
            }
        end
    end

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

local function NextInspect()
    if #inspQueue == 0 then inspecting = nil; return end

    local unit = table.remove(inspQueue, 1)

    -- The "player" unit is always accessible without a server-side inspect request.
    -- CanInspect("player") returns false in WotLK, so bypass the queue mechanism.
    if unit == "player" then
        local data = CollectData("player")
        if data then
            cache[data.name] = data
            RaidInspect:RefreshTable()
        end
        -- Use the same inter-inspect delay as for other units.
        RaidInspect:ScheduleTimer(NextInspect, 0.5)
        return
    end

    if not UnitExists(unit) or not CanInspect(unit) then
        NextInspect(); return
    end

    inspecting = unit
    NotifyInspect(unit)

    -- Failsafe timeout so we never get stuck
    if inspTimer then RaidInspect:CancelTimer(inspTimer) end
    inspTimer = RaidInspect:ScheduleTimer(function()
        ClearInspectPlayer()
        inspecting = nil
        NextInspect()
    end, 5)
end

local function Enqueue(unit)
    if inspecting == unit then return end
    for _, u in ipairs(inspQueue) do
        if u == unit then return end
    end
    inspQueue[#inspQueue+1] = unit
    if not inspecting then NextInspect() end
end

function RaidInspect:ScanRaid()
    wipe(inspQueue)
    wipe(cache)
    if inspTimer then self:CancelTimer(inspTimer); inspTimer = nil end
    inspecting = nil

    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid"..i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                Enqueue(unit)
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
end

-- ============================================================
-- Event: inspection data ready
-- ============================================================

function RaidInspect:INSPECT_READY(_, guid)
    if not inspecting then return end
    if guid ~= UnitGUID(inspecting) then return end

    if inspTimer then self:CancelTimer(inspTimer); inspTimer = nil end

    local data = CollectData(inspecting)
    if data then
        cache[data.name] = data
        self:RefreshTable()
    end

    ClearInspectPlayer()
    inspecting = nil

    -- Small delay between inspects to respect server throttling
    self:ScheduleTimer(NextInspect, 0.5)
end

-- ============================================================
-- AceComm: glyph request / response
-- ============================================================

function RaidInspect:OnCommReceived(prefix, message, _, sender)
    if prefix ~= COMM_PREFIX then return end

    local AceSerializer = LibStub("AceSerializer-3.0")

    if message == GLYPH_REQ_MSG then
        -- Respond with our own glyph data
        local myGlyphs = {}
        for socket = 1, 6 do
            local glyphType, _, glyphSpellID, icon = GetGlyphSocketInfo(socket)
            if glyphSpellID and glyphSpellID > 0 then
                myGlyphs[socket] = {
                    spellID   = glyphSpellID,
                    icon      = icon,
                    glyphType = glyphType,
                }
            end
        end
        local payload = AceSerializer:Serialize(GLYPH_RESP_MSG, myGlyphs)
        self:SendCommMessage(COMM_PREFIX, payload, "WHISPER", sender)
    else
        -- Try to deserialise as a glyph response
        local ok, msgType, glyphs = AceSerializer:Deserialize(message)
        if ok and msgType == GLYPH_RESP_MSG then
            -- Match sender to a cache entry (strip realm suffix for comparison)
            local senderBase = sender:match("^([^%-]+)") or sender
            for name, data in pairs(cache) do
                local nameBase = name:match("^([^%-]+)") or name
                if nameBase:lower() == senderBase:lower() then
                    data.glyphs = glyphs
                    self:RefreshTable()
                    break
                end
            end
        end
    end
end

function RaidInspect:RequestGlyphs()
    local numRaid = GetNumRaidMembers()
    local channel = numRaid > 0 and "RAID" or "PARTY"
    self:SendCommMessage(COMM_PREFIX, GLYPH_REQ_MSG, channel)
    self:Print("Requested glyph data from raid/party members running RaidInspect.")
end

-- ============================================================
-- Tooltip helpers
-- ============================================================

local function ShowTalentTooltip(anchor, data)
    if not data then return end
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    local specNames = CLASS_SPEC_NAMES[data.class] or {"Tree 1", "Tree 2", "Tree 3"}
    local td        = data.talentData or {0, 0, 0}

    GameTooltip:AddLine(data.name .. "'s Talents", 1, 1, 1)
    GameTooltip:AddLine(" ")
    for i = 1, 3 do
        GameTooltip:AddDoubleLine(
            specNames[i] or ("Tree "..i),
            (td[i] or 0).." pts",
            0.8, 0.8, 0.8,
            1.0, 1.0, 0.0
        )
    end

    -- Glyph data if available
    if data.glyphs and next(data.glyphs) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Glyphs:", 1, 0.82, 0)
        for socket = 1, 6 do
            local g = data.glyphs[socket]
            if g then
                local spellName = GetSpellInfo(g.spellID)
                if spellName then
                    local typeStr = (g.glyphType == 1) and "[Major]" or "[Minor]"
                    GameTooltip:AddLine("  "..typeStr.." "..spellName, 0.8, 0.8, 0.8)
                end
            end
        end
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("No glyph data — use 'Request Glyphs' button.", 0.5, 0.5, 0.5)
    end

    GameTooltip:Show()
end

local function ShowItemsTooltip(anchor, data)
    if not data then return end
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(data.name .. "'s Equipment", 1, 1, 1)
    GameTooltip:AddLine(" ")

    for _, slot in ipairs(GEAR_SLOTS) do
        local link = data.items and data.items[slot]
        if link then
            local itemName, _, quality, itemLevel = GetItemInfo(link)
            if itemName then
                local qColors = ITEM_QUALITY_COLORS
                local r, g, b = 0.8, 0.8, 0.8
                if qColors and qColors[quality] then
                    r = qColors[quality].r
                    g = qColors[quality].g
                    b = qColors[quality].b
                end
                local slotLabel = SLOT_NAMES[slot] or ("Slot "..slot)
                local ilvlStr   = itemLevel and (" (i"..itemLevel..")") or ""
                GameTooltip:AddDoubleLine(
                    slotLabel, itemName..ilvlStr,
                    0.6, 0.6, 0.6,
                    r, g, b
                )
            end
        end
    end
    GameTooltip:Show()
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

    -- Spec-acceptable icon
    local specTex = row:CreateTexture(nil, "OVERLAY")
    specTex:SetSize(COL_SPEC - 4, ROW_H - 2)
    specTex:SetPoint("LEFT", row, "LEFT", x + 2, 0)
    row.specTex = specTex
    x = x + COL_SPEC

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

    -- GearScore with colour from GearScoreLite
    if data.gearscore then
        -- GearScore_GetQuality's internal variables are mislabelled: it returns
    -- (Red_value, Blue_value, Green_value) even though the locals inside the
    -- function are named Red/Green/Blue.  Capture them with the correct names
    -- so the final SetTextColor call is unambiguous.
        local gsRed, gsBlue, gsGreen = 1, 1, 1
        if GearScore_GetQuality then
            gsRed, gsBlue, gsGreen = GearScore_GetQuality(data.gearscore)
        end
        row.gsText:SetText(tostring(data.gearscore))
        row.gsText:SetTextColor(gsRed, gsGreen, gsBlue, 1)
    else
        row.gsText:SetText("?")
        row.gsText:SetTextColor(0.5, 0.5, 0.5, 1)
    end

    -- Items button
    row.itemsBtn:SetScript("OnEnter", function(btn) ShowItemsTooltip(btn, data) end)
    row.itemsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Talent distribution
    local td  = data.talentData or {0, 0, 0}
    local str = string.format("%d/%d/%d", td[1] or 0, td[2] or 0, td[3] or 0)
    row.talText:SetText(str)
    row.talText:SetTextColor(0.9, 0.9, 0.9, 1)
    row.talBtn:SetScript("OnEnter", function(btn) ShowTalentTooltip(btn, data) end)
    row.talBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Spec acceptable — combine the coarse spec-tree check with the
    -- per-talent filter check; if only one is configured, use that one.
    local specOk   = IsSpecAcceptable(data.class, data.talentData)
    local filterOk = IsTalentFilterSatisfied(data.class, data.talentPoints)
    local acceptable
    if specOk ~= nil and filterOk ~= nil then
        acceptable = specOk and filterOk
    elseif specOk ~= nil then
        acceptable = specOk
    else
        acceptable = filterOk  -- may still be nil when neither is configured
    end
    SetStatusIcon(row.specTex, acceptable)

    -- Gemmed
    SetStatusIcon(row.gemTex, data.gemmed)

    -- Enchanted
    SetStatusIcon(row.enchTex, data.enchanted)

    row:Show()
end

-- ============================================================
-- Talent filter editor
-- ============================================================

-- Reusable popup window that hosts the MiniTalentWidget.
-- One instance is kept alive for the session; switching classes reuses it.
local talentEditorWindow = nil
local talentEditorWidget = nil

function RaidInspect:OpenTalentFilterEditor(class)
    -- One-time creation of the popup window
    if not talentEditorWindow then
        local win = CreateFrame("Frame", "RaidInspect_TalentEditor", UIParent)
        win:SetBackdrop(BACKDROP_DEF)
        win:SetBackdropColor(0, 0, 0, 0.9)
        win:SetSize(510, 500)
        win:SetPoint("CENTER")
        win:SetMovable(true)
        win:SetClampedToScreen(true)
        win:EnableMouse(true)
        win:RegisterForDrag("LeftButton")
        win:SetScript("OnDragStart", function(w) w:StartMoving() end)
        win:SetScript("OnDragStop",  function(w) w:StopMovingOrSizing() end)
        win:SetToplevel(true)
        win:SetFrameStrata("DIALOG")

        local titleText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        titleText:SetPoint("TOP", win, "TOP", 0, -10)
        win.titleText = titleText

        local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -2, -2)
        closeBtn:SetScript("OnClick", function() win:Hide() end)

        local hint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 14, 10)
        hint:SetText("Click: Yellow = required  |  Red = excluded  |  Dim = any")
        hint:SetTextColor(0.7, 0.7, 0.7, 1)

        -- Message shown when no talent data is loaded for the selected class
        local noDataMsg = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noDataMsg:SetPoint("CENTER", win, "CENTER", 0, 0)
        noDataMsg:SetJustifyH("CENTER")
        noDataMsg:SetTextColor(0.6, 0.6, 0.6, 1)
        noDataMsg:Hide()
        win.noDataMsg = noDataMsg

        -- Create the talent widget and reparent it into our window
        local AceGUI = LibStub("AceGUI-3.0")
        local w = AceGUI:Create("AuraTrackerMiniTalent")
        w:SetCallback("OnValueChanged", function(widget, idx, state, talentName)
            local cls = widget.class
            if not cls or not talentName then return end
            if not RaidInspect.db.profile.talentFilters[cls] then
                RaidInspect.db.profile.talentFilters[cls] = {}
            end
            local tbl = RaidInspect.db.profile.talentFilters[cls]
            if state ~= nil then
                tbl[talentName] = state
            else
                tbl[talentName] = nil
                if not next(tbl) then
                    RaidInspect.db.profile.talentFilters[cls] = nil
                end
            end
            RaidInspect:RefreshTable()
        end)

        -- Embed the talent frame inside our window
        w.frame:SetParent(win)
        w.frame:ClearAllPoints()
        -- Leave room above for the title (≈30 px) plus the toggle/dropdown row
        -- that sits 24 px above the talent frame itself.
        w.frame:SetPoint("TOPLEFT", win, "TOPLEFT", 36, -64)

        talentEditorWindow = win
        talentEditorWidget = w
    end

    -- Update window title and switch to the requested class
    local displayName = CLASS_LOCAL_NAMES[class] or class
    talentEditorWindow.titleText:SetText("Talent Filters — " .. displayName)

    talentEditorWidget:SetClass(class)

    -- Show or hide the "no data" message
    local hasData = LGT and LGT.classTalentData and LGT.classTalentData[class]
    if hasData then
        talentEditorWindow.noDataMsg:Hide()
    else
        talentEditorWindow.noDataMsg:SetFormattedText(
            "No talent data loaded for %s.\n"
            .. "Inspect a %s player in-game\nto populate this tree.",
            displayName, displayName)
        talentEditorWindow.noDataMsg:Show()
    end

    -- Restore previously saved filter states for this class
    local filters = self.db.profile.talentFilters[class] or {}
    talentEditorWidget:RestoreValues(filters)

    talentEditorWindow:Show()
    talentEditorWindow:Raise()
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
        {label="Spec",       w=COL_SPEC},
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
    f:SetBackdrop(BACKDROP_DEF)
    f:SetBackdropColor(0, 0, 0, 0.9)
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

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Scan button
    local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    scanBtn:SetSize(80, 22)
    scanBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -7)
    scanBtn:SetText("Scan Raid")
    scanBtn:SetScript("OnClick", function() RaidInspect:ScanRaid() end)

    -- Config button
    local cfgBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cfgBtn:SetSize(70, 22)
    cfgBtn:SetPoint("LEFT", scanBtn, "RIGHT", 4, 0)
    cfgBtn:SetText("Config")
    cfgBtn:SetScript("OnClick", function()
        LibStub("AceConfigDialog-3.0"):Open(addonName)
    end)

    -- Glyph-request button
    local glyphBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    glyphBtn:SetSize(110, 22)
    glyphBtn:SetPoint("LEFT", cfgBtn, "RIGHT", 4, 0)
    glyphBtn:SetText("Request Glyphs")
    glyphBtn:SetScript("OnClick", function() RaidInspect:RequestGlyphs() end)

    -- Column header row
    local headerRow = CreateHeaderRow(f)
    headerRow:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -34)

    -- Separator line under headers
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetTexture(0.3, 0.3, 0.3, 1)
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  12, -34 - HEADER_H)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -34 - HEADER_H)

    -- Scroll frame
    local sf = CreateFrame("ScrollFrame", "RaidInspect_ScrollFrame",
                           f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",  12, -34 - HEADER_H - 4)
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
-- AceConfig options table
-- ============================================================

function RaidInspect:GetOptions()
    -- Build per-class spec-toggle groups
    local specArgs = {}
    for i, class in ipairs(CLASS_ORDER) do
        local ci        = class          -- capture for all closures in this iteration
        local specNames = CLASS_SPEC_NAMES[class] or {}
        local classArgs = {}
        for si, sname in ipairs(specNames) do
            local sii = si               -- capture inner loop variable
            classArgs["spec"..si] = {
                order = si,
                type  = "toggle",
                name  = sname,
                desc  = "Mark "..sname.." as an acceptable spec for "
                        ..(CLASS_LOCAL_NAMES[class] or class).."s",
                get   = function()
                    local t = self.db.profile.acceptableSpecs[ci]
                    return t and t[sii] or false
                end,
                set   = function(_, val)
                    if not self.db.profile.acceptableSpecs[ci] then
                        self.db.profile.acceptableSpecs[ci] = {}
                    end
                    -- Store true when checked; remove (nil) when unchecked so
                    -- that a class with all specs unchecked reverts to "neutral"
                    -- (no requirement) rather than "all specs unacceptable".
                    self.db.profile.acceptableSpecs[ci][sii] = val and true or nil
                    self:RefreshTable()
                end,
            }
        end
        -- Button to open the per-talent filter editor for this class
        classArgs["editTalentFilters"] = {
            order = 99,
            type  = "execute",
            name  = "Edit Talent Filters",
            desc  = "Open the per-talent filter editor for "
                    .. (CLASS_LOCAL_NAMES[ci] or ci) .. "s.\n"
                    .. "Yellow = required talent  |  Red = excluded talent",
            func  = function()
                RaidInspect:OpenTalentFilterEditor(ci)
            end,
        }
        specArgs[class] = {
            order  = i,
            type   = "group",
            name   = CLASS_LOCAL_NAMES[class] or class,
            inline = true,
            args   = classArgs,
        }
    end

    return {
        name    = addonName,
        handler = self,
        type    = "group",
        args    = {
            gsThreshold = {
                order = 1,
                type  = "range",
                name  = "GearScore Threshold",
                desc  = "Minimum GearScore displayed with a green colour in the table",
                min   = 0, max = 6000, step = 10,
                get   = function() return self.db.profile.gsThreshold end,
                set   = function(_, val)
                    self.db.profile.gsThreshold = val
                    self:RefreshTable()
                end,
            },
            acceptableSpecs = {
                order  = 2,
                type   = "group",
                name   = "Acceptable Specs",
                desc   = "Per-class list of specs that satisfy the spec requirement",
                inline = false,
                args   = specArgs,
            },
            profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db),
        },
    }
end

-- ============================================================
-- Lifecycle
-- ============================================================

function RaidInspect:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("RaidInspectDB", defaults, true)

    LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, function()
        return self:GetOptions()
    end)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, addonName)

    self:RegisterChatCommand("raidinspect", "SlashCommand")
    self:RegisterChatCommand("ri", "SlashCommand")

    self:RegisterComm(COMM_PREFIX, "OnCommReceived")
end

function RaidInspect:OnEnable()
    self:RegisterEvent("INSPECT_READY")
    self:Print("RaidInspect ready. /ri to open · /ri scan · /ri glyphs · /ri config")
end

function RaidInspect:OnDisable()
    wipe(cache)
    wipe(inspQueue)
    if inspTimer then self:CancelTimer(inspTimer); inspTimer = nil end
    inspecting = nil
end

function RaidInspect:SlashCommand(input)
    local cmd = strtrim(input or ""):lower()
    if cmd == "scan" then
        self:ScanRaid()
    elseif cmd == "config" then
        LibStub("AceConfigDialog-3.0"):Open(addonName)
    elseif cmd == "glyphs" then
        self:RequestGlyphs()
    else
        self:ToggleWindow()
    end
end
