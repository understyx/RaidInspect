local addonName, ns = ...

local Swingbar = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceEvent-3.0", "AceConsole-3.0")

local LibFP = LibStub("LibFramePool-1.0")
local LibEM = LibStub("LibEditmode-1.0")
local LSM   = LibStub("LibSharedMedia-3.0")

local BAR_POOL_KEY      = addonName .. "_Bars"
local DEFAULT_BAR_TEX   = "Interface\\TargetingFrame\\UI-StatusBar"
local AUTO_SHOT_NAME

-- Per-class base spell IDs for "on next hit" abilities (rank-1 used only for name lookup)
local CLASS_NEXT_HIT_SPELLS = {
    ["WARRIOR"]     = { 78, 845 },    -- Heroic Strike, Cleave
    ["HUNTER"]      = { 2973 },       -- Raptor Strike
    ["DRUID"]       = { 6807 },       -- Maul
    ["DEATHKNIGHT"] = { 56815 },      -- Rune Strike
}

-- Populated in OnInitialize with the localized spell names for the current class.
-- Name-based matching makes detection rank-independent.
local NEXT_HIT_SPELL_NAMES = {}
local queuedNextHitSpell   = nil  -- spell name currently queued via IsCurrentSpell

local activeBars              = { MH = nil, OH = nil, RANGED = nil }
local lastMHTime, lastMHSpeed = 0, 0
local lastOHTime, lastOHSpeed = 0, 0
local playerClass

local defaults = {
    profile = {
        enabled     = true,
        width       = 200,
        barHeight   = 12,
        barSpacing  = 2,
        barTexture  = "Blizzard",
        x           = 0,
        y           = -100,
        mhColor     = { r = 0.4, g = 0.6, b = 1.0 },
        ohColor     = { r = 1.0, g = 0.5, b = 0.2 },
        rangedColor = { r = 0.3, g = 1.0, b = 0.5 },
    },
}

-- ============================================================
-- Bar-container helper (vertical stacking)
-- ============================================================

local function CreateBarContainer(name, parent, spacing)
    local f = CreateFrame("Frame", name, parent)
    f._children = {}
    f._spacing  = spacing or 2

    function f:AddBar(bar)
        tinsert(self._children, bar)
        self:LayoutBars()
    end

    function f:LayoutBars()
        local totalH = 0
        for i, child in ipairs(self._children) do
            child:ClearAllPoints()
            if i == 1 then
                child:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
            else
                child:SetPoint("TOPLEFT", self._children[i - 1], "BOTTOMLEFT", 0, -self._spacing)
            end
            totalH = totalH + child:GetHeight() + (i > 1 and self._spacing or 0)
        end
        self:SetHeight(math.max(totalH, 1))
    end

    function f:ClearBars()
        wipe(self._children)
    end

    return f
end

-- ============================================================
-- AceConfig options table
-- ============================================================

function Swingbar:GetOptions()
    return {
        name    = addonName,
        handler = self,
        type    = "group",
        args    = {
            enabled = {
                order = 1,
                type  = "toggle",
                name  = "Enable",
                desc  = "Enable or disable the swing timer bars",
                get   = function() return self.db.profile.enabled end,
                set   = function(_, val)
                    self.db.profile.enabled = val
                    if val then self:OnEnable() else self:OnDisable() end
                end,
            },
            editMode = {
                order = 2,
                type  = "execute",
                name  = "Toggle Edit Mode",
                desc  = "Show the mover overlay to drag the swing bar to a new position",
                func  = function()
                    LibEM:ToggleEditMode(addonName)
                end,
            },
            appearance = {
                order  = 3,
                type   = "group",
                name   = "Appearance",
                inline = true,
                args   = {
                    width = {
                        order = 1,
                        type  = "range",
                        name  = "Bar Width",
                        min   = 50, max = 500, step = 1,
                        get   = function() return self.db.profile.width end,
                        set   = function(_, val)
                            self.db.profile.width = val
                            self:RefreshLayout()
                        end,
                    },
                    barHeight = {
                        order = 2,
                        type  = "range",
                        name  = "Bar Height",
                        min   = 4, max = 40, step = 1,
                        get   = function() return self.db.profile.barHeight end,
                        set   = function(_, val)
                            self.db.profile.barHeight = val
                            self:RefreshLayout()
                        end,
                    },
                    barTexture = {
                        order  = 3,
                        type   = "select",
                        name   = "Texture",
                        values = LSM:HashTable("statusbar"),
                        get    = function() return self.db.profile.barTexture end,
                        set    = function(_, val)
                            self.db.profile.barTexture = val
                            self:RefreshLayout()
                        end,
                    },
                },
            },
            colors = {
                order  = 4,
                type   = "group",
                name   = "Colors",
                inline = true,
                args   = {
                    mhColor = {
                        order = 1,
                        type  = "color",
                        name  = "Main Hand",
                        get   = function()
                            local c = self.db.profile.mhColor
                            return c.r, c.g, c.b
                        end,
                        set   = function(_, r, g, b)
                            self.db.profile.mhColor = { r = r, g = g, b = b }
                            if activeBars.MH then activeBars.MH:SetStatusBarColor(r, g, b) end
                        end,
                    },
                    ohColor = {
                        order = 2,
                        type  = "color",
                        name  = "Off Hand",
                        get   = function()
                            local c = self.db.profile.ohColor
                            return c.r, c.g, c.b
                        end,
                        set   = function(_, r, g, b)
                            self.db.profile.ohColor = { r = r, g = g, b = b }
                            if activeBars.OH then activeBars.OH:SetStatusBarColor(r, g, b) end
                        end,
                    },
                    rangedColor = {
                        order = 3,
                        type  = "color",
                        name  = "Ranged",
                        get   = function()
                            local c = self.db.profile.rangedColor
                            return c.r, c.g, c.b
                        end,
                        set   = function(_, r, g, b)
                            self.db.profile.rangedColor = { r = r, g = g, b = b }
                            if activeBars.RANGED then activeBars.RANGED:SetStatusBarColor(r, g, b) end
                        end,
                    },
                },
            },
            profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db),
        },
    }
end

-- ============================================================
-- Lifecycle
-- ============================================================

function Swingbar:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("SwingbarDB", defaults, true)
    AUTO_SHOT_NAME = GetSpellInfo(75)
    _, playerClass = UnitClass("player")

    -- Build the name-based lookup for "on next hit" abilities for this class.
    -- Using spell names (via GetSpellInfo) makes the match rank-independent.
    for _, id in ipairs(CLASS_NEXT_HIT_SPELLS[playerClass] or {}) do
        local name = GetSpellInfo(id)
        if name then NEXT_HIT_SPELL_NAMES[name] = true end
    end

    -- Frame pool: factory creates a StatusBar with a centred overlay label.
    -- The resetter clears animation state so re-acquired bars start fresh.
    LibFP:CreatePool(BAR_POOL_KEY, function(parent)
        local bar = CreateFrame("StatusBar", nil, parent)
        bar:SetMinMaxValues(0, 1)
        bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        bar.text:SetPoint("CENTER")
        return bar
    end, {
        resetter = function(bar)
            bar.isAnimating = false
            bar.paused      = false
            bar.startTime   = nil
            bar.duration    = nil
            bar.lastTick    = nil
            bar:SetValue(0)
            if bar.text then bar.text:SetText("") end
        end,
    })

    -- Register AceConfig options and wire up the Blizzard options panel
    LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, self:GetOptions())
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, addonName)

    -- Slash command: /swingbar  →  opens the options panel
    self:RegisterChatCommand("swingbar", "SlashCommand")
end

function Swingbar:SlashCommand(input)
    if input == "edit" then
        LibEM:ToggleEditMode(addonName)
    else
        LibStub("AceConfigDialog-3.0"):Open(addonName)
    end
end

function Swingbar:OnEnable()
    local db = self.db.profile
    if not db.enabled then
        self:Disable()
        return
    end

    if not self.frame then
        self.frame = CreateBarContainer("Swingbar_Container", UIParent, db.barSpacing)
        self.frame:SetWidth(db.width)
        self.frame:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
        self.frame:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)

        -- Register the container with LibEditmode so it can be repositioned
        self.mover = LibEM:Register(self.frame, {
            label        = "Swingbar",
            addonName    = addonName,
            syncSize     = true,
            initialPoint = { "CENTER", UIParent, "CENTER", db.x, db.y },
            onMove       = function(point, relTo, relPoint, x, y)
                db.x = x
                db.y = y
            end,
            onRightClick = function()
                LibStub("AceConfigDialog-3.0"):Open(addonName)
            end,
        })
    end

    self.frame:Show()

    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("UNIT_SPELLCAST_START")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self:RegisterEvent("UNIT_SPELLCAST_STOP",        "OnSpellCastStop")
    self:RegisterEvent("UNIT_SPELLCAST_FAILED",      "OnSpellCastStop")
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", "OnSpellCastStop")
    if next(NEXT_HIT_SPELL_NAMES) then
        self:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
    end

    self:RefreshLayout()
end

function Swingbar:OnDisable()
    if self.frame then
        self.frame:Hide()
        self.frame:ClearBars()
    end
    LibFP:ReleaseAll(BAR_POOL_KEY)
    wipe(activeBars)
    queuedNextHitSpell = nil
end

function Swingbar:RefreshLayout()
    LibFP:ReleaseAll(BAR_POOL_KEY)
    wipe(activeBars)

    local db = self.db.profile
    if not db.enabled then return end
    if not self.frame then return end

    self.frame:ClearBars()
    self.frame:SetWidth(db.width)

    local texPath = LSM:Fetch("statusbar", db.barTexture) or DEFAULT_BAR_TEX

    local function SetupBar(id, label, color)
        local bar = LibFP:Acquire(BAR_POOL_KEY, self.frame)
        bar:SetStatusBarTexture(texPath)
        bar:SetStatusBarColor(color.r, color.g, color.b)
        bar:SetSize(db.width, db.barHeight)
        bar.text:SetText(label)
        self.frame:AddBar(bar)
        activeBars[id] = bar
    end

    if playerClass == "WARRIOR" then
        SetupBar("MH", "Main Hand", db.mhColor)
        SetupBar("OH", "Off Hand",  db.ohColor)
    else
        if GetInventoryItemLink("player", INVSLOT_MAINHAND) then
            SetupBar("MH", "Main Hand", db.mhColor)
        end
        if GetInventoryItemLink("player", INVSLOT_OFFHAND) then
            local _, ohSpeed = UnitAttackSpeed("player")
            if ohSpeed and ohSpeed > 0 then
                SetupBar("OH", "Off Hand", db.ohColor)
            end
        end
        if playerClass == "HUNTER" and GetInventoryItemLink("player", INVSLOT_RANGED) then
            SetupBar("RANGED", "Ranged", db.rangedColor)
        end
    end

    -- Keep the mover overlay in sync when the container changes size
    if self.mover and self.mover:IsShown() then
        local w, h = self.frame:GetWidth(), self.frame:GetHeight()
        if w and h and w > 0 and h > 0 then
            self.mover:SetSize(w, h)
        end
    end
end

-- ============================================================
-- Swing-timer logic
-- ============================================================

function Swingbar:StartSwing(id, speed)
    local bar = activeBars[id]
    if not bar or not speed or speed <= 0 then return end

    if bar.isAnimating then
        local now = GetTime()
        local remaining = (bar.startTime + bar.duration) - now
        -- If a swing is just about to finish (<0.1s), ignore the new start event
        -- (common workaround for spammy combat logs)
        if remaining > 0.1 then return end
    end

    bar.startTime   = GetTime()
    bar.duration    = speed
    bar:SetValue(0)
    bar.isAnimating = true
end

function Swingbar:OnUpdate(elapsed)
    local now = GetTime()
    local mhSpeed, ohSpeed = UnitAttackSpeed("player")
    local rangedSpeed       = UnitRangedDamage("player")

    for id, bar in pairs(activeBars) do
        if bar and bar.isAnimating then
            if bar.paused then
                -- While paused, shift the start time forward so the bar doesn't "jump" when unpaused
                bar.startTime = bar.startTime + (now - (bar.lastTick or now))
                bar.lastTick  = now
            else
                bar.lastTick = now
                local currentSpeed = (id == "MH" and mhSpeed)
                                  or (id == "OH" and ohSpeed)
                                  or rangedSpeed

                -- Adjust dynamically if attack speed changes mid-swing (Haste procs)
                if currentSpeed and currentSpeed > 0 and currentSpeed ~= bar.duration then
                    local progress = (now - bar.startTime) / bar.duration
                    bar.duration   = currentSpeed
                    bar.startTime  = now - (progress * currentSpeed)
                end

                local progress = (now - bar.startTime) / bar.duration

                if progress >= 1 then
                    bar:SetValue(1)
                    bar.isAnimating = false
                else
                    bar:SetValue(progress)
                end
            end
        end
    end
end

function Swingbar:UNIT_SPELLCAST_START(event, unit, spellName)
    if spellName == "Slam" and unit == "player" then
        if activeBars.MH then activeBars.MH.paused = true end
        if activeBars.OH then activeBars.OH.paused = true end
    end
end

function Swingbar:UNIT_SPELLCAST_SUCCEEDED(event, unit, spellName)
    if unit == "player" and spellName == AUTO_SHOT_NAME then
        self:StartSwing("RANGED", UnitRangedDamage("player"))
    end
end

function Swingbar:OnSpellCastStop(event, unit, spellName)
    if spellName == "Slam" and unit == "player" then
        if activeBars.MH then activeBars.MH.paused = false end
        if activeBars.OH then activeBars.OH.paused = false end
    end
end

-- Track which "on next hit" ability (if any) is currently queued.
-- Fires whenever the player's pending spell changes (CURRENT_SPELL_CAST_CHANGED).
function Swingbar:CURRENT_SPELL_CAST_CHANGED()
    local newQueued
    for spellName in pairs(NEXT_HIT_SPELL_NAMES) do
        if IsCurrentSpell(spellName) then
            newQueued = spellName
            break
        end
    end
    queuedNextHitSpell = newQueued
end

function Swingbar:COMBAT_LOG_EVENT_UNFILTERED(event, ...)
    local _, subEvent, sourceGUID, _, _, _, _, _, _, spellName = ...
    if sourceGUID ~= UnitGUID("player") then return end

    local now = GetTime()
    local mhSpeed, ohSpeed = UnitAttackSpeed("player")
    ohSpeed = ohSpeed or 0

    if subEvent == "SWING_DAMAGE" or subEvent == "SWING_MISSED" then
        local lastMHT, lastMHS = lastMHTime or 0, lastMHSpeed or 0
        local lastOHT, lastOHS = lastOHTime or 0, lastOHSpeed or 0

        -- Determine if this was a Main Hand or Off Hand swing
        if lastMHS == 0 or (now >= lastMHT + lastMHS - 0.1) then
            self:StartSwing("MH", mhSpeed)
            lastMHTime, lastMHSpeed = now, mhSpeed
        elseif ohSpeed > 0 and (lastOHS == 0 or (now >= lastOHT + lastOHS - 0.1)) then
            self:StartSwing("OH", ohSpeed)
            lastOHTime, lastOHSpeed = now, ohSpeed
        end

    elseif subEvent == "SPELL_DAMAGE" or subEvent == "SPELL_MISSED" then
        -- Reset swing timer on "on next hit" abilities (Heroic Strike, Cleave,
        -- Raptor Strike, Maul, Rune Strike, etc.).  Name-based matching works
        -- for every rank without maintaining a large ID list.
        if NEXT_HIT_SPELL_NAMES[spellName] then
            self:StartSwing("MH", mhSpeed)
            lastMHTime, lastMHSpeed = now, mhSpeed
        end
    end
end