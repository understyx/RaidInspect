local addonName = ...
local MAX_GLYPH_SOCKETS = 6
local WINDOW_WIDTH = 360
local WINDOW_HEIGHT = 240

local addon = CreateFrame("Frame")
local LGT = LibStub and LibStub("LibGroupTalents-1.0", true)
local window
local outputBox

local function GetTargetName()
    local name, realm = UnitName("target")
    if not name then
        return nil
    end

    if realm and realm ~= "" then
        return name .. "-" .. realm
    end

    return name
end

local function SetOutput(text)
    outputBox:SetText(text or "")
    outputBox:SetCursorPosition(0)
    outputBox:HighlightText(0, 0)
    outputBox:ClearFocus()
end

local function BuildGlyphText()
    if not LGT then
        return "LibGroupTalents failed to load."
    end

    if not UnitExists("target") then
        return "Target a player to view glyphs."
    end

    if not UnitIsPlayer("target") then
        return "Your target is not a player."
    end

    local targetName = GetTargetName() or "Unknown"

    LGT:GetUnitTalents("target", true)

    local glyphs = {}
    local major = {}
    local minor = {}
    local glyphSpellIDs = { LGT:GetUnitGlyphs("target") }

    for socket = 1, MAX_GLYPH_SOCKETS do
        local spellID = glyphSpellIDs[socket]
        if spellID and spellID > 0 then
            local spellName = GetSpellInfo(spellID) or ("Spell ID " .. tostring(spellID))
            if socket <= 3 then
                major[#major + 1] = spellName
            else
                minor[#minor + 1] = spellName
            end
            glyphs[#glyphs + 1] = spellName
        end
    end

    if #glyphs == 0 then
        return table.concat({
            targetName,
            "",
            "No glyph data.",
            "LibGroupTalents can only show glyphs for players whose data it has received.",
        }, "\n")
    end

    local lines = {targetName, ""}
    lines[#lines + 1] = "Major Glyphs:"
    if #major == 0 then
        lines[#lines + 1] = "- None"
    else
        for _, name in ipairs(major) do
            lines[#lines + 1] = "- " .. name
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Minor Glyphs:"
    if #minor == 0 then
        lines[#lines + 1] = "- None"
    else
        for _, name in ipairs(minor) do
            lines[#lines + 1] = "- " .. name
        end
    end

    return table.concat(lines, "\n")
end

function addon:RefreshText()
    if not outputBox then
        return
    end

    SetOutput(BuildGlyphText())
end

local function CreateWindow()
    if window then
        return
    end

    window = CreateFrame("Frame", "InspectGlyphBoxFrame", UIParent)
    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetClampedToScreen(true)
    window:SetFrameStrata("MEDIUM")
    window:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    window:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Inspect Glyph Box")

    local refreshButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    refreshButton:SetSize(70, 22)
    refreshButton:SetPoint("TOPLEFT", 14, -10)
    refreshButton:SetText("Refresh")
    refreshButton:SetScript("OnClick", function()
        addon:RefreshText()
    end)

    local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    local scrollFrame = CreateFrame("ScrollFrame", "InspectGlyphBoxScrollFrame", window, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 14, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", -32, 14)

    outputBox = CreateFrame("EditBox", "InspectGlyphBoxOutput", scrollFrame)
    outputBox:SetMultiLine(true)
    outputBox:SetAutoFocus(false)
    outputBox:SetFontObject(ChatFontNormal)
    outputBox:SetWidth(WINDOW_WIDTH - 56)
    outputBox:SetHeight(WINDOW_HEIGHT - 70)
    outputBox:SetTextInsets(4, 4, 4, 4)
    outputBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    outputBox:SetScript("OnTextChanged", function(self)
        local minHeight = WINDOW_HEIGHT - 70
        local textHeight = self:GetNumLines() * 14 + 12
        self:SetHeight(math.max(minHeight, textHeight))
    end)
    outputBox:SetScript("OnCursorChanged", function(self, _, y)
        local scroll = scrollFrame:GetVerticalScroll()
        local height = scrollFrame:GetHeight()
        if y < scroll then
            scrollFrame:SetVerticalScroll(y)
        elseif y > scroll + height - 20 then
            scrollFrame:SetVerticalScroll(y - height + 20)
        end
    end)

    scrollFrame:SetScrollChild(outputBox)

    window:Show()
end

SLASH_INSPECTGLYPHBOX1 = "/inspectglyphbox"
SLASH_INSPECTGLYPHBOX2 = "/igb"
SlashCmdList.INSPECTGLYPHBOX = function()
    if not window then
        CreateWindow()
    end

    if window:IsShown() then
        window:Hide()
    else
        window:Show()
        addon:RefreshText()
    end
end

addon:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            return
        end

        CreateWindow()
        addon:RefreshText()

        if LGT then
            LGT.RegisterCallback(addon, "LibGroupTalents_Update", "RefreshText")
            LGT.RegisterCallback(addon, "LibGroupTalents_GlyphUpdate", "RefreshText")
        end
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        addon:RefreshText()
    end
end)

addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_TARGET_CHANGED")
addon:RegisterEvent("PARTY_MEMBERS_CHANGED")
addon:RegisterEvent("RAID_ROSTER_UPDATE")
