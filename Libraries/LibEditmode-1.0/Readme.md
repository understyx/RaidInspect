# LibEditmode-1.0

**LibEditmode-1.0** is a World of Warcraft library designed to easily provide "Edit Mode" functionality to your addon's frames. It handles the creation of overlay "mover" frames, a background alignment grid, and positioning logic, allowing users to drag and reposition your UI elements.

## Dependencies
This library requires **LibStub** and **CallbackHandler-1.0**.

## Getting Started

```lua
local LibEditMode = LibStub("LibEditmode-1.0")
```

---

## API Reference

### `:Register(frame, options)`

Registers a UI frame to be movable. This creates a semi-transparent overlay (the "mover") that appears when Edit Mode is active.

**Parameters:**
* `frame` (Frame): The UI element you want to make movable.
* `options` (Table): A table containing configuration settings.

**Options Table:**

| Key | Type | Description |
| :--- | :--- | :--- |
| `label` | string | Text to display on the mover overlay. Defaults to `frame:GetName()` or "Mover". |
| `width` | number | Explicit width of the mover. |
| `height` | number | Explicit height of the mover. |
| `syncSize` | boolean | If true, the mover will automatically adopt the width/height of the target `frame`. |
| `initialPoint` | table | A table of arguments to pass to `SetPoint` (e.g., `{"CENTER", UIParent, "CENTER", 0, 0}`). |
| `onMove` | function | Callback function triggered while dragging: `func(point, relTo, relPoint, x, y)`. |
| `onClick` | function | Callback function triggered if the mover is clicked but *not* dragged (e.g., for configuration menus). |

**Returns:**
* `mover` (Frame): The overlay frame created for handling movement.

**Example:**
```lua
local myFrame = CreateFrame("Frame", "MyAddonFrame", UIParent)
myFrame:SetSize(100, 100)

LibEditMode:Register(myFrame, {
    label = "My Addon Main",
    syncSize = true,
    onMove = function(point, relativeTo, relativePoint, x, y)
        -- Save variables here
        MySavedVars.pos = {point, "UIParent", relativePoint, x, y}
    end,
    onClick = function(self)
        print("Mover clicked!")
    end
})
```

### `:Unregister(frame)`

Removes the mover associated with the specific frame and detaches it.

**Parameters:**
* `frame` (Frame): The UI element to unregister.

### `:SetEditMode(state)`

Enables or disables Edit Mode globally.

* **True:** Shows the alignment grid and all registered mover frames. The specific strata of movers is bumped above their target frames.
* **False:** Hides the grid and all movers.

### `:ToggleEditMode()`

Toggles the current state of Edit Mode (On -> Off or Off -> On).

### `:GetMover(frame)`

Retrieves the mover object associated with a specific target frame.

**Returns:**
* `mover` (Frame) or `nil`.

### `:GetMoverPosition(mover)`

Helper to get the current anchor points of a mover.

**Returns:**
* `point`, `relativeTo`, `relativePoint`, `x`, `y`

---

## Callbacks

LibEditmode uses `CallbackHandler-1.0`. You can register callbacks to react to global events.

### `LibEditmode_OnEditModeEnter`
Fired when `:SetEditMode(true)` is called.

### `LibEditmode_OnEditModeExit`
Fired when `:SetEditMode(false)` is called.


**Payload:**
1.  `event`: "LibEditmode_OnMove"
2.  `mover`: The mover frame object being dragged.
3.  `point`: Anchor point.
4.  `relativeTo`: Relative frame.
5.  `relativePoint`: Relative anchor point.
6.  `x`: X offset.
7.  `y`: Y offset.

**Example Usage:**
```lua
function MyAddon:OnEnable()
    LibEditMode.callbacks:RegisterCallback("LibEditmode_OnEditModeEnter", function()
        print("Edit Mode Enabled - Drag things around!")
    end)
end
```

## Complete Usage Example

```lua
local addonName, ns = ...
local LEM = LibStub("LibEditmode-1.0")

-- 1. Create your frame
local myFrame = CreateFrame("Frame", "MyCoolFrame", UIParent)
myFrame:SetSize(200, 50)
myFrame:SetPoint("CENTER")
local tex = myFrame:CreateTexture(nil, "BACKGROUND")
tex:SetAllPoints()
tex:SetColorTexture(0, 0, 0, 0.5)

-- 2. Register it with the library
LEM:Register(myFrame, {
    label = "Cool Frame",
    syncSize = true, -- Mover will be 200x50
    onMove = function(point, relTo, relPoint, x, y)
        -- Logic to save position to DB
        ns.db.profile.x = x
        ns.db.profile.y = y
    end
})

-- 3. create a slash command to toggle mode
SLASH_MYADDON1 = "/myaddon"
SlashCmdList["MYADDON"] = function(msg)
    if msg == "unlock" then
        LEM:ToggleEditMode()
    end
end
```