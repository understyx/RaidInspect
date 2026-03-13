local addonName, ns = ...

-- ==========================================================
-- AuraTrackerMiniTalent AceGUI Widget
-- A mini talent tree selector widget for bar talent restrictions.
-- States: true = required (yellow glow), false = excluded (red X), nil = any (dimmed)
-- Adapted from the WeakAuras MiniTalent widget pattern.
-- ==========================================================

local widgetType, widgetVersion = "AuraTrackerMiniTalent", 2
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(widgetType) or 0) >= widgetVersion then
    return
end

local LGT = LibStub and LibStub("LibGroupTalents-1.0", true)

local ceil = math.ceil
local pairs, ipairs = pairs, ipairs

-- All WotLK playable classes in display order
local ALL_CLASSES = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

-- ==========================================================
-- BUILD TALENT LIST FROM CLASS DATA
-- ==========================================================

-- Builds the list table expected by TalentFrame_Update from the
-- LibGroupTalents classTalentData cache for a given class.
-- Returns (list, numTabs) or (nil, 0) when data is not yet loaded.
local function BuildListForClass(class)
    if not LGT then return nil, 0 end
    local data = LGT.classTalentData and LGT.classTalentData[class]
    if not data then return nil, 0 end

    local list      = {}
    local maxTalents = MAX_NUM_TALENTS or 30
    local numTabs   = 0

    for treeIndex = 1, #data do
        local tree = data[treeIndex]
        if tree and tree.list then
            numTabs = treeIndex
            for _, entry in ipairs(tree.list) do
                local idx = (treeIndex - 1) * maxTalents + entry.index
                list[idx] = { entry.icon, entry.tier, entry.column, entry.name, entry.maxRank }
            end
        end
    end

    if numTabs == 0 then return nil, 0 end

    -- Background textures are stored at the sentinel index
    local bgIndex = maxTalents * numTabs + 1
    list[bgIndex] = {}
    for tab = 1, numTabs do
        if data[tab] then
            list[bgIndex][tab] = data[tab].background
        end
    end

    return list, numTabs
end

local buttonSize = 32
local buttonSizePadded = 45
local columnsPerTab = 4        -- max columns in a WotLK talent tab
local collapsedPerRow = 11     -- buttons per row in collapsed view
local collapsedPadding = 7     -- edge padding in collapsed view
local collapsedSpacing = 4     -- extra spacing between collapsed buttons

-- ==========================================================
-- TALENT BUTTON
-- ==========================================================

local function CreateTalentButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button.obj = parent
    button:SetSize(buttonSize, buttonSize)

    local cover = button:CreateTexture(nil, "OVERLAY")
    cover:SetTexture("interface/buttons/checkbuttonglow")
    cover:SetPoint("CENTER")
    cover:SetSize(buttonSize + 20, buttonSize + 20)
    cover:SetBlendMode("ADD")
    cover:Hide()
    button.cover = cover

    button:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")

    function button:Yellow()
        self.cover:Show()
        self.cover:SetVertexColor(1, 1, 0, 1)
        local normalTexture = self:GetNormalTexture()
        if normalTexture then
            normalTexture:SetVertexColor(1, 1, 1, 1)
        end
        if self.line1 then
            self.line1:Hide()
        end
    end

    function button:Red()
        self.cover:Show()
        self.cover:SetVertexColor(1, 0, 0, 1)
        local normalTexture = self:GetNormalTexture()
        if normalTexture then
            normalTexture:SetVertexColor(1, 0, 0, 1)
        end
        if not self.line1 then
            local line1 = button:CreateTexture(nil, "OVERLAY")
            line1:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
            line1:SetAllPoints(button)
            self.line1 = line1
        end
        self.line1:Show()
    end

    function button:Clear()
        self.cover:Hide()
        local normalTexture = self:GetNormalTexture()
        if normalTexture then
            normalTexture:SetVertexColor(0.3, 0.3, 0.3, 1)
        end
        if self.line1 then
            self.line1:Hide()
        end
    end

    function button:UpdateTexture()
        if self.state == nil then
            self:Clear()
        elseif self.state == true then
            self:Yellow()
        elseif self.state == false then
            self:Red()
        end
    end

    function button:SetValue(value)
        self.state = value
        self:UpdateTexture()
    end

    button:SetScript("OnClick", function(self)
        if self.state == true then
            self:SetValue(false)
        elseif self.state == false then
            self:SetValue(nil)
        else
            self:SetValue(true)
        end
        -- button.obj = talentFrame; talentFrame.obj = AceGUI widget
        -- Pass talentName so callers can save/restore by name across classes
        self.obj.obj:Fire("OnValueChanged", self.index, self.state, self.talentName)
    end)

    button:SetScript("OnEnter", function(self)
        if self.talentName then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.talentName, 1, 1, 1)
            if self.maxRank then
                GameTooltip:AddLine("Max Rank: " .. self.maxRank, 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    button:Clear()
    return button
end

-- ==========================================================
-- TALENT FRAME UPDATE
-- ==========================================================

local function TalentFrame_Update(self)
    local buttonShownCount = 0
    if self.list then
        for _, button in ipairs(self.buttons) do
            local data = self.list[button.index]
            if not data then
                button:Hide()
            else
                local icon, tier, column, talentName, maxRank = unpack(data)
                button.tier       = tier
                button.column     = column
                button.talentName = talentName
                button.maxRank    = maxRank
                button:SetNormalTexture(icon)
                button:UpdateTexture()
                button:ClearAllPoints()
                if self.open then
                    button:SetPoint(
                        "TOPLEFT", button.obj, "TOPLEFT",
                        buttonSizePadded * (column - 1) + (button.tab - 1) * buttonSizePadded * columnsPerTab + 5,
                        -buttonSizePadded * (tier - 1) - 5
                    )
                    button:Enable()
                    button:Show()
                else
                    if button.state ~= nil then
                        buttonShownCount = buttonShownCount + 1
                        button:SetPoint(
                            "TOPLEFT", button.obj, "TOPLEFT",
                            collapsedPadding + ((buttonShownCount - 1) % collapsedPerRow) * (buttonSizePadded + collapsedSpacing),
                            -collapsedPadding + -1 * (ceil(buttonShownCount / collapsedPerRow) - 1) * (buttonSizePadded + collapsedSpacing)
                        )
                        button:Disable()
                        button:Show()
                    else
                        button:Hide()
                    end
                end
            end
        end
    end

    if self.open then
        self.frame:SetHeight(self.saveSize.fullHeight)
    else
        local rows = ceil(buttonShownCount / collapsedPerRow)
        if rows > 0 then
            self.frame:SetHeight(self.saveSize.collapsedRowHeight * rows)
        else
            self.frame:SetHeight(1)
        end
    end

    -- Update background textures using the class-specific numTabs, not the
    -- player's own GetNumTalentTabs() which would be wrong for other classes.
    if self.list then
        local numTabs        = self.numTabs or 0
        local maxTalents     = MAX_NUM_TALENTS or 30
        local backgroundIndex = maxTalents * numTabs + 1
        for tab = 1, numTabs do
            local background = self.backgrounds[tab]
            if background then
                local texture = self.list[backgroundIndex] and self.list[backgroundIndex][tab]
                if texture then
                    local base = "Interface\\TalentFrame\\" .. texture .. "-"
                    background:SetTexture(base .. "TopLeft")
                    if self.open then
                        background:Show()
                    else
                        background:Hide()
                    end
                else
                    background:Hide()
                end
            end
        end
    end
end

-- ==========================================================
-- WIDGET METHODS
-- ==========================================================

local methods = {
    OnAcquire = function(self)
        self:SetDisabled(false)
        self.acquired = true
        -- Default to the current player's class so the widget is immediately useful
        local _, playerClass = UnitClass("player")
        if playerClass then
            self:SetClass(playerClass)
        end
    end,

    OnRelease = function(self)
        self:SetDisabled(true)
        self:SetMultiselect(false)
        self.value   = nil
        self.list    = nil
        self.class   = nil
        self.numTabs = nil
        self.acquired = false
    end,

    SetList = function(self, list)
        self.list = list or {}
        TalentFrame_Update(self)
    end,

    -- Switch the talent tree to the given WoW class identifier (e.g. "PALADIN").
    -- Builds the talent list from LibGroupTalents' classTalentData cache and
    -- updates the class-dropdown label.  When data for the class is not yet
    -- loaded (no player of that class has been inspected), the tree is left
    -- empty; inspect a player of the target class to populate it.
    SetClass = function(self, class)
        if not class then return end
        self.class = class
        local displayName = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
        UIDropDownMenu_SetText(self.classDropdown, displayName)
        local newList, numTabs = BuildListForClass(class)
        self.numTabs = numTabs
        self:SetList(newList)
    end,

    -- Restore per-talent filter states from a name→state table.
    -- Called after SetClass to reinstate saved required/excluded flags.
    RestoreValues = function(self, filterTable)
        filterTable = filterTable or {}
        for _, button in ipairs(self.buttons) do
            if button.talentName ~= nil then
                button:SetValue(filterTable[button.talentName])
            end
        end
        TalentFrame_Update(self)
    end,

    SetDisabled = function(self, disabled)
        if disabled then
            for _, button in pairs(self.buttons) do
                button:Hide()
            end
            for _, background in pairs(self.backgrounds) do
                background:Hide()
            end
            self.open = nil
            self.toggleButton:Hide()
            self.classDropdown:Hide()
            self.frame:Hide()
        else
            self.open = nil
            TalentFrame_Update(self)
            self.toggleButton:Show()
            self.classDropdown:Show()
            self.frame:Show()
        end
    end,

    SetItemValue = function(self, item, value)
        if self.buttons[item] then
            self.buttons[item]:SetValue(value)
            TalentFrame_Update(self)
        end
    end,

    SetValue      = function(self, value) end,
    SetLabel      = function(self, text) end,
    SetMultiselect = function(self, multi) end,

    ToggleView = function(self)
        if not self.open then
            self.open = true
        else
            self.open = nil
        end
        TalentFrame_Update(self)
        if self.parent then
            self.parent:DoLayout()
        end
    end,
}

-- ==========================================================
-- CONSTRUCTOR
-- ==========================================================

local function Constructor()
    local name = widgetType .. AceGUI:GetNextWidgetNum(widgetType)

    local talentFrame = CreateFrame("Button", name, UIParent)
    talentFrame:SetFrameStrata("FULLSCREEN_DIALOG")

    -- Always create buttons for 3 tabs × 30 talents (WotLK maximum).
    -- The displayed content is driven by SetClass / SetList, not by the
    -- current player's GetNumTalentTabs().
    local numTabs    = 3
    local maxTalents = MAX_NUM_TALENTS or 30
    local buttons    = {}
    for i = 1, maxTalents * numTabs do
        local button = CreateTalentButton(talentFrame)
        button.index       = i
        button.tab         = ceil(i / maxTalents)
        button.talentIndex = i - (button.tab - 1) * maxTalents
        table.insert(buttons, button)
    end

    -- Create background textures (3.17 ≈ visually fits 4-column tree background per tab)
    local bgColMultiplier = 3.17
    local backgrounds = {}
    for tab = 1, numTabs do
        local background = talentFrame:CreateTexture(nil, "BACKGROUND")
        background:SetPoint("TOPLEFT",     talentFrame, "TOPLEFT",
                            (tab - 1) * buttonSizePadded * bgColMultiplier, 0)
        background:SetPoint("BOTTOMRIGHT", talentFrame, "BOTTOMLEFT",
                            tab * buttonSizePadded * bgColMultiplier, 0)
        background:SetTexCoord(0, 1, 0, 1)
        background:Show()
        table.insert(backgrounds, background)
    end

    -- Scale to fit settings panel
    local width      = buttonSizePadded * columnsPerTab * numTabs + 10
    local height     = buttonSizePadded * 11 + 10
    local finalWidth = 440
    local scale      = finalWidth / width
    local finalHeight = height * scale

    for _, button in ipairs(buttons) do
        button:SetScale(scale)
    end

    talentFrame:SetSize(finalWidth, finalHeight)
    talentFrame:SetScript("OnClick", function(self)
        self.obj:ToggleView()
    end)

    -- Toggle button (expand/collapse)
    local toggleButton = CreateFrame("Button", name .. "Toggle", talentFrame, "UIPanelButtonTemplate")
    toggleButton:SetSize(120, 22)
    toggleButton:SetPoint("BOTTOMRIGHT", talentFrame, "TOPRIGHT", 0, 2)
    toggleButton:SetText("Select Talents")
    toggleButton:SetScript("OnClick", function(self)
        self:GetParent().obj:ToggleView()
    end)
    toggleButton:Show()

    -- Class selector dropdown — lets users pick any WotLK class so that
    -- talent profiles can be created without being that class yourself.
    local classDropdown = CreateFrame("Frame", name .. "ClassDropdown", talentFrame,
                                      "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(classDropdown, 120)
    UIDropDownMenu_SetText(classDropdown, "Select Class")
    classDropdown:SetPoint("BOTTOMLEFT", talentFrame, "TOPLEFT", -16, 2)

    -- Assemble widget before initialising the dropdown so talentFrame.obj is set
    local widget = {
        frame        = talentFrame,
        type         = widgetType,
        buttons      = buttons,
        toggleButton = toggleButton,
        classDropdown = classDropdown,
        backgrounds  = backgrounds,
        saveSize = {
            fullWidth          = finalWidth,
            fullHeight         = finalHeight,
            collapsedRowHeight = (buttonSizePadded + 5) * scale,
        },
    }

    for method, func in pairs(methods) do
        widget[method] = func
    end

    talentFrame.obj = widget

    UIDropDownMenu_Initialize(classDropdown, function(self, level)
        for _, class in ipairs(ALL_CLASSES) do
            local capturedClass = class
            local info  = UIDropDownMenu_CreateInfo()
            info.text   = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
            info.value  = class
            info.func   = function()
                if talentFrame.obj then
                    talentFrame.obj:SetClass(capturedClass)
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    classDropdown:Show()

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(widgetType, Constructor, widgetVersion)
