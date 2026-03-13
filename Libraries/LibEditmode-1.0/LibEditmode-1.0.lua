local MAJOR, MINOR = "LibEditmode-1.0", 3
local Lib = LibStub:NewLibrary(MAJOR, MINOR)
if not Lib then return end

local framepool = {}

Lib.callbacks = Lib.callbacks or LibStub("CallbackHandler-1.0"):New(Lib)

Lib.Movers = Lib.Movers or {}
Lib.EditMode = Lib.EditMode or false
Lib.Grid = Lib.Grid or nil
-- Per-addon/subkey edit-mode state.  Keyed by "addonName" or "addonName:subKey".
Lib.EditModeStates = Lib.EditModeStates or {}


local function CreateGrid()
    if Lib.Grid then return end

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("BACKGROUND")

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetTexture(0, 0, 0, 0.35)

    local size = 32
    local width, height = GetScreenWidth(), GetScreenHeight()
    local centerX, centerY = width / 2, height / 2

    for i = 0, width, size do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetWidth(1)
        t:SetHeight(height)
        t:SetPoint("LEFT", f, "LEFT", i, 0)
        t:SetTexture(1, 1, 1, 0.1)
    end

    for i = 0, height, size do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetWidth(width)
        t:SetHeight(1)
        t:SetPoint("BOTTOM", f, "BOTTOM", 0, i)
        t:SetTexture(1, 1, 1, 0.1)
    end

    local cx = f:CreateTexture(nil, "ARTWORK")
    cx:SetWidth(2)
    cx:SetHeight(height)
    cx:SetPoint("LEFT", f, "LEFT", centerX, 0)
    cx:SetTexture(1, 0, 0, 0.5)

    local cy = f:CreateTexture(nil, "ARTWORK")
    cy:SetWidth(width)
    cy:SetHeight(2)
    cy:SetPoint("BOTTOM", f, "BOTTOM", 0, centerY)
    cy:SetTexture(1, 0, 0, 0.5)

    Lib.Grid = f
end


local function CreateMover()
    local mover = CreateFrame("Frame", nil, UIParent)
    mover:SetMovable(true)
    mover:EnableMouse(true)
    mover:SetClampedToScreen(true)

    mover:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    mover:SetBackdropColor(0, 0.6, 0.1, 0.5)
    mover:SetBackdropBorderColor(0, 0, 0, 1)

    mover.text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mover.text:SetPoint("CENTER")

    mover.dragStartX = nil
    mover.dragStartY = nil
    mover.isDragging = false

    return mover
end


-------------------------------------------------

local SNAP_SIZE = 32

local function SnapPosition(mover)
    local point, relTo, relPoint, x, y = mover:GetPoint()
    if not x or not y then return end
    -- Round to nearest multiple of SNAP_SIZE using standard rounding.
    x = math.floor((x / SNAP_SIZE) + 0.5) * SNAP_SIZE
    y = math.floor((y / SNAP_SIZE) + 0.5) * SNAP_SIZE
    mover:ClearAllPoints()
    mover:SetPoint(point, relTo, relPoint, x, y)
end

local function UpdatePosition(mover)
    local point, relTo, relPoint, x, y = mover:GetPoint()

    if mover.targetFrame then
        mover.targetFrame:ClearAllPoints()
        mover.targetFrame:SetPoint("CENTER", mover, "CENTER")
    end

    if mover.onMove then
        mover.onMove(point, relTo, relPoint, x, y)
    end
end

local function UpdateMoverStrata(mover)
    if not mover.targetFrame then return end
    
    local strata = mover.targetFrame:GetFrameStrata()
    local level = mover.targetFrame:GetFrameLevel()
    
    mover:SetFrameStrata(strata)
    mover:SetFrameLevel(level + 5) 
end

-- Sync the mover's size and anchor to match its target frame's current
-- dimensions and position.  This must be called after the target frame has
-- been fully laid out (e.g. after Bar:UpdateLayout()) so that the mover
-- exactly overlays the bar in edit mode.
local function SyncMoverToFrame(mover)
    if not mover.syncSize or not mover.targetFrame then return end
    local frame = mover.targetFrame
    local w, h = frame:GetWidth(), frame:GetHeight()
    if not w or not h or w <= 0 or h <= 0 then return end
    local scale = frame:GetScale()
    mover:SetSize(w * scale, h * scale)
    -- Re-anchor the mover to the same point/offset as the target frame so
    -- that they perfectly overlap when edit mode is entered.
    local point, relTo, relPoint, x, y = frame:GetPoint(1)
    if point and relTo and relTo ~= mover then
        mover:ClearAllPoints()
        mover:SetPoint(point, relTo, relPoint, x * scale, y * scale)
    end
end


function Lib:Register(frame, opts)
    if not frame or not opts then return end

    local mover = CreateMover()

    mover.targetFrame = frame
    mover.onMove = opts.onMove
    mover.onClick = opts.onClick
    mover.onRightClick = opts.onRightClick
    mover.syncSize = opts.syncSize
    mover.addonName = opts.addonName
    mover.subKey = opts.subKey

    mover.text:SetText(opts.label or frame:GetName() or "Mover")

    -- SetWidth/Height
    if opts.width and opts.height then
        mover:SetWidth(opts.width)
        mover:SetHeight(opts.height)
    end

    if opts.initialPoint then
        mover:SetPoint(unpack(opts.initialPoint))
    else
        mover:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    mover:SetScript("OnMouseDown", function(self, btn)
        if btn ~= "LeftButton" then return end

        self.dragStartX, self.dragStartY = GetCursorPosition()
        self.isDragging = false
        self:StartMoving()

        self:SetScript("OnUpdate", function(s)
            local cx, cy = GetCursorPosition()
            if math.abs(cx - self.dragStartX) > 5
                or math.abs(cy - self.dragStartY) > 5 then
                self.isDragging = true
            end
            UpdatePosition(s)
        end)
    end)

    mover:SetScript("OnMouseUp", function(self, btn)
        -- Right-click: open settings (no drag logic)
        if btn == "RightButton" then
            if self.onRightClick then
                self.onRightClick(self)
            end
            return
        end

        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)

        if not self.isDragging and self.onClick then
            self.onClick(self)
        else
            if self.isDragging then SnapPosition(self) end
            UpdatePosition(self)
        end

        self.dragStartX = nil
        self.dragStartY = nil
        self.isDragging = false
    end)

    if mover.syncSize and mover.targetFrame then
        local w, h = mover.targetFrame:GetWidth(), mover.targetFrame:GetHeight()
        if w and h then
            local scale = mover.targetFrame:GetScale()
            mover:SetWidth(w * scale)
            mover:SetHeight(h * scale)
        end
    end

    -- Initial state check: show if global edit mode or the mover's own addon
    -- edit-mode scope is currently active.
    local shouldShow = Lib.EditMode
    if not shouldShow and mover.addonName then
        local stateKey = mover.subKey and (mover.addonName .. ":" .. mover.subKey) or mover.addonName
        shouldShow = Lib.EditModeStates[stateKey] == true
    end

    if shouldShow then
        UpdateMoverStrata(mover)
        mover:Show()
    else
        mover:Hide()
    end
    
    table.insert(Lib.Movers, mover)

    return mover
end

function Lib:Unregister(frame)
    for i = #Lib.Movers, 1, -1 do
        local mover = Lib.Movers[i]
        if mover.targetFrame == frame then
            mover:Hide()
            mover:SetParent(nil)
            table.remove(Lib.Movers, i)
        end
    end
end

function Lib:SetEditMode(state, addonName, subKey)
    if addonName then
        -- --------------------------------------------------------
        -- Per-addon (or per-addon+subKey) edit mode.
        -- Only movers whose addonName (and optionally subKey) match
        -- are shown or hidden; the global EditMode flag is left
        -- unchanged unless there are no registered addonName-filtered
        -- movers at all.
        -- --------------------------------------------------------
        local stateKey = subKey and (addonName .. ":" .. subKey) or addonName
        if Lib.EditModeStates[stateKey] == state then return end
        Lib.EditModeStates[stateKey] = state

        for _, mover in ipairs(Lib.Movers) do
            local matches
            if subKey then
                matches = mover.addonName == addonName and mover.subKey == subKey
            else
                matches = mover.addonName == addonName
            end

            if matches then
                if state then
                    SyncMoverToFrame(mover)
                    UpdateMoverStrata(mover)
                    mover:Show()
                else
                    mover:Hide()
                end
            end
        end

        -- Update the global grid based on whether any addon has edit mode active.
        local anyActive = false
        for _, v in pairs(Lib.EditModeStates) do
            if v then anyActive = true; break end
        end
        -- Also consider the raw global flag.
        if Lib.EditMode then anyActive = true end

        if anyActive then
            CreateGrid()
            Lib.Grid:Show()
        else
            if Lib.Grid then Lib.Grid:Hide() end
        end

        Lib.callbacks:Fire(state and "LibEditmode_OnEditModeEnter" or "LibEditmode_OnEditModeExit")
    else
        -- --------------------------------------------------------
        -- Global edit mode – original behaviour.
        -- --------------------------------------------------------
        if Lib.EditMode == state then return end
        Lib.EditMode = state

        if state then
            CreateGrid()
            Lib.Grid:Show()
            Lib.callbacks:Fire("LibEditmode_OnEditModeEnter")
        else
            if Lib.Grid then
                Lib.Grid:Hide()
            end
            Lib.callbacks:Fire("LibEditmode_OnEditModeExit")
        end

        for _, mover in ipairs(Lib.Movers) do
            if state then
                SyncMoverToFrame(mover)
                UpdateMoverStrata(mover)
                mover:Show()
            else
                mover:Hide()
            end
        end
    end
end

--- Returns whether edit mode is currently active for the given addonName
--- (and optional subKey).  Pass no arguments to query the global state.
function Lib:IsEditModeActive(addonName, subKey)
    if addonName then
        local stateKey = subKey and (addonName .. ":" .. subKey) or addonName
        return Lib.EditModeStates[stateKey] == true
    end
    return Lib.EditMode
end

function Lib:ToggleEditMode(addonName, subKey)
    local current = self:IsEditModeActive(addonName, subKey)
    self:SetEditMode(not current, addonName, subKey)
end


function Lib:GetMover(frame)
    for _, mover in ipairs(Lib.Movers) do
        if mover.targetFrame == frame then
            return mover
        end
    end
end

function Lib:GetMoverPosition(mover)
    return mover:GetPoint()
end