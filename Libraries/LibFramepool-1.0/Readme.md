# LibFramePool-1.0

**LibFramePool-1.0** is a lightweight World of Warcraft library designed to manage the recycling of frames. By pooling frames instead of creating new ones and discarding old ones, you significantly reduce memory churn and Garbage Collection usage.

## Dependencies

* **LibStub**: This library is required to version and retrieve LibFramePool.

## Getting Started

```lua
local LibFramePool = LibStub("LibFramePool-1.0")
```

## API Reference

### `:CreatePool(poolKey, factoryFunc, [options])`

Creates a new frame pool or retrieves an existing one.

* **`poolKey`** *(string)*: A unique identifier for this pool.
* **`factoryFunc`** *(function or nil)*: A function that creates a new frame when the pool is empty.
    * *Signature:* `function(parent) return frame end`
    * If `nil`, the library defaults to `CreateFrame("Frame", nil, parent or UIParent)`.
* **`options`** *(table or nil)*: Configuration for how frames are reset (see [Pool Options](#pool-options) below).

**Returns:** The pool table object.

### `:Acquire(poolKey, [parent])`

Retrieves a frame from the pool. If the pool is empty, the `factoryFunc` is called to create a new one.

* **`poolKey`** *(string)*: The identifier of the pool to use.
* **`parent`** *(Frame or nil)*: The parent frame to set for the acquired object.

**Returns:** The frame object, or `nil` + error message if the poolKey is invalid.

### `:Release(frame)`

Returns a specific frame to its respective pool to be reused later. The frame is hidden, cleared of points, and reset according to the pool's options.

* **`frame`** *(Frame)*: The frame object to release.
* *Note: If the frame was not created by LibFramePool, this function does nothing.*

### `:ReleaseAll(poolKey)`

Releases **every** currently active frame in the specified pool back into the `unused` queue.

* **`poolKey`** *(string)*: The identifier of the pool.

---

## Pool Options

The `options` table passed to `:CreatePool` controls how frames are cleaned up when `:Release()` is called.

| Option Key | Type | Description |
| :--- | :--- | :--- |
| **`resetter`** | `function` | A custom function called immediately before the frame is stored. Signature: `func(frame)`. |
| **`clearScripts`** | `boolean` | If true, script handlers (e.g., `OnClick`, `OnEnter`) will be set to `nil`. |
| **`scriptsToClear`** | `table` | An array of script names to clear if `clearScripts` is true. If omitted, defaults to a standard list (OnShow, OnClick, OnEnter, etc). |
| **`resetParent`** | `Frame` | If set, the frame is re-parented to this object upon release (useful for hiding frames completely from the UI hierarchy). |

---

## Usage Examples

### 1. Basic Frame Pooling

```lua
local LibFramePool = LibStub("LibFramePool-1.0")

-- 1. Create a pool with a factory function
local function CreateMyButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(100, 20)
    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetColorTexture(1, 0, 0, 0.5)
    btn.tex = tex
    return btn
end

-- Define options: clear OnClick scripts when releasing so old logic doesn't persist
local options = {
    clearScripts = true,
    scriptsToClear = { "OnClick" }
}

LibFramePool:CreatePool("MyButtonPool", CreateMyButton, options)

-- 2. Acquire a button
local newBtn = LibFramePool:Acquire("MyButtonPool", UIParent)
newBtn:SetPoint("CENTER")
newBtn:SetScript("OnClick", function() print("Clicked!") end)

-- 3. Release the button when done
-- It will be Hidden, OnClick cleared, and stored for next time.
LibFramePool:Release(newBtn)
```

### 2. Creating a Custom Resetter

```lua
local function MyCustomReset(frame)
    -- Reset specific custom properties
    frame.myCustomData = nil
    if frame.text then
        frame.text:SetText("")
    end
end

LibFramePool:CreatePool("LabelPool", nil, {
    resetter = MyCustomReset
})
```

## Internal Behavior

When a frame is released, the following standard resets always occur automatically:

* `:Hide()`
* `:ClearAllPoints()`
* `:SetAlpha(1)`
* `:SetScale(1)`
* `:SetFrameStrata("MEDIUM")`
* `:SetFrameLevel(0)`