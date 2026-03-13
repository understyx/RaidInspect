local MAJOR, MINOR = "LibFramePool-1.0", 1
local LibFramePool = LibStub:NewLibrary(MAJOR, MINOR)
if not LibFramePool then
    return
end

LibFramePool.pools = {}

local DEFAULT_SCRIPTS_TO_CLEAR = {
    "OnUpdate", "OnEvent", "OnShow", "OnHide",
    "OnEnter", "OnLeave", "OnMouseDown", "OnMouseUp",
    "OnMouseWheel", "OnKeyDown", "OnKeyUp",
    "OnSizeChanged", "OnValueChanged", "OnDragStart",
    "OnDragStop", "OnReceiveDrag", "OnClick",
}

function LibFramePool:CreatePool(poolKey, factoryFunc, options)
    assert(type(poolKey) == "string", "poolKey must be a string")

    if self.pools[poolKey] then
        return self.pools[poolKey]
    end

    local pool = {
        key = poolKey,
        factory = factoryFunc,
        unused = {},
        active = {},
        options = options or {},
        counts = {
            created = 0,
            active = 0,
        },
    }

    self.pools[poolKey] = pool
    return pool
end

function LibFramePool:Acquire(poolKey, parent)
    local pool = self.pools[poolKey]
    if not pool then
        return nil, "Unknown poolKey: " .. tostring(poolKey)
    end

    local frame = tremove(pool.unused)
    if not frame then
        if pool.factory then
            frame = pool.factory(parent)
        else
            frame = CreateFrame("Frame", nil, parent or UIParent)
        end

        frame._lfp_poolKey = poolKey
        pool.counts.created = pool.counts.created + 1
    end

    if parent then
        frame:SetParent(parent)
    end

    frame:Show()
    frame:SetAlpha(1)

    local index = #pool.active + 1
    pool.active[index] = frame
    frame._lfp_poolIndex = index
    pool.counts.active = pool.counts.active + 1

    return frame
end

function LibFramePool:Release(frame)
    if not frame or not frame._lfp_poolKey then
        return
    end

    local pool = self.pools[frame._lfp_poolKey]
    if not pool then
        return
    end

    local active = pool.active
    local index = frame._lfp_poolIndex
    if not index or active[index] ~= frame then
        for i = 1, #active do
            if active[i] == frame then
                index = i
                break
            end
        end
        if not index then
            return
        end
    end

    local lastIndex = #active
    local lastFrame = active[lastIndex]

    if index ~= lastIndex then
        active[index] = lastFrame
        lastFrame._lfp_poolIndex = index
    end

    active[lastIndex] = nil
    frame._lfp_poolIndex = nil

    pool.counts.active = pool.counts.active - 1

    self:ResetFrame(frame, pool)
    tinsert(pool.unused, frame)
end

function LibFramePool:ReleaseAll(poolKey)
    local pool = self.pools[poolKey]
    if not pool or #pool.active == 0 then
        return
    end

    for i = #pool.active, 1, -1 do
        local frame = pool.active[i]
        frame._lfp_poolIndex = nil
        self:ResetFrame(frame, pool)
        tinsert(pool.unused, frame)
        pool.active[i] = nil
    end

    pool.counts.active = 0
end

function LibFramePool:ResetFrame(frame, pool)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetAlpha(1)
    frame:SetScale(1)
    frame:SetFrameStrata("LOW")
    frame:SetFrameLevel(0)

    if pool.options.resetParent then
        frame:SetParent(pool.options.resetParent)
    end

    if pool.options.clearScripts then
        local scripts = pool.options.scriptsToClear or DEFAULT_SCRIPTS_TO_CLEAR
        for _, script in ipairs(scripts) do
            if frame:HasScript(script) then
                frame:SetScript(script, nil)
            end
        end
    end

    if pool.options.resetter then
        pool.options.resetter(frame)
    end
end